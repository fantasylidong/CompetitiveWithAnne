#pragma semicolon 1 
#pragma newdecls required

/**
 * Infected Control (fdxx-style NavArea spot picking + max-distance fallback + 动态FLOW分桶)
 * - Nav 分桶：开局预扫全图 NavArea，按“进度百分比(0..100)”分桶
 *   - 选点仅在【目标幸存者附近 ±N 桶】里扫描（N 随 ring 动态从 Min→Max 线性变化）
 *   - 严格按中心向外成对扩散顺序扫描：s-1, s+1, s-2, s+2, ...（可选是否包含中心 s）
 *   - 支持 First-Fit 模式：命中第一处合格点立即返回，最大化速度
 * - 主找点（唯一）：TerrorNavArea::FindRandomSpot
 *   - 距离窗口（SpawnMin..ring）
 *   - 视线不可见（眼/脚/SDK 可视）
 *   - Hull 不会卡（WillStuck）
 *   - 轻量分散度（扇区偏好+最近点距离）
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

// =========================
// 常量/宏
// =========================
#define CVAR_FLAG                 FCVAR_NOTIFY
#define TEAM_SURVIVOR             2
#define TEAM_INFECTED             3
#define NAV_MESH_HEIGHT           20.0
#define PLAYER_CHEST              45.0

#define BAIT_DISTANCE             200.0
#define RING_SLACK                350.0
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
#define SUPPORT_SPAWN_DELAY_SECS  1.0
#define SUPPORT_NEED_KILLERS      1

// —— 分散度四件套参数 —— //
#define PI                        3.1415926535
#define SEP_TTL                   3.0    // 最近刷点保留秒数
//#define SEP_MAX                   20     // 记录上限（防止无限增长）
// === Dispersion tuning (lighter penalties) ===
#define SEP_RADIUS                100.0
#define NAV_CD_SECS               0.6
#define SECTORS_BASE              4       // 基准
#define SECTORS_MAX               8       // 动态上限（建议 6~8 之间）
#define DYN_SECTORS_MIN           2       // 动态下限
#define PATH_NO_BUILD_PENALTY     1999.0

// === Dispersion tuning (penalties at BASE=4) ===
#define SECTOR_PREF_BONUS_BASE   -8.0
#define SECTOR_OFF_PENALTY_BASE   4.0
#define RECENT_PENALTY_0_BASE     3.6
#define RECENT_PENALTY_1_BASE     2.4
#define RECENT_PENALTY_2_BASE     2.0

// 可调参数（想热调也能做成 CVar，这里先给常量）
#define PEN_LIMIT_SCALE_HI        1.00   // L=1 时：正向惩罚略强一点
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
// —— Nav 高度“核心”缓存 & 每桶高度范围 —— //
static ArrayList g_AreaZCore = null;   // float per areaIdx（核心高度=多次随机点的 z 均值）
static ArrayList g_AreaZMin  = null;   // float per areaIdx
static ArrayList g_AreaZMax  = null;   // float per areaIdx
static float g_BucketMinZ[FLOW_BUCKETS];
static float g_BucketMaxZ[FLOW_BUCKETS];
static float g_LastSpawnTime[MAXPLAYERS+1];

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
        // 更安全的读取：按位解释为 float
        return view_as<float>(LoadFromAddress(view_as<Address>(this) + view_as<Address>(g_iFlowDistanceOffset), NumberType_Int32));
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

    // —— 分桶策略增强 —— //
    ConVar NavBucketFirstFit;     // 找到第一个合格点就返回
    ConVar NavBucketIncludeCtr;   // 是否包含中心桶 s

    // —— 新增：死亡CD（两档） —— //
    ConVar DeathCDKiller;        
    ConVar DeathCDSupport;       

    // —— 新增：死亡CD放宽的“双保险” —— //
    ConVar DeathCDBypassAfter;   
    ConVar DeathCDUnderfill;     

    ConVar ZSmokerLimit;
    ConVar ZBoomerLimit;
    ConVar ZHunterLimit;
    ConVar ZSpitterLimit;
    ConVar ZJockeyLimit;
    ConVar ZChargerLimit;
    ConVar TeleportSpawnGrace;   // 新刷出来后多少秒内不允许传送
    ConVar TeleportRunnerFast;   // 跑男时的快速阈值（秒），最低也要有个门槛
    float  fTeleportSpawnGrace;
    float  fTeleportRunnerFast;

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

    // —— 分桶策略增强 —— //
    bool  bNavBucketFirstFit;
    bool  bNavBucketIncludeCtr;

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
        this.DebugMode         = CreateConVar("inf_DebugMode", "0","0=off,1=log,2=console+log,3=console+log(+beam)", CVAR_FLAG, true, 0.0, true, 3.0);

        // —— Nav 分桶（静态窗口） —— //
        this.NavBucketEnable   = CreateConVar("inf_NavBucketEnable", "1", "启用 Nav 进度分桶筛选(0=禁用,1=启用)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketWindow   = CreateConVar("inf_NavBucketWindow", "10", "按进度百分比搜索的桶半径(±N)", CVAR_FLAG, true, 0.0, true, 100.0);

        // —— 动态分桶（新增） —— //
        this.NavBucketLinkToRing = CreateConVar("inf_NavBucketLinkToRing", "1", "扩圈时动态调整桶窗口(0=关闭,1=开启)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketWindowMin  = CreateConVar("inf_NavBucketWindowMin", "6", "ring<=MinAt时使用的桶窗口(±N)", CVAR_FLAG, true, 0.0, true, 100.0);
        this.NavBucketWindowMax  = CreateConVar("inf_NavBucketWindowMax", "12", "ring>=MaxAt时使用的桶窗口(±N)", CVAR_FLAG, true, 0.0, true, 100.0);
        this.NavBucketMinAt      = CreateConVar("inf_NavBucketMinAt", "500.0", "小桶阈值对应的ring", CVAR_FLAG, true, 0.0);
        this.NavBucketMaxAt      = CreateConVar("inf_NavBucketMaxAt", "1500.0", "大桶阈值对应的ring", CVAR_FLAG, true, 0.0);

        // —— 分桶策略增强 —— //
        this.NavBucketFirstFit   = CreateConVar("inf_NavBucketFirstFit", "0",  "找到第一个合格点就返回(1=是,0=否)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketIncludeCtr = CreateConVar("inf_NavBucketIncludeCenter", "1", "是否把中心桶 s 也加入扫描序列(1=是,0=否)", CVAR_FLAG, true, 0.0, true, 1.0);

        // —— 死亡CD —— //
        this.DeathCDKiller     = CreateConVar("inf_DeathCooldownKiller",  "2.0","同类击杀后最小补位CD（秒）：Hunter/Smoker/Jockey/Charger", CVAR_FLAG, true, 0.0, true, 30.0);
        this.DeathCDSupport    = CreateConVar("inf_DeathCooldownSupport", "2.0","同类击杀后最小补位CD（秒）：Boomer/Spitter", CVAR_FLAG, true, 0.0, true, 30.0);

        // —— 双保险 —— //
        this.DeathCDBypassAfter = CreateConVar("inf_DeathCooldown_BypassAfter", "1.5","距离上次成功刷出超过该秒数时，临时忽略死亡CD", CVAR_FLAG, true, 0.0, true, 10.0);
        this.DeathCDUnderfill   = CreateConVar("inf_DeathCooldown_Underfill", "0.5","当【场上活着特感】< iSiLimit * 本值 时，忽略死亡CD", CVAR_FLAG, true, 0.0, true, 1.0);
        this.TeleportSpawnGrace = CreateConVar("inf_TeleportSpawnGrace", "2.5",
            "特感生成后多少秒内禁止传送", CVAR_FLAG, true, 0.0, true, 10.0);
        this.TeleportRunnerFast = CreateConVar("inf_TeleportRunnerFast", "1.5",
            "跑男时的快速传送阈值（秒），仍需达到该不可见时长才可传送", CVAR_FLAG, true, 0.0, true, 10.0);

        this.TeleportSpawnGrace.AddChangeHook(OnCfgChanged);
        this.TeleportRunnerFast.AddChangeHook(OnCfgChanged);
        this.MaxPlayerZombies  = FindConVar("z_max_player_zombies");
        this.VsBossFlowBuffer  = FindConVar("versus_boss_buffer");
        this.ZSmokerLimit  = FindConVar("z_smoker_limit");
        this.ZBoomerLimit  = FindConVar("z_boomer_limit");
        this.ZHunterLimit  = FindConVar("z_hunter_limit");
        this.ZSpitterLimit = FindConVar("z_spitter_limit");
        this.ZJockeyLimit  = FindConVar("z_jockey_limit");
        this.ZChargerLimit = FindConVar("z_charger_limit");
        this.DeathCDKiller.AddChangeHook(OnCfgChanged);
        this.DeathCDSupport.AddChangeHook(OnCfgChanged);
        this.DeathCDBypassAfter.AddChangeHook(OnCfgChanged);
        this.DeathCDUnderfill.AddChangeHook(OnCfgChanged);

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
        this.NavBucketFirstFit.AddChangeHook(OnCfgChanged);
        this.NavBucketIncludeCtr.AddChangeHook(OnCfgChanged);

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

        // 分桶策略增强
        this.bNavBucketFirstFit   = this.NavBucketFirstFit.BoolValue;
        this.bNavBucketIncludeCtr = this.NavBucketIncludeCtr.BoolValue;

        // 死亡CD & 放宽
        this.fDeathCDKiller     = this.DeathCDKiller.FloatValue;
        this.fDeathCDSupport    = this.DeathCDSupport.FloatValue;
        this.fDeathCDBypassAfter= this.DeathCDBypassAfter.FloatValue;
        this.fDeathCDUnderfill  = this.DeathCDUnderfill.FloatValue;
        this.fTeleportSpawnGrace = this.TeleportSpawnGrace.FloatValue;
        this.fTeleportRunnerFast = this.TeleportRunnerFast.FloatValue;
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
        for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
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
    version     = "2025.09.07-buckets-ordered",
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
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
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
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
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
    if (!client || !IsClientInGame(client) || !IsFakeClient(client)) return;

    g_LastSpawnTime[client] = GetGameTime();     // ★ 记录出生时间
    gST.teleCount[client]   = 0;                 // ★ 清计数，避免继承旧值

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
        // —— 这里改成“只在未处于冷却期时触发一次CD”，冷却中死亡不重置 —— //
        TouchDeathCooldownOnce(zc);

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

    // 立刻按新上限收缩记录
    CleanupLastSpawns(GetGameTime());
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
    baseCap[0] = gCV.ZSmokerLimit.IntValue;
    baseCap[1] = gCV.ZBoomerLimit.IntValue;
    baseCap[2] = gCV.ZHunterLimit.IntValue;
    baseCap[3] = gCV.ZSpitterLimit.IntValue;
    baseCap[4] = gCV.ZJockeyLimit.IntValue;
    baseCap[5] = gCV.ZChargerLimit.IntValue;

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
    gST.siCap[0] = gCV.ZSmokerLimit.IntValue;
    gST.siCap[1] = gCV.ZBoomerLimit.IntValue;
    gST.siCap[2] = gCV.ZHunterLimit.IntValue;
    gST.siCap[3] = gCV.ZSpitterLimit.IntValue;
    gST.siCap[4] = gCV.ZJockeyLimit.IntValue;
    gST.siCap[5] = gCV.ZChargerLimit.IntValue;

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

// 仅在“无活动冷却”时开启一次死亡CD；若已在CD中则忽略本次死亡
static void TouchDeathCooldownOnce(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= 6) return;

    float need = IsSupportClassInt(zc) ? gCV.fDeathCDSupport : gCV.fDeathCDKiller;
    if (need <= 0.01)
    {
        // 冷却为 0 时不做限制；保持可立即补位
        g_LastDeathTime[idx] = 0.0;
        return;
    }

    float now  = GetGameTime();
    float last = g_LastDeathTime[idx];

    // 若从未启动过，或上一个冷却已结束 → 以“本次死亡”启动新的冷却
    if (last <= 0.01 || (now - last) >= need)
    {
        g_LastDeathTime[idx] = now;
        Debug_Print("[DEATHCD] start %s at %.2f (CD=%.2f)", INFDN[zc], now, need);
    }
    else
    {
        // 仍在冷却期：忽略，不刷新时间戳（不把CD往后推）
        Debug_Print("[DEATHCD] ignore %s death at %.2f (remain=%.2f)",
            INFDN[zc], now, need - (now - last));
    }
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
// ===========================
// 单次正常生成尝试（fdxx-NavArea 主路）— 改：DoSpawnAt 失败给 NavArea 短冷却
// ===========================
static void TryNormalSpawnOnce()
{
    static const float EPS_RADIUS = 1.0;

    int want = gQ.spawn.Get(0);

    // 生成前“只看活着的”上限闸门
    if (HasReachedLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", INFDN[want]);
        gQ.spawn.Erase(0);
        gST.spawnQueueSize--;
        return;
    }

    // 死亡CD：若队头处于死亡CD且当前不放宽，则旋转到末尾
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

    bool triedSpawn = false;
    bool spawnOk = false;

    if (ok)
    {
        triedSpawn = true;
        spawnOk = DoSpawnAt(pos, want);
    }

    if (ok && spawnOk)
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
    else
    {
        // —— 新增：若确实调用了 DoSpawnAt 且失败，并且拿到了 NavArea 编号，则给该 Area 一个短失败冷却 —— //
        if (triedSpawn && !spawnOk && areaIdx >= 0)
            TouchNavCooldown(areaIdx, GetGameTime(), 0.8);
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

    bool triedSpawn = false;
    bool spawnOk = false;

    if (ok)
    {
        triedSpawn = true;
        spawnOk = DoSpawnAt(pos, want);
    }

    if (ok && spawnOk)
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
    else
    {
        // —— 新增：若确实调用了 DoSpawnAt 且失败，并且拿到了 NavArea 编号，则给该 Area 一个短失败冷却 —— //
        if (triedSpawn && !spawnOk && areaIdx >= 0)
            TouchNavCooldown(areaIdx, GetGameTime(), 0.8);
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
            gST.hSpawn = CreateTimer(gCV.fSiInterval * 1.5, Timer_StartNewWave);
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
            gST.hSpawn = CreateTimer(gCV.fSiInterval, Timer_StartNewWave);
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
        gST.hSpawn = CreateTimer(delay, Timer_StartNewWave);
        Debug_Print("Resume spawn in %.2f", delay);
    }
}

// =========================
// 传送监督（1s）—接入 pause / ai_smoker_new
// =========================
// ===========================
// 传送监督（1s）— 加入“出生宽限 + 跑男最小不可见秒数”
// 依赖：g_LastSpawnTime[]、gCV.fTeleportSpawnGrace、gCV.fTeleportRunnerFast（若未加 CVar，也可设默认值为 0.0）
// ===========================
static Action Timer_TeleportTick(Handle timer)
{
    if (g_bPauseLib && IsInPause())
        return Plugin_Continue;

    // 全队被控或倒地：暂停传送监督
    if (CheckRushManAndAllPinned())
        return Plugin_Continue;

    float now = GetGameTime();

    for (int c = 1; c <= MaxClients; c++)
    {
        // 基本资格
        if (!CanBeTeleport(c))
            continue;

        // —— 出生宽限（避免“刚生成就传送”）——
        // 若你尚未把宽限接到 CanBeTeleport，这里再兜一层
        if (gCV.fTeleportSpawnGrace > 0.0)
        {
            float born = g_LastSpawnTime[c];  // 需要在 evt_PlayerSpawn 中记录
            if (born > 0.0 && (now - born) < gCV.fTeleportSpawnGrace)
            {
                // 宽限期内不累计不可见秒数，重置计数防止溢出
                if (gST.teleCount[c] != 0) gST.teleCount[c] = 0;
                continue;
            }
        }

        // 视线检测（以“眼睛”为目标点，与 IsPosVisibleSDK 的口径一致）
        float eyes[3];
        GetClientEyePosition(c, eyes);
        bool vis = IsPosVisibleSDK(eyes, true);

        if (!vis)
        {
            // 第一次入队前，重置传送找点半径
            if (gST.teleportQueueSize == 0)
                gST.teleportDistCur = gCV.fSpawnMin;

            // Smoker 能力未就绪则不传（避免浪费），并清空计数
            int zc = GetInfectedClass(c);
            if (zc == view_as<int>(SI_Smoker) && g_bSmokerLib)
            {
                if (!isSmokerReadyToAttack(c))
                {
                    if (gST.teleCount[c] % 5 == 0)
                        LogMsg("[TP] smoker %N: ability not ready -> skip teleport (tick=%d)", c, gST.teleCount[c]);
                    gST.teleCount[c] = 0;
                    continue;
                }
            }

            // —— 累计不可见秒数（本计时器 1s 调一次）——
            gST.teleCount[c]++;

            // 计算本次需要的不可见阈值（秒）
            // 常规：iTeleportCheckTime；跑男快通道：min(常规, TeleportRunnerFast)，但不低于 0.8s
            float needSecs = float(gCV.iTeleportCheckTime);
            bool  runnerFastPath = (gST.bPickRushMan && gST.teleportQueueSize == 0);
            if (runnerFastPath && gCV.fTeleportRunnerFast > 0.0)
            {
                if (gCV.fTeleportRunnerFast < needSecs)
                    needSecs = gCV.fTeleportRunnerFast;
            }
            if (needSecs < 0.8) needSecs = 0.8; // 防止“闪现即传”

            // 达标：进入传送队列
            if (float(gST.teleCount[c]) >= needSecs)
            {
                int zcx = GetInfectedClass(c);
                if (zcx >= 1 && zcx <= 6)
                {
                    gQ.teleport.Push(zcx);
                    gST.teleportQueueSize++;

                    // 从“在场计数”里扣除（保持与原逻辑一致）
                    if (gST.siAlive[zcx-1] > 0) gST.siAlive[zcx-1]--; else gST.siAlive[zcx-1] = 0;
                    if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;

                    LogMsg("[TP] %N class=%s invisible for %.1f sec%s -> teleport respawn",
                           c, INFDN[zcx], float(gST.teleCount[c]),
                           runnerFastPath ? " (runner-fast)" : "");

                    // 踢掉原实体，进入传送重生流程
                    KickClient(c, "Teleport SI");

                    // 立刻刷新上限/剩余额度
                    RecalcSiCapFromAlive(false);

                    // 清零计数，避免残留
                    gST.teleCount[c] = 0;
                }
            }
        }
        else
        {
            // 再次可见：每 5s 打一条复位日志，并清零计数
            if (gST.teleCount[c] > 0 && (gST.teleCount[c] % 5 == 0))
                LogMsg("[TP] %N visible again (reset tick=%d)", c, gST.teleCount[c]);

            gST.teleCount[c] = 0;
        }
    }

    // 周期性刷新目标幸存者
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
/**
* 检查 Smoker 技能是否冷却完毕
* @param client 客户端索引
* @return bool 是否冷却完毕
**/
stock bool isSmokerReadyToAttack(int client) {
	if (!IsAiSmoker(client))
		return false;

	static int ability;
	ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
	if (!IsValidEdict(ability))
		return false;
	static char clsName[32];
	GetEntityClassname(ability, clsName, sizeof(clsName));
	if (strcmp(clsName, "ability_tongue", false) != 0)
		return false;
	
	static float timestamp;
	timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
	return GetGameTime() >= timestamp;
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
    if (GetEntProp(client, Prop_Send, "m_zombieClass") == 8)  // Tank
        return false;
    if (IsPinningSomeone(client))
        return false;

    // ★ 新增：出生宽限（统一闸门）
    if (gCV.fTeleportSpawnGrace > 0.0)
    {
        float born = g_LastSpawnTime[client];
        if (born > 0.0 && (GetGameTime() - born) < gCV.fTeleportSpawnGrace)
            return false;
    }

    if (IsSpitter(client) && (GetGameTime() - gST.spitterSpitTime[client]) < SPIT_INTERVAL)
        return false;

    if (GetClosestSurvivorDistance(client) < gCV.fSpawnMin)
        return false;

    if (IsAiSmoker(client) && g_bSmokerLib && !isSmokerReadyToAttack(client))
        return false;

    float p[3];
    GetClientAbsOrigin(client, p);
    if (IsPosAheadOfHighest(p))
        return false;

    return true;
}

static bool IsPosVisibleSDK(float pos[3], bool teleportMode)
{
    // 头/胸/脚大致对应 SI 模型高度
    float head[3], chest[3], feet[3];
    head = pos;  head[2]  += 62.0;
    chest = pos; chest[2] += 32.0;
    feet = pos;  feet[2]  +=  8.0;

    // 交集掩码：只把“既挡视线又挡子弹”的东西当作阻挡
    const int visMask = (MASK_VISIBLE & MASK_SHOT);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;
        if (teleportMode && L4D_IsPlayerIncapacitated(i) && gCV.bIgnoreIncapSight)
            continue;

        float eyes[3]; 
        GetClientEyePosition(i, eyes);

        // 1) Ray: 眼睛 -> 头
        Handle tr1 = TR_TraceRayFilterEx(eyes, head, visMask, RayType_EndPoint, TraceFilter);
        bool block1 = TR_DidHit(tr1);
        float frac1 = TR_GetFraction(tr1);
        delete tr1;
        if (!block1 || frac1 >= 0.99)   // 基本贯通 → 可见
            return true;

        // 2) Ray: 眼睛 -> 脚
        Handle tr2 = TR_TraceRayFilterEx(eyes, feet, visMask, RayType_EndPoint, TraceFilter);
        bool block2 = TR_DidHit(tr2);
        float frac2 = TR_GetFraction(tr2);
        delete tr2;
        if (!block2 || frac2 >= 0.99)
            return true;

        // 3) 引擎可视：到胸（team_target=INFECTED → 不考虑朝向，更保守）
        if (L4D2_IsVisibleToPlayer(i, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
            return true;
    }
    // 对所有存活幸存者都“不可见” → 允许刷
    return false;
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
// 兜底（导演 at MaxDistance）— 安全版：容错 target 无效
// =========================
static bool FallbackDirectorPosAtMax(int zc, int target, bool teleportMode, float outPos[3])
{
    const int kTries = 48;

    float bestPt[3];
    bool  have = false;
    float bestDelta = 999999.0;

    float spawnMax = gCV.fSpawnMax;
    float spawnMin = gCV.fSpawnMin;

    // --- 1) 选一个“有效目标幸存者”作为参考（容错 target=-1/已死/未初始化） ---
    int tgt = target;
    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
        tgt = L4D_GetHighestFlowSurvivor();

    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        // 再扫一遍找任何还活着的幸存者
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsValidSurvivor(i) && IsPlayerAlive(i)) { tgt = i; break; }
        }
    }

    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        // 场上没有可用幸存者，兜底无意义 → 返回失败，避免无效 GetClientAbsOrigin
        Debug_Print("[FALLBACK] no valid survivor to reference, abort");
        return false;
    }

    // --- 2) 以该幸存者脚底所在区域作为大致参考（求一个邻近 nav） ---
    float tFeet[3];
    GetClientAbsOrigin(tgt, tFeet);

    Address navTarget = L4D2Direct_GetTerrorNavArea(tFeet);
    if (navTarget == Address_Null)
        navTarget = view_as<Address>(L4D_GetNearestNavArea(tFeet, 300.0, false, false, false, TEAM_INFECTED));

    if (navTarget == Address_Null)
    {
        Debug_Print("[FALLBACK] no nav near survivor feet, abort");
        return false;
    }

    // --- 3) 用导演随机点反复取样，挑一个接近 spawnMax 的、看不见/不卡的点 ---
    for (int i = 0; i < kTries; i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(tgt, zc, 7, pt))
            continue;

        float minD = GetMinDistToAnySurvivor(pt); // 脚底距离；硬下限用眼睛距离在 DoSpawnAt 再把关
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

            // 优先选“<=spawnMax”的，再比谁更接近 spawnMax
            if ((prefer && !bestPrefer) || (prefer == bestPrefer && delta < bestDelta))
            {
                bestPt = pt; bestDelta = delta;
            }
        }
    }

    if (!have)
        return false;

    outPos[0] = bestPt[0];
    outPos[1] = bestPt[1];
    outPos[2] = bestPt[2];
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

    // 先按时间 (SEP_TTL) 清
    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec); // [x,y,z,t]
        if (now - rec[3] > SEP_TTL)
            lastSpawns.Erase(i);
    }

    // 再按“数量上限 = iSiLimit”裁旧
    int cap = GetSepMax();
    while (lastSpawns.Length > cap)
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

// 高度感知的 ring 弹性：越高 → 弹性越大，最多到 2*RING_SLACK；
// 若明显高出所有幸存者眼睛很多，再做衰减避免“屋顶滥刷”。
static float HeightRingSlack(const float p[3], float bucketMinZ, float bucketMaxZ, float allMaxEyeZ)
{
    float zRange = bucketMaxZ - bucketMinZ;
    if (zRange < 1.0) zRange = 1.0;

    // 桶内高度归一化（越高越接近 1）
    float zNorm  = (p[2] - bucketMinZ) / zRange;
    if (zNorm < 0.0) zNorm = 0.0;
    if (zNorm > 1.0) zNorm = 1.0;

    // 基础弹性：线性从 0..zRange
    float base = FloatMin(zRange + 50.0, RING_SLACK * 2.0) * zNorm;

    // 若高于“所有幸存者最大眼睛高度 + 200u”，对弹性做衰减，避免极端屋顶无限放宽
    float over   = FloatMax(0.0, p[2] - (allMaxEyeZ + 200.0));
    float taper  = 1.0 / (1.0 + over / 150.0);  // 100u 每级衰减
    return base * taper;
}

// =========================
// Nav Flow 分桶：构建 / 清理 / 计时器回调
// =========================
static void ClearNavBuckets()
{
    for (int i = 0; i < FLOW_BUCKETS; i++)
    {
        if (g_FlowBuckets[i] != null) { delete g_FlowBuckets[i]; g_FlowBuckets[i] = null; }
        g_BucketMinZ[i] = 0.0;
        g_BucketMaxZ[i] = 0.0;
    }

    if (g_AreaZCore != null) { delete g_AreaZCore; g_AreaZCore = null; }
    if (g_AreaZMin  != null) { delete g_AreaZMin;  g_AreaZMin  = null; }
    if (g_AreaZMax  != null) { delete g_AreaZMax;  g_AreaZMax  = null; }
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

// —— 新版：前2后1推进；若前>后差距>4，则前批量+1、后批量+1 ——
// 例：+1,+2,-1,+3,+4,-2,+5,+6,-3,...；当前累计比后累计多 >4 时→
//     下一轮起批量从 (FwdRun,BackRun) 变为 (FwdRun+1, BackRun+1)。
static int BuildBucketOrder(int s, int win, bool includeCenter, int outBuckets[FLOW_BUCKETS])
{
    if (win < 0)  win = 0;
    if (win > 100) win = 100;
    if (s < 0) s = 0;
    if (s > 100) s = 100;

    int n = 0;
    if (includeCenter && 0 <= s && s <= 100)
        outBuckets[n++] = s;

    // 距离指针（相对桶）
    int fdist = 1; // 向前：s+1, s+2, ...
    int bdist = 1; // 向后：s-1, s-2, ...

    // 每轮批量（动态调整）
    int fwdRun = 2;  // 初始“前2”
    int backRun = 1; // 初始“后1”

    // 已实际添加的前/后计数（考虑边界过滤后有效入列数量）
    int addedF = 0;
    int addedB = 0;

    while ((fdist <= win || bdist <= win) && n < FLOW_BUCKETS)
    {
        // 先推一轮“前 fwdRun”
        int pushedF = 0;
        for (int k = 0; k < fwdRun && fdist <= win && n < FLOW_BUCKETS; k++, fdist++)
        {
            int b = s + fdist;
            if (b <= 100) { outBuckets[n++] = b; pushedF++; }
        }
        addedF += pushedF;

        // 再推一轮“后 backRun”
        int pushedB = 0;
        for (int k = 0; k < backRun && bdist <= win && n < FLOW_BUCKETS; k++, bdist++)
        {
            int a = s - bdist;
            if (a >= 0) { outBuckets[n++] = a; pushedB++; }
        }
        addedB += pushedB;

        // 如果“前面累计 - 后面累计”> 4，则从下一轮起扩大两侧批量（前+1 / 后+1）
        if ((addedF - addedB) > 4)
        {
            fwdRun++;
            backRun++;
        }
    }

    return n;
}
static void BuildNavBuckets()
{
    ClearNavBuckets();

    TheNavAreas pTheNavAreas = view_as<TheNavAreas>(g_pTheNavAreas.Dereference());
    int iAreaCount = g_pTheNavAreas.Count();

    // 预分配高度缓存
    g_AreaZCore = new ArrayList();
    g_AreaZMin  = new ArrayList();
    g_AreaZMax  = new ArrayList();
    for (int i = 0; i < iAreaCount; i++) { g_AreaZCore.Push(0.0); g_AreaZMin.Push(0.0); g_AreaZMax.Push(0.0); }

    for (int b = 0; b < FLOW_BUCKETS; b++) { g_BucketMinZ[b] =  1.0e9; g_BucketMaxZ[b] = -1.0e9; }

    int added = 0;

    // 1) 遍历 NavArea：计算每个 area 的进度桶 + 高度信息
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = pTheNavAreas.GetAreaRaw(i, false);
        if (areaAddr == Address_Null) continue;

        int percent = Calculate_Flow(areaAddr);
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;

        // 估核心高度
        float zAvg, zMin, zMax;
        SampleAreaZ(areaAddr, zAvg, zMin, zMax, 3);
        g_AreaZCore.Set(i, zAvg);
        g_AreaZMin.Set(i,  zMin);
        g_AreaZMax.Set(i,  zMax);

        if (g_FlowBuckets[percent] == null)
            g_FlowBuckets[percent] = new ArrayList(); // 存 NavArea 索引 i

        g_FlowBuckets[percent].Push(i);

        // 维护每桶的高度范围
        if (zMin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zMin;
        if (zMax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zMax;

        added++;
    }

    // 2) 每个桶内：按核心高度从高到低排序
    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        ArrayList L = g_FlowBuckets[b];
        if (L == null) continue;
        int n = L.Length;
        // 简单冒泡即可，构建只做一次（地图开局/重建）
        for (int i = 0; i < n - 1; i++)
        {
            for (int j = 0; j < n - 1 - i; j++)
            {
                int ia = L.Get(j);
                int ib = L.Get(j + 1);
                float za = view_as<float>(g_AreaZCore.Get(ia));
                float zb = view_as<float>(g_AreaZCore.Get(ib));
                if (za < zb)
                {
                    // 交换
                    int tmp = ia;
                    L.Set(j, ib);
                    L.Set(j + 1, tmp);
                }
            }
        }

        // 桶空的话把 min/max 回补为 0，避免 NAN
        if (n == 0) { g_BucketMinZ[b] = 0.0; g_BucketMaxZ[b] = 0.0; }
        // 高度范围异常也做保护
        if (g_BucketMinZ[b] > g_BucketMaxZ[b]) { g_BucketMinZ[b] = g_BucketMaxZ[b] = 0.0; }
    }

    g_BucketsReady = true;
    Debug_Print("[BUCKET] built %d areas into 0..100 buckets (sorted by core-z desc)", added);
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

// ===========================
// 主找点（fdxx NavArea 简化 + 分散度 + FLOW分桶）— 修改版
// - 桶内按“核心高度”从高到低迭代
// - 极值兜底：地底且后方 / 过高极端（Smoker 例外）→ 硬拒
// - 新增“高度偏好”与“前/后均衡偏置”
// ===========================
static bool FindSpawnPosViaNavArea(int zc, int targetSur, float searchRange, bool teleportMode, float outPos[3], int &outAreaIdx)
{
    const int TOPK = 12;                 // 保持与你原本相同的候选上限
    int acceptedHits = 0;

    if (!GetSurPosData())
    {
        Debug_Print("[FIND FAIL] no survivor data");
        return false;
    }

    // ====== 基础上下文 ======
    TheNavAreas pTheNavAreas = view_as<TheNavAreas>(g_pTheNavAreas.Dereference());
    float fMapMaxFlowDist    = L4D2Direct_GetMapMaxFlowDistance();
    int   iAreaCount         = g_pTheNavAreas.Count();
    bool  bFinaleArea        = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < 18;

    float center[3]; GetSectorCenter(center, targetSur);
    int   sectors            = GetCurrentSectors();
    int   preferredSector    = PickSector(sectors);
    float now                = GetGameTime();

    // ===== 统计：你原先已经做的 —— 复用，不再重复遍历 =====
    float allMinZ  =  1.0e9;
    float allMaxZ  = -1.0e9;
    int   allMinFlowBucket = 100; // 越小越靠后
    {
        SurPosData data;
        for (int si = 0; si < g_iSurPosDataLen; si++)
        {
            g_aSurPosData.GetArray(si, data);
            if (data.fPos[2] < allMinZ) allMinZ = data.fPos[2];
            if (data.fPos[2] > allMaxZ) allMaxZ = data.fPos[2];

            int sb = FlowDistanceToPercent(data.fFlow);
            if (sb < allMinFlowBucket) allMinFlowBucket = sb;
        }
    }

    // 中心桶（用于构造扫描序列）
    int centerBucket = 50;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        float tFlowDist = L4D2Direct_GetFlowDistance(targetSur);
        centerBucket = FlowDistanceToPercent(tFlowDist);
    }
    else
    {
        float bestFlow = -1.0;
        SurPosData data2;
        for (int si = 0; si < g_iSurPosDataLen; si++)
        {
            g_aSurPosData.GetArray(si, data2);
            if (data2.fFlow > bestFlow) bestFlow = data2.fFlow;
        }
        if (bestFlow > 0.0) centerBucket = FlowDistanceToPercent(bestFlow);
    }

    bool  found     = false;
    float bestScore = 1.0e9;
    int   bestIdx   = -1;
    float bestPos[3];

    int cFlagBad=0, cFlowBad=0, cNearFail=0, cVis=0, cStuck=0, cCD=0, cSep=0;

    // ===== 调参常量（可改成 CVar）=====
    const float HEIGHT_PEAK_WINDOW = 350.0;  // 0..350u 区间越高越优
    const float TAPER_BASE_DIST    = 200.0;  // 超过 350 后按 1/(1+over/200) 衰减
    const float HEADROOM           = 400.0;  // 需要感知补额的最大值（保证略超 ring 的高点能进候选）
    const float CJ_ALLOWED_PLANE   = 250.0;  // Charger/Jockey 允许的眼高±范围
    const float CJ_PLANE_BASE_PEN  = 20.0;   // 脱平面固定罚
    const float CJ_PLANE_SLOPE     = 0.6;    // 脱平面超出部分的线性罚系数

    // ============ 工具：基于“目标或全队最高”的参考眼高 ============
    float refEyeZ = allMaxZ;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        float e[3]; GetClientEyePosition(targetSur, e);
        refEyeZ = e[2];
    }

    // ===== 分桶路径 =====
    bool useBuckets = (gCV.bNavBucketEnable && g_BucketsReady);
    if (useBuckets)
    {
        int win = ComputeDynamicBucketWindow(searchRange);
        if (win < 0) win = 0; if (win > 100) win = 100;

        int  order[FLOW_BUCKETS];
        int  orderLen  = BuildBucketOrder(centerBucket, win, gCV.bNavBucketIncludeCtr, order);
        bool firstFit  = gCV.bNavBucketFirstFit;

        for (int oi = 0; oi < orderLen; oi++)
        {
            int b = order[oi];
            if (b < 0 || b > 100) continue;
            if (g_FlowBuckets[b] == null) continue;

            // 桶内已按核心高度从高到低排好
            for (int k = 0; k < g_FlowBuckets[b].Length; k++)
            {
                int ai = g_FlowBuckets[b].Get(k);
                if (IsNavOnCooldown(ai, now)) { cCD++; continue; }

                NavArea pArea = view_as<NavArea>(pTheNavAreas.GetAreaRaw(ai, false));
                if (!pArea || !IsValidFlags(pArea.SpawnAttributes, bFinaleArea))
                { cFlagBad++; continue; }

                float fFlow = pArea.GetFlow();
                if (fFlow < 0.0 || fFlow > fMapMaxFlowDist)
                { cFlowBad++; continue; }

                float p[3];
                pArea.GetRandomPoint(p);

                // --- 该候选点所属桶 ---
                int candBucket = FlowDistanceToPercent(fFlow);

                // --- 桶内高度范围（已计算过） ---
                float bMinZ = g_BucketMinZ[candBucket];
                float bMaxZ = g_BucketMaxZ[candBucket];
                if (bMaxZ <= bMinZ) { bMinZ = allMinZ - 50.0; bMaxZ = allMaxZ + 50.0; } // 保护

                // === 距离资格判定：允许“高点需要感知补额”让它进入候选 ===
                float dminEye = GetMinEyeDistToAnySurvivor(p);      // 眼睛最小距离（与硬下限口径一致）
                float slack   = 0.0;

                // 非 CJ 给基础高度放宽 + 需要感知补额
                if (zc != view_as<int>(SI_Charger) && zc != view_as<int>(SI_Jockey))
                {
                    // 基础放宽：沿用 HeightRingSlack（以全队最高眼高 allMaxZ 作为 allMaxEyeZ）
                    float baseSlack = HeightRingSlack(p, bMinZ, bMaxZ, /*allMaxEyeZ=*/allMaxZ);

                    // 需要感知补额：若该点高于参考眼高且“略在 ring 外”，补到能进候选
                    float zRel = p[2] - refEyeZ;
                    float topup = 0.0;
                    if (zRel > 0.0)
                    {
                        float need = FloatMax(0.0, dminEye - searchRange);
                        topup = FloatMin(need, HEADROOM);
                    }
                    slack = FloatMax(baseSlack, topup);
                }
                // Charger/Jockey 不吃任何放宽（保持 0）

                float ringEff = FloatMin(searchRange + slack, gCV.fSpawnMax);

                // 资格：SpawnMin ≤ dminEye ≤ ringEff
                if (!(dminEye >= gCV.fSpawnMin && dminEye <= ringEff))
                { cNearFail++; continue; }

                // 其余快速筛
                if (!PassMinSeparation(p))            { cSep++;   continue; }
                if (WillStuck(p))                     { cStuck++; continue; }
                if (IsPosVisibleSDK(p, teleportMode)) { cVis++;   continue; }

                // ===== 评分（extra汇总） =====
                float extra = 0.0;

                // Finale/尾段前：后方极值软/硬拒（沿用你原规则）
                bool inFinale     = L4D_IsMissionFinalMap();
                bool finaleActive = (L4D2_GetCurrentFinaleStage() != FINALE_NONE);
                if (!(inFinale && finaleActive) && centerBucket < 95)
                {
                    const float EYE_TO_FEET = 60.0;
                    float allMinFeetZ = allMinZ - EYE_TO_FEET;

                    if (p[2] < (allMinFeetZ - 200.0) && candBucket <= (allMinFlowBucket ))
                        extra += 1000.0;         // 地底且靠后
                    else if (p[2] > (allMaxZ + 300.0) && candBucket <= (allMinFlowBucket + 1) && zc != view_as<int>(SI_Smoker))
                        extra += 1000.0;         // 过高且靠后
                }

                // 扇区分散度（与你原来一致）
                int sidx = ComputeSectorIndex(center, p, sectors);
                float prefBonus     = ScaleBySectors(SECTOR_PREF_BONUS_BASE,  sectors);
                float offPenalty    = ScaleBySectors(SECTOR_OFF_PENALTY_BASE, sectors);
                float rpen0         = ScaleBySectors(RECENT_PENALTY_0_BASE,   sectors);
                float rpen1         = ScaleBySectors(RECENT_PENALTY_1_BASE,   sectors);
                float rpen2         = ScaleBySectors(RECENT_PENALTY_2_BASE,   sectors);
                float penScaleLimit = SectorPenaltyScaleByLimit();
                offPenalty *= penScaleLimit; rpen0 *= penScaleLimit; rpen1 *= penScaleLimit; rpen2 *= penScaleLimit;

                float sectorPenalty = (sidx == preferredSector) ? prefBonus : offPenalty;
                if (recentSectors[0] == sidx) sectorPenalty += rpen0;
                if (recentSectors[1] == sidx) sectorPenalty += rpen1;
                if (recentSectors[2] == sidx) sectorPenalty += rpen2;

                // ---- 高度打分：非 CJ 给 0..350 奖励，>350 衰减；CJ 贴平面并对超出惩罚 ----
                float heightBonus = 0.0;
                float zRelScore   = p[2] - refEyeZ;   // 相对参考眼高

                if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
                {
                    float distPlane = FloatAbs(zRelScore);
                    if (distPlane > CJ_ALLOWED_PLANE)
                        extra += CJ_PLANE_BASE_PEN + (distPlane - CJ_ALLOWED_PLANE) * CJ_PLANE_SLOPE;
                    // 不给 heightBonus
                }
                else
                {
                    // 用与你原版量级兼容的峰值：取 (10 + 0.04*zRange)
                    float zRange = bMaxZ - bMinZ; if (zRange < 1.0) zRange = 1.0;
                    float BONUS_BASE_FACTOR = (10.0 + 0.04 * zRange);

                    if (zRelScore <= 0.0)
                    {
                        heightBonus = 0.0; // 眼下/同高不奖不罚（你可改为小罚/小奖）
                    }
                    else if (zRelScore <= HEIGHT_PEAK_WINDOW)
                    {
                        float t = zRelScore / HEIGHT_PEAK_WINDOW; // 0..1 线性上升
                        heightBonus = - BONUS_BASE_FACTOR * t;
                    }
                    else
                    {
                        float over  = zRelScore - HEIGHT_PEAK_WINDOW;
                        float taper = 1.0 / (1.0 + (over / TAPER_BASE_DIST));
                        heightBonus = - BONUS_BASE_FACTOR * (1.0 * taper);
                    }
                    extra += heightBonus;
                }

                // 路径可达性罚分（保持与原逻辑一致，最后叠加）
                float pathPenalty = PathPenalty_NoBuild(p, targetSur, searchRange, gCV.fSpawnMax);
                extra += pathPenalty;

                // First-Fit ：保持原语义（只在路径可达时即返）
                if (firstFit && pathPenalty == 0.0)
                {
                    outPos = p;
                    outAreaIdx = ai;
                    return true;
                }
                else
                {
                    float score = dminEye + sectorPenalty + extra;
                    if (!found || score < bestScore)
                    {
                        found     = true;
                        bestScore = score;
                        bestIdx   = ai;
                        bestPos   = p;
                    }
                    acceptedHits++;
                    if (acceptedHits >= TOPK) break;
                }
            }
            if (acceptedHits >= TOPK) break;
        }
    }
    else
    {
        // ===== 无分桶：全量扫描（评分与 useBuckets 分支对齐）=====
        bool firstFit = gCV.bNavBucketFirstFit;

        for (int ai = 0; ai < iAreaCount; ai++)
        {
            if (IsNavOnCooldown(ai, now)) { cCD++; continue; }

            NavArea pArea = view_as<NavArea>(pTheNavAreas.GetAreaRaw(ai, false));
            if (!pArea || !IsValidFlags(pArea.SpawnAttributes, bFinaleArea))
            { cFlagBad++; continue; }

            float fFlow = pArea.GetFlow();
            if (fFlow < 0.0 || fFlow > fMapMaxFlowDist)
            { cFlowBad++; continue; }

            int candBucket = FlowDistanceToPercent(fFlow);

            float p[3]; pArea.GetRandomPoint(p);

            // 桶内高度范围（若不可用，用 allMinZ/allMaxZ 兜底）
            float bMinZ = g_BucketMinZ[candBucket];
            float bMaxZ = g_BucketMaxZ[candBucket];
            if (bMaxZ <= bMinZ) { bMinZ = allMinZ - 50.0; bMaxZ = allMaxZ + 50.0; }

            // 距离资格（含高点需要感知补额）
            float dminEye = GetMinEyeDistToAnySurvivor(p);
            float slack   = 0.0;
            if (zc != view_as<int>(SI_Charger) && zc != view_as<int>(SI_Jockey))
            {
                float baseSlack = HeightRingSlack(p, bMinZ, bMaxZ, /*allMaxEyeZ=*/allMaxZ);
                float zRel      = p[2] - refEyeZ;
                float topup     = 0.0;
                if (zRel > 0.0)
                {
                    float need = FloatMax(0.0, dminEye - searchRange);
                    topup = FloatMin(need, HEADROOM);
                }
                slack = FloatMax(baseSlack, topup);
            }
            float ringEff = FloatMin(searchRange + slack, gCV.fSpawnMax);
            if (!(dminEye >= gCV.fSpawnMin && dminEye <= ringEff))
            { cNearFail++; continue; }

            if (!PassMinSeparation(p))            { cSep++;   continue; }
            if (WillStuck(p))                     { cStuck++; continue; }
            if (IsPosVisibleSDK(p, teleportMode)) { cVis++;   continue; }

            // 评分
            float extra = 0.0;

            bool inFinale     = L4D_IsMissionFinalMap();
            bool finaleActive = (L4D2_GetCurrentFinaleStage() != FINALE_NONE);
            if (!(inFinale && finaleActive) && centerBucket < 95)
            {
                const float EYE_TO_FEET = 60.0;
                float allMinFeetZ = allMinZ - EYE_TO_FEET;

                if (p[2] < (allMinFeetZ - 200.0) && candBucket <= (allMinFlowBucket ))
                    extra += 1000.0;         // 地底且靠后
                else if (p[2] > (allMaxZ + 300.0) && candBucket <= (allMinFlowBucket + 1) && zc != view_as<int>(SI_Smoker))
                    extra += 1000.0;         // 过高且靠后
            }

            int sidx = ComputeSectorIndex(center, p, sectors);
            float prefBonus     = ScaleBySectors(SECTOR_PREF_BONUS_BASE,  sectors);
            float offPenalty    = ScaleBySectors(SECTOR_OFF_PENALTY_BASE, sectors);
            float rpen0         = ScaleBySectors(RECENT_PENALTY_0_BASE,   sectors);
            float rpen1         = ScaleBySectors(RECENT_PENALTY_1_BASE,   sectors);
            float rpen2         = ScaleBySectors(RECENT_PENALTY_2_BASE,   sectors);
            float penScaleLimit = SectorPenaltyScaleByLimit();
            offPenalty *= penScaleLimit; rpen0 *= penScaleLimit; rpen1 *= penScaleLimit; rpen2 *= penScaleLimit;

            float sectorPenalty = (sidx == preferredSector) ? prefBonus : offPenalty;
            if (recentSectors[0] == sidx) sectorPenalty += rpen0;
            if (recentSectors[1] == sidx) sectorPenalty += rpen1;
            if (recentSectors[2] == sidx) sectorPenalty += rpen2;

            float heightBonus = 0.0;
            float zRelScore   = p[2] - refEyeZ;

            if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
            {
                float distPlane = FloatAbs(zRelScore);
                if (distPlane > CJ_ALLOWED_PLANE)
                    extra += CJ_PLANE_BASE_PEN + (distPlane - CJ_ALLOWED_PLANE) * CJ_PLANE_SLOPE;
            }
            else
            {
                float zRange = bMaxZ - bMinZ; if (zRange < 1.0) zRange = 1.0;
                float BONUS_BASE_FACTOR = (10.0 + 0.04 * zRange);

                if (zRelScore <= 0.0)
                {
                    heightBonus = 0.0;
                }
                else if (zRelScore <= HEIGHT_PEAK_WINDOW)
                {
                    float t = zRelScore / HEIGHT_PEAK_WINDOW;
                    heightBonus = - BONUS_BASE_FACTOR * t;
                }
                else
                {
                    float over  = zRelScore - HEIGHT_PEAK_WINDOW;
                    float taper = 1.0 / (1.0 + (over / TAPER_BASE_DIST));
                    heightBonus = - BONUS_BASE_FACTOR * (1.0 * taper);
                }
                extra += heightBonus;
            }

            float pathPenalty = PathPenalty_NoBuild(p, targetSur, searchRange, gCV.fSpawnMax);
            extra += pathPenalty;

            if (firstFit && pathPenalty == 0.0)
            {
                outPos = p;
                outAreaIdx = ai;
                return true;
            }
            else
            {
                float score = dminEye + sectorPenalty + extra;
                if (!found || score < bestScore)
                {
                    found     = true;
                    bestScore = score;
                    bestIdx   = ai;
                    bestPos   = p;
                }
                acceptedHits++;
                if (acceptedHits >= TOPK) break;
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



stock float PathPenalty_NoBuild(const float candPos[3], int targetSur, float ring, float spawnmax)
{
    // 先选一个有效幸存者：优先 targetSur；否则遍历 1..MaxClients
    int surv = -1;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        surv = targetSur;
    }
    else
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsValidSurvivor(i) && IsPlayerAlive(i) && !L4D_IsPlayerIncapacitated(i))
            {
                surv = i;
                break;
            }
        }
    }
    if (surv == -1) return PATH_NO_BUILD_PENALTY; // 没有可用幸存者，按“不可达”处理

    // 生还者位置（与你 SpawnInfected 的写法保持一致）
    float survPos[3];
    GetClientEyePosition(surv, survPos);
    survPos[2] -= 60.0;

    // 最近 nav（完全复用你 SpawnInfected 的用法/参数）
    Address navGoal  = L4D_GetNearestNavArea(candPos, 120.0, false, false, false, TEAM_INFECTED);
    Address navStart = L4D_GetNearestNavArea(survPos, 120.0, false, false, false, TEAM_INFECTED);
    if (!navGoal || !navStart) return PATH_NO_BUILD_PENALTY;

    // 代价上限：min(ring*3, spawnmax*1.5)
    float limitCost = FloatMin(ring * 3.0, spawnmax * 1.5);

    // 能 BuildPath 且代价不超 => 0；否则给大惩罚
    bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
    return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
}


// =========================
// Spawn / Command helpers
// =========================
// =========================
// Spawn / Command helpers（改：使用眼睛距离判定 SpawnMin）
// =========================
static bool DoSpawnAt(const float pos[3], int zc)
{
    // 使用“眼睛距离”作为硬下限口径，统一与你想要的判定方式
    if (GetMinEyeDistToAnySurvivor(pos) < gCV.fSpawnMin)
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

// 对一个 NavArea 采样若干随机点，估出 zAvg / zMin / zMax
static void SampleAreaZ(Address areaAddr, float &zAvg, float &zMin, float &zMax, int samples = 3)
{
    zAvg = 0.0; zMin = 1.0e9; zMax = -1.0e9;
    if (areaAddr == Address_Null || samples <= 0) { zMin = zMax = zAvg = 0.0; return; }

    NavArea area = view_as<NavArea>(areaAddr);
    float p[3];

    for (int i = 0; i < samples; i++)
    {
        area.GetRandomPoint(p);
        zAvg += p[2];
        if (p[2] < zMin) zMin = p[2];
        if (p[2] > zMax) zMax = p[2];
    }
    zAvg /= float(samples);
}

static void BypassAndExecuteCommand(const char[] cmd)
{
    if (!CheatsOn()) return;
    ServerCommand("%s", cmd);
}
// 计算到任意幸存者“眼睛”的最小距离（用于 DoSpawnAt 的硬下限判定）
static float GetMinEyeDistToAnySurvivor(const float p[3])
{
    float best = 999999.0;
    float eyes[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientEyePosition(i, eyes);
        float d = GetVectorDistance(p, eyes);
        if (d < best) best = d;
    }
    return best;
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
    GetAddress(hGameData, view_as<Address>(g_pPanicEventStage), "CDirectorScriptedEventManager::m_PanicEventStage");

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
stock int GetSepMax()
{
    int cap = gCV.iSiLimit;       // 与特感数量上限一致
    if (cap < 0)  cap = 0;        // 下限保护
    if (cap > 20) cap = 20;       // 上限保护（可按需调大）
    return cap;
}
