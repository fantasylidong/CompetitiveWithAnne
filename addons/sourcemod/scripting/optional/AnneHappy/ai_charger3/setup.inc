#if defined _setup_included_
	#endinput
#endif
#define _setup_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

// =========================================================================
// Public Defines
// =========================================================================
#define CVAR_FLAGS							FCVAR_NOTIFY

#define GAMEDATA 							"l4d2_ai_charger3"
#define SIG_GET_RUN_TOP_SPEED 				"CTerrorPlayer::GetRunTopSpeed"
#define SIG_IS_CHARGE_BLOCKED 				"Charger::IsChargeBlocked"
#define SIG_PATH_FOLLOWER_UPDATE			"PathFollower::Update"
#define SIG_NEXTBOT_GET_COMBAT_CHARACTER 	"INextBot::GetNextBotCombatCharacter"
#define OFFSET_PATH_FOLLOWER_GOAL			"PathFollower::m_goal"
#define SIG_PATH_GET_CUR_GOAL				"Path::GetCurrentGoal"
#define SIG_PATH_INVALIDATE					"Path::Invalidate"
#define SIG_PATH_NEXT_SEGMENT				"Path::NextSegment"
#define SIG_PATH_PRIOR_SEGMENT				"Path::PriorSegment"
#define SIG_PATH_LAST_SEGMENT 				"Path::LastSegment"
#define	SIG_MY_NEXTBOT_POINTER				"CBaseEntity::MyNextBotPointer"
#define SIG_NEXTBOT_GET_LOCOMOTION			"INextBot::GetLocomotionInterface"
#define SIG_LOCOMOTION_APPROACH				"ILocomotion::Approach"
#define SIG_LOCOMOTION_FACE_TO				"ILocomotion::FaceTowards"
#define SIG_LOCOMOTION_HAS_POTENTIAL_GAP	"ILocomotion::HasPotentialGap"

#define PLAYER_HEIGHT 						72.0
#define JUMP_HEIGHT							57.0	// PlayerLocomotion::GetMaxJumpHeight 返回 57.0

#define DEFAULT_CHARGE_SPEED 				500.0
#define DEFAULT_MELEE_RANGE 				70.0
#define DEFAULT_MELEE_DMG_CHARGER 			390
#define DEFAULT_GRAVITY 					800.0
#define DEFAULT_SURVIVOR_SPEED 				220.0
#define DROP_DOWN_THRESHOLD					200.0
#define TARGET_VULNERABLE_ADV_CHECK_DIST	250.0
#define UNAVOIDABLE_TARGET_DIST_BUFFER		120.0
#define EVADE_MOVETO_REFRESH_MIN_DIST		50.0		// 目标至少移动该距离才重建 BehaviorMoveTo, 避免微小位置抖动反复寻路
#define STATE_TOLERANCE_DIST                50.0		// 状态转换容差距离
#define CHARGE_Z_THRESHOLD                  57.0    	// charger 冲锋时, 如果与目标的高度差超过该值, 则取消冲锋
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
	g_cvAirVecModifyInterval,	// 空中速度修正间隔
	g_cvAirVecModifyLerp,		// 空中速度修正转向插值因子
	g_cvBaitMaxDuration,		// charger 进入博弈状态的最长时间
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
	
	float m_flLastHopSpeed;				// 上次起跳的速度
	float m_flFinalBhopStartTime;		// 冲锋前最后一次连跳开始时间, 用于短暂等待落地/进入 commit range
	float m_flLastLookAheadTime;		// 上次节点前向遍历时间
	float m_flLastAirVecModifyTime;		// 上次目标修正时间
	float m_flLastProbChargeChkTime;	// 上次概率冲锋的检测时间
	float m_flLastVisibleTime;			// 当前状态中上次看到目标的时间
	float m_flLastEvadeMoveToCheckTime;	// 上次检查 BehaviorMoveTo 目标坐标是否过期的时间
	float m_vecEvadeMoveToPos[3];		// 当前 BehaviorMoveTo 创建时使用的目标坐标
	Address m_pPathFollower;			// Path Follower 的指针, 用于前瞻 Goal Pos
	PathSegment m_PathSegment;			// Charger 当前 NextBot 寻路的 PathSegment
	PathSegment m_NextPathSegment;		// 当前 PathSegment 的下一个 PathSegment
	PathSegment m_LastPathSegment;		// Charger 当前 NextBot 寻路的当前路径最后一个 PathSegment
	float m_vecAirCorrGoal[3];			// 空中速度修正的前瞻目标点 (一跳内最远且无障碍的 segment goal)
	AirStrafe m_AirStrafe;				// 连跳空中侧向偏移数据
	BhopType m_BhopType;				// 连跳类型 (基于 PATH 或基于目标)

	float m_flPathWaitStart;			// Charger 开始等待下一次 RePath 的时间
	float m_flLastPathInvalidateTime;	// Charger 上次 Path 人为失效时间

	void init() {
		this.m_iTarget = -1;
		this.m_iBetterTarget = -1;
		this.m_flLastHopSpeed = 0.0;
		this.m_flFinalBhopStartTime = 0.0;
		this.m_flLastLookAheadTime = 0.0;
		this.m_flLastAirVecModifyTime = 0.0;
		this.m_flLastProbChargeChkTime = 0.0;
		this.m_flLastVisibleTime = 0.0;
		this.m_bEvadeMoveCommandActive = false;
		this.m_flLastEvadeMoveToCheckTime = 0.0;
		ZeroVector(this.m_vecEvadeMoveToPos);
		this.m_flPathWaitStart = -1.0;
		this.m_flLastPathInvalidateTime = -1.0;
		this.m_pPathFollower = Address_Null;
		this.m_PathSegment.init();
		this.m_NextPathSegment.init();
		this.m_LastPathSegment.init();
		ZeroVector(this.m_vecAirCorrGoal);
		this.m_AirStrafe.init();
	}
}
AiCharger g_AiChargers[MAXPLAYERS + 1];

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

		// 执行旧状态的退出逻辑
		static ChargerState oldState;
		if (this.currentStateId != CH_STATE_NONE && oldState.OnExit != INVALID_FUNCTION) {
			// 如果旧状态不是 STATE_NONE, 则获取旧的状态
			g_ChargerStates.GetArray(this.currentStateId, oldState, sizeof(oldState));
			Call_StartFunction(INVALID_HANDLE, oldState.OnExit);
			Call_PushCell(GetClientOfUserId(this.userId));
			Call_Finish();
		}

		// 设置状态管理器的当前状态 ID 和开始时间
		this.currentStateId = newStateId;
		this.startTime = GetGameTime();

		// 执行新状态的进入逻辑
		static ChargerState newState;
		g_ChargerStates.GetArray(this.currentStateId, newState, sizeof(newState));
		if (newState.OnEnter != INVALID_FUNCTION) {
			Call_StartFunction(INVALID_FUNCTION, newState.OnEnter);
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
	g_hSdkNextBotGetCombatCharacter,
	g_hSdkPathGetCurGoal,
	g_hSdkPathInvalidate,
	g_hSdkPathNextSegment,
	g_hSdkPathPriorSegment,
	g_hSdkPathLastSegment,
	g_hSdkMyNextBotPointer,
	g_hSdkGetLocomotionInterface,
	g_hSdkLocomotionApproach,
	g_hSdkLocomotionFaceTo,
	g_hSdkHasPotentialGap;

Handle
	g_hPathFollowerDetour;

int
	g_iPathFollowerGoalOffset;

stock void SetUp_OnModuleStart() {
	// 初始化状态描述列表
	g_ChargerStates = new ArrayList(sizeof(ChargerState));
}

stock void SetUp_OnConfigsExecuted() {
	cvChargeSpeed = FindConVar("z_charge_max_speed");
	cvMeleeRange = FindConVar("melee_range");
	cvMeleeDamageCharger = FindConVar("melee_damage_charger");
	cvGravity = FindConVar("sv_gravity");
}

stock void SetUp_OnAllPluginsLoaded() {
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(path))
		SetFailState("Missing required gamedata file: %s", path);

	GameData hGameData = new GameData(GAMEDATA);
	if (!hGameData)
		SetFailState("Failed to load gamedata file: %s", path);

	// 读取 PathFollower::m_goal 成员的偏移量 (4 * 4566)
	g_iPathFollowerGoalOffset = hGameData.GetOffset(OFFSET_PATH_FOLLOWER_GOAL);
	if (g_iPathFollowerGoalOffset < 0)
		SetFailState("Failed to load offset: %s in gamedata file: %s.", OFFSET_PATH_FOLLOWER_GOAL, GAMEDATA);

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
	// PathFollower::Update Detour
	// ============================================================
	g_hPathFollowerDetour = DHookCreateFromConf(hGameData, SIG_PATH_FOLLOWER_UPDATE);
	if (!g_hPathFollowerDetour)
		SetFailState("Failed to create detour for signature: %s in gamedata file: %s.", SIG_PATH_FOLLOWER_UPDATE, GAMEDATA);
	if (!DHookEnableDetour(g_hPathFollowerDetour, false, Detour_PathFollower_Update))
		SetFailState("Failed to enable detour for signature: %s in gamedata file: %s.", SIG_PATH_FOLLOWER_UPDATE, GAMEDATA);

	// ============================================================
	// CBaseCombatCharacter* GetEntity( void ) const
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_NEXTBOT_GET_COMBAT_CHARACTER))
		SetFailState("Failed to load signature: %s in gamedata file: %s.", SIG_NEXTBOT_GET_COMBAT_CHARACTER, GAMEDATA);
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	g_hSdkNextBotGetCombatCharacter = EndPrepSDKCall();
	if (!g_hSdkNextBotGetCombatCharacter)
		SetFailState("Failed to prep sdk call for signature %s", SIG_NEXTBOT_GET_COMBAT_CHARACTER);

	// ============================================================
	// int __cdecl PathFollower::GetCurrentGoal(PathFollower *this)
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_PATH_GET_CUR_GOAL))
		SetFailState("Failed to load offset for signature %s", SIG_PATH_GET_CUR_GOAL);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkPathGetCurGoal = EndPrepSDKCall();
	if (!g_hSdkPathGetCurGoal)
		SetFailState("Failed to prep sdk call for signature %s", SIG_PATH_GET_CUR_GOAL);

	// ============================================================
	// void Path::Invalidate()
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_PATH_INVALIDATE))
		SetFailState("Failed to load offset for signature %s", SIG_PATH_INVALIDATE);
	g_hSdkPathInvalidate = EndPrepSDKCall();
	if (!g_hSdkPathInvalidate)
		SetFailState("Failed to prep sdk call for signature %s", SIG_PATH_INVALIDATE);

	// ============================================================
	// Path::Segment* NextSegment( const Path::Segment* currentSegment )
	// given current segment, return next segment
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_PATH_NEXT_SEGMENT))
		SetFailState("Failed to load offset for signature %s", SIG_PATH_NEXT_SEGMENT);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkPathNextSegment = EndPrepSDKCall();
	if (!g_hSdkPathNextSegment)
		SetFailState("Failed to prep sdk call for signature %s", SIG_PATH_NEXT_SEGMENT);

	// ============================================================
	// Path::PriorSegment(Path::Segment const*) const
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_PATH_PRIOR_SEGMENT))
		SetFailState("Failed to load offset for signature %s", SIG_PATH_PRIOR_SEGMENT);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkPathPriorSegment = EndPrepSDKCall();
	if (!g_hSdkPathPriorSegment)
		SetFailState("Failed to prep sdk call for signature %s", SIG_PATH_PRIOR_SEGMENT);

	// ============================================================
	// Path::Segment* Path::LastSegment(void)
	// ============================================================
	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, SIG_PATH_LAST_SEGMENT))
		SetFailState("Failed to load offset for signature %s", SIG_PATH_LAST_SEGMENT);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkPathLastSegment = EndPrepSDKCall();
	if (!g_hSdkPathLastSegment)
		SetFailState("Failed to prep sdk call for signature %s", SIG_PATH_LAST_SEGMENT);

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
	StartPrepSDKCall(SDKCall_Raw)
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
}

stock void SetUp_OnModuleEnd() {
	delete g_ChargerStates;
}
