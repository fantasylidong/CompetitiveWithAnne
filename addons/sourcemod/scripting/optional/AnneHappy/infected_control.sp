#pragma semicolon 1
#pragma newdecls required
#pragma dynamic 32768

/**
 * Infected Control (fdxx-style NavArea spot picking + persisted Nav graph + legacy fallback)
 *
 * ── 模块地图（Modules）
 *  1. 头文件 & 常量/宏
 *  2. 数据结构：Config / State / Queues / 全局缓存（NavAreas/FlowBuckets/冷却/路径缓存…）
 *  3. 插件生命周期：OnPluginStart/OnPluginEnd/Map & Round 事件
 *  4. CVar 管理：Config::Create / Refresh / 变更回调
 *  5. 运行时时序：
 *     - 帧驱动 OnGameFrame → 队列维护 → 常规刷新尝试
 *     - 传送监督定时器 Timer_TeleportTick（1s）
 *     - Spawn 波控制：StartWave/Timer_CheckSpawnWindow/Timer_StartNewWave
 *  6. 选类与队列：稀缺度优先、死亡CD与双保险、上限闸门
 *  7. 刷点核心（NavArea主路）：距离/可视/卡壳/路径/分散度/Flow 评分与 First-Fit
 *  8. Nav 图与进度缓存：图模式直接按路径范围取候选，旧 Flow 桶仅用于扩展失败兜底
 *  9. Flow 与 Survivor 进度：安全获取、回退 TTL、每秒刷新“最后一次有效团队进度”
 * 10. 跑男检测与目标生还者选择
 * 11. 工具函数：可视/线段/碰撞/冷却/扇区/日志
 *
 * ── 行为要点（Behavior）
 *  - 图模式后台预建 Nav 邻接表，并一次性缓存每个 Nav 的 0..100% 进度
 *  - 扩圈 SpawnMin→SpawnMax；到达上限走导演兜底
 *  - 评分四因子：距离 / 高度偏好 / Flow / 分散度（可调权重）
 *  - badflow 仅作轻度扣分（不强制禁用），图模式按 Nav 邻接继承最近有效进度
 *  - 传送监督：出生宽限、跑男快通道（但≥0.8s）、Smoker 技能未就绪不传
 *  - 生还者进度“本地回退”：所有人统计失败时，短期采用“最后一次有效平均进度”
 *
 * ── 维护入口（Maintainer notes）
 *  - 刷特架构总览见：infected_control/README_SPAWN_ARCHITECTURE.md
 *  - 单次找位入口：spawn_core.inc::FindSpawnPosViaNavArea
 *  - 单个 NavArea 候选评估：spawn_core.inc::SpawnCore_EvaluateNavCandidate
 *  - 普通/传送刷出尝试：spawn_attempts.inc::TryNormalSpawnOnce / TryTeleportSpawnOnce
 *  - 波释放时机：wave_decider.inc + wave_control.inc
 *
 * Compatible with SM 1.10+ / L4D2 / left4dhooks
 * Authors: 东, Caibiii, 夜羽真白, Paimon-Kawaii, fdxx (思路)
 */

#include <sourcemod>
#include <colors>
#include <sdktools>
#include <sdkhooks>
#include <sdktools_tempents>
#include <left4dhooks>
#include <sourcescramble>
#include <anne_spawn_accel>
#undef REQUIRE_PLUGIN
#include <anne_traitor_quota> // 可选：每日配额与 Tank 封禁持久化
#include <si_target_limit>  // 可选
#include <pause>            // 可选
#include <l4dstats>         // 可选：普通玩家内鬼资格读取

// =========================
// 常量/宏
// =========================
#define CVAR_FLAG                 FCVAR_NOTIFY
#define TEAM_SPECTATOR            1
#define TEAM_SURVIVOR             2
#define TEAM_INFECTED             3
#define NAV_MESH_HEIGHT           20.0
#define PLAYER_CHEST              45.0

#define BAIT_DISTANCE             200.0

// Nav 找点按帧分片；候选数与昂贵精判数都有限制。
#define NAV_RANDOM_POINT_TRIES    3
#define NAV_SCAN_SCORE_BUDGET_CAP     8
#define NAV_CANDIDATE_PAGE_SIZE       256
#define NAV_CANDIDATE_TEAM_EXCLUSION  250.0
#define NAV_CANDIDATE_LANDING_MARGIN    16.0
#define HURT_TRIGGER_LANDING_MARGIN      40.0
#define NAV_UNSAFE_GEOMETRY_CD_SECS      30.0
#define NAV_CANDIDATE_RANGE_SLACK      128.0
#define NAV_PATH_DISTANCE_SCALE          2.0
#define NAV_HIGH_GROUND_COMP_START_Z     32.0
#define NAV_HIGH_GROUND_SMOKER_SCALE      1.5
#define NAV_HIGH_GROUND_HUNTER_SCALE      1.15
#define NAV_HIGH_GROUND_SMOKER_MAX     1000.0
#define NAV_HIGH_GROUND_HUNTER_MAX      800.0
#define NAV_HIGH_GROUND_MAX_COMP       1000.0
#define NAV_CANDIDATE_IDLE_INTERVAL      1.0
#define NAV_CANDIDATE_WARM_INTERVAL      0.1
#define NAV_CANDIDATE_RESULT_TTL         0.2
#define NAV_CANDIDATE_WARMUP_LEAD         1.0
#define TACTICAL_BAND_STAGES      3
#define SUPPORT_RELEASE_GRACE     0.55
#define SUPPORT_RELEASE_FORCE     0.90
#define DIRECTOR_BASE_API_TRIES      7
#define EXTENDED_FALLBACK_CYCLES     2
#define EXTENDED_DIRECTOR_TRIES     12
#define NAV_WEIGHT_MIN            0.10

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

// === Dispersion tuning (penalties at BASE=4) ===
#define SECTOR_PREF_BONUS_BASE   -8.0
#define SECTOR_OFF_PENALTY_BASE   4.0
#define RECENT_PENALTY_0_BASE     3.6
#define RECENT_PENALTY_1_BASE     2.4
#define RECENT_PENALTY_2_BASE     2.0

// Nav Flow 分桶
#define FLOW_BUCKETS              101     // 0..100
#define BUCKET_CACHE_VER "2026-08"  // 和插件版号保持同步

// areaIdx -> 冷却过期时间；候选热循环直接 O(1) 读取。
ArrayList g_NavCooldownUntil = null;

char g_sInfectedClassNames[10][] =
{
    "common","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};
// NavAreas 全局缓存
ArrayList g_AllNavAreasCache = null;
int g_NavAreasCacheCount = 0;
// —— Nav 高度“核心”缓存 & 每桶高度范围 —— //
ArrayList g_AreaZCore = null;   // float per areaIdx（核心高度=多次随机点的 z 均值）
ArrayList g_AreaZMin  = null;   // float per areaIdx
ArrayList g_AreaZMax  = null;   // float per areaIdx
float g_BucketMinZ[FLOW_BUCKETS];
float g_BucketMaxZ[FLOW_BUCKETS];
float g_LastSpawnTime[MAXPLAYERS+1];

StringMap g_NavIdToIndex = null;  // navid -> areaIdx
ArrayList g_AreaNavIds = null;     // areaIdx -> navid
char g_sBucketCachePath[PLATFORM_MAX_PATH] = "";

#include "infected_control/nav_types.inc"
#include "infected_control/spawn_score_types.inc"
#include "infected_control/utils.inc"
#include "infected_control/config.inc"

// —— 可选库可用性 —— 
bool g_bPauseLib       = false;
bool g_bSmokerLib      = false;
bool g_bTargetLimitLib = false;
bool g_bInfectedControlStarted = false;

// —— 分散度：最近扇区 & 最近刷点 —— //
int recentSectors[3] = { -1, -1, -1 };   // 最近 3 次使用的扇区
ArrayList lastSpawns = null;             // 每条记录 [x,y,z,time]

// —— 死亡CD时间戳 & 最近一次成功刷出 —— //
float g_LastDeathTime[SI_COUNT]; // zc-1 索引
float g_LastSpawnOkTime = 0.0;
float g_SupportShortageStart = 0.0;

// —— Nav Flow 分桶 —— //
ArrayList g_FlowBuckets[FLOW_BUCKETS]; // 每桶存 NavArea 索引 i
bool g_BucketsReady = false;

// —— 供就近归桶使用的中心点 & 预分配的桶百分比 —— //
ArrayList g_AreaCX  = null;  // float per areaIdx
ArrayList g_AreaCY  = null;  // float per areaIdx
ArrayList g_AreaPct = null;  // int   per areaIdx（-1=未知/坏flow，否则0..100）

// 跑男通知 forward
Handle g_hRushManNotifyForward = INVALID_HANDLE;
Handle g_hSpawnCommittedForward = INVALID_HANDLE;
Handle g_hFirstWaveTimer = INVALID_HANDLE;
Handle g_hSaferoomResetTimer = INVALID_HANDLE;
Handle g_hApplyMaxSpecialsTimer = INVALID_HANDLE;

#define RUNTIME_WATCHDOG_INTERVAL       1.0
#define RUNTIME_TIMER_STALE_SECONDS     3.5
#define RUNTIME_FIRST_WAVE_TIMEOUT      5.0
#define RUNTIME_HARD_RECOVERY_COOLDOWN 10.0

bool g_bRuntimeRoundActive = false;
bool g_bRuntimeMapEnding = false;
bool g_bRuntimeRecoveryBusy = false;
bool g_bRuntimeRecoverySuppressed = false;
float g_fNextRuntimeWatchdogAt = 0.0;
float g_fNextRuntimeHardRecoveryAt = 0.0;
float g_fFirstWaveRequestedAt = 0.0;
float g_fWaveCheckHeartbeat = 0.0;
float g_fTeleportHeartbeat = 0.0;
int g_iRuntimeCountMismatchTicks = 0;

// =========================
// 全局
// =========================
public Plugin myinfo =
{
    name        = "Direct InfectedSpawn (directed-nav + maxdist-fallback)",
    author      = "东, Caibiii, 夜羽真白, Paimon-Kawaii, fdxx (inspiration)",
    description = "特感刷新控制 / 传送 / 跑男 / 有向Nav候选 + 当前帧安全精判 + 最大距离兜底",
    version     = "2026-08-03.3",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

// NO_MAPCHANGE timers may already be closed when their owner receives a map
// lifecycle callback. Detach the shared reference first so cleanup is idempotent.
stock bool StopTrackedTimer(Handle &slot)
{
    Handle timer = slot;
    slot = INVALID_HANDLE;
    if (timer == INVALID_HANDLE || !IsValidHandle(timer))
        return false;

    KillTimer(timer);
    return true;
}

stock bool IsTrackedTimerValid(Handle timer)
{
    return timer != INVALID_HANDLE && IsValidHandle(timer);
}

#include "infected_control/runtime_state.inc"

Config gCV;
State  gST;
Queues gQ;

static char g_sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control_fdxxnav.txt";

bool CheckClassEnabled(int zc)
{
    if (zc < 1 || zc > SI_COUNT)
        return false;

    int bit = 1 << (zc - 1);
    return (gCV.iEnableMask & bit) != 0;
}

#include "infected_control/queue.inc"
#include "infected_control/class_queue.inc"
#include "infected_control/client_state.inc"
#include "infected_control/spawn_accel_bridge.inc"

// 刷特管线的依赖顺序很重要：
// 1) 先加载基础状态、队列、玩家状态和可见性工具；
// 2) 再加载评分、Nav/Flow 缓存和性能优化；
// 3) 最后加载 wave 控制、刷点核心和实际刷出尝试。
// SourcePawn include 是文本拼接，新增模块时要确认被调用函数已经在前面可见。
#include "infected_control/visibility.inc"
#include "infected_control/difficulty_strategy.inc"
#include "infected_control/anti_baiter.inc"
#include "infected_control/si_cap.inc"
#include "infected_control/spawn_score.inc"
#include "infected_control/path_cache.inc"
#include "infected_control/survivor_flow.inc"
#include "infected_control/spawn_memory.inc"
#include "infected_control/spawn_tactics.inc"
#include "infected_control/nav_cache.inc"
#include "infected_control/nav_persist.inc"
#include "infected_control/nav_buckets.inc"
#include "infected_control/spawn_perf_optimizer.inc"
#include "infected_control/spawn_perf_config.inc"
#include "infected_control/wave_spawn_report.inc"
#include "infected_control/wave_decider.inc"
#include "infected_control/traitor_quota.inc"
#include "infected_control/traitor_mode.inc"
#include "infected_control/wave_control.inc"
#include "infected_control/spawn_core.inc"
#include "infected_control/spawn_attempts.inc"
#include "infected_control/teleport_monitor.inc"

// =========================
// 前置：事件 & 库
// =========================
public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("AnneSpawn_IsActive");
    MarkNativeAsOptional("AnneSpawn_NavGraphStart");
    MarkNativeAsOptional("AnneSpawn_NavGraphPump");
    MarkNativeAsOptional("AnneSpawn_NavGraphStop");
    MarkNativeAsOptional("AnneSpawn_NavGraphPrepareRange");
    MarkNativeAsOptional("AnneSpawn_NavGraphCollectRange");
    MarkNativeAsOptional("AnneSpawn_NavCandidatesPrepare");
    MarkNativeAsOptional("AnneSpawn_NavCandidatesCollect");
    MarkNativeAsOptional("AnneSpawn_NavCandidatesGetPerf");
    MarkNativeAsOptional("AnneSpawn_NavCandidatesResetPerf");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetAreaCount");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetEdgeCount");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetDiagnostics");
    MarkNativeAsOptional("AnneSpawn_NavGraphCollectProgress");
    MarkNativeAsOptional("AnneSpawn_GetWorkerCount");
    MarkNativeAsOptional("AnneSpawn_SetSurvivorSnapshot");
    MarkNativeAsOptional("AnneSpawn_ClearSurvivorSnapshot");
    MarkNativeAsOptional("AnneSpawn_TestPointSafety");
    MarkNativeAsOptional("AnneSpawn_ComputePointGeometry");
    MarkNativeAsOptional("AnneSpawn_ComputeGeometryBatch");
    MarkNativeAsOptional("AnneSpawn_SelectTopK");
    MarkNativeAsOptional("AnneSpawn_MapNearest2D");
    MarkNativeAsOptional("AnneSpawn_PathExists");
    MarkNativeAsOptional("AnneSpawn_ClearPathCache");
    RegPluginLibrary("infected_control");                           // 供其他插件依赖
    g_hRushManNotifyForward = CreateGlobalForward("OnDetectRushman", // 跑男 forward：传入幸存者 index
                                                  ET_Ignore, Param_Cell);
    g_hSpawnCommittedForward = CreateGlobalForward(
        "InfectedControl_OnSpawnCommitted", ET_Ignore, Param_Cell);
    CreateNative("GetNextSpawnTime", Native_GetNextSpawnTime);       // native：下一次刷特剩余秒数
    CreateNative("InfectedControl_IsTraitorClient", Native_InfectedControlIsTraitorClient);
    CreateNative("InfectedControl_IsTraitorRegistered", Native_InfectedControlIsTraitorRegistered);
    CreateNative("InfectedControl_IsTraitorModeEnabled", Native_InfectedControlIsTraitorModeEnabled);
    CreateNative("InfectedControl_HasPendingTraitorTank", Native_InfectedControlHasPendingTraitorTank);
    CreateNative("InfectedControl_HandleTraitorTankOffer", Native_InfectedControlHandleTraitorTankOffer);
    return APLRes_Success;
}
public void OnAllPluginsLoaded()
{
    g_bTargetLimitLib = LibraryExists("si_target_limit");
    g_bSmokerLib      = LibraryExists("ai_smoker_new");
    g_bPauseLib       = LibraryExists("pause");
    SpawnAccel_UpdateAvailability();
}
public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, ANNE_SPAWN_ACCEL_LIBRARY))
    {
        SpawnAttempts_ResetSearchProgress();
        SpawnAccel_UpdateAvailability();
        Visibility_ClearEyeSnapshot();
        ClearPathCache();
        if (g_bInfectedControlStarted)
            SpawnAccel_ScheduleNavGraphStart(false);
    }

    if (StrEqual(name, "si_target_limit")) g_bTargetLimitLib = true;
    else if (StrEqual(name, "ai_smoker_new")) g_bSmokerLib   = true;
    else if (StrEqual(name, "pause"))         g_bPauseLib    = true;
}
public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, ANNE_SPAWN_ACCEL_LIBRARY))
    {
        SpawnAttempts_ResetSearchProgress();
        SpawnAccel_ClearGraphState(false);
        SpawnAccel_UpdateAvailability();
        Visibility_ClearEyeSnapshot();
        ClearPathCache();
        SpawnAccel_EnsureLegacyBuckets();
    }

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

    float rem = WaveDecider_GetReleaseEta();
    if (rem < 0.0)
        rem = DifficultyStrategy_GetConfiguredWaveDelay() - float(gST.lastSpawnSecs);
    if (rem < 0.0) rem = 0.0;
    return view_as<any>(rem);
}

// =========================
// 插件生命周期
// =========================
public void OnPluginStart()
{
	LoadTranslations("infected_control.phrases");
    SpawnPerfConfig_Create();
    gCV.Create();
    SpawnAccel_UpdateAvailability(true);
    ClearPathCache();
    Visibility_ClearEyeSnapshot();
    ClassCapMirrors_Create();
    gQ.Create();
    gST.Reset();
    InitSDK_FromGamedata();   // ← 加载 NavArea SDK/偏移
    BuildNavIdIndexMap();
    g_bInfectedControlStarted = true;
    SpawnAccel_ScheduleNavGraphStart(false);
    RecalcSiCapFromAlive(true);

    // 分散度：初始化
    lastSpawns = new ArrayList(4);
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;
    // 初始化 Path 缓存
    PathCache_Init();

    // 初始化死亡时间戳
    g_LastSpawnOkTime = 0.0;
    g_SupportShortageStart = 0.0;
    for (int i = 0; i < SI_COUNT; i++) g_LastDeathTime[i] = 0.0;

    RegAdminCmd("sm_startspawn", Cmd_StartSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
    RegAdminCmd("sm_stopspawn",  Cmd_StopSpawn,  ADMFLAG_ROOT, "管理员停止刷特");
    RegAdminCmd("sm_rebuildnavcache", Cmd_RebuildNavCache, ADMFLAG_ROOT, "Rebuild Nav graph and progress cache for current map");
    RegAdminCmd("sm_navpeek", Cmd_NavPeek, ADMFLAG_GENERIC, "查看准星 Nav 的分桶与属性");
    RegAdminCmd("sm_np",      Cmd_NavPeek, ADMFLAG_GENERIC, "查看准星 Nav 的分桶与属性(别名)");
    RegAdminCmd("sm_navtest", Cmd_NavTest, ADMFLAG_GENERIC, "测试准星 Nav 能否生成特感及评分");
    RegAdminCmd("sm_nt",      Cmd_NavTest, ADMFLAG_GENERIC, "测试准星 Nav 能否生成特感及评分(别名)");
    RegAdminCmd("sm_wavestatus", Cmd_WaveStatus, ADMFLAG_GENERIC, "查看当前波决策器状态");
    RegConsoleCmd("sm_neigui", Cmd_Traitor, "进入内鬼刷特队列: sm_neigui [class]");
    RegConsoleCmd("sm_it", Cmd_Traitor, "进入内鬼刷特队列: sm_it [class]");
    RegConsoleCmd("sm_neiguicancel", Cmd_TraitorCancel, "取消内鬼刷特队列");
    AddCommandListener(InfectedControl_OnTraitorCvarCommand, "sm_cvar");

    RegisterSpawnPerfCommands();

    HookEvent("finale_win",      Event_RoundEnd);
    HookEvent("mission_lost",    Event_RoundEnd);
    HookEvent("map_transition",  Event_RoundEnd);
    HookEvent("round_start",     Event_RoundStart);
    HookEvent("player_spawn",    Event_PlayerSpawn);
    HookEvent("player_death",    Event_PlayerDeath);
    HookEvent("player_team",     Event_PlayerTeam);
    HookEvent("player_bot_replace", Event_PlayerBotReplace, EventHookMode_Post);
    HookEvent("bot_player_replace", Event_BotPlayerReplace, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
    HookEvent("player_no_longer_it", Event_PlayerNoLongerIt, EventHookMode_Post);
    HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
    HookEvent("player_ledge_grab", Event_PlayerLedgeGrab, EventHookMode_Post);
    HookEvent("revive_success", Event_PlayerReviveSuccess, EventHookMode_Post);
    HookEvent("ability_use",     Event_AbilityUse);
    HookEvent("charger_charge_start", Event_PressureEngaged, EventHookMode_Post);
    HookEvent("lunge_pounce", Event_PressureEngaged, EventHookMode_Post);
    HookEvent("jockey_ride", Event_PressureEngaged, EventHookMode_Post);
    HookEvent("tongue_grab", Event_PressureEngaged, EventHookMode_Post);
    HookEvent("player_hurt",     Event_PlayerHurt);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
            Traitor_InitializeClientDamage(client);
    }
}

public void OnPluginEnd()
{
    WaveSpawnReport_End("plugin_end");
    g_bInfectedControlStarted = false;
    g_bRuntimeRoundActive = false;
    g_bRuntimeMapEnding = true;
    g_bRuntimeRecoverySuppressed = true;
    StopAll();
    SpawnAccel_ClearGraphState(true);
    AssaultBurst_Reset();
    SpawnAttempts_ResetSearchProgress();
    Traitor_ResetAll(true);
    Traitor_ShutdownDamageHooks();
    Visibility_ResetHurtTriggers();
    // 插件结束时清理 Path 缓存
    ClearPathCache();
}
public void OnMapEnd()
{
    WaveSpawnReport_End("map_end");
    g_bRuntimeRoundActive = false;
    g_bRuntimeMapEnding = true;
    g_bRuntimeRecoverySuppressed = true;
    StopAll();
    SpawnAccel_ClearGraphState(true);
    AssaultBurst_Reset();
    SpawnAttempts_ResetSearchProgress();
    if (g_NavCooldownUntil != null) g_NavCooldownUntil.Clear();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    g_LastSpawnOkTime = 0.0;
    g_SupportShortageStart = 0.0;
    for (int i = 0; i < SI_COUNT; i++) g_LastDeathTime[i] = 0.0;
    Traitor_ResetAll(true);
    Traitor_ShutdownDamageHooks();

    ClearNavBuckets();
    g_BucketsReady = false;
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
    if (g_NavIdToIndex != null) { delete g_NavIdToIndex; g_NavIdToIndex = null; }
    ClearPathCache();
    ClearNavAreasCache();
    Visibility_ResetHurtTriggers();

    if (SpawnPerfConfig_ShowStats())
    {
        SpawnPerf_OnMapEnd();
    }
}

public void OnMapStart()
{
    Visibility_ResetHurtTriggers();
    g_bRuntimeRoundActive = false;
    g_bRuntimeMapEnding = false;
    g_bRuntimeRecoverySuppressed = false;
    g_fNextRuntimeWatchdogAt = 0.0;
    g_fNextRuntimeHardRecoveryAt = 0.0;
    g_iRuntimeCountMismatchTicks = 0;
    if (g_bInfectedControlStarted)
        SpawnAccel_ScheduleNavGraphStart(false);
}

public Action Timer_StartSpawnAccelGraph(Handle timer, any data)
{
    if (timer != g_hSpawnAccelStartTimer)
        return Plugin_Stop;

    g_hSpawnAccelStartTimer = INVALID_HANDLE;
    SpawnAccel_UpdateAvailability();
    SpawnAccel_StartNavGraph(view_as<bool>(data));
    return Plugin_Stop;
}

// =========================
// 调试输出
// =========================
stock void Debug_Print(const char[] format, any ...)
{
    if (gCV.iDebugMode <= 0) return;
    char buf[1024];
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
public Action InfectedControl_OnTraitorCvarCommand(int client, const char[] command, int argc)
{
    if (argc < 2)
        return Plugin_Continue;

    char cvarName[64];
    GetCmdArg(1, cvarName, sizeof(cvarName));
    if (!StrEqual(cvarName, "inf_traitor_max_slots", false))
        return Plugin_Continue;

    if (client == 0 || CheckCommandAccess(client, "infected_control_traitor_slot_cvar", ADMFLAG_ROOT, true))
        return Plugin_Continue;

    CPrintToChat(client, "%t", "InfectedControl_TraitorRootCvarOnly", cvarName);
    return Plugin_Handled;
}

public Action Cmd_StartSpawn(int client, int args)
{
    g_bRuntimeRecoverySuppressed = false;
    RequestStartSpawn();
    return Plugin_Handled;
}

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
    g_bRuntimeRecoverySuppressed = false;
    RequestStartSpawn();
}
public Action Cmd_StopSpawn(int client, int args)
{
    g_bRuntimeRecoverySuppressed = true;
    StopAll();
    return Plugin_Handled;
}

public Action Cmd_WaveStatus(int client, int args)
{
    if (!gST.bLate)
    {
        ReplyToCommand(client, "[IC] 刷特系统尚未启动");
        return Plugin_Handled;
    }

    WaveDecisionState state = WaveDecider_GetState();
    float elapsed = GetGameTime() - gST.lastWaveStartTime;

    char stateName[32];
    WaveDecider_GetStateName(state, stateName, sizeof(stateName));

    ReplyToCommand(client, "[IC] 波决策器状态: %s", stateName);
    ReplyToCommand(client, "  波序号: %d", gST.waveIndex);
    ReplyToCommand(client, "  已用时: %.1f秒", elapsed);
    ReplyToCommand(client, "  特感: %d/%d", gST.totalSI, gCV.iSiLimit);
    ReplyToCommand(client, "%t", "InfectedControl_TraitorWaveStatusReserved", Traitor_CountReservedSlots());
    ReplyToCommand(client, "  Anti-Bait: %s", AntiBait_IsTeamHolding() ? "拦截中" : "放行");

    return Plugin_Handled;
}

// 重建 NavArea、图拓扑和进度缓存
public Action Cmd_RebuildNavCache(int client, int args)
{
    SpawnAttempts_ResetSearchProgress();
    // 强制重建 NavAreas 缓存
    RebuildNavAreasCache();
    
    // 强制重建图拓扑及评分/密度限制使用的进度缓存。
    ClearNavBuckets();
    g_BucketsReady = false;

    // 删除旧的 .kv 缓存文件，防止 BuildNavBuckets 直接从旧缓存加载
    if (g_sBucketCachePath[0] != '\0' && FileExists(g_sBucketCachePath))
        DeleteFile(g_sBucketCachePath);

    if (g_bSpawnAccel)
    {
        SpawnAccel_ResetTopologyRetryState();
        SpawnAccel_StartNavGraph(true);
    }
    else
        BuildNavBuckets();
    
    ReplyToCommand(client, "%t", "InfectedControl_NavCacheRebuildStarted");
    return Plugin_Handled;
}

// =========================
// 重置死亡CD和刷出时间戳
void ResetDeathState()
{
    g_LastSpawnOkTime = 0.0;
    g_SupportShortageStart = 0.0;
    for (int i = 0; i < SI_COUNT; i++) g_LastDeathTime[i] = 0.0;
}

static void StopAll()
{
    SpawnAttempts_ResetPendingActualSpawn();
    WaveSpawnReport_End("stop_all");
    AssaultBurst_Reset();
    SpawnAttempts_ResetSearchProgress();
    StopTrackedTimer(g_hFirstWaveTimer);
    StopTrackedTimer(g_hSaferoomResetTimer);
    StopTrackedTimer(g_hApplyMaxSpecialsTimer);
    g_fFirstWaveRequestedAt = 0.0;
    g_fWaveCheckHeartbeat = 0.0;
    g_fTeleportHeartbeat = 0.0;
    g_iRuntimeCountMismatchTicks = 0;

    gQ.Clear();
    Queue_SyncSizes();
    gST.Reset();
    Traitor_ResetAll(true);
    Traitor_ShutdownDamageHooks();
    AntiBait_OnRoundStart();
    WaveDecider_OnRoundStart();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    ResetDeathState();
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
}
static Action Timer_ApplyMaxSpecials(Handle timer)
{
    if (timer != g_hApplyMaxSpecialsTimer)
        return Plugin_Stop;

    g_hApplyMaxSpecialsTimer = INVALID_HANDLE;
    gCV.ApplyMaxZombieBound();
    return Plugin_Stop;
}

static void ScheduleApplyMaxSpecials()
{
    StopTrackedTimer(g_hApplyMaxSpecialsTimer);
    g_hApplyMaxSpecialsTimer = CreateTimer(
        0.1, Timer_ApplyMaxSpecials, _, TIMER_FLAG_NO_MAPCHANGE);
}

static Action Timer_ResetAtSaferoom(Handle timer)
{
    if (timer != g_hSaferoomResetTimer)
        return Plugin_Stop;

    g_hSaferoomResetTimer = INVALID_HANDLE;
    if (gST.bLate || g_hFirstWaveTimer != INVALID_HANDLE)
        return Plugin_Stop;

    ResetMatchState();
    return Plugin_Stop;
}

static void ScheduleSaferoomReset()
{
    StopTrackedTimer(g_hSaferoomResetTimer);
    g_hSaferoomResetTimer = CreateTimer(
        1.0, Timer_ResetAtSaferoom, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void StartWaveCheckTimer(bool recovery)
{
    StopTrackedTimer(gST.hCheck);
    gST.hCheck = CreateTimer(
        1.0, Timer_CheckSpawnWindow, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    g_fWaveCheckHeartbeat = GetGameTime();
    if (recovery)
        LogError("[IC][RECOVERY] Recreated wave state timer without resetting wave timing (wave=%d)", gST.waveIndex);
}

static void SyncTeleportTimer(bool recovery)
{
    if (!gST.bLate || !gCV.bTeleport)
    {
        StopTrackedTimer(gST.hTeleport);
        g_fTeleportHeartbeat = 0.0;
        return;
    }

    if (IsTrackedTimerValid(gST.hTeleport))
        return;

    gST.hTeleport = INVALID_HANDLE;
    gST.hTeleport = CreateTimer(
        1.0, Timer_TeleportTick, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    g_fTeleportHeartbeat = GetGameTime();
    if (recovery)
        LogError("[IC][RECOVERY] Recreated teleport monitor timer (wave=%d)", gST.waveIndex);
}

static void RequestStartSpawn()
{
    if (gST.bLate || !g_bRuntimeRoundActive || g_bRuntimeMapEnding
        || g_bRuntimeRecoverySuppressed)
        return;

    if (g_hFirstWaveTimer != INVALID_HANDLE)
    {
        if (IsValidHandle(g_hFirstWaveTimer))
            return;
        g_hFirstWaveTimer = INVALID_HANDLE;
    }

    ResetMatchState();
    g_hFirstWaveTimer = CreateTimer(0.1, Timer_SpawnFirstWave, _, TIMER_FLAG_NO_MAPCHANGE);
    g_fFirstWaveRequestedAt = GetGameTime();
    ReadSiCap();
}

static Action Timer_SpawnFirstWave(Handle timer)
{
    if (timer != g_hFirstWaveTimer)
        return Plugin_Stop;

    g_hFirstWaveTimer = INVALID_HANDLE;
    g_fFirstWaveRequestedAt = 0.0;

    if (!g_bRuntimeRoundActive || g_bRuntimeMapEnding || g_bRuntimeRecoverySuppressed)
        return Plugin_Stop;

    if (!gST.bLate)
    {
        gST.bLate = true;
        StartWaveCheckTimer(false);
        StartWave();
        SyncTeleportTimer(false);
    }
    return Plugin_Stop;
}

// =========================
// 事件
// =========================
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRuntimeRoundActive = true;
    g_bRuntimeMapEnding = false;
    g_bRuntimeRecoverySuppressed = false;
    g_bRuntimeRecoveryBusy = false;
    g_fNextRuntimeWatchdogAt = 0.0;
    g_fNextRuntimeHardRecoveryAt = 0.0;
    Traitor_ResetRoundUseLimits();
    StopAll();
    // 权重只在当前回合学习，避免对抗上下半场继承不同的 Nav 历史。
    ClearNavWeightMemory();
    SpawnPerf_OnRoundStart();
    WaveDecider_OnRoundStart();
    ScheduleApplyMaxSpecials();
    ScheduleSaferoomReset();
    ClearPathCache();
}
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRuntimeRoundActive = false;
    g_bRuntimeRecoverySuppressed = true;
    WaveSpawnReport_End("round_end");
    Traitor_OnRoundEnd();
    StopAll();
    ClearPathCache();
}
public void Event_PlayerSpawn(Event event, const char[] name, bool dont_broadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client || !IsClientInGame(client)) return;

    if (IsValidSurvivor(client))
        Traitor_OnSurvivorRevived(client);

    if (!IsFakeClient(client)) return;

    g_LastSpawnTime[client] = GetGameTime();     // 记录出生时间
    gST.teleCount[client]   = 0;                 // 清计数，避免继承旧值

    if (IsSpitter(client))
        gST.spitterSpitTime[client] = GetGameTime();
}

public void Event_AbilityUse(Event event, const char[] name, bool dont_broadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client || !IsClientInGame(client) || !IsFakeClient(client))
        return;
    char ability[16];
    event.GetString("ability", ability, sizeof ability);
    if (strcmp(ability, "ability_spit") == 0)
        gST.spitterSpitTime[client] = GetGameTime();

    if (strcmp(ability, "ability_charge") == 0
        || strcmp(ability, "ability_lunge") == 0
        || strcmp(ability, "ability_leap") == 0
        || strcmp(ability, "ability_tongue") == 0)
    {
        Tactical_OnPressureEngaged();
    }
}

public void Event_PressureEngaged(Event event, const char[] name, bool dont_broadcast)
{
    Tactical_OnPressureEngaged();
}
public void Event_PlayerHurt(Event event, const char[] name, bool dont_broadcast)
{
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int dmg      = GetEventInt(event, "dmg_health");

    if (!gCV.bAddDmgSmoker) return;

    int evHealth = GetEventInt(event, "health");
    if (IsValidSurvivor(attacker) && IsInfectedBot(victim) && GetEntProp(victim, Prop_Send, "m_zombieClass") == view_as<int>(SI_Smoker))
    {
        int bonus = 0;
        if (GetEntPropEnt(victim, Prop_Send, "m_tongueVictim") > 0)
            bonus = dmg * 5;
        int hp = evHealth - bonus;
        if (hp < 0) hp = 0;
        SetEntityHealth(victim, hp);
    }
}

public void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    Traitor_OnSurvivorIncapacitated(client);
}

public void Event_PlayerLedgeGrab(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    Traitor_OnSurvivorIncapacitated(client);
}

public void Event_PlayerReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("subject"));
    if (client <= 0)
        client = GetClientOfUserId(event.GetInt("userid"));

    Traitor_OnSurvivorRevived(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (SpawnAttempts_ConsumeRejectedActualDeath(client)
        || SpawnAttempts_IsPendingActualClient(client))
        return;

    if (IsValidSurvivor(client))
        Traitor_OnSurvivorDeath(client);

    if (Traitor_OnPlayerDeath(client))
        return;

    if (!IsInfectedBot(client)) return;

    int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zc != view_as<int>(SI_Spitter))
        CreateTimer(0.5, Timer_KickBot, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    if (zc >= 1 && zc <= SI_COUNT)
    {
        // 只在未处于冷却期时触发一次 CD，冷却中死亡不重置。
        TouchDeathCooldownOnce(zc);

        int idx = zc - 1;
        if (gST.siAlive[idx] > 0) gST.siAlive[idx]--; else gST.siAlive[idx] = 0;
        if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
        InvalidateBucketShareCache();
    }
    gST.teleCount[client] = 0;
    RecalcSiCapFromAlive(false);  // 保持：死亡后刷新剩余额度
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!client)
        return;

    Traitor_OnClientTeamChanged(client, event.GetInt("oldteam"), event.GetInt("team"));
}

public void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
    int player = GetClientOfUserId(event.GetInt("player"));
    int bot = GetClientOfUserId(event.GetInt("bot"));
    Traitor_OnBileVictimReplaced(player, bot);
    Traitor_OnPlayerBotReplace(player, bot);
}

public void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
    int bot = GetClientOfUserId(event.GetInt("bot"));
    int player = GetClientOfUserId(event.GetInt("player"));
    Traitor_OnBileVictimReplaced(bot, player);
}

public void Event_PlayerNoLongerIt(Event event, const char[] name, bool dontBroadcast)
{
    Traitor_OnBileEffectEnded(GetClientOfUserId(event.GetInt("userid")));
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
        Traitor_OnClientDisconnect(client);
}

public void OnClientDisconnect(int client)
{
    SpawnAttempts_ClearRejectedActualSpawn(client);
    TraitorQuota_InvalidateClientCache(client);
    Traitor_UnhookClientDamage(client);
    Traitor_OnClientDisconnect(client);
}

public void OnClientPutInServer(int client)
{
    TraitorQuota_InvalidateClientCache(client);
    Traitor_InitializeClientDamage(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    Traitor_OnEntityCreated(entity, classname);
}

public void OnEntityDestroyed(int entity)
{
    Traitor_OnEntityDestroyed(entity);
}

static Action Timer_KickBot(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client) && !IsClientInKickQueue(client) && IsFakeClient(client))
    {
        KickClient(client, "SI teleport cleanup");
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

public void OnUnpause()
{
    AntiBait_OnUnpause();
    WaveDecider_OnUnpause();
    float delay = (gST.unpauseDelay > 0.1) ? gST.unpauseDelay : 1.0;
    UnpauseSpawnTimer(delay);
}

// =========================
// CVar / 上限
// =========================
void OnCfgChanged(ConVar convar, const char[] ov, const char[] nv)
{
    SpawnAttempts_ResetSearchProgress();
    bool traitorDisabled = convar == gCV.TraitorEnable && StringToInt(ov) != 0 && StringToInt(nv) == 0;
    gCV.Refresh();
    gCV.ApplyMaxZombieBound();
    if (convar == gCV.SpawnAccelNativeSafety)
        SpawnAccel_UpdateAvailability(true);
    SyncTeleportTimer(false);

    if (traitorDisabled)
    {
        Traitor_ReturnAllReservedSlotsToAI();
        Traitor_ResetAll(true);
    }
}
void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{
    SpawnAttempts_ResetSearchProgress();
    // 图模式只需按缓存的原始 Nav flow 重算 areaIdx -> 百分比。
    if (!SpawnAccel_RebuildAreaProgress())
        RebuildNavBuckets();
}
void OnSiLimitChanged(ConVar convar, const char[] ov, const char[] nv)
{
    gCV.iSiLimit = gCV.SiLimit.IntValue;
    ScheduleApplyMaxSpecials();
    RecalcSiCapFromAlive(false);

    if (gST.siQueueCount < 0)
        gST.siQueueCount = 0;
    if (gST.siQueueCount > gCV.iSiLimit)
        gST.siQueueCount = gCV.iSiLimit;
    SpawnQueue_TrimToLength(gST.siQueueCount);

    // 立刻按新上限收缩记录
    CleanupLastSpawns(GetGameTime());
    gCV.Refresh();
}

static int CountActualSpecialInfected()
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsCountedSpecial(client) && IsPlayerAlive(client) && !IsGhost(client))
            count++;
    }
    return count;
}

static void ForceRuntimeRecovery(const char[] reason, float now)
{
    if (g_bRuntimeRecoveryBusy || now < g_fNextRuntimeHardRecoveryAt)
        return;

    g_bRuntimeRecoveryBusy = true;
    g_fNextRuntimeHardRecoveryAt = now + RUNTIME_HARD_RECOVERY_COOLDOWN;
    LogError("[IC][RECOVERY] Forcing runtime restart: %s (wave=%d state=%d late=%d)",
        reason, gST.waveIndex, view_as<int>(WaveDecider_GetState()), gST.bLate ? 1 : 0);

    WaveSpawnReport_End("watchdog_recover");
    StopAll();
    if (g_bRuntimeRoundActive && !g_bRuntimeMapEnding
        && !g_bRuntimeRecoverySuppressed && L4D_HasAnySurvivorLeftSafeArea())
    {
        RequestStartSpawn();
    }
    g_bRuntimeRecoveryBusy = false;
}

static void RuntimeWatchdog(float now)
{
    if (now < g_fNextRuntimeWatchdogAt)
        return;
    g_fNextRuntimeWatchdogAt = now + RUNTIME_WATCHDOG_INTERVAL;

    if (!g_bInfectedControlStarted || !g_bRuntimeRoundActive
        || g_bRuntimeMapEnding || g_bRuntimeRecoverySuppressed)
    {
        return;
    }

    bool leftSafeArea = L4D_HasAnySurvivorLeftSafeArea();
    if (!gST.bLate)
    {
        if (g_hFirstWaveTimer != INVALID_HANDLE
            && !IsValidHandle(g_hFirstWaveTimer))
        {
            g_hFirstWaveTimer = INVALID_HANDLE;
            g_fFirstWaveRequestedAt = 0.0;
            LogError("[IC][RECOVERY] Cleared stale first-wave timer handle");
        }

        if (!leftSafeArea)
            return;

        if (g_hFirstWaveTimer == INVALID_HANDLE)
        {
            LogError("[IC][RECOVERY] First wave missing after survivors left safe area; rescheduling");
            RequestStartSpawn();
            return;
        }

        if (g_fFirstWaveRequestedAt > 0.0
            && now - g_fFirstWaveRequestedAt >= RUNTIME_FIRST_WAVE_TIMEOUT)
        {
            LogError("[IC][RECOVERY] First-wave timer timed out after %.1fs; rescheduling",
                now - g_fFirstWaveRequestedAt);
            StopTrackedTimer(g_hFirstWaveTimer);
            g_fFirstWaveRequestedAt = 0.0;
            RequestStartSpawn();
        }
        return;
    }

    if (g_hFirstWaveTimer != INVALID_HANDLE)
    {
        LogError("[IC][RECOVERY] Removing duplicate first-wave timer from active runtime");
        StopTrackedTimer(g_hFirstWaveTimer);
        g_fFirstWaveRequestedAt = 0.0;
    }

    bool checkTimerInvalid = !IsTrackedTimerValid(gST.hCheck);
    bool checkHeartbeatStale = g_fWaveCheckHeartbeat > 0.0
        && now - g_fWaveCheckHeartbeat >= RUNTIME_TIMER_STALE_SECONDS;
    if (checkTimerInvalid || checkHeartbeatStale)
        StartWaveCheckTimer(true);

    bool teleportHeartbeatStale = g_fTeleportHeartbeat > 0.0
        && now - g_fTeleportHeartbeat >= RUNTIME_TIMER_STALE_SECONDS;
    if (gCV.bTeleport && (!IsTrackedTimerValid(gST.hTeleport) || teleportHeartbeatStale))
    {
        StopTrackedTimer(gST.hTeleport);
        SyncTeleportTimer(true);
    }
    else if (!gCV.bTeleport && gST.hTeleport != INVALID_HANDLE)
    {
        SyncTeleportTimer(false);
    }

    if (gST.hSpawn != INVALID_HANDLE && !IsValidHandle(gST.hSpawn))
    {
        gST.hSpawn = INVALID_HANDLE;
        LogError("[IC][RECOVERY] Cleared stale next-wave timer handle (wave=%d)", gST.waveIndex);
    }

    if (gST.siQueueCount < 0 || gST.siQueueCount > gCV.iSiLimit
        || SpawnQueue_Length() > gST.siQueueCount)
    {
        int oldPending = gST.siQueueCount;
        int oldQueueLength = SpawnQueue_Length();
        if (gST.siQueueCount < 0)
            gST.siQueueCount = 0;
        if (gST.siQueueCount > gCV.iSiLimit)
            gST.siQueueCount = gCV.iSiLimit;
        SpawnQueue_TrimToLength(gST.siQueueCount);
        LogError("[IC][RECOVERY] Corrected pending queue bounds: budget=%d->%d queue=%d->%d limit=%d",
            oldPending, gST.siQueueCount, oldQueueLength,
            SpawnQueue_Length(), gCV.iSiLimit);
    }

    int transientSpecials = SpawnAttempts_CountPendingActualSpawns()
        + SpawnAttempts_CountRejectedActualSpawns();
    int actualSpecials = CountActualSpecialInfected();
    if (transientSpecials > 0)
    {
        // SpawnSpecial 已创建实体，但 pending 尚未提交；被拒实体也可能仍在
        // Kick 队列中。此时 Recalc 会把临时实体提前算入，提交/断开后再
        // 增减一次，反而制造真实漂移，因此等临时态清空后再连续核验。
        g_iRuntimeCountMismatchTicks = 0;
    }
    else if (actualSpecials != gST.totalSI)
    {
        g_iRuntimeCountMismatchTicks++;
    }
    else
    {
        g_iRuntimeCountMismatchTicks = 0;
    }

    if (g_iRuntimeCountMismatchTicks >= 2)
    {
        LogError("[IC][RECOVERY] Correcting SI count drift: tracked=%d actual=%d wave=%d",
            gST.totalSI, actualSpecials, gST.waveIndex);
        RecalcSiCapFromAlive(false);
        g_iRuntimeCountMismatchTicks = 0;
    }

    bool invalidWaveState = gST.waveIndex <= 0 || gST.lastWaveStartTime <= 0.0
        || !WaveDecider_IsActive();
    bool paused = g_bPauseLib && IsInPause();
    if (invalidWaveState && !paused)
        ForceRuntimeRecovery("active runtime has no valid wave state", now);
}
// =========================
// 帧驱动
// =========================
public void OnGameFrame()
{
    // SpawnSpecial 返回后等待短暂稳定窗口，再批量提交或拒绝临时实体。
    SpawnAttempts_ProcessPendingActualSpawns();

    float now = GetGameTime();
    RuntimeWatchdog(now);

    bool hasSpawnWork = (gST.bLate && (SpawnAttempts_HasPendingActualSpawn()
        || Traitor_HasSpawnWork()
        || (gST.totalSI < gCV.iSiLimit
            && (TeleportQueue_Length() > 0 || gST.siQueueCount > 0 || SpawnQueue_Length() > 0))));
    float releaseEta = WaveDecider_GetReleaseEta();
    bool candidateWarm = hasSpawnWork
        || gST.hSpawn != INVALID_HANDLE
        || g_hFirstWaveTimer != INVALID_HANDLE
        || (releaseEta >= 0.0 && releaseEta <= NAV_CANDIDATE_WARMUP_LEAD);
    SpawnAccel_UpdateCandidateSnapshots(now, candidateWarm);

    // 外部插件可能改写 z_max_player_zombies，但没有必要为此每帧读取 ConVar。
    if (now >= gST.nextMaxZombieCheck)
    {
        if (gCV.GetMaxPlayerZombieBound() > gCV.MaxPlayerZombies.IntValue)
            gCV.ApplyMaxZombieBound();
        gST.nextMaxZombieCheck = now + 1.0;
    }

    if (now < gST.nextFrameThink)
        return;

    float nextThinkStep = hasSpawnWork ? gCV.fFrameThinkStepActive : gCV.fFrameThinkStep;
    // 两种安全检查实现使用同一推进频率，避免 native 模式在职业轮转中
    // 反而只获得一半的搜索时间片。
    if (hasSpawnWork)
        nextThinkStep = FloatMin(nextThinkStep, 0.01);
    gST.nextFrameThink = now + nextThinkStep;

    int pendingActual = SpawnAttempts_CountPendingActualSpawns();
    int rejectedActual = SpawnAttempts_CountRejectedActualSpawns();
    if (gST.totalSI + pendingActual + rejectedActual >= gCV.iSiLimit)
        return;

    // 开波时已经批量补齐队列。只有丢弃队首或死亡 CD 暂时无可用职业时才需要重试，
    // 并限制到每 0.25 秒一次，避免搜索期间反复遍历 MaxClients 重算职业上限。
    int pendingNormal = SpawnAttempts_CountPendingNormalSpawns();
    if (pendingNormal == 0 && SpawnQueue_Length() < gST.siQueueCount
        && now >= gST.nextQueueMaintain)
    {
        FillSpawnQueueToPendingBudget();
        gST.nextQueueMaintain = now + 0.25;
    }

    if (!gST.bLate)
        return;

    float burstStart = GetEngineTime();
    int burstAttempts = 0;
    bool budgetStop = false;
    while (burstAttempts < gCV.iSpawnAttemptsPerFrame
        && gST.totalSI + SpawnAttempts_CountPendingActualSpawns()
            + SpawnAttempts_CountRejectedActualSpawns()
            < gCV.iSiLimit)
    {
        bool attempted = false;
        if (TeleportQueue_Length() > 0)
        {
            TryTeleportSpawnOnce();
            attempted = true;
        }
        else if (gST.siQueueCount > 0 && SpawnQueue_Length() > 0)
        {
            TryNormalSpawnOnce();
            attempted = true;
        }

        if (!attempted)
            break;

        burstAttempts++;
        float elapsedMs = (GetEngineTime() - burstStart) * 1000.0;
        if (elapsedMs >= gCV.fSpawnFrameBudgetMs)
        {
            budgetStop = (TeleportQueue_Length() > 0
                || (gST.siQueueCount > 0 && SpawnQueue_Length() > 0));
            break;
        }
    }

    if (burstAttempts > 0)
    {
        WaveSpawnReport_RecordFrameBurst(
            burstAttempts, (GetEngineTime() - burstStart) * 1000.0, budgetStop);
    }
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

#include "infected_control/nav_debug.inc"

// --- pause
public void OnPause()
{
    AntiBait_OnPause();
    WaveDecider_OnPause();
    PauseSpawnTimer();
}
