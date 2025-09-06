#pragma semicolon 1
#pragma newdecls required

/**
 * Infected Control (fdxx-style NavArea spot picking + max-distance fallback + FLOW分桶)
 * - Nav 分桶：开局预扫全图 NavArea，按“进度百分比(0..100)”分桶
 *   - 选点仅在【目标幸存者附近 ±N 桶】里扫描（默认 N=10，可改CVar）
 *   - 大幅降低每次遍历量；其余过滤保持不变
 * - 主找点（唯一）：TerrorNavArea::FindRandomSpot
 *   - Flow 窗口（仍做二次校验）& 距离窗口（窗口=当前 ring）
 *   - 视线不可见（IsVisibleToPlayer）
 *   - Hull 不会卡（WillStuck）
 *   - 去除多样性/梯子重过滤（按你的要求）
 * - 扩圈：SpawnMin → SpawnMax；到达 Max 触发“导演兜底”
 * - 保留：队列、跑男检测、传送监督、上限/间隔、暂停联动、死亡CD双保险等
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
#include <si_target_limit>  // 可选
#include <pause>            // 可选
#include <ai_smoker_new>    // 可选

// =========================
// 常量/宏
// =========================
#define CVAR_FLAG                 FCVAR_NOTIFY
#define TEAM_SURVIVOR             2
#define TEAM_INFECTED             3
#define NAV_MESH_HEIGHT           20.0
#define PLAYER_CHEST              45.0

#define BAIT_DISTANCE             200.0
#define RING_SLACK                300.0
#define NOSCORE_RADIUS            1000.0
#define SUPPORT_EXPAND_MAX        1200.0

// 扩圈节奏
#define LOW_SCORE_EXPAND          100.0

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

// —— 分散度四件套参数 —— //
#define PI                        3.1415926535
#define SEP_TTL                   8.0    // 最近刷点保留秒数
#define SEP_MAX                   20     // 记录上限（防止无限增长）
// === Dispersion tuning (lighter penalties) ===
#define SEP_RADIUS                100.0
#define NAV_CD_SECS               1.0
#define SECTORS_BASE              4       // 你的当前调参基准
#define SECTORS_MAX               8       // 动态上限（建议 6~8 之间）
#define DYN_SECTORS_MIN           2       // 动态下限

// === Dispersion tuning (penalties at BASE=4) ===
#define SECTOR_PREF_BONUS_BASE   -6.0
#define SECTOR_OFF_PENALTY_BASE   3.0
#define RECENT_PENALTY_0_BASE     2.0
#define RECENT_PENALTY_1_BASE     1.0
#define RECENT_PENALTY_2_BASE     1.0
#define RAND_JITTER_MAX           2.5     // 降低抖动避免“误伤”近点

// 可调参数（想热调也能做成 CVar，这里先给常量）
#define PEN_LIMIT_SCALE_HI        1.08   // L=1 时：正向惩罚略强一点
#define PEN_LIMIT_SCALE_LO        0.60   // L=20 时：正向惩罚明显减弱
#define PEN_LIMIT_MINL            1
#define PEN_LIMIT_MAXL            20

// Nav Flow 分桶
#define FLOW_BUCKETS              101     // 0..100

// 记录最近使用过的 navArea -> 过期时间
StringMap g_NavCooldown;

static const char INFDN[10][] =
{
    "common","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};

// -----------------------
// SDK / Gamedata offsets
// -----------------------
static TheNavAreas g_pTheNavAreas;
// === SDKCall 句柄（全局） ===
static Handle g_hSDKFindRandomSpot = null;     // TerrorNavArea::FindRandomSpot
static Handle g_hSDKIsVisibleToPlayer = null;  // IsVisibleToPlayer(...)
static int g_iSpawnAttributesOffset = -1;
static int g_iFlowDistanceOffset = -1;
static int g_iNavCountOffset = -1;
static int g_pPanicEventStage = -1;

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

// Nav flags（参考 wiki / fdxx）
enum
{
    TERROR_NAV_EMPTY                = 1 << 1,
    TERROR_NAV_STOP_SCAN            = 1 << 2,
    TERROR_NAV_BATTLESTATION        = 1 << 5,
    TERROR_NAV_FINALE               = 1 << 6,
    TERROR_NAV_PLAYER_START         = 1 << 7,
    TERROR_NAV_BATTLEFIELD          = 1 << 8,
    TERROR_NAV_IGNORE_VISIBILITY    = 1 << 9,
    TERROR_NAV_NOT_CLEARABLE        = 1 << 10,
    TERROR_NAV_CHECKPOINT           = 1 << 11,
    TERROR_NAV_OBSCURED             = 1 << 12,
    TERROR_NAV_NO_MOBS              = 1 << 13,
    TERROR_NAV_THREAT               = 1 << 14,
    TERROR_NAV_RESCUE_VEHICLE       = 1 << 15,
    TERROR_NAV_RESCUE_CLOSET        = 1 << 16,
    TERROR_NAV_ESCAPE_ROUTE         = 1 << 17,
    TERROR_NAV_DOOR                 = 1 << 18,
    TERROR_NAV_NOTHREAT             = 1 << 19
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
    ConVar AutoSpawnTime;
    ConVar IgnoreIncapSight;
    ConVar AddDmgSmoker;
    ConVar SiLimit;
    ConVar SiInterval;
    ConVar DebugMode;

    ConVar MaxPlayerZombies;
    ConVar VsBossFlowBuffer;

    // —— Nav 分桶 —— //
    ConVar NavBucketEnable;      
    ConVar NavBucketWindow;      

    // —— 动态分桶（新增） —— //
    ConVar NavBucketLinkToRing;   // 1=跟随扩圈动态调整桶窗口
    ConVar NavBucketWindowMin;    // ring<=MinAt 时窗口(±N)
    ConVar NavBucketWindowMax;    // ring>=MaxAt 时窗口(±N)
    ConVar NavBucketMinAt;        // ring 下界
    ConVar NavBucketMaxAt;        // ring 上界

    // —— 新增：死亡CD（两档） —— //
    ConVar DeathCDKiller;        
    ConVar DeathCDSupport;       

    // —— 新增：死亡CD放宽的“双保险” —— //
    ConVar DeathCDBypassAfter;   
    ConVar DeathCDUnderfill;     

    float fSpawnMin;
    float fSpawnMax;
    float fSiInterval;
    int   iSiLimit;
    int   iEnableMask;
    int   iTeleportCheckTime;
    int   iDebugMode;
    bool  bTeleport;
    bool  bAutoSpawn;
    bool  bIgnoreIncapSight;
    bool  bAddDmgSmoker;

    // —— Nav 分桶 —— //
    bool  bNavBucketEnable;
    int   iNavBucketWindow;

    // —— 动态分桶（新增） —— //
    bool  bNavBucketLinkToRing;
    int   iNavBucketWindowMin;
    int   iNavBucketWindowMax;
    float fNavBucketMinAt;
    float fNavBucketMaxAt;

    float fDeathCDKiller;
    float fDeathCDSupport;
    float fDeathCDBypassAfter;
    float fDeathCDUnderfill;

    void Create()
    {
        this.SpawnMin          = CreateConVar("inf_SpawnDistanceMin", "250.0", "特感复活离生还者最近的距离限制", CVAR_FLAG, true, 0.0);
        this.SpawnMax          = CreateConVar("inf_SpawnDistanceMax", "1500.0", "特感复活离生还者最远的距离限制", CVAR_FLAG, true, this.SpawnMin.FloatValue);
        this.TeleportEnable    = CreateConVar("inf_TeleportSi", "1", "是否开启特感超时传送", CVAR_FLAG, true, 0.0, true, 1.0);
        this.TeleportCheckTime = CreateConVar("inf_TeleportCheckTime", "5", "特感几秒后没被看到开始传送", CVAR_FLAG, true, 0.0);
        this.EnableMask        = CreateConVar("inf_EnableSIoption", "63", "启用生成的特感类型位掩码 (1~63)", CVAR_FLAG, true, 0.0, true, 63.0);
        this.AllCharger        = CreateConVar("inf_AllChargerMode", "0", "是否是全牛模式", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AllHunter         = CreateConVar("inf_AllHunterMode", "0", "是否是全猎人模式", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AutoSpawnTime     = CreateConVar("inf_EnableAutoSpawnTime", "1", "是否开启自动增时", CVAR_FLAG, true, 0.0, true, 1.0);
        this.IgnoreIncapSight  = CreateConVar("inf_IgnoreIncappedSurvivorSight", "1", "传送检测是否忽略倒地/挂边视线", CVAR_FLAG, true, 0.0, true, 1.0);
        this.AddDmgSmoker      = CreateConVar("inf_AddDamageToSmoker", "0", "单人时Smoker拉人对Smoker增伤5x", CVAR_FLAG, true, 0.0, true, 1.0);
        this.SiLimit           = CreateConVar("l4d_infected_limit", "6", "一次刷出多少特感", CVAR_FLAG, true, 0.0);
        this.SiInterval        = CreateConVar("versus_special_respawn_interval", "16.0", "对抗刷新间隔", CVAR_FLAG, true, 0.0);
        this.DebugMode         = CreateConVar("inf_DebugMode", "1","0=off,1=log,2=console+log,3=console+log(+beam)", CVAR_FLAG, true, 0.0, true, 3.0);

        // —— Nav 分桶（静态窗口） —— //
        this.NavBucketEnable   = CreateConVar("inf_NavBucketEnable", "1", "启用 Nav 进度分桶筛选(0=禁用,1=启用)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketWindow   = CreateConVar("inf_NavBucketWindow", "10", "按进度百分比搜索的桶半径(±N)，默认10", CVAR_FLAG, true, 0.0, true, 100.0);

        // —— 动态分桶（新增） —— //
        this.NavBucketLinkToRing = CreateConVar("inf_NavBucketLinkToRing", "1", "扩圈时动态调整桶窗口(0=关闭,1=开启)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketWindowMin  = CreateConVar("inf_NavBucketWindowMin", "6", "ring<=MinAt时使用的桶窗口(±N)", CVAR_FLAG, true, 0.0, true, 100.0);
        this.NavBucketWindowMax  = CreateConVar("inf_NavBucketWindowMax", "12", "ring>=MaxAt时使用的桶窗口(±N)", CVAR_FLAG, true, 0.0, true, 100.0);
        this.NavBucketMinAt      = CreateConVar("inf_NavBucketMinAt", "500.0", "小桶阈值对应的ring", CVAR_FLAG, true, 0.0);
        this.NavBucketMaxAt      = CreateConVar("inf_NavBucketMaxAt", "1500.0", "大桶阈值对应的ring", CVAR_FLAG, true, 0.0);

        // —— 死亡CD —— //
        this.DeathCDKiller     = CreateConVar("inf_DeathCooldownKiller",  "2.0","同类击杀后最小补位CD（秒）：Hunter/Smoker/Jockey/Charger", CVAR_FLAG, true, 0.0, true, 30.0);
        this.DeathCDSupport    = CreateConVar("inf_DeathCooldownSupport", "2.0","同类击杀后最小补位CD（秒）：Boomer/Spitter", CVAR_FLAG, true, 0.0, true, 30.0);

        // —— 双保险 —— //
        this.DeathCDBypassAfter = CreateConVar("inf_DeathCooldown_BypassAfter", "1.0","距离上次成功刷出超过该秒数时，临时忽略死亡CD", CVAR_FLAG, true, 0.0, true, 10.0);
        this.DeathCDUnderfill   = CreateConVar("inf_DeathCooldown_Underfill", "0.5","当【场上活着特感】< iSiLimit * 本值 时，忽略死亡CD", CVAR_FLAG, true, 0.0, true, 1.0);

        this.DeathCDKiller.AddChangeHook(OnCfgChanged);
        this.DeathCDSupport.AddChangeHook(OnCfgChanged);
        this.DeathCDBypassAfter.AddChangeHook(OnCfgChanged);
        this.DeathCDUnderfill.AddChangeHook(OnCfgChanged);

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
        this.AutoSpawnTime.AddChangeHook(OnCfgChanged);
        this.AddDmgSmoker.AddChangeHook(OnCfgChanged);
        this.SiLimit.AddChangeHook(OnSiLimitChanged);
        this.DebugMode.AddChangeHook(OnCfgChanged);

        // Nav 分桶
        this.NavBucketEnable.AddChangeHook(OnCfgChanged);
        this.NavBucketWindow.AddChangeHook(OnCfgChanged);
        this.NavBucketLinkToRing.AddChangeHook(OnCfgChanged);
        this.NavBucketWindowMin.AddChangeHook(OnCfgChanged);
        this.NavBucketWindowMax.AddChangeHook(OnCfgChanged);
        this.NavBucketMinAt.AddChangeHook(OnCfgChanged);
        this.NavBucketMaxAt.AddChangeHook(OnCfgChanged);

        this.VsBossFlowBuffer.AddChangeHook(OnFlowBufferChanged); // Flow百分比受它影响 → 变更时重建桶

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
        this.iDebugMode         = this.DebugMode.IntValue;

        // Nav 分桶
        this.bNavBucketEnable   = this.NavBucketEnable.BoolValue;
        this.iNavBucketWindow   = this.NavBucketWindow.IntValue;

        // 动态分桶
        this.bNavBucketLinkToRing = this.NavBucketLinkToRing.BoolValue;
        this.iNavBucketWindowMin  = this.NavBucketWindowMin.IntValue;
        this.iNavBucketWindowMax  = this.NavBucketWindowMax.IntValue;
        this.fNavBucketMinAt      = this.NavBucketMinAt.FloatValue;
        this.fNavBucketMaxAt      = this.NavBucketMaxAt.FloatValue;

        // 死亡CD & 放宽
        this.fDeathCDKiller     = this.DeathCDKiller.FloatValue;
        this.fDeathCDSupport    = this.DeathCDSupport.FloatValue;
        this.fDeathCDBypassAfter= this.DeathCDBypassAfter.FloatValue;
        this.fDeathCDUnderfill  = this.DeathCDUnderfill.FloatValue;
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

    bool   bPauseLib;
    bool   bSmokerLib;
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
    }
}

// —— 可选库可用性 —— 
static bool g_bPauseLib       = false;
static bool g_bSmokerLib      = false;
static bool g_bTargetLimitLib = false;

// Survivor 数据缓存（fdxx风格）
enum struct SurPosData 
{ 
    float fFlow; 
    float fPos[3]; 
}
static ArrayList g_aSurPosData = null;
static int g_iSurPosDataLen = 0;
static int g_iSurvivors[MAXPLAYERS+1];
static int g_iSurCount = 0;

// —— 分散度：最近扇区 & 最近刷点 —— //
int recentSectors[3] = { -1, -1, -1 };   // 最近 3 次使用的扇区
ArrayList lastSpawns = null;             // 每条记录 [x,y,z,time]

// —— 新增：死亡CD时间戳 & 最近一次成功刷出 —— //
static float g_LastDeathTime[6];     // zc-1 索引
static float g_LastSpawnOkTime = 0.0;

// —— Nav Flow 分桶 —— //
static ArrayList g_FlowBuckets[FLOW_BUCKETS]; // 每桶存 NavArea 索引 i
static bool g_BucketsReady = false;

// 跑男通知 forward
Handle g_hRushManNotifyForward = INVALID_HANDLE;

// =========================
// 全局
// =========================
public Plugin myinfo =
{
    name        = "Direct InfectedSpawn (fdxx-nav + buckets + maxdist-fallback)",
    author      = "Caibiii, 夜羽真白, 东, Paimon-Kawaii, fdxx (inspiration), ChatGPT",
    description = "特感刷新控制 / 传送 / 跑男 / fdxx NavArea选点 + 进度分桶 + 最大距离兜底",
    version     = "2025.09.04-buckets",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

static Config gCV;
static State  gST;
static Queues gQ;

static char g_sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control_fdxxnav.txt";

// =========================
// 前置：事件 & 库
// =========================
public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
    RegPluginLibrary("infected_control");                           // 供其他插件依赖
    g_hRushManNotifyForward = CreateGlobalForward("OnDetectRushman", // 跑男 forward：传入幸存者 index
                                                  ET_Ignore, Param_Cell);
    CreateNative("GetNextSpawnTime", Native_GetNextSpawnTime);       // native：下一次刷特剩余秒数
    return APLRes_Success;
}
public void OnAllPluginsLoaded()
{
    g_bTargetLimitLib = LibraryExists("si_target_limit");
    g_bSmokerLib      = LibraryExists("ai_smoker_new");
    g_bPauseLib       = LibraryExists("pause");
}
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "si_target_limit")) g_bTargetLimitLib = true;
    else if (StrEqual(name, "ai_smoker_new")) g_bSmokerLib   = true;
    else if (StrEqual(name, "pause"))         g_bPauseLib    = true;
}
public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "si_target_limit")) g_bTargetLimitLib = false;
    else if (StrEqual(name, "ai_smoker_new")) g_bSmokerLib   = false;
    else if (StrEqual(name, "pause"))         g_bPauseLib    = false;
}
//native
public any Native_GetNextSpawnTime(Handle plugin, int numParams)
{
    // -1：还没开始刷特（或未知）
    if (!gST.bLate)
        return view_as<any>(-1.0);

    float now = GetGameTime();

    // 如果在暂停，返回预计恢复倒计时
    if (g_bPauseLib && IsInPause())
    {
        float rem = gST.unpauseDelay;
        if (rem <= 0.0) rem = -1.0;
        return view_as<any>(rem);
    }

    // 如果“下一波定时器”存在，按 (间隔 - 已经过的时间) 粗略估算
    if (gST.hSpawn != INVALID_HANDLE)
    {
        float rem = gCV.fSiInterval - (now - gST.lastWaveStartTime);
        if (rem < 0.0) rem = 0.0;
        return view_as<any>(rem);
    }

    // 没有定时器则表示由窗口逻辑随时可能触发，返回 刷特间隔
    return view_as<any>(gCV.fSiInterval);
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
    BuildNavBuckets();        // ← 预建 FLOW 分桶
    RecalcSiCapFromAlive(true);

    // 分散度：初始化
    g_NavCooldown = new StringMap();
    lastSpawns = new ArrayList(4);
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    // 初始化死亡时间戳
    g_LastSpawnOkTime = 0.0;
    for (int i = 0; i < 6; i++) g_LastDeathTime[i] = 0.0;

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
    TweakSettings();
}

public void OnPluginEnd()
{
    if (gCV.AllCharger.IntValue == 1)
    {
        FindConVar("z_charger_health").RestoreDefault();
        FindConVar("z_charge_max_speed").RestoreDefault();
        FindConVar("z_charge_start_speed").RestoreDefault();
        FindConVar("z_charger_pound_dmg").RestoreDefault();
        FindConVar("z_charge_max_damage").RestoreDefault();
        FindConVar("z_charge_interval").RestoreDefault();
    }
}
public void OnMapEnd()
{
    if (g_NavCooldown != null) g_NavCooldown.Clear();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    g_LastSpawnOkTime = 0.0;
    for (int i = 0; i < 6; i++) g_LastDeathTime[i] = 0.0;

    ClearNavBuckets();
    g_BucketsReady = false;
}
void TweakSettings()
{
    if (gCV.AllCharger.IntValue == 1)
    {
        FindConVar("z_charger_health").SetFloat(500.0);
        FindConVar("z_charge_max_speed").SetFloat(750.0);
        FindConVar("z_charge_start_speed").SetFloat(350.0);
        FindConVar("z_charger_pound_dmg").SetFloat(10.0);
        FindConVar("z_charge_max_damage").SetFloat(6.0);
        FindConVar("z_charge_interval").SetFloat(2.0);
    }
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
stock void LogMsg(const char[] fmt, any ...)
{
    if (gCV.iDebugMode <= 0) return;
    char b[512];
    VFormat(b, sizeof b, fmt, 2);
    LogToFile(g_sLogFile, "%s", b);
    if (gCV.iDebugMode >= 2) PrintToServer("[IC] %s", b);
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
        PrintToChatAll("\x03 fdxx-NavArea找点 + FLOW分桶 + 最大距离兜底 已启用 (v2025.09.04) ");
        TweakSettings();
    }
    return Plugin_Handled;
}
public Action Cmd_StopSpawn(int client, int args)
{
    StopAll();
    return Plugin_Handled;
}

// =========================
static void StopAll()
{
    gQ.Clear();
    gST.Reset();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    g_LastSpawnOkTime = 0.0;
    for (int i = 0; i < 6; i++) g_LastDeathTime[i] = 0.0;
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
public void evt_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
    CreateTimer(0.2, Timer_RebuildBuckets, _, TIMER_FLAG_NO_MAPCHANGE); // 地图开局重建分桶
    CreateTimer(1.0,  Timer_ResetAtSaferoom, _, TIMER_FLAG_NO_MAPCHANGE);
}
public void evt_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
}
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
        // 记录该类最后死亡时间
        g_LastDeathTime[zc - 1] = GetGameTime();

        int idx = zc - 1;
        if (gST.siAlive[idx] > 0) gST.siAlive[idx]--; else gST.siAlive[idx] = 0;
        if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
    }
    gST.teleCount[client] = 0;
    RecalcSiCapFromAlive(false);  // 保持：死亡后刷新剩余额度
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
    RecalcSiCapFromAlive(true);   // 每波开始，先用“在场活着的”刷新剩余额度
    gST.survCount = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
            gST.survIdx[gST.survCount++] = i;

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

    Debug_Print("Start wave %d", gST.waveIndex);
}
public void OnUnpause()
{
    float delay = (gST.unpauseDelay > 0.1) ? gST.unpauseDelay : 1.0;
    UnpauseSpawnTimer(delay);
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
static void OnCfgChanged(ConVar convar, const char[] ov, const char[] nv)
{
    gCV.Refresh();
}
static void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{
    // Flow 百分比变化会影响分桶 → 重建
    RebuildNavBuckets();
}
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
                gST.siAlive[zc - 1]++;
                gST.totalSI++;
            }
        }
        if (IsValidSurvivor(i) && !IsPlayerAlive(i))
            L4D_RespawnPlayer(i);
    }
    // 重置死亡记录
    g_LastSpawnOkTime = 0.0;
    for (int k = 0; k < 6; k++) g_LastDeathTime[k] = 0.0;
}
// 扫描在场特感 → gST.siAlive[] / gST.totalSI；再用“上限 - 活着 = 剩余额度”写回 gST.siCap[]
static void RecalcSiCapFromAlive(bool log = false)
{
    for (int i = 0; i < 6; i++) gST.siAlive[i] = 0;
    gST.totalSI = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsInfectedBot(c) && IsPlayerAlive(c))
        {
            int zc = GetEntProp(c, Prop_Send, "m_zombieClass");
            if (1 <= zc && zc <= 6)
            {
                gST.siAlive[zc - 1]++;
                gST.totalSI++;
            }
        }
    }

    int baseCap[6];
    baseCap[0] = GetConVarInt(FindConVar("z_smoker_limit"));
    baseCap[1] = GetConVarInt(FindConVar("z_boomer_limit"));
    baseCap[2] = GetConVarInt(FindConVar("z_hunter_limit"));
    baseCap[3] = GetConVarInt(FindConVar("z_spitter_limit"));
    baseCap[4] = GetConVarInt(FindConVar("z_jockey_limit"));
    baseCap[5] = GetConVarInt(FindConVar("z_charger_limit"));

    for (int i = 0; i < 6; i++)
    {
        int remain = baseCap[i] - gST.siAlive[i];
        if (remain < 0) remain = 0;
        gST.siCap[i] = remain;
    }

    // —— 全猎/全牛：忽略各类原上限，强制该类 = l4d_infected_limit，其它类 = 0 —— //
    int forced = 0;
    if (gCV.AllHunter.BoolValue)  forced = view_as<int>(SI_Hunter);
    if (gCV.AllCharger.BoolValue) forced = view_as<int>(SI_Charger);
    if (forced != 0)
    {
        for (int i = 0; i < 6; i++) gST.siCap[i] = 0;
        int idx = forced - 1;
        int want = gCV.iSiLimit - gST.siAlive[idx];
        if (want < 0) want = 0;
        gST.siCap[idx] = want;
    }

    if (log) Debug_Print("[CAP] remain S=%d B=%d H=%d P=%d J=%d C=%d | alive S=%d B=%d H=%d P=%d J=%d C=%d | total=%d%s",
        gST.siCap[0], gST.siCap[1], gST.siCap[2], gST.siCap[3], gST.siCap[4], gST.siCap[5],
        gST.siAlive[0], gST.siAlive[1], gST.siAlive[2], gST.siAlive[3], gST.siAlive[4], gST.siAlive[5],
        gST.totalSI,
        (forced!=0) ? " [forced mode]" : "");
}
static void ReadSiCap()
{
    gST.siCap[0] = GetConVarInt(FindConVar("z_smoker_limit"));
    gST.siCap[1] = GetConVarInt(FindConVar("z_boomer_limit"));
    gST.siCap[2] = GetConVarInt(FindConVar("z_hunter_limit"));
    gST.siCap[3] = GetConVarInt(FindConVar("z_spitter_limit"));
    gST.siCap[4] = GetConVarInt(FindConVar("z_jockey_limit"));
    gST.siCap[5] = GetConVarInt(FindConVar("z_charger_limit"));

    // —— 全猎/全牛：强制把该类上限改成 l4d_infected_limit，其它类清 0 —— //
    int forced = 0;
    if (gCV.AllHunter.BoolValue)  forced = view_as<int>(SI_Hunter);
    if (gCV.AllCharger.BoolValue) forced = view_as<int>(SI_Charger);
    if (forced != 0)
    {
        for (int i = 0; i < 6; i++) gST.siCap[i] = 0;
        int idx = forced - 1;
        int want = gCV.iSiLimit - gST.siAlive[idx];
        if (want < 0) want = 0;
        gST.siCap[idx] = want;
    }

    Debug_Print("[CAP] caps S=%d B=%d H=%d P=%d J=%d C=%d%s",
        gST.siCap[0], gST.siCap[1], gST.siCap[2], gST.siCap[3], gST.siCap[4], gST.siCap[5],
        (forced!=0) ? " [forced mode]" : "");
}

// =========================
// 帧驱动
// =========================
public void OnGameFrame()
{
    if (gCV.iSiLimit > gCV.MaxPlayerZombies.IntValue)
        CreateTimer(0.1, Timer_ApplyMaxSpecials);

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
// 队列维护 & 选类规则（更新）
// -------------------------
static bool IsKillerClassInt(int zc)
{
    return  zc == view_as<int>(SI_Hunter) || zc == view_as<int>(SI_Jockey) || zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Smoker);
}
static bool IsSupportClassInt(int zc)
{
    return zc == view_as<int>(SI_Boomer) || zc == view_as<int>(SI_Spitter);
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

// 让“是否存在可入队的杀手类”也考虑死亡CD或放宽逻辑
static bool AnyEligibleKillerToQueue()
{
    static int ks[4] = { view_as<int>(SI_Smoker), view_as<int>(SI_Hunter), view_as<int>(SI_Jockey), view_as<int>(SI_Charger) };
    bool relax = ShouldRelaxDeathCD();
    for (int i = 0; i < 4; i++)
    {
        int k = ks[i];
        if (!CheckClassEnabled(k) || !CanQueueClass(k) )
            continue;
        if (!relax && !PassDeathCooldown(k))
            continue;
        return true;
    }
    return false;
}

// 被 MaintainSpawnQueueOnce() 调用的挑选函数（优先在杀手类里随机挑一个满足条件的）
static int PickEligibleKillerClass()
{
    static int ks[4] = { view_as<int>(SI_Smoker), view_as<int>(SI_Hunter), view_as<int>(SI_Jockey), view_as<int>(SI_Charger) };
    bool relax = ShouldRelaxDeathCD();

    // 随机尝试若干次，先走随机
    for (int tries = 0; tries < 8; tries++)
    {
        int k = ks[GetRandomInt(0, 3)];
        if (!CheckClassEnabled(k) || HasReachedLimit(k))
            continue;
        if (!relax && !PassDeathCooldown(k))
            continue;
        return k;
    }

    // 兜底：线性扫一遍
    for (int i = 0; i < 4; i++)
    {
        int k = ks[i];
        if (CheckClassEnabled(k) && !HasReachedLimit(k) && (relax || PassDeathCooldown(k)))
            return k;
    }
    return 0;
}
// —— 新增：死亡CD判断 —— //
static bool PassDeathCooldown(int zc)
{
    if (zc < 1 || zc > 6) return true;
    float now = GetGameTime();
    float last = g_LastDeathTime[zc - 1];
    if (last <= 0.01) return true;

    float need = IsSupportClassInt(zc) ? gCV.fDeathCDSupport : gCV.fDeathCDKiller;
    return (now - last) >= need;
}

// —— 新增：是否放宽CD（永不饿死双保险） —— //
static bool ShouldRelaxDeathCD()
{
    float now = GetGameTime();

    // 1) 最近无成功刷出超过阈值（防饿死）
    if (gCV.fDeathCDBypassAfter > 0.01
        && (g_LastSpawnOkTime <= 0.01 || (now - g_LastSpawnOkTime) >= gCV.fDeathCDBypassAfter))
        return true;

    // 2) 场上活着数低于“下限保有量”
    float uf = gCV.fDeathCDUnderfill;
    if (uf < 0.0) uf = 0.0;
    if (uf > 1.0) uf = 1.0;
    int floorAlive = RoundToCeil(float(gCV.iSiLimit) * uf);
    if (floorAlive < 1) floorAlive = 1;

    if (gST.totalSI < floorAlive)
        return true;

    return false;
}

// —— 新增：稀缺度优先选类（两遍：严格CD → 放宽CD） —— //
static int PickScarceClass()
{
    int pick = PickScarceClassImpl(/*relaxCD=*/false);
    if (pick == 0 && ShouldRelaxDeathCD())
        pick = PickScarceClassImpl(/*relaxCD=*/true);
    return pick;
}
static int PickScarceClassImpl(bool relaxCD)
{
    float bestScore = 9999.0;
    int bestZc = 0;

    for (int zc = 1; zc <= 6; zc++)
    {
        if (!CheckClassEnabled(zc))    continue;
        if (!CanQueueClass(zc))        continue;
        if (!relaxCD && !PassDeathCooldown(zc)) continue;

        int idx      = zc - 1;
        int alive    = gST.siAlive[idx];
        int capTotal = alive + gST.siCap[idx];
        if (capTotal <= 0) continue;

        // 稀缺度：alive / (alive + remain)，越小越稀缺
        float ratio = float(alive) / float(capTotal);

        // 刷新开头给杀手类一点优先（小幅）
        if (gST.lastSpawnSecs < SUPPORT_SPAWN_DELAY_SECS && IsKillerClassInt(zc))
            ratio -= 0.05;

        if (ratio < bestScore)
        {
            bestScore = ratio;
            bestZc = zc;
        }
    }
    return bestZc;
}

static void MaintainSpawnQueueOnce()
{
    RecalcSiCapFromAlive(false);  // 入队前刷新“剩余额度”
    if (gST.spawnQueueSize >= gCV.iSiLimit) return;

    int zc = 0;

    // 模式锁定
    if (gCV.AllCharger.BoolValue)      zc = view_as<int>(SI_Charger);
    else if (gCV.AllHunter.BoolValue)  zc = view_as<int>(SI_Hunter);

    // 稀缺度优先（默认）
    if (zc == 0)
        zc = PickScarceClass();

    // 若仍未挑到（比如所有类都临时不适合），则按旧策略兜底
    if (zc == 0)
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
                if (CanQueueClass(pick) && CheckClassEnabled(pick))
                { zc = pick; break; }
            }
        }
    }

    // 入队前：如果该类处于死亡CD且不满足放宽，就暂不入队，等待下一帧
    if (zc != 0 && CanQueueClass(zc) && CheckClassEnabled(zc))
    {
        if (!PassDeathCooldown(zc) && !ShouldRelaxDeathCD())
        {
            Debug_Print("<SpawnQ> skip %s: death-cooldown active", INFDN[zc]);
            return;
        }

        gQ.spawn.Push(zc);
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

    // 生成前再做一次“只看活着的”上限闸门
    if (HasReachedLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", INFDN[want]);
        gQ.spawn.Erase(0);
        gST.spawnQueueSize--;
        return;
    }

    // 若队头处于死亡CD且当前不触发放宽：把队头旋转到末尾，等待下一次
    if (!PassDeathCooldown(want) && !ShouldRelaxDeathCD())
    {
        gQ.spawn.Erase(0);
        gQ.spawn.Push(want);
        Debug_Print("[QUEUE ROTATE] %s under death-cooldown, rotate to tail", INFDN[want]);
        return;
    }

    bool isSupport = (want == view_as<int>(SI_Boomer) || want == view_as<int>(SI_Spitter));

    float pos[3];
    int areaIdx = -1;
    float ring = gST.spawnDistCur;

    float maxR = gCV.fSpawnMax;
    if (isSupport && SUPPORT_EXPAND_MAX < maxR)
        maxR = SUPPORT_EXPAND_MAX;

    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, false, pos, areaIdx);

    if (ok && IsPosVisibleSDK(pos, false)) { ok = false; }

    if (ok && DoSpawnAt(pos, want))
    {
        // 分散度：成功后记录冷却与最近刷点
        if (areaIdx >= 0) TouchNavCooldown(areaIdx, GetGameTime(), NAV_CD_SECS);
        float center[3]; GetSectorCenter(center, gST.targetSurvivor);
        RememberSpawn(pos, center);

        gST.siQueueCount--;
        gST.siAlive[want - 1]++; gST.totalSI++;
        gQ.spawn.Erase(0);        gST.spawnQueueSize--;

        BypassAndExecuteCommand("nb_assault");

        float nextStart = ring * 0.7;
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
            // 兜底不绑定具体 NavArea，记录坐标分散度即可
            float center[3]; GetSectorCenter(center, gST.targetSurvivor);
            RememberSpawn(pt, center);

            gST.siQueueCount--;
            gST.siAlive[want - 1]++; gST.totalSI++;
            gQ.spawn.Erase(0);        gST.spawnQueueSize--;

            BypassAndExecuteCommand("nb_assault");

            gST.spawnDistCur *= 0.8; // 兜底后略收缩
            Debug_Print("[SPAWN] fallback@max success");
        }
        else
        {
            Debug_Print("[SPAWN FAIL] fallback@max failed class=%s", INFDN[want]);
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
    int areaIdx = -1;
    float ring = gST.teleportDistCur;
    float maxR = gCV.fSpawnMax;

    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, true, pos, areaIdx);

    if (ok && IsPosVisibleSDK(pos, true)) { ok = false; }

    if (ok && DoSpawnAt(pos, want))
    {
        if (areaIdx >= 0) TouchNavCooldown(areaIdx, GetGameTime(), NAV_CD_SECS);
        float center[3]; GetSectorCenter(center, gST.targetSurvivor);
        RememberSpawn(pos, center);

        gST.siAlive[want - 1]++; gST.totalSI++;
        gQ.teleport.Erase(0);    gST.teleportQueueSize--;

        float nextTP = ring * 0.8;
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
            float center[3]; GetSectorCenter(center, gST.targetSurvivor);
            RememberSpawn(pt, center);

            gST.siAlive[want - 1]++; gST.totalSI++;
            gQ.teleport.Erase(0);    gST.teleportQueueSize--;

            gST.teleportDistCur = FloatMax(gCV.fSpawnMin, gST.teleportDistCur * 0.7);
            Debug_Print("[TP] fallback@max success, ring now %.1f", gST.teleportDistCur);
        }
        else
        {
            Debug_Print("[TP FAIL] fallback@max failed class=%s", INFDN[want]);
        }
    }
}

// =========================
// Anti-bait 定时器 / 波时序（去掉梯子相关）
// =========================
static Action Timer_CheckSpawnWindow(Handle timer)
{
    if (g_bPauseLib && IsInPause())
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
// 传送监督（1s）—接入 pause / ai_smoker_new
// =========================
static Action Timer_TeleportTick(Handle timer)
{
    if (g_bPauseLib && IsInPause())
        return Plugin_Continue;

    if (CheckRushManAndAllPinned())
        return Plugin_Continue;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!CanBeTeleport(c)) continue;

        float eyes[3];
        GetClientEyePosition(c, eyes);
        bool vis = IsPosVisibleSDK(eyes, true);

        if (!vis)
        {
            if (gST.teleportQueueSize == 0)
                gST.teleportDistCur = gCV.fSpawnMin;

            // Smoker：能力未就绪则暂不传（避免浪费）
            int zc = GetInfectedClass(c);
            if (zc == view_as<int>(SI_Smoker) && g_bSmokerLib)
            {
                int canUse = IsSmokerCanUseAbility(c); // 1 可用 / 0 不可用
                if (canUse == 0)
                {
                    if (gST.teleCount[c] % 5 == 0)
                        LogMsg("[TP] smoker %N: ability not ready -> skip teleport (tick=%d)", c, gST.teleCount[c]);
                    gST.teleCount[c] = 0;
                    continue;
                }
            }

            if (gST.teleCount[c] > gCV.iTeleportCheckTime || (gST.bPickRushMan && gST.teleportQueueSize == 0 && gST.teleCount[c] > 0))
            {
                int zcx = GetInfectedClass(c);
                if (zcx >= 1 && zcx <= 6)
                {
                    gQ.teleport.Push(zcx);
                    gST.teleportQueueSize++;

                    if (gST.siAlive[zcx-1] > 0) gST.siAlive[zcx-1]--; else gST.siAlive[zcx-1] = 0;
                    if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;

                    LogMsg("[TP] %N class=%s invisible for %d sec -> teleport respawn",
                           c, INFDN[zcx], gST.teleCount[c]);

                    KickClient(c, "Teleport SI");
                    RecalcSiCapFromAlive(false);
                    gST.teleCount[c] = 0;
                }
            }
            gST.teleCount[c]++;
        }
        else
        {
            if (gST.teleCount[c] > 0 && gST.teleCount[c] % 5 == 0)
                LogMsg("[TP] %N visible again (reset tick)", c);
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
static bool IsValidClient(int c) { return c > 0 && c <= MaxClients && IsClientInGame(c); }
static bool IsValidSurvivor(int c) { return IsValidClient(c) && GetClientTeam(c) == TEAM_SURVIVOR; }
static bool IsSpitter(int client)
{
    return IsInfectedBot(client) && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == view_as<int>(SI_Spitter);
}
static int  GetInfectedClass(int client) { return GetEntProp(client, Prop_Send, "m_zombieClass"); }
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
static float GetClosestSurvivorDistance(int client)
{
    float p[3]; GetClientAbsOrigin(client, p);
    float best = 999999.0, s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d < best) best = d;
    }
    return best;
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

    if (IsAiSmoker(client) && g_bSmokerLib && !IsSmokerCanUseAbility(client))
        return false;

    float p[3];
    GetClientAbsOrigin(client, p);
    if (IsPosAheadOfHighest(p))
        return false;

    return true;
}

// =========================
// 可视/落地/几何
// =========================
static bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    // 头/胸/脚：高度大致对应 SI 模型
    float head[3],chest[3],feet[3];
    head = pos; head[2] += 62.0;
    chest = pos; chest[2] += 32.0;
    feet = pos; feet[2] += 8.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;
        if (teleportMode && L4D_IsPlayerIncapacitated(i) && gCV.bIgnoreIncapSight)
            continue;

        float eyes[3];
        GetClientEyePosition(i, eyes);

        // 1) Ray：眼睛 -> 头（任一射线“几乎贯通”都视为可见 → 禁刷）
        {
            Handle tr = TR_TraceRayFilterEx(eyes, head, MASK_VISIBLE, RayType_EndPoint, TraceFilter);
            bool blocked = TR_DidHit(tr);
            float frac   = TR_GetFraction(tr);
            delete tr;
            if (!blocked || frac > 0.985)
                return true;
        }

        // 2) Ray：眼睛 -> 脚
        {
            Handle tr = TR_TraceRayFilterEx(eyes, feet, MASK_VISIBLE, RayType_EndPoint, TraceFilter);
            bool blocked = TR_DidHit(tr);
            float frac   = TR_GetFraction(tr);
            delete tr;
            if (!blocked || frac > 0.985)
                return true;
        }

        // 3) 引擎可视（到胸，team_target=感染者队）
        if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
            return true;
    }
    return false; // 对所有幸存者都不可见 → 可以刷
}



stock bool TraceFilter_Stuck(int entity, int contentsMask)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    static char sClassName[20];
    GetEntityClassname(entity, sClassName, sizeof(sClassName));
    if (strcmp(sClassName, "env_physics_blocker") == 0 && !EnvBlockType(entity))
        return false;

    return true;
}
stock bool EnvBlockType(int entity)
{
    int BlockType = GetEntProp(entity, Prop_Data, "m_nBlockType");
    return !(BlockType == 1 || BlockType == 2);
}
static bool WillStuck(const float at[3])
{
    static const float mins[3] = { -16.0, -16.0, 0.0 };
    static const float maxs[3] = {  16.0,  16.0, 71.0 };
    Handle tr = TR_TraceHullFilterEx(at, at, mins, maxs, MASK_PLAYERSOLID, TraceFilter_Stuck);
    bool hit = TR_DidHit(tr);
    delete tr;
    return hit;
}
stock bool TraceFilter(int entity, int contentsMask)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    static char sClassName[9];
    GetEntityClassname(entity, sClassName, sizeof(sClassName));
    if (strcmp(sClassName, "infected") == 0 || strcmp(sClassName, "witch") == 0)
        return false;

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
static int FlowDistanceToPercent(float flowDist)
{
    float flow = flowDist / L4D2Direct_GetMapMaxFlowDistance();
    float prox = flow + gCV.VsBossFlowBuffer.FloatValue / L4D2Direct_GetMapMaxFlowDistance();
    if (prox > 1.0) prox = 1.0;
    return RoundToNearest(prox * 100.0);
}

// =========================
// 目标选择 & 跑男（简化版保留）
// =========================
static int ChooseTargetSurvivor()
{
    if (gST.bPickRushMan && IsValidSurvivor(gST.rushManIndex) && IsPlayerAlive(gST.rushManIndex) && !IsPinned(gST.rushManIndex))
        return gST.rushManIndex;

    int cand[8]; int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i) && !L4D_IsPlayerIncapacitated(i))
        {
            if (g_bTargetLimitLib && IsClientReachLimit(i))
            {
                LogMsg("[TARGET] skip %N: reach limit", i);
                continue;
            }
            cand[n++] = i; if (n >= 8) break;
        }
    }
    if (n > 0) return cand[GetRandomInt(0, n-1)];
    int fb = L4D_GetHighestFlowSurvivor();
    LogMsg("[TARGET] fallback to highest-flow %N", fb);
    return fb;
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
            if (IsPinned(c) || L4D_IsPlayerIncapacitated(c)) pinned++;
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
            if (IsPinned(target) || L4D_IsPlayerIncapacitated(target) || (surv[i] != target && GetVectorDistance(sPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0)))
            { nearAnotherSurvivor = true; break; }
        }

        if (!nearAnotherSurvivor || gST.totalSI < (gCV.iSiLimit / 2 + 1))
        {
            gST.bPickRushMan = false; gST.rushManIndex = -1;
            if (old != gST.bPickRushMan) LogMsg("Runner state OFF");
            return pinned == ns;
        }
        else
        {
            for (int i = 0; i < ni; i++)
            {
                if (IsPinned(target) || L4D_IsPlayerIncapacitated(target) || (GetVectorDistance(iPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0) * 1.3))
                {
                    gST.bPickRushMan = false; gST.rushManIndex = -1;
                    if (old != gST.bPickRushMan) LogMsg("Runner state OFF");
                    return pinned == ns;
                }
            }
        }

        gST.bPickRushMan = true;
        gST.rushManIndex = target;
        if (old != gST.bPickRushMan)
        {
            LogMsg("Runner state ON: %N", target);
            EmitRushmanForward(target);    // ← 这里触发 forward，告诉外部“检测到跑男”
        }
    }
    return pinned == ns;
}

// =========================
// Flow / 平均
// =========================
static bool IsAllKillersDown()
{
    int sum = gST.siAlive[view_as<int>(SI_Charger) - 1] + gST.siAlive[view_as<int>(SI_Hunter) - 1] + gST.siAlive[view_as<int>(SI_Jockey) - 1] + gST.siAlive[view_as<int>(SI_Smoker) - 1];
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
static float GetSurAvrFlow()
{
    int n = 0; float sum = 0.0;
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidSurvivor(i)) { sum += L4D2_GetVersusCompletionPlayer(i); n++; }
    return n > 0 ? (sum / float(n)) : 0.0;
}

// =========================
// 兜底（导演 at MaxDistance）
// =========================
static bool FallbackDirectorPosAtMax(int zc, int target, bool teleportMode, float outPos[3])
{
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
        if (minD < spawnMin || minD > spawnMax + 200.0)
            continue;

        if (IsPosVisibleSDK(pt, teleportMode))
            continue;

        if (WillStuck(pt))
            continue;

        float delta = FloatAbs(spawnMax - minD);

        bool prefer = (minD <= spawnMax);
        if (!have)
        {
            bestPt = pt; have = true; bestDelta = delta;
        }
        else
        {
            float bestMinD = GetMinDistToAnySurvivor(bestPt);
            bool bestPrefer = (bestMinD <= spawnMax);
            if ((prefer && !bestPrefer) || (prefer == bestPrefer && delta < bestDelta))
            {
                bestPt = pt; bestDelta = delta;
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
// 分散度工具（冷却/扇区/间距/并列最小随机）
// =========================
bool IsNavOnCooldown(int area, float now)
{
    if (g_NavCooldown == null) return false;

    char key[16];
    IntToString(area, key, sizeof(key));

    any stored;
    if (g_NavCooldown.GetValue(key, stored))
    {
        float until = view_as<float>(stored);
        return (now < until);
    }
    return false;
}

void TouchNavCooldown(int area, float now, float cooldown = 8.0)
{
    if (g_NavCooldown == null)
        g_NavCooldown = new StringMap();

    char key[16];
    IntToString(area, key, sizeof(key));

    g_NavCooldown.SetValue(key, view_as<any>(now + cooldown));
}

stock void CleanupLastSpawns(float now)
{
    if (lastSpawns == null) return;
    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec); // [x,y,z,t]
        if (now - rec[3] > SEP_TTL)
            lastSpawns.Erase(i);
    }
    while (lastSpawns.Length > SEP_MAX)
        lastSpawns.Erase(0);
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now = GetGameTime();
    float sep2 = SEP_RADIUS * SEP_RADIUS;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec); // [x, y, z, t]

        // 过期清理
        if (now - rec[3] > SEP_TTL)
        {
            lastSpawns.Erase(i);
            continue;
        }

        // 只取前三个分量参与距离计算
        float rec3[3];
        rec3[0] = rec[0];
        rec3[1] = rec[1];
        rec3[2] = rec[2];

        // 用平方距离避免开方
        if (GetVectorDistance(pos, rec3, true) < sep2)
            return false;
    }
    return true;
}

stock int ComputeSectorIndex(const float center[3], const float pt[3], int sectors)
{
    float dx = pt[0] - center[0];
    float dy = pt[1] - center[1];
    float ang = ArcTangent2(dy, dx); // -pi..pi
    if (ang < 0.0) ang += 2.0 * PI;

    float w = (2.0 * PI) / float(sectors);
    int idx = RoundToFloor(ang / w);
    if (idx < 0) idx = 0;
    if (idx >= sectors) idx = sectors - 1;
    return idx;
}


stock void GetSectorCenter(float outCenter[3], int targetSur)
{
    if (IsValidSurvivor(targetSur))
    {
        GetClientAbsOrigin(targetSur, outCenter);
        return;
    }

    int fb = L4D_GetHighestFlowSurvivor();
    if (IsValidSurvivor(fb))
    {
        GetClientAbsOrigin(fb, outCenter);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i))
        {
            GetClientAbsOrigin(i, outCenter);
            return;
        }
    }

    outCenter[0] = outCenter[1] = outCenter[2] = 0.0;
}

stock void RememberSpawn(const float pos[3], const float center[3])
{
    float now = GetGameTime();
    CleanupLastSpawns(now);

    float rec[4];
    rec[0] = pos[0]; rec[1] = pos[1]; rec[2] = pos[2]; rec[3] = now;
    lastSpawns.PushArray(rec);

    int sectors = GetCurrentSectors();
    int s = ComputeSectorIndex(center, pos, sectors);
    recentSectors[2] = recentSectors[1];
    recentSectors[1] = recentSectors[0];
    recentSectors[0] = s;
}

stock int ArgMinFloat(const float[] a, int n, float eps = 0.0001)
{
    if (n <= 0) return -1;

    float best = a[0];
    for (int i = 1; i < n; i++)
        if (a[i] < best) best = a[i];

    int ties = 0;
    for (int i = 0; i < n; i++)
        if (a[i] <= best + eps) ties++;

    int pick = GetRandomInt(1, ties);
    for (int i = 0; i < n; i++)
        if (a[i] <= best + eps && --pick == 0) return i;

    return 0;
}

int PickSector(int sectors)
{
    float score[SECTORS_MAX];
    for (int s = 0; s < sectors; s++)
        score[s] = GetRandomFloat(0.0, 1.0);

    if (recentSectors[0] >= 0 && recentSectors[0] < sectors) score[recentSectors[0]] += 1.5;
    if (recentSectors[1] >= 0 && recentSectors[1] < sectors) score[recentSectors[1]] += 1.0;
    if (recentSectors[2] >= 0 && recentSectors[2] < sectors) score[recentSectors[2]] += 0.5;

    return ArgMinFloat(score, sectors);
}
// 将 iSiLimit∈[1,20] → t∈[0,1]，再做 smoothstep 平滑
static float SectorPenaltyScaleByLimit()
{
    int L = gCV.iSiLimit;
    if (L < PEN_LIMIT_MINL) L = PEN_LIMIT_MINL;
    if (L > PEN_LIMIT_MAXL) L = PEN_LIMIT_MAXL;

    float t = (float(L) - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL);
    t = t * t * (3.0 - 2.0 * t);

    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

// 运行时计算当前扇区数：最低2；其余= ceil(目标T/2)+1；再夹在 [2, SECTORS_MAX]
static int GetCurrentSectors()
{
    int T = gCV.iSiLimit;
    int n = (T <= 2) ? 2 : (RoundToCeil(float(T) / 2.0) + 1);
    if (n < DYN_SECTORS_MIN) n = DYN_SECTORS_MIN;
    if (n > SECTORS_MAX)     n = SECTORS_MAX;
    return n;
}

// 把“以4扇区为基准”的罚分缩放到当前扇区数
static float ScaleBySectors(float baseAt4, int sectorsNow)
{
    return baseAt4 * (float(SECTORS_BASE) / float(sectorsNow));
}

// =========================
// Survivor数据辅助
// =========================
static bool GetSurPosData()
{
    if (g_aSurPosData != null) { delete g_aSurPosData; g_aSurPosData = null; }
    g_aSurPosData = new ArrayList(sizeof(SurPosData));
    g_iSurPosDataLen = 0; g_iSurCount = 0;

    SurPosData data;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i) && !L4D_IsPlayerIncapacitated(i))
        {
            data.fFlow = L4D2Direct_GetFlowDistance(i);
            GetClientEyePosition(i, data.fPos);
            g_aSurPosData.PushArray(data);
            g_iSurvivors[g_iSurCount++] = i;
        }
    }
    return (g_iSurPosDataLen = g_aSurPosData.Length) > 0;
}
static bool IsValidFlags(int iFlags, bool bFinaleArea)
{
    if (!iFlags)
        return true;

    if (bFinaleArea && (iFlags & TERROR_NAV_FINALE) == 0)
        return false;

    return (iFlags & (TERROR_NAV_RESCUE_CLOSET|TERROR_NAV_RESCUE_VEHICLE|TERROR_NAV_CHECKPOINT)) == 0;
}
static bool IsNearTheSur(float fSpawnRange, float fFlow, const float fPos[3], float &fDist)
{
    if (g_aSurPosData == null || g_iSurPosDataLen <= 0) return false;

    SurPosData data;
    for (int i = 0; i < g_iSurPosDataLen; i++)
    {
        g_aSurPosData.GetArray(i, data);
        if (FloatAbs(fFlow - data.fFlow) < fSpawnRange)
        {
            fDist = GetVectorDistance(data.fPos, fPos);
            if (fDist < fSpawnRange)
                return true;
        }
    }
    return false;
}

// =========================
// Nav Flow 分桶：构建 / 清理 / 计时器回调
// =========================
static void ClearNavBuckets()
{
    for (int i = 0; i < FLOW_BUCKETS; i++)
    {
        if (g_FlowBuckets[i] != null)
        {
            delete g_FlowBuckets[i];
            g_FlowBuckets[i] = null;
        }
    }
}
static void BuildNavBuckets()
{
    ClearNavBuckets();

    TheNavAreas pTheNavAreas = view_as<TheNavAreas>(g_pTheNavAreas.Dereference());
    int iAreaCount = g_pTheNavAreas.Count();

    int added = 0;
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = pTheNavAreas.GetAreaRaw(i, false);
        if (areaAddr == Address_Null) continue;

        int percent = Calculate_Flow(areaAddr);
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;

        if (g_FlowBuckets[percent] == null)
            g_FlowBuckets[percent] = new ArrayList(); // 存 NavArea 索引 i

        g_FlowBuckets[percent].Push(i);
        added++;
    }

    g_BucketsReady = true;
    Debug_Print("[BUCKET] built %d areas into 0..100 buckets", added);
}
static int ComputeDynamicBucketWindow(float ring)
{
    // 如果没启用动态联动，直接返回静态窗口
    if (!gCV.bNavBucketLinkToRing)
        return gCV.iNavBucketWindow;

    float a = gCV.fNavBucketMinAt;
    float b = gCV.fNavBucketMaxAt;
    int   w0 = gCV.iNavBucketWindowMin;
    int   w1 = gCV.iNavBucketWindowMax;

    if (b < a) { float t=a; a=b; b=t; } // 容错：交换

    float t;
    if (ring <= a)       t = 0.0;
    else if (ring >= b)  t = 1.0;
    else                 t = (ring - a) / (b - a);

    // 线性插值并四舍五入
    float w = float(w0) + (float(w1) - float(w0)) * t;
    int   win = RoundToNearest(w);

    if (win < 0)   win = 0;
    if (win > 100) win = 100;
    return win;
}

static Action Timer_RebuildBuckets(Handle timer)
{
    RebuildNavBuckets();
    return Plugin_Stop;
}
static void RebuildNavBuckets()
{
    BuildNavBuckets();
}

// =========================
// 主找点（fdxx NavArea 简化 + 分散度 + FLOW分桶）
// =========================
static bool FindSpawnPosViaNavArea(int zc, int targetSur, float searchRange, bool teleportMode, float outPos[3], int &outAreaIdx)
{
    if (!GetSurPosData())
    {
        Debug_Print("[FIND FAIL] no survivor data");
        return false;
    }

    TheNavAreas pTheNavAreas = view_as<TheNavAreas>(g_pTheNavAreas.Dereference());
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    int iAreaCount = g_pTheNavAreas.Count();
    bool bFinaleArea = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < 18;

    float center[3]; GetSectorCenter(center, targetSur);
    int sectors = GetCurrentSectors();
    int preferredSector = PickSector(sectors);
    float now = GetGameTime();

    bool found = false;
    float bestScore = 1.0e9;
    int   bestIdx = -1;
    float bestPos[3];

    int cFlagBad=0, cFlowBad=0, cNearFail=0, cVis=0, cStuck=0, cCD=0, cSep=0;

    // ====== 计算要扫描的桶集合（±Window） ======
    bool useBuckets = (gCV.bNavBucketEnable && g_BucketsReady);
    bool bucketMask[FLOW_BUCKETS];
    for (int i = 0; i < FLOW_BUCKETS; i++) bucketMask[i] = false;

    if (useBuckets)
    {
        // 动态或静态窗口
        int win = ComputeDynamicBucketWindow(searchRange);
        if (win < 0) win = 0; if (win > 100) win = 100;

        // A) 优先围绕目标幸存者的进度建桶
        if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
        {
            float tFlowDist = L4D2Direct_GetFlowDistance(targetSur);
            int s = FlowDistanceToPercent(tFlowDist);
            int lo = s - win;
            int hi = s + win;
            if (lo < 0) lo = 0;
            if (hi > 100) hi = 100;
            for (int b = lo; b <= hi; b++) bucketMask[b] = true;
        }
        else
        {
            // B) 退化为所有存活幸存者的并集（与旧行为一致）
            SurPosData data;
            for (int i = 0; i < g_iSurPosDataLen; i++)
            {
                g_aSurPosData.GetArray(i, data);
                int s = FlowDistanceToPercent(data.fFlow);
                int lo = s - win;
                int hi = s + win;
                if (lo < 0) lo = 0;
                if (hi > 100) hi = 100;
                for (int b = lo; b <= hi; b++) bucketMask[b] = true;
            }
        }
    }

    // ====== 扫描候选 NavArea（按桶或全量） ======
    if (useBuckets)
    {
        for (int b = 0; b < FLOW_BUCKETS; b++)
        {
            if (!bucketMask[b]) continue;
            if (g_FlowBuckets[b] == null) continue;

            for (int k = 0; k < g_FlowBuckets[b].Length; k++)
            {
                int i = g_FlowBuckets[b].Get(k);

                if (IsNavOnCooldown(i, now)) { cCD++; continue; }

                NavArea pArea = view_as<NavArea>(pTheNavAreas.GetAreaRaw(i, false));
                if (!pArea || !IsValidFlags(pArea.SpawnAttributes, bFinaleArea))
                { cFlagBad++; continue; }

                float fFlow = pArea.GetFlow();
                if (fFlow < 0.0 || fFlow > fMapMaxFlowDist)
                { cFlowBad++; continue; }

                float fSpawnPos[3];
                pArea.GetRandomPoint(fSpawnPos);

                float fDist;
                if (!IsNearTheSur(searchRange, fFlow, fSpawnPos, fDist))
                { cNearFail++; continue; }

                // [SpawnMin, searchRange] 窗口
                if (fDist < gCV.fSpawnMin) { cNearFail++; continue; }
                if (WillStuck(fSpawnPos)) { cStuck++; continue; }
                if (IsPosVisibleSDK(fSpawnPos, teleportMode)) { cVis++; continue; }
                if (!PassMinSeparation(fSpawnPos)) { cSep++; continue; }

                int s = ComputeSectorIndex(center, fSpawnPos, sectors);

                float prefBonus    = ScaleBySectors(SECTOR_PREF_BONUS_BASE, sectors);
                float offPenalty   = ScaleBySectors(SECTOR_OFF_PENALTY_BASE, sectors);
                float rpen0        = ScaleBySectors(RECENT_PENALTY_0_BASE, sectors);
                float rpen1        = ScaleBySectors(RECENT_PENALTY_1_BASE, sectors);
                float rpen2        = ScaleBySectors(RECENT_PENALTY_2_BASE, sectors);

                float penScaleLimit = SectorPenaltyScaleByLimit();
                offPenalty *= penScaleLimit;
                rpen0     *= penScaleLimit;
                rpen1     *= penScaleLimit;
                rpen2     *= penScaleLimit;

                float sectorPenalty = (s == preferredSector) ? prefBonus : offPenalty;
                if (recentSectors[0] == s) sectorPenalty += rpen0;
                if (recentSectors[1] == s) sectorPenalty += rpen1;
                if (recentSectors[2] == s) sectorPenalty += rpen2;

                float jitter = GetRandomFloat(0.0, RAND_JITTER_MAX);
                float score = fDist + sectorPenalty + jitter;

                if (!found || score < bestScore)
                {
                    found = true;
                    bestScore = score;
                    bestIdx = i;
                    bestPos = fSpawnPos;
                }
            }
        }
    }
    else
    {
        // 未启用分桶或桶未就绪 → 全量扫描（原逻辑）
        for (int i = 0; i < iAreaCount; i++)
        {
            if (IsNavOnCooldown(i, now)) { cCD++; continue; }

            NavArea pArea = view_as<NavArea>(pTheNavAreas.GetAreaRaw(i, false));
            if (!pArea || !IsValidFlags(pArea.SpawnAttributes, bFinaleArea))
            { cFlagBad++; continue; }

            float fFlow = pArea.GetFlow();
            if (fFlow < 0.0 || fFlow > fMapMaxFlowDist)
            { cFlowBad++; continue; }

            float fSpawnPos[3];
            pArea.GetRandomPoint(fSpawnPos);

            float fDist;
            if (!IsNearTheSur(searchRange, fFlow, fSpawnPos, fDist))
            { cNearFail++; continue; }

            if (fDist < gCV.fSpawnMin) { cNearFail++; continue; }
            if (WillStuck(fSpawnPos)) { cStuck++; continue; }
            if (IsPosVisibleSDK(fSpawnPos, teleportMode)) { cVis++; continue; }
            if (!PassMinSeparation(fSpawnPos)) { cSep++; continue; }

            int s = ComputeSectorIndex(center, fSpawnPos, sectors);

            float prefBonus    = ScaleBySectors(SECTOR_PREF_BONUS_BASE, sectors);
            float offPenalty   = ScaleBySectors(SECTOR_OFF_PENALTY_BASE, sectors);
            float rpen0        = ScaleBySectors(RECENT_PENALTY_0_BASE, sectors);
            float rpen1        = ScaleBySectors(RECENT_PENALTY_1_BASE, sectors);
            float rpen2        = ScaleBySectors(RECENT_PENALTY_2_BASE, sectors);

            float penScaleLimit = SectorPenaltyScaleByLimit();
            offPenalty *= penScaleLimit;
            rpen0     *= penScaleLimit;
            rpen1     *= penScaleLimit;
            rpen2     *= penScaleLimit;

            float sectorPenalty = (s == preferredSector) ? prefBonus : offPenalty;
            if (recentSectors[0] == s) sectorPenalty += rpen0;
            if (recentSectors[1] == s) sectorPenalty += rpen1;
            if (recentSectors[2] == s) sectorPenalty += rpen2;

            float jitter = GetRandomFloat(0.0, RAND_JITTER_MAX);
            float score = fDist + sectorPenalty + jitter;

            if (!found || score < bestScore)
            {
                found = true;
                bestScore = score;
                bestIdx = i;
                bestPos = fSpawnPos;
            }
        }
    }

    if (!found)
    {
        Debug_Print("[FIND FAIL] ring=%.1f arr=0 (flags=%d flow=%d near=%d vis=%d stuck=%d cd=%d sep=%d)%s",
            searchRange, cFlagBad, cFlowBad, cNearFail, cVis, cStuck, cCD, cSep,
            useBuckets ? " [buckets]" : "");
        return false;
    }

    outPos = bestPos;
    outAreaIdx = bestIdx;
    return true;
}


// =========================
// Spawn / Command helpers
// =========================
static bool DoSpawnAt(const float pos[3], int zc)
{
    // 绝对保险：小于 SpawnMin 一律拒绝
    if (GetMinDistToAnySurvivor(pos) < gCV.fSpawnMin)
    {
        Debug_Print("[SPAWN BLOCK] too close (< SpawnMin=%.1f) at (%.1f %.1f %.1f)",
                    gCV.fSpawnMin, pos[0], pos[1], pos[2]);
        return false;
    }

    int idx = L4D2_SpawnSpecial(zc, pos, NULL_VECTOR);
    if (idx > 0)
    {
        // 记录“最近一次成功刷出”的时间（用于超时放宽）
        g_LastSpawnOkTime = GetGameTime();

        Debug_Print("[SPAWN OK] %s idx=%d at (%.1f %.1f %.1f)", INFDN[zc], idx, pos[0], pos[1], pos[2]);
        RecalcSiCapFromAlive(false);
        return true;
    }
    Debug_Print("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d", INFDN[zc], pos[0], pos[1], pos[2], idx);
    return false;
}
static void BypassAndExecuteCommand(const char[] cmd)
{
    if (!CheatsOn()) return;
    ServerCommand("%s", cmd);
}

// =========================
// SI 选择 / 限制
// =========================
static bool CheckClassEnabled(int zc)
{
    int bit = 1 << (zc - 1);
    return (gCV.iEnableMask & bit) != 0;
}

// 重要：只按“活着的”判断是否到达每类上限（不把队列算进上限）
static bool HasReachedLimit(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= 6) return true;

    int cap = gST.siAlive[idx] + gST.siCap[idx];
    return gST.siAlive[idx] >= cap;
}
// 统计 spawn 队列中某类的数量（不含 teleport 队列）
static int CountQueuedOfClass(int zc)
{
    int n = 0;
    for (int i = 0; i < gQ.spawn.Length; i++)
    {
        if (gQ.spawn.Get(i) == zc)
            n++;
    }
    return n;
}

// 是否还能把该类加入 spawn 队列：活着 + 已入队 < 该类总额度（alive + remain）
static bool CanQueueClass(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= 6) return false;

    int capTotal = gST.siAlive[idx] + gST.siCap[idx];
    return (gST.siAlive[idx] + CountQueuedOfClass(zc)) < capTotal;
}

// =========================
// Gamedata / SDK
// =========================
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "infected_control");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    GetOffset(hGameData, g_iSpawnAttributesOffset, "TerrorNavArea::SpawnAttributes");
    GetOffset(hGameData, g_iFlowDistanceOffset, "TerrorNavArea::FlowDistance");
    GetOffset(hGameData, g_iNavCountOffset, "TheNavAreas::Count");
    
    GetAddress(hGameData, view_as<Address>(g_pTheNavAreas), "TheNavAreas");
    GetAddress(hGameData, g_pPanicEventStage, "CDirectorScriptedEventManager::m_PanicEventStage");

    // Vector CNavArea::GetRandomPoint( void ) const
    strcopy(sBuffer, sizeof(sBuffer), "TerrorNavArea::FindRandomSpot");
    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, sBuffer);
    PrepSDKCall_SetReturnInfo(SDKType_Vector, SDKPass_ByValue);
    g_hSDKFindRandomSpot = EndPrepSDKCall();
    if(g_hSDKFindRandomSpot == null)
        SetFailState("Failed to create SDKCall: %s", sBuffer);

    // IsVisibleToPlayer(Vector const&, CBasePlayer *, int, int, float, CBaseEntity const*, TerrorNavArea **, bool *);
    strcopy(sBuffer, sizeof(sBuffer), "IsVisibleToPlayer");
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, sBuffer);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);            // target position
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);     // client
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);      // client team
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);      // target position team
    PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);             // unknown
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);      // unknown
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer);    // target position NavArea
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Pointer);            // auto get NavArea if false
    PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
    g_hSDKIsVisibleToPlayer = EndPrepSDKCall();
    if (g_hSDKIsVisibleToPlayer == null)
        SetFailState("Failed to create SDKCall: %s", sBuffer);

    // Unlock Max SI limit.
    strcopy(sBuffer, sizeof(sBuffer), "CDirector::GetMaxPlayerZombies");
    MemoryPatch mPatch = MemoryPatch.CreateFromConf(hGameData, sBuffer);
    if (!mPatch.Validate())
        SetFailState("Failed to verify patch: %s", sBuffer);
    if (!mPatch.Enable())
        SetFailState("Failed to Enable patch: %s", sBuffer);

    delete hGameData;
}
void GetOffset(GameData hGameData, int &offset, const char[] name)
{
    offset = hGameData.GetOffset(name);
    if (offset == -1)
        SetFailState("Failed to get offset: %s", name);
}
void GetAddress(GameData hGameData, Address &address, const char[] name)
{
    address = hGameData.GetAddress(name);
    if (address == Address_Null)
        SetFailState("Failed to get address: %s", name);
}

// --- Math helpers --- 
stock float FloatMax(float a, float b) { return (a > b) ? a : b; } 
stock float FloatMin(float a, float b) { return (a < b) ? a : b; }
stock float Clamp01(float v) { if (v < 0.0) return 0.0; if (v > 1.0) return 1.0; return v; }

// --- pause
public void OnPause()
{
    PauseSpawnTimer();
}
static bool CheatsOn()
{
    ConVar sv = FindConVar("sv_cheats");
    return (sv != null && sv.BoolValue);
}

static void EmitRushmanForward(int survivor)
{
    if (g_hRushManNotifyForward != INVALID_HANDLE)
    {
        Call_StartForward(g_hRushManNotifyForward);
        Call_PushCell(survivor);   // 跑男目标
        Call_Finish();
    }
}
