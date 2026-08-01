#include "extension.h"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <tier1/convar.h>

namespace
{
constexpr int kMaxNextBots = 2048;
constexpr int kNpcClassCount = 10;
constexpr int kCommonClass = 0;
constexpr int kChargerClass = 6;
constexpr int kWitchClass = 7;
constexpr int kTankClass = 8;
constexpr int kBotIdOffset = 8;
constexpr int kScheduledOffset = 12;
constexpr int kLastUpdateTickOffset = 16;
constexpr int kPathConsumerTank = 1 << 0;
constexpr int kPathConsumerCharger = 1 << 1;
constexpr int kPathConsumerMask = kPathConsumerTank | kPathConsumerCharger;

struct BotCacheEntry
{
    void *bot = nullptr;
    int entity = -1;
    int zombieClass = -1;
};

struct PathFollowerStats
{
    std::uint64_t matched = 0;
    std::uint64_t forwarded = 0;
    std::uint64_t invalid = 0;
    std::uint64_t errors = 0;
    int lastClient = -1;
    int lastTick = -1;
};

struct NextBotStats
{
    std::uint64_t shouldUpdateCalls = 0;
    std::uint64_t shouldUpdateEligible = 0;
    std::uint64_t shouldUpdateThrottled = 0;
    std::uint64_t shouldUpdatePassthrough = 0;
    std::uint64_t registerCalls = 0;
    std::uint64_t unregisterCalls = 0;
    std::uint64_t pathFollowerCalls = 0;
    PathFollowerStats tank;
    PathFollowerStats charger;
};

std::array<BotCacheEntry, kMaxNextBots> g_BotCache;
std::array<int, kNpcClassCount> g_UpdateTicks = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
int g_GlobalUpdateTicks = 1;
int g_GetEntityVtableIndex = -1;
int g_ZombieClassOffset = -1;
bool g_SchedulerEnabled = false;
bool g_PathBrokerEnabled = false;
int g_PathConsumers = 0;
bool g_ShouldUpdateDetourEnabled = false;
bool g_RegisterDetourEnabled = false;
bool g_UnregisterDetourEnabled = false;
bool g_PathFollowerUpdateDetourEnabled = false;
bool g_StatusCommandRegistered = false;
NextBotStats g_Stats;

IGameConfig *g_GameConfig = nullptr;
CDetour *g_ShouldUpdateDetour = nullptr;
CDetour *g_RegisterDetour = nullptr;
CDetour *g_UnregisterDetour = nullptr;
CDetour *g_PathFollowerUpdateDetour = nullptr;
IForward *g_TankPathForward = nullptr;
IForward *g_ChargerPathForward = nullptr;

template <typename T>
T ReadField(const void *base, int offset)
{
    T value{};
    std::memcpy(&value, static_cast<const std::uint8_t *>(base) + offset, sizeof(value));
    return value;
}

template <typename T>
void WriteField(void *base, int offset, T value)
{
    std::memcpy(static_cast<std::uint8_t *>(base) + offset, &value, sizeof(value));
}

int GetBotId(void *bot)
{
    return bot ? ReadField<int>(bot, kBotIdOffset) : -1;
}

CBaseEntity *GetBotEntity(void *bot)
{
    if (!bot || g_GetEntityVtableIndex < 0)
        return nullptr;

    void **vtable = *reinterpret_cast<void ***>(bot);
    if (!vtable)
        return nullptr;

#if defined _WIN32
    using GetEntityFn = CBaseEntity *(__thiscall *)(void *);
#else
    using GetEntityFn = CBaseEntity *(*)(void *);
#endif
    return reinterpret_cast<GetEntityFn>(vtable[g_GetEntityVtableIndex])(bot);
}

int ClassifyEntity(CBaseEntity *entity, int &entityIndex)
{
    entityIndex = -1;
    if (!entity)
        return -1;

    cell_t reference = gamehelpers->EntityToBCompatRef(entity);
    entityIndex = gamehelpers->ReferenceToIndex(reference);
    if (entityIndex <= 0 || !gpGlobals || entityIndex >= gpGlobals->maxEntities)
        return -1;

    if (entityIndex <= gpGlobals->maxClients)
    {
        if (g_ZombieClassOffset < 0)
            return -1;

        int zombieClass = ReadField<int>(entity, g_ZombieClassOffset);
        return zombieClass >= 0 && zombieClass < kNpcClassCount ? zombieClass : -1;
    }

    edict_t *edict = gamehelpers->EdictOfIndex(entityIndex);
    if (!edict || edict->IsFree())
        return -1;

    const char *classname = edict->GetClassName();
    if (!classname)
        return -1;
    if (std::strcmp(classname, "infected") == 0)
        return kCommonClass;
    if (std::strcmp(classname, "witch") == 0)
        return kWitchClass;
    return -1;
}

BotCacheEntry &CacheBot(void *bot)
{
    static BotCacheEntry invalid;
    int id = GetBotId(bot);
    if (id < 0 || id >= kMaxNextBots)
        return invalid;

    BotCacheEntry &entry = g_BotCache[id];
    if (entry.bot == bot && entry.zombieClass >= 0)
        return entry;

    entry = {};
    entry.bot = bot;
    entry.entity = -1;
    entry.zombieClass = ClassifyEntity(GetBotEntity(bot), entry.entity);
    return entry;
}

void RegisterBot(int id, void *bot)
{
    if (!bot || id < 0 || id >= kMaxNextBots)
        return;

    g_BotCache[id] = {};
    g_BotCache[id].bot = bot;
}

void ClearBot(int id, void *bot)
{
    if (id < 0 || id >= kMaxNextBots)
        return;

    if (g_BotCache[id].bot == bot)
        g_BotCache[id] = {};
}

enum class PathForwardResult
{
    Invalid,
    Forwarded,
    Error,
};

PathForwardResult RunPathForward(IForward *forward, int client, void *pathFollower)
{
    if (!forward || client <= 0 || !pathFollower)
        return PathForwardResult::Invalid;

    forward->PushCell(client);
    forward->PushCell(static_cast<cell_t>(reinterpret_cast<std::uintptr_t>(pathFollower)));
    return forward->Execute(nullptr) == SP_ERROR_NONE ? PathForwardResult::Forwarded : PathForwardResult::Error;
}

void RecordPathForward(PathFollowerStats &stats, IForward *forward, int client, void *pathFollower)
{
    ++stats.matched;
    PathForwardResult result = RunPathForward(forward, client, pathFollower);
    if (result == PathForwardResult::Invalid)
    {
        ++stats.invalid;
        return;
    }
    if (result == PathForwardResult::Error)
    {
        ++stats.errors;
        return;
    }

    ++stats.forwarded;
    stats.lastClient = client;
    stats.lastTick = gpGlobals ? gpGlobals->tickcount : -1;
}
}

DETOUR_DECL_MEMBER1(Anne_ShouldUpdate, bool, void *, bot)
{
    ++g_Stats.shouldUpdateCalls;
    if (!g_SchedulerEnabled || !bot || !gpGlobals)
    {
        ++g_Stats.shouldUpdatePassthrough;
        return DETOUR_MEMBER_CALL(Anne_ShouldUpdate)(bot);
    }

    BotCacheEntry &entry = CacheBot(bot);
    if (entry.bot != bot || entry.zombieClass < 0 || entry.zombieClass >= kNpcClassCount)
    {
        ++g_Stats.shouldUpdatePassthrough;
        return DETOUR_MEMBER_CALL(Anne_ShouldUpdate)(bot);
    }

    int currentTick = gpGlobals->tickcount;
    int lastTick = ReadField<int>(bot, kLastUpdateTickOffset);
    int updateTicks = g_UpdateTicks[entry.zombieClass];
    if (currentTick < lastTick + updateTicks)
    {
        ++g_Stats.shouldUpdateThrottled;
        return false;
    }

    WriteField<bool>(bot, kScheduledOffset, true);
    if (updateTicks < g_GlobalUpdateTicks)
        WriteField<int>(bot, kLastUpdateTickOffset, lastTick + updateTicks - g_GlobalUpdateTicks);

    ++g_Stats.shouldUpdateEligible;
    return DETOUR_MEMBER_CALL(Anne_ShouldUpdate)(bot);
}

DETOUR_DECL_MEMBER1(Anne_Register, int, void *, bot)
{
    int result = DETOUR_MEMBER_CALL(Anne_Register)(bot);
    ++g_Stats.registerCalls;
    RegisterBot(result, bot);
    return result;
}

DETOUR_DECL_MEMBER1(Anne_Unregister, void, void *, bot)
{
    int id = GetBotId(bot);
    DETOUR_MEMBER_CALL(Anne_Unregister)(bot);
    ++g_Stats.unregisterCalls;
    ClearBot(id, bot);
}

DETOUR_DECL_MEMBER1(Anne_PathFollowerUpdate, void, void *, bot)
{
    ++g_Stats.pathFollowerCalls;
    if (g_PathBrokerEnabled && bot)
    {
        BotCacheEntry &entry = CacheBot(bot);
        if (entry.zombieClass == kTankClass && (g_PathConsumers & kPathConsumerTank) != 0)
            RecordPathForward(g_Stats.tank, g_TankPathForward, entry.entity, this);
        else if (entry.zombieClass == kChargerClass && (g_PathConsumers & kPathConsumerCharger) != 0)
            RecordPathForward(g_Stats.charger, g_ChargerPathForward, entry.entity, this);
    }

    DETOUR_MEMBER_CALL(Anne_PathFollowerUpdate)(bot);
}

namespace
{
int CountCachedBots(bool classifiedOnly)
{
    int count = 0;
    for (const BotCacheEntry &entry : g_BotCache)
    {
        if (entry.bot && (!classifiedOnly || entry.zombieClass >= 0))
            ++count;
    }
    return count;
}

double GetLastAgeSeconds(const PathFollowerStats &stats)
{
    if (!gpGlobals || stats.lastTick < 0 || gpGlobals->tickcount < stats.lastTick)
        return -1.0;
    return static_cast<double>(gpGlobals->tickcount - stats.lastTick) * gpGlobals->interval_per_tick;
}

const char *GetPathState(bool requested, IForward *forward, const PathFollowerStats &stats)
{
    if (!requested)
        return "not-requested";
    if (!g_PathBrokerEnabled)
        return "broker-off";
    if (!forward || forward->GetFunctionCount() == 0)
        return "no-listener";
    if (stats.errors > 0 && stats.forwarded == 0)
        return "forward-error";
    if (stats.forwarded == 0)
        return "waiting";

    double age = GetLastAgeSeconds(stats);
    return age >= 0.0 && age <= 10.0 ? "active" : "idle";
}

void PrintPathStatus(const char *name, int consumer, IForward *forward, const PathFollowerStats &stats)
{
    bool requested = (g_PathConsumers & consumer) != 0;
    unsigned int listeners = forward ? forward->GetFunctionCount() : 0;
    double age = GetLastAgeSeconds(stats);
    if (age < 0.0)
    {
        g_SMAPI->ConPrintf(
            "[Anne NextBot] %s requested=%s listeners=%u matched=%llu forwarded=%llu invalid=%llu errors=%llu last=never state=%s\n",
            name,
            requested ? "yes" : "no",
            listeners,
            static_cast<unsigned long long>(stats.matched),
            static_cast<unsigned long long>(stats.forwarded),
            static_cast<unsigned long long>(stats.invalid),
            static_cast<unsigned long long>(stats.errors),
            GetPathState(requested, forward, stats));
        return;
    }

    g_SMAPI->ConPrintf(
        "[Anne NextBot] %s requested=%s listeners=%u matched=%llu forwarded=%llu invalid=%llu errors=%llu lastClient=%d lastAge=%.2fs state=%s\n",
        name,
        requested ? "yes" : "no",
        listeners,
        static_cast<unsigned long long>(stats.matched),
        static_cast<unsigned long long>(stats.forwarded),
        static_cast<unsigned long long>(stats.invalid),
        static_cast<unsigned long long>(stats.errors),
        stats.lastClient,
        age,
        GetPathState(requested, forward, stats));
}

void Command_NextBotStatus(const CCommand &)
{
    const char *consumers = g_PathConsumers == kPathConsumerMask ? "tank,charger"
        : g_PathConsumers == kPathConsumerTank ? "tank"
        : g_PathConsumers == kPathConsumerCharger ? "charger"
        : "none";

    g_SMAPI->ConPrintf(
        "[Anne NextBot] version=%s scheduler=%s pathBroker=%s consumers=%s cached=%d classified=%d tick=%d\n",
        SMEXT_CONF_VERSION,
        g_SchedulerEnabled ? "on" : "off",
        g_PathBrokerEnabled ? "on" : "off",
        consumers,
        CountCachedBots(false),
        CountCachedBots(true),
        gpGlobals ? gpGlobals->tickcount : -1);
    g_SMAPI->ConPrintf(
        "[Anne NextBot] scheduler calls=%llu eligible=%llu throttled=%llu passthrough=%llu register=%llu unregister=%llu ticks(global=%d charger=%d tank=%d)\n",
        static_cast<unsigned long long>(g_Stats.shouldUpdateCalls),
        static_cast<unsigned long long>(g_Stats.shouldUpdateEligible),
        static_cast<unsigned long long>(g_Stats.shouldUpdateThrottled),
        static_cast<unsigned long long>(g_Stats.shouldUpdatePassthrough),
        static_cast<unsigned long long>(g_Stats.registerCalls),
        static_cast<unsigned long long>(g_Stats.unregisterCalls),
        g_GlobalUpdateTicks,
        g_UpdateTicks[kChargerClass],
        g_UpdateTicks[kTankClass]);
    g_SMAPI->ConPrintf(
        "[Anne NextBot] pathFollower detourCalls=%llu\n",
        static_cast<unsigned long long>(g_Stats.pathFollowerCalls));
    PrintPathStatus("ai_tank", kPathConsumerTank, g_TankPathForward, g_Stats.tank);
    PrintPathStatus("ai_charger", kPathConsumerCharger, g_ChargerPathForward, g_Stats.charger);
}

ConCommand g_NextBotStatusCommand(
    "sm_anne_nextbot_status",
    Command_NextBotStatus,
    "Show Anne NextBot scheduler and PathFollower forwarding status.",
    FCVAR_NONE);

void SetDetourEnabled(CDetour *detour, bool enabled, bool &current)
{
    if (!detour || enabled == current)
        return;

    if (enabled)
        detour->EnableDetour();
    else
        detour->DisableDetour();
    current = enabled;
}

void RefreshDetours()
{
    bool pathNeeded = g_PathConsumers != 0;
    bool cacheNeeded = g_SchedulerEnabled || pathNeeded;

    // Register/UnRegister must already be active before a hot detour starts using the cache.
    if (cacheNeeded)
    {
        SetDetourEnabled(g_RegisterDetour, true, g_RegisterDetourEnabled);
        SetDetourEnabled(g_UnregisterDetour, true, g_UnregisterDetourEnabled);
    }

    SetDetourEnabled(g_ShouldUpdateDetour, g_SchedulerEnabled, g_ShouldUpdateDetourEnabled);
    SetDetourEnabled(g_PathFollowerUpdateDetour, pathNeeded, g_PathFollowerUpdateDetourEnabled);
    g_PathBrokerEnabled = g_PathFollowerUpdateDetourEnabled;

    if (!cacheNeeded)
    {
        SetDetourEnabled(g_UnregisterDetour, false, g_UnregisterDetourEnabled);
        SetDetourEnabled(g_RegisterDetour, false, g_RegisterDetourEnabled);
        g_BotCache.fill(BotCacheEntry{});
    }
}

cell_t Native_IsActive(IPluginContext *, const cell_t *)
{
    return 1;
}

cell_t Native_IsPathBrokerActive(IPluginContext *, const cell_t *)
{
    return g_PathBrokerEnabled ? 1 : 0;
}

cell_t Native_SetPathConsumer(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 2)
        return context->ThrowNativeError("AnneNextBot_SetPathConsumer expects 2 parameters, got %d", params[0]);

    int consumer = params[1];
    if (consumer <= 0 || (consumer & ~kPathConsumerMask) != 0)
        return context->ThrowNativeError("Invalid Anne NextBot path consumer mask %d", consumer);

    if (params[2] != 0)
        g_PathConsumers |= consumer;
    else
        g_PathConsumers &= ~consumer;
    RefreshDetours();
    return g_PathBrokerEnabled ? 1 : 0;
}

cell_t Native_Configure(IPluginContext *context, const cell_t *params)
{
    if (params[0] != 12)
        return context->ThrowNativeError("AnneNextBot_Configure expects 12 parameters, got %d", params[0]);

    g_SchedulerEnabled = params[1] != 0;
    g_GlobalUpdateTicks = std::max(1, static_cast<int>(params[2]));
    for (int i = 0; i < kNpcClassCount; ++i)
        g_UpdateTicks[i] = std::max(1, static_cast<int>(params[i + 3]));
    RefreshDetours();
    return 1;
}

sp_nativeinfo_t g_Natives[] = {
    {"AnneNextBot_IsActive", Native_IsActive},
    {"AnneNextBot_IsPathBrokerActive", Native_IsPathBrokerActive},
    {"AnneNextBot_SetPathConsumer", Native_SetPathConsumer},
    {"AnneNextBot_Configure", Native_Configure},
    {nullptr, nullptr},
};

void DestroyDetour(CDetour *&detour)
{
    if (!detour)
        return;
    detour->Destroy();
    detour = nullptr;
}

bool CreateDetours(char *error, size_t maxlength)
{
    g_ShouldUpdateDetour = DETOUR_CREATE_MEMBER(Anne_ShouldUpdate, "NextBotManager::ShouldUpdate");
    g_RegisterDetour = DETOUR_CREATE_MEMBER(Anne_Register, "NextBotManager::Register");
    g_UnregisterDetour = DETOUR_CREATE_MEMBER(Anne_Unregister, "NextBotManager::UnRegister");
    g_PathFollowerUpdateDetour = DETOUR_CREATE_MEMBER(Anne_PathFollowerUpdate, "PathFollower::Update");

    if (!g_ShouldUpdateDetour || !g_RegisterDetour || !g_UnregisterDetour || !g_PathFollowerUpdateDetour)
    {
        std::snprintf(error, maxlength, "Failed to create one or more NextBot detours");
        return false;
    }

    return true;
}
}

AnneNextBotExtension g_AnneNextBot;
CGlobalVars *gpGlobals = nullptr;
SMEXT_LINK(&g_AnneNextBot);

bool AnneNextBotExtension::SDK_OnMetamodLoad(ISmmAPI *ismm, char *, size_t, bool)
{
    gpGlobals = ismm->GetCGlobals();
    return gpGlobals != nullptr;
}

bool AnneNextBotExtension::SDK_OnLoad(char *error, size_t maxlength, bool late)
{
    if (late)
    {
        std::snprintf(error, maxlength, "Anne NextBot must be loaded during server startup; restart the server after installing it");
        return false;
    }

    if (std::strcmp(g_pSM->GetGameFolderName(), "left4dead2") != 0)
    {
        std::snprintf(error, maxlength, "Anne NextBot only supports Left 4 Dead 2");
        return false;
    }

    char configError[256] = "";
    if (!gameconfs->LoadGameConfigFile("anne_nextbot.games", &g_GameConfig, configError, sizeof(configError)))
    {
        std::snprintf(error, maxlength, "Could not load anne_nextbot.games: %s", configError);
        return false;
    }

    sm_sendprop_info_t zombieClassInfo;
    if (!g_GameConfig->GetOffset("INextBot::GetEntity", &g_GetEntityVtableIndex) ||
        !gamehelpers->FindSendPropInfo("CTerrorPlayer", "m_zombieClass", &zombieClassInfo))
    {
        std::snprintf(error, maxlength, "Could not resolve INextBot::GetEntity or CTerrorPlayer::m_zombieClass");
        SDK_OnUnload();
        return false;
    }
    g_ZombieClassOffset = zombieClassInfo.actual_offset;

    CDetourManager::Init(g_pSM->GetScriptingEngine(), g_GameConfig);
    if (!CreateDetours(error, maxlength))
    {
        SDK_OnUnload();
        return false;
    }

    g_TankPathForward = forwards->CreateForward(
        "AnneNextBot_OnTankPathFollowerUpdate", ET_Ignore, 2, nullptr, Param_Cell, Param_Cell);
    g_ChargerPathForward = forwards->CreateForward(
        "AICharger3_OnPathFollowerUpdate", ET_Ignore, 2, nullptr, Param_Cell, Param_Cell);
    if (!g_TankPathForward || !g_ChargerPathForward)
    {
        std::snprintf(error, maxlength, "Could not create PathFollower forwards");
        SDK_OnUnload();
        return false;
    }

    sharesys->AddNatives(myself, g_Natives);
    sharesys->RegisterLibrary(myself, "anne_nextbot");

    if (!g_SMAPI->RegisterConCommandBase(g_PLAPI, &g_NextBotStatusCommand))
    {
        std::snprintf(error, maxlength, "Could not register sm_anne_nextbot_status");
        SDK_OnUnload();
        return false;
    }
    g_StatusCommandRegistered = true;
    return true;
}

void AnneNextBotExtension::SDK_OnUnload()
{
    if (g_StatusCommandRegistered)
    {
        g_SMAPI->UnregisterConCommandBase(g_PLAPI, &g_NextBotStatusCommand);
        g_StatusCommandRegistered = false;
    }

    g_SchedulerEnabled = false;
    g_PathBrokerEnabled = false;
    g_PathConsumers = 0;

    SetDetourEnabled(g_PathFollowerUpdateDetour, false, g_PathFollowerUpdateDetourEnabled);
    SetDetourEnabled(g_ShouldUpdateDetour, false, g_ShouldUpdateDetourEnabled);
    SetDetourEnabled(g_UnregisterDetour, false, g_UnregisterDetourEnabled);
    SetDetourEnabled(g_RegisterDetour, false, g_RegisterDetourEnabled);

    DestroyDetour(g_PathFollowerUpdateDetour);
    DestroyDetour(g_UnregisterDetour);
    DestroyDetour(g_RegisterDetour);
    DestroyDetour(g_ShouldUpdateDetour);

    if (g_TankPathForward)
    {
        forwards->ReleaseForward(g_TankPathForward);
        g_TankPathForward = nullptr;
    }
    if (g_ChargerPathForward)
    {
        forwards->ReleaseForward(g_ChargerPathForward);
        g_ChargerPathForward = nullptr;
    }
    if (g_GameConfig)
    {
        gameconfs->CloseGameConfigFile(g_GameConfig);
        g_GameConfig = nullptr;
    }

    g_BotCache.fill(BotCacheEntry{});
}
