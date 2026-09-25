#if defined _setup_included_
	#endinput
#endif
#define _setup_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <anne_nextbot>

// =========================================================================
// Public Defines
// =========================================================================
#define CVAR_FLAGS							FCVAR_NONE

#define GAMEDATA 							"l4d2_ai_charger3"
#define SIG_GET_RUN_TOP_SPEED 				"CTerrorPlayer::GetRunTopSpeed"
#define SIG_IS_CHARGE_BLOCKED 				"Charger::IsChargeBlocked"
#define	SIG_MY_NEXTBOT_POINTER				"CBaseEntity::MyNextBotPointer"
#define SIG_NEXTBOT_GET_LOCOMOTION			"INextBot::GetLocomotionInterface"
#define SIG_LOCOMOTION_APPROACH				"ILocomotion::Approach"
#define SIG_LOCOMOTION_FACE_TO				"ILocomotion::FaceTowards"
#define SIG_LOCOMOTION_HAS_POTENTIAL_GAP	"ILocomotion::HasPotentialGap"

#define PLAYER_HEIGHT 						72.0
#define JUMP_HEIGHT							57.0	// PlayerLocomotion::GetMaxJumpHeight 返回 57.0

#define DEFAULT_CHARGE_SPEED 				500.0
#define DEFAULT_MELEE_RANGE 				70.0
#define DEFAULT_CHARGER_CLAW_RANGE			70.0
#define DEFAULT_MELEE_DMG_CHARGER 			390
#define DEFAULT_GRAVITY 					800.0
#define DEFAULT_SURVIVOR_SPEED 				220.0
#define DROP_DOWN_THRESHOLD					200.0
#define TARGET_VULNERABLE_ADV_CHECK_DIST	250.0
#define UNAVOIDABLE_TARGET_DIST_BUFFER		120.0
#define EVADE_MOVETO_REFRESH_MIN_DIST		50.0		// 目标至少移动该距离才重建 BehaviorMoveTo, 避免微小位置抖动反复寻路
#define STATE_TOLERANCE_DIST                50.0		// 状态转换容差距离
#define BAIT_MOVE_SPEED_RAMP				40.0		// 近战博弈距离控制的比例区间, 距离误差达到该值时使用满速
#define BAIT_MOVE_MIN_SPEED_RATIO			0.35		// 近战博弈距离控制的最小速度比例, 避免误差很小时仍然满速冲刺
#define BAIT_MOVE_HOLD_TIME					0.25		// 近战博弈距离控制同一方向的最短驻留时间, 抑制方向每帧翻转
#define BAIT_MOVE_DEADZONE_DAMP				0.7			// 近战博弈死区内每帧的速度衰减系数, 代替直接把速度清零
#define BAIT_BACKHOP_LOCK_TIME				0.45		// 后跳落地后禁止距离控制立刻前进的锁定时长
#define BAIT_ORBIT_SPEED_RATIO				0.55		// 近战博弈绕圈时切向速度占跑速的比例
#define BAIT_ORBIT_FLIP_INTERVAL			0.4			// 绕圈方向被挡住后, 最短多久允许再翻一次方向
#define MELEE_SWING_WINDOW					0.2			// 近战目标挥空后摇窗口阈值 (通用 vulnerable 检查用的是 0.5, 对近战太长抓不到)
#define MELEE_STALEMATE_KEEP_GAP			2.0			// 距上次近战博弈超过该时间才重置僵持计时, Approach<->Bait 抖动不清零
#define MELEE_STALEMATE_FEINT_LIMIT			2			// 僵持升级中最多做几次诱骗
#define MELEE_FEINT_WINDOW					0.7			// 单次诱骗最长持续时间, 超时就放弃这次贴脸
#define MELEE_FEINT_COOLDOWN				1.2			// 两次诱骗之间的间隔
#define CHARGER_FORCED_TARGET_TTL			3.0			// 僵持换目标登记后, 等待 OnChooseVictim 落实的有效期
#define DEFAULT_STALEMATE_SWITCH_DIST		350.0		// 僵持换目标时的最大搜索半径 (legacy extra target 未配置时的回退值)
#define CHARGE_Z_THRESHOLD                  57.0    	// charger 冲锋时, 如果与目标的高度差超过该值, 则取消冲锋
#define MAX_PATH_SNAPSHOT_SEGMENTS          512			// 单次 PathFollower::Update 最多复制的路径节点数
#define PI									3.14159265

// =========================================================================
// ConVars
// =========================================================================
ConVar
	g_cvBhop,					// 是否允许普通连跳 (STATE APPROACH 时的连跳)
	g_cvBhopMinDist,			// 禁止连跳的最小距离
	g_cvDirectBhopDist,			// 朝着目标直线连跳的最小距离
	g_cvBhopMaxDist,			// 允许连跳的最大距离
	g_cvBhopMinSpeed,			// 允许连跳的最小速度
	g_cvBhopMaxSpeed,			// 连跳的最大速度
	g_cvBhopBeforeCharge,		// 冲锋前是否允许进行接近连跳
	g_cvBhopImpulse,			// 连跳加速度
	g_cvBhopFirstHopRatio,		// 从跑动直接起跳的第一跳可拿到的加速度比例
	g_cvBhopNoVision,			// 是否允许无视野连跳
	g_cvBhopNoVisionMaxAng,		// 无视野时自身速度方向与视角方向夹角小于这个值允许连跳
	g_cvTargetWatchMaxDeg,		// 目标视角向量与到 charger 的位置向量夹角小于这个值时认为目标正在看着 charger, 用于控制侧向连跳等
	g_cvBhopStrafeMinDist,		// 禁止侧向连跳的最小距离 (距离目标小于这个距离, 禁止侧向连跳)
	g_cvBhopStrafeMinDeg,		// 目标看着 charger 时, 连跳方向向基准方向左右偏移的最小角度
	g_cvBhopStrafeMaxDeg,		// 目标看着 charger 时, 连跳方向向基准方向左右偏移的最大角度
	g_cvBhopStrafeOnceDist,		// 左右侧向连跳一次的最小距离限制 (距离 Goal Pos 小于这个值时不允许侧向连跳)
	g_cvBhopStrafeTwiceDist,	// 左右侧向连跳两次的最小距离限制 (距离 Goal Pos 大于这个值且以当前速度一跳可达才允许左右侧向连跳两次)
	g_cvMeleeBaitZoneMinRange,	// 目标拿着近战时, 近战博弈区的最小范围, melee_range + 这个值
	g_cvMeleeBaitZoneMaxRange,	// 目标拿着近战时, 近战博弈区的最大范围, melee_range + 这个值
	g_cvAirVecModifyMinDegree,	// 在空中 charger 到目标方向向量与速度向量夹角超过这个值进行速度修正
	g_cvAirVecModifyMaxDegree,	// 在空中 charger 到目标方向向量与速度向量夹角超过这个值放弃修正
	g_cvAirVecModifyInterval,	// 空中平滑转向达到配置插值强度的基准时间
	g_cvAirVecModifyLerp,		// 空中速度修正转向插值因子
	g_cvAirTurnSpeedLoss,		// 空中实际转向 90 度时损失的水平速度比例
	g_cvAirSpeedFloorRatio,		// 空中方向修正使用的起跳保存速度下限比例
	g_cvAirTurnBudget,			// 每次离地后空中速度方向最多偏离起跳方向的角度
	g_cvBaitMaxDuration,		// charger 进入博弈状态的最长时间
	g_cvMeleeBaitOrbit,			// 近战博弈死区内是否沿切向绕圈, 代替原地急停
	g_cvMeleeBaitStalemateSwitch,	// 近战僵持升级到最后一级时是否允许换目标
	g_cvMeleeBaitBlacklistDur,	// 因近战僵持放弃目标后, 该目标进入黑名单的时长
	g_cvProbChargeChkDur,		// 概率冲锋时的检测间隔
	g_cvProbChargeProb,			// 概率冲锋的概率到达这个数值可冲锋
	g_cvAntiRetreat,			// 是否阻止 charger 逃跑
	g_cvEvadeMoveToRefreshInterval,	// ChargerEvade 生成的 BehaviorMoveTo 目标坐标刷新间隔
	g_cvPathLookAheadMaxDepth;	// 向前搜索 PathSegment 的最大深度

// ai_charger_2 兼容配置。旧配置继续使用原名称，内部转换为 3.0 的行为参数。
ConVar
	g_cvLegacyBhop,
	g_cvLegacyBhopSpeed,
	g_cvLegacyChargeDistance,
	g_cvLegacyExtraTargetDistance,
	g_cvLegacyAimOffset,
	g_cvLegacyMeleeAvoid,
	g_cvLegacyMeleeDamage,
	g_cvLegacyTarget,
	g_cvLegacyChargeHeightDiff;

float g_fLegacyExtraTargetMin;
float g_fLegacyExtraTargetMax;

// =========================================================================
// AI Charger Data
// =========================================================================

enum SegmentType {
	SegType_OnGround,
	SegType_DropDown,
	SegType_ClimbUp,
	SegType_JumpOverGap,
	SegType_LadderUp,
	SegType_LadderDown,
	SegType_Size
}

enum struct PathSegment {
	Address m_pPathSegment;			// 指向该 PathSegment 结构体的指针
	Address m_pNavArea;				// 指向该 NavArea 的指针
	int m_iNavTraverseType;			// 如何从上一个 PathSegment 到该 PathSegment 的移动方式
	float m_vecGoalPos[3];			// 目标点
	SegmentType m_SegmentType;		// 如何移动到该 PathSegment
	float m_vecForward[3];			// 路径前进方向
	float m_flLength;				// 路径长度
	float m_flDistFromStart;		// 当前 PathSegment 到起始点的距离

	void init() {
		this.m_pPathSegment = Address_Null;
		this.m_pNavArea = Address_Null;
		ZeroVector(this.m_vecGoalPos);
		ZeroVector(this.m_vecForward);
	}
}

enum StrafeDir {
	StrafeDir_None = 0,
	StrafeDir_Left = 1,
	StrafeDir_Right = -1,
	StrafeDir_Size
}

enum StrafeType {
	StrafeType_None = -1,
	StrafeType_Once,
	StrafeType_Twice,
	StrafeType_Size
}

enum struct AirStrafe {
	float m_flStrafeStartDist;	// 准备执行侧向连跳时, 计算的 Charger 当前位置到 Goal Pos 的距离
	float m_flStrafeAmp;		// 侧向连跳的振幅
	StrafeDir m_StrafeDir;		// 侧向连跳的方向
	StrafeType m_StrafeType;	// 侧向连跳的类型
	
	void init() {
		this.m_flStrafeStartDist = 0.0;
		this.m_flStrafeAmp = 0.0;
		this.m_StrafeDir = StrafeDir_None;
		this.m_StrafeType = StrafeType_None;
	}
}

enum BhopType {
	BhopType_None,
	BhopType_Path,				// 沿着 Path 进行连跳
	BhopType_DirectCandidate,	// 距离目标小于直线连跳阈值, 但还在验证路径是否安全
	BhopType_Normal,			// 朝着目标直线连跳
	BhopType_BaitRetreat,		// 近战 Bait 状态中正在执行向后跳
	BhopType_Repathing,			// 已经到达当前 Path 末尾, 正在重新找一条新的 Path (c4m2 楼梯口, 当前 Path 末端在楼梯口, 但是 Charger 应该从旁边绕过来)
	BhopType_Size
}

enum struct AiCharger {
	int m_iTarget;						// 当前目标 userId
	int m_iBetterTarget;				// 更好的目标 userId
	bool m_bChargeDelayed;				// 目前冲撞能力是否被人为延时
	bool m_bHasAirBreaked;				// 在空中时是否急停过了
	bool m_bBhopBeforeCharge;			// 冲锋之前是否进行了最后一次连跳
	bool m_bEvadeMoveCommandActive;	// ChargerEvade 是否已经下发 BOT_CMD_MOVE 追击命令
	bool m_bEvadeMoveCommandPending;	// 是否已经安排下一帧下发 BOT_CMD_MOVE
	
	float m_flLastHopSpeed;				// 上次起跳的速度
	float m_flFinalBhopStartTime;		// 冲锋前最后一次连跳开始时间, 用于短暂等待落地/进入 commit range
	float m_flLastLookAheadTime;		// 上次节点前向遍历时间
	float m_flLastAirVecModifyTime;		// 上次目标修正时间
	float m_flLastProbChargeChkTime;	// 上次概率冲锋的检测时间
	float m_flLastVisibleTime;			// 当前状态中上次看到目标的时间
	float m_flNextBetterTargetCheck;	// 下次允许扫描更优冲锋目标的时间
	float m_flLastEvadeMoveToCheckTime;	// 上次检查 BehaviorMoveTo 目标坐标是否过期的时间
	float m_vecEvadeMoveToPos[3];		// 当前 BehaviorMoveTo 创建时使用的目标坐标
	bool m_bPathSnapshotComplete;		// 路径快照是否完整复制到了 LastSegment
	bool m_bPathInvalidatePending;		// 是否需要在下次 PathFollower::Update 中使路径失效
	PathSegment m_PathSegment;			// Charger 当前 NextBot 寻路的 PathSegment
	PathSegment m_NextPathSegment;		// 当前 PathSegment 的下一个 PathSegment
	PathSegment m_LastPathSegment;		// Charger 当前 NextBot 寻路的当前路径最后一个 PathSegment
	float m_vecAirCorrGoal[3];			// 空中速度修正的前瞻目标点 (一跳内最远且无障碍的 segment goal)
	AirStrafe m_AirStrafe;				// 连跳空中侧向偏移数据
	BhopType m_BhopType;				// 连跳类型 (基于 PATH 或基于目标)
	bool m_bAirborne;					// 上一帧是否已经离地, 用于识别新的一次离地
	bool m_bAirTakeoffDirValid;			// 本次离地的起跳方向是否已经登记
	float m_vecAirTakeoffDir[3];		// 本次离地的起跳水平方向 (单位向量), 空中转向预算以它为基准
	float m_flAirTurnDeviation;			// 本次 (落地后为上一次) 离地期间空中修正偏离起跳方向的最大角度
	float m_flLastHopTurn;				// 最近一次起跳计入加速度折算的总转角 (起跳改向 + 落地跳时上一跳的空中偏转)
	float m_flLastHopImpulseScale;		// 最近一次起跳的加速度折算系数 1 - θ / 90, 仅用于日志

	float m_flPathWaitStart;			// Charger 开始等待下一次 RePath 的时间
	float m_flLastPathInvalidateTime;	// Charger 上次 Path 人为失效时间
	int m_iBaitClawSwings;				// 持枪博弈中已挥出的锤击次数
	bool m_bBaitClawBaselineValid;		// 是否已经取得有效的爪击时间基线
	float m_flLastClawNextAttack;		// 上次读到的爪击 m_flNextPrimaryAttack, 用于检测新挥击
	float m_flBaitClawStart;			// 开始尝试锤击的时间, 超时则改为冲锋

	// 近战博弈距离控制 (迟滞 + 比例 + 最短驻留)
	int m_iBaitMoveSign;				// 当前距离控制方向, 带迟滞, 退到带中心才松手
	float m_flBaitMoveHoldUntil;		// 当前方向的最短驻留截止时间
	float m_flBaitBackhopLockUntil;		// 后跳落地后禁止距离控制前进的截止时间
	int m_iBaitOrbitDir;				// 近战博弈绕圈方向 (+1 / -1)
	float m_flBaitOrbitFlipTime;		// 下次允许翻转绕圈方向的时间

	// 近战僵持追踪 (跨 Approach <-> Bait 抖动保留)
	int m_iStalemateTarget;				// 僵持计时绑定的目标 userId
	float m_flStalemateStart;			// 僵持开始时间
	float m_flLastMeleeBaitTime;		// 上次处于近战博弈的时间
	int m_iStalemateFeints;				// 已经做过的诱骗次数
	float m_flStalemateFeintUntil;		// 当前一次诱骗的截止时间
	float m_flStalemateFeintCooldown;	// 下一次允许发起诱骗的时间
	float m_flTargetSwingNextAttack;	// 上次读到的目标近战 m_flNextPrimaryAttack, 用于识别挥空
	bool m_bTargetSwingBaselineValid;	// 目标近战挥击基线是否有效

	void init() {
		this.m_iTarget = -1;
		this.m_iBetterTarget = -1;
		this.m_flLastHopSpeed = 0.0;
		this.m_flFinalBhopStartTime = 0.0;
		this.m_flLastLookAheadTime = 0.0;
		this.m_flLastAirVecModifyTime = 0.0;
		this.m_flLastProbChargeChkTime = 0.0;
		this.m_flLastVisibleTime = 0.0;
		this.m_flNextBetterTargetCheck = 0.0;
		this.m_bEvadeMoveCommandActive = false;
		this.m_bEvadeMoveCommandPending = false;
		this.m_flLastEvadeMoveToCheckTime = 0.0;
		ZeroVector(this.m_vecEvadeMoveToPos);
		this.m_flPathWaitStart = -1.0;
		this.m_flLastPathInvalidateTime = -1.0;
		this.m_iBaitClawSwings = 0;
		this.m_bBaitClawBaselineValid = false;
		this.m_flLastClawNextAttack = 0.0;
		this.m_flBaitClawStart = 0.0;
		this.m_iBaitMoveSign = 0;
		this.m_flBaitMoveHoldUntil = 0.0;
		this.m_flBaitBackhopLockUntil = 0.0;
		this.m_iBaitOrbitDir = 0;
		this.m_flBaitOrbitFlipTime = 0.0;
		this.m_iStalemateTarget = -1;
		this.m_flStalemateStart = 0.0;
		this.m_flLastMeleeBaitTime = 0.0;
		this.m_iStalemateFeints = 0;
		this.m_flStalemateFeintUntil = 0.0;
		this.m_flStalemateFeintCooldown = 0.0;
		this.m_flTargetSwingNextAttack = 0.0;
		this.m_bTargetSwingBaselineValid = false;
		this.m_bPathSnapshotComplete = false;
		this.m_bPathInvalidatePending = false;
		this.m_PathSegment.init();
		this.m_NextPathSegment.init();
		this.m_LastPathSegment.init();
		ZeroVector(this.m_vecAirCorrGoal);
		this.m_AirStrafe.init();
		this.m_bAirborne = false;
		this.m_bAirTakeoffDirValid = false;
		ZeroVector(this.m_vecAirTakeoffDir);
		this.m_flAirTurnDeviation = 0.0;
		this.m_flLastHopTurn = 0.0;
		this.m_flLastHopImpulseScale = 1.0;
	}
}
AiCharger g_AiChargers[MAXPLAYERS + 1];
ArrayList g_ChargerPathSnapshots[MAXPLAYERS + 1];

// 近战僵持放弃目标后的黑名单 (charger -> survivor 的过期时间), 防止 OnChooseVictim 立刻把同一个人选回来
float g_flBaitTargetBlacklist[MAXPLAYERS + 1][MAXPLAYERS + 1];
// 近战僵持换目标后的强制目标, 等待下一次 L4D2_OnChooseVictim 落实
int g_iChargerForcedTarget[MAXPLAYERS + 1];
float g_flChargerForcedTargetUntil[MAXPLAYERS + 1];

// 定义状态函数原型 Funcion Properties
typedef StateFunc_Enter = function void(int client);
typedef StateFunc_Update = function Action(int client, int& buttons, float vel[3], float ang[3]);
typedef StateFunc_Exit = function void(int client);

// Charger 状态枚举
enum {
	CH_STATE_NONE = -1,
	CH_STATE_APPROACH = 0,	// 接近目标中
	CH_STATE_BAIT,			// 与目标博弈
	CH_STATE_LOCKED, 		// 锁定目标, 准备冲撞
	CH_STATE_CHARGING, 		// 冲锋中
	CH_STATE_COUNT,			// 状态计数
}

// =========================================================================
// 每个状态的描述数组
// =========================================================================
enum struct ChargerState {
	char name[64];				// 状态名称
	StateFunc_Enter OnEnter;	// 进入状态函数指针
	StateFunc_Update OnUpdate;	// 状态更新函数指针
	StateFunc_Exit OnExit;		// 退出状态函数指针
}

ArrayList g_ChargerStates;

// =========================================================================
// Charger 状态管理器 (持有一个当前状态 ID, 负责状态转换与执行)
// 1. TransitionTo(int newStateId) 用于进行状态转换
// 2. update(int& buttons, float vel[3], float ang[3]) 由 OnPlayerRunCmd 调用, 用于每帧执行当前状态
// =========================================================================   
enum struct ChargerStateContext {
	int userId;
	int currentStateId;	// 状态 ID
	float startTime;	// 持续时间

	// 状态管理器初始化
	void init(int client) {
		if (!IsValidInfected(client) || GetInfectedClass(client) != ZC_CHARGER
			|| !IsPlayerAlive(client) || !IsFakeClient(client) || IsInGhostState(client))
			return;
		
		this.userId = GetClientUserId(client);
		this.currentStateId = CH_STATE_NONE;
		this.startTime = GetGameTime();
	}

	// 状态转移
	void transitionTo(int newStateId) {
		if (newStateId == this.currentStateId)
			return;
		if (!IsValidClient(GetClientOfUserId(this.userId)))
			return;

		// 执行旧状态的退出逻辑（必须先读取旧状态数据，再判断 OnExit 是否有效）
		static ChargerState oldState;
		if (this.currentStateId != CH_STATE_NONE && g_ChargerStates != null) {
			g_ChargerStates.GetArray(this.currentStateId, oldState, sizeof(oldState));
			if (oldState.OnExit != INVALID_FUNCTION) {
				Call_StartFunction(INVALID_HANDLE, oldState.OnExit);
				Call_PushCell(GetClientOfUserId(this.userId));
				Call_Finish();
			}
		}

		// 设置状态管理器的当前状态 ID 和开始时间
		this.currentStateId = newStateId;
		this.startTime = GetGameTime();

		// 执行新状态的进入逻辑
		static ChargerState newState;
		g_ChargerStates.GetArray(this.currentStateId, newState, sizeof(newState));
		if (newState.OnEnter != INVALID_FUNCTION) {
			Call_StartFunction(INVALID_HANDLE, newState.OnEnter);
			Call_PushCell(GetClientOfUserId(this.userId));
			Call_Finish();
		}
	}

	// 状态的每帧更新操作
	Action update(int& buttons, float vel[3], float ang[3]) {
		// 默认返回值, 如果没有状态或者没有 update 函数, 返回 Plugin_Continue
		Action res = Plugin_Continue;
		if (this.currentStateId == CH_STATE_NONE || g_ChargerStates == null)
			return res;

		// 获取当前状态
		static ChargerState curState;
		g_ChargerStates.GetArray(this.currentStateId, curState, sizeof(curState));

		if (curState.OnUpdate != INVALID_FUNCTION) {
			Call_StartFunction(INVALID_HANDLE, curState.OnUpdate);
			Call_PushCell(GetClientOfUserId(this.userId));
			Call_PushCellRef(buttons);
			Call_PushArrayEx(vel, 3, SM_PARAM_COPYBACK);
			Call_PushArrayEx(ang, 3, SM_PARAM_COPYBACK);
			Call_Finish(res);
		}

		return res;
	}

	// 获取当前状态执行时间
	float getStateDuration() {
		return GetGameTime() - this.startTime;
	}
}

ChargerStateContext g_ChargerStateContext[MAXPLAYERS + 1];

// =========================================================================
// 目标持有武器类型枚举
// =========================================================================
enum TargetThreatType{
	Threat_None,
	Threat_Shotgun,		// 目标正在拿着霰弹枪
	Threat_Melee,		// 目标正在拿着近战武器
	Threat_Normal,		// 正常的持枪玩家
}

// =========================================================================
// Setup 模块初始化与销毁
// =========================================================================
ConVar
	cvChargeSpeed,
	cvMeleeRange,
	cvMeleeDamageCharger,
	cvGravity;

Handle
		g_hSdkGetRunTopSpeed,
		g_hSdkIsChargeBlocked,
		g_hSdkMyNextBotPointer,
	g_hSdkGetLocomotionInterface,
	g_hSdkLocomotionApproach,
	g_hSdkLocomotionFaceTo,
	g_hSdkHasPotentialGap;

stock void SetUp_OnModuleStart() {
	// 初始化状态描述列表
	g_ChargerStates = new ArrayList(sizeof(ChargerState));
	for (int client = 1; client <= MaxClients; client++)
		g_ChargerPathSnapshots[client] = new ArrayList(sizeof(PathSegment));
}

stock void SetUp_OnConfigsExecuted() {
	cvChargeSpeed = FindConVar("z_charge_max_speed");
	cvMeleeRange = FindConVar("melee_range");
	cvMeleeDamageCharger = FindConVar("melee_damage_charger");
	cvGravity = FindConVar("sv_gravity");
}

stock bool SetUp_SetAnneNextBotPathConsumer(bool enabled) {
	if (!LibraryExists(ANNE_NEXTBOT_LIBRARY)
		|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_IsActive") != FeatureStatus_Available
			|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_SetPathConsumer") != FeatureStatus_Available
			|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSnapshotInfo") != FeatureStatus_Available
			|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSegment") != FeatureStatus_Available
			|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_SetPathGoal") != FeatureStatus_Available
			|| GetFeatureStatus(FeatureType_Native, "AnneNextBot_InvalidatePath") != FeatureStatus_Available
			|| !AnneNextBot_IsActive())
		return false;

	return AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Charger, enabled);
}
stock void SetUp_OnAllPluginsLoaded() {
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(path))
		SetFailState("Missing required gamedata file: %s", path);

	GameData hGameData = new GameData(GAMEDATA);
	if (!hGameData)
		SetFailState("Failed to load gamedata file: %s", path);

	// ============================================================
	// Read SDK function 'CTerrorPlayer::GetRunTopSpeed'
	// ============================================================
	StartPrepSDKCall(SDKCall_Entity);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, SIG_GET_RUN_TOP_SPEED))
		SetFailState("Failed to load signature: %s in gamedata file: %s.", SIG_GET_RUN_TOP_SPEED, GAMEDATA);
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
	g_hSdkGetRunTopSpeed = EndPrepSDKCall();
	if (!g_hSdkGetRunTopSpeed)
		SetFailState("Could not prep the %s function.", SIG_GET_RUN_TOP_SPEED);

	// =========================================================================
	// Read SDK function 'Charger::IsChargeBlocked'
	// =========================================================================
	StartPrepSDKCall(SDKCall_Player);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, SIG_IS_CHARGE_BLOCKED))
		SetFailState("Failed to load signature: %s in gamedata file: %s.", SIG_IS_CHARGE_BLOCKED, GAMEDATA);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSdkIsChargeBlocked = EndPrepSDKCall();
	if (!g_hSdkIsChargeBlocked)
		SetFailState("Could not prep the %s function.", SIG_IS_CHARGE_BLOCKED);

	// ============================================================
	// int CBaseEntity::MyNextBotPointer()
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_MY_NEXTBOT_POINTER))
		SetFailState("Failed to load offset for signature %s", SIG_MY_NEXTBOT_POINTER);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkMyNextBotPointer = EndPrepSDKCall();
	if (!g_hSdkMyNextBotPointer)
		SetFailState("Failed to prep sdk call for signature %s", SIG_MY_NEXTBOT_POINTER);

	// ============================================================
	// INextBot::GetLocomotionInterface() const
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_NEXTBOT_GET_LOCOMOTION))
		SetFailState("Failed to load offset for signature %s", SIG_NEXTBOT_GET_LOCOMOTION);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkGetLocomotionInterface = EndPrepSDKCall();
	if (!g_hSdkGetLocomotionInterface)
		SetFailState("Failed to prep sdk call for signature %s", SIG_NEXTBOT_GET_LOCOMOTION);

	// ============================================================
	// ILocomotion::Approach(Vector const&, float)
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_LOCOMOTION_APPROACH))
		SetFailState("Failed to load offset for signature %s", SIG_LOCOMOTION_APPROACH);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	g_hSdkLocomotionApproach = EndPrepSDKCall();
	if (!g_hSdkLocomotionApproach)
		SetFailState("Failed to prep sdk call for signature %s", SIG_LOCOMOTION_APPROACH);

	// ============================================================
	// ILocomotion::FaceTowards(Vector const&)
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_LOCOMOTION_FACE_TO))
		SetFailState("Failed to load offset for signature %s", SIG_LOCOMOTION_FACE_TO);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	g_hSdkLocomotionFaceTo = EndPrepSDKCall();
	if (!g_hSdkLocomotionFaceTo)
		SetFailState("Failed to prep sdk call for signature %s", SIG_LOCOMOTION_FACE_TO);

	// ============================================================
	// ILocomotion::HasPotentialGap(Vector const&, Vector const&, float*) const
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_LOCOMOTION_HAS_POTENTIAL_GAP))
		SetFailState("Failed to load offset for signature %s", SIG_LOCOMOTION_HAS_POTENTIAL_GAP);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_ByRef);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_hSdkHasPotentialGap = EndPrepSDKCall();
	if (!g_hSdkHasPotentialGap)
		SetFailState("Failed to find signature %s", SIG_LOCOMOTION_HAS_POTENTIAL_GAP);

		delete hGameData;
		if (!SetUp_SetAnneNextBotPathConsumer(true))
			SetFailState("ai_charger3 requires anne_nextbot path snapshots.");
	}

stock void SetUp_OnModuleEnd() {
		SetUp_SetAnneNextBotPathConsumer(false);
	for (int client = 1; client <= MaxClients; client++)
		delete g_ChargerPathSnapshots[client];
	delete g_ChargerStates;
}
