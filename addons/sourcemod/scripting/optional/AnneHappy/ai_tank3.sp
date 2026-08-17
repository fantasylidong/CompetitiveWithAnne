#pragma semicolon 1
#pragma newdecls required

// ===== 头文件 =====
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#include <treeutil>
#include <logger2>
#include <anne_nextbot>
#include "ai_path_movement.inc"
// 你自己的公共方法、工具函数（判定AI Tank / 可见性 / 贴图等）都在这里
#include "../../archive/AnneHappy/stocks.sp"

// ===== 常量 / 宏 =====
#define CVAR_FLAGS                 FCVAR_NONE
#define PLUGIN_PREFIX              "Ai-Tank3"
#define GAMEDATA                   "l4d2_ai_tank3"

#define DEFAULT_THROW_FORCE        800.0
#define DEFAULT_SV_GRAVITY         800.0
#define DEFAULT_SWING_RANGE        56.0
#define PATH_LOOKAHEAD_MIN_DIST    150.0
#define PATH_GOAL_TOLERANCE_DIST   25.0
#define MAX_TANK_PATH_SNAPSHOT_SEGMENTS 256

#define ROCK_FL_GRAVITY            0.4

#define PLAYER_HEIGHT              72.0
#define PLAYER_EYE_HEIGHT          62.0
#define PLAYER_CHEST               52.0
#define TANK_HEIGHT                84.0
#define JUMP_HEIGHT                56.0

#define THROW_UNDERHEAD_POS_Z      33.38  // 单手下挥出手高度
#define THROW_OVERSHOULDER_POS_Z   93.58  // 单手过肩出手高度
#define THROW_OVERHEAD_POS_Z       104.01 // 双手过头出手高度

#define JUMP_SPEED_Z               300.0  // 跳砖时给的Z轴速度
#define LADDER_NEARBY_CACHE_DEFAULT 0.20  // 梯子附近检测缓存，避免每帧扫实体/nav
#define HEAD_BLOCK_PROGRESS_DIST   32.0   // 判定窗口内移动超过该距离视为仍在正常寻路

// ===== ConVar =====
ConVar g_cvPluginName, g_cvLogLevel;

ConVar
    g_cvEnable,
    g_cvTankBhop,
    g_cvBhopMinDist,
    g_cvBhopMaxDist,
    g_cvBhopMinSpeed,
    g_cvBhopMaxSpeed,
    g_cvBhopImpulse,
    g_cvBhopNoVision,
    g_cvBhopPathFallbackDist,
    g_cvPathLookAheadMaxDepth,
    g_cvThrowMinDist,
    g_cvThrowMaxDist,
    g_cvAirVecModifyDegree,
    g_cvAirVecModifyMaxDegree,
    g_cvAirVecModifyInterval,
    g_cvRockTargetAdjust,
    g_cvBackFist,
    g_cvBackFistRange,
    g_cvBackFistAllowMaxSpd,
    g_cvPunchLockVision,
    g_cvJumpRock,
    g_cvBackFistWindow,
    g_cvHeadBlockEnable,
    g_cvHeadBlockTime,
    g_cvHeadBlockVertical,
    g_cvHeadBlockHorizontal,
    g_cvHeadBlockIgnoreTime,
    g_cvHeadBlockSwitchCooldown,
    g_cvHeadBlockForceRockTime,
    g_cvHeadBlockForceRockRange,
    g_cvHeadBlockForceRockReleaseHoriz,
    g_cvHeadBlockForceRockReleaseVert,
    g_cvLadderNearbyDisable,
    g_cvLadderNearbyRadius,
    g_cvLadderNearbyCacheTime;

ConVar g_cvBhopNoVisionMaxAng;
ConVar cvTankSwingRange;

// ===== 运行时对象 =====
StringMap g_hThrowAnimMap;
ArrayList g_hNearbyLadderList;

Handle g_hSdkTankClawSweepFist;

bool  g_bLateLoad;
float g_fTankSwingRange;
float g_fHeadBlockIgnoreUntil[MAXPLAYERS + 1][MAXPLAYERS + 1];
float g_fLastLadderNearbyCheck[MAXPLAYERS + 1];
bool  g_bLastLadderNearby[MAXPLAYERS + 1];

// ===== 结构体 =====
enum struct PathSegment
{
    Address m_pPathSegment;
    Address m_pNavArea;
    float   m_vecGoalPos[3];
    float   m_vecForward[3];
    int     m_iNavTraverseType;
    int     m_SegmentType;
    float   m_flLength;
    float   m_flDistFromStart;

    void initData()
    {
        this.m_pPathSegment = Address_Null;
        this.m_pNavArea = Address_Null;
        this.m_vecGoalPos = NULL_VECTOR;
        this.m_vecForward = NULL_VECTOR;
        this.m_iNavTraverseType = 0;
        this.m_SegmentType = 0;
        this.m_flLength = 0.0;
        this.m_flDistFromStart = 0.0;
    }
}

enum TankBhopType
{
    TankBhopType_None,
    TankBhopType_Path,
    TankBhopType_Normal
}

enum struct AiTank
{
    int   target;               // 目标(userId)
    float lastAirVecModifyTime; // 上次空中速度修正时间
    float lastLookAheadTime;    // 上次路径前瞻刷新时间
    float nextAttackTime;       // 下次挥拳时间
    bool  wasThrowing;          // 是否处于扔石头序列中
    float lastHopSpeed;         // 上次起跳时的速度（用于空中修正还原）
    float backFistExpire;       // 通背拳允许窗口到期时间（EngineTime <= 0 未开启）
    float headBlockStart;       // 头顶卡检测开始时间
    float headBlockOrigin[3];   // 头顶卡检测窗口开始时的 Tank 位置
    float lastHeadBlockTargetSwitch; // 上次因头顶拉黑强制换目标时间
    int   forcedTarget;         // 反头顶卡期间锁定的替代目标(userId)
    float forcedTargetUntil;    // 临时目标锁截止时间
    float forceRockUntil;       // 除卡位者外其他生还都倒地时的强制投石截止时间
    int   forceRockTarget;      // 除卡位者外其他生还都倒地时的强制投石目标(userId)
    PathSegment pathSegment;    // 当前 PathSegment
    PathSegment lastPathSegment;// 当前路径最后一个 PathSegment
    float airCorrGoal[3];       // 无视野路径连跳的空中修正目标点
    TankBhopType bhopType;      // 当前连跳类型

    void initData()
    {
        this.target = -1;
        this.lastAirVecModifyTime = 0.0;
        this.lastLookAheadTime = 0.0;
        this.nextAttackTime = 0.0;
        this.wasThrowing = false;
        this.lastHopSpeed = 0.0;
        this.backFistExpire = 0.0;
        this.headBlockStart = 0.0;
        this.headBlockOrigin = NULL_VECTOR;
        this.lastHeadBlockTargetSwitch = 0.0;
        this.forcedTarget = -1;
        this.forcedTargetUntil = 0.0;
        this.forceRockUntil = 0.0;
        this.forceRockTarget = -1;
        this.pathSegment.initData();
        this.lastPathSegment.initData();
        this.airCorrGoal = NULL_VECTOR;
        this.bhopType = TankBhopType_None;
    }
}
AiTank g_AiTanks[MAXPLAYERS + 1];
ArrayList g_TankPathSnapshots[MAXPLAYERS + 1];

Logger log;

// ===== Tank 动画类型（按逻辑分类）=====
enum TankSequenceType
{
    tankSequence_Throw
}

// ===== 插件信息 =====
public Plugin myinfo =
{
    name        = "Ai-Tank 3",
    author      = "夜羽真白",
    description = "Ai Tank 增强 3.0 版本（含攀爬/梯子分离加速、空速修正、跳砖、通背拳窗口等）",
    version     = "1.0.0.8",
    url         = "https://steamcommunity.com/id/saku_ra/"
};

// ===== 预加载 =====
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "本插件仅支持 Left 4 Dead 2");
        return APLRes_SilentFailure;
    }
    MarkNativeAsOptional("L4D_FindEntityByClassnameNearest");
    MarkNativeAsOptional("L4D_FindEntityByClassnameWithin");
    MarkNativeAsOptional("L4D_NavArea_GetLadder");
    g_bLateLoad = late;
    return APLRes_Success;
}

// ===== 启动 =====
public void OnPluginStart()
{
    // 总开关
    g_cvEnable = CreateConVar("ai_tank3_enable", "1", "是否启用插件, 0=禁用, 1=启用", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 连跳
    g_cvTankBhop   = CreateConVar("ai_tank_bhop", "1", "是否允许坦克连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopMinDist= CreateConVar("ai_Tank_StopDistance", "135", "停止连跳的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxDist= CreateConVar("ai_tank3_bhop_max_dist", "9999", "开始连跳的最大距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMinSpeed=CreateConVar("ai_tank3_bhop_min_speed", "200", "连跳的最小速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxSpeed=CreateConVar("ai_tank3_bhop_max_speed", "1000", "连跳的最大速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopImpulse =CreateConVar("ai_tank3_bhop_impulse", "60", "连跳的加速度（每次离地时追加）", CVAR_FLAGS, true, 0.0);
    g_cvBhopNoVision=CreateConVar("ai_tank3_bhop_no_vision", "1", "无视野是否允许连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopNoVisionMaxAng = CreateConVar("_ai_tank3_bhop_nvis_maxang", "75.0", "无视野时速度向量与视角前向向量阈值（度）", CVAR_FLAGS, true, 0.0);
    g_cvBhopPathFallbackDist = CreateConVar("ai_tank3_bhop_path_fallback_dist", "500.0", "Tank 无视野且距离大于该值时使用 Path 前瞻连跳；有视野或近于该值时回退当前连跳", CVAR_FLAGS, true, 0.0);
    g_cvPathLookAheadMaxDepth = CreateConVar("ai_tank3_path_lookahead_maxdepth", "10", "Tank 无视野 Path 连跳向前搜索 PathSegment 的最大深度", CVAR_FLAGS, true, 1.0);

    // 空速矫正
    g_cvAirVecModifyDegree     = CreateConVar("ai_tank3_airvec_modify_degree", "45.0", "空速方向与目标方向角 >=此值 开始修正", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyMaxDegree  = CreateConVar("ai_tank3_airvec_modify_degree_max", "135.0", "角度 >此值 不再修正", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyInterval   = CreateConVar("ai_tank3_airvec_modify_interval", "0.3", "空速方向修正最小间隔(秒)", CVAR_FLAGS, true, 0.1);

    // 投石/距离
    g_cvThrowMinDist = CreateConVar("ai_tank3_throw_min_dist", "0",   "允许扔石头的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvThrowMaxDist = CreateConVar("ai_tank3_throw_max_dist", "800", "允许扔石头的最大距离", CVAR_FLAGS, true, 0.0);

    // 投石目标调整 / 通背拳 / 锁视角 / 跳砖
    g_cvRockTargetAdjust  = CreateConVar("ai_tank3_rock_target_adjust", "1", "扔石头时若原目标不可见，允许切换至最近可视目标", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFist          = CreateConVar("ai_tank3_back_fist", "1", "允许通背拳（可拍背后的人）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFistRange     = CreateConVar("ai_tank3_back_fist_range", "128.0", "通背拳距离（-1 使用 tank_swing_range）", CVAR_FLAGS, true, -1.0);
    g_cvBackFistAllowMaxSpd = CreateConVar("ai_tank3_back_fist_max_spd", "50.0", "通背拳允许的最大移动速度（超过禁用）", CVAR_FLAGS, true, -1.0);
    g_cvPunchLockVision   = CreateConVar("ai_tank3_punch_lock_vision", "1", "挥拳时视角锁定目标", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvJumpRock          = CreateConVar("ai_tank3_jump_rock", "1", "扔石头起手时允许“跳砖”", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFistWindow    = CreateConVar("ai_tank3_back_fist_window", "3.0", "通背拳窗口（秒），Tank 爪击命中后开启/刷新", CVAR_FLAGS, true, 0.0);

    // 反头顶卡
    g_cvHeadBlockEnable        = CreateConVar("ai_tank3_head_block_enable", "1", "是否启用 Tank 反头顶卡逻辑", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvHeadBlockTime          = CreateConVar("ai_tank3_head_block_time", "2.0", "Tank 位于目标脚下的持续时间阈值（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockVertical      = CreateConVar("ai_tank3_head_block_vertical", "80.0", "触发头顶卡判定需要的垂直距离（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockHorizontal    = CreateConVar("ai_tank3_head_block_horizontal", "65.0", "触发头顶卡判定的水平距离上限（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockIgnoreTime    = CreateConVar("ai_tank3_head_block_ignore_time", "10.0", "判定恶意卡位后屏蔽该生还者的时间（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockSwitchCooldown= CreateConVar("ai_tank3_head_block_switch_cooldown", "0.75", "头顶卡目标被屏蔽后，强制换目标命令的最小间隔（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockTime = CreateConVar("ai_tank3_head_block_force_rock_time", "20.0", "除卡位者外其他生还都倒地时，强制投石保持的最长时间（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockRange= CreateConVar("ai_tank3_head_block_force_rock_range", "250.0", "触发强制投石时 Tank 需要与卡位者拉开的最小水平距离（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseHoriz = CreateConVar("ai_tank3_head_block_force_rock_release_h", "400", "强制投石期间卡位者离开多远（水平距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseVert  = CreateConVar("ai_tank3_head_block_force_rock_release_v", "250", "强制投石期间卡位者离开多远（垂直距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);

    // 梯子附近仅让出移动/投石控制；目标卡住恢复仍需运行
    g_cvLadderNearbyDisable = CreateConVar("ai_tank3_ladder_nearby_disable", "1", "Tank 在梯子附近时暂停 ai_tank3 移动和投石处理", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvLadderNearbyRadius = CreateConVar("ai_tank3_ladder_nearby_radius", "180.0", "Tank 距离梯子多近时暂停 ai_tank3 移动和投石处理", CVAR_FLAGS, true, 0.0);
    g_cvLadderNearbyCacheTime = CreateConVar("ai_tank3_ladder_nearby_cache", "0.20", "梯子附近检测缓存时间（秒）", CVAR_FLAGS, true, 0.0);

    // 日志
    g_cvPluginName = CreateConVar("ai_tank3_plugin_name", "ai_tank3");
    char cvName[64];
    g_cvPluginName.GetString(cvName, sizeof(cvName));
    FormatEx(cvName, sizeof(cvName), "%s_log_level", cvName);
    g_cvLogLevel = CreateConVar(cvName, "32", "日志级别: 1=关,2=控制台,4=log,8=chat,16=srv,32=err", CVAR_FLAGS);

    // 事件
    HookEvent("round_start", evtRoundStart);
    HookEvent("round_end",   evtRoundEnd);
    HookEvent("player_hurt", evtPlayerHurt, EventHookMode_Post); // 命中刷新通背拳窗口

    // 日志对象
    log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);

    // 初始化动画活动映射
    initAnimMap();
    g_hNearbyLadderList = new ArrayList();
    for (int client = 1; client <= MaxClients; client++)
        g_TankPathSnapshots[client] = new ArrayList(sizeof(PathSegment));

    // 迟加载：给已在服玩家挂钩
    if (g_bLateLoad)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidClient(i)) continue;
            OnClientPutInServer(i);
        }
    }
}

// ===== 动态链接符 =====
public void OnAllPluginsLoaded()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(path))
        SetFailState("Missing required gamedata file: %s", path);

    Handle hGamedata = LoadGameConfigFile(GAMEDATA);
    if (!hGamedata)
        SetFailState("Failed to load %s gamedata.", GAMEDATA);

    // CTankClaw::SweepFist(start,end)
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(hGamedata, SDKConf_Signature, "CTankClaw::SweepFist");
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkTankClawSweepFist = EndPrepSDKCall();
    if (!g_hSdkTankClawSweepFist)
        SetFailState("Failed to find signature for CTankClaw::SweepFist.");

    delete hGamedata;
    if (!SetAnneNextBotPathConsumer(true))
        SetFailState("ai_tank3 requires anne_nextbot path snapshots.");
}

bool SetAnneNextBotPathConsumer(bool enabled)
{
    if (!LibraryExists(ANNE_NEXTBOT_LIBRARY)
        || GetFeatureStatus(FeatureType_Native, "AnneNextBot_IsActive") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "AnneNextBot_SetPathConsumer") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSnapshotInfo") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSegment") != FeatureStatus_Available
        || !AnneNextBot_IsActive())
        return false;

    return AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Tank, enabled);
}

public void AnneNextBot_OnTankPathSnapshotUpdated(int client)
{
    if (!IsValidInfected(client) || !IsFakeClient(client) || !IsPlayerAlive(client) || IsInGhostState(client))
        return;
    if (GetInfectedClass(client) != ZC_TANK || IsClientIncapped(client))
        return;

    if (!captureTankPathSnapshot(client))
        clearCachedTankPath(client);
}

// ===== 读取/监听 CVar =====
public void OnConfigsExecuted()
{
    static bool swingRangeHooked = false;

    cvTankSwingRange  = FindConVar("tank_swing_range");
    g_fTankSwingRange = (!cvTankSwingRange) ? DEFAULT_SWING_RANGE : cvTankSwingRange.FloatValue;

    // FIX: 只有找到 cvar 才能挂 ChangeHook（原版写反了）；且每次换图只挂一次，避免钩子累积
    if (cvTankSwingRange && !swingRangeHooked)
    {
        cvTankSwingRange.AddChangeHook(changeHookTankSwingRange);
        swingRangeHooked = true;
    }
}

void changeHookTankSwingRange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_fTankSwingRange = convar.FloatValue;
    log.debugAll("tank_swing_range changed to %d", convar.IntValue);
}

// ===== 结束回收 =====
public void OnPluginEnd()
{
    SetAnneNextBotPathConsumer(false);
    for (int client = 1; client <= MaxClients; client++)
        delete g_TankPathSnapshots[client];
    delete log;
    delete g_hThrowAnimMap;
    delete g_hNearbyLadderList;
}

// ===== 事件 =====
void evtRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_AiTanks[i].backFistExpire = 0.0;
        g_AiTanks[i].headBlockStart = 0.0;
        g_AiTanks[i].lastHeadBlockTargetSwitch = 0.0;
        g_AiTanks[i].forcedTarget = -1;
        g_AiTanks[i].forcedTargetUntil = 0.0;
        g_AiTanks[i].forceRockUntil = 0.0;
        g_AiTanks[i].forceRockTarget = -1;
        g_AiTanks[i].lastLookAheadTime = 0.0;
        clearCachedTankPath(i);
        g_AiTanks[i].bhopType = TankBhopType_None;
        for (int survivor = 1; survivor <= MaxClients; survivor++)
            g_fHeadBlockIgnoreUntil[i][survivor] = 0.0;
        g_fLastLadderNearbyCheck[i] = 0.0;
        g_bLastLadderNearby[i] = false;
    }
}

void evtRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_AiTanks[i].backFistExpire = 0.0;
        g_AiTanks[i].headBlockStart = 0.0;
        g_AiTanks[i].lastHeadBlockTargetSwitch = 0.0;
        g_AiTanks[i].forcedTarget = -1;
        g_AiTanks[i].forcedTargetUntil = 0.0;
        g_AiTanks[i].forceRockUntil = 0.0;
        g_AiTanks[i].forceRockTarget = -1;
        g_AiTanks[i].lastLookAheadTime = 0.0;
        clearCachedTankPath(i);
        g_AiTanks[i].bhopType = TankBhopType_None;
        for (int survivor = 1; survivor <= MaxClients; survivor++)
            g_fHeadBlockIgnoreUntil[i][survivor] = 0.0;
        g_fLastLadderNearbyCheck[i] = 0.0;
        g_bLastLadderNearby[i] = false;
    }
}

// ===== 动画活动映射 =====
stock void initAnimMap()
{
    if (!g_hThrowAnimMap) g_hThrowAnimMap = new StringMap();

    // 投石动画（活动名）
    g_hThrowAnimMap.SetValue("ACT_SIGNAL2", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL3", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL_ADVANCE", true);
}

// ===== 玩家指令帧 =====
public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3])
{
    if (!g_cvEnable.BoolValue || !isAiTank(client))
        return Plugin_Continue;

    // 只有最终返回 Plugin_Changed 时按键修改才会生效，各子逻辑的结果必须聚合后返回
    Action result = Plugin_Continue;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    bool nearLadder = isTankNearLadder(client, pos);
    if (!nearLadder && handleForceRock(client, buttons, pos) == Plugin_Changed)
        result = Plugin_Changed;

    int target = GetClientOfUserId(g_AiTanks[client].target);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
    {
        if (nearLadder)
            resetTankMovementOverrides(client);
        return result;
    }

    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    float dist = GetVectorDistance(pos, targetPos);

    bool targetIgnored = isSurvivorIgnored(client, target);
    if (!targetIgnored)
    {
        if (handleHeadBlock(client, target, pos, targetPos))
        {
            if (!trySwitchHeadBlockTarget(client, target, false))
                commandTankAttackTarget(client, target, "refreshing route to overhead target");
            resetTankMovementOverrides(client);
            return result;
        }
    }
    else
    {
        g_AiTanks[client].headBlockStart = 0.0;
        trySwitchHeadBlockTarget(client, target, false);
        if (nearLadder)
            resetTankMovementOverrides(client);
        return result;
    }

    if (nearLadder)
    {
        resetTankMovementOverrides(client);
        return result;
    }

    // 挥拳锁视角
    punchLockVision(client, target, pos, targetPos);

    // 限制投石距离
    if (checkEnableThrow(client, buttons, dist) == Plugin_Changed)
        result = Plugin_Changed;

    // 连跳逻辑
    if (checkEnableBhop(client, target, buttons, pos, targetPos, dist) == Plugin_Changed)
        result = Plugin_Changed;

    return result;
}

bool isSurvivorIgnored(int tank, int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return false;
    if (tank < 1 || tank > MaxClients)
        return false;
    if (!IsValidSurvivor(survivor))
        return false;
    return g_fHeadBlockIgnoreUntil[tank][survivor] > GetEngineTime();
}

bool isTankNearLadder(int client, const float pos[3])
{
    if (!g_cvLadderNearbyDisable.BoolValue)
        return false;

    float now = GetEngineTime();
    float cacheTime = g_cvLadderNearbyCacheTime.FloatValue;
    if (cacheTime <= 0.0)
        cacheTime = LADDER_NEARBY_CACHE_DEFAULT;

    if ((now - g_fLastLadderNearbyCheck[client]) < cacheTime)
        return g_bLastLadderNearby[client];

    g_fLastLadderNearbyCheck[client] = now;
    g_bLastLadderNearby[client] = findNearbyLadderEntity(pos, g_cvLadderNearbyRadius.FloatValue) ||
        currentNavAreaHasLadder(pos);

    return g_bLastLadderNearby[client];
}

bool findNearbyLadderEntity(const float pos[3], float radius)
{
    if (radius <= 0.0)
        return false;

    if (GetFeatureStatus(FeatureType_Native, "L4D_FindEntityByClassnameNearest") == FeatureStatus_Available)
    {
        float searchPos[3];
        searchPos = pos;

        if (L4D_FindEntityByClassnameNearest("func_simpleladder", searchPos, radius) != INVALID_ENT_REFERENCE)
            return true;
        if (L4D_FindEntityByClassnameNearest("func_ladder", searchPos, radius) != INVALID_ENT_REFERENCE)
            return true;
    }

    return findNearbyLadderEntityFallback(pos, radius);
}

bool findNearbyLadderEntityFallback(const float pos[3], float radius)
{
    int entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "func_simpleladder")) != INVALID_ENT_REFERENCE)
    {
        if (isEntityNearPos2D(entity, pos, radius))
            return true;
    }

    entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "func_ladder")) != INVALID_ENT_REFERENCE)
    {
        if (isEntityNearPos2D(entity, pos, radius))
            return true;
    }

    return false;
}

bool currentNavAreaHasLadder(const float pos[3])
{
    if (GetFeatureStatus(FeatureType_Native, "L4D_NavArea_GetLadder") != FeatureStatus_Available)
        return false;

    Address area = L4D_GetNearestNavArea(pos, g_cvLadderNearbyRadius.FloatValue, true, false, false, TEAM_INFECTED);
    if (area == Address_Null)
        return false;

    if (g_hNearbyLadderList == null)
        g_hNearbyLadderList = new ArrayList();

    g_hNearbyLadderList.Clear();
    return L4D_NavArea_GetLadder(area, g_hNearbyLadderList) > 0;
}

bool isEntityNearPos2D(int entity, const float pos[3], float radius)
{
    if (!IsValidEntity(entity))
        return false;

    float entPos[3], mins[3], maxs[3], center[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", entPos);
    GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
    GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);

    center[0] = entPos[0] + (mins[0] + maxs[0]) * 0.5;
    center[1] = entPos[1] + (mins[1] + maxs[1]) * 0.5;
    center[2] = entPos[2] + (mins[2] + maxs[2]) * 0.5;

    return getVectorDistance2D(pos, center) <= radius;
}

void resetTankMovementOverrides(int client)
{
    g_AiTanks[client].airCorrGoal = NULL_VECTOR;
    g_AiTanks[client].bhopType = TankBhopType_None;
    g_AiTanks[client].lastLookAheadTime = 0.0;
    g_AiTanks[client].lastAirVecModifyTime = 0.0;
    AIPathMovement_Reset(client);
}

static bool isClientDownState(int client)
{
    return IsClientIncapped(client) || IsClientHanging(client);
}

bool handleHeadBlock(int tank, int target, const float tankPos[3], const float targetPos[3])
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;
    if (isClientDownState(target))
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return false;
    }

    float verticalDiff = targetPos[2] - tankPos[2];
    if (verticalDiff < g_cvHeadBlockVertical.FloatValue)
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return false;
    }

    float dx = targetPos[0] - tankPos[0];
    float dy = targetPos[1] - tankPos[1];
    float horizontalDiff = SquareRoot(dx * dx + dy * dy);
    if (horizontalDiff > g_cvHeadBlockHorizontal.FloatValue)
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return false;
    }

    if (GetEntityMoveType(tank) == MOVETYPE_LADDER)
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return false;
    }

    float now = GetEngineTime();
    if (g_AiTanks[tank].headBlockStart <= 0.0)
    {
        g_AiTanks[tank].headBlockStart = now;
        g_AiTanks[tank].headBlockOrigin = tankPos;
        return false;
    }

    if (GetVectorDistance(tankPos, g_AiTanks[tank].headBlockOrigin) >= HEAD_BLOCK_PROGRESS_DIST)
    {
        g_AiTanks[tank].headBlockStart = now;
        g_AiTanks[tank].headBlockOrigin = tankPos;
        return false;
    }

    if ((now - g_AiTanks[tank].headBlockStart) < g_cvHeadBlockTime.FloatValue)
        return false;

    g_AiTanks[tank].headBlockStart = 0.0;
    g_fHeadBlockIgnoreUntil[tank][target] = now + g_cvHeadBlockIgnoreTime.FloatValue;
    if (log != null)
        log.debugAll("%N flagged %N for overhead path stall (v=%.1f h=%.1f)", tank, target, verticalDiff, horizontalDiff);
    return true;
}

Action handleForceRock(int tank, int& buttons, const float tankPos[3])
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return Plugin_Continue;

    float now = GetEngineTime();
    if (g_AiTanks[tank].forceRockUntil <= now)
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        return Plugin_Continue;
    }

    int rockTarget = GetClientOfUserId(g_AiTanks[tank].forceRockTarget);
    if (!IsValidSurvivor(rockTarget) || !IsPlayerAlive(rockTarget))
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        return Plugin_Continue;
    }

    float blockedPos[3];
    GetClientAbsOrigin(rockTarget, blockedPos);
    float dx = blockedPos[0] - tankPos[0];
    float dy = blockedPos[1] - tankPos[1];
    float horizontal = SquareRoot(dx * dx + dy * dy);
    float vertical = FloatAbs(blockedPos[2] - tankPos[2]);

    float releaseHoriz = g_cvHeadBlockForceRockReleaseHoriz.FloatValue;
    float releaseVert  = g_cvHeadBlockForceRockReleaseVert.FloatValue;
    bool overHoriz = (releaseHoriz > 0.0 && horizontal > releaseHoriz);
    bool overVert  = (releaseVert > 0.0 && vertical  > releaseVert);
    if (overHoriz || overVert)
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        return Plugin_Continue;
    }

    float needDistance = g_cvHeadBlockForceRockRange.FloatValue;
    if (horizontal < needDistance)
        return Plugin_Continue;

    bool visible = clientIsVisibleToClient(tank, rockTarget);
    if (!visible)
    {
        float eyeTarget[3];
        GetClientEyePosition(rockTarget, eyeTarget);
        visible = L4D2_IsVisibleToPlayer(tank, TEAM_INFECTED, 0, 0, eyeTarget);
    }
    if (!visible)
        return Plugin_Continue;

    buttons |= IN_ATTACK2;
    g_AiTanks[tank].forceRockUntil = 0.0;
    g_AiTanks[tank].forceRockTarget = -1;
    return Plugin_Changed;
}

int findAlternativeVictim(int tank, int ignoreTarget, bool &allOthersDown, int &nearestDown)
{
    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);

    int bestStanding = -1;
    float bestStandingDist = 999999.0;
    nearestDown = -1;
    float bestDownDist = 999999.0;
    allOthersDown = true;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;
        if (i == ignoreTarget)
            continue;
        if (isSurvivorIgnored(tank, i))
            continue;

        bool down = isClientDownState(i);
        if (!down)
            allOthersDown = false;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(tankPos, pos);

        if (!down)
        {
            if (L4D_IsPlayerPinned(i))
                continue;

            if (dist < bestStandingDist)
            {
                bestStandingDist = dist;
                bestStanding = i;
            }
        }
        else
        {
            if (IsClientHanging(i))
                continue;

            if (dist < bestDownDist)
            {
                bestDownDist = dist;
                nearestDown = i;
            }
        }
    }

    if (bestStanding != -1)
        return bestStanding;
    if (allOthersDown && nearestDown != -1)
        return nearestDown;

    allOthersDown = false;
    return -1;
}

bool trySwitchHeadBlockTarget(int tank, int blockedTarget, bool updateVictimOnly)
{
    if (!g_cvHeadBlockEnable.BoolValue || !isAiTank(tank) || !IsValidSurvivor(blockedTarget))
        return false;
    if (!isSurvivorIgnored(tank, blockedTarget))
        return false;

    bool allOthersDown = false;
    int nearestDown = -1;
    int alternative = findAlternativeVictim(tank, blockedTarget, allOthersDown, nearestDown);
    if (alternative <= 0)
        return false;

    float now = GetEngineTime();
    int chaseTarget = alternative;
    if (allOthersDown)
    {
        chaseTarget = (nearestDown > 0) ? nearestDown : blockedTarget;

        int blockedUserId = GetClientUserId(blockedTarget);
        if (blockedUserId > 0)
        {
            g_AiTanks[tank].forceRockTarget = blockedUserId;
            g_AiTanks[tank].forceRockUntil = now + g_cvHeadBlockForceRockTime.FloatValue;
        }
    }
    else
    {
        g_AiTanks[tank].forceRockTarget = -1;
        g_AiTanks[tank].forceRockUntil = 0.0;
    }

    int chaseUserId = GetClientUserId(chaseTarget);
    if (chaseUserId <= 0)
        return false;

    g_AiTanks[tank].forcedTarget = chaseUserId;
    g_AiTanks[tank].forcedTargetUntil = g_fHeadBlockIgnoreUntil[tank][blockedTarget];
    g_AiTanks[tank].target = chaseUserId;

    if (!updateVictimOnly)
        commandTankAttackTarget(tank, chaseTarget, "switching from overhead target");

    if (log != null)
        log.debugAll("%N switched head-block target from %N to %N", tank, blockedTarget, chaseTarget);

    return true;
}

void clearTankTargetLock(int tank)
{
    if (tank < 1 || tank > MaxClients)
        return;

    g_AiTanks[tank].forcedTarget = -1;
    g_AiTanks[tank].forcedTargetUntil = 0.0;
}

bool canKeepDownTargetForForceRock(int tank, int target, float now)
{
    if (!isClientDownState(target) || IsClientHanging(target) || g_AiTanks[tank].forceRockUntil <= now)
        return false;

    int blockedTarget = GetClientOfUserId(g_AiTanks[tank].forceRockTarget);
    if (!IsValidSurvivor(blockedTarget) || !IsPlayerAlive(blockedTarget))
        return false;

    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || survivor == blockedTarget)
            continue;
        if (!isClientDownState(survivor))
            return false;
    }

    return true;
}

bool getTankForcedTarget(int tank, int &target)
{
    target = -1;
    if (!g_cvHeadBlockEnable.BoolValue || !isAiTank(tank))
    {
        clearTankTargetLock(tank);
        return false;
    }

    float now = GetEngineTime();
    if (g_AiTanks[tank].forcedTargetUntil <= now)
    {
        clearTankTargetLock(tank);
        return false;
    }

    target = GetClientOfUserId(g_AiTanks[tank].forcedTarget);
    bool keepDownTarget = IsValidSurvivor(target) && canKeepDownTargetForForceRock(tank, target, now);
    if (IsValidSurvivor(target) && g_AiTanks[tank].forceRockUntil > now &&
        isClientDownState(target) && !keepDownTarget)
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
    }

    if (!IsValidSurvivor(target) || !IsPlayerAlive(target) || IsClientHanging(target) ||
        L4D_IsPlayerPinned(target) || (isClientDownState(target) && !keepDownTarget) ||
        isSurvivorIgnored(tank, target))
    {
        clearTankTargetLock(tank);
        target = -1;
        return false;
    }

    return true;
}

bool commandTankAttackTarget(int tank, int target, const char[] reason)
{
    if (!isAiTank(tank) || !IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;

    float now = GetEngineTime();
    float cooldown = g_cvHeadBlockSwitchCooldown.FloatValue;
    if (cooldown > 0.0 && now - g_AiTanks[tank].lastHeadBlockTargetSwitch < cooldown)
        return false;

    int tankUserId = GetClientUserId(tank);
    int targetUserId = GetClientUserId(target);
    if (tankUserId <= 0 || targetUserId <= 0)
        return false;

    Logic_RunScript(COMMANDABOT_RESET, tankUserId);
    Logic_RunScript(COMMANDABOT_ATTACK, tankUserId, targetUserId);
    g_AiTanks[tank].target = targetUserId;
    g_AiTanks[tank].lastHeadBlockTargetSwitch = now;

    if (log != null)
        log.debugAll("%N reset path and attacked %N: %s", tank, target, reason);
    return true;
}

// 确保目标缓存一致并处理反卡逻辑
public Action L4D2_OnChooseVictim(int client, int &curTarget)
{
    if (!isAiTank(client))
        return Plugin_Continue;

    int forcedTarget;
    if (getTankForcedTarget(client, forcedTarget))
    {
        g_AiTanks[client].target = GetClientUserId(forcedTarget);
        if (curTarget != forcedTarget)
        {
            curTarget = forcedTarget;
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }

    if (!IsValidSurvivor(curTarget))
        return Plugin_Continue;

    float now = GetEngineTime();

    int blockedClient = curTarget;

    if (isSurvivorIgnored(client, blockedClient) && trySwitchHeadBlockTarget(client, blockedClient, true))
    {
        int switchedTarget;
        if (getTankForcedTarget(client, switchedTarget) && switchedTarget != curTarget)
        {
            curTarget = switchedTarget;
            return Plugin_Changed;
        }
    }

    if (g_AiTanks[client].forceRockUntil > 0.0 && g_AiTanks[client].forceRockUntil <= now)
    {
        g_AiTanks[client].forceRockUntil = 0.0;
        g_AiTanks[client].forceRockTarget = -1;
    }

    if (!isClientDownState(curTarget))
    {
        g_AiTanks[client].forceRockTarget = -1;
        g_AiTanks[client].forceRockUntil = 0.0;
    }

    int cachedTarget = GetClientOfUserId(g_AiTanks[client].target);
    if (!IsValidClient(cachedTarget) || cachedTarget != curTarget)
        g_AiTanks[client].target = GetClientUserId(curTarget);

    return Plugin_Continue;
}

public Action L4D_OnTargetOverride(int attacker, int &victim, int order)
{
    if (!isAiTank(attacker))
        return Plugin_Continue;

    int forcedTarget;
    if (getTankForcedTarget(attacker, forcedTarget))
    {
        if (victim != forcedTarget)
        {
            victim = forcedTarget;
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }

    if (!IsValidSurvivor(victim))
        return Plugin_Continue;

    if (trySwitchHeadBlockTarget(attacker, victim, true))
    {
        int switchedTarget;
        if (getTankForcedTarget(attacker, switchedTarget) && switchedTarget != victim)
        {
            victim = switchedTarget;
            return Plugin_Changed;
        }
    }

    return Plugin_Continue;
}

// ===== 通背拳（背后扫击） =====
stock bool IsBackFistAllowedNow(int tank)
{
    if (!g_cvBackFist.BoolValue)                return false;
    if (!isAiTank(tank))                        return false;
    if (!IsClientOnGround(tank))                return false;                    // 必须在地上
    if (GetEntityMoveType(tank) == MOVETYPE_LADDER) return false;               // 梯子上不允许
    float now = GetEngineTime();
    return (g_AiTanks[tank].backFistExpire > 0.0 && now <= g_AiTanks[tank].backFistExpire);
}

public void L4D_TankClaw_DoSwing_Post(int tank, int claw)
{
    if (!g_cvBackFist.BoolValue || !isAiTank(tank))
        return;

    // 速度过快不允许通背拳
    float vAbsVelVec[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    float speed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
    if (speed > g_cvBackFistAllowMaxSpd.FloatValue)
        return;

    if (!IsBackFistAllowedNow(tank))
        return;

    float pos[3], targetPos[3];
    float fistRange = (g_cvBackFistRange.IntValue >= 0) ? g_cvBackFistRange.FloatValue : g_fTankSwingRange;

    GetClientEyePosition(tank, pos);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientEyePosition(i, targetPos);
        if (GetVectorDistance(pos, targetPos) > fistRange)
            continue;
        if (!clientIsVisibleToClient(tank, i))
            continue;

        // 用 TankClaw 扫描碰撞
        SDKCall(g_hSdkTankClawSweepFist, claw, targetPos, targetPos);
    }
}

// 爪击命中 -> 刷新通背拳窗口
void evtPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidSurvivor(victim) || !IsValidClient(attacker) || !isAiTank(attacker))
        return;

    char wep[64];
    GetEventString(event, "weapon", wep, sizeof(wep));
    bool isClaw = StrEqual(wep, "tank_claw", false) || StrEqual(wep, "tank", false);
    if (!isClaw)
    {
        int claw = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
        if (claw > 0 && IsValidEdict(claw))
        {
            char cls[64];
            GetEntityClassname(claw, cls, sizeof(cls));
            if (StrEqual(cls, "weapon_tank_claw", false))
                isClaw = true;
        }
    }
    if (!isClaw) return;

    g_AiTanks[attacker].backFistExpire = GetEngineTime() + g_cvBackFistWindow.FloatValue;
}

// 挥拳锁视角
Action punchLockVision(int client, int target, const float pos[3], const float targetPos[3])
{
    if (!g_cvPunchLockVision.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
        return Plugin_Continue;

    int claw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!claw || !IsValidEdict(claw)) return Plugin_Continue;
    if (!HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack"))
        return Plugin_Continue;

    // m_flNextPrimaryAttack 属于 GameTime 时钟域，统一用 GetGameTime 比较，避免与 EngineTime 漂移
    float nextAtk = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
    if (g_AiTanks[client].nextAttackTime < GetGameTime() && nextAtk > GetGameTime())
    {
        float vLookAt[3], vDir[3];
        MakeVectorFromPoints(pos, targetPos, vLookAt);
        GetVectorAngles(vLookAt, vDir);
        TeleportEntity(client, NULL_VECTOR, vDir, NULL_VECTOR);
    }
    g_AiTanks[client].nextAttackTime = nextAtk;
    return Plugin_Continue;
}

// ===== 连跳 =====
Action checkEnableBhop(int client, int target, int& buttons, const float pos[3], const float targetPos[3], float dist)
{
    if (!g_cvTankBhop.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
        return Plugin_Continue;

    if (L4D_IsPlayerStaggering(client))
        return Plugin_Continue;

    // 梯子/水中不连跳
    if (GetEntityMoveType(client) == MOVETYPE_LADDER || GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
        return Plugin_Continue;

    float velVec[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    float vel = SquareRoot(Pow(velVec[0], 2.0) + Pow(velVec[1], 2.0));
    if (vel < g_cvBhopMinSpeed.FloatValue)
        return Plugin_Continue;

    if (dist < g_cvBhopMinDist.FloatValue || dist > g_cvBhopMaxDist.FloatValue)
        return Plugin_Continue;

    float vAbsVelVec[3], vTargetAbsVelVec[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

    // 是否可见
    float l_targetPos[3]; l_targetPos = targetPos;
    bool visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, 0, 0, l_targetPos);

    bool useCurrentBhop = visible || dist <= g_cvBhopPathFallbackDist.FloatValue;

    if (IsClientOnGround(client))
    {
        if (!g_cvBhopNoVision.BoolValue && !visible)
            return Plugin_Continue;

        // 上次起跳安全检查因地形失败且仍在冷却期内时跳过尝试，避免受阻时每帧重复整套 trace
        if (AIPathMovement_IsRouteCheckThrottled(client))
            return Plugin_Continue;

        if (!useCurrentBhop)
        {
            bool pathHandled = false;
            Action pathBhop = tryPathGroundBhop(client, buttons, pos, vel, visible, pathHandled);
            if (pathHandled)
                return pathBhop;
        }

        if (!nextTickPosCheck(client, visible))
        {
            AIPathMovement_MarkRouteCheckFailure(client);
            return Plugin_Continue;
        }

        float vPredict[3], vDir[3], vFwd[3], vRight[3];
        g_AiTanks[client].bhopType = TankBhopType_Normal;
        g_AiTanks[client].airCorrGoal = NULL_VECTOR;

        if (!visible)
        {
            NormalizeVector(velVec, vFwd);
        }
        else
        {
            // 预测目标下一帧位置
            AddVectors(targetPos, vTargetAbsVelVec, vPredict);
            MakeVectorFromPoints(pos, vPredict, vDir);
            vDir[2] = 0.0;
            NormalizeVector(vDir, vDir);
            vFwd = vDir;
        }

        buttons |= IN_DUCK;
        buttons |= IN_JUMP;

        bool fwdOnly  = ((buttons & IN_FORWARD) && !(buttons & IN_BACK));
        bool backOnly = ((buttons & IN_BACK) && !(buttons & IN_FORWARD));
        bool leftOnly = ((buttons & IN_LEFT) && !(buttons & IN_RIGHT));
        bool rightOnly= ((buttons & IN_RIGHT) && !(buttons & IN_LEFT));

        if (fwdOnly)
        {
            NormalizeVector(vFwd, vFwd);
            ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
            AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
        }
        else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0))
        {
            vFwd[0] = velVec[0]; vFwd[1] = velVec[1]; vFwd[2] = 0.0;
            NormalizeVector(vFwd, vFwd);
            ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
            AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
        }
        else
        {
            float baseFwd[3];
            if (fwdOnly)
            {
                baseFwd[0] = vFwd[0]; baseFwd[1] = vFwd[1]; baseFwd[2] = 0.0;
            }
            else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0))
            {
                baseFwd[0] = velVec[0]; baseFwd[1] = velVec[1]; baseFwd[2] = 0.0;
            }
            else
            {
                baseFwd[0] = vFwd[0]; baseFwd[1] = vFwd[1]; baseFwd[2] = 0.0;
            }

            GetVectorCrossProduct({0.0, 0.0, 1.0}, baseFwd, vRight);
            NormalizeVector(vRight, vRight);
            if (rightOnly ^ leftOnly)
            {
                vRight[2] = 0.0;
                ScaleVector(vRight, g_cvBhopImpulse.FloatValue * (rightOnly ? 1.0 : -1.0));
                AddVectors(vAbsVelVec, vRight, vAbsVelVec);
            }
        }

        // 记录起跳水平速度（空中修正用）
        g_AiTanks[client].lastHopSpeed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
        AIPathMovement_BeginPathHop(client, targetPos, g_AiTanks[client].lastHopSpeed);
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
        return Plugin_Changed;
    }

    // 限速（空中）
    if (vel > g_cvBhopMaxSpeed.FloatValue)
    {
        NormalizeVector(velVec, velVec);
        ScaleVector(velVec, g_cvBhopMaxSpeed.FloatValue);
        SetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    }

    if (!useCurrentBhop && g_AiTanks[client].bhopType == TankBhopType_Path)
    {
        Action pathAir = tryPathAirCorrection(client, pos, vAbsVelVec, vel);
        if (pathAir != Plugin_Continue)
            return pathAir;
    }

    // 普通连跳也使用共享的渐进式空中修正，目标方向仍由 Tank 自己决定。
    float vDir2[3];
    MakeVectorFromPoints(pos, targetPos, vDir2);
    vDir2[2] = 0.0;

    float dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
    float dz = targetPos[2] - pos[2];
    float pitch = dx > 0.0 ? RadToDeg(ArcTangent(dz / dx)) : 90.0;
    if (dz > (JUMP_HEIGHT + TANK_HEIGHT + g_fTankSwingRange) && pitch > 45.0)
        return Plugin_Continue;

    bool notPressBack = !(buttons & IN_BACK);
    float correctedVelocity[3];
    if (visible && notPressBack && AIPathMovement_ComputeAirCorrectionToward(
        client,
        vAbsVelVec,
        vDir2,
        dist,
        PATH_GOAL_TOLERANCE_DIST,
        g_cvAirVecModifyDegree.FloatValue,
        g_cvAirVecModifyMaxDegree.FloatValue,
        0.3,
        g_cvAirVecModifyInterval.FloatValue,
        0.12,
        correctedVelocity
    ))
    {
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, correctedVelocity);
        g_AiTanks[client].lastAirVecModifyTime = GetEngineTime();
    }
    return Plugin_Changed;
}

Action tryPathGroundBhop(int client, int& buttons, const float pos[3], float speed, bool visible, bool& handled)
{
    handled = false;

    if (!hasValidTankPath(client))
        return Plugin_Continue;

    handled = true;

    float lookAheadPos[3];
    float maxEstimateDist = speed * getTankJumpAirTime();
    if (maxEstimateDist < PATH_LOOKAHEAD_MIN_DIST)
        maxEstimateDist = PATH_LOOKAHEAD_MIN_DIST;

    if (!getTankLookAheadGoalPos(client, pos, maxEstimateDist, lookAheadPos, g_cvPathLookAheadMaxDepth.IntValue))
    {
        // 前视首节点被遮挡属于地形失败, 冷却期内不再重试
        AIPathMovement_MarkRouteCheckFailure(client);
        return Plugin_Continue;
    }

    float vFwd[3];
    MakeVectorFromPoints(pos, lookAheadPos, vFwd);
    vFwd[2] = 0.0;
    NormalizeVector(vFwd, vFwd);
    ScaleVector(vFwd, speed + g_cvBhopImpulse.FloatValue);

    if (!AIPathMovement_IsJumpRouteSafe(
        client,
        vFwd,
        getTankJumpAirTime(),
        JUMP_HEIGHT,
        visible,
        g_cvBhopNoVisionMaxAng.FloatValue
    ))
    {
        AIPathMovement_MarkRouteCheckFailure(client);
        return Plugin_Continue;
    }

    float vecLen = getVectorLength2D(vFwd);
    if (vecLen > g_cvBhopMaxSpeed.FloatValue)
    {
        float scale = g_cvBhopMaxSpeed.FloatValue / vecLen;
        ScaleVector(vFwd, scale);
    }

    buttons |= IN_DUCK;
    buttons |= IN_JUMP;

    g_AiTanks[client].bhopType = TankBhopType_Path;
    g_AiTanks[client].airCorrGoal = lookAheadPos;
    g_AiTanks[client].lastHopSpeed = getVectorLength2D(vFwd);
    AIPathMovement_BeginPathHop(client, lookAheadPos, g_AiTanks[client].lastHopSpeed);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vFwd);
    return Plugin_Changed;
}

Action tryPathAirCorrection(int client, const float pos[3], const float vAbsVelVec[3], float speed)
{
    #pragma unused pos
    #pragma unused speed

    if (!AIPathMovement_IsPathHopActive(client))
        return Plugin_Continue;

    float correctedVelocity[3];
    if (AIPathMovement_ComputePathAirCorrection(
        client,
        vAbsVelVec,
        PATH_GOAL_TOLERANCE_DIST,
        g_cvAirVecModifyDegree.FloatValue,
        g_cvAirVecModifyMaxDegree.FloatValue,
        0.3,
        g_cvAirVecModifyInterval.FloatValue,
        0.12,
        correctedVelocity
    ))
    {
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, correctedVelocity);
        g_AiTanks[client].lastAirVecModifyTime = GetEngineTime();
    }
    return Plugin_Changed;
}

// 预测下一帧位置是否会撞/坠落
stock bool nextTickPosCheck(int client, bool visible)
{
    if (!isAiTank(client)) return false;

    float velVec[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    return nextTickVelocityCheck(client, velVec, visible);
}

stock bool nextTickVelocityCheck(int client, const float velocity[3], bool visible)
{
    if (!isAiTank(client))
        return false;

    return AIPathMovement_IsJumpRouteSafe(
        client,
        velocity,
        getTankJumpAirTime(),
        JUMP_HEIGHT,
        visible,
        g_cvBhopNoVisionMaxAng.FloatValue
    );
}

void clearTankPathSnapshot(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    if (g_TankPathSnapshots[client] != null)
        g_TankPathSnapshots[client].Clear();
}

void clearCachedTankPath(int client)
{
    clearTankPathSnapshot(client);
    g_AiTanks[client].pathSegment.initData();
    g_AiTanks[client].lastPathSegment.initData();
    g_AiTanks[client].airCorrGoal = NULL_VECTOR;
    AIPathMovement_Reset(client);

    if (g_AiTanks[client].bhopType == TankBhopType_Path)
        g_AiTanks[client].bhopType = TankBhopType_None;
}

bool hasValidTankPath(int client)
{
    if (!isAiTank(client))
        return false;

    ArrayList snapshot = g_TankPathSnapshots[client];
    if (snapshot == null || snapshot.Length < 2)
        return false;

    PathSegment curSegment;
    PathSegment lastSegment;
    curSegment = g_AiTanks[client].pathSegment;
    lastSegment = g_AiTanks[client].lastPathSegment;
    return (
        curSegment.m_pPathSegment != Address_Null &&
        lastSegment.m_pPathSegment != Address_Null &&
        curSegment.m_pPathSegment != lastSegment.m_pPathSegment
    );
}

bool constructPathSegmentFromSnapshot(int client, int sourceIndex, PathSegment segment)
{
    segment.initData();
    if (!AnneNextBot_GetPathSegment(
        client,
        sourceIndex,
        segment.m_pNavArea,
        segment.m_iNavTraverseType,
        segment.m_vecGoalPos,
        segment.m_SegmentType,
        segment.m_vecForward,
        segment.m_flLength,
        segment.m_flDistFromStart
    ))
    {
        return false;
    }

    // 该字段现在只是稳定的非零节点令牌，不再保存原生 PathSegment 指针。
    segment.m_pPathSegment = view_as<Address>(sourceIndex + 1);
    return true;
}

bool captureTankPathSnapshot(int client)
{
    clearTankPathSnapshot(client);

    ArrayList snapshot = g_TankPathSnapshots[client];
    int count, currentIndex;
    bool complete;
    float age;
    if (snapshot == null ||
        !AnneNextBot_GetPathSnapshotInfo(client, count, currentIndex, complete, age) ||
        currentIndex < 0 || currentIndex >= count)
    {
        clearCachedTankPath(client);
        return false;
    }

    PathSegment segment;

    int maxDepth = g_cvPathLookAheadMaxDepth.IntValue;
    if (maxDepth < 1)
        maxDepth = 1;

    // 前两段前瞻循环各自最多推进 maxDepth，因此默认只需复制 2 * maxDepth + 1 个节点。
    int snapshotLimit = (maxDepth >= (MAX_TANK_PATH_SNAPSHOT_SEGMENTS - 1) / 2)
        ? MAX_TANK_PATH_SNAPSHOT_SEGMENTS
        : maxDepth * 2 + 1;

    int endIndex = currentIndex + snapshotLimit;
    if (endIndex > count)
        endIndex = count;
    for (int sourceIndex = currentIndex; sourceIndex < endIndex; sourceIndex++)
    {
        if (!constructPathSegmentFromSnapshot(client, sourceIndex, segment))
            break;
        snapshot.PushArray(segment, sizeof(segment));
    }

    if (snapshot.Length < 1)
    {
        clearCachedTankPath(client);
        return false;
    }

    snapshot.GetArray(0, g_AiTanks[client].pathSegment, sizeof(PathSegment));

    if (!complete || !constructPathSegmentFromSnapshot(client, count - 1, g_AiTanks[client].lastPathSegment))
        g_AiTanks[client].lastPathSegment.initData();

    return true;
}

bool getTankLookAheadGoalPos(int client, const float pos[3], float maxDist, float outPos[3], int maxDepth = 10)
{
    ArrayList snapshot = g_TankPathSnapshots[client];
    if (snapshot == null || snapshot.Length < 1)
        return false;

    int segmentIndex = 0;
    int segmentCount = snapshot.Length;
    PathSegment iterSeg;
    snapshot.GetArray(segmentIndex, iterSeg, sizeof(iterSeg));

    float pos2D[3];
    pos2D = pos;
    pos2D[2] = 0.0;

    for (int i = 0; i < maxDepth; i++)
    {
        if (segmentIndex + 1 >= segmentCount)
            break;

        PathSegment nextSeg;
        snapshot.GetArray(segmentIndex + 1, nextSeg, sizeof(nextSeg));

        float curGoal2D[3], nextGoal2D[3];
        curGoal2D = iterSeg.m_vecGoalPos;
        nextGoal2D = nextSeg.m_vecGoalPos;
        curGoal2D[2] = 0.0;
        nextGoal2D[2] = 0.0;

        float curToNext[3], curToTank[3];
        MakeVectorFromPoints(curGoal2D, nextGoal2D, curToNext);
        MakeVectorFromPoints(curGoal2D, pos2D, curToTank);

        float lenSqr = GetVectorDotProduct(curToNext, curToNext);
        if (lenSqr <= 0.0)
        {
            iterSeg = nextSeg;
            segmentIndex++;
            continue;
        }

        float proj = GetVectorDotProduct(curToNext, curToTank) / lenSqr;
        if (proj >= 1.0)
        {
            iterSeg = nextSeg;
            segmentIndex++;
            continue;
        }
        if (proj >= 0.5)
        {
            iterSeg = nextSeg;
            segmentIndex++;
        }

        break;
    }

    float lastVisPos[3];
    lastVisPos = iterSeg.m_vecGoalPos;

    float start[3];
    GetClientAbsOrigin(client, start);
    start[2] += 36.0;

    int fwdCount = 0;
    for (int i = 0; i < maxDepth; i++)
    {
        float goal[3], end[3];
        goal = iterSeg.m_vecGoalPos;
        end = goal;
        end[2] += 36.0;

        Handle hTrace = TR_TraceHullFilterEx(start, end, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
        bool isHit = TR_DidHit(hTrace);
        delete hTrace;

        if (isHit)
            break;

        lastVisPos = goal;
        fwdCount++;

        float dist2Goal = getVectorDistance2D(start, goal);
        if (dist2Goal >= maxDist)
            break;

        if (goal[2] - pos[2] > JUMP_HEIGHT)
            break;

        if (segmentIndex + 1 >= segmentCount)
            break;

        segmentIndex++;
        snapshot.GetArray(segmentIndex, iterSeg, sizeof(iterSeg));
    }

    if (fwdCount < 1)
        return false;

    outPos = lastVisPos;
    return true;
}

float getTankJumpAirTime()
{
    return AIPathMovement_GetJumpAirTime(JUMP_HEIGHT);
}

float getVectorLength2D(const float vec[3])
{
    return SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
}

float getVectorDistance2D(const float vec1[3], const float vec2[3])
{
    return SquareRoot(Pow(vec1[0] - vec2[0], 2.0) + Pow(vec1[1] - vec2[1], 2.0));
}

// ===== 玩家进服：启用动画钩子 & 梯子常驻维护 =====
public void OnClientPutInServer(int client)
{
    g_AiTanks[client].initData();
    AIPathMovement_Reset(client);
    clearTankPathSnapshot(client);
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fHeadBlockIgnoreUntil[client][i] = 0.0;
        g_fHeadBlockIgnoreUntil[i][client] = 0.0;
    }
    // 后置动画钩子：识别投石/翻越等序列变化
    AnimHookEnable(client, INVALID_FUNCTION, tankAnimHookPostCb);
}

public void OnClientDisconnect(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_fHeadBlockIgnoreUntil[client][i] = 0.0;
        g_fHeadBlockIgnoreUntil[i][client] = 0.0;
    }
    g_AiTanks[client].headBlockStart = 0.0;
    g_AiTanks[client].lastHeadBlockTargetSwitch = 0.0;
    clearTankTargetLock(client);
    g_AiTanks[client].forceRockUntil = 0.0;
    g_AiTanks[client].forceRockTarget = -1;
    g_AiTanks[client].lastLookAheadTime = 0.0;
    clearCachedTankPath(client);
    g_AiTanks[client].bhopType = TankBhopType_None;
    g_fLastLadderNearbyCheck[client] = 0.0;
    g_bLastLadderNearby[client] = false;
}

// ===== 动画后置钩子：识别投石序列并触发相应逻辑 =====
Action tankAnimHookPostCb(int tank, int &sequence)
{
    if (!isAiTank(tank))
    {
        AnimHookDisable(tank, tankAnimHookPostCb);
        return Plugin_Continue;
    }

    if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        if (g_cvJumpRock.BoolValue && !g_AiTanks[tank].wasThrowing)
        {
            makeTankJumpRock(tank);
            g_AiTanks[tank].wasThrowing = true;
            CreateTimer(0.5, timerResetThrowingFlagHandler, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    return Plugin_Continue;
}

// 判断序列是否匹配投石动画
bool isMatchedSequence(int sequence, TankSequenceType seqType)
{
    if (sequence < 0) return false;

    char seqName[64];
    if (!AnimGetActivity(sequence, seqName, sizeof(seqName)))
        return false;

    switch (seqType)
    {
        case view_as<TankSequenceType>(tankSequence_Throw):
            return g_hThrowAnimMap.ContainsKey(seqName);
    }
    return false;
}

// ===== 投石：跳砖、距离限制、出手角度 =====
void makeTankJumpRock(int tank)
{
    if (!isAiTank(tank)) return;

    float vAbsVelVec[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    vAbsVelVec[2] += JUMP_SPEED_Z;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
}

Action timerResetThrowingFlagHandler(Handle timer, int userId)
{
    int tank = GetClientOfUserId(userId);
    if (!isAiTank(tank))
        return Plugin_Stop;

    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    if (!isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        g_AiTanks[tank].wasThrowing = false;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

Action checkEnableThrow(int client, int& buttons, float dist)
{
    if (!isAiTank(client)) return Plugin_Continue;

    if ((dist < g_cvThrowMinDist.FloatValue || dist > g_cvThrowMaxDist.FloatValue) && (buttons & IN_ATTACK2))
    {
        buttons &= ~IN_ATTACK2;
        return Plugin_Changed;
    }

    return Plugin_Continue;
}

public Action L4D_TankRock_OnRelease(int tank, int rock, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
    if (!isAiTank(tank)) return Plugin_Continue;
    if (!HasEntProp(rock, Prop_Data, "m_flGravity")) return Plugin_Continue;

    static ConVar cv_ThrowForce, cv_Gravity;
    if (!cv_ThrowForce) cv_ThrowForce = FindConVar("z_tank_throw_force");
    if (!cv_Gravity)    cv_Gravity    = FindConVar("sv_gravity");

    float throwSpeed = (!cv_ThrowForce) ? DEFAULT_THROW_FORCE : cv_ThrowForce.FloatValue;
    float svGravity  = (!cv_Gravity)    ? DEFAULT_SV_GRAVITY  : cv_Gravity.FloatValue;

    int target = GetClientOfUserId(g_AiTanks[tank].target);
    if (!IsValidSurvivor(target)) return Plugin_Continue;

    int newRockTarget = -1;
    if (g_cvRockTargetAdjust.BoolValue)
    {
        static ArrayList targets;
        if (!targets) targets = new ArrayList(2);

        float pos[3], tpos[3];
        GetClientEyePosition(tank, pos);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (tank == i || !IsValidSurvivor(i) || !IsPlayerAlive(i) || IsClientIncapped(i) || isPinnedByHunterOrCharger(i))
                continue;
            if (!clientIsVisibleToClient(tank, i))
                continue;
            GetClientEyePosition(i, tpos);
            targets.Set(targets.Push(GetVectorDistance(pos, tpos)), i, 1);
        }
        if (targets.Length > 0)
        {
            SortADTArray(targets, Sort_Ascending, Sort_Float);
            newRockTarget = targets.Get(0, 1);
        }
        delete targets;
    }

    int aimTarget = IsValidSurvivor(newRockTarget) ? newRockTarget : target;

    // 计算上抬角
    float rockGravityScale = GetEntPropFloat(rock, Prop_Data, "m_flGravity");
    float pitch = calculateThrowAngle(tank, aimTarget, throwSpeed, svGravity * rockGravityScale);
    if (pitch > 90.0 || pitch < -90.0)
        return Plugin_Continue;

    // 预测偏航
    float pos0[3], tpos0[3], pred[3], vTargetAbsVelVec[3], aimAng[3];
    GetClientAbsOrigin(tank, pos0);
    GetClientAbsOrigin(aimTarget, tpos0);
    GetEntPropVector(aimTarget, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

    float dx = SquareRoot(Pow(vecPos[0] - tpos0[0], 2.0) + Pow(vecPos[1] - tpos0[1], 2.0));
    float vx = throwSpeed * Cosine(DegToRad(pitch));
    float t  = dx / vx;

    pred[0] = tpos0[0] + vTargetAbsVelVec[0] * t;
    pred[1] = tpos0[1] + vTargetAbsVelVec[1] * t;
    pred[2] = tpos0[2] + vTargetAbsVelVec[2] * t;

    float yawCenter = ArcTangent2(pred[1] - pos0[1], pred[0] - pos0[0]);
    float yawThrow  = ArcTangent2(pred[1] - vecPos[1], pred[0] - vecPos[0]);
    yawThrow        = RadToDeg(yawThrow - yawCenter);

    MakeVectorFromPoints(pos0, pred, aimAng);
    GetVectorAngles(aimAng, aimAng);
    aimAng[0] = -pitch;
    aimAng[1] += yawThrow;
    if (aimAng[1] > 180.0)  aimAng[1] -= 360.0;
    if (aimAng[1] < -180.0) aimAng[1] += 360.0;
    aimAng[2] = 0.0;

    GetAngleVectors(aimAng, aimAng, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(aimAng, aimAng);
    ScaleVector(aimAng, throwSpeed);
    vecVel = aimAng;

    return Plugin_Changed;
}

// 计算投石出手角度
float calculateThrowAngle(int tank, int target, float vSpeed = 800.0, float g = 320.0)
{
    if (!isAiTank(tank) || !IsValidSurvivor(target))
        return -9999.0;

    float pos[3], tpos[3];
    GetClientAbsOrigin(tank, pos);

    // m_nSequence 是模型序列号而非 Activity 枚举，通过活动名解析出手高度，避免依赖数值巧合
    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    char actName[64];
    if (animSeq >= 0 && AnimGetActivity(animSeq, actName, sizeof(actName)))
    {
        if (StrEqual(actName, "ACT_SIGNAL3")) { pos[2] += THROW_UNDERHEAD_POS_Z; }
        else if (StrEqual(actName, "ACT_SIGNAL2")) { pos[2] += THROW_OVERSHOULDER_POS_Z; }
        else if (StrEqual(actName, "ACT_SIGNAL_ADVANCE")) { pos[2] += THROW_OVERHEAD_POS_Z; }
    }

    GetClientAbsOrigin(target, tpos);
    tpos[2] += PLAYER_CHEST;

    float dx = SquareRoot(Pow(tpos[0] - pos[0], 2.0) + Pow(tpos[1] - pos[1], 2.0));
    float dz = tpos[2] - pos[2];

    float v2 = Pow(vSpeed, 2.0);
    float v4 = Pow(vSpeed, 4.0);
    float delta = v4 - g * (g * dx * dx + 2.0 * dz * v2);
    if (delta < 0.0)
    {
        log.debugAll("%N rock unreachable: dist=%.2f dh=%.2f v=%.2f g=%.2f", tank, dx, dz, vSpeed, g);
        return -9999.0;
    }

    float tanTheta = (v2 - SquareRoot(delta)) / (g * dx); // 取低抛解
    return RadToDeg(ArcTangent(tanTheta));
}
