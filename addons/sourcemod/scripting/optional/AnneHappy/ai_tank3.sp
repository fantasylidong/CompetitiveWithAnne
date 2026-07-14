#pragma semicolon 1
#pragma newdecls required

// ===== 头文件 =====
#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>
#include <colors>
#include <treeutil>
#include <logger2>
// 你自己的公共方法、工具函数（判定AI Tank / 可见性 / 贴图等）都在这里
#include "../../archive/AnneHappy/stocks.sp"

// ===== 常量 / 宏 =====
#define CVAR_FLAGS                 FCVAR_NOTIFY
#define PLUGIN_PREFIX              "Ai-Tank3"
#define GAMEDATA                   "l4d2_ai_tank3"
#define SIG_PATH_FOLLOWER_UPDATE   "PathFollower::Update"
#define SIG_NEXTBOT_GET_COMBAT_CHARACTER "INextBot::GetNextBotCombatCharacter"
#define SIG_PATH_GET_CUR_GOAL      "Path::GetCurrentGoal"
#define SIG_PATH_INVALIDATE        "Path::Invalidate"
#define SIG_PATH_NEXT_SEGMENT      "Path::NextSegment"
#define SIG_PATH_LAST_SEGMENT      "Path::LastSegment"

#define DEFAULT_THROW_FORCE        800.0
#define DEFAULT_SV_GRAVITY         800.0
#define DEFAULT_SWING_RANGE        56.0
#define PATH_LOOKAHEAD_MIN_DIST    150.0
#define PATH_GOAL_TOLERANCE_DIST   25.0
#define PATH_CACHE_MAX_AGE         0.25
#define PATH_INVALIDATE_PENDING_TIME 1.0
#define TANK_PATH_CACHE_SIZE       32
#define OBSTACLE_JUMP_TRACE_STEP   0.05
#define OBSTACLE_JUMP_TRACE_START_Z 2.0
#define OBSTACLE_JUMP_MAX_DROP     96.0
#define OBSTACLE_JUMP_LAND_NORMAL  0.65
#define OBSTACLE_JUMP_MAX_STEPS    128

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

#define TANK_SEGMENT_ON_GROUND     0
#define TANK_SEGMENT_DROP_DOWN     1
#define TANK_SEGMENT_CLIMB_UP      2
#define TANK_SEGMENT_JUMP_GAP      3
#define TANK_SEGMENT_LADDER_UP     4
#define TANK_SEGMENT_LADDER_DOWN   5

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
    g_cvLadderNearbyCacheTime,
    g_cvPathBhopPrefer,
    g_cvStuckDetect,
    g_cvStuckTime,
    g_cvStuckMinMove,
    g_cvStuckCheckInterval,
    g_cvStuckEntityCheck,
    g_cvStuckEntityInterval,
    g_cvStuckEntityTime,
    g_cvStuckObstacleJump,
    g_cvStuckObstacleJumpSpeed,
    g_cvStuckObstacleJumpDuration,
    g_cvStuckObstacleJumpCooldown,
    g_cvStuckObstacleJumpAttempts,
    g_cvSpecialMoveTimeout,
    g_cvPathInvalidateCooldown,
    g_cvRecoveryTime;

ConVar g_cvBhopNoVisionMaxAng;
ConVar cvTankSwingRange;

// ===== 运行时对象 =====
StringMap g_hThrowAnimMap;
ArrayList g_hNearbyLadderList;

Handle g_hSdkTankClawSweepFist;
Handle g_hSdkNextBotGetCombatCharacter;
Handle g_hSdkPathGetCurGoal;
Handle g_hSdkPathNextSegment;
Handle g_hSdkPathInvalidate;
Handle g_hSdkPathLastSegment;
Handle g_hPathFollowerDetour;

bool  g_bLateLoad;
float g_fTankSwingRange;
float g_fHeadBlockIgnoreUntil[MAXPLAYERS + 1];
float g_fLastLadderNearbyCheck[MAXPLAYERS + 1];
bool  g_bLastLadderNearby[MAXPLAYERS + 1];
bool  g_bAnimHooked[MAXPLAYERS + 1];

enum TankMoveState
{
    TankMoveState_Native,
    TankMoveState_Path,
    TankMoveState_Direct,
    TankMoveState_Special,
    TankMoveState_Recovery,
    TankMoveState_Commit
}

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
    float lastHeadBlockTargetSwitch; // 上次因头顶拉黑强制换目标时间
    float forceRockUntil;       // 除卡位者外其他生还都倒地时的强制投石截止时间
    int   forceRockTarget;      // 除卡位者外其他生还都倒地时的强制投石目标(userId)
    PathSegment pathSegment;    // 当前 PathSegment
    PathSegment lastPathSegment;// 当前路径最后一个 PathSegment
    bool pathInvalidatePending; // 下一次 PathFollower detour 中安全地失效当前路径
    float pathInvalidatePendingUntil;
    float pathUpdateTime;       // 最近一次从有效 PathFollower 复制路径的时间
    int pathSegmentCount;       // 已复制到本地缓存的 PathSegment 数量
    float airCorrGoal[3];       // 无视野路径连跳的空中修正目标点
    TankBhopType bhopType;      // 当前连跳类型
    TankMoveState moveState;    // 移动状态机当前状态
    float moveStateStart;       // 当前移动状态开始时间
    float progressCheckTime;    // 上次无进展检查时间
    float progressPos[3];       // 上次记录的位置
    float stuckSince;            // 疑似卡住开始时间
    float stuckEntitySince;      // 同一阻挡实体持续时间
    float lastStuckEntityCheckTime;
    float ladderNearbyIgnoreUntil; // 路径失效后暂时避免重新进入梯子附近死循环
    float lastPathInvalidateTime;
    float recoveryUntil;
    int stuckEntity;
    int stuckCount;
    float obstacleJumpUntil;
    float obstacleJumpCooldownUntil;
    int obstacleJumpEntity;
    int obstacleJumpAttempts;

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
        this.lastHeadBlockTargetSwitch = 0.0;
        this.forceRockUntil = 0.0;
        this.forceRockTarget = -1;
        this.pathSegment.initData();
        this.lastPathSegment.initData();
        this.pathInvalidatePending = false;
        this.pathInvalidatePendingUntil = 0.0;
        this.pathUpdateTime = 0.0;
        this.pathSegmentCount = 0;
        this.airCorrGoal = NULL_VECTOR;
        this.bhopType = TankBhopType_None;
        this.moveState = TankMoveState_Native;
        this.moveStateStart = 0.0;
        this.progressCheckTime = 0.0;
        this.progressPos = NULL_VECTOR;
        this.stuckSince = 0.0;
        this.stuckEntitySince = 0.0;
        this.lastStuckEntityCheckTime = 0.0;
        this.ladderNearbyIgnoreUntil = 0.0;
        this.lastPathInvalidateTime = 0.0;
        this.recoveryUntil = 0.0;
        this.stuckEntity = -1;
        this.stuckCount = 0;
        this.obstacleJumpUntil = 0.0;
        this.obstacleJumpCooldownUntil = 0.0;
        this.obstacleJumpEntity = -1;
        this.obstacleJumpAttempts = 0;
    }
}
AiTank g_AiTanks[MAXPLAYERS + 1];
PathSegment g_TankPathCache[MAXPLAYERS + 1][TANK_PATH_CACHE_SIZE];

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
    description = "Ai Tank 增强 3.0 版本（状态机、路径连跳、卡住恢复、障碍跳跃、梯子处理）",
    version     = "1.1.1.0",
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

    // 梯子附近让出本插件移动/目标/投石逻辑，交还 NextBot 和梯子加速插件处理
    g_cvLadderNearbyDisable = CreateConVar("ai_tank3_ladder_nearby_disable", "1", "Tank 在梯子附近时暂停 ai_tank3 行为处理", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvLadderNearbyRadius = CreateConVar("ai_tank3_ladder_nearby_radius", "180.0", "Tank 距离梯子多近时暂停 ai_tank3 行为处理", CVAR_FLAGS, true, 0.0);
    g_cvLadderNearbyCacheTime = CreateConVar("ai_tank3_ladder_nearby_cache", "0.20", "梯子附近检测缓存时间（秒）", CVAR_FLAGS, true, 0.0);

    // 移动状态机与卡住恢复
    g_cvPathBhopPrefer = CreateConVar("ai_tank3_path_bhop_prefer", "1", "有有效导航路径时优先沿路径连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvStuckDetect = CreateConVar("ai_tank3_stuck_detect", "1", "是否启用 Tank 无进展检测与路径恢复", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvStuckTime = CreateConVar("ai_tank3_stuck_time", "0.90", "Tank 预计移动但持续无进展多久后判定卡住（秒）", CVAR_FLAGS, true, 0.2);
    g_cvStuckMinMove = CreateConVar("ai_tank3_stuck_min_move", "24.0", "卡住检测周期内的最小水平位移", CVAR_FLAGS, true, 1.0);
    g_cvStuckCheckInterval = CreateConVar("ai_tank3_stuck_check_interval", "0.20", "无进展检测间隔（秒）", CVAR_FLAGS, true, 0.05);
    g_cvStuckEntityCheck = CreateConVar("ai_tank3_stuck_entity_check", "1", "疑似卡住时是否检测脚部阻挡实体", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvStuckEntityInterval = CreateConVar("ai_tank3_stuck_entity_interval", "0.25", "脚部阻挡实体检测间隔（秒）", CVAR_FLAGS, true, 0.05);
    g_cvStuckEntityTime = CreateConVar("ai_tank3_stuck_entity_time", "0.45", "同一实体持续卡脚多久后触发恢复（秒）", CVAR_FLAGS, true, 0.1);
    g_cvStuckObstacleJump = CreateConVar("ai_tank3_stuck_obstacle_jump", "1", "检测到可越过的脚部阻挡实体时是否先尝试跳跃", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvStuckObstacleJumpSpeed = CreateConVar("ai_tank3_stuck_obstacle_jump_speed", "300.0", "脚部阻挡跳跃的垂直速度", CVAR_FLAGS, true, 150.0, true, 600.0);
    g_cvStuckObstacleJumpDuration = CreateConVar("ai_tank3_stuck_obstacle_jump_duration", "0.80", "脚部阻挡跳跃期间暂停其他移动覆盖的时间（秒）", CVAR_FLAGS, true, 0.2, true, 2.0);
    g_cvStuckObstacleJumpCooldown = CreateConVar("ai_tank3_stuck_obstacle_jump_cooldown", "1.25", "同一 Tank 两次脚部阻挡跳跃的最小间隔（秒）", CVAR_FLAGS, true, 0.2, true, 5.0);
    g_cvStuckObstacleJumpAttempts = CreateConVar("ai_tank3_stuck_obstacle_jump_attempts", "1", "同一阻挡实体允许尝试跳跃的次数，失败后改为重新寻路", CVAR_FLAGS, true, 0.0, true, 3.0);
    g_cvSpecialMoveTimeout = CreateConVar("ai_tank3_special_move_timeout", "1.50", "梯子/攀爬等特殊移动最长等待时间（秒）", CVAR_FLAGS, true, 0.2);
    g_cvPathInvalidateCooldown = CreateConVar("ai_tank3_path_invalidate_cooldown", "0.75", "两次主动路径失效之间的最小间隔（秒）", CVAR_FLAGS, true, 0.1);
    g_cvRecoveryTime = CreateConVar("ai_tank3_recovery_time", "0.35", "路径恢复期间暂停移动覆盖的时间（秒）", CVAR_FLAGS, true, 0.1);

    // 日志
    g_cvPluginName = CreateConVar("ai_tank3_plugin_name", "ai_tank3");
    char cvName[64];
    g_cvPluginName.GetString(cvName, sizeof(cvName));
    FormatEx(cvName, sizeof(cvName), "%s_log_level", cvName);
    g_cvLogLevel = CreateConVar(cvName, "32", "日志级别: 1=关,2=控制台,4=log,8=chat,16=srv,32=err", CVAR_FLAGS);

    // 事件
    HookEvent("round_start", evtRoundStart);
    HookEvent("round_end",   evtRoundEnd);
    HookEvent("player_spawn", evtPlayerSpawn, EventHookMode_Post);
    HookEvent("player_death", evtPlayerDeath, EventHookMode_Post);
    HookEvent("tank_spawn", evtTankSpawn, EventHookMode_Post);
    HookEvent("player_bot_replace", evtPlayerBotReplace, EventHookMode_Post);
    HookEvent("bot_player_replace", evtBotPlayerReplace, EventHookMode_Post);
    HookEvent("player_hurt", evtPlayerHurt, EventHookMode_Post); // 命中刷新通背拳窗口

    // 日志对象
    log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);

    // 初始化动画活动映射
    initAnimMap();
    g_hNearbyLadderList = new ArrayList();

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

    g_hPathFollowerDetour = DHookCreateFromConf(hGamedata, SIG_PATH_FOLLOWER_UPDATE);
    if (!g_hPathFollowerDetour)
        SetFailState("Failed to create detour for %s.", SIG_PATH_FOLLOWER_UPDATE);
    if (!DHookEnableDetour(g_hPathFollowerDetour, false, Detour_PathFollower_Update))
        SetFailState("Failed to enable detour for %s.", SIG_PATH_FOLLOWER_UPDATE);

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(hGamedata, SDKConf_Virtual, SIG_NEXTBOT_GET_COMBAT_CHARACTER))
        SetFailState("Failed to load offset for %s.", SIG_NEXTBOT_GET_COMBAT_CHARACTER);
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
    g_hSdkNextBotGetCombatCharacter = EndPrepSDKCall();
    if (!g_hSdkNextBotGetCombatCharacter)
        SetFailState("Failed to prep SDKCall for %s.", SIG_NEXTBOT_GET_COMBAT_CHARACTER);

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(hGamedata, SDKConf_Virtual, SIG_PATH_GET_CUR_GOAL))
        SetFailState("Failed to load offset for %s.", SIG_PATH_GET_CUR_GOAL);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkPathGetCurGoal = EndPrepSDKCall();
    if (!g_hSdkPathGetCurGoal)
        SetFailState("Failed to prep SDKCall for %s.", SIG_PATH_GET_CUR_GOAL);

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(hGamedata, SDKConf_Virtual, SIG_PATH_INVALIDATE))
        SetFailState("Failed to load offset for %s.", SIG_PATH_INVALIDATE);
    g_hSdkPathInvalidate = EndPrepSDKCall();
    if (!g_hSdkPathInvalidate)
        SetFailState("Failed to prep SDKCall for %s.", SIG_PATH_INVALIDATE);

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(hGamedata, SDKConf_Virtual, SIG_PATH_NEXT_SEGMENT))
        SetFailState("Failed to load offset for %s.", SIG_PATH_NEXT_SEGMENT);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkPathNextSegment = EndPrepSDKCall();
    if (!g_hSdkPathNextSegment)
        SetFailState("Failed to prep SDKCall for %s.", SIG_PATH_NEXT_SEGMENT);

    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(hGamedata, SDKConf_Virtual, SIG_PATH_LAST_SEGMENT))
        SetFailState("Failed to load offset for %s.", SIG_PATH_LAST_SEGMENT);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkPathLastSegment = EndPrepSDKCall();
    if (!g_hSdkPathLastSegment)
        SetFailState("Failed to prep SDKCall for %s.", SIG_PATH_LAST_SEGMENT);

    delete hGamedata;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            ensureTankAnimHook(i);
    }
}

public MRESReturn Detour_PathFollower_Update(Address pThis, Handle hParams)
{
    if (!pThis || !hParams || !g_hSdkNextBotGetCombatCharacter)
        return MRES_Ignored;

    Address pNextBot = view_as<Address>(DHookGetParam(hParams, 1));
    if (!pNextBot)
        return MRES_Ignored;

    int client = SDKCall(g_hSdkNextBotGetCombatCharacter, pNextBot);
    if (!isAiTank(client))
        return MRES_Ignored;

    if (g_AiTanks[client].pathInvalidatePending)
    {
        bool shouldInvalidate = GetEngineTime() <= g_AiTanks[client].pathInvalidatePendingUntil;
        g_AiTanks[client].pathInvalidatePending = false;
        g_AiTanks[client].pathInvalidatePendingUntil = 0.0;
        if (shouldInvalidate)
        {
            SDKCall(g_hSdkPathInvalidate, pThis);
            clearTankPathSnapshot(client);
            return MRES_Ignored;
        }
    }

    Address pPathSeg = view_as<Address>(SDKCall(g_hSdkPathGetCurGoal, pThis));
    if (!pPathSeg)
    {
        clearTankPathSnapshot(client);
        return MRES_Ignored;
    }

    PathSegment curSegment;
    constructPathSegment(pPathSeg, curSegment);
    g_AiTanks[client].pathSegment = curSegment;

    int cacheLimit = g_cvPathLookAheadMaxDepth.IntValue + 1;
    if (cacheLimit < 1)
        cacheLimit = 1;
    else if (cacheLimit > TANK_PATH_CACHE_SIZE)
        cacheLimit = TANK_PATH_CACHE_SIZE;

    int cacheCount = 0;
    Address pIterSeg = pPathSeg;
    while (pIterSeg != Address_Null && cacheCount < cacheLimit)
    {
        PathSegment cachedSegment;
        constructPathSegment(pIterSeg, cachedSegment);
        g_TankPathCache[client][cacheCount] = cachedSegment;
        cacheCount++;

        pIterSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pThis, pIterSeg));
    }
    g_AiTanks[client].pathSegmentCount = cacheCount;
    g_AiTanks[client].pathUpdateTime = GetEngineTime();

    Address pLastSeg = view_as<Address>(SDKCall(g_hSdkPathLastSegment, pThis));
    if (!pLastSeg)
    {
        g_AiTanks[client].lastPathSegment.initData();
    }
    else
    {
        PathSegment lastSegment;
        constructPathSegment(pLastSeg, lastSegment);
        g_AiTanks[client].lastPathSegment = lastSegment;
    }

    return MRES_Ignored;
}

// ===== 读取/监听 CVar =====
public void OnConfigsExecuted()
{
    cvTankSwingRange  = FindConVar("tank_swing_range");
    g_fTankSwingRange = (!cvTankSwingRange) ? DEFAULT_SWING_RANGE : cvTankSwingRange.FloatValue;

    // FIX: 只有找到 cvar 才能挂 ChangeHook（原版写反了）
    if (cvTankSwingRange)
        cvTankSwingRange.AddChangeHook(changeHookTankSwingRange);
}

void changeHookTankSwingRange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_fTankSwingRange = convar.FloatValue;
    log.debugAll("tank_swing_range changed to %d", convar.IntValue);
}

// ===== 结束回收 =====
public void OnPluginEnd()
{
    if (GetFeatureStatus(FeatureType_Native, "AnimHookDisable") == FeatureStatus_Available)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_bAnimHooked[i] && IsClientInGame(i))
                AnimHookDisable(i, INVALID_FUNCTION, tankAnimHookPostCb);
        }
    }

    delete log;
    delete g_hThrowAnimMap;
    delete g_hNearbyLadderList;
    delete g_hPathFollowerDetour;
    delete g_hSdkNextBotGetCombatCharacter;
    delete g_hSdkPathGetCurGoal;
    delete g_hSdkPathNextSegment;
    delete g_hSdkPathInvalidate;
    delete g_hSdkPathLastSegment;
}

// ===== 事件 =====
void clearTankPathSnapshot(int client)
{
    g_AiTanks[client].pathSegment.initData();
    g_AiTanks[client].lastPathSegment.initData();
    g_AiTanks[client].pathUpdateTime = 0.0;
    g_AiTanks[client].pathSegmentCount = 0;
    g_AiTanks[client].airCorrGoal = NULL_VECTOR;
    g_AiTanks[client].bhopType = TankBhopType_None;
    g_AiTanks[client].lastHopSpeed = 0.0;
    g_AiTanks[client].lastLookAheadTime = 0.0;
    g_AiTanks[client].lastAirVecModifyTime = 0.0;
}

void resetTankClientState(int client, bool resetIgnore)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AiTanks[client].initData();
    g_fLastLadderNearbyCheck[client] = 0.0;
    g_bLastLadderNearby[client] = false;
    if (resetIgnore)
        g_fHeadBlockIgnoreUntil[client] = 0.0;
}

void ensureTankAnimHook(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || g_bAnimHooked[client])
        return;
    if (GetFeatureStatus(FeatureType_Native, "AnimHookEnable") != FeatureStatus_Available)
        return;

    g_bAnimHooked[client] = AnimHookEnable(client, INVALID_FUNCTION, tankAnimHookPostCb);
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bAnimHooked[i] = false;
        if (IsClientInGame(i))
            ensureTankAnimHook(i);
    }
}

public void OnMapEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        resetTankClientState(i, true);
        g_bAnimHooked[i] = false;
    }
}

void evtRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        resetTankClientState(i, true);
}

void evtRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
        resetTankClientState(i, true);
}

void evtPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    resetTankClientState(client, true);
    ensureTankAnimHook(client);
}

void evtPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED)
        resetTankClientState(client, false);
}

void evtTankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    resetTankClientState(client, true);
    ensureTankAnimHook(client);
}

void resetTankReplacementClients(Event event)
{
    int player = GetClientOfUserId(event.GetInt("player"));
    int bot = GetClientOfUserId(event.GetInt("bot"));
    resetTankClientState(player, true);
    resetTankClientState(bot, true);
    ensureTankAnimHook(player);
    ensureTankAnimHook(bot);
}

void evtPlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
    resetTankReplacementClients(event);
}

void evtBotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
    resetTankReplacementClients(event);
}

public void L4D_OnReplaceTank(int oldTank, int newTank)
{
    resetTankClientState(oldTank, true);
    resetTankClientState(newTank, true);
    ensureTankAnimHook(oldTank);
    ensureTankAnimHook(newTank);
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


    float pos[3];
    GetClientAbsOrigin(client, pos);

    if (handleTankObstacleJumpState(client, buttons, vel))
    {
        resetTankMovementOverrides(client);
        return Plugin_Changed;
    }

    bool actualLadder = GetEntityMoveType(client) == MOVETYPE_LADDER;
    bool nearLadder = actualLadder || isTankNearLadder(client, pos);
    if (handleTankSpecialMoveState(client, pos, nearLadder, actualLadder))
    {
        resetTankMovementOverrides(client);
        return Plugin_Continue;
    }

    handleForceRock(client, buttons, pos);

    int target = GetClientOfUserId(g_AiTanks[client].target);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return Plugin_Continue;

    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    float dist = GetVectorDistance(pos, targetPos);

    updateTankMoveState(client, target, dist);
    if (updateTankProgress(client, pos, targetPos, dist, buttons, vel))
    {
        resetTankMovementOverrides(client);
        return Plugin_Changed;
    }

    bool targetIgnored = isSurvivorIgnored(target);
    if (!targetIgnored)
    {
        handleHeadBlock(client, target, pos, targetPos);
    }
    else
    {
        g_AiTanks[client].headBlockStart = 0.0;
        trySwitchHeadBlockTarget(client, target, false);
        return Plugin_Continue;
    }

    // 挥拳锁视角
    punchLockVision(client, target, pos, targetPos);

    // 限制投石距离
    checkEnableThrow(client, buttons, dist);

    // 连跳逻辑
    checkEnableBhop(client, target, buttons, pos, targetPos, dist);

    return Plugin_Continue;
}

bool isSurvivorIgnored(int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return false;
    if (!IsValidSurvivor(survivor))
        return false;
    return g_fHeadBlockIgnoreUntil[survivor] > GetEngineTime();
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
    g_AiTanks[client].lastHopSpeed = 0.0;
    g_AiTanks[client].lastLookAheadTime = 0.0;
    g_AiTanks[client].lastAirVecModifyTime = 0.0;
}

void setTankMoveState(int client, TankMoveState state)
{
    if (g_AiTanks[client].moveState == state)
        return;

    g_AiTanks[client].moveState = state;
    g_AiTanks[client].moveStateStart = GetEngineTime();
    if (state == TankMoveState_Recovery || state == TankMoveState_Special)
        resetTankMovementOverrides(client);
}

bool handleTankObstacleJumpState(int client, int& buttons, float vel[3])
{
    float now = GetEngineTime();
    if (g_AiTanks[client].obstacleJumpUntil <= 0.0)
        return false;

    bool landed = IsClientOnGround(client) && now - g_AiTanks[client].moveStateStart >= 0.15;
    if (now >= g_AiTanks[client].obstacleJumpUntil || landed)
    {
        g_AiTanks[client].obstacleJumpUntil = 0.0;
        return false;
    }

    // 起跳速度由 TeleportEntity 完全接管，避免原生跳跃和空中加速改变预测轨迹。
    buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_LEFT | IN_RIGHT);
    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    return true;
}

bool getTankObstacleDirection(int client, const float pos[3], const float targetPos[3], float direction[3])
{
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", direction);
    direction[2] = 0.0;
    if (getVectorLength2D(direction) < 10.0 && hasTankPathSegment(client))
        direction = g_AiTanks[client].pathSegment.m_vecForward;
    if (getVectorLength2D(direction) < 10.0)
        MakeVectorFromPoints(pos, targetPos, direction);
    direction[2] = 0.0;
    return NormalizeVector(direction, direction) > 0.0;
}

bool isTankObstacleJumpEntity(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    char className[64];
    GetEntityClassname(entity, className, sizeof(className));
    if (strcmp(className, "func_ladder", false) == 0 ||
        strcmp(className, "func_simpleladder", false) == 0 ||
        strcmp(className, "func_nav_blocker", false) == 0 ||
        strcmp(className, "func_playerclip", false) == 0 ||
        strcmp(className, "player_infected_clip", false) == 0 ||
        strcmp(className, "func_playerinfected_clip", false) == 0 ||
        StrContains(className, "trigger_", false) == 0)
    {
        return false;
    }
    return true;
}

float getTankGravity(int client)
{
    ConVar cvGravity = FindConVar("sv_gravity");
    float gravity = cvGravity ? cvGravity.FloatValue : DEFAULT_SV_GRAVITY;
    if (gravity <= 1.0)
        gravity = DEFAULT_SV_GRAVITY;

    if (HasEntProp(client, Prop_Data, "m_flGravity"))
    {
        float gravityScale = GetEntPropFloat(client, Prop_Data, "m_flGravity");
        if (gravityScale > 0.0)
            gravity *= gravityScale;
    }
    return gravity;
}

bool tankJumpChordTouchesEntityClass(const float start[3], const float end[3], const float vMins[3], const float vMaxs[3], const char[] className)
{
    int entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, className)) != INVALID_ENT_REFERENCE)
    {
        Handle trace = TR_ClipRayHullToEntityEx(start, end, vMins, vMaxs, MASK_ALL, entity);
        bool touched = TR_DidHit(trace) || TR_StartSolid(trace);
        delete trace;
        if (touched)
            return true;
    }
    return false;
}

bool tankJumpChordTouchesHazard(const float start[3], const float end[3], const float vMins[3], const float vMaxs[3])
{
    return tankJumpChordTouchesEntityClass(start, end, vMins, vMaxs, "trigger_hurt") ||
        tankJumpChordTouchesEntityClass(start, end, vMins, vMaxs, "trigger_fall") ||
        tankJumpChordTouchesEntityClass(start, end, vMins, vMaxs, "trigger_teleport") ||
        tankJumpChordTouchesEntityClass(start, end, vMins, vMaxs, "trigger_push") ||
        tankJumpChordTouchesEntityClass(start, end, vMins, vMaxs, "trigger_gravity");
}

bool canTankJumpOverObstacle(int client, const float pos[3], const float jumpVelocity[3], float& landingTime)
{
    float gravity = getTankGravity(client);
    float jumpHeight = jumpVelocity[2] * jumpVelocity[2] / (2.0 * gravity);
    if (jumpVelocity[2] <= 0.0 || jumpHeight < 24.0)
        return false;

    float traceDrop = OBSTACLE_JUMP_MAX_DROP + OBSTACLE_JUMP_TRACE_START_Z;
    float maxTime = (jumpVelocity[2] + SquareRoot(jumpVelocity[2] * jumpVelocity[2] + 2.0 * gravity * traceDrop)) / gravity;
    int steps = RoundToCeil(maxTime / OBSTACLE_JUMP_TRACE_STEP);
    int distanceSteps = RoundToCeil(getVectorLength2D(jumpVelocity) * maxTime / 32.0);
    if (distanceSteps > steps)
        steps = distanceSteps;
    if (steps < 8)
        steps = 8;
    else if (steps > OBSTACLE_JUMP_MAX_STEPS)
        steps = OBSTACLE_JUMP_MAX_STEPS;

    float vMins[3], vMaxs[3];
    GetClientMins(client, vMins);
    GetClientMaxs(client, vMaxs);

    float previousPos[3];
    previousPos = pos;
    previousPos[2] += OBSTACLE_JUMP_TRACE_START_Z;
    float previousTime = 0.0;
    for (int i = 1; i <= steps; i++)
    {
        float currentTime = maxTime * float(i) / float(steps);
        float currentPos[3];
        currentPos[0] = pos[0] + jumpVelocity[0] * currentTime;
        currentPos[1] = pos[1] + jumpVelocity[1] * currentTime;
        currentPos[2] = pos[2] + OBSTACLE_JUMP_TRACE_START_Z + jumpVelocity[2] * currentTime - 0.5 * gravity * currentTime * currentTime;

        if (TR_PointOutsideWorld(currentPos) || tankJumpChordTouchesHazard(previousPos, currentPos, vMins, vMaxs))
            return false;

        Handle trace = TR_TraceHullFilterEx(previousPos, currentPos, vMins, vMaxs, MASK_PLAYERSOLID, _TraceWallFilter, client);
        bool startedSolid = TR_StartSolid(trace);
        if (!TR_DidHit(trace))
        {
            delete trace;
            previousPos = currentPos;
            previousTime = currentTime;
            continue;
        }

        float fraction = TR_GetFraction(trace);
        float hitTime = previousTime + (currentTime - previousTime) * fraction;
        float hitPos[3], hitNormal[3];
        TR_GetEndPosition(hitPos, trace);
        TR_GetPlaneNormal(trace, hitNormal);
        delete trace;

        float verticalSpeed = jumpVelocity[2] - gravity * hitTime;
        if (startedSolid || verticalSpeed >= 0.0 || hitNormal[2] < OBSTACLE_JUMP_LAND_NORMAL ||
            hitPos[2] < pos[2] - OBSTACLE_JUMP_MAX_DROP)
        {
            return false;
        }

        landingTime = hitTime;
        return true;
    }
    return false;
}

bool tryTankObstacleJump(int client, int blocker, const float pos[3], const float targetPos[3], int& buttons, float cmdVel[3])
{
    if (!g_cvStuckObstacleJump.BoolValue || !isTankObstacleJumpEntity(blocker))
        return false;
    if (!IsClientOnGround(client) || L4D_IsPlayerStaggering(client) ||
        GetEntityMoveType(client) == MOVETYPE_LADDER ||
        GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
    {
        return false;
    }

    float now = GetEngineTime();
    if (now < g_AiTanks[client].obstacleJumpCooldownUntil)
        return false;
    if (g_AiTanks[client].obstacleJumpEntity != blocker)
    {
        g_AiTanks[client].obstacleJumpEntity = blocker;
        g_AiTanks[client].obstacleJumpAttempts = 0;
    }
    if (g_AiTanks[client].obstacleJumpAttempts >= g_cvStuckObstacleJumpAttempts.IntValue)
        return false;

    float direction[3];
    if (!getTankObstacleDirection(client, pos, targetPos, direction))
        return false;

    float velocity[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);
    float forwardSpeed = getVectorLength2D(velocity);
    if (forwardSpeed < 220.0)
        forwardSpeed = 220.0;
    if (g_cvBhopMaxSpeed.FloatValue >= 220.0 && forwardSpeed > g_cvBhopMaxSpeed.FloatValue)
        forwardSpeed = g_cvBhopMaxSpeed.FloatValue;

    float jumpVelocity[3];
    jumpVelocity[0] = direction[0] * forwardSpeed;
    jumpVelocity[1] = direction[1] * forwardSpeed;
    jumpVelocity[2] = g_cvStuckObstacleJumpSpeed.FloatValue;

    float landingTime;
    if (!canTankJumpOverObstacle(client, pos, jumpVelocity, landingTime))
        return false;

    g_AiTanks[client].obstacleJumpAttempts++;
    float jumpControlTime = landingTime + 0.05;
    if (jumpControlTime < g_cvStuckObstacleJumpDuration.FloatValue)
        jumpControlTime = g_cvStuckObstacleJumpDuration.FloatValue;
    g_AiTanks[client].obstacleJumpUntil = now + jumpControlTime;
    g_AiTanks[client].obstacleJumpCooldownUntil = now + g_cvStuckObstacleJumpCooldown.FloatValue;
    g_AiTanks[client].stuckSince = now;
    g_AiTanks[client].stuckEntitySince = now;
    g_AiTanks[client].lastStuckEntityCheckTime = now;
    g_AiTanks[client].progressPos = pos;
    g_AiTanks[client].progressCheckTime = now;
    setTankMoveState(client, TankMoveState_Special);

    buttons &= ~(IN_ATTACK | IN_ATTACK2 | IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_LEFT | IN_RIGHT);
    cmdVel[0] = 0.0;
    cmdVel[1] = 0.0;
    cmdVel[2] = 0.0;
    if (HasEntProp(client, Prop_Send, "m_hGroundEntity"))
        SetEntPropEnt(client, Prop_Send, "m_hGroundEntity", -1);
    SetEntityFlags(client, GetEntityFlags(client) & ~FL_ONGROUND);
    float jumpStart[3];
    jumpStart = pos;
    jumpStart[2] += OBSTACLE_JUMP_TRACE_START_Z;
    TeleportEntity(client, jumpStart, NULL_VECTOR, jumpVelocity);

    if (log != null)
        log.debugAll("Tank %N jumps over foot blocking entity %d", client, blocker);
    return true;
}

bool isTankPathSpecialMove(int client)
{
    if (!hasTankPathSegment(client))
        return false;

    return g_AiTanks[client].pathSegment.m_SegmentType != TANK_SEGMENT_ON_GROUND;
}

bool handleTankSpecialMoveState(int client, const float pos[3], bool nearLadder, bool actualLadder)
{
    float now = GetEngineTime();
    if (g_AiTanks[client].moveState == TankMoveState_Recovery)
    {
        if (now < g_AiTanks[client].recoveryUntil)
            return true;
        setTankMoveState(client, TankMoveState_Native);
    }

    bool nearbyAllowed = nearLadder && (actualLadder || now >= g_AiTanks[client].ladderNearbyIgnoreUntil);
    bool specialPath = isTankPathSpecialMove(client);
    if (!nearbyAllowed && !specialPath)
    {
        if (g_AiTanks[client].moveState == TankMoveState_Special)
            setTankMoveState(client, TankMoveState_Native);
        return false;
    }

    if (g_AiTanks[client].moveState != TankMoveState_Special)
    {
        setTankMoveState(client, TankMoveState_Special);
        g_AiTanks[client].progressPos = pos;
        g_AiTanks[client].progressCheckTime = now;
    }

    // 仅仅靠近梯子时继续让权给原生 AI，但不把正常停顿当成梯子卡住。
    if (!actualLadder && !specialPath)
    {
        g_AiTanks[client].progressPos = pos;
        g_AiTanks[client].progressCheckTime = now;
        g_AiTanks[client].moveStateStart = now;
        return true;
    }

    if (!g_cvStuckDetect.BoolValue)
    {
        g_AiTanks[client].progressPos = pos;
        g_AiTanks[client].progressCheckTime = now;
        g_AiTanks[client].moveStateStart = now;
        return true;
    }

    float moved = GetVectorDistance(pos, g_AiTanks[client].progressPos);
    if (moved >= g_cvStuckMinMove.FloatValue)
    {
        g_AiTanks[client].progressPos = pos;
        g_AiTanks[client].progressCheckTime = now;
        g_AiTanks[client].moveStateStart = now;
        return true;
    }

    if (now - g_AiTanks[client].moveStateStart >= g_cvSpecialMoveTimeout.FloatValue)
    {
        invalidateTankPath(client, actualLadder ? "ladder made no progress" : "special path made no progress", true);
    }
    return true;
}

void updateTankMoveState(int client, int target, float dist)
{
    if (!isAiTank(client) || !IsValidSurvivor(target))
        return;

    float now = GetEngineTime();
    if (g_AiTanks[client].moveState == TankMoveState_Recovery)
    {
        if (now < g_AiTanks[client].recoveryUntil)
            return;
        setTankMoveState(client, TankMoveState_Native);
    }

    if (dist <= g_cvBhopMinDist.FloatValue)
    {
        setTankMoveState(client, TankMoveState_Commit);
        return;
    }

    if (g_cvPathBhopPrefer.BoolValue && hasValidTankPath(client) && !isTankPathSpecialMove(client))
    {
        setTankMoveState(client, TankMoveState_Path);
        return;
    }

    if (dist <= g_cvBhopPathFallbackDist.FloatValue)
    {
        setTankMoveState(client, TankMoveState_Direct);
        return;
    }

    setTankMoveState(client, TankMoveState_Native);
}

void invalidateTankPath(int client, const char[] reason, bool forceRequest = false)
{
    if (!isAiTank(client))
        return;

    float now = GetEngineTime();
    if (now - g_AiTanks[client].lastPathInvalidateTime < g_cvPathInvalidateCooldown.FloatValue)
        return;

    g_AiTanks[client].pathInvalidatePending = forceRequest || hasTankPathSegment(client);
    g_AiTanks[client].pathInvalidatePendingUntil = now + PATH_INVALIDATE_PENDING_TIME;

    g_AiTanks[client].lastPathInvalidateTime = now;
    g_AiTanks[client].ladderNearbyIgnoreUntil = now + 2.0;
    g_AiTanks[client].recoveryUntil = now + g_cvRecoveryTime.FloatValue;
    g_AiTanks[client].stuckCount++;
    g_AiTanks[client].stuckSince = 0.0;
    g_AiTanks[client].stuckEntity = -1;
    g_AiTanks[client].stuckEntitySince = 0.0;
    g_AiTanks[client].lastStuckEntityCheckTime = 0.0;
    g_AiTanks[client].obstacleJumpUntil = 0.0;
    g_AiTanks[client].obstacleJumpEntity = -1;
    g_AiTanks[client].obstacleJumpAttempts = 0;
    clearTankPathSnapshot(client);
    setTankMoveState(client, TankMoveState_Recovery);
    resetTankMovementOverrides(client);

    if (log != null)
        log.debugAll("Tank %N invalidated path: %s (attempt %d)", client, reason, g_AiTanks[client].stuckCount);
}

int detectTankFootBlockingEntity(int client, const float pos[3], const float targetPos[3])
{
    float direction[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", direction);
    direction[2] = 0.0;
    if (getVectorLength2D(direction) < 10.0 && hasTankPathSegment(client))
        direction = g_AiTanks[client].pathSegment.m_vecForward;
    if (getVectorLength2D(direction) < 10.0)
        MakeVectorFromPoints(pos, targetPos, direction);
    direction[2] = 0.0;
    if (NormalizeVector(direction, direction) <= 0.0)
        return -1;

    float start[3], end[3];
    start = pos;
    start[2] += 4.0;
    end = start;
    ScaleVector(direction, 42.0);
    AddVectors(end, direction, end);

    Handle trace = TR_TraceHullFilterEx(start, end, {-32.0, -32.0, 0.0}, {32.0, 32.0, 34.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
    if (!TR_DidHit(trace))
    {
        delete trace;
        return -1;
    }

    int entity = TR_GetEntityIndex(trace);
    delete trace;
    if (entity > MaxClients && IsValidEntity(entity))
        return entity;
    return -1;
}

void resetTankProgressTracking(int client, const float pos[3], float now)
{
    g_AiTanks[client].progressPos = pos;
    g_AiTanks[client].progressCheckTime = now;
    g_AiTanks[client].stuckSince = 0.0;
    g_AiTanks[client].stuckEntity = -1;
    g_AiTanks[client].stuckEntitySince = 0.0;
    g_AiTanks[client].lastStuckEntityCheckTime = 0.0;
    g_AiTanks[client].obstacleJumpEntity = -1;
    g_AiTanks[client].obstacleJumpAttempts = 0;
}

bool updateTankProgress(int client, const float pos[3], const float targetPos[3], float dist, int& buttons, float cmdVel[3])
{
    if (!isAiTank(client))
        return false;

    float now = GetEngineTime();
    if (!g_cvStuckDetect.BoolValue)
    {
        resetTankProgressTracking(client, pos, now);
        return false;
    }

    TankMoveState state = g_AiTanks[client].moveState;
    if (state != TankMoveState_Path && state != TankMoveState_Direct)
    {
        resetTankProgressTracking(client, pos, now);
        return false;
    }

    if (L4D_IsPlayerStaggering(client) || GetEntityMoveType(client) == MOVETYPE_LADDER ||
        GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
    {
        resetTankProgressTracking(client, pos, now);
        return false;
    }

    if (g_AiTanks[client].progressCheckTime <= 0.0)
    {
        g_AiTanks[client].progressPos = pos;
        g_AiTanks[client].progressCheckTime = now;
        return false;
    }
    if (now - g_AiTanks[client].progressCheckTime < g_cvStuckCheckInterval.FloatValue)
        return false;

    float moved = getVectorDistance2D(pos, g_AiTanks[client].progressPos);
    g_AiTanks[client].progressCheckTime = now;
    if (moved >= g_cvStuckMinMove.FloatValue)
    {
        resetTankProgressTracking(client, pos, now);
        return false;
    }

    bool committedToAttack = g_AiTanks[client].wasThrowing || (buttons & (IN_ATTACK | IN_ATTACK2)) != 0;
    bool expectedToMove = !committedToAttack && ((buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)) != 0 ||
        FloatAbs(cmdVel[0]) > 1.0 || FloatAbs(cmdVel[1]) > 1.0);
    if (!expectedToMove || dist < g_cvBhopMinDist.FloatValue)
    {
        resetTankProgressTracking(client, pos, now);
        return false;
    }

    if (g_AiTanks[client].stuckSince <= 0.0)
        g_AiTanks[client].stuckSince = now;
    if (now - g_AiTanks[client].stuckSince < g_cvStuckTime.FloatValue)
        return false;

    if (g_cvStuckEntityCheck.BoolValue && now - g_AiTanks[client].lastStuckEntityCheckTime >= g_cvStuckEntityInterval.FloatValue)
    {
        g_AiTanks[client].lastStuckEntityCheckTime = now;
        int blockedEntity = detectTankFootBlockingEntity(client, pos, targetPos);
        if (blockedEntity > 0)
        {
            if (g_AiTanks[client].stuckEntity != blockedEntity)
            {
                g_AiTanks[client].stuckEntity = blockedEntity;
                g_AiTanks[client].stuckEntitySince = now;
            }
            else if (now - g_AiTanks[client].stuckEntitySince >= g_cvStuckEntityTime.FloatValue)
            {
                if (tryTankObstacleJump(client, blockedEntity, pos, targetPos, buttons, cmdVel))
                    return true;
                invalidateTankPath(client, "foot blocking entity");
                return false;
            }
        }
        else
        {
            g_AiTanks[client].stuckEntity = -1;
            g_AiTanks[client].stuckEntitySince = 0.0;
            g_AiTanks[client].obstacleJumpEntity = -1;
            g_AiTanks[client].obstacleJumpAttempts = 0;
        }
    }

    // 实体检测有自己的持续时间阈值；在确认实体消失或跳跃/寻路处理完成前，
    // 不要被下面的通用“无进展”分支提前失效路径。
    if (g_cvStuckEntityCheck.BoolValue && g_AiTanks[client].stuckEntity > 0)
        return false;

    if (hasTankPathSegment(client))
        invalidateTankPath(client, "no movement on path");
    else
    {
        g_AiTanks[client].recoveryUntil = now + g_cvRecoveryTime.FloatValue;
        setTankMoveState(client, TankMoveState_Recovery);
        resetTankMovementOverrides(client);
    }
    return false;
}

static bool isClientDownState(int client)
{
    return IsClientIncapped(client) || IsClientHanging(client);
}

void handleHeadBlock(int tank, int target, const float tankPos[3], const float targetPos[3])
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return;
    if (isClientDownState(target))
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return;
    }

    float targetMins[3], tankMaxs[3];
    GetClientMins(target, targetMins);
    GetClientMaxs(tank, tankMaxs);

    float targetFootZ = targetPos[2] + targetMins[2];
    float tankHeadZ   = tankPos[2] + tankMaxs[2];
    float verticalDiff = targetFootZ - tankHeadZ;
    if (verticalDiff < g_cvHeadBlockVertical.FloatValue)
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return;
    }

    float dx = targetPos[0] - tankPos[0];
    float dy = targetPos[1] - tankPos[1];
    float horizontalDiff = SquareRoot(dx * dx + dy * dy);
    if (horizontalDiff > g_cvHeadBlockHorizontal.FloatValue)
    {
        g_AiTanks[tank].headBlockStart = 0.0;
        return;
    }

    float now = GetEngineTime();
    if (g_AiTanks[tank].headBlockStart <= 0.0)
    {
        g_AiTanks[tank].headBlockStart = now;
        return;
    }

    if ((now - g_AiTanks[tank].headBlockStart) < g_cvHeadBlockTime.FloatValue)
        return;

    g_AiTanks[tank].headBlockStart = 0.0;
    g_fHeadBlockIgnoreUntil[target] = now + g_cvHeadBlockIgnoreTime.FloatValue;
    if (log != null)
        log.debugAll("%N flagged %N for head blocking (v=%.1f h=%.1f)", tank, target, verticalDiff, horizontalDiff);
}

void handleForceRock(int tank, int& buttons, const float tankPos[3])
{
    if (!g_cvHeadBlockEnable.BoolValue)
        return;

    float now = GetEngineTime();
    if (g_AiTanks[tank].forceRockUntil <= now)
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        return;
    }

    int rockTarget = GetClientOfUserId(g_AiTanks[tank].forceRockTarget);
    if (!IsValidSurvivor(rockTarget) || !IsPlayerAlive(rockTarget))
    {
        g_AiTanks[tank].forceRockUntil = 0.0;
        g_AiTanks[tank].forceRockTarget = -1;
        return;
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
        return;
    }

    float needDistance = g_cvHeadBlockForceRockRange.FloatValue;
    if (horizontal < needDistance)
        return;

    bool visible = clientIsVisibleToClient(tank, rockTarget);
    if (!visible)
    {
        float eyeTarget[3];
        GetClientEyePosition(rockTarget, eyeTarget);
        visible = L4D2_IsVisibleToPlayer(tank, TEAM_INFECTED, 0, 0, eyeTarget);
    }
    if (!visible)
        return;

    buttons |= IN_ATTACK2;
    g_AiTanks[tank].forceRockUntil = 0.0;
    g_AiTanks[tank].forceRockTarget = -1;
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
        if (isSurvivorIgnored(i))
            continue;

        bool down = isClientDownState(i);
        if (!down)
            allOthersDown = false;

        float pos[3];
        GetClientAbsOrigin(i, pos);
        float dist = GetVectorDistance(tankPos, pos);

        if (!down)
        {
            if (dist < bestStandingDist)
            {
                bestStandingDist = dist;
                bestStanding = i;
            }
        }
        else
        {
            if (dist < bestDownDist)
            {
                bestDownDist = dist;
                nearestDown = i;
            }
        }
    }

    if (bestStanding != -1)
        return bestStanding;
    if (nearestDown != -1)
        return nearestDown;

    allOthersDown = false;
    return -1;
}

bool trySwitchHeadBlockTarget(int tank, int blockedTarget, bool updateVictimOnly)
{
    if (!g_cvHeadBlockEnable.BoolValue || !isAiTank(tank) || !IsValidSurvivor(blockedTarget))
        return false;
    if (!isSurvivorIgnored(blockedTarget))
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

    g_AiTanks[tank].target = chaseUserId;

    if (!updateVictimOnly)
    {
        float cooldown = g_cvHeadBlockSwitchCooldown.FloatValue;
        if (cooldown <= 0.0 || now - g_AiTanks[tank].lastHeadBlockTargetSwitch >= cooldown)
        {
            Logic_RunScript(COMMANDABOT_ATTACK, GetClientUserId(tank), chaseUserId);
            g_AiTanks[tank].lastHeadBlockTargetSwitch = now;
        }
    }

    if (log != null)
        log.debugAll("%N switched head-block target from %N to %N", tank, blockedTarget, chaseTarget);

    return true;
}

// 确保目标缓存一致并处理反卡逻辑
public Action L4D2_OnChooseVictim(int client, int &curTarget)
{
    if (!isAiTank(client) || !IsValidSurvivor(curTarget))
        return Plugin_Continue;

    float now = GetEngineTime();

    int blockedClient = curTarget;

    if (isSurvivorIgnored(blockedClient))
    {
        bool allOthersDown = false;
        int nearestDown = -1;
        int alternative = findAlternativeVictim(client, blockedClient, allOthersDown, nearestDown);
        if (alternative > 0)
        {
            if (allOthersDown)
            {
                int moveTarget = (nearestDown > 0) ? nearestDown : blockedClient;
                if (moveTarget > 0)
                    curTarget = moveTarget;

                int chaseUserId = GetClientUserId(curTarget);
                if (chaseUserId > 0)
                    g_AiTanks[client].target = chaseUserId;

                int blockedUserId = GetClientUserId(blockedClient);
                if (blockedUserId > 0)
                {
                    g_AiTanks[client].forceRockTarget = blockedUserId;
                    g_AiTanks[client].forceRockUntil = now + g_cvHeadBlockForceRockTime.FloatValue;
                }
                else
                {
                    g_AiTanks[client].forceRockTarget = -1;
                    g_AiTanks[client].forceRockUntil = 0.0;
                }
            }
            else
            {
                curTarget = alternative;
                g_AiTanks[client].target = GetClientUserId(curTarget);
                g_AiTanks[client].forceRockTarget = -1;
                g_AiTanks[client].forceRockUntil = 0.0;
            }

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
    if (!isAiTank(attacker) || !IsValidSurvivor(victim))
        return Plugin_Continue;

    if (trySwitchHeadBlockTarget(attacker, victim, true))
    {
        int switchedTarget = GetClientOfUserId(g_AiTanks[attacker].target);
        if (IsValidSurvivor(switchedTarget) && switchedTarget != victim)
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

    float nextAtk = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
    float now = GetGameTime();
    if (g_AiTanks[client].nextAttackTime <= now && nextAtk > now)
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

    if (g_AiTanks[client].moveState == TankMoveState_Special ||
        g_AiTanks[client].moveState == TankMoveState_Recovery ||
        g_AiTanks[client].moveState == TankMoveState_Commit)
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

    bool pathPreferred = g_cvPathBhopPrefer.BoolValue &&
        hasValidTankPath(client) && !isTankPathSpecialMove(client);

    if (IsClientOnGround(client))
    {
        if (!g_cvBhopNoVision.BoolValue && !visible)
            return Plugin_Continue;

        if (pathPreferred)
        {
            bool pathHandled = false;
            Action pathBhop = tryPathGroundBhop(client, buttons, pos, vel, visible, pathHandled);
            if (pathHandled)
                return pathBhop;
        }

        if (!nextTickPosCheck(client, visible))
            return Plugin_Continue;

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

    if (g_AiTanks[client].bhopType == TankBhopType_Path)
    {
        Action pathAir = tryPathAirCorrection(client, pos, vAbsVelVec, vel);
        if (pathAir != Plugin_Continue)
            return pathAir;
    }

    // 空中矫正：角度在 [min, max] 内
    float vAbsVelVecCpy[3]; vAbsVelVecCpy = vAbsVelVec;
    NormalizeVector(vAbsVelVec, vAbsVelVec);
    float vDir2[3];
    MakeVectorFromPoints(pos, targetPos, vDir2);
    NormalizeVector(vDir2, vDir2);
    vAbsVelVec[2] = 0.0; vDir2[2] = 0.0;

    float dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
    float dz = targetPos[2] - pos[2];
    if (dx <= 1.0)
        return Plugin_Continue;
    float pitch = RadToDeg(ArcTangent(dz / dx));
    if (dz > (JUMP_HEIGHT + TANK_HEIGHT + g_fTankSwingRange) && pitch > 45.0)
        return Plugin_Continue;

    float angle = RadToDeg(ArcCosine(GetVectorDotProduct(vAbsVelVec, vDir2)));
    bool inAngleRange = (angle >= g_cvAirVecModifyDegree.FloatValue && angle <= g_cvAirVecModifyMaxDegree.FloatValue);
    bool notPressBack = !(buttons & IN_BACK);
    bool delayExpired = (GetEngineTime() - g_AiTanks[client].lastAirVecModifyTime) > g_cvAirVecModifyInterval.FloatValue;

    if (visible && inAngleRange && notPressBack && delayExpired)
    {
        NormalizeVector(vDir2, vDir2);
        if (vel < g_AiTanks[client].lastHopSpeed)
            vel = g_AiTanks[client].lastHopSpeed;
        ScaleVector(vDir2, vel);
        vDir2[2] = vAbsVelVecCpy[2];
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vDir2);
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
        return Plugin_Continue;

    float vFwd[3];
    MakeVectorFromPoints(pos, lookAheadPos, vFwd);
    vFwd[2] = 0.0;
    NormalizeVector(vFwd, vFwd);
    ScaleVector(vFwd, speed + g_cvBhopImpulse.FloatValue);

    if (!nextTickVelocityCheck(client, vFwd, visible))
        return Plugin_Continue;

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
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vFwd);
    return Plugin_Changed;
}

Action tryPathAirCorrection(int client, const float pos[3], const float vAbsVelVec[3], float speed)
{
    if (!hasValidTankPath(client) || isNullVector(g_AiTanks[client].airCorrGoal))
        return Plugin_Continue;

    float goal[3];
    goal = g_AiTanks[client].airCorrGoal;

    float vVel2D[3];
    vVel2D = vAbsVelVec;
    vVel2D[2] = 0.0;

    float vDir[3];
    MakeVectorFromPoints(pos, goal, vDir);
    vDir[2] = 0.0;

    float d2Goal = getVectorDistance2D(pos, goal);
    float dotToGoal = calcVectorAngle2D(vVel2D, vDir);
    bool needLookAhead = d2Goal < PATH_GOAL_TOLERANCE_DIST || dotToGoal > 90.0 || floatIsNan(dotToGoal);
    float now = GetEngineTime();

    if (needLookAhead && now - g_AiTanks[client].lastLookAheadTime > 0.1)
    {
        float newGoal[3];
        float maxEstimateDist = getVectorLength2D(vAbsVelVec) * getTankJumpAirTime();
        if (maxEstimateDist < PATH_LOOKAHEAD_MIN_DIST)
            maxEstimateDist = PATH_LOOKAHEAD_MIN_DIST;

        if (getTankLookAheadGoalPos(client, pos, maxEstimateDist, newGoal, g_cvPathLookAheadMaxDepth.IntValue))
        {
            goal = newGoal;
            g_AiTanks[client].airCorrGoal = newGoal;
            MakeVectorFromPoints(pos, goal, vDir);
            vDir[2] = 0.0;
            d2Goal = getVectorDistance2D(pos, goal);
            dotToGoal = calcVectorAngle2D(vVel2D, vDir);
        }

        g_AiTanks[client].lastLookAheadTime = now;
    }

    if (d2Goal <= PATH_GOAL_TOLERANCE_DIST)
        return Plugin_Continue;

    bool inAngleRange = (dotToGoal >= g_cvAirVecModifyDegree.FloatValue && dotToGoal <= g_cvAirVecModifyMaxDegree.FloatValue);
    bool delayExpired = (now - g_AiTanks[client].lastAirVecModifyTime) > g_cvAirVecModifyInterval.FloatValue;
    if (!inAngleRange || !delayExpired)
        return Plugin_Continue;

    NormalizeVector(vDir, vDir);
    if (speed < g_AiTanks[client].lastHopSpeed)
        speed = g_AiTanks[client].lastHopSpeed;
    ScaleVector(vDir, speed);
    vDir[2] = vAbsVelVec[2];

    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vDir);
    g_AiTanks[client].lastAirVecModifyTime = now;
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
    if (!isAiTank(client)) return false;

    float vMins[3], vMaxs[3];
    GetClientMins(client, vMins);
    GetClientMaxs(client, vMaxs);

    float pos[3], endPos[3], velVec[3];
    GetClientAbsOrigin(client, pos);
    velVec = velocity;
    float vel = GetVectorLength(velVec);
    if (vel <= 1.0)
        return false;
    NormalizeVector(velVec, velVec);

    ScaleVector(velVec, vel + FloatAbs(vMaxs[0] - vMins[0]) + 3.0);
    AddVectors(pos, velVec, endPos);
    pos[2]     += 10.0;
    endPos[2]  += 10.0;

    Handle hTrace = TR_TraceHullFilterEx(pos, endPos, {-36.0, -36.0, 10.0}, {36.0, 36.0, 72.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
    if (TR_DidHit(hTrace))
    {
        float hitNormal[3];
        TR_GetPlaneNormal(hTrace, hitNormal);
        NormalizeVector(hitNormal, hitNormal);
        NormalizeVector(velVec, velVec);
        if (RadToDeg(ArcCosine(GetVectorDotProduct(hitNormal, velVec))) > 165.0)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;

    if (!visible)
    {
        float eyeAng[3], dir[3];
        GetClientEyeAngles(client, eyeAng);
        GetAngleVectors(eyeAng, dir, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(dir, dir);
        NormalizeVector(velVec, velVec);
        dir[2] = velVec[2] = 0.0;
        float ang = RadToDeg(ArcCosine(GetVectorDotProduct(dir, velVec)));
        if (floatIsNan(ang) || ang > g_cvBhopNoVisionMaxAng.FloatValue)
            return false;
    }

    float downPos[3]; downPos = endPos; downPos[2] -= 99999.0;
    hTrace = TR_TraceHullFilterEx(endPos, downPos, {-16.0, -16.0, 0.0}, {16.0, 16.0, 0.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
    if (!TR_DidHit(hTrace))
    {
        delete hTrace;
        return false;
    }
    int hitEnt = TR_GetEntityIndex(hTrace);
    if (IsValidEntity(hitEnt))
    {
        char className[32];
        GetEntityClassname(hitEnt, className, sizeof(className));
        if (strcmp(className, "trigger_hurt", false) == 0)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;
    return true;
}

bool hasTankPathSegment(int client)
{
    if (!isAiTank(client))
        return false;

    return (
        g_AiTanks[client].pathSegmentCount > 0 &&
        g_AiTanks[client].pathUpdateTime > 0.0 &&
        GetEngineTime() - g_AiTanks[client].pathUpdateTime <= PATH_CACHE_MAX_AGE &&
        g_AiTanks[client].pathSegment.m_pPathSegment != Address_Null
    );
}

bool hasValidTankPath(int client)
{
    if (!hasTankPathSegment(client))
        return false;

    return g_AiTanks[client].lastPathSegment.m_pPathSegment != Address_Null &&
        g_AiTanks[client].pathSegment.m_pPathSegment != g_AiTanks[client].lastPathSegment.m_pPathSegment;
}

void constructPathSegment(Address pPathSegment, PathSegment segment)
{
    if (!pPathSegment)
    {
        segment.initData();
        return;
    }

    segment.m_pPathSegment = pPathSegment;
    segment.m_pNavArea = view_as<Address>(LoadFromAddress(pPathSegment, NumberType_Int32));
    segment.m_iNavTraverseType = view_as<int>(LoadFromAddress(pPathSegment + view_as<Address>(4), NumberType_Int32));
    segment.m_vecGoalPos[0] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(8), NumberType_Int32));
    segment.m_vecGoalPos[1] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(12), NumberType_Int32));
    segment.m_vecGoalPos[2] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(16), NumberType_Int32));
    segment.m_SegmentType = view_as<int>(LoadFromAddress(pPathSegment + view_as<Address>(24), NumberType_Int32));
    segment.m_vecForward[0] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(28), NumberType_Int32));
    segment.m_vecForward[1] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(32), NumberType_Int32));
    segment.m_vecForward[2] = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(36), NumberType_Int32));
    segment.m_flLength = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(40), NumberType_Int32));
    segment.m_flDistFromStart = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(44), NumberType_Int32));
}

bool getTankLookAheadGoalPos(int client, const float pos[3], float maxDist, float outPos[3], int maxDepth = 10)
{
    if (!hasValidTankPath(client))
        return false;

    int cacheCount = g_AiTanks[client].pathSegmentCount;
    if (cacheCount < 1)
        return false;

    int iterIndex = 0;
    PathSegment iterSeg;
    iterSeg = g_TankPathCache[client][iterIndex];
    if (iterSeg.m_pPathSegment == Address_Null)
        return false;
    if (iterSeg.m_SegmentType != TANK_SEGMENT_ON_GROUND)
        return false;

    float pos2D[3];
    pos2D = pos;
    pos2D[2] = 0.0;

    for (int i = 0; i < maxDepth && iterIndex + 1 < cacheCount; i++)
    {
        PathSegment nextSeg;
        nextSeg = g_TankPathCache[client][iterIndex + 1];
        if (nextSeg.m_SegmentType != TANK_SEGMENT_ON_GROUND)
            break;

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
            if (nextSeg.m_pPathSegment == g_AiTanks[client].lastPathSegment.m_pPathSegment)
                return false;
            iterIndex++;
            iterSeg = nextSeg;
            continue;
        }

        float proj = GetVectorDotProduct(curToNext, curToTank) / lenSqr;
        if (proj >= 1.0)
        {
            if (nextSeg.m_pPathSegment == g_AiTanks[client].lastPathSegment.m_pPathSegment)
                return false;
            iterIndex++;
            iterSeg = nextSeg;
            continue;
        }
        if (proj >= 0.5)
        {
            iterIndex++;
            iterSeg = nextSeg;
        }

        break;
    }

    float lastVisPos[3];
    lastVisPos = iterSeg.m_vecGoalPos;

    float start[3];
    GetClientAbsOrigin(client, start);
    start[2] += 36.0;

    int fwdCount = 0;
    for (int i = 0; i < maxDepth && iterIndex < cacheCount; i++)
    {
        float goal[3], endPos[3];
        goal = iterSeg.m_vecGoalPos;
        endPos = goal;
        endPos[2] += 36.0;

        Handle hTrace = TR_TraceHullFilterEx(start, endPos, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
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

        iterIndex++;
        if (iterIndex >= cacheCount)
            break;
        iterSeg = g_TankPathCache[client][iterIndex];
        if (iterSeg.m_SegmentType != TANK_SEGMENT_ON_GROUND)
            break;
    }

    if (fwdCount < 1)
        return false;

    outPos = lastVisPos;
    return true;
}

float getTankJumpAirTime()
{
    ConVar cvGravity = FindConVar("sv_gravity");
    float gravity = (!cvGravity) ? DEFAULT_SV_GRAVITY : cvGravity.FloatValue;
    return SquareRoot((JUMP_HEIGHT * 2.0) / gravity) * 2.0;
}

float getVectorLength2D(const float vec[3])
{
    return SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
}

float getVectorDistance2D(const float vec1[3], const float vec2[3])
{
    return SquareRoot(Pow(vec1[0] - vec2[0], 2.0) + Pow(vec1[1] - vec2[1], 2.0));
}

float calcVectorAngle2D(const float vec1[3], const float vec2[3])
{
    float v1[3], v2[3];
    v1 = vec1;
    v2 = vec2;
    v1[2] = 0.0;
    v2[2] = 0.0;

    NormalizeVector(v1, v1);
    NormalizeVector(v2, v2);

    float dot = GetVectorDotProduct(v1, v2);
    if (dot > 1.0) dot = 1.0;
    else if (dot < -1.0) dot = -1.0;
    return RadToDeg(ArcCosine(dot));
}

bool isNullVector(const float vec[3])
{
    return vec[0] == 0.0 && vec[1] == 0.0 && vec[2] == 0.0;
}

// ===== 玩家进服：启用动画钩子 & 梯子常驻维护 =====
public void OnClientPutInServer(int client)
{
    resetTankClientState(client, true);
    ensureTankAnimHook(client);
}

public void OnClientDisconnect(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    resetTankClientState(client, true);
    g_bAnimHooked[client] = false;
}

// ===== 动画后置钩子：识别投石序列并触发相应逻辑 =====
Action tankAnimHookPostCb(int tank, int &sequence)
{
    if (!isAiTank(tank))
        return Plugin_Continue;

    if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        if (!g_AiTanks[tank].wasThrowing)
        {
            g_AiTanks[tank].wasThrowing = true;
            if (g_cvJumpRock.BoolValue)
                makeTankJumpRock(tank);
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
    if (g_AiTanks[tank].obstacleJumpUntil > GetEngineTime()) return;

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
        if (tank > 0)
            g_AiTanks[tank].wasThrowing = false;
        return Plugin_Stop;
    }

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

    if (dist < g_cvThrowMinDist.FloatValue || dist > g_cvThrowMaxDist.FloatValue)
        buttons &= ~IN_ATTACK2;

    return Plugin_Changed;
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

    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    switch (animSeq)
    {
        case L4D2_ACT_SIGNAL3: { pos[2] += THROW_UNDERHEAD_POS_Z; }
        case L4D2_ACT_SIGNAL2: { pos[2] += THROW_OVERSHOULDER_POS_Z; }
        case L4D2_ACT_SIGNAL_ADVANCE: { pos[2] += THROW_OVERHEAD_POS_Z; }
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
