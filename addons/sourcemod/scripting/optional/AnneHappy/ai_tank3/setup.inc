#if defined _ai_tank3_setup_included
    #endinput
#endif
#define _ai_tank3_setup_included

// =========================================================================
// 常量
// =========================================================================
#define CVAR_FLAGS                      FCVAR_NONE
#define PLUGIN_PREFIX                   "Ai-Tank3"
#define GAMEDATA                        "l4d2_ai_tank3"

#define DEFAULT_THROW_FORCE             800.0
#define DEFAULT_SV_GRAVITY              800.0
#define DEFAULT_SWING_RANGE             56.0
#define DEFAULT_TANK_RUN_SPEED          210.0

#define PLAYER_CHEST                    52.0
#define TANK_HEIGHT                     84.0
#define JUMP_HEIGHT                     56.0
#define JUMP_SPEED_Z                    300.0   // 跳砖时给的 Z 轴速度
#define HULL_CENTER_HEIGHT              36.0
#define TANK_AIR_THINK_INTERVAL          0.05
#define TANK_AIR_GROUND_SEARCH           128.0
#define TANK_AIR_TRACE_STEP              0.10
#define TANK_HOP_MAX_DROP                256.0  // 路径明确且完整落点检查通过时，可连续跳下的普通落差

// 路径快照（anne_nextbot）
#define PATH_STALE_TIME                 0.35    // 快照超过这个年龄视为过期，回退到实体梯子检测
#define PATH_SCAN_MAX_SEGMENTS          32      // 每 tick 最多向前扫描的路径段数
#define PATH_GOAL_TOLERANCE_DIST        25.0
#define PATH_LOOKAHEAD_MIN_DIST         150.0
#define PATH_LOOKAHEAD_MIN_GOAL_DIST    32.0    // 前瞻点太近时方向不可靠，不拿来当连跳方向
#define PATH_LOOKAHEAD_MAX_CANDIDATES   16
#define PATH_LOOKAHEAD_TRACE_BUDGET     3       // 每 tick 每只 Tank 独立的前瞻 hull trace 次数
#define PATH_REACH_TARGET_MIN_2D        150.0   // 路径终点离目标多近算“路径走得到目标”
#define PATH_REACH_TARGET_RATIO         0.35    // 远距离按直线距离比例放宽，ChasePath 会给移动目标带提前量
#define PATH_REACH_TARGET_Z             72.0

// 梯子
#define LADDER_CACHE_DEFAULT            0.20
#define LADDER_Z_TOLERANCE              72.0    // 实体梯子检测：高度超出梯子包围盒上下这么多不算附近
#define LADDER_NAV_SEARCH_DIST          64.0
#define LADDER_LOOK_MARGIN              48.0    // 锁视角时必须贴在这架梯子包围盒这么近的范围内
#define LADDER_LOOK_Z_TOLERANCE         16.0
#define LADDER_LOOK_ALIGN_DEG           8.0     // 爬梯朝向已足够接近时不再改视角
#define LADDER_SPEED_BLEED_RATIO        1.10    // 梯子窗口内水平速度超过跑速的这个倍数就压回跑速
#define LADDER_HOP_MARGIN               64.0    // 连跳落点至少停在特殊路径段起点前这么远
#define LADDER_VICTIM_FREEZE            0.75    // 梯子窗口内冻结换目标的续期

// 目标
#define VISIBILITY_CACHE_TIME           0.10
#define TARGET_TRAVEL_CACHE_TIME        0.5     // 走得到的人，绕路系数隔这么久重算一次
#define TARGET_TRAVEL_UNREACHABLE_RETRY 1.0     // 走不到/没有 nav 的人结果很少变化，重算间隔放长
#define TARGET_TRAVEL_UNKNOWN           -2.0
#define TARGET_TRAVEL_UNREACHABLE       -1.0
#define TARGET_TRAVEL_MAX_SEARCH        3000.0  // 分档寻路估距的封顶长度，超过按走不到计分
// 分档命中后在“上一档走不通、这一档走得通”的区间里二分，直到区间不宽于这个值（最多 REFINE_STEPS 次），取中点。
// 单人误差不超过它的一半，两人得分之差的误差不超过它本身，所以 ai_tank3_target_switch_gain 要比它大，估距噪声才不会自己触发换目标
#define TARGET_TRAVEL_PRECISION         64.0
#define TARGET_TRAVEL_REFINE_STEPS      4
#define TARGET_UNREACHABLE_PENALTY      1500.0
#define TARGET_VOMIT_SCORE_MULT         2.0     // 对应 target_override 的 order 2：被喷的人排在正常生还者后面，倍率越大越靠后
#define TARGET_PINNED_MASK_DEFAULT      14      // target_override 未加载时的默认口径：忽略被猎人/猴子/牛控的人
#define TARGET_INCAP_MODE_DEFAULT       0

#define TARGET_TIER_NONE                0
#define TARGET_TIER_REGULAR             1
#define TARGET_TIER_FALLBACK            2

// 头顶卡 / 骑头
#define HEAD_BLOCK_PROGRESS_DIST        32.0    // 停滞窗口内移动超过该距离视为仍在正常寻路
#define HEAD_BLOCK_ROUTE_UP_MULT        3.0     // 路径能经梯子/攀爬走到目标时，停滞判定时间放大倍数
#define RIDE_CHECK_CACHE                0.10
#define RIDE_AABB_SLACK                 8.0

// 强制投石 / 撤离
#define FORCE_ROCK_RETREAT_MARGIN       48.0
#define FORCE_ROCK_MIN_HORIZONTAL       96.0    // 水平距离太近时原地上抛无效
#define ROCK_PENDING_HOLD_TIME          1.5     // 按下攻击2后等待出手的最长时间
#define RETREAT_MAX_ATTEMPTS            3
#define RETREAT_RETRY_INTERVAL          1.0
#define RETREAT_MIN_TIMEOUT             0.5
#define RETREAT_STALL_TIME              1.5
#define RETREAT_STALL_DIST              16.0
#define RETREAT_NAV_SEARCH_DIST         160.0
#define RETREAT_MAX_Z_DIFF              72.0
#define RETREAT_LADDER_CLEARANCE        96.0
#define RETREAT_TRAVEL_RATIO            2.5

// 投石序列（post 动画钩子给的是模型 m_nSequence，L4D2 Tank 投石固定为 48-51）
#define TANK_THROW_SEQUENCE_MIN         48
#define TANK_THROW_SEQUENCE_MAX         51
#define THROW_STATE_POLL_INTERVAL       0.5

float g_fRetreatYawOffsets[] = {0.0, 40.0, -40.0, 80.0, -80.0};
float g_fTravelBucketRatios[] = {1.15, 1.5, 2.25, 3.5, 6.0, 10.0};

// =========================================================================
// ConVar
// =========================================================================
ConVar
    g_cvPluginName,
    g_cvLogLevel,
    g_cvEnable,
    // 连跳
    g_cvTankBhop,
    g_cvBhopMinDist,
    g_cvBhopMaxDist,
    g_cvBhopMinSpeed,
    g_cvBhopMaxSpeed,
    g_cvBhopImpulse,
    g_cvBhopFirstHopRatio,
    g_cvBhopNoVision,
    g_cvBhopNoVisionMaxAng,
    g_cvPathLookAheadMaxDepth,
    g_cvDirectChaseMaxAngle,
    g_cvBhopStrafeAngle,
    g_cvBhopStrafeMinDist,
    g_cvBhopReverseHop,
    g_cvBhopReverseBrake,
    // 空中修正
    g_cvAirVecModifyDegree,
    g_cvAirVecModifyMaxDegree,
    g_cvAirVecModifyInterval,
    // 投石 / 挥拳
    g_cvThrowMinDist,
    g_cvThrowMaxDist,
    g_cvRockTargetAdjust,
    g_cvJumpRock,
    g_cvBackFist,
    g_cvBackFistRange,
    g_cvBackFistAllowMaxSpd,
    g_cvBackFistWindow,
    g_cvPunchLockVision,
    // 目标选择
    g_cvTargetSelect,
    g_cvTargetSwitchRatio,
    g_cvTargetSwitchGain,
    g_cvTargetCommitTime,
    g_cvTargetDecisiveRatio,
    // 反头顶卡 / 骑头 / 强制投石
    g_cvHeadBlockEnable,
    g_cvHeadBlockTime,
    g_cvHeadBlockVertical,
    g_cvHeadBlockHorizontal,
    g_cvHeadBlockIgnoreTime,
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
    g_cvRetreatTimeout,
    // 梯子
    g_cvLadderLookLock,
    g_cvLadderNearbyDisable,
    g_cvLadderNearbyRadius,
    g_cvLadderNearbyCacheTime;

ConVar g_cvTankSwingRange;

// =========================================================================
// 结构体
// =========================================================================
enum TankHopMode
{
    TankHop_None,
    TankHop_Target,     // 有视野、同一高度、路径方向与目标一致：朝目标预测点连跳
    TankHop_Path,       // 沿 NextBot 路径前瞻点连跳
    TankHop_Velocity    // 无视野且没有路径快照：沿当前速度方向连跳（旧行为兜底）
}

enum TankRockReason
{
    TankRock_None,
    TankRock_HeadBlock, // 够不着的高台停滞：拉开距离后投石
    TankRock_Riding     // 骑头且拳打不到：原地投石
}

// 每 tick 从路径快照里提炼一次的摘要
enum struct TankPathInfo
{
    int   tick;
    float time;
    bool  fresh;            // 快照可用且未过期
    int   count;
    int   currentIndex;
    bool  complete;
    float ladderDist;       // 沿路径到最近梯子段入口的距离，-1 = 扫描范围内没有
    float blockHopDist;     // 沿路径到最近“不能被连跳越过”的特殊段起点的距离，-1 = 没有
    float dropDist;         // 最近深下落段入口，用于落点验证及禁止边沿蛇形/跳砖
    float dropLandingZ;
    bool  routeUp;          // 扫描范围内有向上的梯子/攀爬段
    bool  reachesTarget;    // 路径终点接近当前目标

    void Reset()
    {
        this.tick = -1;
        this.time = 0.0;
        this.fresh = false;
        this.count = 0;
        this.currentIndex = -1;
        this.complete = false;
        this.ladderDist = -1.0;
        this.blockHopDist = -1.0;
        this.dropDist = -1.0;
        this.dropLandingZ = 0.0;
        this.routeUp = false;
        this.reachesTarget = false;
    }
}

enum struct TankState
{
    int   userId;               // 状态所属 Tank 的 userid，换人时整体重置

    // 目标
    int   victim;               // 插件视角的当前目标(userid)
    float victimSince;          // 最近一次换目标时间
    float victimFreezeUntil;    // 梯子/攀爬期间冻结换目标
    int   travelUser[MAXPLAYERS + 1];
    float travelRatio[MAXPLAYERS + 1];   // 寻路距离 / 直线距离，或 TARGET_TRAVEL_UNKNOWN / UNREACHABLE
    float travelTime[MAXPLAYERS + 1];
    int   ignoreUser[MAXPLAYERS + 1];
    float ignoreUntil[MAXPLAYERS + 1];
    int   visUser;
    float visTime;
    bool  visResult;

    // 移动
    TankHopMode hopMode;
    float nextAirThink;
    float hopStrafeYaw;         // 本跳的侧向偏角，空中不随机翻转
    int   lastStrafeSide;       // 确认落地后的下一跳才换边
    float ladderCheckTime;
    bool  ladderNear;

    // 头顶卡
    int   headBlockUser;
    float headBlockStart;
    float headBlockOrigin[3];

    // 骑头
    int   ridingUser;
    float ridingStart;
    int   rideCheckUser[MAXPLAYERS + 1];
    float rideCheckTime[MAXPLAYERS + 1];
    bool  rideCheckResult[MAXPLAYERS + 1];

    // 强制投石
    TankRockReason rockReason;
    int   rockUser;
    float rockUntil;
    int   rockAimUser;          // 出手时用来瞄准的目标(userid)
    float rockPendingUntil;     // 插件按下攻击2后等待出手的截止时间
    int   retreatAttempts;
    float retreatLastIssue;

    // 撤离命令（BOT_CMD_MOVE）
    bool  moveActive;
    float moveDeadline;
    float moveProgressTime;
    float moveProgressPos[3];

    // 挥拳 / 投石
    float nextAttackTime;
    float backFistExpire;
    bool  throwing;

    void Reset(int userId)
    {
        this.userId = userId;
        this.victim = 0;
        this.victimSince = 0.0;
        this.victimFreezeUntil = 0.0;
        for (int i = 0; i <= MAXPLAYERS; i++)
        {
            this.travelUser[i] = 0;
            this.travelRatio[i] = TARGET_TRAVEL_UNKNOWN;
            this.travelTime[i] = 0.0;
            this.ignoreUser[i] = 0;
            this.ignoreUntil[i] = 0.0;
            this.rideCheckUser[i] = 0;
            this.rideCheckTime[i] = 0.0;
            this.rideCheckResult[i] = false;
        }
        this.visUser = 0;
        this.visTime = 0.0;
        this.visResult = false;
        this.hopMode = TankHop_None;
        this.nextAirThink = 0.0;
        this.hopStrafeYaw = 0.0;
        this.lastStrafeSide = 0;
        this.ladderCheckTime = 0.0;
        this.ladderNear = false;
        this.headBlockUser = 0;
        this.headBlockStart = 0.0;
        this.headBlockOrigin = NULL_VECTOR;
        this.ridingUser = 0;
        this.ridingStart = 0.0;
        this.rockReason = TankRock_None;
        this.rockUser = 0;
        this.rockUntil = 0.0;
        this.rockAimUser = 0;
        this.rockPendingUntil = 0.0;
        this.retreatAttempts = 0;
        this.retreatLastIssue = 0.0;
        this.moveActive = false;
        this.moveDeadline = 0.0;
        this.moveProgressTime = 0.0;
        this.moveProgressPos = NULL_VECTOR;
        this.nextAttackTime = 0.0;
        this.backFistExpire = 0.0;
        this.throwing = false;
    }
}

// =========================================================================
// 全局状态
// =========================================================================
TankState    g_Tank[MAXPLAYERS + 1];
TankPathInfo g_TankPath[MAXPLAYERS + 1];
bool         g_bAnimHooked[MAXPLAYERS + 1];

Logger    log;
Handle    g_hSdkTankClawSweepFist;
ArrayList g_hLadderNavList;
float     g_fTankSwingRange = DEFAULT_SWING_RANGE;
bool      g_bPathConsumerEnabled;
int       g_iTravelBudgetTick = -1;
int       g_iPathTraceTick[MAXPLAYERS + 1];
int       g_iPathTraceUsed[MAXPLAYERS + 1];

void State_ResetClient(int client, int userId)
{
    g_Tank[client].Reset(userId);
    g_TankPath[client].Reset();
    g_iPathTraceTick[client] = -1;
    g_iPathTraceUsed[client] = 0;
    AIPathMovement_Reset(client);
    AIPathMovement_ResetHopChain(client);
}

// 同一个客户端槽位换了 Tank（新 Bot 接管、换图、回合重开）时整体清掉旧状态，不依赖事件顺序
void State_EnsureOwner(int client)
{
    int userId = GetClientUserId(client);
    if (g_Tank[client].userId != userId)
        State_ResetClient(client, userId);
}
