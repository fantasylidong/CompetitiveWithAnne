#pragma semicolon 1 
#pragma newdecls required

/**
 * Infected Control (Rework) + Nav Snap (no dynamic lanes)
 * -------------------------------------------------------
 * - 强化找位、低分扩圈直至 inf_SpawnDistanceMax、到顶后兜底随机
 * - 全局多样性、梯子诱饵抑制（Nav 黑名单 + 距离惩罚）
 * - 辅助型延后机制（优先进攻）
 * - 详细 Debug：候选点淘汰原因计数、最终评分构成、半径、NavID 等
 * - 去除 “动态路线(Lane)” 相关逻辑，仅保留前后均衡在评分中的“前方优先”(ScoreAheadness)
 *
 * Compatible with SourceMod 1.10+ + L4D2 + left4dhooks
 *
 * Authors: Caibiii, 夜羽真白, 东, Paimon-Kawaii, and rework by ChatGPT (no-lanes)
 */

//#define DEBUG 1      // ← 调试输出开关（1=输出；0=静默）

#include <sourcemod>
#include <sdktools>
#include <sdktools_tempents>
#include <left4dhooks>
#undef REQUIRE_PLUGIN
#include <si_target_limit>
#include <pause>
#include <ai_smoker_new>

// Nav Area Spawn Attribute
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

// ---------------------------------------------------------------------------
// Constants & Helpers
// ---------------------------------------------------------------------------

#define CVAR_FLAG              FCVAR_NOTIFY
#define TEAM_SURVIVOR          2
#define TEAM_INFECTED          3

#define NAV_MESH_HEIGHT        20.0
#define PLAYER_HEIGHT          72.0
#define PLAYER_CHEST           45.0
#define HIGHERPOS              300.0
#define HIGHERPOSADDDISTANCE   250.0
#define INCAPSURVIVORCHECKDIS  500.0
#define NORMALPOSMULT          1.4
#define BAIT_DISTANCE          200.0
#define LADDER_DETECT_DIST     500.0
#define RING_SLACK             300.0
#define ROOF_SEPARATION_PENALTY 180.0
#define ROOF_VDELTA_MIN         100.0
#define ROOF_HORIZ_MAX          650.0
#define NOSCORE_RADIUS          1000.0
#define SUPPORT_EXPAND_MAX      1200.0

// —— 低分阈值＆扩圈 ——
#define LOW_SCORE_THRESHOLD   -200.0
#define LOW_SCORE_EXPAND      20.0
#define LOW_SCORE_MAX_STEPS   75

#define ENABLE_SMOKER          (1 << 0)
#define ENABLE_BOOMER          (1 << 1)
#define ENABLE_HUNTER          (1 << 2)
#define ENABLE_SPITTER         (1 << 3)
#define ENABLE_JOCKEY          (1 << 4)
#define ENABLE_CHARGER         (1 << 5)

#define SPIT_INTERVAL          2.0
#define RUSH_MAN_DISTANCE      1200.0

#define FRAME_THINK_STEP       0.01
#define CANDIDATE_TRIES        16

// ---- Support SI gating at wave start ----
#define SUPPORT_SPAWN_DELAY_SECS  1.8
#define SUPPORT_NEED_KILLERS      1

// ---- Global diversity (shared by all SI) ----
#define DIVERSITY_HISTORY_GLOBAL        12
#define DIVERSITY_NEAR_RADIUS           250.0
#define DIVERSITY_NEAR_WEIGHT           0.75
#define DIVERSITY_MID_RADIUS            600.0
#define DIVERSITY_MID_WEIGHT            0.35
#define DIVERSITY_AREA_PENALTY_GLOBAL   60.0

// ---- Ladder bait: proximity + Nav mask ----
#define LADDER_PROX_RADIUS              300.0
#define LADDER_PROX_NEAR                100.0
#define LADDER_PROX_PENALTY_NEAR        200.0
#define LADDER_PROX_PENALTY_FAR         90.0

#define LADDER_NAVMASK_RADIUS        100.0
#define LADDER_MASK_OFFS1            100.0
#define LADDER_MASK_OFFS2            100.0
#define LADDER_NAVMASK_STRICT_ALWAYS 0
#define LADDER_MASK_SOFT_PENALTY     60.0

// 删除所有 LANE 相关常量/加分（完全去除动态路线）

static const char INFDN[10][] = {
    "common","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};

char g_sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control_rework.txt";

// ---------------------------------------------------------------------------
// Enum / Structs
// ---------------------------------------------------------------------------

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
    // ConVars
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

    // read-only pointers
    ConVar MaxPlayerZombies;
    ConVar VsBossFlowBuffer;

    // runtime cache
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
        this.DebugMode         = CreateConVar("inf_DebugMode", "1","0=off, 1=logfile, 2=console+logfile, 3= console + logfile + beam", CVAR_FLAG, true, 0.0, true, 3.0);

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
    // Timers
    Handle hCheck;
    Handle hSpawn;
    Handle hTeleport;

    // Flags
    bool   bLate;
    bool   bPickRushMan;
    bool   bShouldCheck;
    bool   bSmokerLib;
    bool   bPauseLib;
    bool   bTargetLimitLib;

    // Counters & data
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

    // Survivors cache
    int    survCount;
    int    survIdx[8];

    // Floats
    float  lastWaveStartTime;
    float  unpauseDelay;
    float  lastWaveAvgFlow;
    float  spawnDistCur;
    float  teleportDistCur;
    float  spitterSpitTime[MAXPLAYERS+1];

    // Anti-bait
    int    baitCheckCount;
    int    ladderBaitCount;

    // Think throttle
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
    void Create() { this.arr = new ArrayList(3); } 
    void Clear()  { this.arr.Clear(); } 
}
static LadderList gLadder;

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------

public Plugin myinfo =
{
    name        = "Direct InfectedSpawn (Rework, no-lanes)",
    author      = "Caibiii, 夜羽真白，东, Paimon-Kawaii + ChatGPT",
    description = "特感刷新控制 / 传送 / 反诱饵 / 每类特感找位策略 (重构，无动态路线)",
    version     = "2025.08.31-nolanes",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

static Config gCV;
static State  gST;
static Queues gQ;
static Handle g_hRushFwd = INVALID_HANDLE;

static void OnCfgChanged(ConVar convar, const char[] ov, const char[] nv) { gCV.Refresh(); }
static void OnSiLimitChanged(ConVar convar, const char[] ov, const char[] nv)
{
    gCV.iSiLimit = gCV.SiLimit.IntValue;
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
}

// ---------------------------------------------------------------------------
// Debug infra
// ---------------------------------------------------------------------------

stock void Debug_Print(const char[] format, any ...)
{
    if (gCV.iDebugMode <= 0) return;

    char buf[512];
    VFormat(buf, sizeof buf, format, 2);

    LogToFile(g_sLogFile, "%s", buf);
    if (gCV.iDebugMode >= 2)
        PrintToConsoleAll("[IC] %s", buf);
}

static bool IsKillerClassInt(int zc)
{
    return zc == view_as<int>(SI_Smoker) || zc == view_as<int>(SI_Hunter) || zc == view_as<int>(SI_Jockey) || zc == view_as<int>(SI_Charger);
}

static int AddrAsInt(Address a) { return view_as<int>(a); }

// —— 单次找位 Debug 结构 —— //
enum struct SpawnDebug
{
    int   zc;
    int   target;
    float radius;
    bool  ladderStrict;
    int   considered;
    int failVisible;
    int failMesh;
    int failHull;
    int failAhead;
    int failNear;
    int failRing;
    int failPath;
    int failMaskedStrict;
    int   lowExpands;
    float radiusFinal;
    float bestScore;
    float bestPos[3];
    float distToTarget;
    float ideal;
    float classScore;
    float divPenBest;
    float ladPenBest;
    float sepPenaltyBest;
    bool  maskedSoft;
    Address navBest;
    Address navTarget;
}
static SpawnDebug gDBG;

static void Debug_Reset(int zc, int target, float radius, Address navTarget, bool ladderStrict)
{
    gDBG.zc = zc; gDBG.target = target; gDBG.radius = radius;
    gDBG.ladderStrict = ladderStrict;
    gDBG.considered = 0;
    gDBG.failVisible = gDBG.failMesh = gDBG.failHull = gDBG.failAhead = 0;
    gDBG.failNear = gDBG.failRing = gDBG.failPath = gDBG.failMaskedStrict = 0;
    gDBG.bestScore = -1.0e9;
    gDBG.bestPos[0] = gDBG.bestPos[1] = gDBG.bestPos[2] = 0.0;
    gDBG.distToTarget = 0.0; gDBG.ideal = 0.0; gDBG.classScore = 0.0;
    gDBG.divPenBest = gDBG.ladPenBest = gDBG.sepPenaltyBest = 0.0;
    gDBG.maskedSoft = false;
    gDBG.navBest = Address_Null; gDBG.navTarget = navTarget;
    gDBG.lowExpands   = 0;
    gDBG.radiusFinal  = radius;
}

static void Debug_DumpSuccess(const char[] tag)
{
    if (gCV.iDebugMode <= 0) return;

    Debug_Print("[%s] SI=%s wave=%d target=%d radius=%.1f->%.1f expands=%d tries=%d",
        tag, INFDN[gDBG.zc], gST.waveIndex, gDBG.target, gDBG.radius, gDBG.radiusFinal, gDBG.lowExpands, gDBG.considered);
    Debug_Print("  pos=(%.1f %.1f %.1f) dist=%.1f score=%.1f  ideal=%.1f",
        gDBG.bestPos[0], gDBG.bestPos[1], gDBG.bestPos[2],
        gDBG.distToTarget, gDBG.bestScore, gDBG.ideal);
    Debug_Print("  class=%.1f, div=%.1f, ladder=%.1f, ceiling=%.1f, maskedSoft=%d",
        gDBG.classScore, gDBG.divPenBest, gDBG.ladPenBest, gDBG.sepPenaltyBest,
        gDBG.maskedSoft ? 1 : 0);
    Debug_Print("  ladderStrict=%d, navBest=0x%x, navTarget=0x%x",
        gDBG.ladderStrict ? 1 : 0, AddrAsInt(gDBG.navBest), AddrAsInt(gDBG.navTarget));
    Debug_Print("  rejects: vis=%d mesh=%d hull=%d ahead=%d near=%d ring=%d path=%d masked=%d",
        gDBG.failVisible, gDBG.failMesh, gDBG.failHull, gDBG.failAhead,
        gDBG.failNear, gDBG.failRing, gDBG.failPath, gDBG.failMaskedStrict);
}

static void Debug_DumpFail(const char[] tag)
{
    if (gCV.iDebugMode <= 0) return;

    Debug_Print("[%s-FAIL] SI=%s wave=%d target=%d radius=%.1f tries=%d ladderStrict=%d",
        tag, INFDN[gDBG.zc], gST.waveIndex, gDBG.target, gDBG.radius, gDBG.considered, gDBG.ladderStrict ? 1 : 0);
    Debug_Print("  rejects: vis=%d mesh=%d hull=%d ahead=%d near=%d ring=%d path=%d masked=%d",
        gDBG.failVisible, gDBG.failMesh, gDBG.failHull, gDBG.failAhead,
        gDBG.failNear, gDBG.failRing, gDBG.failPath, gDBG.failMaskedStrict);
}

// ---- Global diversity history (shared by all SI) ----
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
    if (g_LastCountGlobal < DIVERSITY_HISTORY_GLOBAL)
        g_LastCountGlobal++;
}

static float DiversityPenaltyGlobal(const float p[3], Address area)
{
    float pen = 0.0;

    for (int i = 0; i < g_LastCountGlobal; i++)
    {
        float prev[3];
        prev[0] = g_LastPosGlobal[i][0];
        prev[1] = g_LastPosGlobal[i][1];
        prev[2] = g_LastPosGlobal[i][2];

        float d = GetVectorDistance(p, prev);

        if (d < DIVERSITY_NEAR_RADIUS)
            pen -= (DIVERSITY_NEAR_RADIUS - d) * DIVERSITY_NEAR_WEIGHT;
        else if (d < DIVERSITY_MID_RADIUS)
            pen -= (DIVERSITY_MID_RADIUS - d) * DIVERSITY_MID_WEIGHT;

        if (area != Address_Null && g_LastAreaGlobal[i] == area)
            pen -= DIVERSITY_AREA_PENALTY_GLOBAL;
    }

    return pen;
}

// ---- Ladder Nav mask & proximity penalty ----
static ArrayList gLadderNavMask = null; // stores int(Address)

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
    static const float OFFS[][3] = {
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

static bool ShouldApplyLadderStrict()
{
    #if LADDER_NAVMASK_STRICT_ALWAYS
        return true;
    #else
        float avg = GetSurAvrDistance();
        if (avg > 0.0 && avg <= BAIT_DISTANCE + 30.0) return true; // 当前近身优先
        return (gST.ladderBaitCount > 0);
    #endif
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

static float LadderProximityPenalty(const float p[3])
{
    float d2d;
    if (!NearestLadder2D(p, d2d)) return 0.0;
    if (d2d >= LADDER_PROX_RADIUS) return 0.0;

    float t = 1.0 - (d2d / LADDER_PROX_RADIUS);
    float nearBoost = (d2d <= LADDER_PROX_NEAR) ? 1.0 : ((LADDER_PROX_RADIUS - d2d) / (LADDER_PROX_NEAR > 1.0 ? (LADDER_PROX_RADIUS - LADDER_PROX_NEAR) : LADDER_PROX_RADIUS));
    if (nearBoost < 0.0) nearBoost = 0.0;

    float base = LADDER_PROX_PENALTY_FAR + (LADDER_PROX_PENALTY_NEAR - LADDER_PROX_PENALTY_FAR) * nearBoost;
    return -(base * (0.6 + 0.4 * t));
}

// ---------------------------------------------------------------------------
// Plugin lifecycle
// ---------------------------------------------------------------------------

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
    RegPluginLibrary("infected_control");
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

public void OnPluginStart()
{
    gCV.Create();
    gQ.Create();
    gST.Reset();

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
}

// ---------------------------------------------------------------------------
// Admin commands
// ---------------------------------------------------------------------------

public Action Cmd_StartSpawn(int client, int args)
{
    if (L4D_HasAnySurvivorLeftSafeArea())
    {
        ResetMatchState();
        CreateTimer(0.1, Timer_SpawnFirstWave);
        ReadSiCap();
        TweakAllChargerOrHunter();
        PrintToChatAll("\x03 目前是测试版本v1.8-nolanes，刷特在版本更新期间可能会不断跟进版本，谢谢大家体谅");
    }
    return Plugin_Handled;
}

public Action Cmd_StopSpawn(int client, int args)
{
    StopAll();
    return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// Round lifecycle
// ---------------------------------------------------------------------------

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
    if (gLadderNavMask != null) gLadderNavMask.Clear();
    StopAll();

    // 波级复位
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

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Wave management
// ---------------------------------------------------------------------------

static void StartWave()
{
    gST.survCount = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
            gST.survIdx[gST.survCount++] = i;

    // 波级复位
    gST.ladderBaitCount = 0;
    gST.teleportDistCur = gCV.fSpawnMin;

    gST.spawnDistCur = gCV.fSpawnMin;
    gST.siQueueCount += gCV.iSiLimit;

    gST.bShouldCheck = true;
    gST.waveIndex++;
    gST.lastWaveAvgFlow = GetSurAvrFlow();
    gST.lastSpawnSecs = 0;
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

// ---------------------------------------------------------------------------
// ConVar helpers / Tweaks
// ---------------------------------------------------------------------------

static void TweakAllChargerOrHunter()
{
    if (gCV.AllCharger.BoolValue)
    {
        FindConVar("z_charger_health").SetFloat(500.0);
        FindConVar("z_charge_max_speed").SetFloat(750.0);
        FindConVar("z_charge_start_speed").SetFloat(350.0);
        FindConVar("z_charger_pound_dmg").SetFloat(10.0);
        FindConVar("z_charge_max_damage").SetFloat(6.0);
        FindConVar("z_charge_interval").SetFloat(2.0);
    }
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

    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        int t = gQ.spawn.Get(i);
        if (t >= 1 && t <= 6 && gST.siCap[t-1] > 0)
            gST.siCap[t-1]--;
    }
}

// ---------------------------------------------------------------------------
// OnGameFrame
// ---------------------------------------------------------------------------

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

public void OnGameFrame()
{
    if (gCV.iSiLimit > gCV.MaxPlayerZombies.IntValue)
        CreateTimer(0.1, Timer_ApplyMaxSpecials);

    float now = GetGameTime();
    if (now < gST.nextFrameThink)
        return;
    gST.nextFrameThink = now + FRAME_THINK_STEP;
    if(gST.totalSI == gCV.iSiLimit)
        return;

    if (gST.teleportQueueSize <= 0 && gST.spawnQueueSize < gCV.iSiLimit)
    {
        int zc = 0;
        if (gCV.AllCharger.BoolValue) zc = view_as<int>(SI_Charger);
        else if (gCV.AllHunter.BoolValue) zc = view_as<int>(SI_Hunter);
        else
        {
            float waveAge = float(gST.lastSpawnSecs);
            int killersNow = CountKillersAlive() + CountKillersQueued();
            bool preferKillerNow =
                (waveAge < SUPPORT_SPAWN_DELAY_SECS && killersNow < SUPPORT_NEED_KILLERS && AnyEligibleKillerToQueue());
            if (preferKillerNow) zc = PickEligibleKillerClass();
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
            gST.siCap[zc-1] -= 1;
            gST.spawnQueueSize++;
            Debug_Print("<SpawnQ> +%s size=%d", INFDN[zc], gST.spawnQueueSize);
        }
    }

    if (!gST.bLate)
        return;

    if (gST.totalSI < gCV.iSiLimit)
    {
        if (gST.teleportQueueSize > 0)
        {
            gST.targetSurvivor = ChooseTargetSurvivor();

            float pos[3];
            int want = gQ.teleport.Get(0);
            bool ok = FindSpawnPosForClass(want, gST.targetSurvivor, gST.teleportDistCur, true, pos);
            if (ok)
            {
                if (DoSpawnAt(pos, want))
                {
                    gST.siAlive[want-1]++; gST.totalSI++;
                    gQ.teleport.Erase(0);  gST.teleportQueueSize--;
                    RecordSpawnPosGlobal(pos, L4D2Direct_GetTerrorNavArea(pos));
                    Debug_DumpSuccess("TP");
                }
            }
            else if (gST.teleportQueueSize <= 0)
            {
                gQ.teleport.Clear();
                gST.teleportQueueSize = 0;
            }
        }

        if (gST.siQueueCount > 0 && gST.teleportQueueSize <= 0 && gST.spawnQueueSize > 0)
        {
            gST.targetSurvivor = ChooseTargetSurvivor();

            float pos2[3];
            int want2 = gQ.spawn.Get(0);

            bool isSupport = (want2 == view_as<int>(SI_Boomer) || want2 == view_as<int>(SI_Spitter));
            if (isSupport)
            {
                float waveAge = float(gST.lastSpawnSecs);
                int killersNow = CountKillersAlive() + CountKillersQueued();

                if (waveAge < SUPPORT_SPAWN_DELAY_SECS && killersNow < SUPPORT_NEED_KILLERS && AnyEligibleKillerToQueue())
                {
                    int repl = PickEligibleKillerClass();
                    if (repl != 0)
                    {
                        Debug_Print("[Gate] support %s -> replace with %s (killersNow=%d need=%d age=%.1f)",
                            INFDN[want2], INFDN[repl], killersNow, SUPPORT_NEED_KILLERS, waveAge);
                        gQ.spawn.Set(0, repl);
                        want2 = repl;
                    }
                    else
                    {
                        Debug_Print("[Gate] support %s moved to back (no eligible killer)", INFDN[want2]);
                        int front = gQ.spawn.Get(0);
                        gQ.spawn.Erase(0);
                        gQ.spawn.Push(front);
                        return;
                    }
                }
            }

            bool ok2 = FindSpawnPosForClass(want2, gST.targetSurvivor, gST.spawnDistCur, false, pos2);
            if (ok2 && DoSpawnAt(pos2, want2))
            {
                gST.siQueueCount--;
                gST.siAlive[want2-1]++; gST.totalSI++;
                gQ.spawn.Erase(0);      gST.spawnQueueSize--;

                BypassAndExecuteCommand("nb_assault");

                RecordSpawnPosGlobal(pos2, L4D2Direct_GetTerrorNavArea(pos2));

                gST.spawnDistCur = FloatMax(gCV.fSpawnMin, gST.spawnDistCur * 0.8);

                Debug_DumpSuccess("SPAWN");
            }
            else
            {
                if (HasReachedLimit(want2))
                    ReplaceFrontSpawnIfFull(want2);

                if (gST.spawnQueueSize <= 0)
                {
                    gQ.spawn.Clear();
                    gST.spawnQueueSize = 0;
                }
            }
        }
    }
}


static void ReplaceFrontSpawnIfFull(int fullType)
{
    if (gQ.spawn.Length > 1 && gST.spawnQueueSize > 0)
    {
        Debug_Print("%s cap reached -> pop front", INFDN[fullType]);
        gQ.spawn.Erase(0);
        gST.spawnQueueSize--;
    }
    else
    {
        for (int i = 1; i <= 6; i++)
        {
            if (CheckClassEnabled(i) && !HasReachedLimit(i))
            {
                gQ.spawn.Set(0, i);
                break;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Anti-bait supervisor (1s timer)
// ---------------------------------------------------------------------------

static Action Timer_CheckSpawnWindow(Handle timer)
{
    if (gST.bPauseLib && IsInPause())
    {
        Debug_Print("Paused – stop spawning");
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

// ---------------------------------------------------------------------------
// Teleport supervisor (1s)
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Eligibility / counts
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Visibility & Nav helpers
// ---------------------------------------------------------------------------

static bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    float eyes[3];
    float posEye[3];
    posEye = pos;
    posEye[2] += 62.0;

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
                        if (GetVectorDistance(tmp, eyes, true) < Pow(INCAPSURVIVORCHECKDIS, 2.0))
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

        if (L4D2_IsVisibleToPlayer(i, 2, 3, 0, pos))
            return true;
        if (L4D2_IsVisibleToPlayer(i, 2, 3, 0, posEye))
            return true;
    }
    return false;
}

stock void DebugBeam(const float start[3], const float end[3], bool clear)
{
    if (gCV.iDebugMode < 3) return;

    static int g_iBeamSprite = -1;
    if (g_iBeamSprite == -1)
    {
        g_iBeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
    }
    int col[4];
    if (clear) { col[0]=0; col[1]=255; col[2]=0; col[3]=255; }
    else       { col[0]=255; col[1]=0; col[2]=0; col[3]=255; }

    TE_SetupBeamPoints(start, end, g_iBeamSprite, 0, 0, 0, 0.15, 2.0, 2.0, 1, 0.0, col, 0);
    TE_SendToAll();
}

static int GroundMaskForRadius(float r)
{
    if (r <= 400.0)         return MASK_VISIBLE;
    else                    return MASK_VISIBLE | CONTENTS_GRATE;
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

static bool TraceFilter_Stuck(int ent, int mask)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return false;
    char cls[20];
    GetEntityClassname(ent, cls, sizeof cls);
    if (strcmp(cls, "env_physics_blocker") == 0 && !EnvBlockType(ent))
        return false;
    return true;
}

static bool TraceFilter_Ground(int ent, int mask)
{
    if (ent <= MaxClients || !IsValidEntity(ent))
        return false;

    char cls[32];
    GetEntityClassname(ent, cls, sizeof cls);

    if (StartsWith(cls, "prop_"))             return false;
    if (StartsWith(cls, "weapon_"))           return false;
    if (StartsWith(cls, "item_"))             return false;
    if (StartsWith(cls, "trigger_"))          return false;
    if (StartsWith(cls, "func_ladder"))       return false;

    if (strcmp(cls, "env_physics_blocker") == 0)
    {
        int t = GetEntProp(ent, Prop_Data, "m_nBlockType");
        if (t == 1 || t == 2) return false;
    }

    return true;
}

static bool EnvBlockType(int ent)
{
    int t = GetEntProp(ent, Prop_Data, "m_nBlockType");
    return !(t == 1 || t == 2);
}

// ---------------------------------------------------------------------------
// Per-SI spawn strategies (scoring based)
// ---------------------------------------------------------------------------

static float ScoreDistanceIdeal(float dist, float ideal) { return 1000.0 - FloatAbs(dist - ideal); }
static float ClampFloat(float v, float mn, float mx) { if (v < mn) return mn; if (v > mx) return mx; return v; }

static float ScoreHeightDelta(const float pos[3], int target)
{
    float t[3]; GetClientEyePosition(target, t);
    return (pos[2] - t[2]);
}

static float ScoreAheadness(float pos[3], int target)
{
    return IsPosAheadOfHighest(pos, target) ? 100.0 : -100.0;
}


static void SurvivorForward(int target, float out[3])
{
    float ang[3]; GetClientEyeAngles(target, ang);
    GetAngleVectors(ang, out, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(out, out);
}

static float ScoreSmoker(float pos[3], int target, float dist, float ideal)
{
    // 轻量：距离理想度 + 前方优先 + 高打低
    float score = ScoreDistanceIdeal(dist, ideal) + ScoreAheadness(pos, target);

    float dz = ClampFloat(ScoreHeightDelta(pos, target), 0.0, 320.0);
    score += dz * 0.80; // 高打低较稳

    // 与生还者朝向的点积（-1 背后，0 侧面，+1 正前）
    float fwd[3]; SurvivorForward(target, fwd);
    float t[3];   GetClientAbsOrigin(target, t);
    float to[3];  MakeVectorFromPoints(pos, t, to); NormalizeVector(to, to);
    float dot = GetVectorDotProduct(fwd, to);

    // 侧面优先，其次背后；用点积近似而非射线
    if (FloatAbs(dot) < 0.35)        score += 140.0;
    else if (dot < -0.25)            score += 80.0;

    // 过低位置略减分（易被掩体卡视角）
    if (dz < 24.0)                   score -= 30.0;

    return score;
}

static float ScoreBoomer(float pos[3], int target, float dist, float ideal)
{
    float score = ScoreDistanceIdeal(dist, ideal);

    // 略倾向后路（不在推进面上更安全接近）
    float aheadBias = IsPosAheadOfHighest(pos, target) ? 0.0 : 80.0;
    score += aheadBias;

    // 与朝向的点积：背后最佳，其次侧面
    float fwd[3]; SurvivorForward(target, fwd);
    float t[3];   GetClientAbsOrigin(target, t);
    float to[3];  MakeVectorFromPoints(pos, t, to); NormalizeVector(to, to);
    float dot = GetVectorDotProduct(fwd, to);
    if (dot < -0.20)                 score += 200.0;  // 背后
    else if (FloatAbs(dot) < 0.20)   score += 110.0;  // 侧面

    // 稍低位/等高更好
    float below = -ScoreHeightDelta(pos, target);
    score += ClampFloat(below, 0.0, 160.0) * 0.90;

    score += 25.0; // 轻微常数项
    return score;
}

static float ScoreHunter(float pos[3], int target, float dist, float ideal)
{
    float score = ScoreDistanceIdeal(dist, ideal) + ScoreAheadness(pos, target);

    // 高差更利于猛扑
    float dz = ClampFloat(ScoreHeightDelta(pos, target), 0.0, 720.0);
    score += dz * 0.80;

    // 正面斜上略优（用点积近似落点朝向关系）
    float fwd[3]; SurvivorForward(target, fwd);
    float t[3];   GetClientAbsOrigin(target, t);
    float to[3];  MakeVectorFromPoints(pos, t, to); NormalizeVector(to, to);
    float dot = GetVectorDotProduct(fwd, to);
    if (dot > 0.35)                  score += 70.0;

    return score;
}

static float ScoreSpitter(float pos[3], int target, float dist, float ideal)
{
    float score = ScoreDistanceIdeal(dist, ideal);

    // 稍微偏后/侧更安全抛射
    float aheadBias = IsPosAheadOfHighest(pos, target) ? 0.0 : 60.0;
    score += aheadBias;

    // 略微高度优势（不需要太高）
    float dz = ClampFloat(ScoreHeightDelta(pos, target), 0.0, 300.0);
    score += dz * 0.40;

    score += 60.0; // 常数项
    return score;
}

static float ScoreJockey(float pos[3], int target, float dist, float ideal)
{
    float score = ScoreDistanceIdeal(dist, ideal) + ScoreAheadness(pos, target);

    // 侧面黏人窗口更大
    float fwd[3]; SurvivorForward(target, fwd);
    float t[3];   GetClientAbsOrigin(target, t);
    float to[3];  MakeVectorFromPoints(pos, t, to); NormalizeVector(to, to);
    float dot = GetVectorDotProduct(fwd, to);
    if (FloatAbs(dot) < 0.50)        score += 100.0;

    // 轻度高度优势
    float dz = ClampFloat(ScoreHeightDelta(pos, target), 0.0, 300.0);
    score += dz * 0.55;

    return score;
}

static float ScoreCharger(float pos[3], int target, float dist, float ideal)
{
    float score = ScoreDistanceIdeal(dist, ideal) + ScoreAheadness(pos, target);

    // 跑道检测改为方向对齐近似（去除 HasClearRunway 的 Hull Trace）
    float fwd[3]; SurvivorForward(target, fwd);
    float t[3];   GetClientAbsOrigin(target, t);
    float to[3];  MakeVectorFromPoints(pos, t, to); NormalizeVector(to, to);
    float dot = GetVectorDotProduct(fwd, to);

    if (dot > 0.35)                  score += 180.0;   // 基本对正
    if (dot > 0.70)                  score += 60.0;    // 高度对正

    // 垂直差过大不利于冲锋，给惩罚（无射线）
    float adz = FloatAbs(ScoreHeightDelta(pos, target));
    if (adz > 60.0)                  score -= (adz - 60.0) * 0.80;

    return score;
}

// ---------------------------------------------------------------------------
// FindSpawnPosForClass (with low-score expand, debug)
// ---------------------------------------------------------------------------

static bool FindSpawnPosForClass(int zc, int targetSurvivor, float searchRadius, bool teleportMode, float outPos[3])
{
    if (!IsValidClient(targetSurvivor)) return false;

    float tEye[3]; GetClientEyePosition(targetSurvivor, tEye);

    float baseIdeal = ClampFloat(searchRadius * 0.90, gCV.fSpawnMin + 80.0, gCV.fSpawnMin + 600.0);

    float sPos[3];
    GetClientEyePosition(targetSurvivor, sPos);
    sPos[2] -= 60.0;

    Address navS = L4D2Direct_GetTerrorNavArea(sPos);
    bool strictLadder = ShouldApplyLadderStrict();
    Debug_Reset(zc, targetSurvivor, searchRadius, navS, strictLadder);

    float best[3]; bool haveBest = false;
    float bestScore = -1.0e9;

    float radiusCur = searchRadius;
    int   expandCnt = 0;
    bool  isSupportClass = (zc == view_as<int>(SI_Boomer) || zc == view_as<int>(SI_Spitter));
    float maxR = isSupportClass ? FloatMin(gCV.fSpawnMax, SUPPORT_EXPAND_MAX) : gCV.fSpawnMax;

    float avgDist = GetSurAvrDistance();

    do
    {
        float mins[3], maxs[3];
        mins[0] = tEye[0] - radiusCur;
        mins[1] = tEye[1] - radiusCur;
        mins[2] = tEye[2];

        maxs[0] = tEye[0] + radiusCur;
        maxs[1] = tEye[1] + radiusCur;
        maxs[2] = tEye[2] + ((radiusCur < 500.0) ? 800.0 : (radiusCur + 300.0));

        float R = radiusCur;
        if (avgDist < BAIT_DISTANCE) R *= (1.0 + (avgDist / BAIT_DISTANCE));
        if (gST.ladderBaitCount)     R += BAIT_DISTANCE;

        for (int i = 0; i < CANDIDATE_TRIES; i++)
        {
            float p[3];
            p[0] = GetRandomFloat(mins[0], maxs[0]);
            p[1] = GetRandomFloat(mins[1], maxs[1]);
            p[2] = GetRandomFloat(mins[2], maxs[2]);

            // 落地到可站高度
            float dir[3] = {90.0, 0.0, 0.0};
            int gmask = GroundMaskForRadius(radiusCur);
            Handle trRay = TR_TraceRayFilterEx(p, dir, gmask, RayType_Infinite, TraceFilter_Ground);
            if (TR_DidHit(trRay))
            {
                float endp[3];
                TR_GetEndPosition(endp, trRay);
                p[0] = endp[0];
                p[1] = endp[1];
                p[2] = endp[2] + NAV_MESH_HEIGHT;
            }
            delete trRay;

            gDBG.considered++;

            if (!IsOnValidMesh(p)) { gDBG.failMesh++; continue; }
            if (!IsHullFreeAt(p))  { gDBG.failHull++; continue; }

            float dist = GetVectorDistance(sPos, p);
            if (dist < gCV.fSpawnMin)        { gDBG.failNear++;  continue; }
            if (dist > (R + RING_SLACK))     { gDBG.failRing++;  continue; }

            if ((gST.bPickRushMan || teleportMode) && IsKillerClassInt(zc) && !IsPosAheadOfHighest(p, targetSurvivor))
            { gDBG.failAhead++; continue; }

            if (IsPosVisibleSDK(p, teleportMode)) { gDBG.failVisible++; continue; }

            // 可达性
            float pathNeed = radiusCur * NORMALPOSMULT;
            if (pathNeed - radiusCur <= 120.0) pathNeed = radiusCur + 120.0;
            if (p[2] - sPos[2] > HIGHERPOS)   pathNeed += HIGHERPOSADDDISTANCE;
            Address navP = view_as<Address>(L4D_GetNearestNavArea(p, 120.0, false, false, false, TEAM_INFECTED));
            if (!L4D2_NavAreaBuildPath(navS, navP, pathNeed, TEAM_INFECTED, false)) { gDBG.failPath++; continue; }

            // 梯子黑名单（严格模式直接拒绝）
            bool atMasked = false;
            if (IsAreaMasked(navP))
            {
                if (strictLadder) { gDBG.failMaskedStrict++; continue; }
                atMasked = true;
            }

            // 房顶/楼板隔断惩罚（轻量）
            float dx = p[0] - sPos[0];
            float dy = p[1] - sPos[1];
            float dz_check = (p[2] - sPos[2]);
            float horiz_check = SquareRoot(dx*dx + dy*dy);
            float sepPenalty = 0.0;
            if (dz_check > ROOF_VDELTA_MIN && horiz_check < ROOF_HORIZ_MAX && IsSeparatedByCeiling(p, targetSurvivor))
                sepPenalty = -ROOF_SEPARATION_PENALTY;

            // === 无评分模式：半径 >= 1000 直接接受第一个合格点 ===
            if (radiusCur >= 1000.0)
            {
                gDBG.bestScore      = 0.0;
                gDBG.bestPos[0]     = p[0]; gDBG.bestPos[1] = p[1]; gDBG.bestPos[2] = p[2];
                gDBG.distToTarget   = dist;
                gDBG.ideal          = 0.0;
                gDBG.classScore     = 0.0;
                gDBG.divPenBest     = 0.0;
                gDBG.ladPenBest     = 0.0;
                gDBG.sepPenaltyBest = sepPenalty;
                gDBG.maskedSoft     = atMasked;
                gDBG.navBest        = navP;
                gDBG.radiusFinal    = radiusCur;

                outPos[0] = p[0]; outPos[1] = p[1]; outPos[2] = p[2];
                return true;
            }

            // === 正常评分模式（半径 < 1000 才会走到这里）===
            float ideal = baseIdeal;
            switch (zc)
            {
                case view_as<int>(SI_Smoker):  ideal = baseIdeal + 60.0;
                case view_as<int>(SI_Boomer):  ideal = baseIdeal - 60.0;
                case view_as<int>(SI_Hunter):  ideal = baseIdeal + 40.0;
                case view_as<int>(SI_Spitter): ideal = baseIdeal + 20.0;
                case view_as<int>(SI_Jockey):  ideal = baseIdeal - 60.0;
                case view_as<int>(SI_Charger): ideal = baseIdeal + 40.0;
            }

            float classSc = 0.0;
            switch (zc)
            {
                case view_as<int>(SI_Smoker):  classSc = ScoreSmoker(p, targetSurvivor, dist, ideal);
                case view_as<int>(SI_Boomer):  classSc = ScoreBoomer(p, targetSurvivor, dist, ideal);
                case view_as<int>(SI_Hunter):  classSc = ScoreHunter(p, targetSurvivor, dist, ideal);
                case view_as<int>(SI_Spitter): classSc = ScoreSpitter(p, targetSurvivor, dist, ideal);
                case view_as<int>(SI_Jockey):  classSc = ScoreJockey(p, targetSurvivor, dist, ideal);
                case view_as<int>(SI_Charger): classSc = ScoreCharger(p, targetSurvivor, dist, ideal);
                default:                       classSc = 0.0;
            }

            float divPen = DiversityPenaltyGlobal(p, navP);
            float ladPen = LadderProximityPenalty(p);
            float sc = classSc + divPen + ladPen + sepPenalty;
            if (atMasked) sc -= LADDER_MASK_SOFT_PENALTY;

            if (sc > bestScore)
            {
                bestScore = sc;
                best[0] = p[0]; best[1] = p[1]; best[2] = p[2];
                haveBest = true;

                gDBG.bestScore      = sc;
                gDBG.bestPos[0]     = p[0]; gDBG.bestPos[1] = p[1]; gDBG.bestPos[2] = p[2];
                gDBG.distToTarget   = dist;
                gDBG.ideal          = ideal;
                gDBG.classScore     = classSc;
                gDBG.divPenBest     = divPen;
                gDBG.ladPenBest     = ladPen;
                gDBG.sepPenaltyBest = sepPenalty;
                gDBG.maskedSoft     = atMasked;
                gDBG.navBest        = navP;
            }
        }

        if (bestScore >= LOW_SCORE_THRESHOLD) break;

        float prev = radiusCur;
        radiusCur = FloatMin(radiusCur + LOW_SCORE_EXPAND, maxR);
        if (radiusCur > prev + 0.1)
        {
            expandCnt++;
            gDBG.lowExpands++;
            gDBG.radiusFinal = radiusCur;
        }
        else break;

    } while (radiusCur + 0.1 < maxR && expandCnt < LOW_SCORE_MAX_STEPS);

    if (haveBest && bestScore >= -1.0e8)
    {
        gDBG.radiusFinal = radiusCur;
        outPos[0] = best[0]; outPos[1] = best[1]; outPos[2] = best[2];
        return true;
    }

    // --- 兜底：导演随机 PZ 点（保持你原有逻辑，不引入评分） ---
    float pz[3]; bool ok = false;
    int refSur = IsValidSurvivor(targetSurvivor) ? targetSurvivor : L4D_GetHighestFlowSurvivor();
    if (!IsValidSurvivor(refSur)) refSur = 0;

    const int PZ_TRIES = 24;
    for (int j = 0; j < PZ_TRIES; j++)
    {
        if (!L4D_GetRandomPZSpawnPosition(refSur, zc, 2, pz))
            continue;

        gDBG.considered++;

        if (IsPosVisibleSDK(pz, teleportMode)) { gDBG.failVisible++; continue; }
        if ((gST.bPickRushMan || teleportMode) && IsKillerClassInt(zc) && !IsPosAheadOfHighest(pz, targetSurvivor))
        { gDBG.failAhead++; continue; }

        outPos[0] = pz[0];
        outPos[1] = pz[1];
        outPos[2] = pz[2];

        gDBG.radiusFinal = gCV.fSpawnMax;
        gDBG.bestScore   = -500.0;
        ok = true;
        break;
    }

    if (ok) return true;

    Debug_DumpFail(teleportMode ? "TP" : "SPAWN");
    return false;
}


// ---------------------------------------------------------------------------
// Spawning
// ---------------------------------------------------------------------------

stock static bool DoSpawnAt(const float where[3], int zc)
{
    int ent = -1;
    ent = L4D2_SpawnSpecial(zc, where, view_as<float>({0.0, 0.0, 0.0}));

    if (IsValidEntity(ent) && IsValidEdict(ent) && IsInfectedBot(ent) && IsPlayerAlive(ent))
        return true;

    if (ent != -1 && IsValidEntity(ent))
        RemoveEntity(ent);
    return false;
}

static void BypassAndExecuteCommand(const char[] cmd)
{
    int fl = GetCommandFlags(cmd);
    SetCommandFlags(cmd, fl & ~FCVAR_CHEAT);
    FakeClientCommand(GetRandomSurvivor(), "%s", cmd);
    SetCommandFlags(cmd, fl);
}

// ---------------------------------------------------------------------------
// Class caps & masks
// ---------------------------------------------------------------------------

static int CheckClassEnabled(int t)
{
    switch (t)
    {
        case view_as<int>(SI_Smoker):  return ENABLE_SMOKER  & gCV.iEnableMask;
        case view_as<int>(SI_Boomer):  return ENABLE_BOOMER  & gCV.iEnableMask;
        case view_as<int>(SI_Hunter):  return ENABLE_HUNTER  & gCV.iEnableMask;
        case view_as<int>(SI_Spitter): return ENABLE_SPITTER & gCV.iEnableMask;
        case view_as<int>(SI_Jockey):  return ENABLE_JOCKEY  & gCV.iEnableMask;
        case view_as<int>(SI_Charger): return ENABLE_CHARGER & gCV.iEnableMask;
    }
    return 0;
}

static bool MeetClassRequirement(int t)
{
    if (gCV.AllCharger.BoolValue || gCV.AllHunter.BoolValue) return true;
    ReadSiCap();

    if (t < 1 || t > 6) return false;

    switch (t)
    {
        case view_as<int>(SI_Boomer):
        {
            if (CheckClassEnabled(t) && (gST.siCap[t-1] > 0) && ((CountDominateQueued() > (gCV.iSiLimit / 4 + 1)) || (gST.spawnQueueSize >= gCV.iSiLimit - 2)))
                return true;
        }
        case view_as<int>(SI_Spitter):
        {
            if (CheckClassEnabled(t) && (gST.siCap[t-1] > 0) && ((CountHunterChargerQueued() > (gCV.iSiLimit / 5 + 1)) || (gST.spawnQueueSize >= gCV.iSiLimit - 2)))
                return true;
        }
        default:
        {
            if (CheckClassEnabled(t) && (gST.siCap[t-1] > 0))
                return true;
        }
    }
    return false;
}

static int CountHunterChargerQueued()
{
    int c = 0;
    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        int t = gQ.spawn.Get(i);
        if (t == view_as<int>(SI_Hunter) || t == view_as<int>(SI_Charger)) c++;
    }
    return c;
}

static int CountDominateQueued()
{
    int c = 0;
    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        int t = gQ.spawn.Get(i);
        if (t == view_as<int>(SI_Smoker)
         || t == view_as<int>(SI_Hunter)
         || t == view_as<int>(SI_Jockey)
         || t == view_as<int>(SI_Charger)) c++;
    }
    return c;
}
static bool HasReachedLimit(int zc)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_zombieClass") == zc)
            count++;

    if ((gCV.AllCharger.BoolValue || gCV.AllHunter.BoolValue) && count >= gCV.iSiLimit)
        return true;
    if (gCV.AllCharger.BoolValue || gCV.AllHunter.BoolValue)
        return false;

    char cvar[24];
    FormatEx(cvar, sizeof cvar, "z_%s_limit", INFDN[zc]);
    return count >= GetConVarInt(FindConVar(cvar));
}

// ---------------------------------------------------------------------------
// Target selection & runner detection
// ---------------------------------------------------------------------------

static int ChooseTargetSurvivor()
{
    if (gST.bPickRushMan && IsValidSurvivor(gST.rushManIndex) && IsPlayerAlive(gST.rushManIndex) && !IsPinned(gST.rushManIndex))
        return gST.rushManIndex;

    int cand[8]; int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i) && (!IsPinned(i) || !IsClientIncapped(i)))
        {
            if (gST.bTargetLimitLib && IsClientReachLimit(i)) continue;
            cand[n++] = i;
            if (n >= 8) break;
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

// ---------------------------------------------------------------------------
// Flow / ahead helpers
// ---------------------------------------------------------------------------

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

static int Calculate_Flow(Address area)
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

// ---------------------------------------------------------------------------
// Bait / density / averages
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Common infected trickle
// ---------------------------------------------------------------------------

static void SpawnCommonInfect(int amount)
{
    float pos[3];
    for (int i = 0; i < amount; i++)
    {
        L4D_GetRandomPZSpawnPosition(0, view_as<int>(SI_Jockey), 2, pos);
        L4D_SpawnCommonInfected(pos, {0.0, 0.0, 0.0});
    }
}

// ---------------------------------------------------------------------------
// Ladder cache & mask build
// ---------------------------------------------------------------------------

static Action Timer_InitLadders(Handle timer)
{
    if (gLadder.arr == null) gLadder.Create();
    if (gLadder.arr.Length <= 1) CacheAllLadders();
    BuildLadderNavMask();
    return Plugin_Continue;
}

static void CacheAllLadders()
{
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
}

static bool IsLadderAround(int client, float dist)
{
    if (client <= 0 || !IsValidSurvivor(client)) return false;
    if (gLadder.arr == null || gLadder.arr.Length == 0) return false;
    float c[3]; GetClientAbsOrigin(client, c);
    float L[3];
    for (int i = 0; i < gLadder.arr.Length; i++)
    {
        gLadder.arr.GetArray(i, L);
        c[2] = 0.0; L[2] = 0.0;
        if (GetVectorDistance(c, L) <= dist) return true;
    }
    return false;
}

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

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

static bool IsValidClient(int client) { return (client >= 1 && client <= MaxClients && IsClientInGame(client)); }
static bool IsValidSurvivor(int client) { return IsValidClient(client) && (GetClientTeam(client) == TEAM_SURVIVOR); }
stock float FloatMin(float a, float b)
{
    return (a < b) ? a : b;
}

stock float FloatMax(float a, float b)
{
    return (a > b) ? a : b;
}

static float GetClosestSurvivorDistance(int client)
{
    float c[3]; GetClientAbsOrigin(client, c);
    float best = 999999.0; float s[3];
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i)) { GetClientAbsOrigin(i, s); float d = GetVectorDistance(c, s); if (d < best) best = d; }
    return best;
}

static bool IsClientIncapped(int client)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
        return false;
    if (L4D_IsPlayerIncapacitated(client))
        return true;
    return GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0;
}

public Action L4D_OnGetScriptValueInt(const char[] key, int &ret)
{
    if (((strcmp(key, "cm_ShouldHurry", false) == 0) || (strcmp(key, "cm_AggressiveSpecials", false) == 0)) && ret != 1)
    { ret = 1; return Plugin_Handled; }
    return Plugin_Continue;
}


// ---------- Roof/Room separation helpers ----------

static bool StartsWith(const char[] s, const char[] pre) { return StrContains(s, pre, false) == 0; }

static bool IsBrushySolid(int ent)
{
    if (ent == 0) return true;
    if (!IsValidEntity(ent)) return false;

    char cls[32];
    GetEntityClassname(ent, cls, sizeof cls);

    if (StartsWith(cls, "func_")) return true;
    if (StartsWith(cls, "prop_")) return true;
    return false;
}

static bool IsSeparatedByCeiling(const float spawnPos[3], int target)
{
    if (!IsValidSurvivor(target)) return false;

    float chest[3];
    GetClientAbsOrigin(target, chest);
    chest[2] += PLAYER_CHEST;

    float dx = spawnPos[0] - chest[0];
    float dy = spawnPos[1] - chest[1];
    float dz = spawnPos[2] - chest[2];
    float horiz = SquareRoot(dx*dx + dy*dy);

    if (dz <= 120.0 || horiz >= 600.0)
        return false;

    Handle tr = TR_TraceRayFilterEx(spawnPos, chest, MASK_VISIBLE | CONTENTS_GRATE, RayType_EndPoint, TraceFilter_Stuck);
    bool hit = TR_DidHit(tr);
    int ent  = hit ? TR_GetEntityIndex(tr) : -1;
    delete tr;

    return hit && IsBrushySolid(ent);
}
