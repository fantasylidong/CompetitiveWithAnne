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
#undef REQUIRE_PLUGIN
#include <si_target_limit>
#define REQUIRE_PLUGIN
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
#define HEAD_BLOCK_PROGRESS_DIST   32.0   // 高台停滞窗口内移动超过该距离视为仍在正常寻路
#define RIDE_CHECK_CACHE           0.10   // 骑头判定缓存，避免每帧 hull trace
#define RIDE_AABB_SLACK            8.0    // 水平投影重叠的外扩，吸收网络抖动
#define LADDER_LOOK_ALIGN_DEG      8.0    // 爬梯朝向已足够接近时不再改视角
#define FORCE_ROCK_RETREAT_INTERVAL 0.50  // 强制投石撤离命令刷新间隔
#define FORCE_ROCK_RETREAT_MARGIN  48.0   // 撤离目标点越过最小投石距离的余量
#define FORCE_ROCK_MIN_HORIZONTAL  96.0   // 防止配置为 0 后重新尝试无效的原地上抛

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
    g_cvBhopFirstHopRatio,
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
    g_cvHeadBlockRideEnable,
    g_cvHeadBlockRideHorizontal,
    g_cvHeadBlockRideVerticalMin,
    g_cvHeadBlockRideVerticalMax,
    g_cvHeadBlockRideRockTime,
    g_cvHeadBlockUpSwing,
    g_cvLadderLookLock,
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
    float headBlockStart;       // 高台停滞检测开始时间
    float headBlockOrigin[3];   // 高台停滞窗口开始时的 Tank 位置
    float lastHeadBlockTargetSwitch; // 上次因头顶拉黑强制换目标时间
    int   forcedTarget;         // 反头顶卡期间锁定的替代目标(userId)
    float forcedTargetUntil;    // 临时目标锁截止时间
    float forceRockUntil;       // 强制投石尝试截止时间
    int   forceRockTarget;      // 强制投石目标(userId)
    float lastForceRockRetreatTime; // 上次刷新撤离目标时间
    int   forceRockAimTarget;   // 出手后仍用于瞄准的目标(userId)
    bool  forceRockPending;     // 已提交攻击2，等待投石动画释放
    float ridingStart;          // 当前骑头开始时间
    int   ridingTarget;         // 当前骑头目标(userId)
    int   rideCheckSurvivor[MAXPLAYERS + 1]; // 按生还者缓存骑头判定(userId)
    float rideCheckTime[MAXPLAYERS + 1];
    bool  rideCheckResult[MAXPLAYERS + 1];
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
        this.lastForceRockRetreatTime = 0.0;
        this.forceRockAimTarget = -1;
        this.forceRockPending = false;
        this.ridingStart = 0.0;
        this.ridingTarget = -1;
        for (int i = 1; i <= MaxClients; i++)
        {
            this.rideCheckSurvivor[i] = -1;
            this.rideCheckTime[i] = 0.0;
            this.rideCheckResult[i] = false;
        }
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
    description = "Ai Tank 增强 3.0 版本（含攀爬/梯子分离加速、空速修正、跳砖、通背拳、骑头反制等）",
    version     = "1.0.0.13",
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
    g_cvBhopImpulse =CreateConVar("ai_tank3_bhop_impulse", "60", "连跳的加速度（落地后紧接着再起跳时追加，从跑动直接起跳的第一跳按 ai_tank3_bhop_first_hop_ratio 折算）", CVAR_FLAGS, true, 0.0);
    g_cvBhopFirstHopRatio=CreateConVar("ai_tank3_bhop_first_hop_ratio", "1.0", "从跑动直接起跳的第一跳可拿到的加速度比例，0.0=不加速只改方向，1.0=与落地跳相同（旧行为）", CVAR_FLAGS, true, 0.0, true, 1.0);
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
    g_cvHeadBlockForceRockTime = CreateConVar("ai_tank3_head_block_force_rock_time", "20.0", "强制投石尝试的最长时间（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockRange= CreateConVar("ai_tank3_head_block_force_rock_range", "250.0", "强制投石前 Tank 需要与目标拉开的最小水平距离（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseHoriz = CreateConVar("ai_tank3_head_block_force_rock_release_h", "400", "强制投石期间目标离开多远（水平距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseVert  = CreateConVar("ai_tank3_head_block_force_rock_release_v", "250", "强制投石期间目标离开多远（垂直距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideEnable    = CreateConVar("ai_tank3_head_block_ride_enable", "1", "是否把 Tank 正上方的生还者按骑头处理（能命中则上挥，否则撤离投石）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvHeadBlockRideHorizontal= CreateConVar("ai_tank3_head_block_ride_horizontal", "40.0", "骑头判定的水平距离上限（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideVerticalMin = CreateConVar("ai_tank3_head_block_ride_vertical_min", "40.0", "骑头判定的最小垂直差（单位，脚站在 Tank 上时可被 GroundEntity 短路）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideVerticalMax = CreateConVar("ai_tank3_head_block_ride_vertical_max", "100.0", "骑头判定的最大垂直差（单位，超过视为高台而非骑头）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideRockTime  = CreateConVar("ai_tank3_head_block_ride_rock_time", "3.0", "拳打不到的骑头目标持续多久后开始撤离投石（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockUpSwing       = CreateConVar("ai_tank3_head_block_up_swing", "1", "挥拳时对骑头生还者额外向上 SweepFist", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvLadderLookLock         = CreateConVar("ai_tank3_ladder_look_lock", "1", "Tank 在梯子上时把视角锁到梯子朝向，避免抬头看人掉梯", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 梯子附近仅让出连跳/锁视角；骑头出手与高台投石仍可运行
    g_cvLadderNearbyDisable = CreateConVar("ai_tank3_ladder_nearby_disable", "1", "Tank 在梯子附近时暂停 ai_tank3 连跳和挥拳锁视角", CVAR_FLAGS, true, 0.0, true, 1.0);
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
        g_AiTanks[i].wasThrowing = false;
        clearTankForceRock(i);
        clearRidingState(i);
        for (int survivor = 1; survivor <= MaxClients; survivor++)
        {
            g_AiTanks[i].rideCheckSurvivor[survivor] = -1;
            g_AiTanks[i].rideCheckTime[survivor] = 0.0;
            g_AiTanks[i].rideCheckResult[survivor] = false;
        }
        g_AiTanks[i].lastLookAheadTime = 0.0;
        clearCachedTankPath(i);
        AIPathMovement_ResetHopChain(i);
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
        g_AiTanks[i].wasThrowing = false;
        clearTankForceRock(i);
        clearRidingState(i);
        for (int survivor = 1; survivor <= MaxClients; survivor++)
        {
            g_AiTanks[i].rideCheckSurvivor[survivor] = -1;
            g_AiTanks[i].rideCheckTime[survivor] = 0.0;
            g_AiTanks[i].rideCheckResult[survivor] = false;
        }
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
    bool onLadder = (GetEntityMoveType(client) == MOVETYPE_LADDER);

    // 地面/梯子登记必须每帧、在任何提前返回之前完成，否则站在地上的帧漏登记会被误判成滞空落地，让停顿后的第一跳白拿一份加速度
    // 传入 onLadder 让梯顶 dismount 那段短暂离地不被当成落地
    if (onLadder || IsClientOnGround(client))
        AIPathMovement_NotifyGrounded(client, onLadder);
    bool nearLadder = isTankNearLadder(client, pos);

    if (onLadder && lockTankLadderLook(client, angles))
        result = Plugin_Changed;

    int target = GetClientOfUserId(g_AiTanks[client].target);
    bool validTarget = IsValidSurvivor(target) && IsPlayerAlive(target);
    int rider = (!onLadder) ? findNearestRidingSurvivor(client) : -1;
    bool riding = rider > 0;

    if (riding)
    {
        g_fHeadBlockIgnoreUntil[client][rider] = 0.0;
        g_AiTanks[client].headBlockStart = 0.0;
        if (handleRidingCombat(client, rider, buttons) == Plugin_Changed)
            result = Plugin_Changed;
    }
    else
    {
        clearRidingState(client);
    }

    // 梯子上不投石，避免松手
    bool forceRockRetreating = false;
    if (!onLadder && handleForceRock(client, buttons, pos, forceRockRetreating) == Plugin_Changed)
        result = Plugin_Changed;
    if (forceRockRetreating)
    {
        resetTankMovementOverrides(client);
        return result;
    }

    if (!validTarget)
    {
        if (nearLadder)
            resetTankMovementOverrides(client);
        return result;
    }

    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    float dist = GetVectorDistance(pos, targetPos);

    if (riding)
    {
        resetTankMovementOverrides(client);
        return result;
    }

    bool targetIgnored = isSurvivorIgnored(client, target);
    if (!targetIgnored)
    {
        if (handleHeadBlock(client, target, pos, targetPos))
        {
            if (!trySwitchHeadBlockTarget(client, target, false))
            {
                armForceRock(client, target);
                commandTankAttackTarget(client, target, "refreshing route to overhead target");
            }
            resetTankMovementOverrides(client);
            bool retreating = false;
            if (!onLadder && handleForceRock(client, buttons, pos, retreating) == Plugin_Changed)
                result = Plugin_Changed;
            return result;
        }
    }
    else
    {
        g_AiTanks[client].headBlockStart = 0.0;
        if (!trySwitchHeadBlockTarget(client, target, false) &&
            g_AiTanks[client].forceRockTarget > 0)
            commandTankAttackTarget(client, target, "refreshing ignored overhead route");
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

    return isTankPhysicallyNearLadder(client, pos);
}

bool isTankPhysicallyNearLadder(int client, const float pos[3])
{
    if (GetEntityMoveType(client) == MOVETYPE_LADDER)
        return true;

    float now = GetEngineTime();
    float cacheTime = g_cvLadderNearbyCacheTime.FloatValue;
    if (cacheTime <= 0.0)
        cacheTime = LADDER_NEARBY_CACHE_DEFAULT;

    if ((now - g_fLastLadderNearbyCheck[client]) < cacheTime)
        return g_bLastLadderNearby[client];

    g_fLastLadderNearbyCheck[client] = now;
    g_bLastLadderNearby[client] = (findNearestLadderEntity(pos, g_cvLadderNearbyRadius.FloatValue) > 0) ||
        currentNavAreaHasLadder(pos);

    return g_bLastLadderNearby[client];
}

int findNearestLadderEntity(const float pos[3], float radius)
{
    if (radius <= 0.0)
        return -1;

    if (GetFeatureStatus(FeatureType_Native, "L4D_FindEntityByClassnameNearest") == FeatureStatus_Available)
    {
        float searchPos[3];
        searchPos = pos;

        int best = -1;
        float bestDist = 999999.0;
        int entity = L4D_FindEntityByClassnameNearest("func_simpleladder", searchPos, radius);
        float dist;
        if (entity > 0 && getEntityDistance2D(entity, pos, dist) && dist < bestDist)
        {
            best = entity;
            bestDist = dist;
        }
        entity = L4D_FindEntityByClassnameNearest("func_ladder", searchPos, radius);
        if (entity > 0 && getEntityDistance2D(entity, pos, dist) && dist < bestDist)
            best = entity;
        if (best > 0)
            return best;
    }

    return findNearestLadderEntityFallback(pos, radius);
}

int findNearestLadderEntityFallback(const float pos[3], float radius)
{
    int best = -1;
    float bestDist = 999999.0;

    int entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "func_simpleladder")) != INVALID_ENT_REFERENCE)
    {
        float dist;
        if (!getEntityDistance2D(entity, pos, dist) || dist > radius)
            continue;
        if (dist < bestDist)
        {
            bestDist = dist;
            best = entity;
        }
    }

    entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "func_ladder")) != INVALID_ENT_REFERENCE)
    {
        float dist;
        if (!getEntityDistance2D(entity, pos, dist) || dist > radius)
            continue;
        if (dist < bestDist)
        {
            bestDist = dist;
            best = entity;
        }
    }

    return best;
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

bool getEntityDistance2D(int entity, const float pos[3], float &dist)
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
    dist = getVectorDistance2D(pos, center);
    return true;
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

void clearRidingState(int tank)
{
    if (tank < 1 || tank > MaxClients)
        return;
    g_AiTanks[tank].ridingStart = 0.0;
    g_AiTanks[tank].ridingTarget = -1;
}

void clearTankForceRock(int tank, bool keepAim = false)
{
    if (tank < 1 || tank > MaxClients)
        return;

    bool preservePending = keepAim && g_AiTanks[tank].forceRockPending;
    if (!preservePending)
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        g_AiTanks[tank].lastForceRockRetreatTime = 0.0;
    }
    if (!keepAim)
    {
        g_AiTanks[tank].forceRockAimTarget = -1;
        g_AiTanks[tank].forceRockPending = false;
    }
}

float wrapYawDelta(float delta)
{
    while (delta > 180.0)
        delta -= 360.0;
    while (delta < -180.0)
        delta += 360.0;
    return delta;
}

bool clientsOverlapAABB2D(int first, int second, float slack)
{
    float firstPos[3], secondPos[3];
    float firstMins[3], firstMaxs[3], secondMins[3], secondMaxs[3];
    GetClientAbsOrigin(first, firstPos);
    GetClientAbsOrigin(second, secondPos);
    GetClientMins(first, firstMins);
    GetClientMaxs(first, firstMaxs);
    GetClientMins(second, secondMins);
    GetClientMaxs(second, secondMaxs);

    float firstMinX = firstPos[0] + firstMins[0] - slack;
    float firstMaxX = firstPos[0] + firstMaxs[0] + slack;
    float firstMinY = firstPos[1] + firstMins[1] - slack;
    float firstMaxY = firstPos[1] + firstMaxs[1] + slack;
    float secondMinX = secondPos[0] + secondMins[0];
    float secondMaxX = secondPos[0] + secondMaxs[0];
    float secondMinY = secondPos[1] + secondMins[1];
    float secondMaxY = secondPos[1] + secondMaxs[1];

    return firstMinX <= secondMaxX && firstMaxX >= secondMinX &&
        firstMinY <= secondMaxY && firstMaxY >= secondMinY;
}

int getSurvivorGroundEntity(int survivor)
{
    if (HasEntProp(survivor, Prop_Send, "m_hGroundEntity"))
        return GetEntPropEnt(survivor, Prop_Send, "m_hGroundEntity");
    if (HasEntProp(survivor, Prop_Data, "m_hGroundEntity"))
        return GetEntPropEnt(survivor, Prop_Data, "m_hGroundEntity");
    return -1;
}

bool detectSurvivorRidingTank(int tank, int survivor)
{
    float tankPos[3], survivorPos[3];
    GetClientAbsOrigin(tank, tankPos);
    GetClientAbsOrigin(survivor, survivorPos);

    int ground = getSurvivorGroundEntity(survivor);
    if (ground < 0 && !(GetEntityFlags(survivor) & FL_ONGROUND))
        return false;

    float vertical = survivorPos[2] - tankPos[2];
    if (vertical < g_cvHeadBlockRideVerticalMin.FloatValue ||
        vertical > g_cvHeadBlockRideVerticalMax.FloatValue)
        return false;
    if (getVectorDistance2D(tankPos, survivorPos) > g_cvHeadBlockRideHorizontal.FloatValue)
        return false;

    // 直接站在 Tank 上时优先相信引擎的接地实体
    if (ground == tank)
        return true;

    // 站在箱子、平台或地图地面上时，GroundEntity 是中间物/World；
    // 只要人在地面、水平投影与 Tank 重叠且高度在配置窗口内，也视为 Tank 下方骑头。
    return clientsOverlapAABB2D(tank, survivor, RIDE_AABB_SLACK);
}

bool isSurvivorRidingTank(int tank, int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue || !g_cvHeadBlockRideEnable.BoolValue)
        return false;
    if (tank < 1 || tank > MaxClients)
        return false;
    if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || isClientDownState(survivor))
        return false;

    float now = GetEngineTime();
    int survivorUser = GetClientUserId(survivor);
    if (g_AiTanks[tank].rideCheckSurvivor[survivor] == survivorUser &&
        (now - g_AiTanks[tank].rideCheckTime[survivor]) < RIDE_CHECK_CACHE)
        return g_AiTanks[tank].rideCheckResult[survivor];

    bool riding = detectSurvivorRidingTank(tank, survivor);
    g_AiTanks[tank].rideCheckSurvivor[survivor] = survivorUser;
    g_AiTanks[tank].rideCheckTime[survivor] = now;
    g_AiTanks[tank].rideCheckResult[survivor] = riding;
    return riding;
}

int findNearestRidingSurvivor(int tank)
{
    int nearest = -1;
    float nearestDist = 999999.0;
    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);

    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!isSurvivorRidingTank(tank, survivor))
            continue;

        float survivorPos[3];
        GetClientAbsOrigin(survivor, survivorPos);
        float dist = GetVectorDistance(tankPos, survivorPos);
        if (dist < nearestDist)
        {
            nearestDist = dist;
            nearest = survivor;
        }
    }

    return nearest;
}

bool isAnySurvivorRidingTank(int tank)
{
    return findNearestRidingSurvivor(tank) > 0;
}

void armForceRock(int tank, int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue || !IsValidSurvivor(survivor) || !IsPlayerAlive(survivor))
        return;

    int uid = GetClientUserId(survivor);
    if (uid <= 0)
        return;

    float now = GetEngineTime();
    if (g_AiTanks[tank].forceRockTarget == uid && g_AiTanks[tank].forceRockUntil > now)
        return;

    g_AiTanks[tank].forceRockTarget = uid;
    g_AiTanks[tank].forceRockUntil = now + g_cvHeadBlockForceRockTime.FloatValue;
    g_AiTanks[tank].lastForceRockRetreatTime = 0.0;
    if (log != null)
        log.debugAll("%N armed retreat rock at %N", tank, survivor);
}

void updateRidingForceRock(int tank, int rider)
{
    float now = GetEngineTime();
    int riderUser = GetClientUserId(rider);
    if (g_AiTanks[tank].ridingTarget != riderUser)
    {
        g_AiTanks[tank].ridingTarget = riderUser;
        g_AiTanks[tank].ridingStart = now;
    }

    if (g_cvHeadBlockRideRockTime.FloatValue <= 0.0)
        return;
    if ((now - g_AiTanks[tank].ridingStart) < g_cvHeadBlockRideRockTime.FloatValue)
        return;

    armForceRock(tank, rider);
}

bool canPunchRidingSurvivor(int tank, int rider)
{
    float tankEye[3], riderChest[3];
    GetClientEyePosition(tank, tankEye);
    GetClientAbsOrigin(rider, riderChest);
    riderChest[2] += PLAYER_CHEST;

    float swingRange = (g_fTankSwingRange > 0.0) ? g_fTankSwingRange : DEFAULT_SWING_RANGE;
    if (GetVectorDistance(tankEye, riderChest) > swingRange + RIDE_AABB_SLACK)
        return false;

    return clientIsVisibleToClient(tank, rider);
}

Action handleRidingCombat(int tank, int rider, int& buttons)
{
    int oldButtons = buttons;
    buttons &= ~(IN_ATTACK | IN_ATTACK2);

    if (g_AiTanks[tank].wasThrowing)
        return (buttons != oldButtons) ? Plugin_Changed : Plugin_Continue;

    if (canPunchRidingSurvivor(tank, rider))
    {
        clearRidingState(tank);
        if (GetClientOfUserId(g_AiTanks[tank].forceRockTarget) == rider)
            clearTankForceRock(tank);

        int claw = GetEntPropEnt(tank, Prop_Send, "m_hActiveWeapon");
        if (claw > 0 && IsValidEdict(claw) && HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack") &&
            GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack") <= GetGameTime())
            buttons |= IN_ATTACK;
    }
    else
    {
        // 平台或地形挡住拳路时才开始延迟投石计时。
        updateRidingForceRock(tank, rider);
    }

    return (buttons != oldButtons) ? Plugin_Changed : Plugin_Continue;
}

bool lockTankLadderLook(int tank, float angles[3])
{
    if (!g_cvLadderLookLock.BoolValue)
        return false;

    float desired[3];
    desired = angles;
    desired[0] = 0.0;
    desired[2] = 0.0;

    float pos[3];
    GetClientAbsOrigin(tank, pos);
    int ladder = findNearestLadderEntity(pos, g_cvLadderNearbyRadius.FloatValue);
    if (ladder <= 0 || !HasEntProp(ladder, Prop_Send, "m_climbableNormal"))
        return false;

    float normal[3];
    GetEntPropVector(ladder, Prop_Send, "m_climbableNormal", normal);
    if (GetVectorLength(normal) <= 0.01)
        return false;
    desired[1] = RadToDeg(ArcTangent2(-normal[1], -normal[0]));

    if (FloatAbs(angles[0] - desired[0]) < LADDER_LOOK_ALIGN_DEG &&
        FloatAbs(wrapYawDelta(angles[1] - desired[1])) < LADDER_LOOK_ALIGN_DEG)
        return false;

    angles[0] = desired[0];
    angles[1] = desired[1];
    angles[2] = 0.0;
    TeleportEntity(tank, NULL_VECTOR, angles, NULL_VECTOR);
    return true;
}

void sweepFistAtRider(int tank, int claw, int survivor)
{
    if (g_hSdkTankClawSweepFist == null || claw <= 0 || !IsValidEdict(claw))
        return;

    float start[3], end[3];
    GetClientEyePosition(tank, start);
    GetClientAbsOrigin(survivor, end);
    end[2] += PLAYER_CHEST;
    SDKCall(g_hSdkTankClawSweepFist, claw, start, end);
    if (log != null)
        log.debugAll("%N up-swing at rider %N", tank, survivor);
}

bool handleHeadBlock(int tank, int target, const float tankPos[3], const float targetPos[3])
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;
    if (isClientDownState(target) || isSurvivorRidingTank(tank, target))
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

    float horizontalDiff = getVectorDistance2D(tankPos, targetPos);
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

void commandTankRetreatForRock(int tank, const float tankPos[3], const float targetPos[3], float horizontal, float needDistance)
{
    float now = GetEngineTime();
    if (now - g_AiTanks[tank].lastForceRockRetreatTime < FORCE_ROCK_RETREAT_INTERVAL)
        return;

    float away[3];
    away[0] = tankPos[0] - targetPos[0];
    away[1] = tankPos[1] - targetPos[1];
    away[2] = 0.0;
    if (GetVectorLength(away) < 1.0)
    {
        float angles[3], forwardVec[3];
        GetClientEyeAngles(tank, angles);
        angles[0] = 0.0;
        angles[2] = 0.0;
        GetAngleVectors(angles, forwardVec, NULL_VECTOR, NULL_VECTOR);
        away[0] = -forwardVec[0];
        away[1] = -forwardVec[1];
        away[2] = 0.0;
    }
    NormalizeVector(away, away);

    float retreatPos[3];
    float retreatDistance = needDistance - horizontal + FORCE_ROCK_RETREAT_MARGIN;
    retreatPos[0] = tankPos[0] + away[0] * retreatDistance;
    retreatPos[1] = tankPos[1] + away[1] * retreatDistance;
    retreatPos[2] = tankPos[2];

    if (GetFeatureStatus(FeatureType_Native, "L4D_GetNearestNavArea") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "L4D_GetNavAreaCenter") == FeatureStatus_Available)
    {
        Address area = L4D_GetNearestNavArea(retreatPos, 160.0, false, false, true, TEAM_INFECTED);
        if (area != Address_Null)
        {
            float navCenter[3];
            L4D_GetNavAreaCenter(area, navCenter);
            if (getVectorDistance2D(navCenter, targetPos) > horizontal + 16.0)
                retreatPos = navCenter;
        }
    }

    int tankUserId = GetClientUserId(tank);
    if (tankUserId <= 0)
        return;

    Logic_RunScript(COMMANDABOT_RESET, tankUserId);
    Logic_RunScript(COMMANDABOT_MOVE, retreatPos[0], retreatPos[1], retreatPos[2], tankUserId);
    g_AiTanks[tank].lastForceRockRetreatTime = now;
    if (log != null)
        log.debugAll("%N retreating %.1f units before rock", tank, needDistance - horizontal);
}

Action handleForceRock(int tank, int& buttons, const float tankPos[3], bool &retreating)
{
    retreating = false;
    if (!g_cvHeadBlockEnable.BoolValue)
        return Plugin_Continue;
    if (g_AiTanks[tank].forceRockUntil <= 0.0 && g_AiTanks[tank].forceRockTarget <= 0 &&
        g_AiTanks[tank].forceRockAimTarget <= 0)
        return Plugin_Continue;
    if (g_AiTanks[tank].wasThrowing)
        return Plugin_Continue;

    float now = GetEngineTime();
    if (g_AiTanks[tank].forceRockUntil <= now)
    {
        clearTankForceRock(tank);
        return Plugin_Continue;
    }

    int rockTarget = GetClientOfUserId(g_AiTanks[tank].forceRockTarget);
    if (!IsValidSurvivor(rockTarget) || !IsPlayerAlive(rockTarget))
    {
        clearTankForceRock(tank);
        return Plugin_Continue;
    }

    float blockedPos[3];
    GetClientAbsOrigin(rockTarget, blockedPos);
    float horizontal = getVectorDistance2D(tankPos, blockedPos);
    float vertical = FloatAbs(blockedPos[2] - tankPos[2]);

    float releaseHoriz = g_cvHeadBlockForceRockReleaseHoriz.FloatValue;
    float releaseVert  = g_cvHeadBlockForceRockReleaseVert.FloatValue;
    bool overHoriz = (releaseHoriz > 0.0 && horizontal > releaseHoriz);
    bool overVert  = (releaseVert > 0.0 && vertical  > releaseVert);
    if (overHoriz || overVert)
    {
        clearTankForceRock(tank);
        return Plugin_Continue;
    }

    float needDistance = g_cvHeadBlockForceRockRange.FloatValue;
    if (needDistance < FORCE_ROCK_MIN_HORIZONTAL)
        needDistance = FORCE_ROCK_MIN_HORIZONTAL;
    if (horizontal < needDistance)
    {
        int oldButtons = buttons;
        buttons &= ~(IN_ATTACK | IN_ATTACK2);
        retreating = true;
        commandTankRetreatForRock(tank, tankPos, blockedPos, horizontal, needDistance);
        return (buttons != oldButtons) ? Plugin_Changed : Plugin_Continue;
    }

    float throwMax = g_cvThrowMaxDist.FloatValue;
    if (throwMax > 0.0 && GetVectorDistance(tankPos, blockedPos) > throwMax)
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
    g_AiTanks[tank].forceRockAimTarget = g_AiTanks[tank].forceRockTarget;
    g_AiTanks[tank].forceRockPending = true;
    return Plugin_Changed;
}

int findAlternativeVictim(int tank, int ignoreTarget, bool &allOthersDown, int &nearestDown)
{
    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);

    int bestStanding = -1;
    float bestStandingDist = 999999.0;
    int bestPinned = -1;
    float bestPinnedDist = 999999.0;
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
            {
                if (dist < bestPinnedDist)
                {
                    bestPinnedDist = dist;
                    bestPinned = i;
                }
                continue;
            }

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
    if (bestPinned != -1)
    {
        allOthersDown = false;
        return bestPinned;
    }
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

    int chaseTarget = alternative;
    if (allOthersDown)
    {
        chaseTarget = (nearestDown > 0) ? nearestDown : blockedTarget;
                armForceRock(tank, blockedTarget);
    }
    else
    {
        clearTankForceRock(tank, true);
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
        clearTankForceRock(tank, true);
    }

    if (!IsValidSurvivor(target) || !IsPlayerAlive(target) || IsClientHanging(target) ||
        (isClientDownState(target) && !keepDownTarget) ||
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

    float pos[3];
    GetClientAbsOrigin(tank, pos);
    if (isTankNearLadder(tank, pos))
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
            SITL_CommitVictim(client, forcedTarget);
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
            SITL_CommitVictim(client, switchedTarget);
            return Plugin_Changed;
        }
    }

    if (g_AiTanks[client].forceRockUntil > 0.0 && g_AiTanks[client].forceRockUntil <= now &&
        !g_AiTanks[client].wasThrowing)
    {
        clearTankForceRock(client);
    }

    if (!isClientDownState(curTarget))
    {
        int rockTarget = GetClientOfUserId(g_AiTanks[client].forceRockTarget);
        if (rockTarget != curTarget)
            clearTankForceRock(client, true);
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
    if (!isAiTank(tank) || claw <= 0 || !IsValidEdict(claw))
        return;
    if (GetEntityMoveType(tank) == MOVETYPE_LADDER)
        return;

    bool upSwing = g_cvHeadBlockEnable.BoolValue && g_cvHeadBlockUpSwing.BoolValue &&
        g_cvHeadBlockRideEnable.BoolValue;

    if (upSwing)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (isSurvivorRidingTank(tank, i) && canPunchRidingSurvivor(tank, i))
                sweepFistAtRider(tank, claw, i);
        }
    }

    if (!g_cvBackFist.BoolValue)
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
        if (upSwing && isSurvivorRidingTank(tank, i) && canPunchRidingSurvivor(tank, i))
            continue;

        GetClientEyePosition(i, targetPos);
        if (GetVectorDistance(pos, targetPos) > fistRange)
            continue;
        if (!clientIsVisibleToClient(tank, i))
            continue;

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

        // 从跑动直接起跳的第一跳按 first_hop_ratio 折算加速度 (0 = 不加), 完整加速度留到落地再起跳时追加
        float hopImpulse = AIPathMovement_GetHopImpulse(client, g_cvBhopImpulse.FloatValue, g_cvBhopFirstHopRatio.FloatValue);

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
            ScaleVector(vFwd, hopImpulse);
            AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
        }
        else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0))
        {
            vFwd[0] = velVec[0]; vFwd[1] = velVec[1]; vFwd[2] = 0.0;
            NormalizeVector(vFwd, vFwd);
            ScaleVector(vFwd, hopImpulse);
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
                ScaleVector(vRight, hopImpulse * (rightOnly ? 1.0 : -1.0));
                AddVectors(vAbsVelVec, vRight, vAbsVelVec);
            }
        }

        // 起跳帧同样受最大连跳速度约束, 原来只在空中帧限速, 起跳那一帧可以超限
        AIPathMovement_ClampHorizontalSpeed(vAbsVelVec, g_cvBhopMaxSpeed.FloatValue);

        // 记录起跳水平速度（空中修正用）
        g_AiTanks[client].lastHopSpeed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
        AIPathMovement_BeginPathHop(client, targetPos, g_AiTanks[client].lastHopSpeed, g_cvBhopMaxSpeed.FloatValue);
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
        AIPathMovement_MarkHopStart(client);
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
    // 从跑动直接起跳的第一跳按 first_hop_ratio 折算加速度 (0 = 只改方向), 完整加速度留到落地再起跳时追加
    ScaleVector(vFwd, speed + AIPathMovement_GetHopImpulse(client, g_cvBhopImpulse.FloatValue, g_cvBhopFirstHopRatio.FloatValue));

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
    AIPathMovement_BeginPathHop(client, lookAheadPos, g_AiTanks[client].lastHopSpeed, g_cvBhopMaxSpeed.FloatValue);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vFwd);
    AIPathMovement_MarkHopStart(client);
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
    AIPathMovement_ResetHopChain(client);
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
    g_AiTanks[client].wasThrowing = false;
    clearTankTargetLock(client);
    clearTankForceRock(client);
    clearRidingState(client);
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        g_AiTanks[client].rideCheckSurvivor[survivor] = -1;
        g_AiTanks[client].rideCheckTime[survivor] = 0.0;
        g_AiTanks[client].rideCheckResult[survivor] = false;
    }
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
        if (tank > 0 && tank <= MaxClients)
        {
            g_AiTanks[tank].wasThrowing = false;
            clearTankForceRock(tank);
        }
        AnimHookDisable(tank, tankAnimHookPostCb);
        return Plugin_Continue;
    }

    if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        if (!g_AiTanks[tank].wasThrowing)
        {
            // 出手已经开始，停止继续按攻击2，但保留瞄准目标到 OnRelease
            g_AiTanks[tank].forceRockUntil = 0.0;
            g_AiTanks[tank].forceRockTarget = -1;
            g_AiTanks[tank].lastForceRockRetreatTime = 0.0;
            if (g_cvJumpRock.BoolValue)
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

    switch (seqType)
    {
        case view_as<TankSequenceType>(tankSequence_Throw):
            // post animation hook 提供的是 Tank 模型的 m_nSequence；L4D2
            // 投石序列固定为 48-51，不能用 AnimGetActivity() 解析。
            return sequence >= 48 && sequence <= 51;
    }
    return false;
}

// ===== 投石：跳砖、距离限制、出手角度 =====
void makeTankJumpRock(int tank)
{
    if (!isAiTank(tank)) return;
    if (GetEntityMoveType(tank) == MOVETYPE_LADDER)
        return;
    if (isAnySurvivorRidingTank(tank))
        return;

    float vAbsVelVec[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    vAbsVelVec[2] += JUMP_SPEED_Z;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
}

Action timerResetThrowingFlagHandler(Handle timer, int userId)
{
    int tank = GetClientOfUserId(userId);
    if (!isAiTank(tank))
    {
        if (tank > 0 && tank <= MaxClients)
        {
            g_AiTanks[tank].wasThrowing = false;
            clearTankForceRock(tank);
        }
        return Plugin_Stop;
    }

    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    if (!isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        g_AiTanks[tank].wasThrowing = false;
        clearTankForceRock(tank);
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

Action checkEnableThrow(int client, int& buttons, float dist)
{
    if (!isAiTank(client)) return Plugin_Continue;
    if (g_AiTanks[client].wasThrowing) return Plugin_Continue;

    if ((dist < g_cvThrowMinDist.FloatValue || dist > g_cvThrowMaxDist.FloatValue) && (buttons & IN_ATTACK2))
    {
        buttons &= ~IN_ATTACK2;
        if (g_AiTanks[client].forceRockPending)
        {
            g_AiTanks[client].forceRockAimTarget = -1;
            g_AiTanks[client].forceRockPending = false;
        }
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

    int aimOverride = -1;
    if (g_AiTanks[tank].forceRockPending)
        aimOverride = GetClientOfUserId(g_AiTanks[tank].forceRockAimTarget);
    int target = GetClientOfUserId(g_AiTanks[tank].target);
    if (IsValidSurvivor(aimOverride) && IsPlayerAlive(aimOverride))
        target = aimOverride;
    g_AiTanks[tank].forceRockAimTarget = -1;
    g_AiTanks[tank].forceRockPending = false;
    if (!IsValidSurvivor(target)) return Plugin_Continue;

    int newRockTarget = -1;
    if (!IsValidSurvivor(aimOverride) && g_cvRockTargetAdjust.BoolValue)
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

    // m_nSequence 是模型序列号；L4D2 投石序列为 48-51。
    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    switch (animSeq)
    {
        case 48, 50:
            pos[2] += THROW_UNDERHEAD_POS_Z;
        case 49:
            pos[2] += THROW_OVERSHOULDER_POS_Z;
        case 51:
            pos[2] += THROW_OVERHEAD_POS_Z;
    }

    GetClientAbsOrigin(target, tpos);
    tpos[2] += PLAYER_CHEST;

    float dx = SquareRoot(Pow(tpos[0] - pos[0], 2.0) + Pow(tpos[1] - pos[1], 2.0));
    float dz = tpos[2] - pos[2];
    if (dx < 1.0)
        return -9999.0;

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
