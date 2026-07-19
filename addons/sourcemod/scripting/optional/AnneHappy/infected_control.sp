#pragma semicolon 1
#pragma newdecls required

/**
 * Infected Control (fdxx-style NavArea spot picking + max-distance fallback + 动态FLOW分桶)
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
 *  8. Nav 分桶与缓存：BuildNavBuckets / KV 读写 / 桶窗口序列（含本文件补完的 BuildBucketOrder）
 *  9. Flow 与 Survivor 进度：安全获取、回退 TTL、每秒刷新“最后一次有效团队进度”
 * 10. 跑男检测与目标生还者选择
 * 11. 工具函数：可视/线段/碰撞/冷却/扇区/日志
 *
 * ── 行为要点（Behavior）
 *  - 预建 Nav Flow 分桶（0..100%），刷点时仅在“目标生还者附近 ±N 桶”内扫描
 *  - 扩圈 SpawnMin→SpawnMax；到达上限走导演兜底
 *  - 评分四因子：距离 / 高度偏好 / Flow / 分散度（可调权重）
 *  - badflow 仅作轻度扣分（不强制禁用），支持空间映射就近归桶
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
#include <dbi>
#include <sdktools>
#include <sdkhooks>
#include <sdktools_tempents>
#include <left4dhooks>
#include <sourcescramble>
#undef REQUIRE_PLUGIN
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
#define RING_SLACK                350.0
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
#define BUCKET_CACHE_VER "2026-07"  // 和插件版号保持同步

// 记录最近使用过的 navArea -> 过期时间
StringMap g_NavCooldown;

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
char g_sBucketCachePath[PLATFORM_MAX_PATH] = "";

#include "infected_control/nav_types.inc"
#include "infected_control/spawn_score_types.inc"
#include "infected_control/utils.inc"
#include "infected_control/config.inc"

// —— 可选库可用性 —— 
bool g_bPauseLib       = false;
bool g_bSmokerLib      = false;
bool g_bTargetLimitLib = false;

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
Handle g_hFirstWaveTimer = INVALID_HANDLE;

// =========================
// 全局
// =========================
public Plugin myinfo =
{
    name        = "Direct InfectedSpawn (fdxx-nav + buckets + maxdist-fallback)",
    author      = "东, Caibiii, 夜羽真白, Paimon-Kawaii, fdxx (inspiration)",
    description = "特感刷新控制 / 传送 / 跑男 / fdxx NavArea选点 + 进度分桶 + 最大距离兜底",
    version     = "2026-07",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

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

#include "infected_control/runtime_state.inc"
#include "infected_control/queue.inc"
#include "infected_control/class_queue.inc"
#include "infected_control/client_state.inc"

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
#include "infected_control/nav_cache.inc"
#include "infected_control/nav_persist.inc"
#include "infected_control/nav_buckets.inc"
#include "infected_control/spawn_perf_optimizer.inc"
#include "infected_control/spawn_perf_config.inc"
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
    RegPluginLibrary("infected_control");                           // 供其他插件依赖
    g_hRushManNotifyForward = CreateGlobalForward("OnDetectRushman", // 跑男 forward：传入幸存者 index
                                                  ET_Ignore, Param_Cell);
    CreateNative("GetNextSpawnTime", Native_GetNextSpawnTime);       // native：下一次刷特剩余秒数
    CreateNative("InfectedControl_IsTraitorClient", Native_InfectedControlIsTraitorClient);
    CreateNative("InfectedControl_HandleTraitorTankOffer", Native_InfectedControlHandleTraitorTankOffer);
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

    float rem = DifficultyStrategy_GetConfiguredWaveDelay() - float(gST.lastSpawnSecs);
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
    TraitorQuota_Init();
    ClassCapMirrors_Create();
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
    // 初始化 Path 缓存
    PathCache_Init();

    // 初始化死亡时间戳
    g_LastSpawnOkTime = 0.0;
    g_SupportShortageStart = 0.0;
    for (int i = 0; i < SI_COUNT; i++) g_LastDeathTime[i] = 0.0;

    RegAdminCmd("sm_startspawn", Cmd_StartSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
    RegAdminCmd("sm_stopspawn",  Cmd_StopSpawn,  ADMFLAG_ROOT, "管理员停止刷特");
    RegAdminCmd("sm_rebuildnavcache", Cmd_RebuildNavCache, ADMFLAG_ROOT, "Rebuild Nav bucket cache for current map");
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
    HookEvent("player_hurt",     Event_PlayerHurt);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
            Traitor_HookClientDamage(client);
    }
}

public void OnPluginEnd()
{
    // 插件结束时清理 Path 缓存
    ClearPathCache();
    TraitorQuota_Close();
}
public void OnMapEnd()
{
    if (g_NavCooldown != null) g_NavCooldown.Clear();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    g_LastSpawnOkTime = 0.0;
    g_SupportShortageStart = 0.0;
    for (int i = 0; i < SI_COUNT; i++) g_LastDeathTime[i] = 0.0;
    Traitor_ResetAll(true);

    ClearNavBuckets();
    g_BucketsReady = false;
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
    if (g_NavIdToIndex != null) { delete g_NavIdToIndex; g_NavIdToIndex = null; }
    ClearPathCache();
    ClearNavAreasCache();

    if (SpawnPerfConfig_ShowStats())
    {
        SpawnPerf_OnMapEnd();
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
    RequestStartSpawn();
    return Plugin_Handled;
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
    RequestStartSpawn();
    return Plugin_Continue;
}
public Action Cmd_StopSpawn(int client, int args)
{
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

// 重建 NavArea 缓存和分桶缓存
public Action Cmd_RebuildNavCache(int client, int args)
{
    // 强制重建 NavAreas 缓存
    RebuildNavAreasCache();
    
    // 强制重建并覆盖 Bucket 缓存
    ClearNavBuckets();
    g_BucketsReady = false;

    // 删除旧的 .kv 缓存文件，防止 BuildNavBuckets 直接从旧缓存加载
    if (g_sBucketCachePath[0] != '\0' && FileExists(g_sBucketCachePath))
        DeleteFile(g_sBucketCachePath);

    BuildNavBuckets();
    
    ReplyToCommand(client, "[IC] Rebuilt Nav bucket cache (forced, old cache deleted).");
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
    if (g_hFirstWaveTimer != INVALID_HANDLE)
    {
        KillTimer(g_hFirstWaveTimer);
        g_hFirstWaveTimer = INVALID_HANDLE;
    }

    gQ.Clear();
    Queue_SyncSizes();
    gST.Reset();
    Traitor_ResetAll(true);
    AntiBait_OnRoundStart();
    WaveDecider_OnRoundStart();
    if (lastSpawns != null) lastSpawns.Clear();
    recentSectors[0] = recentSectors[1] = recentSectors[2] = -1;

    ResetDeathState();
    for (int i = 0; i <= MAXPLAYERS; i++) g_LastSpawnTime[i] = 0.0;
}
static Action Timer_ApplyMaxSpecials(Handle timer)
{
    gCV.ApplyMaxZombieBound();
    return Plugin_Stop;
}
static Action Timer_ResetAtSaferoom(Handle timer)
{
    if (gST.bLate || g_hFirstWaveTimer != INVALID_HANDLE)
        return Plugin_Stop;

    ResetMatchState();
    return Plugin_Stop;
}

static void RequestStartSpawn()
{
    if (gST.bLate || g_hFirstWaveTimer != INVALID_HANDLE)
        return;

    ResetMatchState();
    g_hFirstWaveTimer = CreateTimer(0.1, Timer_SpawnFirstWave, _, TIMER_FLAG_NO_MAPCHANGE);
    ReadSiCap();
}

static Action Timer_SpawnFirstWave(Handle timer)
{
    g_hFirstWaveTimer = INVALID_HANDLE;

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
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
    SpawnPerf_OnRoundStart();
    WaveDecider_OnRoundStart();
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
    CreateTimer(1.0,  Timer_ResetAtSaferoom, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(2.0, Timer_RebuildBuckets, _, TIMER_FLAG_NO_MAPCHANGE); // 地图开局重建分桶
    ClearPathCache();
}
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
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
        SetEventInt(event, "health", hp);
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
    if (IsValidSurvivor(client))
        Traitor_OnSurvivorDeath(client);

    if (Traitor_OnPlayerDeath(client))
        return;

    if (!IsInfectedBot(client)) return;

    int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zc != view_as<int>(SI_Spitter))
        CreateTimer(0.5, Timer_KickBot, GetClientUserId(client));

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
    Traitor_UnhookClientDamage(client);
    Traitor_OnClientDisconnect(client);
}

public void OnClientPutInServer(int client)
{
    Traitor_HookClientDamage(client);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    Traitor_OnEntityCreated(entity, classname);
}

public void OnEntityDestroyed(int entity)
{
    Traitor_OnEntityDestroyed(entity);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    return Traitor_OnPlayerRunCmd(client, buttons);
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
    float delay = (gST.unpauseDelay > 0.1) ? gST.unpauseDelay : 1.0;
    UnpauseSpawnTimer(delay);
}

// =========================
// CVar / 上限
// =========================
void OnCfgChanged(ConVar convar, const char[] ov, const char[] nv)
{
    bool traitorDisabled = convar == gCV.TraitorEnable && StringToInt(ov) != 0 && StringToInt(nv) == 0;
    gCV.Refresh();
    gCV.ApplyMaxZombieBound();

    if (traitorDisabled)
        Traitor_ResetAll(false);
}
void OnFlowBufferChanged(ConVar convar, const char[] ov, const char[] nv)
{
    // Flow 百分比变化会影响分桶 → 重建
    RebuildNavBuckets();
}
void OnSiLimitChanged(ConVar convar, const char[] ov, const char[] nv)
{
    gCV.iSiLimit = gCV.SiLimit.IntValue;
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
    RecalcSiCapFromAlive(false);

    // 立刻按新上限收缩记录
    CleanupLastSpawns(GetGameTime());
    gCV.Refresh();
}
// =========================
// 帧驱动
// =========================
public void OnGameFrame()
{
    if (gCV.GetMaxPlayerZombieBound() > gCV.MaxPlayerZombies.IntValue)
        gCV.ApplyMaxZombieBound();

    float now = GetGameTime();
    if (now < gST.nextFrameThink)
        return;

    bool hasSpawnWork = (gST.bLate && (Traitor_HasSpawnWork()
        || (gST.totalSI < gCV.iSiLimit
            && (TeleportQueue_Length() > 0 || gST.siQueueCount > 0 || SpawnQueue_Length() > 0))));
    gST.nextFrameThink = now + (hasSpawnWork ? gCV.fFrameThinkStepActive : gCV.fFrameThinkStep);

    if (gST.totalSI >= gCV.iSiLimit)
        return;

    // 每个 think slice 先维护普通刷特队列：按上限、稀缺度、死亡 CD 和支援特感规则补队列。
    // 真正刷出时优先处理传送队列，因为传送一般意味着已有特感失去作用或跑男压力更高。
    MaintainSpawnQueueOnce();

    if (!gST.bLate)
        return;

    if (TeleportQueue_Length() > 0 && gST.totalSI < gCV.iSiLimit)
    {
        TryTeleportSpawnOnce();
        return;
    }

    if (gST.siQueueCount > 0 && SpawnQueue_Length() > 0 && gST.totalSI < gCV.iSiLimit)
    {
        TryNormalSpawnOnce();
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
    PauseSpawnTimer();
}
