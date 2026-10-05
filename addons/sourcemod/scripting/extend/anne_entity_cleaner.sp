#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

// Threshold/batch diagnostics inspired by Ahri's 4.3.0 SMX (static analysis).
// Deliberately no general prop/effect/projectile removal or forced map cleanup.
#define PLUGIN_VERSION "1.0.0"
#define MAX_EDICTS 2048
#define MAX_BATCH 128

enum CleanupKind
{
    Cleanup_None,
    Cleanup_ItemBeam,
    Cleanup_DroppedWeapon,
    Cleanup_DeadCommon
};

public Plugin myinfo =
{
    name = "Anne Entity Cleaner",
    author = "Anne",
    description = "Pressure cleanup of tracked leftovers with entity diagnostics.",
    version = PLUGIN_VERSION,
    url = ""
};

ConVar g_Enable, g_Threshold, g_Target, g_Batch, g_Age, g_DropAge, g_Distance;
int g_Refs[MAX_EDICTS];
CleanupKind g_Kinds[MAX_EDICTS];
float g_Since[MAX_EDICTS];
int g_QueuedRefs[MAX_BATCH], g_QueuedCount, g_BeforeUsed;
float g_NextReport, g_NextCleanup;
bool g_MapRunning, g_Baseline, g_Cleaning;
char g_LogPath[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, errMax, "Anne Entity Cleaner requires L4D2.");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    if (GetMaxEntities() > MAX_EDICTS)
        SetFailState("Unsupported edict capacity: %d", GetMaxEntities());

    g_Enable = CreateConVar("anne_entity_cleaner_enable", "1", "Enable pressure cleanup (statistics remain available).", FCVAR_NONE, true, 0.0, true, 1.0);
    g_Threshold = CreateConVar("anne_entity_cleaner_threshold", "1800", "Start cleanup at this edict pressure.", FCVAR_NONE, true, 128.0, true, 2047.0);
    g_Target = CreateConVar("anne_entity_cleaner_target", "1700", "Desired pressure after cleanup; never bypasses safety checks.", FCVAR_NONE, true, 64.0, true, 2046.0);
    g_Batch = CreateConVar("anne_entity_cleaner_batch", "32", "Maximum deletion requests per two-second pass.", FCVAR_NONE, true, 1.0, true, 128.0);
    g_Age = CreateConVar("anne_entity_cleaner_min_age", "30", "Minimum observed age of Anne item beams and confirmed common corpses.", FCVAR_NONE, true, 10.0);
    g_DropAge = CreateConVar("anne_entity_cleaner_drop_age", "120", "Minimum age after a witnessed survivor weapon drop.", FCVAR_NONE, true, 30.0);
    g_Distance = CreateConVar("anne_entity_cleaner_distance", "1500", "Protect entities within this distance of survivors or human infected.", FCVAR_NONE, true, 500.0);
    AutoExecConfig(true, "anne_entity_cleaner");

    BuildPath(Path_SM, g_LogPath, sizeof(g_LogPath), "logs/anne_entity_cleaner.log");
    RegAdminCmd("sm_anne_entities", Command_Stats, ADMFLAG_ROOT, "Print edict counts, safe candidates and largest classes to console.");
    RegAdminCmd("sm_anne_entityclean", Command_Clean, ADMFLAG_ROOT, "Run one bounded pass with the same safety checks; console output only.");
    HookEvent("player_death", Event_Death, EventHookMode_Pre);
    HookEvent("weapon_drop", Event_Drop);
    ResetTracking();
    for (int client = 1; client <= MaxClients; client++)
        if (IsClientInGame(client))
            OnClientPutInServer(client);
    // Persistent timer: OnMapEnd blocks it, and OnMapStart resets all references.
    CreateTimer(2.0, Timer_Check, _, TIMER_REPEAT);
}

public void OnMapStart()
{
    ResetTracking();
    g_MapRunning = true;
    g_Baseline = true;
    g_NextReport = 0.0;
}

public void OnMapEnd()
{
    g_MapRunning = false;
    ResetTracking();
}

void ResetTracking()
{
    for (int entity = 0; entity < MAX_EDICTS; entity++)
        ForgetEntity(entity);
    g_QueuedCount = 0;
    g_NextCleanup = 0.0;
    g_Cleaning = false;
}

void ForgetEntity(int entity)
{
    g_Refs[entity] = INVALID_ENT_REFERENCE;
    g_Kinds[entity] = Cleanup_None;
    g_Since[entity] = 0.0;
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity > MaxClients && entity < MAX_EDICTS)
        ForgetEntity(entity);
}

public void OnEntityDestroyed(int entity)
{
    if (entity > MaxClients && entity < MAX_EDICTS)
        ForgetEntity(entity);
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_WeaponDropPost, WeaponDropPost);
    SDKHook(client, SDKHook_WeaponEquipPost, WeaponEquipPost);
}

void TrackEntity(int entity, CleanupKind kind)
{
    g_Refs[entity] = EntIndexToEntRef(entity);
    g_Kinds[entity] = kind;
    g_Since[entity] = GetGameTime();
}

void WeaponDropPost(int client, int weapon)
{
    if (!g_MapRunning || GetClientTeam(client) != 2 || !IsNetworkEntity(weapon))
        return;
    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    if (IsOrdinaryWeapon(classname))
        TrackEntity(weapon, Cleanup_DroppedWeapon);
}

void WeaponEquipPost(int client, int weapon)
{
    if (weapon > MaxClients && weapon < MAX_EDICTS)
        ForgetEntity(weapon);
}

void Event_Drop(Event event, const char[] name, bool dontBroadcast)
{
    // Also observe plugin-driven drops that bypass SDKHooks' drop forward.
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client))
        WeaponDropPost(client, event.GetInt("propid"));
}

void Event_Death(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_MapRunning || event.GetInt("userid") > 0)
        return;
    int entity = event.GetInt("entityid");
    if (!IsNetworkEntity(entity))
        return;
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (StrEqual(classname, "infected"))
        TrackEntity(entity, Cleanup_DeadCommon);
}

bool IsNetworkEntity(int entity)
{
    return entity > MaxClients && entity < MAX_EDICTS && entity < GetMaxEntities()
        && IsValidEdict(entity) && IsValidEntity(entity);
}

bool IsOrdinaryWeapon(const char[] classname)
{
    // Exact classes: no *_spawn, carryables, melee/chainsaw, custom weapons or projectiles.
    static const char weapons[][] =
    {
        "weapon_pistol", "weapon_pistol_magnum", "weapon_smg", "weapon_smg_silenced", "weapon_smg_mp5",
        "weapon_pumpshotgun", "weapon_shotgun_chrome", "weapon_autoshotgun", "weapon_shotgun_spas",
        "weapon_rifle", "weapon_rifle_ak47", "weapon_rifle_desert", "weapon_rifle_sg552", "weapon_rifle_m60",
        "weapon_hunting_rifle", "weapon_sniper_military", "weapon_sniper_awp", "weapon_sniper_scout",
        "weapon_grenade_launcher", "weapon_pain_pills", "weapon_adrenaline", "weapon_first_aid_kit",
        "weapon_defibrillator", "weapon_molotov", "weapon_pipe_bomb", "weapon_vomitjar"
    };
    for (int i = 0; i < sizeof(weapons); i++)
        if (StrEqual(classname, weapons[i]))
            return true;
    return false;
}

void RefreshCandidates()
{
    char classname[64], name[128];
    for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++)
    {
        if (!IsNetworkEntity(entity))
        {
            ForgetEntity(entity);
            continue;
        }
        if (EntRefToEntIndex(g_Refs[entity]) != entity)
            ForgetEntity(entity);

        GetEntityClassname(entity, classname, sizeof(classname));
        if (g_Kinds[entity] == Cleanup_None && StrEqual(classname, "beam_spotlight")
            && HasEntProp(entity, Prop_Data, "m_iName"))
        {
            GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
            // Its owning plugin clears its own references in OnEntityDestroyed.
            if (StrEqual(name, "l4d_random_beam_item"))
                TrackEntity(entity, Cleanup_ItemBeam);
        }
        if (g_Kinds[entity] == Cleanup_DroppedWeapon
            && ((HasEntProp(entity, Prop_Data, "m_hOwnerEntity")
                && GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity") != -1)
                || (HasEntProp(entity, Prop_Send, "m_hOwner")
                && GetEntPropEnt(entity, Prop_Send, "m_hOwner") != -1)))
            ForgetEntity(entity);
    }
}

bool HasProtectedIdentity(int entity, CleanupKind kind)
{
    // Fail closed if the identity fields cannot be inspected.
    if (!HasEntProp(entity, Prop_Data, "m_iHammerID") || !HasEntProp(entity, Prop_Data, "m_iName"))
        return true;
    if (GetEntProp(entity, Prop_Data, "m_iHammerID") > 0)
        return true;
    char name[128];
    GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
    if (kind == Cleanup_ItemBeam)
    {
        if (!StrEqual(name, "l4d_random_beam_item"))
            return true;
    }
    else if (name[0] != '\0')
        return true;
    if (HasEntProp(entity, Prop_Data, "m_iGlobalname"))
    {
        GetEntPropString(entity, Prop_Data, "m_iGlobalname", name, sizeof(name));
        if (name[0] != '\0')
            return true;
    }
    return false;
}

bool IsAttachedOrOwned(int entity)
{
    if (!HasEntProp(entity, Prop_Data, "m_hOwnerEntity")
        || GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity") != -1)
        return true;
    if (HasEntProp(entity, Prop_Send, "m_hOwner")
        && GetEntPropEnt(entity, Prop_Send, "m_hOwner") != -1)
        return true;
    // m_pParent is used by Anne's item hint; other aliases cover engine datamaps.
    static const char parents[][] = {"m_pParent", "m_hMoveParent", "m_hParent"};
    bool inspectedParent = false;
    for (int i = 0; i < sizeof(parents); i++)
    {
        if (HasEntProp(entity, Prop_Data, parents[i]))
        {
            inspectedParent = true;
            if (GetEntPropEnt(entity, Prop_Data, parents[i]) != -1)
                return true;
        }
    }
    if (!inspectedParent)
        return true;
    static const char children[][] = {"m_pChild", "m_hMoveChild"};
    for (int i = 0; i < sizeof(children); i++)
        if (HasEntProp(entity, Prop_Data, children[i])
            && GetEntPropEnt(entity, Prop_Data, children[i]) != -1)
            return true;
    return false;
}

bool IsFarFromPlayers(int entity)
{
    if (!HasEntProp(entity, Prop_Data, "m_vecAbsOrigin"))
        return false;
    float origin[3], player[3];
    GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", origin);
    float distance = g_Distance.FloatValue;
    int protectedPlayers = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;
        int team = GetClientTeam(client);
        if (team != 2 && (team != 3 || IsFakeClient(client)))
            continue;
        // Include dead/incapacitated survivors; their equipment may still be recovered.
        protectedPlayers++;
        GetClientAbsOrigin(client, player);
        if (GetVectorDistance(origin, player, true) <= distance * distance)
            return false;
    }
    return protectedPlayers > 0;
}

bool IsEligible(int entity, float now)
{
    if (!IsNetworkEntity(entity) || EntRefToEntIndex(g_Refs[entity]) != entity)
        return false;
    CleanupKind kind = g_Kinds[entity];
    if (kind == Cleanup_None)
        return false;
    float minAge = kind == Cleanup_DroppedWeapon ? g_DropAge.FloatValue : g_Age.FloatValue;
    if (now - g_Since[entity] < minAge || HasProtectedIdentity(entity, kind) || IsAttachedOrOwned(entity))
        return false;
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    if (kind == Cleanup_ItemBeam && !StrEqual(classname, "beam_spotlight"))
        return false;
    if (kind == Cleanup_DroppedWeapon && !IsOrdinaryWeapon(classname))
        return false;
    if (kind == Cleanup_DeadCommon)
    {
        if (!StrEqual(classname, "infected") || !HasEntProp(entity, Prop_Data, "m_lifeState")
            || !HasEntProp(entity, Prop_Data, "m_iHealth")
            || GetEntProp(entity, Prop_Data, "m_lifeState") < 2
            || GetEntProp(entity, Prop_Data, "m_iHealth") > 0)
            return false;
    }
    return IsFarFromPlayers(entity);
}

int CountUsedEdicts()
{
    int count = 0;
    for (int entity = 0; entity < GetMaxEntities(); entity++)
        if (IsValidEdict(entity))
            count++;
    return count;
}

int CleanupBatch(int budget)
{
    int refs[MAX_BATCH], count = 0;
    float now = GetGameTime();
    if (budget <= 0 || g_QueuedCount > 0 || now < g_NextCleanup)
        return 0;
    if (budget > MAX_BATCH)
        budget = MAX_BATCH;
    // Reclaim decorative beams before equipment; never expand the allowlist under pressure.
    for (int pass = 0; pass < 3 && count < budget; pass++)
    {
        CleanupKind kind = pass == 0 ? Cleanup_ItemBeam : (pass == 1 ? Cleanup_DeadCommon : Cleanup_DroppedWeapon);
        for (int entity = MaxClients + 1; entity < GetMaxEntities() && count < budget; entity++)
            if (g_Kinds[entity] == kind && IsEligible(entity, now))
                refs[count++] = g_Refs[entity];
    }
    for (int i = 0; i < count; i++)
    {
        int entity = EntRefToEntIndex(refs[i]);
        // Other plugins' destruction callbacks may have invalidated a later candidate.
        if (!IsNetworkEntity(entity) || !IsEligible(entity, now))
            continue;
        char classname[64];
        GetEntityClassname(entity, classname, sizeof(classname));
        LogToFileEx(g_LogPath, "queue ref=%d class=%s kind=%d age=%.1f", refs[i], classname, g_Kinds[entity], now - g_Since[entity]);
        g_QueuedRefs[g_QueuedCount++] = refs[i];
        ForgetEntity(entity);
        RemoveEntity(entity);
    }
    if (g_QueuedCount > 0)
        g_NextCleanup = now + 2.0;
    return g_QueuedCount;
}

void VerifyPreviousBatch(int used)
{
    if (g_QueuedCount == 0)
        return;
    int gone = 0;
    for (int i = 0; i < g_QueuedCount; i++)
        if (EntRefToEntIndex(g_QueuedRefs[i]) == INVALID_ENT_REFERENCE)
            gone++;
    LogToFileEx(g_LogPath, "verify requested=%d refs_gone=%d used_before=%d used_now=%d engine_now=%d (counts may include new entities)",
        g_QueuedCount, gone, g_BeforeUsed, used, GetEntityCount());
    g_QueuedCount = 0;
}

Action Timer_Check(Handle timer)
{
    if (!g_MapRunning)
        return Plugin_Continue;
    RefreshCandidates();
    int used = CountUsedEdicts();
    VerifyPreviousBatch(used);
    // Count occupied edict slots explicitly. Keep the engine-reported value in
    // diagnostics only; it must not cause deletion if it acts as a high-water mark.
    int pressure = used;
    float now = GetGameTime();
    int target = g_Target.IntValue;
    if (target >= g_Threshold.IntValue)
        target = g_Threshold.IntValue - 1;
    if (!g_Enable.BoolValue || pressure <= target)
        g_Cleaning = false;
    else if (pressure >= g_Threshold.IntValue)
        g_Cleaning = true;
    if (g_Baseline || ((g_Cleaning || pressure >= g_Threshold.IntValue) && now >= g_NextReport))
    {
        WriteSnapshot(-1);
        g_Baseline = false;
        g_NextReport = now + 60.0;
    }
    if (g_Cleaning)
    {
        int budget = pressure - target;
        if (budget > g_Batch.IntValue)
            budget = g_Batch.IntValue;
        g_BeforeUsed = used;
        CleanupBatch(budget);
    }
    return Plugin_Continue;
}

public Action Command_Stats(int client, int args)
{
    if (g_MapRunning)
    {
        RefreshCandidates();
        WriteSnapshot(client);
    }
    return Plugin_Handled;
}

public Action Command_Clean(int client, int args)
{
    if (!g_MapRunning || !g_Enable.BoolValue)
    {
        ConsoleLine(client, "[AnneCleaner] Disabled or no active map.");
        return Plugin_Handled;
    }
    // Do not let repeated console calls exceed the two-second deletion budget.
    if (g_QueuedCount > 0 || GetGameTime() < g_NextCleanup)
    {
        ConsoleLine(client, "[AnneCleaner] Waiting for batch verification and the two-second cleanup window.");
        return Plugin_Handled;
    }
    RefreshCandidates();
    g_BeforeUsed = CountUsedEdicts();
    int queued = CleanupBatch(g_Batch.IntValue);
    ConsoleLine(client, "[AnneCleaner] Queued %d safe candidates; release is checked on the next scan.", queued);
    WriteSnapshot(client);
    return Plugin_Handled;
}

void WriteSnapshot(int client)
{
    StringMap counts = new StringMap();
    char classname[64], map[128];
    int eligible = 0, tracked = 0;
    float now = GetGameTime();
    for (int entity = MaxClients + 1; entity < GetMaxEntities(); entity++)
    {
        if (!IsNetworkEntity(entity))
            continue;
        GetEntityClassname(entity, classname, sizeof(classname));
        int count = 0;
        counts.GetValue(classname, count);
        counts.SetValue(classname, count + 1);
        if (g_Kinds[entity] != Cleanup_None)
            tracked++;
        if (IsEligible(entity, now))
            eligible++;
    }
    GetCurrentMap(map, sizeof(map));
    int used = CountUsedEdicts();
    char line[256];
    FormatEx(line, sizeof(line), "[AnneCleaner] map=%s used=%d/%d engine=%d tracked=%d eligible=%d enabled=%d",
        map, used, GetMaxEntities(), GetEntityCount(), tracked, eligible, g_Enable.BoolValue);
    SnapshotLine(client, line);
    StringMapSnapshot snapshot = counts.Snapshot();
    for (int rank = 0; rank < 20; rank++)
    {
        int largest = 0;
        char largestClass[64];
        for (int i = 0; i < snapshot.Length; i++)
        {
            snapshot.GetKey(i, classname, sizeof(classname));
            int count;
            counts.GetValue(classname, count);
            if (count > largest)
            {
                largest = count;
                strcopy(largestClass, sizeof(largestClass), classname);
            }
        }
        if (largest == 0)
            break;
        FormatEx(line, sizeof(line), "  class=%s edicts=%d", largestClass, largest);
        SnapshotLine(client, line);
        counts.SetValue(largestClass, 0);
    }
    delete snapshot;
    delete counts;
}

void SnapshotLine(int client, const char[] line)
{
    LogToFileEx(g_LogPath, "%s", line);
    if (client >= 0)
        ConsoleLine(client, "%s", line);
}

// Administrator diagnostics stay in the console, never player chat.
void ConsoleLine(int client, const char[] format, any ...)
{
    char buffer[512];
    VFormat(buffer, sizeof(buffer), format, 3);
    if (client > 0 && IsClientInGame(client))
        PrintToConsole(client, "%s", buffer);
    else
        PrintToServer("%s", buffer);
}
