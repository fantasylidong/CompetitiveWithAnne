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
#define SUPPORT_EXPAND_MAX        1200.0
#define FLOW_TO_RING_SCALE        1.5

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
#define SEP_RADIUS                80.0
#define NAV_CD_SECS               0.5
#define SECTORS_BASE              6       // 基准
#define SECTORS_MAX               8       // 动态上限（建议 6~8 之间）
#define DYN_SECTORS_MIN           3       // 动态下限
// 可调参数（想热调也能做成 CVar，这里先给常量）
#define PEN_LIMIT_SCALE_HI        1.00   // L=1 时：正向惩罚略强一点
#define PEN_LIMIT_SCALE_LO        0.50   // L=20 时：正向惩罚明显减弱
#define PEN_LIMIT_MINL            1
#define PEN_LIMIT_MAXL            16

// [新增] —— PathPenalty_NoBuild 结果缓存（key -> result / expire）
static StringMap g_PathCacheRes = null;  // key -> int(0/1)

#define PATH_NO_BUILD_PENALTY     1999.0

// === Dispersion tuning (penalties at BASE=4) ===
#define SECTOR_PREF_BONUS_BASE   -8.0
#define SECTOR_OFF_PENALTY_BASE   4.0
#define RECENT_PENALTY_0_BASE     3.6
#define RECENT_PENALTY_1_BASE     2.4
#define RECENT_PENALTY_2_BASE     2.0

// Nav Flow 分桶
#define FLOW_BUCKETS              101     // 0..100
#define BUCKET_CACHE_VER "2025.10.09"  // 和插件版号保持同步

// 记录最近使用过的 navArea -> 过期时间
StringMap g_NavCooldown;

static const char INFDN[10][] =
{
    "common","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};
// ✅ 添加：NavAreas 全局缓存
static ArrayList g_AllNavAreasCache = null;
static int g_NavAreasCacheCount = 0;
// —— Nav 高度“核心”缓存 & 每桶高度范围 —— //
static ArrayList g_AreaZCore = null;   // float per areaIdx（核心高度=多次随机点的 z 均值）
static ArrayList g_AreaZMin  = null;   // float per areaIdx
static ArrayList g_AreaZMax  = null;   // float per areaIdx
static float g_BucketMinZ[FLOW_BUCKETS];
static float g_BucketMaxZ[FLOW_BUCKETS];
static float g_LastSpawnTime[MAXPLAYERS+1];

static StringMap g_NavIdToIndex = null;  // navid -> areaIdx
static char g_sBucketCachePath[PLATFORM_MAX_PATH] = "";

// =========================
// 修改 TheNavAreas methodmap
// =========================
methodmap TheNavAreas
{
    // 使用 left4dhooks 的 L4D_GetAllNavAreas 替代
    public int Count()
    {
        EnsureNavAreasCache();  // ✅ 确保缓存存在
        return g_NavAreasCacheCount;
    }
    
    public Address GetAreaByIndex(int i)
    {
        EnsureNavAreasCache();  // ✅ 确保缓存存在
        if (i < 0 || i >= g_NavAreasCacheCount)
            return Address_Null;
        return g_AllNavAreasCache.Get(i);
    }
}
// =========================
// 修改 NavArea methodmap
// =========================
methodmap NavArea
{
    public bool IsNull()
    {
        return view_as<Address>(this) == Address_Null;
    }

    // ✅ 使用 L4D_FindRandomSpot 替代 SDK call
    public void GetRandomPoint(float outPos[3])
    {
        L4D_FindRandomSpot(view_as<int>(this), outPos);
    }

    // ✅ 使用 L4D_GetNavArea_SpawnAttributes 替代 offset
    property int SpawnAttributes
    {
        public get()
        {
            return L4D_GetNavArea_SpawnAttributes(view_as<Address>(this));
        }
        public set(int v)
        {
            L4D_SetNavArea_SpawnAttributes(view_as<Address>(this), v);
        }
    }

    // ✅ 使用 L4D2Direct_GetTerrorNavAreaFlow 替代 offset
    public float GetFlow()
    {
        return L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(this));
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

// [优化] 扩展结构体以缓存更多信息
enum struct SpawnCandidate
{
    int areaIdx;
    float pos[3];
    int bucket;
    bool rawBadFlow;
    float dminEye;
}

// [ADD] 单次最终入选刷点的评分快照（只打印最终点）
enum struct SpawnScoreDbg
{
    float total;
    float dist;
    float hght;
    float flow;
    float dispRaw;
    float dispScaled;
    float penK;

    float dminEye;
    float ringEff;
    float slack;

    int candBucket;
    int centerBucket;
    int deltaFlow;
    int sector;
    int areaIdx;

    float pos[3];
    bool rawBadFlow;
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
    ConVar NavBucketIncludeCtr;
    // —— 选桶与配额（新增） —— //
    ConVar NavBucketPickCount;     // 从基桶起，按顺序取 N 个桶参与评估
    ConVar CandGlobalCap;          // 全局候选容量上限（用于控制开销）
    ConVar NavBucketBaseQuotaNum;  // 基桶配额：分子
    ConVar NavBucketBaseQuotaDen;  // 基桶配额：分母
    ConVar NavBucketOtherQuotaNum; // 其他桶配额：分子
    ConVar NavBucketOtherQuotaDen; // 其他桶配额：分母
   // 是否包含中心桶 s

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
    // Config 字段（在 enum struct Config 里补充）
    ConVar NavBucketMapInvalid;        // 将坏flow的NavArea映射到就近正常桶
    ConVar NavBucketAssignRadius;      // 可选：就近半径上限(0=不限)
    // Config 里已有占位：ConVar gCvarNavCacheEnable; 这里补 bool 并在 Refresh 里赋值
    ConVar gCvarNavCacheEnable;
    // [新增] 新版评分系统权重与参数
    // [ADD] New scoring system weights & parameters
    ConVar Score_w_dist;
    ConVar Score_w_hght;
    ConVar Score_w_flow;
    ConVar Score_w_disp;

    ConVar PathCacheEnable;
    ConVar PathCacheQuantize;
    ConVar CandTopK;               // <<<<<<< 新增: 声明 ConVar 句柄

    bool  bPathCacheEnable;
    float fPathCacheQuantize;

    float w_dist[7];
    float w_hght[7];
    float w_flow[7];
    float w_disp[7];
    bool  bNavCacheEnable;

    bool  bNavBucketMapInvalid;
    float fNavBucketAssignRadius;
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
    // —— 运行期缓存（新增） —— //
    int   iNavBucketPickCount;
    int   iCandGlobalCap;
    int   iBucketBaseQuotaNum;
    int   iBucketBaseQuotaDen;
    int   iBucketOtherQuotaNum;
    int   iBucketOtherQuotaDen;
    int    iCandTopK;              // <<<<<<< 新增: 声明用于缓存的整型变量

    // 【新增】raw badflow 高度惩罚 - CVar 句柄
    ConVar FlowBadPenaltyEnable;
    ConVar FlowBadPenaltyScale;

    // 【新增】缓存到运行期
    bool  bFlowBadPenaltyEnable;
    float fFlowBadPenaltyScale;

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

        // —— 选桶与配额（新增） —— //
        /* 【修改】默认取前 4 个桶（中心 + 相邻 2 桶），以配合 9+12=21 的并行评分预算 */
        this.NavBucketPickCount     = CreateConVar("inf_nav_bucket_pick_count", "3",
            "Number of buckets to evaluate starting from the base bucket (>=1).", CVAR_FLAG, true, 1.0, true, 25.0);

        /* 【修改】预算上限保守到 24（与 topK 21 配合，避免爆量） */
        this.CandGlobalCap          = CreateConVar("inf_nav_cand_global_cap", "24",
            "Maximum global candidate capacity to avoid excessive computation.", CVAR_FLAG, true, 8.0, true, 512.0);

        /* 【修改】基桶配额：3/4 × topK = 9 */
        this.NavBucketBaseQuotaNum  = CreateConVar("inf_nav_bucket_base_quota_num", "3",
            "Base bucket candidate quota numerator (e.g., 1/3 * TOPK).", CVAR_FLAG, true, 1.0, true, 10.0);
        this.NavBucketBaseQuotaDen  = CreateConVar("inf_nav_bucket_base_quota_den", "4",
            "Base bucket candidate quota denominator.", CVAR_FLAG, true, 1.0, true, 10.0);

        /* 【修改】其他桶配额：每桶 1/2 × topK = 6（2 桶合计 12） */
        this.NavBucketOtherQuotaNum = CreateConVar("inf_nav_bucket_other_quota_num", "1",
            "Other buckets candidate quota numerator (e.g., 2/9 * TOPK).", CVAR_FLAG, true, 1.0, true, 10.0);
        this.NavBucketOtherQuotaDen = CreateConVar("inf_nav_bucket_other_quota_den", "2",
            "Other buckets candidate quota denominator.", CVAR_FLAG, true, 1.0, true, 10.0);

        /* 【修改】topK：设为 27；这是“进入评分阶段的候选上限”，最终仍旧只会选 1 个点刷出 */
        this.CandTopK = CreateConVar("inf_nav_cand_topk", "21",
            "在评分前，从合格点中收集的顶尖候选点的数量上限。这直接影响配额计算和性能开销。",
            CVAR_FLAG, true, 4.0, true, 64.0);

        // 【新增】raw badflow 高度惩罚开关与强度
        this.FlowBadPenaltyEnable = CreateConVar(
            "inf_flow_bad_penalty_enable", "1",
            "当候选点所在 NavArea 的原始 flow 无效时（raw badflow），对流程分额外叠加高度惩罚（1=开启，0=关闭）。", 
            CVAR_FLAG, true, 0.0, true, 1.0);

        this.FlowBadPenaltyScale = CreateConVar(
            "inf_flow_bad_penalty_scale", "1.0",
            "raw badflow 高度惩罚的缩放系数（建议 0.6~1.2）。", 
            CVAR_FLAG, true, 0.0, true, 3.0);

        this.FlowBadPenaltyEnable.AddChangeHook(OnCfgChanged);
        this.FlowBadPenaltyScale.AddChangeHook(OnCfgChanged);
        // —— 死亡CD —— //
        this.DeathCDKiller     = CreateConVar("inf_DeathCooldownKiller",  "1.0","同类击杀后最小补位CD（秒）：Hunter/Smoker/Jockey/Charger", CVAR_FLAG, true, 0.0, true, 30.0);
        this.DeathCDSupport    = CreateConVar("inf_DeathCooldownSupport", "2.0","同类击杀后最小补位CD（秒）：Boomer/Spitter", CVAR_FLAG, true, 0.0, true, 30.0);

        // —— 双保险 —— //
        this.DeathCDBypassAfter = CreateConVar("inf_DeathCooldown_BypassAfter", "1.5","距离上次成功刷出超过该秒数时，临时忽略死亡CD", CVAR_FLAG, true, 0.0, true, 10.0);
        this.DeathCDUnderfill   = CreateConVar("inf_DeathCooldown_Underfill", "0.5","当【场上活着特感】< iSiLimit * 本值 时，忽略死亡CD", CVAR_FLAG, true, 0.0, true, 1.0);
        this.TeleportSpawnGrace = CreateConVar("inf_TeleportSpawnGrace", "2.5",
            "特感生成后多少秒内禁止传送", CVAR_FLAG, true, 0.0, true, 10.0);
        this.TeleportRunnerFast = CreateConVar("inf_TeleportRunnerFast", "1.5",
            "跑男时的快速传送阈值（秒），仍需达到该不可见时长才可传送", CVAR_FLAG, true, 0.0, true, 10.0);
        // Create() 里，紧跟“Nav 分桶”相关 CVar 后面加入：
        this.NavBucketMapInvalid   = CreateConVar("inf_NavBucketMapInvalid", "1",
            "Map invalid-flow NavAreas to nearest valid-flow bucket (0=off,1=on)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.NavBucketAssignRadius = CreateConVar("inf_NavBucketAssignRadius", "0.0",
            "Optional XY max distance when reassigning invalid-flow areas; 0 = unlimited", CVAR_FLAG, true, 0.0);
        this.gCvarNavCacheEnable = CreateConVar(
            "inf_NavCacheEnable", "1",
            "Enable on-disk cache for Nav flow buckets (0=off,1=on)",
            CVAR_FLAG, true, 0.0, true, 1.0);
        // [新增] 为新评分系统创建CVar
        // [ADD] Create CVars for the new scoring system
        this.Score_w_dist = CreateConVar("inf_score_w_dist", "1.35 1.10 1.20 1.05 1.20 1.25", "距离分权重(S,H,P,B,J,C)", CVAR_FLAG);
        this.Score_w_hght = CreateConVar("inf_score_w_hght", "2.20 1.10 1.60 1.40 0.60 0.60", "高度分权重(S,H,P,B,J,C)", CVAR_FLAG);
        this.Score_w_flow = CreateConVar("inf_score_w_flow", "1.40 1.00 1.20 1.35 1.10 1.20", "流程分权重(S,H,P,B,J,C)", CVAR_FLAG);
        this.Score_w_disp = CreateConVar("inf_score_w_disp", "1.25 1.05 1.15 1.30 0.90 0.80", "分散度分权重(S,H,P,B,J,C)", CVAR_FLAG);
        this.PathCacheEnable   = CreateConVar("inf_PathCacheEnable", "1",
            "Enable PathPenalty_NoBuild cache (0/1)", CVAR_FLAG, true, 0.0, true, 1.0);
        this.PathCacheQuantize = CreateConVar("inf_PathCacheQuantize", "50.0",
            "Quantization step for limitCost when caching (world units)",
            CVAR_FLAG, true, 1.0, true, 500.0);

        this.PathCacheEnable.AddChangeHook(OnCfgChanged);
        this.PathCacheQuantize.AddChangeHook(OnCfgChanged);
        this.Score_w_dist.AddChangeHook(OnCfgChanged);
        this.Score_w_hght.AddChangeHook(OnCfgChanged);
        this.Score_w_flow.AddChangeHook(OnCfgChanged);
        this.Score_w_disp.AddChangeHook(OnCfgChanged);
        this.gCvarNavCacheEnable.AddChangeHook(OnCfgChanged);

        this.NavBucketMapInvalid.AddChangeHook(OnCfgChanged);
        this.NavBucketAssignRadius.AddChangeHook(OnCfgChanged);
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
        // 【新增】让这些 CVar 热更新能立刻生效
        this.NavBucketPickCount.AddChangeHook(OnCfgChanged);        // [新增]
        this.CandGlobalCap.AddChangeHook(OnCfgChanged);             // [新增]
        this.NavBucketBaseQuotaNum.AddChangeHook(OnCfgChanged);     // [新增]
        this.NavBucketBaseQuotaDen.AddChangeHook(OnCfgChanged);     // [新增]
        this.NavBucketOtherQuotaNum.AddChangeHook(OnCfgChanged);    // [新增]
        this.NavBucketOtherQuotaDen.AddChangeHook(OnCfgChanged);    // [新增]
        this.CandTopK.AddChangeHook(OnCfgChanged);                  // [新增]

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
        // —— 选桶与配额（读取） —— //
        this.iNavBucketPickCount   = this.NavBucketPickCount.IntValue;
        if (this.iNavBucketPickCount < 1)  this.iNavBucketPickCount = 1;
        if (this.iNavBucketPickCount > 25) this.iNavBucketPickCount = 25;

        this.iCandGlobalCap        = this.CandGlobalCap.IntValue;
        if (this.iCandGlobalCap < 8)    this.iCandGlobalCap = 8;
        if (this.iCandGlobalCap > 512)  this.iCandGlobalCap = 512;

        this.iBucketBaseQuotaNum   = this.NavBucketBaseQuotaNum.IntValue;
        this.iBucketBaseQuotaDen   = this.NavBucketBaseQuotaDen.IntValue;
        this.iBucketOtherQuotaNum  = this.NavBucketOtherQuotaNum.IntValue;
        this.iBucketOtherQuotaDen  = this.NavBucketOtherQuotaDen.IntValue;
        if (this.iBucketBaseQuotaDen <= 0)   this.iBucketBaseQuotaDen = 1;
        if (this.iBucketOtherQuotaDen <= 0)  this.iBucketOtherQuotaDen = 1;

        /* 【新增】读取 topK，并与全局候选能力做 min()，避免超配 */
        this.iCandTopK = this.CandTopK.IntValue;                 // [新增]
        if (this.iCandTopK < 4)   this.iCandTopK = 4;            // [新增]
        if (this.iCandTopK > this.iCandGlobalCap)                // [新增]
            this.iCandTopK = this.iCandGlobalCap;                // [新增]

        // 【新增】读取 raw badflow 惩罚配置
        this.bFlowBadPenaltyEnable = this.FlowBadPenaltyEnable.BoolValue;
        this.fFlowBadPenaltyScale  = this.FlowBadPenaltyScale.FloatValue;
        if (this.fFlowBadPenaltyScale < 0.0) this.fFlowBadPenaltyScale = 0.0;

        // 死亡CD & 放宽
        this.fDeathCDKiller     = this.DeathCDKiller.FloatValue;
        this.fDeathCDSupport    = this.DeathCDSupport.FloatValue;
        this.fDeathCDBypassAfter= this.DeathCDBypassAfter.FloatValue;
        this.fDeathCDUnderfill  = this.DeathCDUnderfill.FloatValue;
        this.fTeleportSpawnGrace = this.TeleportSpawnGrace.FloatValue;
        this.fTeleportRunnerFast = this.TeleportRunnerFast.FloatValue;

        this.bNavBucketMapInvalid   = this.NavBucketMapInvalid.BoolValue;
        this.fNavBucketAssignRadius = this.NavBucketAssignRadius.FloatValue;
        this.bNavCacheEnable = this.gCvarNavCacheEnable.BoolValue;
        // [新增] 刷新新评分系统的权重值 (已修正 ExplodeString 用法)
        // [ADD] Refresh weights for the new scoring system (ExplodeString usage corrected)
        char buffer[256];
        char parts[6][16];
        int numParts;

        // [新增] —— 权重兜底：当 CVar 给的值不足或为 0 时，回退到 1.0，避免意外禁用某因子
        for (int i = 1; i <= 6; i++) {
            if (this.w_dist[i] <= 0.0) this.w_dist[i] = 1.0;
            if (this.w_hght[i] <= 0.0) this.w_hght[i] = 1.0;
            if (this.w_flow[i] <= 0.0) this.w_flow[i] = 1.0;
            if (this.w_disp[i] <= 0.0) this.w_disp[i] = 1.0;
        }

        this.Score_w_dist.GetString(buffer, sizeof(buffer));
        numParts = ExplodeString(buffer, " ", parts, 6, 16);
        for (int i = 0; i < numParts && i < 6; i++) {
            this.w_dist[i+1] = StringToFloat(parts[i]);
        }

        this.Score_w_hght.GetString(buffer, sizeof(buffer));
        numParts = ExplodeString(buffer, " ", parts, 6, 16);
        for (int i = 0; i < numParts && i < 6; i++) {
            this.w_hght[i+1] = StringToFloat(parts[i]);
        }

        this.Score_w_flow.GetString(buffer, sizeof(buffer));
        numParts = ExplodeString(buffer, " ", parts, 6, 16);
        for (int i = 0; i < numParts && i < 6; i++) {
            this.w_flow[i+1] = StringToFloat(parts[i]);
        }

        this.Score_w_disp.GetString(buffer, sizeof(buffer));
        numParts = ExplodeString(buffer, " ", parts, 6, 16);
        for (int i = 0; i < numParts && i < 6; i++) {
            this.w_disp[i+1] = StringToFloat(parts[i]);
        }
        
        this.bPathCacheEnable   = this.PathCacheEnable.BoolValue;
        this.fPathCacheQuantize = this.PathCacheQuantize.FloatValue;
        if (this.fPathCacheQuantize < 1.0) this.fPathCacheQuantize = 1.0;
        this.iCandTopK = this.CandTopK.IntValue;
        if (this.iCandTopK < 4)   this.iCandTopK = 4;
        if (this.iCandTopK > this.iCandGlobalCap)  // 与全局上限合并
            this.iCandTopK = this.iCandGlobalCap;
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

// —— 分散度：最近扇区 & 最近刷点 —— //
int recentSectors[3] = { -1, -1, -1 };   // 最近 3 次使用的扇区
ArrayList lastSpawns = null;             // 每条记录 [x,y,z,time]

// —— 新增：死亡CD时间戳 & 最近一次成功刷出 —— //
static float g_LastDeathTime[6];     // zc-1 索引
static float g_LastSpawnOkTime = 0.0;

// —— Nav Flow 分桶 —— //
static ArrayList g_FlowBuckets[FLOW_BUCKETS]; // 每桶存 NavArea 索引 i
static bool g_BucketsReady = false;

// —— 供就近归桶使用的中心点 & 预分配的桶百分比 —— //
static ArrayList g_AreaCX  = null;  // float per areaIdx
static ArrayList g_AreaCY  = null;  // float per areaIdx
static ArrayList g_AreaPct = null;  // int   per areaIdx（-1=未知/坏flow，否则0..100）

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
    version     = "2025.10.09",
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
    BuildNavIdIndexMap();
    BuildNavBuckets();        // ← 预建 FLOW 分桶
    RecalcSiCapFromAlive(true);

    // 分散度：初始化
    g_NavCooldown = new StringMap();
    lastSpawns = new ArrayList(4);
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;
    // [新增] Path 缓存初始化
    g_PathCacheRes = new StringMap();

    // 初始化死亡时间戳
    g_LastSpawnOkTime = 0.0;
    for (int i = 0; i < 6; i++) g_LastDeathTime[i] = 0.0;

    RegAdminCmd("sm_startspawn", Cmd_StartSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
    RegAdminCmd("sm_stopspawn",  Cmd_StopSpawn,  ADMFLAG_ROOT, "管理员停止刷特");
    RegAdminCmd("sm_rebuildnavcache", Cmd_RebuildNavCache, ADMFLAG_ROOT, "Rebuild Nav bucket cache for current map");
    RegAdminCmd("sm_navpeek", Cmd_NavPeek, ADMFLAG_GENERIC, "查看准星 Nav 的分桶与属性");
    RegAdminCmd("sm_np",      Cmd_NavPeek, ADMFLAG_GENERIC, "查看准星 Nav 的分桶与属性(别名)");
    RegAdminCmd("sm_navtest", Cmd_NavTest, ADMFLAG_GENERIC, "测试准星 Nav 能否生成特感及评分");
    RegAdminCmd("sm_nt",      Cmd_NavTest, ADMFLAG_GENERIC, "测试准星 Nav 能否生成特感及评分(别名)");

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
    // [新增] —— 每波开始即清理 Path 缓存（波级作用域）
    ClearPathCache();
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
    if (g_NavIdToIndex != null) { delete g_NavIdToIndex; g_NavIdToIndex = null; }
    // [新增] —— 每波开始即清理 Path 缓存（波级作用域）
    ClearPathCache();
    // ✅ 添加：清理 NavAreas 缓存
    ClearNavAreasCache();
}
// =========================
// NavAreas 缓存管理
// =========================

// ✅ 新增：确保缓存已初始化
stock void EnsureNavAreasCache()
{
    if (g_AllNavAreasCache == null)
    {
        g_AllNavAreasCache = new ArrayList();
        L4D_GetAllNavAreas(g_AllNavAreasCache);
        g_NavAreasCacheCount = g_AllNavAreasCache.Length;
        Debug_Print("[NAV CACHE] Initialized: %d areas", g_NavAreasCacheCount);
    }
}

// ✅ 新增：清理缓存
stock void ClearNavAreasCache()
{
    if (g_AllNavAreasCache != null)
    {
        delete g_AllNavAreasCache;
        g_AllNavAreasCache = null;
        g_NavAreasCacheCount = 0;
        Debug_Print("[NAV CACHE] Cleared");
    }
}

// ✅ 新增：强制重建缓存
stock void RebuildNavAreasCache()
{
    ClearNavAreasCache();
    EnsureNavAreasCache();
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

// ✅ 修改：重建时也重建 NavAreas 缓存
public Action Cmd_RebuildNavCache(int client, int args)
{
    // 强制重建 NavAreas 缓存
    RebuildNavAreasCache();
    
    // 强制重建并覆盖 Bucket 缓存
    ClearNavBuckets();
    g_BucketsReady = false;
    BuildNavBuckets();
    
    ReplyToCommand(client, "[IC] Rebuilt Nav bucket cache.");
    return Plugin_Handled;
}

// ===== 准星 NavArea 查看命令 =====
public Action Cmd_NavPeek(int client, int args)
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;

    float hit[3];
    if (!GetAimHitPos(client, hit))
    {
        PrintToChat(client, "\x04[IC]\x01 未能获取准星命中点。");
        return Plugin_Handled;
    }

    // 命中点所在的 TerrorNavArea；不行就找最近
    Address area = L4D2Direct_GetTerrorNavArea(hit);
    if (area == Address_Null)
        area = view_as<Address>(L4D_GetNearestNavArea(hit, 300.0, false, false, false, TEAM_INFECTED));

    if (area == Address_Null)
    {
        PrintToChat(client, "\x04[IC]\x01 附近没有 NavArea。");
        return Plugin_Handled;
    }

    NavArea na = view_as<NavArea>(area);
    int navid  = L4D_GetNavAreaID(area);
    int index  = FindNavIndexByAddress(area);

    float flowDist = na.GetFlow();                      // 可能为负(无效)
    float maxFlow  = L4D2Direct_GetMapMaxFlowDistance();
    int   bucketC  = (flowDist >= 0.0 && maxFlow > 0.0) ? FlowDistanceToPercent(flowDist) : -1;

    // 若预分桶已就绪，拿“归档桶”和区域高度统计
    int   bucketA = -1;
    float aZCore = 0.0, aZMin = 0.0, aZMax = 0.0;
    float bZMin  = 0.0, bZMax  = 0.0;

    if (g_BucketsReady && index >= 0 && g_AreaPct != null)
    {
        bucketA = view_as<int>(g_AreaPct.Get(index));
        aZCore  = view_as<float>(g_AreaZCore.Get(index));
        aZMin   = view_as<float>(g_AreaZMin.Get(index));
        aZMax   = view_as<float>(g_AreaZMax.Get(index));
        if (0 <= bucketA && bucketA <= 100)
        {
            bZMin = g_BucketMinZ[bucketA];
            bZMax = g_BucketMaxZ[bucketA];
        }
    }

    // 解析 Nav flags
    int flags = na.SpawnAttributes;
    char flagBuf[256];
    DescribeNavFlags(flags, flagBuf, sizeof flagBuf);

    // —— 控制台详细 —— //
    PrintToConsole(client, "=== [IC] NavPeek ===");
    PrintToConsole(client, "pos = (%.1f, %.1f, %.1f)", hit[0], hit[1], hit[2]);
    PrintToConsole(client, "navid = %d, index = %d", navid, index);
    if (bucketC >= 0)
        PrintToConsole(client, "flow = %.1f / %.1f  -> bucket(computed) = %d", flowDist, maxFlow, bucketC);
    else
        PrintToConsole(client, "flow = (invalid) -> bucket(computed) = N/A");

    if (g_BucketsReady)
    {
        PrintToConsole(client, "bucket(assigned) = %d", bucketA);
        PrintToConsole(client, "areaZ(core/min/max) = %.1f / %.1f / %.1f", aZCore, aZMin, aZMax);
        if (0 <= bucketA && bucketA <= 100)
            PrintToConsole(client, "bucketZ[min..max] = [%.1f .. %.1f]", bZMin, bZMax);
    }
    PrintToConsole(client, "flags = %s", flagBuf[0] ? flagBuf : "(none)");

    // —— 聊天简要 —— //
    if (bucketC >= 0)
        PrintToChat(client, "\x04[IC]\x01 navid=%d  桶=%d(算) / %d(归)  flag=%s", navid, bucketC, bucketA, flagBuf);
    else
        PrintToChat(client, "\x04[IC]\x01 navid=%d  桶=N/A / %d(归)  flag=%s", navid, bucketA, flagBuf);

    // DebugMode>=3：画一条短暂的准星射线，直观确认命中点
    if (gCV.iDebugMode >= 3)
        DrawAimLineOnce(client, hit);

    return Plugin_Handled;
}

// —— 计算准星命中点（忽略玩家/感染者/女巫，优先世界几何）——
static bool GetAimHitPos(int client, float outPos[3])
{
    float start[3], ang[3], dir[3], end[3];
    GetClientEyePosition(client, start);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
    ScaleVector(dir, 5000.0);
    AddVectors(start, dir, end);

    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(outPos, tr);
        delete tr;
        return true;
    }
    delete tr;
    outPos = end;
    return true;
}

// =====================
// 【修改】Nav 测试命令：评分改用 ScoreCandidate()
// =====================
public Action Cmd_NavTest(int client, int args)  // 【修改】
{
    if (!client || !IsClientInGame(client))
        return Plugin_Handled;

    float hit[3];
    if (!GetAimHitPos(client, hit)) {
        PrintToChat(client, "\x04[IC]\x01 未能获取准星命中点。");
        return Plugin_Handled;
    }

    Address area = L4D2Direct_GetTerrorNavArea(hit);
    if (area == Address_Null)
        area = view_as<Address>(L4D_GetNearestNavArea(hit, 300.0, false, false, false, TEAM_INFECTED));
    if (area == Address_Null) {
        PrintToChat(client, "\x04[IC]\x01 附近没有 NavArea。");
        return Plugin_Handled;
    }

    NavArea na = view_as<NavArea>(area);
    int navid  = L4D_GetNavAreaID(area);
    int index  = FindNavIndexByAddress(area);

    float testPos[3];
    na.GetRandomPoint(testPos);

    PrintToConsole(client, "");
    PrintToConsole(client, "========================================");
    PrintToConsole(client, "=== [IC] Nav Spawn Test ===");
    PrintToConsole(client, "========================================");
    PrintToConsole(client, "NavID: %d | Index: %d", navid, index);
    PrintToConsole(client, "Test Pos: (%.1f, %.1f, %.1f)", testPos[0], testPos[1], testPos[2]);
    PrintToConsole(client, "");

    float now = GetGameTime();
    bool bFinaleArea = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < 18;

    // 1. 冷却
    bool passCooldown = !IsNavOnCooldown(index, now);
    PrintToConsole(client, "[1] Cooldown Check: %s", passCooldown ? "PASS" : "FAIL (on cooldown)");

    // 2. Flags
    int flags = na.SpawnAttributes;
    bool passFlags = IsValidFlags(flags, bFinaleArea);
    char flagBuf[256];
    DescribeNavFlags(flags, flagBuf, sizeof flagBuf);
    PrintToConsole(client, "[2] Flags Check: %s | Flags: %s", passFlags ? "PASS" : "FAIL", flagBuf[0] ? flagBuf : "(none)");

    // 3. Flow（raw + 映射）
    float flowDist = na.GetFlow();
    float maxFlow  = L4D2Direct_GetMapMaxFlowDistance();
    bool  passFlowRaw = (flowDist >= 0.0 && flowDist <= maxFlow);

    int mappedPct = -1;
    if (gCV.bNavBucketEnable && g_BucketsReady && g_AreaPct != null && index >= 0 && index < g_AreaPct.Length) {
        mappedPct = view_as<int>(g_AreaPct.Get(index));  // 0..100 或 -1
    }
    bool passFlow = passFlowRaw || (mappedPct >= 0 && mappedPct <= 100);
    int  flowPercent = passFlowRaw ? FlowDistanceToPercent(flowDist) : mappedPct;

    PrintToConsole(client, "[3] Flow Check: %s | Flow: %.1f / %.1f (%d%%)%s",
        passFlow ? "PASS" : "FAIL (invalid flow)",
        flowDist, maxFlow, passFlow ? flowPercent : -1,
        (!passFlowRaw && passFlow) ? " [mapped]" : "");

    // 4. 距离
    float dminEye = GetMinEyeDistToAnySurvivor(testPos);
    float dminFeet = GetMinDistToAnySurvivor(testPos);
    bool passDist = (dminEye >= gCV.fSpawnMin && dminEye <= gCV.fSpawnMax);
    PrintToConsole(client, "[4] Distance Check: %s | Eye: %.1f | Feet: %.1f | Range: %.1f-%.1f",
        passDist ? "PASS" : "FAIL", dminEye, dminFeet, gCV.fSpawnMin, gCV.fSpawnMax);

    // 5. 位置关系（后方/上下层）
    int targetSur = ChooseTargetSurvivor();
    bool passPosition = PassRealPositionCheck(testPos, targetSur, view_as<int>(SI_Smoker));
    int candPercent = GetPositionBucketPercent(testPos);
    int surPercent = -1;
    if (IsValidSurvivor(targetSur)) TryGetClientFlowPercentSafe(targetSur, surPercent);
    int deltaReal = candPercent - surPercent;
    PrintToConsole(client, "[5] Position Check: %s | Cand: %d%% | Sur: %d%% | Delta: %d%%",
        passPosition ? "PASS" : "FAIL (behind/under/over)", candPercent, surPercent, deltaReal);

    // 6. 分散度（最小间距）
    bool passSeparation = PassMinSeparation(testPos);
    PrintToConsole(client, "[6] Dispersion Check: %s", passSeparation ? "PASS" : "FAIL");

    // 7. 卡壳
    bool passStuck = !WillStuck(testPos);
    PrintToConsole(client, "[7] Stuck Check: %s", passStuck ? "PASS" : "FAIL (will stuck)");

    // 8. 视线
    bool passVis = !IsPosVisibleSDK(testPos, false);
    PrintToConsole(client, "[8] Visibility Check: %s", passVis ? "PASS" : "FAIL (visible)");

    // 9. 路径
    float pathPenalty = PathPenalty_NoBuild(testPos, targetSur, gCV.fSpawnMax, gCV.fSpawnMax);
    bool passPath = (pathPenalty == 0.0);
    PrintToConsole(client, "[9] Path Check: %s | Penalty: %.1f", passPath ? "PASS" : "FAIL (no path)", pathPenalty);

    // === 评分演算（统一入口） ===
    PrintToConsole(client, "");
    PrintToConsole(client, "--- Score Breakdown (via ScoreCandidate) ---");

    int zc = view_as<int>(SI_Smoker); // 和原测试保持一致
    int centerBucket = 50; 
    if (surPercent >= 0) 
    {
        centerBucket = surPercent;
    } 
    SpawnScoreDbg dbg;
    float totalScore = ScoreCandidate(zc, testPos, centerBucket, dbg, /*ringForDbg=*/gCV.fSpawnMin);

    PrintToConsole(client, "  Distance Score: %.1f (dminEye=%.1f)", dbg.dist, dbg.dminEye);
    PrintToConsole(client, "  Height   Score: %.1f", dbg.hght);
    PrintToConsole(client, "  Flow     Score: %.1f (cand=%d%%, sur=%d%%, delta=%d%%)", dbg.flow, dbg.candBucket, dbg.centerBucket, dbg.deltaFlow);
    PrintToConsole(client, "  Disp     Score: %.1f (raw=%.1f, penK=%.2f, sector=%d)", dbg.dispScaled, dbg.dispRaw, dbg.penK, dbg.sector);
    PrintToConsole(client, "");
    PrintToConsole(client, "  TOTAL SCORE: %.1f", totalScore);
    PrintToConsole(client, "  (weights: dist=%.2f, hght=%.2f, flow=%.2f, disp=%.2f)",
        gCV.w_dist[zc], gCV.w_hght[zc], gCV.w_flow[zc], gCV.w_disp[zc]);

    PrintToConsole(client, "");
    // 【新增】在 NavTest 的打分打印处添加这一行（可选）
    if (dbg.rawBadFlow)
    PrintToConsole(client, "  Flow Penalty: raw badflow height penalty was applied (scale=%.2f)", gCV.fFlowBadPenaltyScale);
    bool canSpawn = passCooldown && passFlags && passFlow && passDist && passPosition
                 && passSeparation && passStuck && passVis && passPath;
    PrintToConsole(client, "========================================");
    PrintToConsole(client, "=== RESULT: %s ===", canSpawn ? "CAN SPAWN" : "CANNOT SPAWN");
    PrintToConsole(client, "========================================");

    if (canSpawn)
        PrintToChat(client, "\x04[IC]\x01 Nav %d \x05可以生成\x01 | 总分: \x03%.1f\x01 | 详情见控制台", navid, totalScore);
    else
        PrintToChat(client, "\x04[IC]\x01 Nav %d \x03不能生成\x01 | 详情见控制台", navid);

    if (gCV.iDebugMode >= 3)
    {
        int color[4] = {255, 255, 255, 255};
        if (canSpawn) color = {0, 255, 0, 255};
        else          color = {255, 0, 0, 255};

        float beamEnd[3]; beamEnd = testPos; beamEnd[2] += 100.0;
        TE_SetupBeamPoints(testPos, beamEnd, 0, 0, 0, 5, 2.0, 5.0, 5.0, 0, 0.0, color, 0);
        TE_SendToClient(client);
    }

    return Plugin_Handled;
}

// =========================
// 修改 FindNavIndexByAddress（用于调试命令）
// =========================
static int FindNavIndexByAddress(Address addr)
{
    if (addr == Address_Null) return -1;
    
    EnsureNavAreasCache();  // ✅ 确保缓存存在
    
    for (int i = 0; i < g_NavAreasCacheCount; i++)
    {
        if (g_AllNavAreasCache.Get(i) == addr)
            return i;
    }
    
    return -1;
}

// —— 将 SpawnAttributes 的位标记转成人类可读文本 ——
// 输出示例： "EMPTY|BATTLEFIELD|OBSCURED"
static void DescribeNavFlags(int f, char[] out, int maxlen)
{
    out[0] = '\0';
    AppendFlag(out, maxlen, f, TERROR_NAV_EMPTY,             "EMPTY");
    AppendFlag(out, maxlen, f, TERROR_NAV_STOP_SCAN,         "STOP");
    AppendFlag(out, maxlen, f, TERROR_NAV_BATTLESTATION,     "BATTLESTATION");
    AppendFlag(out, maxlen, f, TERROR_NAV_FINALE,            "FINALE");
    AppendFlag(out, maxlen, f, TERROR_NAV_PLAYER_START,      "PLAYER_START");
    AppendFlag(out, maxlen, f, TERROR_NAV_BATTLEFIELD,       "BATTLEFIELD");
    AppendFlag(out, maxlen, f, TERROR_NAV_IGNORE_VISIBILITY, "IGNORE_VIS");
    AppendFlag(out, maxlen, f, TERROR_NAV_NOT_CLEARABLE,     "NOT_CLEARABLE");
    AppendFlag(out, maxlen, f, TERROR_NAV_CHECKPOINT,        "CHECKPOINT");
    AppendFlag(out, maxlen, f, TERROR_NAV_OBSCURED,          "OBSCURED");
    AppendFlag(out, maxlen, f, TERROR_NAV_NO_MOBS,           "NO_MOBS");
    AppendFlag(out, maxlen, f, TERROR_NAV_THREAT,            "THREAT");
    AppendFlag(out, maxlen, f, TERROR_NAV_RESCUE_VEHICLE,    "RESCUE_VEH");
    AppendFlag(out, maxlen, f, TERROR_NAV_RESCUE_CLOSET,     "RESCUE_CLOSET");
    AppendFlag(out, maxlen, f, TERROR_NAV_ESCAPE_ROUTE,      "ESCAPE_ROUTE");
    AppendFlag(out, maxlen, f, TERROR_NAV_DOOR,              "DOOR");
    AppendFlag(out, maxlen, f, TERROR_NAV_NOTHREAT,          "NOTHREAT");

    // 去掉可能多余的前导 '|'
    if (out[0] == '|' && out[1] == ' ') {
        strcopy(out, maxlen, out[2]);
    }
}

static void AppendFlag(char[] out, int maxlen, int f, int bit, const char[] name)
{
    if ((f & bit) == 0) return;
    if (out[0] != '\0') StrCat(out, maxlen, "|");
    StrCat(out, maxlen, name);
}

// —— Debug: 画一条一次性光束，帮助确认你指到哪 ——
// 需要已包含 <sdktools_tempents>
static void DrawAimLineOnce(int client, const float end[3])
{
    float start[3];
    GetClientEyePosition(client, start);
    TE_SetupBeamPoints(start, end, 0, 0, 0, 5, 0.7, 2.0, 2.0, 0, 0.0, {255,255,255,255}, 0);
    TE_SendToClient(client);
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
    // [新增] —— 每波开始即清理 Path 缓存（波级作用域）
    ClearPathCache();
}
public void evt_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
    // [新增] —— 每波开始即清理 Path 缓存（波级作用域）
    ClearPathCache();
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
    // [新增] —— 每波开始即清理 Path 缓存（波级作用域）
    ClearPathCache();
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

// -------------------------
// 队列维护 & 选类规则（修复版）
// -------------------------
static void MaintainSpawnQueueOnce()
{
    RecalcSiCapFromAlive(false);  // 入队前刷新“剩余额度”
    if (gST.spawnQueueSize >= gCV.iSiLimit) return;

    int zc = 0;
    bool relax = ShouldRelaxDeathCD();  // 是否放宽死亡CD

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
        if (preferKiller)
            zc = PickEligibleKillerClass();

        // 【修复点 #1】随机兜底分支在不放宽时也过滤死亡CD
        if (zc == 0)
        {
            for (int tries = 0; tries < 8; tries++)
            {
                int pick = GetRandomInt(1, 6);
                if (!CheckClassEnabled(pick) || !CanQueueClass(pick))
                    continue;
                if (!relax && !PassDeathCooldown(pick)) // ★ 不放宽时跳过处于CD的类
                    continue;

                zc = pick;
                break;
            }
        }
    }

    // 入队前的最终资格判断 + CD处理
    if (zc != 0 && CanQueueClass(zc) && CheckClassEnabled(zc))
    {
        // 【修复点 #2】当稀缺度/兜底挑中的类处于CD，且当前不放宽时，尝试一次“替补”
        if (!PassDeathCooldown(zc) && !relax)
        {
            int alt = PickEligibleKillerClass(); // 已内部考虑CD/放宽

            // 仍找不到就再做一轮“非杀手限定”的随机替补（不放宽时必须通过CD）
            if (alt == 0)
            {
                for (int tries = 0; tries < 8; tries++)
                {
                    int p = GetRandomInt(1, 6);
                    if (!CheckClassEnabled(p) || !CanQueueClass(p))
                        continue;
                    if (!PassDeathCooldown(p)) // relax 为 false，此处必须通过CD
                        continue;

                    alt = p;
                    break;
                }
            }

            if (alt == 0)
            {
                Debug_Print("<SpawnQ> no eligible class (CD on %s) -> wait", INFDN[zc]);
                return; // 本帧确实无可用类，等待下一帧
            }

            Debug_Print("<SpawnQ> substitute %s -> %s (CD active on original)", INFDN[zc], INFDN[alt]);
            zc = alt; // 用替补继续入队
        }

        // 入队
        gQ.spawn.Push(zc);
        gST.spawnQueueSize++;
        Debug_Print("<SpawnQ> +%s size=%d", INFDN[zc], gST.spawnQueueSize);
    }
}


// =========================
// 修改 BuildNavIdIndexMap（简化）
// =========================
static void BuildNavIdIndexMap()
{
    if (g_NavIdToIndex != null) { delete g_NavIdToIndex; g_NavIdToIndex = null; }
    g_NavIdToIndex = new StringMap();
    
    EnsureNavAreasCache();  // ✅ 确保缓存存在
    
    for (int i = 0; i < g_NavAreasCacheCount; i++)
    {
        Address area = g_AllNavAreasCache.Get(i);
        int navid = L4D_GetNavAreaID(area);
        if (navid < 0) continue;
        
        char key[16]; 
        IntToString(navid, key, sizeof key);
        g_NavIdToIndex.SetValue(key, view_as<any>(i));
    }
}
static int GetAreaIndexByNavID_Int(int navid)
{
    if (g_NavIdToIndex == null) BuildNavIdIndexMap();
    char key[16]; IntToString(navid, key, sizeof key);
    any idx;
    return g_NavIdToIndex.GetValue(key, idx) ? view_as<int>(idx) : -1;
}
static void MakeBucketCachePath()
{
    char map[64];
    GetCurrentMap(map, sizeof map);
    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof dir, "data/infd_buckets");
    CreateDirectory(dir, 511);
    BuildPath(Path_SM, g_sBucketCachePath, sizeof g_sBucketCachePath, "data/infd_buckets/%s.kv", map);
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
    // [ADD] 本地 best 调试包
    SpawnScoreDbg bestDbg;
    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, false, pos, areaIdx, bestDbg);

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
        LogChosenSpawnScore(want, bestDbg);
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
    // [ADD] 本地 best 调试包
    SpawnScoreDbg bestDbg;
    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, true, pos, areaIdx, bestDbg);

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
        LogChosenSpawnScore(want, bestDbg);
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
// ✅ 新版：使用分桶百分比而非原始 flow（约第2100行）
static bool IsPosAheadOfHighest(float ref[3], int target = -1)
{
    // ✅ 使用分桶系统的百分比（已处理异常flow）
    int posPercent = GetPositionBucketPercent(ref);
    if (posPercent < 0) return false;  // 完全无法确定位置

    if (target == -1) target = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(target))
    {
        int tPct;
        if (!TryGetClientFlowPercentSafe(target, tPct))
            return false;
        
        return posPercent >= tPct;
    }
    return false;
}

// ✅ 新增：根据坐标查询其在分桶系统中的百分比
stock int GetPositionBucketPercent(float pos[3])
{
    // 1. 先找最近的 NavArea
    Address nav = L4D2Direct_GetTerrorNavArea(pos);
    if (nav == Address_Null)
        nav = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_INFECTED);
    
    if (nav == Address_Null) return -1;
    
    // 2. 查询该 NavArea 在分桶系统中的归属
    int navid = L4D_GetNavAreaID(nav);
    int areaIdx = GetAreaIndexByNavID_Int(navid);
    
    if (areaIdx < 0 || areaIdx >= g_AreaPct.Length)
        return -1;
    
    // 3. 返回分桶系统中的百分比（已处理异常flow映射）
    int bucket = view_as<int>(g_AreaPct.Get(areaIdx));
    return (bucket >= 0 && bucket <= 100) ? bucket : -1;
}

static int FlowDistanceToPercent(float flowDist)
{
    float maxd = L4D2Direct_GetMapMaxFlowDistance();
    if (maxd <= 1.0) maxd = 1.0;

    // 传入的是“距离”而非比例：做 NaN/负数/越界钳位
    float d = flowDist;
    if (!(d >= 0.0)) d = 0.0;     // NaN/负数 → 0
    if (d > maxd)    d = maxd;    // 距离上限

    // 按距离口径叠加 BossBuffer（也是距离）
    float prox = d + gCV.VsBossFlowBuffer.FloatValue;
    if (!(prox >= 0.0)) prox = 0.0;
    if (prox > maxd)    prox = maxd;

    return RoundToNearest((prox / maxd) * 100.0); // → 0..100
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
    int fb = GetHighestFlowSurvivorSafe();
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

    int target = GetHighestFlowSurvivorSafe(); // ★
    if (ns >= 1 && IsValidClient(target))
    {
        GetClientAbsOrigin(target, tmp);
        bool nearAnotherSurvivor = false;
        for (int i = 0; i < ns; i++)
        {
            if (IsPinned(target) || L4D_IsPlayerIncapacitated(target) ||
                (surv[i] != target && GetVectorDistance(sPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0)))
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
                if (IsPinned(target) || L4D_IsPlayerIncapacitated(target) ||
                    (GetVectorDistance(iPos[i], tmp, true) <= Pow(RUSH_MAN_DISTANCE, 2.0) * 1.3))
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
            EmitRushmanForward(target);
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
    int n = 0;
    float sumPct = 0.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i)) continue;
        int pct;
        if (!TryGetClientFlowPercentSafe(i, pct)) continue;
        sumPct += float(pct);
        n++;
    }
    return n > 0 ? (sumPct / float(n)) : 0.0;
}

// 【新增】只在 raw badflow 时使用：返回“应扣的分值”，而不是改后的分。
// 【新增】raw badflow 高度惩罚（只在“原始 flow 无效”时调用）
// 规则回顾：
//  - candZ > 眼睛Z + 120u        -> 不扣
//  - 眼睛Z+120 .. 眼睛Z          -> 温和线性 0..60
//  - 眼睛Z .. 眼睛Z-60           -> 陡峭线性 60..180 （到 -60 时 >100）
//  - 眼睛Z-60 以下                -> 封顶 200
stock float ComputeBadFlowHeightPenalty(float candZ, float refBestEyeZ)
{
    const float CAP = 200.0;
    float delta = refBestEyeZ - candZ;  // cand 低于“最好眼睛”的高度为正

    if (delta < -120.0) return 0.0;

    float pen;
    if (delta <= 0.0) {
        pen = 0.5 * (delta + 120.0);            // 0..60
    } else if (delta <= 60.0) {
        pen = 60.0 + 2.0 * delta;               // 60..180
    } else {
        pen = CAP;                               // 200
    }
    if (pen < 0.0) pen = 0.0;
    if (pen > CAP) pen = CAP;
    return pen;
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

    int tgt = target;
    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
        tgt = GetHighestFlowSurvivorSafe(); // ★

    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsValidSurvivor(i) && IsPlayerAlive(i)) { tgt = i; break; }
    }
    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        Debug_Print("[FALLBACK] no valid survivor to reference, abort");
        return false;
    }

    float tFeet[3]; GetClientAbsOrigin(tgt, tFeet);
    Address navTarget = L4D2Direct_GetTerrorNavArea(tFeet);
    if (navTarget == Address_Null)
        navTarget = view_as<Address>(L4D_GetNearestNavArea(tFeet, 300.0, false, false, false, TEAM_INFECTED));
    if (navTarget == Address_Null)
        return false;

    for (int i = 0; i < kTries; i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(tgt, zc, 7, pt)) continue;

        float minD = GetMinDistToAnySurvivor(pt);
        if (minD < spawnMin || minD > spawnMax + 200.0) continue;
        if (IsPosVisibleSDK(pt, teleportMode)) continue;
        if (WillStuck(pt)) continue;

        float delta = FloatAbs(spawnMax - minD);
        bool prefer = (minD <= spawnMax);

        if (!have) { bestPt = pt; have = true; bestDelta = delta; }
        else
        {
            float bestMinD = GetMinDistToAnySurvivor(bestPt);
            bool bestPrefer = (bestMinD <= spawnMax);
            if ((prefer && !bestPrefer) || (prefer == bestPrefer && delta < bestDelta))
            { bestPt = pt; bestDelta = delta; }
        }
    }

    if (!have) return false;
    outPos = bestPt;
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
// === 原实现改名：以 NavAreaID 为 key ===
bool IsNavOnCooldownID(int areaID, float now)
{
    if (areaID < 0 || g_NavCooldown == null) return false;

    char key[16];
    IntToString(areaID, key, sizeof key);

    any stored;
    if (g_NavCooldown.GetValue(key, stored))
    {
        float until = view_as<float>(stored);
        return (now < until);
    }
    return false;
}

void TouchNavCooldownID(int areaID, float now, float cooldown = 8.0)
{
    if (areaID < 0) return;
    if (g_NavCooldown == null) g_NavCooldown = new StringMap();

    char key[16];
    IntToString(areaID, key, sizeof key);
    g_NavCooldown.SetValue(key, view_as<any>(now + cooldown));
}

// === 兼容包装：仍然接受 areaIdx（内部转 NavAreaID）===
stock bool IsNavOnCooldown(int areaIdx, float now)
{
    return IsNavOnCooldownID(GetNavIDByIndex(areaIdx), now);
}
stock void TouchNavCooldown(int areaIdx, float now, float cooldown = 8.0)
{
    TouchNavCooldownID(GetNavIDByIndex(areaIdx), now, cooldown);
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
    float k = PenLimitScale();                     // 1.00 → 0.50 (随上限增大而变小)
    float SEP_RADIUS_EFF = SEP_RADIUS * k;         // 半径随之缩小，更容易靠近
    float sep2 = SEP_RADIUS_EFF * SEP_RADIUS_EFF;

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

stock bool PassRealPositionCheck(float candPos[3], int targetSur, int si=0) 
{
    // 1) 候选点的分桶百分比
    int candPercent = GetPositionBucketPercent(candPos);
    if (candPercent < 0) 
        return true;  // 无法判断就放行，避免误杀

    // 2) 目标（或最高进度）生还者的分桶百分比
    int surPercent = -1;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur))
    {
        if (!TryGetClientFlowPercentSafe(targetSur, surPercent))
            return true;
    }
    else
    {
        int fb = GetHighestFlowSurvivorSafe();
        if (!IsValidSurvivor(fb) || !TryGetClientFlowPercentSafe(fb, surPercent))
            return true;
    }

    // 3) 后方超过 6 个桶：直接禁止
    if (candPercent < surPercent - 6)
        return false;

    // 4) 你的需求：若“候选桶在生还进度后方” 且 “候选点 Z <= 所有生还者最低脚部 Z - 200u”，则禁止
    float minFootZ;
    if (TryGetLowestSurvivorFootZ(minFootZ))
    {
        // 严格“后方”：candPercent < surPercent（不含相等）
        if (candPercent < surPercent && (candPos[2] <= (minFootZ - 180.0)|| (si != view_as<int>(SI_Smoker) && candPos[2] >= (minFootZ + 200.0))))
            return false;
    }
    // 如果没找到生还者（极端情况），保持放行
    return true;
}

// 返回 true 表示找到至少一名有效、生还且有坐标的生还者；outMinZ 为他们脚底 Z 的最小值
stock bool TryGetLowestSurvivorFootZ(float &outMinZ)
{
    bool found = false;
    float bestZ = 0.0;
    float s[3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientAbsOrigin(i, s); // Source 中 origin 在脚底附近，符合“脚部 Z”的语义
        if (!found || s[2] < bestZ)
        {
            bestZ = s[2];
            found = true;
        }
    }

    if (found) outMinZ = bestZ;
    return found;
}
// =========================
// 修改 GetNavIDByIndex（需要重新获取）
// =========================
stock int GetNavIDByIndex(int idx)
{
    EnsureNavAreasCache();  // ✅ 确保缓存存在
    
    if (idx < 0 || idx >= g_NavAreasCacheCount)
        return -1;
    
    Address area = g_AllNavAreasCache.Get(idx);
    return L4D_GetNavAreaID(area);
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

    int fb = GetHighestFlowSurvivorSafe();
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

// 运行时计算当前扇区数：最低2；其余= ceil(目标T/2)+1；再夹在 [2, SECTORS_MAX]
static int GetCurrentSectors()
{
    int T = gCV.iSiLimit;
    int n = (T <= 2) ? 2 : (RoundToCeil(float(T) / 2.0) + 1);
    if (n < DYN_SECTORS_MIN) n = DYN_SECTORS_MIN;
    if (n > SECTORS_MAX)     n = SECTORS_MAX;
    return n;
}

// 判异常：flow < 0 或 > 地图最大 flow
static bool IsFlowAbnormal(float flowDist, float maxFlow)
{
    if (maxFlow <= 0.0) return true;
    return (flowDist < 0.0 || flowDist > maxFlow);
}

static bool TryGetFlowDistanceFromArea(Address area, float &outFlow)
{
    if (area == Address_Null) return false;
    float d = L4D2Direct_GetTerrorNavAreaFlow(area);
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (IsFlowAbnormal(d, maxFlow)) return false;
    outFlow = d;
    return true;
}

// ★核心兜底：为 client 拿“安全 flow 距离”
// 1) 直接读玩家 flow；异常 → 2) 用 L4D_GetLastKnownArea(client) 取 Nav flow；仍异常 → 3) 最近 NavArea。
static bool TryGetClientFlowDistanceSafe(int client, float &outFlow)
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();

    float d = L4D2Direct_GetFlowDistance(client);
    if (!IsFlowAbnormal(d, maxFlow)) { outFlow = d; return true; }

    // ★ 显式兜底：使用 L4D_GetLastKnownArea（你要求的函数）
    Address last = view_as<Address>(L4D_GetLastKnownArea(client));
    if (TryGetFlowDistanceFromArea(last, outFlow)) return true;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    Address near = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_SURVIVOR);
    if (TryGetFlowDistanceFromArea(near, outFlow)) return true;

    return false;
}

// 百分比封装
static bool TryGetClientFlowPercentSafe(int client, int &outPct)
{
    float d;
    if (!TryGetClientFlowDistanceSafe(client, d)) return false;
    outPct = FlowDistanceToPercent(d);
    if (outPct < 0) outPct = 0;
    if (outPct > 100) outPct = 100;
    return true;
}

// 最高进度幸存者（安全版）
static int GetHighestFlowSurvivorSafe()
{
    int best = -1, bestPct = -1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        int pct;
        if (!TryGetClientFlowPercentSafe(i, pct)) continue;
        if (pct > bestPct) { bestPct = pct; best = i; }
    }
    if (best != -1) return best;
    // 若全部失败，退回引擎原生（极端保护）
    return L4D_GetHighestFlowSurvivor();
}

static bool IsValidFlags(int iFlags, bool bFinaleArea)
{
    if (!iFlags)
        return true;

    if (bFinaleArea && (iFlags & TERROR_NAV_FINALE) == 0)
        return false;

    return (iFlags & (TERROR_NAV_RESCUE_CLOSET|TERROR_NAV_RESCUE_VEHICLE|TERROR_NAV_CHECKPOINT)) == 0;
}

// [修改] —— 高度感知的 ring 弹性（加入近距离屋顶衰减因子）
static float HeightRingSlack(const float p[3], float bucketMinZ, float bucketMaxZ, float allMaxEyeZ)
{
    float zRange = bucketMaxZ - bucketMinZ;
    if (zRange < 1.0) zRange = 1.0;

    // 桶内高度归一化（越高越接近 1）
    float zNorm  = (p[2] - bucketMinZ) / zRange;
    if (zNorm < 0.0) zNorm = 0.0;
    if (zNorm > 1.0) zNorm = 1.0;

    // 基础弹性：线性从 0..zRange（上限 2*RING_SLACK）
    float base = FloatMin(zRange + 50.0, RING_SLACK * 2.0) * zNorm;

    // 超过“所有幸存者最大眼睛 + 200u”后，对弹性做竖直衰减
    float over   = FloatMax(0.0, p[2] - (allMaxEyeZ + 200.0));
    float taperZ = 1.0 / (1.0 + over / 150.0);  // 150u 每级衰减

    return base * taperZ;
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
    if (g_AreaCX  != null) { delete g_AreaCX;  g_AreaCX  = null; }
    if (g_AreaCY  != null) { delete g_AreaCY;  g_AreaCY  = null; }
    if (g_AreaPct != null) { delete g_AreaPct; g_AreaPct = null; }
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
    if (TryLoadBucketsFromCache())
        return;
        
    ClearNavBuckets();
    BuildNavIdIndexMap();

    EnsureNavAreasCache();
    int iAreaCount = g_NavAreasCacheCount;
    
    float fMapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    bool  bFinaleArea     = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < 18;

    g_AreaZCore = new ArrayList(); 
    g_AreaZMin  = new ArrayList(); 
    g_AreaZMax  = new ArrayList();
    g_AreaCX    = new ArrayList(); 
    g_AreaCY    = new ArrayList(); 
    g_AreaPct   = new ArrayList();
    
    for (int i = 0; i < iAreaCount; i++)
    {
        g_AreaZCore.Push(0.0); 
        g_AreaZMin.Push(0.0); 
        g_AreaZMax.Push(0.0);
        g_AreaCX.Push(0.0);    
        g_AreaCY.Push(0.0);   
        g_AreaPct.Push(-1);
    }
    
    for (int b = 0; b < FLOW_BUCKETS; b++) 
    { 
        g_BucketMinZ[b] =  1.0e9; 
        g_BucketMaxZ[b] = -1.0e9; 
    }

    for (int b = 0; b < FLOW_BUCKETS; b++)
        g_FlowBuckets[b] = null;

    ArrayList badIdxs   = new ArrayList();
    ArrayList validIdxs = new ArrayList();

    int addedValid = 0, addedBad = 0, skippedFlag = 0;

    // ★ 新增：标记“原始 flow 无效”的区域（后续用于同桶尾置）
    ArrayList wasBad = new ArrayList();
    for (int i = 0; i < iAreaCount; i++) wasBad.Push(0);

    // === 第一遍：采样 + 直接入桶 ===
    for (int i = 0; i < iAreaCount; i++)
    {
        Address areaAddr = g_AllNavAreasCache.Get(i);
        if (areaAddr == Address_Null) continue;

        NavArea pArea = view_as<NavArea>(areaAddr);

        if (!IsValidFlags(pArea.SpawnAttributes, bFinaleArea)) 
        { 
            skippedFlag++; 
            continue; 
        }

        float cx, cy, zAvg, zMin, zMax;
        SampleAreaCenterAndZ(areaAddr, cx, cy, zAvg, zMin, zMax, 3);
        g_AreaCX.Set(i, cx); 
        g_AreaCY.Set(i, cy);
        g_AreaZCore.Set(i, zAvg); 
        g_AreaZMin.Set(i, zMin); 
        g_AreaZMax.Set(i, zMax);

        float fFlow = pArea.GetFlow();
        bool  flowOK = (fFlow >= 0.0 && fFlow <= fMapMaxFlowDist);
        
        if (flowOK)
        {
            int percent = FlowDistanceToPercent(fFlow);
            if (percent < 0) percent = 0; 
            if (percent > 100) percent = 100;

            if (g_FlowBuckets[percent] == null)
                g_FlowBuckets[percent] = new ArrayList();
            g_FlowBuckets[percent].Push(i);

            if (zMin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zMin;
            if (zMax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zMax;

            g_AreaPct.Set(i, percent);
            validIdxs.Push(i);
            addedValid++;
        }
        else
        {
            badIdxs.Push(i);
            wasBad.Set(i, 1); // ★ 标记为原始 bad flow
            addedBad++;
        }
    }

    // === 第二遍：映射坏flow的area ===
    int mapped = 0, dropped = 0;
    if (gCV.bNavBucketMapInvalid && validIdxs.Length > 0 && badIdxs.Length > 0)
    {
        float maxR2 = (gCV.fNavBucketAssignRadius > 0.1) ? 
                      (gCV.fNavBucketAssignRadius * gCV.fNavBucketAssignRadius) : -1.0;

        for (int bi = 0; bi < badIdxs.Length; bi++)
        {
            int aidx = badIdxs.Get(bi);

            float ax = view_as<float>(g_AreaCX.Get(aidx));
            float ay = view_as<float>(g_AreaCY.Get(aidx));

            float bestD2 = 1.0e12;
            int   bestV  = -1;
            
            for (int vi = 0; vi < validIdxs.Length; vi++)
            {
                int vidx = validIdxs.Get(vi);
                float vx = view_as<float>(g_AreaCX.Get(vidx));
                float vy = view_as<float>(g_AreaCY.Get(vidx));
                float dx = ax - vx, dy = ay - vy;
                float d2 = dx*dx + dy*dy;
                if (d2 < bestD2) { bestD2 = d2; bestV = vidx; }
            }

            if (bestV == -1 || (maxR2 > 0.0 && bestD2 > maxR2))
            {
                dropped++;
                continue;
            }

            int percent = view_as<int>(g_AreaPct.Get(bestV));
            if (percent < 0) { dropped++; continue; }

            if (g_FlowBuckets[percent] == null)
                g_FlowBuckets[percent] = new ArrayList();
            g_FlowBuckets[percent].Push(aidx);

            float zMin = view_as<float>(g_AreaZMin.Get(aidx));
            float zMax = view_as<float>(g_AreaZMax.Get(aidx));
            if (zMin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zMin;
            if (zMax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zMax;

            g_AreaPct.Set(aidx, percent);
            mapped++;
        }
    }

    // === 改进：按 Z 轴智能排序（上方优先，下方延后） ===
    float lowestSurvivorZ = GetLowestSurvivorFootZ();
    
    for (int b = 0; b < FLOW_BUCKETS; b++)
    {
        ArrayList L = g_FlowBuckets[b];
        if (L == null || L.Length == 0) continue;

        ArrayList above = new ArrayList();
        ArrayList same  = new ArrayList();
        ArrayList below = new ArrayList();

        for (int i = 0; i < L.Length; i++)
        {
            int areaIdx = L.Get(i);
            float zCore = view_as<float>(g_AreaZCore.Get(areaIdx));
            float deltaZ = zCore - lowestSurvivorZ;
            
            if (deltaZ > 120.0)
                above.Push(areaIdx);
            else if (deltaZ < -80.0)
                below.Push(areaIdx);
            else
                same.Push(areaIdx);
        }

        ShuffleArrayList(above);
        ShuffleArrayList(same);
        ShuffleArrayList(below);

        L.Clear();
        for (int i = 0; i < same.Length; i++)  L.Push(same.Get(i));
        for (int i = 0; i < above.Length; i++) L.Push(above.Get(i));
        for (int i = 0; i < below.Length; i++) L.Push(below.Get(i));

        delete above;
        delete same;
        delete below;

        // ★ 新增：把“原始 bad flow（被映射来的）”稳定移到桶的末尾
        {
            ArrayList normals = new ArrayList();
            ArrayList mappedBad = new ArrayList();

            for (int i = 0; i < L.Length; i++)
            {
                int areaIdx = L.Get(i);
                int isBad = view_as<int>(wasBad.Get(areaIdx));
                if (isBad != 0)
                    mappedBad.Push(areaIdx);
                else
                    normals.Push(areaIdx);
            }

            L.Clear();
            for (int i = 0; i < normals.Length; i++)    L.Push(normals.Get(i));
            for (int i = 0; i < mappedBad.Length; i++)  L.Push(mappedBad.Get(i));

            delete normals;
            delete mappedBad;
        }

        if (L.Length == 0) { g_BucketMinZ[b] = 0.0; g_BucketMaxZ[b] = 0.0; }
        if (g_BucketMinZ[b] > g_BucketMaxZ[b]) { g_BucketMinZ[b] = g_BucketMaxZ[b] = 0.0; }
    }

    // ★ 清理标记表
    delete wasBad;

    delete badIdxs;
    delete validIdxs;

    g_BucketsReady = true;
    Debug_Print("[BUCKET] valid=%d, bad=%d, mapped=%d, dropped=%d, skipFlag=%d",
        addedValid, addedBad, mapped, dropped, skippedFlag);

    SaveBucketsToCache();
}

// ✅ 新增：获取所有生还者的最低脚位置（约第2850行）
stock float GetLowestSurvivorFootZ()
{
    float lowest = 999999.0;
    float pos[3];
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;
        
        GetClientAbsOrigin(i, pos);
        if (pos[2] < lowest)
            lowest = pos[2];
    }
    
    // 如果没有生还者（异常情况），返回一个合理的默认值
    return (lowest < 999999.0) ? lowest : 0.0;
}

stock void ShuffleArrayList(ArrayList L)
{
    int n = L.Length;
    for (int i = n - 1; i > 0; i--)
    {
        int j = GetRandomInt(0, i);
        if (j == i) continue;
        int ai = L.Get(i), aj = L.Get(j);
        L.Set(i, aj); L.Set(j, ai);
    }
}

// ✅ 修改：重建 Buckets 时确保缓存新鲜
static Action Timer_RebuildBuckets(Handle timer)
{
    // 如果本局本图已经有可用缓存，就别动了
    if (g_BucketsReady && g_AllNavAreasCache != null && g_NavAreasCacheCount > 0)
    {
        // Debug_Print("[NAV CACHE] Skip rebuild (already warm)");
        return Plugin_Stop;
    }

    // 只在“没有缓存”时，补齐一次（不会触发 Cleared 日志）
    EnsureNavAreasCache();   // 仅确保存在，不清空
    BuildNavBuckets();       // 内部会 TryLoadBucketsFromCache()
    return Plugin_Stop;
}

static void RebuildNavBuckets()
{
    BuildNavBuckets();
}

static bool FindDropLanding(const float from[3], float outLand[3], float maxDrop = 480.0)
{
    float start[3];
    start[0] = from[0];
    start[1] = from[1];
    start[2] = from[2] + 1.0;

    float end[3];
    end[0] = from[0];
    end[1] = from[1];
    end[2] = from[2] - maxDrop;

    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
    if (!TR_DidHit(tr))
    {
        delete tr;
        return false;
    }

    TR_GetEndPosition(outLand, tr);
    delete tr;

    Address nav = L4D_GetNearestNavArea(outLand, 120.0, false, false, false, TEAM_INFECTED);
    return nav != Address_Null;
}

// [新增] 解决 error 017: undefined symbol "Clamp"
stock float clamp(float val, float min, float max)
{
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

// [新增] 新评分系统 - 计算高度得分 (可为负)
// [ADD] New Scoring System - Calculate Height Score (can be negative)
stock float CalculateScore_Height(int zc, const float p[3], float refEyeZ)
{
    float zRel = p[2] - refEyeZ;

    // --- 平面型特感 (Charger / Jockey) ---
    if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
    {
        const float CJ_ALLOWED_PLANE = 150.0;
        float distPlane = FloatAbs(zRel);
        if (distPlane <= CJ_ALLOWED_PLANE)
        {
            return 90.0 - (distPlane / CJ_ALLOWED_PLANE) * 20.0; // 在平面内，分数 70-90
        }
        else
        {
            return 60.0 - (distPlane - CJ_ALLOWED_PLANE) * 0.2; // 偏离平面则分数骤减
        }
    }

    // --- 垂直/通用型特感 ---
    float score = 0.0;
    const float HEIGHT_PEAK_WINDOW = 400.0;
    const float TAPER_BASE_DIST = 250.0;

    if (zRel <= 20.0) // 在下方或略高，不加分
    {
        score = 0.0;
    }
    else if (zRel <= HEIGHT_PEAK_WINDOW) // 在理想高度区间内，线性加分
    {
        score = (zRel / HEIGHT_PEAK_WINDOW) * 100.0;
    }
    else // 超出理想高度，分数衰减
    {
        float over = zRel - HEIGHT_PEAK_WINDOW;
        float taper = 1.0 / (1.0 + (over / TAPER_BASE_DIST));
        score = 100.0 * taper;
    }

    // 空降潜力加分
    float land[3];
    if (FindDropLanding(p, land))
    {
        float d = GetMinDistToAnySurvivor(land);
        if (d < 450.0) score += 40.0 * (1.0 - d/450.0); // 离落点越近，加分越多
    }
    
    return score;
}

// [新增] 新评分系统 - 计算流程位置得分 (0-100)
// [ADD] New Scoring System - Calculate Flow Position Score (0-100)
stock float CalculateScore_Flow(int candBucket, int survBucket)
{
    int delta = candBucket - survBucket;

    if (delta > 0 && delta <= 8) // 在生还者前方不远处，是最佳埋伏点
    {
        return 100.0;
    }
    else if (delta > 8 && delta <= 20) // 在前方较远处
    {
        return 70.0;
    }
    else if (delta == 0) // 与生还者在同一进度
    {
        return 50.0;
    }
    else if (delta < 0 && delta >= -10) // 在后方不远处
    {
        return 30.0;
    }

    return 10.0; // 在遥远的后方或前方
}

// [新增] 新评分系统 - 计算分散度得分 (-50 - 100)
// [ADD] New Scoring System - Calculate Dispersion Score (-50 to 100)
// [修改] 解决 warning 219: local variable "recentSectors" shadows a variable
stock float CalculateScore_Dispersion(int sidx, int preferredSector, const int a_recentSectors[3])
{
    float k = PenLimitScale(); // 1.00..0.50
    if (sidx == preferredSector)      return 100.0;      // 正向奖励不缩
    if (sidx == a_recentSectors[0])   return -50.0 * k;  // 最近扇区的负分随上限减半
    if (sidx == a_recentSectors[1])   return -25.0 * k;  // 次近扇区同理
    if (sidx == a_recentSectors[2])   return 0.0;
    return 50.0;
}

// [新增] —— 简易 e^x 封装（SourcePawn 没有 Exp，改用 Pow）
#define M_E 2.718281828459045
stock float ExpF(float x)
{
    return Pow(M_E, x);
}

// [新增] —— Logistic 距离评分（0..100），围绕“类目甜点”对称衰减
// [修改] —— 距离平滑评分：以“甜点距离 sweet”为中心的对称衰减
stock float ScoreDistSmooth(float dminEye, float sweet, float width)
{
    // 防御：宽度太小会过于尖锐
    if (width < 1.0) width = 1.0;

    // 归一化偏差
    float t = FloatAbs(dminEye - sweet) / width;

    // 100 / (1 + e^(k*t))，t 越大衰减越多；k 适中给点锐度
    float k = 1.5;
    float s = 100.0 / (1.0 + ExpF(k * t));

    // 限幅，避免因为极端参数出 0 分或 100+ 分
    return clamp(s, 10.0, 100.0);
}

// [新增] —— 各类的甜点距离与宽度（可按需改成 CVar）
stock void GetClassDistanceProfile(int zc, float min, float max, float &sweet, float &width)
{
    float span = FloatMax(1.0, max - min);
    switch (zc) {
        case view_as<int>(SI_Boomer): { sweet = min + 0.25*span; width = 0.22*span; }
        case view_as<int>(SI_Hunter): { sweet = min + 0.45*span; width = 0.28*span; }
        case view_as<int>(SI_Smoker): { sweet = min + 0.60*span; width = 0.30*span; }
        case view_as<int>(SI_Spitter):{ sweet = min + 0.40*span; width = 0.25*span; }
        case view_as<int>(SI_Jockey): { sweet = min + 0.35*span; width = 0.24*span; }
        case view_as<int>(SI_Charger):{ sweet = min + 0.38*span; width = 0.26*span; }
        default: { sweet = min + 0.40*span; width = 0.25*span; }
    }
}

// [ADD] —— 通过 areaIdx 直接反查分桶（优先缓存，其次 Flow→Percent）
stock bool TryGetBucketByAreaIdx(int areaIdx, int &outBucket)
{
    outBucket = -1;
    if (areaIdx < 0) return false;

    if (g_AreaPct != null && areaIdx < g_AreaPct.Length)
    {
        int b = view_as<int>(g_AreaPct.Get(areaIdx));
        if (b >= 0 && b <= 100) { outBucket = b; return true; }
    }

    if (g_AllNavAreasCache != null && areaIdx < g_NavAreasCacheCount)
    {
        Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
        if (areaAddr != Address_Null)
        {
            NavArea area = view_as<NavArea>(areaAddr);
            if (area)
            {
                float f   = area.GetFlow();
                float max = L4D2Direct_GetMapMaxFlowDistance();
                if (f >= 0.0 && f <= max)
                {
                    int b2 = FlowDistanceToPercent(f);
                    if (b2 < 0) b2 = 0; if (b2 > 100) b2 = 100;
                    outBucket = b2;
                    return true;
                }
            }
        }
    }
    return false;
}

// [MOD] —— 覆盖：无重叠、可读的 Flow 评分
// 语义：略微领先（+1..+5）最好；过远前方衰减；同进度中性；落后扣分。
stock float ScoreFlowSmooth(int deltaFlow)
{
    // 后方：-12 以下直接给极低
    if (deltaFlow <= -12) return 0.0;

    // 后方：-11..-1 线性爬升到 30 分（仍然是偏低，鼓励前置）
    if (deltaFlow < 0)
    {
        // -11 -> 5 分,  -1 -> 30 分
        float t = float(deltaFlow + 11) / 10.0;      // 0..1
        return 5.0 + t * 25.0;                       // 5..30
    }

    // 同进度：给中性 50 分
    if (deltaFlow == 0) return 50.0;

    // 前方近距离最佳：+1..+5 → 100 分
    if (deltaFlow <= 5) return 100.0;

    // 前方中距离：+6..+12 从 85 线性降到 45
    if (deltaFlow <= 12)
    {
        float t = float(deltaFlow - 6) / 6.0;        // 0..1
        return 85.0 - t * 40.0;                      // 85..45
    }

    // 前方太远（>+12）：缓慢衰减到 30~40 的平台
    // 用个平滑函数避免突变
    float over = float(deltaFlow - 12);
    float s = 40.0 / (1.0 + (over / 8.0));           // 40 → 渐近 0
    return 30.0 + clamp(s, 0.0, 40.0);               // 30..70（但很快收敛到 30~40）
}

// === Limit-aware penalty scale (uses PEN_LIMIT_* macros) ===
stock float PenLimitScale()
{
    // iSiLimit 在 gCV 里；把它压到 [PEN_LIMIT_MINL .. PEN_LIMIT_MAXL]
    float L = float(gCV.iSiLimit);
    float t = Clamp01((L - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL));
    // L=MINL 时返回 1.0（惩罚原强度）；L=MAXL 及以上时返回 0.5（惩罚减半）
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

// ===============================
// 【修改/整段覆盖】TryPickValidSpotInArea
// 说明：一个 NavArea 只尝试 1 个随机点（去掉多次采样循环）
// 参数第4个为 ringEff（每桶临时 ring 上界）
// ===============================
stock bool TryPickValidSpotInArea(int areaIdx, int targetSur,
                                  float ringEff, bool teleportMode,
                                  float outPos[3], SpawnScoreDbg dbg)
{
    // 基本检查
    EnsureNavAreasCache();
    if (areaIdx < 0 || areaIdx >= g_NavAreasCacheCount) return false;

    Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
    if (areaAddr == Address_Null) return false;

    NavArea na = view_as<NavArea>(areaAddr);
    float now = GetGameTime();

    // NavArea 短冷却
    if (IsNavOnCooldown(areaIdx, now))
        return false;

    // Nav flags 过滤
    bool bFinaleArea = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < 18;
    if (!IsValidFlags(na.SpawnAttributes, bFinaleArea))
        return false;

    // —— 预取该 Area 所在桶，以及该桶的 Z 范围（用于高度弹性）——
    float bucketMinZ = 0.0, bucketMaxZ = 0.0;
    int candBucket = -1;
    if (g_BucketsReady && g_AreaPct != null && areaIdx >= 0 && areaIdx < g_AreaPct.Length)
    {
        candBucket = view_as<int>(g_AreaPct.Get(areaIdx)); // 0..100 或 -1
        if (0 <= candBucket && candBucket <= 100)
        {
            bucketMinZ = g_BucketMinZ[candBucket];
            bucketMaxZ = g_BucketMaxZ[candBucket];
        }
    }

    // 计算“全队最高眼睛高度”，供高度弹性参考
    float bestEyeZ = -1.0e9;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
        {
            float ez[3]; GetClientEyePosition(i, ez);
            if (ez[2] > bestEyeZ) bestEyeZ = ez[2];
        }
    }
    if (bestEyeZ <= -1.0e8) bestEyeZ = 0.0;

    // 【删除】原 kTries=6 的多次采样循环
    // 【修改】只取 1 个随机点
    float p[3];
    na.GetRandomPoint(p);

    // 距离：下限 SpawnMin，上限 = 每桶 ring + 高度弹性
    float dminEye = GetMinEyeDistToAnySurvivor(p);
    float slack = 0.0;
    if (0 <= candBucket && candBucket <= 100)
        slack = HeightRingSlack(p, bucketMinZ, bucketMaxZ, bestEyeZ);

    if (!(dminEye >= gCV.fSpawnMin && dminEye <= ringEff + slack))
        return false;

    // 可见性：对所有存活幸存者不可见（teleportMode 时可忽略倒地者）
    if (IsPosVisibleSDK(p, teleportMode))
        return false;

    // 分散度：与最近 N 次刷点保持最小间距
    if (!PassMinSeparation(p))
        return false;

    // 卡壳：Hull 碰撞体检查
    if (WillStuck(p))
        return false;

    // 路径：PathPenalty_NoBuild 为 0 表示通
    float pathPenalty = PathPenalty_NoBuild(p, targetSur, gCV.fSpawnMax, gCV.fSpawnMax);
    if (pathPenalty != 0.0)
        return false;

    // —— 通过所有硬条件：回填并返回 —— //
    outPos = p;

    // 只填基础字段；完整打分交给 ScoreCandidate
    dbg.dminEye    = dminEye;
    dbg.candBucket = candBucket;
    dbg.pos        = p;
    dbg.ringEff    = ringEff;
    dbg.rawBadFlow = false;

    return true;
}

// ====================================================
// [新增] 对单个候选点进行评分（距离/高度/流程/分散度）
// 依赖：ScoreDistSmooth / GetClassDistanceProfile /
//      CalculateScore_Height / CalculateScore_Flow /
//      CalculateScore_Dispersion / ComputePenScaleByLimit /
//      ScaleNegativeOnly / GetSectorCenter / GetCurrentSectors / ComputeSectorIndex
// 【修改】ScoreCandidate：集成 raw badflow 高度惩罚（可开关+缩放）
// ===============================
stock float ScoreCandidate(int zc, float pos[3], int centerBucket,
                           SpawnScoreDbg dbg, float ringForDbg)
{
    // 1) 距离（眼睛最近距离）
    float dminEye = GetMinEyeDistToAnySurvivor(pos);
    float sweet, width; GetClassDistanceProfile(zc, gCV.fSpawnMin, gCV.fSpawnMax, sweet, width);
    float s_dist = ScoreDistSmooth(dminEye, sweet, width);

    // 2) 高度（参考目标：最高眼睛以更保守）
    float bestEyeZ = -1.0e9;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidSurvivor(i) && IsPlayerAlive(i)) {
            float ez[3]; GetClientEyePosition(i, ez);
            if (ez[2] > bestEyeZ) bestEyeZ = ez[2];
        }
    }
    if (bestEyeZ <= -1.0e8) bestEyeZ = 0.0;
    float s_hght = CalculateScore_Height(zc, pos, bestEyeZ);

    // 3) 流程（candBucket 相对 centerBucket）
    int candBucket = GetPositionBucketPercent(pos);
    if (candBucket < 0) candBucket = centerBucket;   // 取不到时与中心等同
    int  deltaFlow = candBucket - centerBucket;
    float s_flow   = CalculateScore_Flow(candBucket, centerBucket);

    // —— 仅当“原始 flow 无效”时叠加高度惩罚 —— //
    bool rawBadFlow = false;
    if (gCV.bFlowBadPenaltyEnable) {
        Address nav = L4D2Direct_GetTerrorNavArea(pos);
        if (nav == Address_Null)
            nav = view_as<Address>(L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_INFECTED));

        if (nav != Address_Null) {
            float d = L4D2Direct_GetTerrorNavAreaFlow(nav);
            float maxF = L4D2Direct_GetMapMaxFlowDistance();
            if (IsFlowAbnormal(d, maxF)) {
                rawBadFlow = true;
                float pen = ComputeBadFlowHeightPenalty(pos[2], bestEyeZ);
                s_flow -= gCV.fFlowBadPenaltyScale * pen;
                if (s_flow > 100.0)  s_flow = 100.0;
                if (s_flow < -200.0) s_flow = -200.0;
            }
        }
    }

    // 4) 分散度（最近扇区负分缩放）
    float center[3]; GetSectorCenter(center, GetHighestFlowSurvivorSafe());
    int sectors = GetCurrentSectors();
    int prefSec = PickSector(sectors);
    int sidx    = ComputeSectorIndex(center, pos, sectors);
    float s_disp_raw = CalculateScore_Dispersion(sidx, prefSec, recentSectors);
    float penK = ComputePenScaleByLimit(gCV.iSiLimit);
    float s_disp = (s_disp_raw < 0.0) ? (s_disp_raw * penK) : s_disp_raw;

    // 聚合
    float total = gCV.w_dist[zc]*s_dist + gCV.w_hght[zc]*s_hght
                + gCV.w_flow[zc]*s_flow + gCV.w_disp[zc]*s_disp;

    // 回填调试
    dbg.total        = total;
    dbg.dist         = s_dist;
    dbg.hght         = s_hght;
    dbg.flow         = s_flow;
    dbg.dispRaw      = s_disp_raw;
    dbg.dispScaled   = s_disp;
    dbg.penK         = penK;
    dbg.dminEye      = dminEye;
    dbg.centerBucket = centerBucket;
    dbg.candBucket   = candBucket;
    dbg.deltaFlow    = deltaFlow;
    dbg.sector       = sidx;
    dbg.pos          = pos;
    dbg.rawBadFlow   = rawBadFlow;   // 【修改】回传是否使用了 raw badflow 惩罚
    dbg.ringEff      = ringForDbg;   // 【新增】用掉 ringForDbg，消除警告

    return total;
}


// ===============================
// 【修改/整段覆盖】FindSpawnPosViaNavArea
//  - 多桶并行评分 + First-Fit
//  - 每桶 ring 扩展（按桶偏移量）
//  - topK/配额/全局软限
//  - 分桶缺失时兜底扫描
// ===============================
stock bool FindSpawnPosViaNavArea(int zc, int targetSur, float ring, bool teleportMode,
                                  float outPos[3], int &outAreaIdx, SpawnScoreDbg outDbg)
{
    outAreaIdx = -1;

    // —— 计算“中心桶”（以目标幸存者为参考；退化用最高进度；再不行用 50%） —— //
    int centerBucket = -1;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur))
        TryGetClientFlowPercentSafe(targetSur, centerBucket);
    if (centerBucket < 0) {
        int fb = GetHighestFlowSurvivorSafe();
        if (IsValidSurvivor(fb)) TryGetClientFlowPercentSafe(fb, centerBucket);
    }
    if (centerBucket < 0) centerBucket = 50;

    // —— First-Fit（命中即返，提高速度） —— //
    bool FIRST_FIT = gCV.bNavBucketFirstFit;

    // —— 评分池 / 配额 / 软限参数 —— //
    int TOPK  = gCV.iCandTopK;                 // 【新增】评分池上限（如：27）
    if (TOPK < 1) TOPK = 1;
    int GLOBAL_CAP = gCV.iCandGlobalCap;       // 【新增】全局扫描软限（如：32）
    if (GLOBAL_CAP < TOPK) GLOBAL_CAP = TOPK;  // 软限至少不低于 TOPK

    // —— 分桶相关 —— //
    bool USE_BUCKETS = (gCV.bNavBucketEnable && g_BucketsReady);
    int pickedBucketsMax   = gCV.iNavBucketPickCount;           // 参与评分的桶个数（含中心桶）
    if (pickedBucketsMax < 1) pickedBucketsMax = 1;

    // ★ 兜底存放“当前最佳”
    float bestScore = -1.0e12;
    float bestPos[3];
    int   bestAreaIdx = -1;
    SpawnScoreDbg bestDbg;

    // =========================================
    // 分桶分支
    // =========================================
    if (USE_BUCKETS)
    {
        // —— 动态窗口 ±N —— //
        int win = ComputeDynamicBucketWindow(ring);

        // —— 生成桶扫描顺序（中心向外，前2后1推进） —— //
        int ordered[FLOW_BUCKETS];
        int nOrdered = BuildBucketOrder(centerBucket, win, gCV.bNavBucketIncludeCtr, ordered);

        // —— 确定“要参与的桶集合” + 每桶配额 —— //
        int baseNum = gCV.iBucketBaseQuotaNum, baseDen = gCV.iBucketBaseQuotaDen;
        int othNum  = gCV.iBucketOtherQuotaNum, othDen  = gCV.iBucketOtherQuotaDen;
        if (baseDen <= 0) baseDen = 1;
        if (othDen  <= 0) othDen  = 1;

        // 例：TOPK=27, 基桶=1/3→9；其他=2/9→6
        int baseQuota  = RoundToCeil(float(TOPK) * float(baseNum) / float(baseDen));
        int otherQuota = RoundToCeil(float(TOPK) * float(othNum)  / float(othDen));
        if (baseQuota  < 1) baseQuota  = 1;
        if (otherQuota < 1) otherQuota = 1;

        int bucketQuota[FLOW_BUCKETS];
        int bucketTaken[FLOW_BUCKETS];
        for (int i = 0; i < FLOW_BUCKETS; i++) { bucketQuota[i] = 0; bucketTaken[i] = 0; }

        // 第一遍：挑出要参与的若干桶并分配配额
        int selected = 0;
        for (int i = 0; i < nOrdered && selected < pickedBucketsMax; i++)
        {
            int b = ordered[i];
            if (b < 0 || b > 100) continue;

            ArrayList arr = g_FlowBuckets[b];
            if (arr == null || arr.Length == 0) continue;  // 空桶跳过

            // 给中心桶配“基桶配额”，其它桶配“其他配额”
            bucketQuota[b] = (b == centerBucket) ? baseQuota : otherQuota;
            selected++;
        }

        // —— Second pass：实际扫描，遵循每桶配额 & 全局软限 & TOPK —— //
        int globalTaken = 0;

        for (int i = 0; i < nOrdered; i++)
        {
            int b = ordered[i];
            if (b < 0 || b > 100) continue;
            if (bucketQuota[b] <= 0) continue;             // 未被选入的桶

            ArrayList areas = g_FlowBuckets[b];
            if (areas == null || areas.Length == 0) continue;

            // 【新增】每桶“临时 ring”扩展：基于桶偏移量
            int   deltaBuckets   = (b > centerBucket) ? (b - centerBucket) : (centerBucket - b);
            float ringEffBucket  = ring + float(deltaBuckets) * (FLOW_TO_RING_SCALE * 100.0);
            if (ringEffBucket > gCV.fSpawnMax) ringEffBucket = gCV.fSpawnMax;

            // —— 遍历该桶的区域 —— //
            for (int ai = 0; ai < areas.Length; ai++)
            {
                // 全局停止条件
                if (globalTaken >= GLOBAL_CAP) break;
                if (!FIRST_FIT && globalTaken >= TOPK) break;

                int areaIdx = areas.Get(ai);

                float cand[3];
                SpawnScoreDbg dbg;

                // 【修改】此处使用“每桶 ring”做硬条件过滤（距离上界在 TryPick 内部以 ringEff 叠加 HeightRingSlack）
                if (!TryPickValidSpotInArea(areaIdx, targetSur, /*ringEff=*/ringEffBucket, teleportMode, cand, dbg))
                    continue;

                // First-Fit：命中第一处合格点即返
                if (FIRST_FIT)
                {
                    // 仍然调用一次 ScoreCandidate 以便日志/调试完整
                    ScoreCandidate(zc, cand, centerBucket, dbg, /*ringForDbg=*/ringEffBucket);
                    outPos = cand;
                    outAreaIdx = areaIdx;
                    outDbg = dbg;
                    return true;
                }

                // 并行评分：打分 + 维护当前“最佳”
                ScoreCandidate(zc, cand, centerBucket, dbg, /*ringForDbg=*/ringEffBucket);

                if (dbg.total > bestScore)
                {
                    bestScore   = dbg.total;
                    bestPos     = cand;
                    bestAreaIdx = areaIdx;
                    bestDbg     = dbg;
                }

                // 计数 & 配额
                bucketTaken[b]++;
                globalTaken++;

                if (bucketTaken[b] >= bucketQuota[b])      // 本桶配额已满
                    break;
            }

            // 全局停止条件（每桶循环尾再次判断）
            if (globalTaken >= GLOBAL_CAP) break;
            if (!FIRST_FIT && globalTaken >= TOPK) break;
        }

        if (bestAreaIdx >= 0)
        {
            outPos = bestPos;
            outAreaIdx = bestAreaIdx;
            outDbg = bestDbg;
            return true;
        }

        return false; // 分桶启用但没找到
    }

    // =========================================
    // 兜底分支：分桶不可用时的“全图有限扫描 + topK”
    // =========================================
    {
        EnsureNavAreasCache();  // 使用已缓存的 NavAreas
        if (g_NavAreasCacheCount <= 0) return false;

        int maxScan = GLOBAL_CAP;                 // 兜底扫描量：不超过软限
        int step    = 1 + (g_NavAreasCacheCount / maxScan);
        if (step < 1) step = 1;

        int globalTaken = 0;

        for (int i = 0; i < g_NavAreasCacheCount; i += step)
        {
            if (globalTaken >= GLOBAL_CAP) break;
            if (!FIRST_FIT && globalTaken >= TOPK) break;

            Address area = g_AllNavAreasCache.Get(i);
            if (area == Address_Null) continue;

            int areaIdx = FindNavIndexByAddress(area);
            if (areaIdx < 0) continue;

            float cand[3];
            SpawnScoreDbg dbg;

            // 兜底没有“每桶 ring”，就用原始 ring（TryPick 内部仍有 HeightRingSlack）
            if (!TryPickValidSpotInArea(areaIdx, targetSur, /*ringEff=*/ring, teleportMode, cand, dbg))
                continue;

            if (FIRST_FIT)
            {
                ScoreCandidate(zc, cand, centerBucket, dbg, /*ringForDbg=*/ring);
                outPos = cand;
                outAreaIdx = areaIdx;
                outDbg = dbg;
                return true;
            }

            ScoreCandidate(zc, cand, centerBucket, dbg, /*ringForDbg=*/ring);

            if (dbg.total > bestScore)
            {
                bestScore   = dbg.total;
                bestPos     = cand;
                bestAreaIdx = areaIdx;
                bestDbg     = dbg;
            }

            globalTaken++;
        }

        if (bestAreaIdx >= 0)
        {
            outPos = bestPos;
            outAreaIdx = bestAreaIdx;
            outDbg = bestDbg;
            return true;
        }

        return false;
    }
}

// [新增] —— 生成缓存 Key（NavAreaID + 量化后的 limitCost）
stock void PathCache_BuildKey(Address navGoal, Address navStart, float limitCost, char[] outKey, int maxlen)
{
    int idG = (navGoal  != Address_Null) ? L4D_GetNavAreaID(navGoal)  : -1;
    int idS = (navStart != Address_Null) ? L4D_GetNavAreaID(navStart) : -1;
    int q   = RoundToNearest(limitCost / gCV.fPathCacheQuantize); // 量化，避免 key 激增
    Format(outKey, maxlen, "%d|%d|%d", idG, idS, q);
}

// [新增] —— 简单读写（无 TTL）
stock bool PathCache_TryGetSimple(const char[] key, bool &okOut)
{
    if (g_PathCacheRes == null) return false;
    any resAny;
    if (!g_PathCacheRes.GetValue(key, resAny)) return false;
    okOut = (view_as<int>(resAny) != 0);
    return true;
}

stock void PathCache_PutSimple(const char[] key, bool ok)
{
    if (g_PathCacheRes == null) return;
    g_PathCacheRes.SetValue(key, view_as<any>(ok ? 1 : 0));
}
// [修改] —— 仅清结果表
static void ClearPathCache()
{
    if (g_PathCacheRes != null) g_PathCacheRes.Clear();
}

// [修改] —— 整函数覆盖：使用波级缓存（无 TTL）
stock float PathPenalty_NoBuild(const float candPos[3], int targetSur, float ring, float spawnmax)
{
    // 选目标幸存者：优先 targetSur，其次任意存活
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
            { surv = i; break; }
        }
    }
    if (surv == -1) return PATH_NO_BUILD_PENALTY; // 没有可用幸存者，按“不可达”

    // 生还者位置（与你 SpawnInfected 的口径一致）
    float survPos[3];
    GetClientEyePosition(surv, survPos);
    survPos[2] -= 60.0;

    // 找最近 NavArea
    Address navGoal  = L4D_GetNearestNavArea(candPos, 120.0, false, false, false, TEAM_INFECTED);
    Address navStart = L4D_GetNearestNavArea(survPos, 120.0, false, false, false, TEAM_INFECTED);
    if (!navGoal || !navStart) return PATH_NO_BUILD_PENALTY;

    // 代价上限：min(ring*3, spawnmax*1.5)
    float limitCost = FloatMin(ring * 3.0, spawnmax * 1.5);

    if (gCV.bPathCacheEnable)
    {
        char key[64];
        PathCache_BuildKey(navGoal, navStart, limitCost, key, sizeof key);

        bool okCached;
        if (PathCache_TryGetSimple(key, okCached))
            return okCached ? 0.0 : PATH_NO_BUILD_PENALTY;

        bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
        PathCache_PutSimple(key, ok);
        return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
    }

    // 不启用缓存：直接判定
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

// 采样 NavArea 的“几何中心近似 + 高度统计”
static void SampleAreaCenterAndZ(Address areaAddr, float &cx, float &cy, float &zAvg, float &zMin, float &zMax, int samples = 3)
{
    cx = cy = 0.0; zAvg = 0.0; zMin = 1.0e9; zMax = -1.0e9;
    if (areaAddr == Address_Null || samples <= 0) { zMin = zMax = zAvg = 0.0; return; }

    NavArea area = view_as<NavArea>(areaAddr);
    float p[3];

    for (int i = 0; i < samples; i++)
    {
        area.GetRandomPoint(p);
        cx   += p[0];
        cy   += p[1];
        zAvg += p[2];
        if (p[2] < zMin) zMin = p[2];
        if (p[2] > zMax) zMax = p[2];
    }
    float inv = 1.0 / float(samples);
    cx   *= inv;
    cy   *= inv;
    zAvg *= inv;
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

static bool TryLoadBucketsFromCache()
{
    if (!gCV.bNavCacheEnable) return false;

    MakeBucketCachePath();
    if (!FileExists(g_sBucketCachePath)) return false;

    KeyValues kv = new KeyValues("BucketsCache");
    if (!kv.ImportFromFile(g_sBucketCachePath)) { delete kv; return false; }

    kv.Rewind();
    char ver[64]; kv.GetString("version", ver, sizeof ver, "");
    if (!StrEqual(ver, BUCKET_CACHE_VER))
    { delete kv; return false; }

    char map[64], mapCur[64];
    GetCurrentMap(mapCur, sizeof mapCur);
    kv.GetString("map", map, sizeof map, "");
    if (!StrEqual(map, mapCur))
    { delete kv; return false; }

    // ✅ 使用缓存
    EnsureNavAreasCache();
    int currentAreaCount = g_NavAreasCacheCount;

    int areaCount = kv.GetNum("area_count", -1);
    if (areaCount <= 0 || areaCount != currentAreaCount)
    { delete kv; return false; }

    float maxFlowCur = L4D2Direct_GetMapMaxFlowDistance();
    float maxFlowCached = kv.GetFloat("max_flow", -1.0);
    if (FloatAbs(maxFlowCached - maxFlowCur) > 0.1)
    { delete kv; return false; }

    // 影响分桶的运行参数（变了就作废）
    float bufCur = gCV.VsBossFlowBuffer.FloatValue;
    float bufCached = kv.GetFloat("vsboss_buffer", 0.0);
    int   mapInvalidCur = gCV.bNavBucketMapInvalid ? 1 : 0;
    int   mapInvalidCac = kv.GetNum("map_invalid", 1);
    float assignRcur    = gCV.fNavBucketAssignRadius;
    float assignRcac    = kv.GetFloat("assign_radius", 0.0);

    // 【修改】去掉 stuck_probe 的一致性校验
    if (FloatAbs(bufCur-bufCached)>0.01 || mapInvalidCur!=mapInvalidCac ||
        FloatAbs(assignRcur-assignRcac)>0.5)
    { delete kv; return false; }

    // 清理并初始化容器
    ClearNavBuckets();
    BuildNavIdIndexMap();

    g_AreaZCore = new ArrayList();
    g_AreaZMin  = new ArrayList();
    g_AreaZMax  = new ArrayList();
    g_AreaCX    = new ArrayList();
    g_AreaCY    = new ArrayList();
    g_AreaPct   = new ArrayList();

    for (int i = 0; i < areaCount; i++)
    { g_AreaZCore.Push(0.0); g_AreaZMin.Push(0.0); g_AreaZMax.Push(0.0); g_AreaCX.Push(0.0); g_AreaCY.Push(0.0); g_AreaPct.Push(-1); }

    for (int b = 0; b < FLOW_BUCKETS; b++)
    { g_BucketMinZ[b] =  1.0e9; g_BucketMaxZ[b] = -1.0e9; }

    // 桶 Z 范围
    if (kv.JumpToKey("bucket_zrange", false))
    {
        for (int b = 0; b <= 100; b++)
        {
            char k[8]; IntToString(b, k, sizeof k);
            if (kv.JumpToKey(k, false))
            {
                g_BucketMinZ[b] = kv.GetFloat("min", 0.0);
                g_BucketMaxZ[b] = kv.GetFloat("max", 0.0);
                kv.GoBack();
            }
        }
        kv.GoBack();
    }

    // areas
    if (!kv.JumpToKey("areas", false))
    { delete kv; return false; }

    if (kv.GotoFirstSubKey(false))
    {
        do {
            char sNav[16]; kv.GetSectionName(sNav, sizeof sNav);
            int navid = StringToInt(sNav);
            int idx = GetAreaIndexByNavID_Int(navid);
            if (idx < 0) continue;

            int bucket = kv.GetNum("bucket", -1);
            if (bucket < 0 || bucket > 100) continue;

            float cx = kv.GetFloat("cx", 0.0);
            float cy = kv.GetFloat("cy", 0.0);
            float zc = kv.GetFloat("zCore", 0.0);
            float zmin = kv.GetFloat("zMin", 0.0);
            float zmax = kv.GetFloat("zMax", 0.0);

            g_AreaCX.Set(idx, cx);
            g_AreaCY.Set(idx, cy);
            g_AreaZCore.Set(idx, zc);
            g_AreaZMin.Set(idx, zmin);
            g_AreaZMax.Set(idx, zmax);
            g_AreaPct.Set(idx, bucket);

            if (g_FlowBuckets[bucket] == null)
                g_FlowBuckets[bucket] = new ArrayList();
            g_FlowBuckets[bucket].Push(idx);

        } while (kv.GotoNextKey(false));
        kv.GoBack();
    }

    delete kv;
    g_BucketsReady = true;
    Debug_Print("[BUCKET] loaded from cache: %s", g_sBucketCachePath);
    return true;
}

static void SaveBucketsToCache()
{
    if (!gCV.bNavCacheEnable || !g_BucketsReady) return;

    MakeBucketCachePath();

    KeyValues kv = new KeyValues("BucketsCache");
    kv.SetString("version", BUCKET_CACHE_VER);

    char map[64]; GetCurrentMap(map, sizeof map);
    kv.SetString("map", map);

    // ✅ 使用缓存
    EnsureNavAreasCache();
    int areaCount = g_NavAreasCacheCount;

    kv.SetNum("area_count", areaCount);
    kv.SetFloat("max_flow", L4D2Direct_GetMapMaxFlowDistance());
    kv.SetFloat("vsboss_buffer", gCV.VsBossFlowBuffer.FloatValue);
    kv.SetNum("map_invalid", gCV.bNavBucketMapInvalid ? 1 : 0);
    kv.SetFloat("assign_radius", gCV.fNavBucketAssignRadius);

    // 桶 Z 范围
    kv.JumpToKey("bucket_zrange", true);
    for (int b = 0; b <= 100; b++)
    {
        char k[8]; IntToString(b, k, sizeof k);
        kv.JumpToKey(k, true);
        kv.SetFloat("min", g_BucketMinZ[b]);
        kv.SetFloat("max", g_BucketMaxZ[b]);
        kv.GoBack();
    }
    kv.GoBack();

    // areas
    kv.JumpToKey("areas", true);
    for (int i = 0; i < areaCount; i++)
    {
        int navid = GetNavIDByIndex(i);
        if (navid < 0) continue;

        int bucket = view_as<int>(g_AreaPct.Get(i));
        if (bucket < 0 || bucket > 100) continue;

        char sNav[16]; IntToString(navid, sNav, sizeof sNav);
        kv.JumpToKey(sNav, true);

        kv.SetNum("bucket", bucket);
        kv.SetFloat("cx", view_as<float>(g_AreaCX.Get(i)));
        kv.SetFloat("cy", view_as<float>(g_AreaCY.Get(i)));
        kv.SetFloat("zCore", view_as<float>(g_AreaZCore.Get(i)));
        kv.SetFloat("zMin", view_as<float>(g_AreaZMin.Get(i)));
        kv.SetFloat("zMax", view_as<float>(g_AreaZMax.Get(i)));

        kv.GoBack();
    }
    kv.GoBack();

    kv.ExportToFile(g_sBucketCachePath);
    delete kv;
    Debug_Print("[BUCKET] saved to cache: %s", g_sBucketCachePath);
}

// =========================
// Gamedata / SDK（简化版 - 只保留 MaxSpecial unlock）
// =========================
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "infected_control");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    // Unlock Max SI limit - 这是唯一需要保留的 gamedata patch
    strcopy(sBuffer, sizeof(sBuffer), "CDirector::GetMaxPlayerZombies");
    MemoryPatch mPatch = MemoryPatch.CreateFromConf(hGameData, sBuffer);
    if (!mPatch.Validate())
        SetFailState("Failed to verify patch: %s", sBuffer);
    if (!mPatch.Enable())
        SetFailState("Failed to Enable patch: %s", sBuffer);

    delete hGameData;
}

// --- Math helpers --- 
stock float FloatMax(float a, float b) { return (a > b) ? a : b; } 
stock float FloatMin(float a, float b) { return (a < b) ? a : b; }
stock float Clamp01(float v) { if (v < 0.0) return 0.0; if (v > 1.0) return 1.0; return v; }
// [ADD] int 夹取
stock int clampi(int v, int lo, int hi) { if (v<lo) return lo; if (v>hi) return hi; return v; }

// [ADD] 负向分散度惩罚随上限 L 变弱（用你给的宏）
stock float ComputePenScaleByLimit(int L) {
    int Lc = clampi(L, PEN_LIMIT_MINL, PEN_LIMIT_MAXL);
    float t = float(Lc - PEN_LIMIT_MINL) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL); // 0..1
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}
stock float ScaleNegativeOnly(float v, float k) { return (v < 0.0) ? (v * k) : v; }

// 在 LogChosenSpawnScore 中增加（约第2900行）
static void LogChosenSpawnScore(int zc, const SpawnScoreDbg dbg) 
{
    if (gCV.iDebugMode <= 0) return;
    
    // ✅ 计算真实位置关系
    int candReal = GetPositionBucketPercent(dbg.pos);
    int surReal = -1;
    int fb = GetHighestFlowSurvivorSafe();
    TryGetClientFlowPercentSafe(fb, surReal);
    
    Debug_Print("[SCORE-CHOSEN] %s pos=(%.1f,%.1f,%.1f) area=%d | tot=%.1f | dist=%.1f h=%.1f flow=%.1f disp=%.1f->%.1f(pK=%.2f) | dEye=%.1f ringEff=%.1f slack=%.1f | bkt=%d ctr=%d dF=%d sec=%d | REAL: cand=%d%% sur=%d%% delta=%d%%",
        INFDN[zc], dbg.pos[0], dbg.pos[1], dbg.pos[2], dbg.areaIdx,
        dbg.total, dbg.dist, dbg.hght, dbg.flow, dbg.dispRaw, dbg.dispScaled, dbg.penK,
        dbg.dminEye, dbg.ringEff, dbg.slack, 
        dbg.candBucket, dbg.centerBucket, dbg.deltaFlow, dbg.sector,
        candReal, surReal, candReal - surReal);  // ✅ 真实位置关系
}
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
