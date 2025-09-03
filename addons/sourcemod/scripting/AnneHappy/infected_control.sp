#pragma semicolon 1
#pragma newdecls required

/**
 * Infected Control (fdxx-style NavArea spot picking + max-distance fallback)
 * ------------------------------------------------------------------------
 * - 主找点（唯一）：遍历全局 TerrorNavArea，调用 SDK FindRandomSpot
 *   - 距离窗口 / Flow 窗口（以 searchRange 为尺度）
 *   - 不可见、可达（NavAreaBuildPath）、Hull 不卡
 *   - 需要时（TP/追跑者+杀手类）约束在“前方”
 *   - 多样性/梯子：轻量“跳过”式过滤（Pass1 严格，Pass2 放宽）
 * - 兜底（仅当扩圈达到最大距离时触发）：
 *   - 用 L4D_GetRandomPZSpawnPosition 采样一批点
 *   - 以“与最近生还者的距离最接近 SpawnMax 且不超过 SpawnMax”为目标进行选择
 *   - 仍需：不可见 + 可达 + SnapToGround
 * - 保留：队列/传送/反诱饵/梯子缓存/波节奏/上限/延迟等主逻辑
 *
 * Compatible with SourceMod 1.10+ + L4D2 + left4dhooks
 * Authors: Caibiii, 夜羽真白, 东, Paimon-Kawaii, fdxx (思路), merge & cleanup by ChatGPT
 */

#include <sourcemod>
#include <sdktools>
#include <sdktools_tempents>
#include <left4dhooks>
#include <sourcescramble>
#undef REQUIRE_PLUGIN
#include <si_target_limit>
#include <pause>
#include <ai_smoker_new>

// =========================
// 常量/宏
// =========================
#define CVAR_FLAG                 FCVAR_NOTIFY
#define TEAM_SURVIVOR             2
#define TEAM_INFECTED             3
#define NAV_MESH_HEIGHT           20.0
#define PLAYER_CHEST              45.0

#define BAIT_DISTANCE             200.0
#define LADDER_DETECT_DIST        500.0
#define RING_SLACK                300.0
#define NOSCORE_RADIUS            1000.0
#define SUPPORT_EXPAND_MAX        1200.0
#define EARLY_ACCEPT_AFTER        1
#define EARLY_ACCEPT_SAFE_SLACK   100.0

// 扩圈节奏
#define LOW_SCORE_EXPAND          50.0

#define ENABLE_SMOKER             (1 << 0)
#define ENABLE_BOOMER             (1 << 1)
#define ENABLE_HUNTER             (1 << 2)
#define ENABLE_SPITTER            (1 << 3)
#define ENABLE_JOCKEY             (1 << 4)
#define ENABLE_CHARGER            (1 << 5)

#define SPIT_INTERVAL             2.0
#define RUSH_MAN_DISTANCE         1200.0

#define FRAME_THINK_STEP          0.02

// Support SI gating
#define SUPPORT_SPAWN_DELAY_SECS  1.8
#define SUPPORT_NEED_KILLERS      1

// ---- Global Diversity（轻量过滤版） ----
#define DIVERSITY_HISTORY_GLOBAL        12
#define DIVERSITY_NEAR_RADIUS           250.0
#define DIVERSITY_AREA_SKIP_PASS1       1
#define DIVERSITY_RELAX_AFTER_FAILS     8

// ---- Ladder（轻量过滤版）----
#define LADDER_PROX_RADIUS              300.0
#define LADDER_PROX_NEAR                100.0
#define LADDER_MASK_OFFS1               100.0
#define LADDER_MASK_OFFS2               100.0
#define LADDER_NAVMASK_RADIUS           100.0

static const char INFDN[10][] =
{
    "common","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};

// -----------------------
// SDK / Gamedata offsets
// -----------------------
static Handle g_hSDKFindRandomSpot = null;   // TerrorNavArea::FindRandomSpot
static Address g_pTheNavAreas = Address_Null;

static int g_iSpawnAttributesOffset = -1;
static int g_iFlowDistanceOffset = -1;
static int g_iNavCountOffset = -1;

// TheNavAreas / NavArea methodmap（参考 fdxx）
methodmap TheNavAreas
{
    public int Count()
    {
        return LoadFromAddress(view_as<Address>(this) + view_as<Address>(g_iNavCountOffset), NumberType_Int32);
    }
    public Address Dereference()
    {
        return LoadFromAddress(view_as<Address>(this), NumberType_Int32);
    }
    public Address GetAreaRaw(int i, bool bDereference = true)
    {
        if (!bDereference)
            return LoadFromAddress(view_as<Address>(this) + view_as<Address>(i*4), NumberType_Int32);
        return LoadFromAddress(this.Dereference() + view_as<Address>(i*4), NumberType_Int32);
    }
}

methodmap NavArea
{
    public bool IsNull()
    {
        return view_as<Address>(this) == Address_Null;
    }

    public void GetRandomPoint(float outPos[3])
    {
        SDKCall(g_hSDKFindRandomSpot, this, outPos);
    }

    property int SpawnAttributes
    {
        public get()
        {
            return LoadFromAddress(view_as<Address>(this) + view_as<Address>(g_iSpawnAttributesOffset), NumberType_Int32);
        }
        public set(int v)
        {
            StoreToAddress(view_as<Address>(this) + view_as<Address>(g_iSpawnAttributesOffset), v, NumberType_Int32);
        }
    }

    public float GetFlow()
    {
        return LoadFromAddress(view_as<Address>(this) + view_as<Address>(g_iFlowDistanceOffset), NumberType_Int32);
    }
}

// Nav flags（参考 wiki）
enum
{
    EMPTY = 2,
    STOP_SCAN = 4,
    BATTLESTATION = 32,
    FINALE = 64,
    PLAYER_START = 128,
    BATTLEFIELD = 256,
    IGNORE_VISIBILITY = 512,
    NOT_CLEARABLE = 1024,
    CHECKPOINT = 2048,
    OBSCURED = 4096,
    NO_MOBS = 8192,
    THREAT = 16384,
    RESCUE_VEHICLE = 32768,
    RESCUE_CLOSET = 65536,
    ESCAPE_ROUTE = 131072,
    DOOR_OR_DESTROYED_DOOR = 262144,
    NOTHREAT = 524288,
    LYINGDOWN = 1048576,
    COMPASS_NORTH = 16777216,
    COMPASS_NORTHEAST = 33554432,
    COMPASS_EAST = 67108864,
    COMPASS_EASTSOUTH = 134217728,
    COMPASS_SOUTH = 268435456,
    COMPASS_SOUTHWEST = 536870912,
    COMPASS_WEST = 1073741824,
    COMPASS_WESTNORTH = -2147483648
}

// =========================
// 枚举/结构
// =========================
enum SIClass
{
    SI_None    = 0,
    SI_Smoker  = 1,
    SI_Boomer  = 2,
    SI_Hunter  = 3,
    SI_Spitter = 4,
    SI_Jockey  = 5,
    SI_Charger = 6
};

enum struct Config
{
    ConVar SpawnMin;
    ConVar SpawnMax;
    ConVar TeleportEnable;
    ConVar TeleportCheckTime;
    ConVar EnableMask;
    ConVar AllCharger;
    ConVar AllHunter;
    ConVar AntiBait;
    ConVar BaitFlow;
    ConVar AutoSpawnTime;
    ConVar IgnoreIncapSight;
    ConVar AddDmgSmoker;
    ConVar SiLimit;
    ConVar SiInterval;
    ConVar DebugMode;

    ConVar MaxPlayerZombies;
    ConVar VsBossFlowBuffer;

    float fSpawnMin;
    float fSpawnMax;
    float fSiInterval;
    float fBaitFlow;
    int   iSiLimit;
    int   iEnableMask;
    int   iTeleportCheckTime;
    int   iDebugMode;
    bool  bTeleport;
    bool  bAutoSpawn;
    bool  bIgnoreIncapSight;
    bool  bAddDmgSmoker;
    bool  bAntiBait;

    void Create()
    {
        this.SpawnMin          = CreateConVar("inf_SpawnDistanceMin", "250.0", "特感复活离生还者最近的距离限制", CVAR_FLAG, true, 0.0);
        this.SpawnMax          = CreateConVar("inf_SpawnDistanceMax", "1500.0", "特感复活离生还者最远的距离限制", CVAR_FLAG, true, this.SpawnMin.FloatValue);
        this.TeleportEnable    = CreateConVar("inf_TeleportSi", "1", "是否开启特感超时传送", CVAR_FLAG, true, 0.0);
        this.TeleportCheckTime = CreateConVar("inf_TeleportCheckTime", "5", "特感几秒后没被看到开始传送", CVAR_FLAG, true, 0.0);
        this.EnableMask        = CreateConVar("inf_EnableSIoption", "63", "启用生成的特感类型位掩码 (1~32)", CVAR_FLAG, true, 0.0, true, 63.0);
        this.AllCharger        = CreateConVar("inf_AllChargerMode", "0", "是否是全牛模式", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AllHunter         = CreateConVar("inf_AllHunterMode", "0", "是否是全猎人模式", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AntiBait          = CreateConVar("inf_AntiBaitMode", "0", "是否开启诱饵模式", CVAR_FLAG, true, 0.0, true, 1.0);
        this.BaitFlow          = CreateConVar("inf_BaitFlow", "3.0", "两波间平均推进不足该值判定为Bait (1-10)", CVAR_FLAG, true, 0.0, true, 10.0);
        this.AutoSpawnTime     = CreateConVar("inf_EnableAutoSpawnTime", "1", "是否开启自动增时", CVAR_FLAG, true, 0.0, true, 1.0);
        this.IgnoreIncapSight  = CreateConVar("inf_IgnoreIncappedSurvivorSight", "1", "传送检测是否忽略倒地/挂边视线", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AddDmgSmoker      = CreateConVar("inf_AddDamageToSmoker", "0", "单人时Smoker拉人对Smoker增伤5x", CVAR_FLAG, true, 0.0, true, 1.0);
        this.SiLimit           = CreateConVar("l4d_infected_limit", "6", "一次刷出多少特感", CVAR_FLAG, true, 0.0);
        this.SiInterval        = CreateConVar("versus_special_respawn_interval", "16.0", "对抗刷新间隔", CVAR_FLAG, true, 0.0);
        this.DebugMode         = CreateConVar("inf_DebugMode", "1","0=off, 1=logfile, 2=console+logfile, 3=console+logfile+beam", CVAR_FLAG, true, 0.0, true, 3.0);

        this.MaxPlayerZombies  = FindConVar("z_max_player_zombies");
        this.VsBossFlowBuffer  = FindConVar("versus_boss_buffer");

        SetConVarInt(FindConVar("director_no_specials"), 1);

        this.SpawnMax.AddChangeHook(OnCfgChanged);
        this.SpawnMin.AddChangeHook(OnCfgChanged);
        this.TeleportEnable.AddChangeHook(OnCfgChanged);
        this.TeleportCheckTime.AddChangeHook(OnCfgChanged);
        this.SiInterval.AddChangeHook(OnCfgChanged);
        this.IgnoreIncapSight.AddChangeHook(OnCfgChanged);
        this.EnableMask.AddChangeHook(OnCfgChanged);
        this.AllCharger.AddChangeHook(OnCfgChanged);
        this.AllHunter.AddChangeHook(OnCfgChanged);
        this.AntiBait.AddChangeHook(OnCfgChanged);
        this.AutoSpawnTime.AddChangeHook(OnCfgChanged);
        this.AddDmgSmoker.AddChangeHook(OnCfgChanged);
        this.SiLimit.AddChangeHook(OnSiLimitChanged);
        this.DebugMode.AddChangeHook(OnCfgChanged);

        this.Refresh();
        this.ApplyMaxZombieBound();
    }

    void Refresh()
    {
        this.fSpawnMax          = this.SpawnMax.FloatValue;
        this.fSpawnMin          = this.SpawnMin.FloatValue;
        this.bTeleport          = this.TeleportEnable.BoolValue;
        this.fSiInterval        = this.SiInterval.FloatValue;
        this.iSiLimit           = this.SiLimit.IntValue;
        this.iTeleportCheckTime = this.TeleportCheckTime.IntValue;
        this.iEnableMask        = this.EnableMask.IntValue;
        this.bAddDmgSmoker      = this.AddDmgSmoker.BoolValue;
        this.bAutoSpawn         = this.AutoSpawnTime.BoolValue;
        this.bIgnoreIncapSight  = this.IgnoreIncapSight.BoolValue;
        this.bAntiBait          = this.AntiBait.BoolValue;
        this.fBaitFlow          = this.BaitFlow.FloatValue;
        this.iDebugMode         = this.DebugMode.IntValue;
    }

    void ApplyMaxZombieBound()
    {
        SetConVarBounds(this.MaxPlayerZombies, ConVarBound_Upper, true, float(this.iSiLimit));
        this.MaxPlayerZombies.IntValue = this.iSiLimit;
    }
}

enum struct Queues
{
    ArrayList spawn;      // of int SIClass
    ArrayList teleport;   // of int SIClass

    void Create()
    {
        this.spawn    = new ArrayList();
        this.teleport = new ArrayList();
    }
    void Clear()
    {
        this.spawn.Clear();
        this.teleport.Clear();
    }
}

enum struct State
{
    Handle hCheck;
    Handle hSpawn;
    Handle hTeleport;

    bool   bLate;
    bool   bPickRushMan;
    bool   bShouldCheck;
    bool   bSmokerLib;
    bool   bPauseLib;
    bool   bTargetLimitLib;

    int    totalSI;
    int    siQueueCount;
    int    teleCount[MAXPLAYERS+1];
    int    siAlive[6];
    int    siCap[6];
    int    teleportQueueSize;
    int    spawnQueueSize;
    int    waveIndex;
    int    lastSpawnSecs;
    int    rushManIndex;
    int    targetSurvivor;

    int    survCount;
    int    survIdx[8];

    float  lastWaveStartTime;
    float  unpauseDelay;
    float  lastWaveAvgFlow;
    float  spawnDistCur;
    float  teleportDistCur;
    float  spitterSpitTime[MAXPLAYERS+1];

    int    baitCheckCount;
    int    ladderBaitCount;

    float  nextFrameThink;

    void Reset()
    {
        if (this.hTeleport != INVALID_HANDLE) { delete this.hTeleport; this.hTeleport = INVALID_HANDLE; }
        if (this.hCheck    != INVALID_HANDLE) { delete this.hCheck;    this.hCheck    = INVALID_HANDLE; }
        if (this.hSpawn    != INVALID_HANDLE) { KillTimer(this.hSpawn); this.hSpawn    = INVALID_HANDLE; }

        this.bPickRushMan = false;
        this.bShouldCheck = false;
        this.bLate        = false;

        this.siQueueCount = 0;
        this.lastWaveStartTime = 0.0;
        this.unpauseDelay      = 0.0;
        this.lastWaveAvgFlow   = 0.0;
        this.baitCheckCount    = 0;
        this.ladderBaitCount   = 0;
        this.totalSI           = 0;
        this.spawnQueueSize    = 0;
        this.teleportQueueSize = 0;
        this.waveIndex         = 0;
        this.rushManIndex      = -1;
        this.targetSurvivor    = -1;
        this.spawnDistCur      = 0.0;
        this.teleportDistCur   = 0.0;
        this.nextFrameThink    = 0.0;

        for (int i = 0; i <= MAXPLAYERS; i++)
        {
            this.spitterSpitTime[i] = 0.0;
            this.teleCount[i]       = 0;
        }
        for (int i = 0; i < 6; i++) this.siAlive[i] = 0;

        ResetGlobalDiversityHistory();
    }
}

enum struct LadderList 
{ 
    ArrayList arr; 
    void Create()
    { 
        this.arr = new ArrayList(3);
    } 
    void Clear()
    { 
        this.arr.Clear(); 
    } 
}
static LadderList gLadder;

// Diversity history
static float   g_LastPosGlobal[DIVERSITY_HISTORY_GLOBAL][3];
static Address g_LastAreaGlobal[DIVERSITY_HISTORY_GLOBAL];
static int     g_LastHeadGlobal;
static int     g_LastCountGlobal;

static void ResetGlobalDiversityHistory()
{
    g_LastHeadGlobal  = 0;
    g_LastCountGlobal = 0;
}
static void RecordSpawnPosGlobal(const float p[3], Address area)
{
    int head = g_LastHeadGlobal;
    g_LastPosGlobal[head][0] = p[0];
    g_LastPosGlobal[head][1] = p[1];
    g_LastPosGlobal[head][2] = p[2];
    g_LastAreaGlobal[head]   = area;
    g_LastHeadGlobal = (head + 1) % DIVERSITY_HISTORY_GLOBAL;
    if (g_LastCountGlobal < DIVERSITY_HISTORY_GLOBAL) g_LastCountGlobal++;
}

// =========================
// 全局
// =========================
public Plugin myinfo =
{
    name        = "Direct InfectedSpawn (fdxx-nav + maxdist-fallback)",
    author      = "Caibiii, 夜羽真白，东, Paimon-Kawaii, fdxx (inspiration), ChatGPT",
    description = "特感刷新控制 / 传送 / 反诱饵 / fdxx风格NavArea选点 + 最大距离兜底",
    version     = "2025.09.02-fdxxnav",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

static Config gCV;
static State  gST;
static Queues gQ;
static Handle g_hRushFwd = INVALID_HANDLE;

static char g_sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control_fdxxnav.txt";

// =========================
// 前置：事件 & 库
// =========================
public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
    RegPluginLibrary("infected_control"); // 保持你的库名
    g_hRushFwd = CreateGlobalForward("OnDetectRushman", ET_Ignore, Param_Cell);
    CreateNative("GetNextSpawnTime", Native_GetNextSpawnTime);
    return APLRes_Success;
}
any Native_GetNextSpawnTime(Handle plugin, int numParams)
{
    if (gST.hSpawn == INVALID_HANDLE)
        return gCV.fSiInterval;
    return gCV.fSiInterval - (GetGameTime() - gST.lastWaveStartTime);
}

public void OnAllPluginsLoaded()
{
    gST.bTargetLimitLib = LibraryExists("si_target_limit");
    gST.bSmokerLib      = LibraryExists("ai_smoker_new");
    gST.bPauseLib       = LibraryExists("pause");
}
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "si_target_limit")) gST.bTargetLimitLib = true;
    else if (StrEqual(name, "ai_smoker_new")) gST.bSmokerLib    = true;
    else if (StrEqual(name, "pause"))         gST.bPauseLib     = true;
}
public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "si_target_limit")) gST.bTargetLimitLib = false;
    else if (StrEqual(name, "ai_smoker_new")) gST.bSmokerLib    = false;
    else if (StrEqual(name, "pause"))         gST.bPauseLib     = false;
}

// =========================
// 插件生命周期
// =========================
public void OnPluginStart()
{
    gCV.Create();
    gQ.Create();
    gST.Reset();
    InitSDK_FromGamedata();   // ← 加载 NavArea SDK/偏移

    RegAdminCmd("sm_startspawn", Cmd_StartSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
    RegAdminCmd("sm_stopspawn",  Cmd_StopSpawn,  ADMFLAG_ROOT, "管理员停止刷特");

    HookEvent("finale_win",      evt_RoundEnd);
    HookEvent("mission_lost",    evt_RoundEnd);
    HookEvent("map_transition",  evt_RoundEnd);
    HookEvent("round_start",     evt_RoundStart);
    HookEvent("player_spawn",    evt_PlayerSpawn);
    HookEvent("player_death",    evt_PlayerDeath);
    HookEvent("ability_use",     evt_AbilityUse);
    HookEvent("player_hurt",     evt_PlayerHurt);
}

public void OnPluginEnd()
{
    if (gCV.AllCharger.BoolValue)
    {
        FindConVar("z_charger_health").RestoreDefault();
        FindConVar("z_charge_max_speed").RestoreDefault();
        FindConVar("z_charge_start_speed").RestoreDefault();
        FindConVar("z_charger_pound_dmg").RestoreDefault();
        FindConVar("z_charge_max_damage").RestoreDefault();
        FindConVar("z_charge_interval").RestoreDefault();
    }
    ConVar dir = FindConVar("director_no_specials");
    if (dir != null) dir.IntValue = 0;
}

// =========================
// 调试输出
// =========================
stock void Debug_Print(const char[] format, any ...)
{
    if (gCV.iDebugMode <= 0) return;
    char buf[512];
    VFormat(buf, sizeof buf, format, 2);
    LogToFile(g_sLogFile, "%s", buf);
    if (gCV.iDebugMode >= 2)
        PrintToConsoleAll("[IC] %s", buf);
}

// =========================
// 管理指令
// =========================
public Action Cmd_StartSpawn(int client, int args)
{
    if (L4D_HasAnySurvivorLeftSafeArea())
    {
        ResetMatchState();
        CreateTimer(0.1, Timer_SpawnFirstWave);
        ReadSiCap();
        PrintToChatAll("\x03 fdxx-NavArea找点 + 最大距离兜底 已启用 (v2025.09.02) ");
    }
    return Plugin_Handled;
}
public Action Cmd_StopSpawn(int client, int args)
{
    StopAll();
    return Plugin_Handled;
}

// =========================
// 回合流程
// =========================
public void evt_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
    CreateTimer(1.0,  Timer_ResetAtSaferoom, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(3.0,  Timer_InitLadders,     _, TIMER_FLAG_NO_MAPCHANGE);
}
public void evt_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    gLadder.Clear();
    StopAll();

    gST.ladderBaitCount = 0;
    gST.teleportDistCur = gCV.fSpawnMin;

    if (gQ.spawn.Length > 0) { gQ.spawn.Clear(); gST.spawnQueueSize = 0; }
    gST.spawnDistCur = gCV.fSpawnMin;
    gST.lastSpawnSecs = 0;
    ResetGlobalDiversityHistory();
}

static void StopAll()
{
    gQ.Clear();
    gST.Reset();
}
static Action Timer_ApplyMaxSpecials(Handle timer)
{
    gCV.ApplyMaxZombieBound();
    return Plugin_Continue;
}
static Action Timer_ResetAtSaferoom(Handle timer)
{
    ResetMatchState();
    return Plugin_Continue;
}
static Action Timer_SpawnFirstWave(Handle timer)
{
    if (!gST.bLate)
    {
        gST.bLate = true;
        gST.hCheck    = CreateTimer(1.0, Timer_CheckSpawnWindow, _, TIMER_REPEAT);
        StartWave();
        if (gCV.bTeleport)
            gST.hTeleport = CreateTimer(1.0, Timer_TeleportTick, _, TIMER_REPEAT);
    }
    return Plugin_Stop;
}

// =========================
// 事件
// =========================
public void evt_PlayerSpawn(Event event, const char[] name, bool dont_broadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsSpitter(client))
        gST.spitterSpitTime[client] = GetGameTime();
}
public void evt_AbilityUse(Event event, const char[] name, bool dont_broadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client || !IsClientInGame(client) || !IsFakeClient(client))
        return;
    char ability[16];
    event.GetString("ability", ability, sizeof ability);
    if (strcmp(ability, "ability_spit") == 0)
        gST.spitterSpitTime[client] = GetGameTime();
}
public void evt_PlayerHurt(Event event, const char[] name, bool dont_broadcast)
{
    if (!gCV.bAddDmgSmoker) return;
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int dmg      = GetEventInt(event, "dmg_health");
    int evHealth = GetEventInt(event, "health");
    if (IsValidSurvivor(attacker) && IsInfectedBot(victim) && GetEntProp(victim, Prop_Send, "m_zombieClass") == view_as<int>(SI_Smoker))
    {
        int bonus = 0;
        if (GetEntPropEnt(victim, Prop_Send, "m_tongueVictim") > 0)
            bonus = dmg * 5;
        int hp = evHealth - bonus;
        if (hp < 0) hp = 0;
        SetEntityHealth(victim, hp);
        SetEventInt(event, "health", hp);
    }
}
public void evt_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsInfectedBot(client)) return;

    int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zc != view_as<int>(SI_Spitter))
        CreateTimer(0.5, Timer_KickBot, client);

    if (zc >= 1 && zc <= 6)
    {
        int idx = zc - 1;
        if (gST.siAlive[idx] > 0) gST.siAlive[idx]--; else gST.siAlive[idx] = 0;
        if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
    }
    gST.teleCount[client] = 0;
}
static Action Timer_KickBot(Handle timer, int client)
{
    if (IsClientInGame(client) && !IsClientInKickQueue(client) && IsFakeClient(client))
    {
        KickClient(client, "SI teleport cleanup");
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

// =========================
// 波/时序
// =========================
static void StartWave()
{
    gST.survCount = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
            gST.survIdx[gST.survCount++] = i;

    gST.ladderBaitCount = 0;
    gST.teleportDistCur = gCV.fSpawnMin;
    gST.spawnDistCur    = gCV.fSpawnMin;
    gST.siQueueCount   += gCV.iSiLimit;

    gST.bShouldCheck = true;
    gST.waveIndex++;
    gST.lastWaveAvgFlow = GetSurAvrFlow();
    gST.lastSpawnSecs   = 0;
    gST.lastWaveStartTime = GetGameTime();

    if (gST.siQueueCount > gCV.iSiLimit)
        gST.siQueueCount = gCV.iSiLimit;

    ResetGlobalDiversityHistory();
    Debug_Print("Start wave %d", gST.waveIndex);
}
public void OnUnpause()
{
    if (gST.hSpawn == INVALID_HANDLE)
    {
        Debug_Print("Unpause -> next wave in %.2f sec", gST.unpauseDelay);
        gST.hSpawn = CreateTimer(gST.unpauseDelay, Timer_StartNewWave, _, TIMER_REPEAT);
    }
}
static Action Timer_StartNewWave(Handle timer)
{
    StartWave();
    gST.hSpawn = INVALID_HANDLE;
    gST.lastWaveStartTime = GetGameTime();
    return Plugin_Stop;
}

// =========================
// CVar / 上限
// =========================
static void OnCfgChanged(ConVar convar, const char[] ov, const char[] nv) { gCV.Refresh(); }
static void OnSiLimitChanged(ConVar convar, const char[] ov, const char[] nv)
{
    gCV.iSiLimit = gCV.SiLimit.IntValue;
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
}
static void ResetMatchState()
{
    gST.totalSI = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsInfectedBot(i) && IsPlayerAlive(i))
        {
            gST.teleCount[i] = 0;
            int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
            if (zc >= 1 && zc <= 6)
            {
                int idx = zc - 1;
                gST.siAlive[idx]++;
                gST.totalSI++;
            }
        }
        if (IsValidSurvivor(i) && !IsPlayerAlive(i))
            L4D_RespawnPlayer(i);
    }
}
static void ReadSiCap()
{
    gST.siCap[0] = GetConVarInt(FindConVar("z_smoker_limit"));
    gST.siCap[1] = GetConVarInt(FindConVar("z_boomer_limit"));
    gST.siCap[2] = GetConVarInt(FindConVar("z_hunter_limit"));
    gST.siCap[3] = GetConVarInt(FindConVar("z_spitter_limit"));
    gST.siCap[4] = GetConVarInt(FindConVar("z_jockey_limit"));
    gST.siCap[5] = GetConVarInt(FindConVar("z_charger_limit"));
    
    // 先扣“已在场”的职业
    for (int i = 0; i < 6; i++)
    {
        gST.siCap[i] -= gST.siAlive[i];
        if (gST.siCap[i] < 0) gST.siCap[i] = 0;
    }

    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        int t = gQ.spawn.Get(i);
        if (t >= 1 && t <= 6 && gST.siCap[t-1] > 0)
            gST.siCap[t-1]--;
    }
}

// =========================
// 帧驱动
// =========================
public void OnGameFrame()
{
    if (gCV.iSiLimit > gCV.MaxPlayerZombies.IntValue)
        gCV.ApplyMaxZombieBound();

    float now = GetGameTime();
    if (now < gST.nextFrameThink)
        return;
    gST.nextFrameThink = now + FRAME_THINK_STEP;

    if (gST.totalSI >= gCV.iSiLimit)
        return;

    MaintainSpawnQueueOnce();

    if (!gST.bLate)
        return;

    if (gST.teleportQueueSize > 0 && gST.totalSI < gCV.iSiLimit)
    {
        TryTeleportSpawnOnce();
        return;
    }

    if (gST.siQueueCount > 0 && gST.spawnQueueSize > 0 && gST.totalSI < gCV.iSiLimit)
    {
        TryNormalSpawnOnce();
    }
}

// -------------------------
// 队列维护
// -------------------------
static bool IsKillerClassInt(int zc)
{
    return  zc == view_as<int>(SI_Hunter) || zc == view_as<int>(SI_Jockey) || zc == view_as<int>(SI_Charger);
}
static int CountKillersAlive()
{
    return gST.siAlive[view_as<int>(SI_Smoker)-1]
         + gST.siAlive[view_as<int>(SI_Hunter)-1]
         + gST.siAlive[view_as<int>(SI_Jockey)-1]
         + gST.siAlive[view_as<int>(SI_Charger)-1];
}
static int CountKillersQueued()
{
    int c = 0;
    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        int t = gQ.spawn.Get(i);
        if (IsKillerClassInt(t)) c++;
    }
    return c;
}
static bool AnyEligibleKillerToQueue()
{
    static int ks[4] = { view_as<int>(SI_Smoker), view_as<int>(SI_Hunter), view_as<int>(SI_Jockey), view_as<int>(SI_Charger) };
    for (int i = 0; i < 4; i++)
    {
        int k = ks[i];
        if (CheckClassEnabled(k) && !HasReachedLimit(k) && MeetClassRequirement(k))
            return true;
    }
    return false;
}
static int PickEligibleKillerClass()
{
    static int ks[4] = { view_as<int>(SI_Smoker), view_as<int>(SI_Hunter), view_as<int>(SI_Jockey), view_as<int>(SI_Charger) };
    for (int s = 0; s < 6; s++)
    {
        int k = ks[GetRandomInt(0, 3)];
        if (CheckClassEnabled(k) && !HasReachedLimit(k) && MeetClassRequirement(k))
            return k;
    }
    return 0;
}
static void MaintainSpawnQueueOnce()
{
    if (gST.teleportQueueSize > 0) return;
    if (gST.spawnQueueSize >= gCV.iSiLimit) return;

    int zc = 0;
    if (gCV.AllCharger.BoolValue)      zc = view_as<int>(SI_Charger);
    else if (gCV.AllHunter.BoolValue)  zc = view_as<int>(SI_Hunter);
    else
    {
        float waveAge    = float(gST.lastSpawnSecs);
        int killersNow   = CountKillersAlive() + CountKillersQueued();
        bool preferKiller= (waveAge < SUPPORT_SPAWN_DELAY_SECS
                           && killersNow < SUPPORT_NEED_KILLERS
                           && AnyEligibleKillerToQueue());
        if (preferKiller) zc = PickEligibleKillerClass();

        if (zc == 0)
        {
            for (int tries = 0; tries < 6; tries++)
            {
                int pick = GetRandomInt(1, 6);
                if (MeetClassRequirement(pick) && !HasReachedLimit(pick))
                { zc = pick; break; }
            }
        }
    }

    if (zc != 0 && MeetClassRequirement(zc) && !HasReachedLimit(zc) && gST.spawnQueueSize < gCV.iSiLimit)
    {
        gQ.spawn.Push(zc);
        gST.siCap[zc - 1] -= 1;
        gST.spawnQueueSize++;
        Debug_Print("<SpawnQ> +%s size=%d", INFDN[zc], gST.spawnQueueSize);
    }
}

// ===========================
// 单次正常生成尝试（fdxx-NavArea 主路）
// ===========================
static void TryNormalSpawnOnce()
{
    static const float EPS_RADIUS = 1.0;

    int want = gQ.spawn.Get(0);
    bool isSupport = (want == view_as<int>(SI_Boomer) || want == view_as<int>(SI_Spitter));

    float pos[3];
    float ring = gST.spawnDistCur;

    float maxR = gCV.fSpawnMax;
    if (isSupport && SUPPORT_EXPAND_MAX < maxR)
        maxR = SUPPORT_EXPAND_MAX;

    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, false, pos);

    if (ok && IsPosVisibleSDK(pos, false)) { ok = false; }

    if (ok && DoSpawnAt(pos, want))
    {
        gST.siQueueCount--;
        gST.siAlive[want - 1]++; gST.totalSI++;
        gQ.spawn.Erase(0);        gST.spawnQueueSize--;

        BypassAndExecuteCommand("nb_assault");

        RecordSpawnPosGlobal(pos, L4D2Direct_GetTerrorNavArea(pos));

        float nextStart = ring * 0.5;
        if (nextStart < gCV.fSpawnMin) nextStart = gCV.fSpawnMin;
        if (nextStart > gCV.fSpawnMax) nextStart = gCV.fSpawnMax;
        gST.spawnDistCur = nextStart;

        Debug_Print("[SPAWN] success ring=%.1f -> nextStart=%.1f", ring, gST.spawnDistCur);
        return;
    }

    // 扩圈
    float nextR = gST.spawnDistCur + LOW_SCORE_EXPAND;
    if (nextR > maxR) nextR = maxR;
    gST.spawnDistCur = nextR;

    Debug_Print("[SPAWN] expand -> %.1f (max=%.1f) class=%s", gST.spawnDistCur, maxR, INFDN[want]);

    // —— 到达最大半径：触发“最大距离兜底” —— //
    if (gST.spawnDistCur + EPS_RADIUS >= maxR)
    {
        float pt[3];
        if (FallbackDirectorPosAtMax(want, gST.targetSurvivor, /*teleportMode=*/false, pt) && DoSpawnAt(pt, want))
        {
            gST.siQueueCount--;
            gST.siAlive[want - 1]++; gST.totalSI++;
            gQ.spawn.Erase(0);        gST.spawnQueueSize--;

            BypassAndExecuteCommand("nb_assault");

            RecordSpawnPosGlobal(pt, L4D2Direct_GetTerrorNavArea(pt));

            gST.spawnDistCur = gCV.fSpawnMin; // 兜底后回到最小半径
            Debug_Print("[SPAWN] fallback@max success, reset ring->min");
        }
    }
}

// ===========================
// 单次传送尝试（fdxx-NavArea 主路）
// ===========================
static void TryTeleportSpawnOnce()
{
    static const float EPS_RADIUS = 1.0;

    int want = gQ.teleport.Get(0);
    if (gST.totalSI >= gCV.iSiLimit || HasReachedLimit(want))
        return;

    float pos[3];
    float ring = gST.teleportDistCur;
    float maxR = gCV.fSpawnMax;

    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, true, pos);

    if (ok && IsPosVisibleSDK(pos, true)) { ok = false; }

    if (ok && DoSpawnAt(pos, want))
    {
        gST.siAlive[want - 1]++; gST.totalSI++;
        if (gST.siCap[want - 1] > 0) gST.siCap[want - 1]--;
        gQ.teleport.Erase(0);    gST.teleportQueueSize--;

        RecordSpawnPosGlobal(pos, L4D2Direct_GetTerrorNavArea(pos));

        float nextTP = ring * 0.7;
        if (nextTP < gCV.fSpawnMin) nextTP = gCV.fSpawnMin;
        if (nextTP > gCV.fSpawnMax) nextTP = gCV.fSpawnMax;
        gST.teleportDistCur = nextTP;

        if (gST.teleportQueueSize == 0)
            gST.teleportDistCur = gCV.fSpawnMin;

        Debug_Print("[TP] success ring=%.1f -> nextStart=%.1f", ring, gST.teleportDistCur);
        return;
    }

    // 扩圈
    float nextR = gST.teleportDistCur + LOW_SCORE_EXPAND;
    if (nextR > maxR) nextR = maxR;
    gST.teleportDistCur = nextR;

    Debug_Print("[TP] expand -> %.1f (max=%.1f) class=%s", gST.teleportDistCur, maxR, INFDN[want]);

    // —— 到达最大半径：触发“最大距离兜底” —— //
    if (gST.teleportDistCur + EPS_RADIUS >= maxR)
    {
        float pt[3];
        if (FallbackDirectorPosAtMax(want, gST.targetSurvivor, /*teleportMode=*/true, pt) && DoSpawnAt(pt, want))
        {
            gST.siAlive[want - 1]++; gST.totalSI++;
            gQ.teleport.Erase(0);    gST.teleportQueueSize--;

            RecordSpawnPosGlobal(pt, L4D2Direct_GetTerrorNavArea(pt));

            gST.teleportDistCur = FloatMax(gCV.fSpawnMin, gST.teleportDistCur * 0.7);
            Debug_Print("[TP] fallback@max success, ring now %.1f", gST.teleportDistCur);
        }
    }
}

// =========================
// Anti-bait 定时器 / 波时序
// =========================
static Action Timer_CheckSpawnWindow(Handle timer)
{
    if (gST.bPauseLib && IsInPause())
    {
        if (gST.hSpawn != INVALID_HANDLE)
        {
            gST.unpauseDelay = gCV.fSiInterval - (GetGameTime() - gST.lastWaveStartTime);
            KillTimer(gST.hSpawn);
            gST.hSpawn = INVALID_HANDLE;
        }
        return Plugin_Continue;
    }

    gST.lastSpawnSecs++;
    if (!gST.bLate) return Plugin_Stop;

    if (gCV.bAntiBait)
    {
        if (!gST.bShouldCheck && gST.lastSpawnSecs > RoundToFloor(gCV.fSiInterval / 2) + 2)
        {
            int baitRes = IsSurvivorBait();
            if (baitRes == 0 && gST.baitCheckCount != -10)
            {
                gST.baitCheckCount = (gST.baitCheckCount > 2) ? 2 : gST.baitCheckCount - 1;
                if (gST.baitCheckCount < -1) gST.baitCheckCount = -1;
            }
            else if (baitRes == 2)
            {
                gST.baitCheckCount++;
                if (gST.baitCheckCount > 3 && gST.hSpawn != INVALID_HANDLE)
                {
                    PauseSpawnTimer();
                }
                if (gST.baitCheckCount > 6 && gST.baitCheckCount <= 26)
                {
                    SpawnCommonInfect(2);
                }
            }

            if (gST.baitCheckCount == -1 && gST.hSpawn == INVALID_HANDLE)
            {
                UnpauseSpawnTimer(1.0);
                gST.baitCheckCount = -10;
            }
        }
    }

    if (!gST.bShouldCheck || gST.hSpawn != INVALID_HANDLE) return Plugin_Continue;

    if (FindConVar("survivor_limit").IntValue >= 2 && IsAnyTankOrAboveHalfSurvivorDownOrDied(1) && gST.lastSpawnSecs < RoundToFloor(gCV.fSiInterval / 2))
        return Plugin_Continue;

    if (!gCV.bAutoSpawn)
    {
        if (gST.siQueueCount == gCV.iSiLimit)
        {
            gST.lastSpawnSecs = 0;
        }
        else
        {
            gST.bShouldCheck = false;
            gST.hSpawn = CreateTimer(gCV.fSiInterval * 1.5, Timer_StartNewWave, _, TIMER_REPEAT);
        }
    }
    else if ((IsAllKillersDown() && gST.siQueueCount == 0) || (gST.totalSI <= (RoundToFloor(gCV.iSiLimit / 4.0) + 1) && gST.siQueueCount == 0) || (gST.lastSpawnSecs >= gCV.fSiInterval * 0.5))
    {
        if (gST.siQueueCount == gCV.iSiLimit)
        {
            gST.lastSpawnSecs = 0;
        }
        else
        {
            gST.bShouldCheck = false;
            gST.hSpawn = CreateTimer(gCV.fSiInterval, Timer_StartNewWave, _, TIMER_REPEAT);
        }
    }

    return Plugin_Continue;
}
static void PauseSpawnTimer()
{
    if (gST.hSpawn != INVALID_HANDLE)
    {
        gST.unpauseDelay = gCV.fSiInterval - (GetGameTime() - gST.lastWaveStartTime);
        KillTimer(gST.hSpawn);
        gST.hSpawn = INVALID_HANDLE;
        Debug_Print("Pause spawn timer, resume after %.2f", gST.unpauseDelay);
    }
}
static void UnpauseSpawnTimer(float delay)
{
    if (gST.hSpawn == INVALID_HANDLE)
    {
        gST.hSpawn = CreateTimer(delay, Timer_StartNewWave, _, TIMER_REPEAT);
        Debug_Print("Resume spawn in %.2f", delay);
    }
}

// =========================
// 传送监督（1s）
// =========================
static Action Timer_TeleportTick(Handle timer)
{
    if (gST.bPauseLib && IsInPause())
        return Plugin_Continue;

    if (CheckRushManAndAllPinned())
        return Plugin_Continue;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!CanBeTeleport(c)) continue;
        float eyes[3];
        GetClientEyePosition(c, eyes);
        if (!IsPosVisibleSDK(eyes, true))
        {
            if (gST.teleportQueueSize == 0)
                gST.teleportDistCur = gCV.fSpawnMin;

            if (gST.teleCount[c] > gCV.iTeleportCheckTime || (gST.bPickRushMan && gST.teleCount[c] > 0))
            {
                int zc = GetInfectedClass(c);
                if (zc >= 1 && zc <= 6)
                {
                    gQ.teleport.Push(zc);
                    gST.teleportQueueSize++;

                    if (gST.siAlive[zc-1] > 0) gST.siAlive[zc-1]--; else gST.siAlive[zc-1] = 0;
                    if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
                    // 传送是“同一只”重生：临时回补职业余量，避免被上限挡住
                    gST.siCap[zc-1]++;

                    KickClient(c, "Teleport SI");
                    gST.teleCount[c] = 0;
                    Debug_Print("<TeleportQ> +%s size=%d", INFDN[zc], gST.teleportQueueSize);
                }
            }
            gST.teleCount[c]++;
        }
        else
        {
            gST.teleCount[c] = 0;
        }
    }

    gST.targetSurvivor = ChooseTargetSurvivor();
    return Plugin_Continue;
}

// =========================
// 资格/可传送
// =========================
static bool IsInfectedBot(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client)
           && GetClientTeam(client) == TEAM_INFECTED && (GetEntProp(client, Prop_Send, "m_zombieClass") >= 1 && GetEntProp(client, Prop_Send, "m_zombieClass") <= 6);
}
static bool IsSpitter(int client)
{
    return IsInfectedBot(client) && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == view_as<int>(SI_Spitter);
}
static int GetInfectedClass(int client) { return GetEntProp(client, Prop_Send, "m_zombieClass"); }
static bool IsGhost(int client) { return IsValidClient(client) && view_as<bool>(GetEntProp(client, Prop_Send, "m_isGhost")); }

static bool IsAiSmoker(int c)
{
    return c && c <= MaxClients && IsClientInGame(c) && IsPlayerAlive(c) && IsFakeClient(c)
        && GetClientTeam(c) == TEAM_INFECTED && GetEntProp(c, Prop_Send, "m_zombieClass") == view_as<int>(SI_Smoker) && !IsGhost(c);
}
static bool IsAiTank(int c)
{
    return c && c <= MaxClients && IsClientInGame(c) && IsPlayerAlive(c) && IsFakeClient(c)
        && GetClientTeam(c) == TEAM_INFECTED && GetEntProp(c, Prop_Send, "m_zombieClass") == 8 && !IsGhost(c);
}
static bool IsPinned(int client)
{
    if (!(IsValidSurvivor(client) && IsPlayerAlive(client))) return false;
    return GetEntPropEnt(client, Prop_Send, "m_tongueOwner")   > 0
        || GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker")> 0
        || GetEntPropEnt(client, Prop_Send, "m_pounceAttacker")> 0
        || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker")> 0;
}
static bool IsPinningSomeone(int client)
{
    if (!IsInfectedBot(client)) return false;
    return GetEntPropEnt(client, Prop_Send, "m_tongueVictim") > 0
        || GetEntPropEnt(client, Prop_Send, "m_jockeyVictim") > 0
        || GetEntPropEnt(client, Prop_Send, "m_pounceVictim") > 0
        || GetEntPropEnt(client, Prop_Send, "m_pummelVictim") > 0
        || GetEntPropEnt(client, Prop_Send, "m_carryVictim")  > 0;
}
static bool CanBeTeleport(int client)
{
    if (!IsInfectedBot(client) || !IsClientInGame(client) || !IsPlayerAlive(client))
        return false;
    if (GetEntProp(client, Prop_Send, "m_zombieClass") == 8)
        return false;
    if (IsPinningSomeone(client))
        return false;

    if (IsSpitter(client) && (GetGameTime() - gST.spitterSpitTime[client]) < SPIT_INTERVAL)
        return false;

    if (GetClosestSurvivorDistance(client) < gCV.fSpawnMin)
        return false;

    if (IsAiSmoker(client) && gST.bSmokerLib && !IsSmokerCanUseAbility(client))
        return false;

    float p[3];
    GetClientAbsOrigin(client, p);
    if (IsPosAheadOfHighest(p))
        return false;

    return true;
}

// =========================
// 可视/落地/路径/几何
// =========================
static bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    float eyes[3], posEye[3];
    posEye = pos; posEye[2] += 62.0;

    int countTooFar = 0;
    int skipCount   = 0;
    int survTotal   = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;
        survTotal++;

        GetClientEyePosition(i, eyes);

        if (teleportMode && (IsClientIncapped(i) || (gST.bPickRushMan && IsPinned(i))))
        {
            if (!gCV.bIgnoreIncapSight)
            {
                int healthyNearby = 0; float tmp[3];
                for (int j = 1; j <= MaxClients; j++)
                {
                    if (j != i && IsValidSurvivor(j) && !IsClientIncapped(j))
                    {
                        GetClientAbsOrigin(j, tmp);
                        if (GetVectorDistance(tmp, eyes, true) < Pow(500.0, 2.0))
                            healthyNearby++;
                    }
                }
                if (healthyNearby == 0) { skipCount++; continue; }
            }
            else { skipCount++; continue; }
        }

        float d2 = GetVectorDistance(pos, eyes, true);
        int effective = (survTotal - skipCount);
        if (d2 >= Pow(gCV.fSpawnMax, 2.0))
        {
            countTooFar++;
            if (effective > 0 && countTooFar >= effective)
                return false;
        }

        if (L4D2_IsVisibleToPlayer(i, 2, 3, 0, pos))     return true;
        if (L4D2_IsVisibleToPlayer(i, 2, 3, 0, posEye))  return true;
    }
    return false;
}
static bool TraceFilter_Stuck(int ent, int mask)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return false;
    char cls[20];
    GetEntityClassname(ent, cls, sizeof cls);
    if (strcmp(cls, "env_physics_blocker") == 0)
    {
        int t = GetEntProp(ent, Prop_Data, "m_nBlockType");
        if (t == 1 || t == 2) return false;
    }
    return true;
}
static bool IsHullFreeAt(const float at[3])
{
    static const float mins[3] = { -16.0, -16.0, 0.0 };
    static const float maxs[3] = {  16.0,  16.0, 72.0 };
    Handle tr = TR_TraceHullFilterEx(at, at, mins, maxs, MASK_PLAYERSOLID, TraceFilter_Stuck);
    bool hit = TR_DidHit(tr);
    delete tr;
    return !hit;
}
static bool SnapToGroundAt(float p[3])
{
    float angDown[3] = {90.0, 0.0, 0.0};
    Handle tr = TR_TraceRayFilterEx(p, angDown, MASK_SHOT | CONTENTS_MONSTERCLIP | CONTENTS_GRATE, RayType_Infinite, TraceFilter_Stuck);
    if (!TR_DidHit(tr)) { delete tr; return false; }
    float endp[3]; TR_GetEndPosition(endp, tr); delete tr;
    p[2] = endp[2] + NAV_MESH_HEIGHT;
    return true;
}

// =========================
// 前方/Flow/层级判定
// =========================
static bool IsPosAheadOfHighest(float ref[3], int target = -1)
{
    Address navP = L4D2Direct_GetTerrorNavArea(ref);
    if (navP == Address_Null)
        navP = view_as<Address>(L4D_GetNearestNavArea(ref, 300.0, false, false, false, TEAM_INFECTED));

    int posFlow = Calculate_Flow(navP);

    if (target == -1) target = L4D_GetHighestFlowSurvivor();
    if (IsValidSurvivor(target))
    {
        float t[3]; GetClientAbsOrigin(target, t);
        Address navT = L4D2Direct_GetTerrorNavArea(t);
        if (navT == Address_Null)
            navT = view_as<Address>(L4D_GetNearestNavArea(t, 300.0, false, false, false, TEAM_INFECTED));
        int tFlow = Calculate_Flow(navT);
        return posFlow >= tFlow;
    }
    return false;
}

stock static int Calculate_Flow(Address area)
{
    float flow = L4D2Direct_GetTerrorNavAreaFlow(area) / L4D2Direct_GetMapMaxFlowDistance();
    float prox = flow + gCV.VsBossFlowBuffer.FloatValue / L4D2Direct_GetMapMaxFlowDistance();
    if (prox > 1.0) prox = 1.0;
    return RoundToNearest(prox * 100.0);
}
static bool IsOnValidMesh(float ref[3])
{
    Address area = L4D2Direct_GetTerrorNavArea(ref);
    return area != Address_Null && !((L4D_GetNavArea_SpawnAttributes(area) & CHECKPOINT));
}

// =========================
// 多样性/梯子（轻量过滤）
// =========================
static ArrayList gLadderNavMask = null; // 存 Address(int)
static void PushNavMaskUnique(Address area)
{
    if (area == Address_Null) return;
    if (gLadderNavMask == null) gLadderNavMask = new ArrayList();
    int a = view_as<int>(area);
    for (int i = 0; i < gLadderNavMask.Length; i++)
        if (gLadderNavMask.Get(i) == a) return;
    gLadderNavMask.Push(a);
}
static bool IsAreaMasked(Address area)
{
    if (area == Address_Null || gLadderNavMask == null) return false;
    int a = view_as<int>(area);
    for (int i = 0; i < gLadderNavMask.Length; i++)
        if (gLadderNavMask.Get(i) == a) return true;
    return false;
}
static void BuildLadderNavMask()
{
    if (gLadderNavMask == null) gLadderNavMask = new ArrayList();
    gLadderNavMask.Clear();
    if (gLadder.arr == null || gLadder.arr.Length == 0) return;

    float L[3], S[3];
    static const float OFFS[][3] =
    {
        { 0.0, 0.0, 0.0 },
        { LADDER_MASK_OFFS1, 0.0, 0.0 }, { -LADDER_MASK_OFFS1, 0.0, 0.0 },
        { 0.0, LADDER_MASK_OFFS1, 0.0 }, {  0.0,-LADDER_MASK_OFFS1, 0.0 },
        { LADDER_MASK_OFFS2, 0.0, 0.0 }, { -LADDER_MASK_OFFS2, 0.0, 0.0 },
        { 0.0, LADDER_MASK_OFFS2, 0.0 }, {  0.0,-LADDER_MASK_OFFS2, 0.0 },
    };

    for (int i = 0; i < gLadder.arr.Length; i++)
    {
        gLadder.arr.GetArray(i, L);
        for (int k = 0; k < sizeof(OFFS); k++)
        {
            S[0] = L[0] + OFFS[k][0];
            S[1] = L[1] + OFFS[k][1];
            S[2] = L[2] + OFFS[k][2];
            Address a = view_as<Address>(L4D_GetNearestNavArea(S, LADDER_NAVMASK_RADIUS, false, false, false, TEAM_INFECTED));
            PushNavMaskUnique(a);
        }
    }
}
static bool NearestLadder2D(const float p[3], float &dist2D)
{
    if (gLadder.arr == null || gLadder.arr.Length == 0) { dist2D = 999999.0; return false; }
    float best = 999999.0;
    float tmp[3], p2[3]; p2 = p; p2[2] = 0.0;

    for (int i = 0; i < gLadder.arr.Length; i++)
    {
        gLadder.arr.GetArray(i, tmp);
        float t2[3]; t2 = tmp; t2[2] = 0.0;
        float d = GetVectorDistance(p2, t2);
        if (d < best) best = d;
    }
    dist2D = best;
    return (best < 999999.0);
}
static bool DiversitySkipPass(Address area, const float p[3], bool relax)
{
    // 先用“跳过”替代罚分：Pass1 更严格，Pass2 放宽
    for (int i = 0; i < g_LastCountGlobal; i++)
    {
        float prev[3];
        prev[0]=g_LastPosGlobal[i][0]; prev[1]=g_LastPosGlobal[i][1]; prev[2]=g_LastPosGlobal[i][2];
        float d = GetVectorDistance(p, prev);
        if (!relax)
        {
            if (d < DIVERSITY_NEAR_RADIUS) return true;
            #if DIVERSITY_AREA_SKIP_PASS1
            if (area != Address_Null && g_LastAreaGlobal[i] == area) return true;
            #endif
        }
        else
        {
            if (d < DIVERSITY_NEAR_RADIUS*0.6) return true;
        }
    }
    return false;
}
static bool LadderSkipPass(Address area, const float p[3], bool relax)
{
    float d2d;
    bool prox = NearestLadder2D(p, d2d) && (d2d <= (relax ? LADDER_PROX_NEAR*0.6 : LADDER_PROX_RADIUS));
    bool masked = IsAreaMasked(area);
    if (!relax) return (prox || masked);
    return (d2d <= LADDER_PROX_NEAR*0.6);
}

// =========================
// 目标选择 & 追跑者
// =========================
static int ChooseTargetSurvivor()
{
    if (gST.bPickRushMan && IsValidSurvivor(gST.rushManIndex) && IsPlayerAlive(gST.rushManIndex) && !IsPinned(gST.rushManIndex))
        return gST.rushManIndex;

    int cand[8]; int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i) && (!IsPinned(i) && !IsClientIncapped(i)))
        {
            if (gST.bTargetLimitLib && IsClientReachLimit(i)) continue;
            cand[n++] = i; if (n >= 8) break;
        }
    }
    if (n > 0) return cand[GetRandomInt(0, n-1)];
    return L4D_GetHighestFlowSurvivor();
}
static bool CheckRushManAndAllPinned()
{
    bool old = gST.bPickRushMan;

    int surv[8]; int ns = 0; int pinned = 0;
    int infected[MAXPLAYERS]; int ni = 0;
    float sPos[8][3]; float iPos[MAXPLAYERS][3]; float tmp[3];

    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsValidSurvivor(c) && IsPlayerAlive(c))
        {
            if (IsPinned(c) || IsClientIncapped(c)) pinned++;
            GetClientAbsOrigin(c, tmp);
            if (ns < 8) { sPos[ns] = tmp; surv[ns++] = c; }
        }
        else if (IsInfectedBot(c) && IsPlayerAlive(c))
        {
            infected[ni] = c;
            GetClientAbsOrigin(c, tmp); iPos[ni++] = tmp;
        }
    }

    if (ns == 1) return false;

    int target = L4D_GetHighestFlowSurvivor();
    if (ns >= 1 && IsValidClient(target))
    {
        GetClientAbsOrigin(target, tmp);
        bool nearAnotherSurvivor = false;
        for (int i = 0; i < ns; i++)
        {
            if (IsPinned(target) || IsClientIncapped(target) || (surv[i] != target && GetVectorDistance(sPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0)))
            { nearAnotherSurvivor = true; break; }
        }

        if (!nearAnotherSurvivor || gST.totalSI < (gCV.iSiLimit / 2 + 1))
        {
            gST.bPickRushMan = false; gST.rushManIndex = -1;
            if (old != gST.bPickRushMan) FireRushmanForward(false);
            return pinned == ns;
        }
        else
        {
            for (int i = 0; i < ni; i++)
            {
                if (IsPinned(target) || IsClientIncapped(target) || (GetVectorDistance(iPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0) * 1.3))
                {
                    gST.bPickRushMan = false; gST.rushManIndex = -1;
                    if (old != gST.bPickRushMan) FireRushmanForward(false);
                    return pinned == ns;
                }
            }
        }

        gST.bPickRushMan = true;
        gST.rushManIndex = target;
        if (old != gST.bPickRushMan) FireRushmanForward(true);
    }
    return pinned == ns;
}
static void FireRushmanForward(bool active)
{
    Debug_Print("Runner state changed: %d", active);
    if (g_hRushFwd != INVALID_HANDLE)
    {
        Call_StartForward(g_hRushFwd);
        Call_PushCell(active ? 1 : 0);
        Call_Finish();
    }
}

// =========================
// Flow / 平均
// =========================
static bool IsAllKillersDown()
{
    int sum = gST.siAlive[view_as<int>(SI_Charger) - 1] + gST.siAlive[view_as<int>(SI_Hunter) - 1] + gST.siAlive[view_as<int>(SI_Jockey) - 1];
    return sum == 0;
}
static bool IsAnyTankOrAboveHalfSurvivorDownOrDied(int limit = 0)
{
    int down = 0; int survMax = FindConVar("survivor_limit").IntValue;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsAiTank(i)) return true;
        if (IsValidSurvivor(i) && (L4D_IsPlayerIncapacitated(i) || !IsPlayerAlive(i))) down++;
    }
    if (limit == 0)
        return down >= RoundToCeil(float(survMax) / 2.0);
    else
        return down >= limit;
}
static float GetSurAvrDistance()
{
    int ids[8]; int n = 0; float pos[8][3];
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i)) { ids[n] = i; GetClientAbsOrigin(i, pos[n]); n++; if (n >= 8) break; }
    if (n <= 1) return 0.0;
    float sum = 0.0; int pairs = 0;
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
        { sum += GetVectorDistance(pos[i], pos[j]); pairs++; }
    return (pairs > 0) ? (sum / float(pairs)) : 0.0;
}
static float GetSurAvrFlow()
{
    int n = 0; float sum = 0.0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i)) { sum += L4D2_GetVersusCompletionPlayer(i); n++; }
    return n > 0 ? (sum / float(n)) : 0.0;
}
static int IsSurvivorBait()
{
    if (IsAnyTankOrAboveHalfSurvivorDownOrDied(1))
    {
        gST.ladderBaitCount = 0;
        return 0;
    }
    float avgDist = GetSurAvrDistance();
    if (avgDist > (BAIT_DISTANCE + 80.0) || gST.totalSI >= (gCV.iSiLimit - 1))
    {
        if (gST.ladderBaitCount > 0) gST.ladderBaitCount--;
    }

    bool ladderNear = IsLadderAround(GetRandomSurvivor(), LADDER_DETECT_DIST);
    if (avgDist > 0.0 && avgDist <= BAIT_DISTANCE && gST.totalSI <= RoundToFloor(float(gCV.iSiLimit) / 3.0) && ladderNear)
        gST.ladderBaitCount++;

    float flow = GetSurAvrFlow();
    if (flow != 0.0 && flow - gST.lastWaveAvgFlow <= gCV.fBaitFlow && avgDist <= BAIT_DISTANCE && gST.totalSI <= RoundToFloor(float(gCV.iSiLimit) / 3.0) + 1)
        return 2;
    return 0;
}

// =========================
// 兜底（导演 at MaxDistance）
// =========================
static bool FallbackDirectorPosAtMax(int zc, int target, bool teleportMode, float outPos[3])
{
    // 在达到最大扩圈半径时触发。
    // 目标：minDistToAnySurvivor 尽量接近 SpawnMax 且 <= SpawnMax。
    const int kTries = 48;

    float bestPt[3];
    bool  have = false;
    float bestDelta = 999999.0;

    float spawnMax = gCV.fSpawnMax;
    float spawnMin = gCV.fSpawnMin;

    float tFeet[3]; GetClientAbsOrigin(target, tFeet);
    Address navTarget = L4D2Direct_GetTerrorNavArea(tFeet);
    if (navTarget == Address_Null)
        navTarget = view_as<Address>(L4D_GetNearestNavArea(tFeet, 300.0, false, false, false, TEAM_INFECTED));
    if (navTarget == Address_Null) return false;

    for (int i = 0; i < kTries; i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(target, zc, 7, pt))
            continue;

        float minD = GetMinDistToAnySurvivor(pt);
        if (minD < spawnMin || minD > spawnMax + 200.0) // 允许一点点超出用于可达校验
            continue;

        if (IsPosVisibleSDK(pt, teleportMode))
            continue;

        if (!IsHullFreeAt(pt))
            continue;

        Address navP = view_as<Address>(L4D_GetNearestNavArea(pt, 120.0, false, false, false, TEAM_INFECTED));
        if (navP == Address_Null) continue;

        float need = FloatMax(minD + 120.0, spawnMin + 120.0);
        if (!L4D2_NavAreaBuildPath(navTarget, navP, need, TEAM_INFECTED, false))
            continue;

        float p2[3]; p2 = pt;
        if (!SnapToGroundAt(p2)) continue;

        float delta = FloatAbs(spawnMax - minD);

        // 首选 <= spawnMax；若都不满足，则取 delta 最小
        bool prefer = (minD <= spawnMax);
        if (!have)
        {
            bestPt = p2; have = true; bestDelta = delta;
        }
        else
        {
            float bestMinD = GetMinDistToAnySurvivor(bestPt);
            bool bestPrefer = (bestMinD <= spawnMax);
            if ((prefer && !bestPrefer) || (prefer == bestPrefer && delta < bestDelta))
            {
                bestPt = p2; bestDelta = delta;
            }
        }
    }

    if (!have) return false;
    outPos[0]=bestPt[0]; outPos[1]=bestPt[1]; outPos[2]=bestPt[2];
    return true;
}
static float GetMinDistToAnySurvivor(const float p[3])
{
    float best = 999999.0;
    float s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d < best) best = d;
    }
    return best;
}

// =========================
// 主找点（fdxx NavArea + 轻量过滤）
// =========================
static bool FindSpawnPosViaNavArea(int zc, int targetSurvivor, float searchRange, bool teleportMode, float outPos[3])
{
    // SDK 未初始化则直接失败，交给外层扩圈或兜底
    if (g_hSDKFindRandomSpot == null || g_pTheNavAreas == Address_Null || g_iNavCountOffset < 0)
        return false;

    if (!IsValidSurvivor(targetSurvivor))
        targetSurvivor = L4D_GetHighestFlowSurvivor();
    if (!IsValidSurvivor(targetSurvivor))
        return false;

    bool mustAhead = teleportMode || (gST.bPickRushMan && IsKillerClassInt(zc));

    float tFeet[3]; GetClientAbsOrigin(targetSurvivor, tFeet);
    Address navTarget = L4D2Direct_GetTerrorNavArea(tFeet);
    if (navTarget == Address_Null)
        navTarget = view_as<Address>(L4D_GetNearestNavArea(tFeet, 300.0, false, false, false, TEAM_INFECTED));
    if (navTarget == Address_Null)
        return false;

    // 距离窗口（围绕 searchRange）
    float ringMin = FloatMax(gCV.fSpawnMin, searchRange - RING_SLACK);
    float ringMax = FloatMin(gCV.fSpawnMax, searchRange + RING_SLACK);

    // Flow 窗口（尺度随 searchRange 变化）
    int tFlow = Calculate_Flow(navTarget);
    int flowHalf = RoundToNearest( (searchRange / FloatMax(gCV.fSpawnMax, 1.0)) * 30.0 ) + 6;
    if (flowHalf < 8)  flowHalf = 8;
    if (flowHalf > 30) flowHalf = 30;
    int flowLo = tFlow - flowHalf;
    int flowHi = tFlow + flowHalf;
    if (flowLo < 0)  flowLo = 0;
    if (flowHi > 100) flowHi = 100;

    TheNavAreas areas = view_as<TheNavAreas>(g_pTheNavAreas);
    int count = areas.Count();
    if (count <= 0)
        return false;

    // 两趟：第一趟严格过滤（多样性+梯子），第二趟放宽
    int start = GetRandomInt(0, count - 1);
    for (int pass = 0; pass < 2; pass++)
    {
        bool relax = (pass == 1);

        for (int j = 0; j < count; j++)
        {
            int i = (start + j) % count;
            Address aRaw = areas.GetAreaRaw(i);
            NavArea area = view_as<NavArea>(aRaw);
            if (area.IsNull())
                continue;

            int attrs = L4D_GetNavArea_SpawnAttributes(aRaw);
            if ((attrs & (CHECKPOINT|PLAYER_START|RESCUE_VEHICLE|RESCUE_CLOSET|FINALE|STOP_SCAN|NO_MOBS)) != 0)
                continue;

            int aFlow = Calculate_Flow(aRaw);
            if (aFlow < flowLo || aFlow > flowHi)
                continue;

            // 需要前方约束（TP 或 追跑者+杀手类）
            if (mustAhead)
            {
                int highest = L4D_GetHighestFlowSurvivor();
                if (IsValidSurvivor(highest))
                {
                    float hp[3]; GetClientAbsOrigin(highest, hp);
                    Address na = L4D2Direct_GetTerrorNavArea(hp);
                    if (na == Address_Null)
                        na = view_as<Address>(L4D_GetNearestNavArea(hp, 300.0, false, false, false, TEAM_INFECTED));
                    int hFlow = (na != Address_Null) ? Calculate_Flow(na) : 0;
                    if (aFlow < hFlow)
                        continue;
                }
            }

            // 同一 NavArea 给两次随机点机会
            for (int tries = 0; tries < 2; tries++)
            {
                float p[3];
                area.GetRandomPoint(p);

                if (!IsOnValidMesh(p))
                    continue;

                // 多样性/梯子“跳过式”过滤
                if (DiversitySkipPass(aRaw, p, relax))
                    continue;
                if (LadderSkipPass(aRaw, p, relax))
                    continue;

                // 与任一生还者的最小距离必须落在窗口
                float minD = GetMinDistToAnySurvivor(p);
                if (minD < ringMin || minD > ringMax)
                    continue;

                // TP 模式和倒地/挂边视线放宽由 IsPosVisibleSDK 内部处理
                if (IsPosVisibleSDK(p, teleportMode))
                    continue;

                if (!IsHullFreeAt(p))
                    continue;

                // 可达校验
                Address navP = view_as<Address>(L4D_GetNearestNavArea(p, 120.0, false, false, false, TEAM_INFECTED));
                if (navP == Address_Null)
                    continue;

                float need = FloatMax(minD + 120.0, gCV.fSpawnMin + 120.0);
                if (!L4D2_NavAreaBuildPath(navTarget, navP, need, TEAM_INFECTED, false))
                    continue;

                // 落地微调
                float p2[3]; p2 = p;
                if (!SnapToGroundAt(p2))
                    continue;

                outPos[0] = p2[0];
                outPos[1] = p2[1];
                outPos[2] = p2[2];
                return true;
            }
        }
    }

    return false;
}

// =========================
// 其它工具 & 兼容性实现
// =========================
static bool DoSpawnAt(const float pos[3], int zc)
{
    float ang[3] = {0.0, 0.0, 0.0};

    // 预防：最终再做一次可视/落地
    float p[3]; p = pos;
    if (IsPosVisibleSDK(p, false)) return false;
    if (!IsHullFreeAt(p)) return false;
    if (!SnapToGroundAt(p)) return false;

    // 依赖 left4dhooks: L4D2_SpawnZombie(zclass, pos, ang) 返回实体 index 或 0
    int ent = L4D2_SpawnSpecial(zc, p, ang);
    if (ent > 0 && IsValidEntity(ent))
        return true;

    Debug_Print("Spawn failed at (%.0f %.0f %.0f) class=%s", p[0], p[1], p[2], INFDN[zc]);
    return false;
}

static void BypassAndExecuteCommand(const char[] cmd)
{
    ConVar cheats = FindConVar("sv_cheats");
    int old = cheats != null ? cheats.IntValue : 0;
    if (cheats != null && old == 0) cheats.IntValue = 1;
    ServerCommand("%s", cmd);
    if (cheats != null && old == 0) cheats.IntValue = 0;
}
static float GetClosestSurvivorDistance(int client)
{
    if (!IsValidClient(client)) return 999999.0;
    float me[3]; GetClientAbsOrigin(client, me);
    float best = 999999.0, s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(me, s);
        if (d < best) best = d;
    }
    return best;
}

static bool IsValidClient(int c)   { return c > 0 && c <= MaxClients && IsClientInGame(c); }
static bool IsValidSurvivor(int c) { return IsValidClient(c) && GetClientTeam(c) == TEAM_SURVIVOR; }

static bool CheckClassEnabled(int zc)
{
    // 位：1<<0 ~ 1<<5 对应 Smoker..Charger
    int bit = (zc - 1);
    if (bit < 0 || bit > 5) return false;
    return (gCV.iEnableMask & (1 << bit)) != 0;
}
static bool HasReachedLimit(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx > 5) return true;
    return (gST.siCap[idx] <= 0);
}
static bool MeetClassRequirement(int zc)
{
    // 这里保留扩展位（比如限制同屏辅助/追跑者节奏等）
    // 当前版本统一返回 true
    return CheckClassEnabled(zc);
}

// =========================
// 梯子采集 / 附近检查
// =========================
static bool IsLadderAround(int surv, float dist)
{
    if (!IsValidSurvivor(surv) || gLadder.arr == null || gLadder.arr.Length == 0)
        return false;
    float me[3]; GetClientAbsOrigin(surv, me);
    float me2[3]; me2 = me; me2[2] = 0.0;

    float L[3];
    for (int i = 0; i < gLadder.arr.Length; i++)
    {
        gLadder.arr.GetArray(i, L, 3);
        float l2[3]; l2 = L; l2[2] = 0.0;
        if (GetVectorDistance(me2, l2) <= dist)
            return true;
    }
    return false;
}

static Action Timer_InitLadders(Handle timer)
{
    if (gLadder.arr == null) gLadder.Create();
    gLadder.Clear();

    char cls[64]; float pos[3], ang[3], mins[3], maxs[3], center[3];

    for (int i = MaxClients + 1; i < GetEntityCount(); i++)
    {
        if (!IsValidEntity(i) || !IsValidEdict(i)) continue;
        GetEntityClassname(i, cls, sizeof cls);
        if (cls[0] != 'f') continue;
        if (strcmp(cls, "func_simpleladder") && strcmp(cls, "func_ladder")) continue;

        GetEntPropVector(i, Prop_Send, "m_vecOrigin", pos);
        GetEntPropVector(i, Prop_Send, "m_vecMins",   mins);
        GetEntPropVector(i, Prop_Send, "m_vecMaxs",   maxs);
        GetEntPropVector(i, Prop_Send, "m_angRotation", ang);
        Math_RotateVector(mins, ang, mins);
        Math_RotateVector(maxs, ang, maxs);
        center[0] = pos[0] + (mins[0] + maxs[0]) * 0.5;
        center[1] = pos[1] + (mins[1] + maxs[1]) * 0.5;
        center[2] = pos[2] + (mins[2] + maxs[2]) * 0.5;
        gLadder.arr.PushArray(center);
        if (gCV.iDebugMode >= 2)
            Debug_Print("[Ladder] #%d (%.1f,%.1f,%.1f)", i, center[0], center[1], center[2]);

    }

    BuildLadderNavMask();
    Debug_Print("Ladder markers cached: %d", (gLadder.arr != null) ? gLadder.arr.Length : 0);
    return Plugin_Stop;
}

// =========================
// SDK / Gamedata 初始化
// =========================
static void InitSDK_FromGamedata()
{
    Handle conf = LoadGameConfigFile("infected_control");
    if (conf == null)
    {
        Debug_Print("Gamedata not found: infected_control.txt");
        return;
    }

    // CTerrorNavArea::FindRandomSpot(this, out Vec)
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CTerrorNavArea::FindRandomSpot"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer); // float outPos[3]
        g_hSDKFindRandomSpot = EndPrepSDKCall();
    }

    g_pTheNavAreas           = GameConfGetAddress(conf, "TheNavAreas");
    g_iSpawnAttributesOffset = GameConfGetOffset(conf, "CTerrorNavArea::m_spawnAttributeFlags");
    g_iFlowDistanceOffset    = GameConfGetOffset(conf, "CTerrorNavArea::m_flow"); // 距离型 flow，Calculate_Flow 会归一化
    g_iNavCountOffset        = GameConfGetOffset(conf, "TheNavAreas::m_vecAreas.Count");

    CloseHandle(conf);

    Debug_Print("SDK init: FindRandomSpot=%d, TheNavAreas=%x, offs(attr=%d flow=%d cnt=%d)",
        g_hSDKFindRandomSpot != null, g_pTheNavAreas, g_iSpawnAttributesOffset, g_iFlowDistanceOffset, g_iNavCountOffset);
}

// =========================
// 杂项：普通尸潮（反诱饵）
// =========================
static void SpawnCommonInfect(int count)
{
    for (int i = 0; i < count; i++)
        BypassAndExecuteCommand("z_spawn_old common");
}

// =========================
// 其余小工具
// =========================
stock bool IsClientIncapped(int client)
{
    return IsValidSurvivor(client) && L4D_IsPlayerIncapacitated(client);
}
// --- Math helpers --- 
stock float FloatMax(float a, float b) { return (a > b) ? a : b; } 
stock float FloatMin(float a, float b) { return (a < b) ? a : b; }
static void Math_RotateVector(const float v[3], const float a[3], float r[3])
{
    float rad[3];
    rad[0] = DegToRad(a[2]);
    rad[1] = DegToRad(a[0]);
    rad[2] = DegToRad(a[1]);

    float cA = Cosine(rad[0]), sA = Sine(rad[0]);
    float cB = Cosine(rad[1]), sB = Sine(rad[1]);
    float cG = Cosine(rad[2]), sG = Sine(rad[2]);

    float x=v[0], y=v[1], z=v[2], nx, ny, nz;
    ny = cA*y - sA*z; nz = cA*z + sA*y; y=ny; z=nz;
    nx = cB*x + sB*z; nz = cB*z - sB*x; x=nx; z=nz;
    nx = cG*x - sG*y; ny = cG*y + sG*x; x=nx; y=ny;

    r[0]=x; r[1]=y; r[2]=z;
}