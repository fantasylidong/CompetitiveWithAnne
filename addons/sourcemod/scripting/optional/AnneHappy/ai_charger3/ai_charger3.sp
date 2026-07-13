#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#include <treeutil>
#include <logger2>
#include <actions>

// For debug print vector direction, positon
#include <vector_show>

#include "./setup.inc"
#include "./stocks.inc"
#include "./state/state.inc"

// 将插件日志前缀改成自己插件的日志前缀
#define PLUGIN_PREFIX "AI-Charger3"
#define ACT_NAME_CHARGER_EVADE		"ChargerEvade"
#define ACT_NAME_CHARGE_AT_VICTIM 	"ChargerChargeAtVictim"

ConVar
	g_cvPluginName,
	g_cvLogLevel;

Logger
	log;

public Plugin myinfo = 
{
	name 			= "Ai-Charger 3.0",
	author 			= "夜羽真白",
	description 	= "Ai Charger 增强 3.0 版本",
	version 		= "1.0.0.0",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

public void OnPluginStart() {
	// allow charger to bhop?
	g_cvBhop = CreateConVar("ai_charger3_bhop", "1", "是否允许 Charger 进行在接近状态时连跳操作, 0=禁止, 1=允许", CVAR_FLAGS, true, 0.0, true, 1.0);
	// charger is allowed to bhop when its distance from the target is between [ai_charger3_bhop_min_dist, ai_charger3_bhop_max_dist], if the distance is less than this value, charger will transition to bait state
	g_cvBhopMinDist = CreateConVar("ai_charger3_bhop_min_dist", "75.0", "禁止连跳的最小距离, 小于这个距离转换为博弈状态", CVAR_FLAGS, true, 0.0);
	g_cvBhopMaxDist = CreateConVar("ai_charger3_bhop_max_dist", "9999.0", "允许连跳的最大距离", CVAR_FLAGS, true, 0.0);
	g_cvDirectBhopDist = CreateConVar("ai_charger3_bhop_direct_dist", "400.0", "Charger 在接近状态中切换到朝目标方向直线连跳的距离阈值", CVAR_FLAGS, true, 0.0);
	// the bhop impulse, when charger is allowed to bhop, each time it jumps up from the ground, it will gain a speed impulse with the value of ai_charger3_bhop_impulse
	g_cvBhopImpulse = CreateConVar("ai_charger3_bhop_impulse", "100.0", "连跳的加速度", CVAR_FLAGS, true, 0.0);
	// when charger's speed is greater than 'ai_charger3_bhop_min_speed', it is allowed to bhop, and its max bhop speed will not greater than 'ai_charger3_bhop_max_speed'
	g_cvBhopMinSpeed = CreateConVar("ai_charger3_bhop_min_speed", "200", "允许连跳的最小速度", CVAR_FLAGS, true, 0.0);
	g_cvBhopMaxSpeed = CreateConVar("ai_charger3_bhop_max_speed", "1000", "连跳的最大限制速度", CVAR_FLAGS, true, 0.0);
	// Whether charger is allowed to perform bhop before charging. 0=Disabled, 1=Enabled
	g_cvBhopBeforeCharge = CreateConVar("ai_charger3_bhop_before_charge", "1", "是否允许在冲锋前进行连跳, 0=禁止, 1=允许", CVAR_FLAGS, true, 0.0, true, 1.0);
	// when charger has no vision of the target survivor, allow it to bhop?
	g_cvBhopNoVision = CreateConVar("ai_charger3_bhop_no_vision", "1", "是否允许Charger无目标视野时进行连跳, 0=禁止, 1=允许", CVAR_FLAGS, true, 0.0, true, 1.0);
	// when charger has no sight of target, it is allowed to bhop when its speed vector and eye angle forward vector within this degree
	g_cvBhopNoVisionMaxAng = CreateConVar("ai_charger3_bhop_nvis_maxang", "90.0", "无生还者视野时速度向量与视角前向向量在这个角度范围内, 允许连跳", CVAR_FLAGS, true, 0.0);
	// when the vector of charger to target and charger's eye angle forward vector within this degree, consider the target is looking at charger
	g_cvTargetWatchMaxDeg = CreateConVar("ai_charger3_target_watch_maxdeg", "22.5", "目标视角与到 Charger 位置向量夹角小于这个值时, 认为目标正在看着 Charger", CVAR_FLAGS, true, 0.0, true, 180.0);
	// when the distance between charger and target is less than this value, disable left/right strafing offset of charger's bhop direction
	g_cvBhopStrafeMinDist = CreateConVar("ai_charger3_bhop_strafe_mindist", "400.0", "与目标小于这个距离时, 禁止连跳方向左右偏移", CVAR_FLAGS, true, 0.0);
	// the minimum angle of random left/right strafing offset for charger's bhop direction. Enable if greater than 0.0, disable this feature if set to -1.0
	g_cvBhopStrafeMinDeg = CreateConVar("ai_charger3_bhop_strafe_mindeg", "30.0", "Charger 连跳方向左右随机偏移 (侧向连跳) 的最小偏移角度, 大于 0.0 启用, -1.0 禁用此功能", CVAR_FLAGS, true, -1.0);
	// the maximum angle of random left/right strafing offset for charger's bhop direction
	g_cvBhopStrafeMaxDeg = CreateConVar("ai_charger3_bhop_strafe_maxdeg", "55.0", "Charger 侧向连跳的最大角度", CVAR_FLAGS, true, 0.0, true, 89.0);
	// The minimum distance from target required for charger to perform single strafe bhop (bhopping is disabled when closer than this distance)
	g_cvBhopStrafeOnceDist = CreateConVar("ai_charger3_bhop_strafe_once_dist", "200.0", "允许 Charger 侧向连跳一次的最小距离 (距离目标点小于这个距离不允许侧向连跳)", CVAR_FLAGS);
	// The minimum distance from target required for charger to perform double strafe bhop (bhopping is disabled when closer than this distance)
	g_cvBhopStrafeTwiceDist = CreateConVar("ai_charger3_bhop_strafe_twice_dist", "400.0", "允许 Charger 侧向连跳两次的最小距离 (距离目标点大于这个距离才允许侧向连跳两次)", CVAR_FLAGS);
	// when the target is holding a melee weapon, the minimum range of the melee bait zone (calculated as melee_range plus this value)
	g_cvMeleeBaitZoneMinRange = CreateConVar("_ai_charger3_melee_bait_minrange", "15.0", "目标拿着近战时, 近战博弈区的最小范围, melee_range + 这个值", CVAR_FLAGS, true, 0.0);
	// when the target is holding a melee weapon, the maximum range of the melee bait zone (calculated as melee_range plus this value)
	g_cvMeleeBaitZoneMaxRange = CreateConVar("_ai_charger3_melee_bait_maxrange", "50.0", "目标拿着近战时, 近战博弈区的最大范围, melee_range + 这个值", CVAR_FLAGS, true, 0.0);
	// when the angle between charger's air velocity direction and the direction from charger to target exceeds this value, perform air velocity modification (air modification: set charger's current velocity direction to the target direction)
	g_cvAirVecModifyMinDegree = CreateConVar("ai_charger3_airvec_modify_min_deg", "45.0", "在空中速度方向与自身到目标方向角度超过这个值进行速度修正", CVAR_FLAGS, true, 0.0);
	// When the angle between charger's air velocity direction and the direction from charger to target exceeds this value, abandon air velocity modification
	g_cvAirVecModifyMaxDegree = CreateConVar("ai_charger3_airvec_modify_max_deg", "180.0", "在空中速度方向与自身到目标方向角度超过这个值放弃速度修正", CVAR_FLAGS, true, 0.0);
	// the interval (in seconds) between consecutive air velocity vector modifications for charger
	g_cvAirVecModifyInterval = CreateConVar("ai_charger3_airvec_modify_interval", "0.3", "空中速度修正间隔", CVAR_FLAGS, true, 0.0);
	// The interpolation factor for charger's air velocity direction modification. Min: 0.0, Max: 1.0. Lower values result in smoother air turning, higher values result in sharper air turning
	g_cvAirVecModifyLerp = CreateConVar("_ai_charger3_airvec_modify_lerp", "0.3", "空中速度方向修正的修正插值因子, 0.1~1.0, 越小转向越平滑, 但是需要更多的帧数, 越大转向越锐利, 需要较少的帧数就可以完成空中转向", CVAR_FLAGS, true, 0.0, true, 1.0);
	// the maximum allowed duration (in seconds) for charger to stay in the bait state
	g_cvBaitMaxDuration = CreateConVar("ai_charger3_bait_max_duration", "7.0", "Charger 进入博弈状态的最大允许时间", CVAR_FLAGS, true, 0.0);
	// the detection interval (in seconds) for charger's probabilistic charge when in the bait state
	g_cvProbChargeChkDur = CreateConVar("ai_charger3_prob_charge_chk_dur", "1.0", "Charger 进入博弈状态概率冲锋的检测间隔", CVAR_FLAGS, true, 0.0);
	// the probability (0.0 to 1.0) of charger performing a probabilistic charge when in the bait state
	g_cvProbChargeProb = CreateConVar("ai_charger3_prob_charge_prob", "0.5", "Charger 进入博弈状态概率冲锋的概率", CVAR_FLAGS, true, 0.0);
	// whether to prohibit charger from retreating: 0=Disabled (allow retreat), 1=Enabled (forbid retreat)
	g_cvAntiRetreat = CreateConVar("ai_charger3_anti_retreat", "1", "是否禁止 Charger 逃跑, 0=禁止, 1=允许", CVAR_FLAGS, true, 0.0, true, 1.0);
	// refresh interval for the target destination used by BehaviorMoveTo while ChargerEvade is intercepted
	g_cvEvadeMoveToRefreshInterval = CreateConVar("ai_charger3_evade_moveto_refresh_interval", "1.0", "ChargerEvade 追击时检查并刷新 BehaviorMoveTo 目标坐标的间隔", CVAR_FLAGS, true, 0.1, true, 10.0);
	// The maximum depth of path segments that charger will look ahead when it is on ground and preparing to bhop (0 = disabled). Controls how far ahead charger scans the current PATH to find suitable landing spots before hopping from ground
	g_cvPathLookAheadMaxDepth = CreateConVar("ai_charger3_path_lookahead_maxdepth", "10", "Charger 向前搜索以当前速度可以一步到达的 PathSegment 的最大深度", CVAR_FLAGS, true, 0.0);

	// 兼容 ai_charger_2 的配置。先查找旧 Cvar，支持同一局内从旧版本切换到新版本。
	g_cvLegacyBhop = getOrCreateLegacyConVar("ai_ChargerBhop", "1", "是否开启 Charger 连跳", true, 0.0, true, 1.0);
	g_cvLegacyBhopSpeed = getOrCreateLegacyConVar("ai_ChagrerBhopSpeed", "90.0", "Charger 连跳速度/加速度兼容值", true, 0.0, false, 0.0);
	g_cvLegacyChargeDistance = getOrCreateLegacyConVar("ai_ChargerChargeDistance", "250.0", "Charger 旧版冲锋距离，转换为 3.0 直线连跳阈值", true, 0.0, false, 0.0);
	g_cvLegacyExtraTargetDistance = getOrCreateLegacyConVar("ai_ChargerExtraTargetDistance", "0,350", "Charger 额外目标范围，格式为最小距离,最大距离", false, 0.0, false, 0.0);
	g_cvLegacyAimOffset = getOrCreateLegacyConVar("ai_ChargerAimOffset", "30.0", "目标视角与 Charger 的兼容判定角度", true, 0.0, false, 0.0);
	g_cvLegacyMeleeAvoid = getOrCreateLegacyConVar("ai_ChargerMeleeAvoid", "1", "是否启用 Charger 近战回避", true, 0.0, true, 1.0);
	g_cvLegacyMeleeDamage = getOrCreateLegacyConVar("ai_ChargerMeleeDamage", "350", "Charger 血量低于该值时避免近战目标", true, 0.0, false, 0.0);
	g_cvLegacyTarget = getOrCreateLegacyConVar("ai_ChargerTarget", "1", "Charger 目标选择：1=原生，2=最近，3=人群中心", true, 1.0, true, 3.0);
	g_cvLegacyChargeHeightDiff = getOrCreateLegacyConVar("ai_ChargerChargeHeightDiff", "80.0", "允许直接冲锋的最大高度差，<=0 使用默认值", false, 0.0, false, 0.0);
	g_cvLegacyBhop.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyBhopSpeed.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyChargeDistance.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyExtraTargetDistance.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyAimOffset.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyMeleeAvoid.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyMeleeDamage.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyTarget.AddChangeHook(legacyChargerConfigChanged);
	g_cvLegacyChargeHeightDiff.AddChangeHook(legacyChargerConfigChanged);

	// 将插件名称改成自己插件名称
	g_cvPluginName = CreateConVar("ai_charger3_plugin_name", "ai_charger3");

	char cvName[64];
	g_cvPluginName.GetString(cvName, sizeof(cvName));
	FormatEx(cvName, sizeof(cvName), "%s_log_level", cvName);
	// log recording level: 1=Disabled, 2=Console output, 4=Log file output, 8=Chat box output, 16=Server console output, 32=Error file output. Values can be added together for multiple outputs
	g_cvLogLevel = CreateConVar(cvName, "38", "日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 数字相加", CVAR_FLAGS);

	HookEvent("round_start", evtRoundStart);
	HookEvent("round_end", evtRoundEnd);
	HookEvent("player_spawn", evtPlayerSpawn, EventHookMode_Pre);

	log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);

	// 子模块初始化
	SetUp_OnModuleStart();
	State_OnModuleStart(g_cvPluginName);
	Stock_OnModuleStart(g_cvPluginName);
}

public void OnPluginEnd() {
	SetUp_OnModuleEnd();
	State_OnModuleEnd();
	Stock_OnModuleEnd();
	delete log;
}

public void OnAllPluginsLoaded() {
	SetUp_OnAllPluginsLoaded();
}

public void OnConfigsExecuted() {
	SetUp_OnConfigsExecuted();
	syncLegacyChargerConfig();
}

ConVar getOrCreateLegacyConVar(const char[] name, const char[] defaultValue, const char[] description,
	bool hasMin, float minValue, bool hasMax, float maxValue)
{
	ConVar convar = FindConVar(name);
	if (convar != null)
		return convar;

	if (hasMin && hasMax)
		return CreateConVar(name, defaultValue, description, CVAR_FLAGS, true, minValue, true, maxValue);
	if (hasMin)
		return CreateConVar(name, defaultValue, description, CVAR_FLAGS, true, minValue);
	return CreateConVar(name, defaultValue, description, CVAR_FLAGS);
}

void syncLegacyChargerConfig()
{
	if (g_cvLegacyBhop != null)
		g_cvBhop.SetInt(g_cvLegacyBhop.IntValue);
	if (g_cvLegacyBhopSpeed != null)
		g_cvBhopImpulse.SetFloat(g_cvLegacyBhopSpeed.FloatValue);
	if (g_cvLegacyChargeDistance != null)
		g_cvDirectBhopDist.SetFloat(g_cvLegacyChargeDistance.FloatValue);
	if (g_cvLegacyAimOffset != null)
		g_cvTargetWatchMaxDeg.SetFloat(g_cvLegacyAimOffset.FloatValue);

	g_fLegacyExtraTargetMin = 0.0;
	g_fLegacyExtraTargetMax = 350.0;
	if (g_cvLegacyExtraTargetDistance != null)
	{
		char range[64];
		char values[2][32];
		g_cvLegacyExtraTargetDistance.GetString(range, sizeof(range));
		int count = ExplodeString(range, ",", values, sizeof(values), sizeof(values[]));
		if (count >= 1)
			g_fLegacyExtraTargetMin = StringToFloat(values[0]);
		if (count >= 2)
			g_fLegacyExtraTargetMax = StringToFloat(values[1]);
		if (g_fLegacyExtraTargetMax < g_fLegacyExtraTargetMin)
			g_fLegacyExtraTargetMax = g_fLegacyExtraTargetMin;
	}
}

void legacyChargerConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	syncLegacyChargerConfig();
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon) {
	if (!isAiCharger(client))
		return Plugin_Continue;

	// BehaviorMoveTo 无法被 actions.ext 捕获, 因此从始终执行的 RunCmd 维护 BOT_CMD_MOVE 的目标坐标
	maintainEvadeMoveCommand(client);

	if (GetEntityMoveType(client) == MOVETYPE_LADDER) {
		buttons &= ~IN_JUMP;
		buttons &= ~IN_DUCK;
	}

	static int ability;
	ability = getChargeAbilityEnt(client);
	if (!IsValidEdict(ability))
		return Plugin_Continue;
	static bool isCharging;
	isCharging = view_as<bool>(GetEntProp(ability, Prop_Send, "m_isCharging"));
	if (isCharging && g_AiChargers[client].m_bChargeDelayed)
		g_AiChargers[client].m_bChargeDelayed = false;
	
	static int target;
	target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
	if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
		return Plugin_Continue;

	if (g_ChargerStateContext[client].userId != GetClientUserId(client)) {
		g_AiChargers[client].init();
		// 目标变化, 重置状态
		g_ChargerStateContext[client].init(client);
		g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
	}

	// 执行当前状态的每帧行为更新操作
	return g_ChargerStateContext[client].update(buttons, vel, angles);
}

void evtRoundStart(Event event, const char[] name, bool dontBroadcast) {

}

void evtRoundEnd(Event event, const char[] name, bool dontBroadcast) {

}

void evtPlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	static int client;
	client = GetClientOfUserId(event.GetInt("userid"));
	if (!isAiCharger(client))
		return;
	
	// 新的 charger, 重置状态
	g_AiChargers[client].init();
	g_ChargerStateContext[client].init(client);
	g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
}

public void OnMapStart() {
	GetVectorShowSprite();
}

public void OnMapEnd() {

}

public Action L4D2_OnChooseVictim(int client, int &curTarget) {
	if (!isAiCharger(client))
		return Plugin_Continue;

	int selected = selectLegacyCompatibleTarget(client, curTarget);
	if (selected > 0 && selected != curTarget)
	{
		curTarget = selected;
		g_AiChargers[client].m_iTarget = GetClientUserId(selected);
		return Plugin_Changed;
	}

	if (IsValidSurvivor(curTarget) && IsPlayerAlive(curTarget))
		g_AiChargers[client].m_iTarget = GetClientUserId(curTarget);
	return Plugin_Continue;
}

bool isLegacyTargetCandidate(int client, int target, const float origin[3], float &distance)
{
	if (target == client || !IsValidSurvivor(target) || !IsPlayerAlive(target))
		return false;
	if (IsClientIncapped(target) || IsClientHanging(target) || IsClientPinned(target))
		return false;

	float targetPos[3];
	GetClientAbsOrigin(target, targetPos);
	distance = GetVectorDistance(origin, targetPos);
	return distance >= g_fLegacyExtraTargetMin && distance <= g_fLegacyExtraTargetMax;
}

int selectLegacyCompatibleTarget(int client, int currentTarget)
{
	if (!g_cvLegacyTarget || g_cvLegacyTarget.IntValue <= 1)
		return (IsValidSurvivor(currentTarget) && IsPlayerAlive(currentTarget)) ? currentTarget : getClosestSurvivorAndValid(client);

	float origin[3];
	GetClientAbsOrigin(client, origin);

	int bestTarget = -1;
	float bestDistance = 999999.0;
	float bestScore = 999999999.0;
	int mode = g_cvLegacyTarget.IntValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		float distance;
		if (!isLegacyTargetCandidate(client, i, origin, distance))
			continue;

		if (mode == 2)
		{
			if (distance < bestDistance)
			{
				bestDistance = distance;
				bestTarget = i;
			}
			continue;
		}

		float candidatePos[3];
		GetClientAbsOrigin(i, candidatePos);
		float crowdScore = 0.0;
		for (int j = 1; j <= MaxClients; j++)
		{
			if (j == client || !IsValidSurvivor(j) || !IsPlayerAlive(j))
				continue;

			float survivorPos[3];
			GetClientAbsOrigin(j, survivorPos);
			crowdScore += GetVectorDistance(candidatePos, survivorPos, true);
		}

		if (crowdScore < bestScore)
		{
			bestScore = crowdScore;
			bestTarget = i;
		}
	}

	if (bestTarget > 0)
		return bestTarget;
	if (IsValidSurvivor(currentTarget) && IsPlayerAlive(currentTarget))
		return currentTarget;
	return getClosestSurvivorAndValid(client);
}

// PathFollower::Update(long double a1@<st0>, PathFollower *this, INextBot *a3)
// PathFollower::Update 首次执行晚于 OnPlayerRunCmd, 并且频率大概是 OnPlayerRunCmd 的 1/3
MRESReturn Detour_PathFollower_Update(Address pThis, Handle hParams) {
	if (!pThis) {
		stateLog.error("Detour for signature: %s got null this pointer", SIG_PATH_FOLLOWER_UPDATE);
		return MRES_Ignored;
	}
	if (!hParams) {
		stateLog.error("Detour for signature: %s got null params handle", SIG_PATH_FOLLOWER_UPDATE);
		return MRES_Ignored;
	}

	// 首先获取 client index
	static Address pNextBot;
	pNextBot = view_as<Address>(DHookGetParam(hParams, 1));
	if (!pNextBot) {
		stateLog.error("Detour for signature: %s got null parameter 1: nextbot pointer", SIG_PATH_FOLLOWER_UPDATE);
		return MRES_Ignored;
	}
	static int client;
	client = SDKCall(g_hSdkNextBotGetCombatCharacter, pNextBot);
	if (!isAiCharger(client))
		return MRES_Ignored;

	// 保存 IPathFollower 指针, 用于路径前瞻与失效化处理
	g_AiChargers[client].m_pPathFollower = pThis;

	// v37 = *((_DWORD *)this + 4566); 因为 this 被转成了 DWORD 类型, 因此后面的偏移量 4566 也是基于 4 字节的
	static Address pPathSeg, pNextSeg, pLastSeg;
	static PathSegment curSegment, nextSegment, lastSegment;
	// Current Segment struct
	pPathSeg = view_as<Address>(SDKCall(g_hSdkPathGetCurGoal, pThis));
	if (!pPathSeg) {
		g_AiChargers[client].m_PathSegment.init();
		return MRES_Ignored;
	} else {
		constructPathSegment(pPathSeg, curSegment);
		g_AiChargers[client].m_PathSegment = curSegment;
	}

	// Next Segment struct
	pNextSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pThis, pPathSeg));
	if (!pNextSeg) {
		g_AiChargers[client].m_NextPathSegment.init();
	} else {
		constructPathSegment(pNextSeg, nextSegment);
		g_AiChargers[client].m_NextPathSegment = nextSegment;
	}

	// Last Segment struct
	// class PathFollower : public Path; PathFollower 继承自 Path, 可以使用 Path 类中的虚函数 Path::LastSegment
	pLastSeg = view_as<Address>(SDKCall(g_hSdkPathLastSegment, pThis));
	if (!pLastSeg) {
		g_AiChargers[client].m_LastPathSegment.init();
	} else {
		constructPathSegment(pLastSeg, lastSegment);
		g_AiChargers[client].m_LastPathSegment = lastSegment;
	}

	// 检查落后的 m_goal；无法在剩余路径中重新定位时，无效化旧路径并等待原生 Action 重新寻路。
	checkGoalIsBehind(client, pThis, pPathSeg);
	return MRES_Ignored;
}

void checkGoalIsBehind(int client, Address pPathFollower, Address pCurrentSeg) {
	if (!isAiCharger(client))
		return;
	if (!pPathFollower)
		return;
	if (!pCurrentSeg)
		return;

	PathSegment curSeg;
	curSeg = g_AiChargers[client].m_PathSegment;
	if (!curSeg.m_pNavArea)
		return;

	Address pLastKnownArea = L4D_GetLastKnownArea(client);
	if (!pLastKnownArea) {
		static float pos[3];
		GetClientAbsOrigin(client, pos);
		pos[2] += 20.0;
		pLastKnownArea = view_as<Address>(L4D_GetNearestNavArea(pos, _, _, true, true, TEAM_INFECTED));

		if (!pLastKnownArea) {
			log.error("[CheckGoalIsBehind]: Failed to get client %N's LastKnownArea or nearest NavArea", client);
			return;
		}
	}

	/*
	 * 原生 CheckProgress 的 LookAhead 机制可能一次跳过多个 Segment, 虽然 LookAhead Range 一般会被设置成 0, 所以是关闭的
	 * 但是为了防止这种情况, 考虑 LookAhead 机制, 开启 LookAhead 时, LastKnownArea 位于 CurrentGoal
	 * 之前的任意 Segment 都可能是正常状态，不能仅检查 PriorSegment
	 */
	static Address pPastSeg;
	static PathSegment pastSeg;
	pPastSeg = pCurrentSeg;
	while (pPastSeg) {
		constructPathSegment(pPastSeg, pastSeg);
		if (pastSeg.m_pNavArea == pLastKnownArea)
			return;

		pPastSeg = view_as<Address>(SDKCall(g_hSdkPathPriorSegment, pPathFollower, pPastSeg));
	}

	/*
	* 向前检查当前路径的 PathSegment, 检查 LastKnownArea 是否属于 CurrentGoal 本身或者之前的路径
	* 如果是, 说明 Charger 正在朝着 CurrentGoal 或者已经到达了 CurrentGoal, 此时无需干预
	*/
	if (pPastSeg) {
		log.debugAll("[CheckGoalIsBehind]: Aborted prior path scan for Charger %N because found a prior segment (NavId: %d) is same as LastKnownArea (NavId: %d)",
			client, L4D_GetNavAreaID(pastSeg.m_pNavArea)), L4D_GetNavAreaID(pLastKnownArea);
		return;
	}

	/*
	* CurrentGoal 落后于 LastKnownArea 但是 LastKnownArea 仍然在当前 Path 上
	* 从 CurrengSegment 开始向后扫描, 直到 LastKnownArea, 如果找到了一个 Segment 等于 LastKnownArea, 那么将 CurrentGoal 设置为 LastKnownArea 的 Segment
	*/
	static Address pIterSeg, pMatchedSeg;
	pIterSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pPathFollower, pCurrentSeg));
	pMatchedSeg = Address_Null;

	// 从 CurrentGoal 开始向后扫描整段路径
	while (pIterSeg) {
		static PathSegment iterSeg;
		constructPathSegment(pIterSeg, iterSeg);

		if (iterSeg.m_pNavArea == pLastKnownArea) {
			pMatchedSeg = pIterSeg;
			break;
		}

		pIterSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pPathFollower, pIterSeg));
	}

	if (pMatchedSeg) {
		// 进入匹配 NavArea 不代表已经越过该 Segment 的 GoalPos, 因此不再额外跳到 NextSegment
		static Address pNewGoal;
		pNewGoal = pMatchedSeg;
		// 将 PathFollower::m_goal 写成当前 LastKnownArea 对应的 PathSegment 的 m_goal
		StoreToAddress(pPathFollower + view_as<Address>(g_iPathFollowerGoalOffset), pNewGoal, NumberType_Int32);

		static PathSegment newGoalSeg;
		constructPathSegment(pNewGoal, newGoalSeg);
		g_AiChargers[client].m_PathSegment = newGoalSeg;

		static Address pNewNext;
		pNewNext = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pPathFollower, pNewGoal));
		if (pNewNext) {
			static PathSegment newNextSeg;
			constructPathSegment(pNewNext, newNextSeg);
			g_AiChargers[client].m_NextPathSegment = newNextSeg;
		} else {
			g_AiChargers[client].m_NextPathSegment.init();
		}

		// 重新找到了新的 CurrentGoal, 重置空中速度修正坐标
		ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
		g_AiChargers[client].m_AirStrafe.init();

		log.debugAll("[CheckGoalIsBehind]: Advanced Charger %N goal after matching future NavArea %d", client, L4D_GetNavAreaID(pLastKnownArea));
		return;
	}

	/*
	* 如果 LastKnownArea 无法匹配当前 Path 上任何一个节点, 说明 Charger 已经脱离该 Path, 此时需要使旧的 Path 无效化
	* 然后通过 ChargerAttack::Update 这个 Action 重新构造一条新的 Path
	*/
	SDKCall(g_hSdkPathInvalidate, pPathFollower);

	g_AiChargers[client].m_PathSegment.init();
	g_AiChargers[client].m_NextPathSegment.init();
	g_AiChargers[client].m_LastPathSegment.init();
	ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
	g_AiChargers[client].m_AirStrafe.init();
	g_AiChargers[client].m_BhopType = BhopType_None;

	log.debugAll("[CheckGoalIsBehind]: Invalidated Charger %N path because LastKnownArea %d is absent from the remaining path", client, L4D_GetNavAreaID(pLastKnownArea));
}

/**
* 将生还者当前位置解析为适合 BOT_CMD_MOVE 的 Nav 目的地。
* 目标可能站在箱子或处于空中, 因此优先使用当前位置附近的 NavArea,
* LastKnownArea 只作为最后回退, 避免传送后继续使用旧区域。
*/
stock bool getEvadeMoveDestination(int target, float movePos[3]) {
	if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
		return false;

	static float targetPos[3], navQueryPos[3];
	GetClientAbsOrigin(target, targetPos);

	static Address targetNavArea;
	targetNavArea = L4D2Direct_GetTerrorNavArea(targetPos);

	if (!targetNavArea) {
		navQueryPos = targetPos;
		navQueryPos[2] += 20.0;
		targetNavArea = L4D_GetNearestNavArea(navQueryPos, _, false, true, true, TEAM_SURVIVOR);
	}

	if (!targetNavArea)
		targetNavArea = L4D_GetLastKnownArea(target);

	if (!targetNavArea)
		return false;

	L4D_GetNavAreaCenter(targetNavArea, movePos);
	return true;
}

stock void clearEvadeMoveCommandTracking(int client) {
	g_AiChargers[client].m_bEvadeMoveCommandActive = false;
	g_AiChargers[client].m_flLastEvadeMoveToCheckTime = 0.0;
	ZeroVector(g_AiChargers[client].m_vecEvadeMoveToPos);
}

stock void stopEvadeMoveCommand(int client, const char[] reason) {
	static bool accepted;
	accepted = L4D2_CommandABot(client, 0, BOT_CMD_RESET);

	log.debugAll("[EvadeMoveCommand]: Reset Charger %N command, accepted: %d, reason: %s", client, accepted, reason);
	clearEvadeMoveCommandTracking(client);
}

/**
* actions.ext 无法观察 CommandABot 创建的 BehaviorMoveTo, 因此由 RunCmd 定时维护命令
* 目标 Nav 目的地变化后只 RESET 旧的 CommandABot MOVE 命令; ChargerEvade 恢复时负责读取新坐标并重新下发 MOVE
*/
stock void maintainEvadeMoveCommand(int client) {
	if (!g_AiChargers[client].m_bEvadeMoveCommandActive)
		return;

	if (!g_cvAntiRetreat.BoolValue) {
		stopEvadeMoveCommand(client, "anti-retreat disabled");
		return;
	}

	if (isChargerCharging(client) ||
		IsValidSurvivor(L4D2_GetQueuedPummelVictim(client)) ||
		IsValidSurvivor(L4D_GetVictimCharger(client)) ||
		IsValidSurvivor(L4D_GetVictimCarry(client))
	) {
		stopEvadeMoveCommand(client, "charging or pinning");
		return;
	}

	static int target;
	target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
	if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
		stopEvadeMoveCommand(client, "target invalid");
		return;
	}

	/*
	* 检查旧的目标位置是否仍然有效, 目标移动超过 EVADE_MOVETO_REFRESH_MIN_DIST 时, 下达 BOT_CMD_RESET 恢复 Charger 原生行为
	* 如果 ChargerEvade 继续生效, 那么会尝试获取新的目标位置, 下达 BOT_CMD_MOVE 命令
	*/
	static float now;
	now = GetEngineTime();
	if (now - g_AiChargers[client].m_flLastEvadeMoveToCheckTime < g_cvEvadeMoveToRefreshInterval.FloatValue)
		return;

	g_AiChargers[client].m_flLastEvadeMoveToCheckTime = now;

	static float newMovePos[3];
	if (!getEvadeMoveDestination(target, newMovePos)) {
		log.debugAll("[EvadeMoveCommand]: Failed to resolve target %N's current move destination", target);
		return;
	}

	static float movedDist;
	movedDist = GetVectorDistance(g_AiChargers[client].m_vecEvadeMoveToPos, newMovePos);
	if (movedDist < EVADE_MOVETO_REFRESH_MIN_DIST)
		return;

	/*
	* 不在这里更新旧坐标或清除 active 标记。若 RESET 未生效, 下一周期仍会重试
	* 若 RESET 生效, 恢复的 ChargerEvade 会重新下发 MOVE 并写入新坐标
	*/
	static bool accepted;
	accepted = L4D2_CommandABot(client, 0, BOT_CMD_RESET);
	log.debugAll("[EvadeMoveCommand]: Target %N destination moved %.2f units, reset Charger %N command, accepted: %d",
		target, movedDist, client, accepted);
}

// ============================================================
// Action Extension
// ============================================================
public void OnActionCreated(BehaviorAction action, int actor, const char[] name) {
	if (action == INVALID_ACTION || !isAiCharger(actor))
		return;

	if (g_cvAntiRetreat.BoolValue) {
		if (strcmp(name, ACT_NAME_CHARGER_EVADE, false) == 0) {
			action.OnUpdate = chargerEvade_OnUpdate;
			action.OnEnd = chargerEvade_OnEnd;
		}
	}
	// 防止 charger 刷新距离生还者很近时, 游戏强制冲撞, 但是 APPROACH STATE 同时将 Charger 能力就绪时间设置为 1 秒后, 导致 Charger 原地卡住
	if (strcmp(name, ACT_NAME_CHARGE_AT_VICTIM, false) == 0) {
		action.OnUpdate = chargerChargeAtVictim_OnUpdate;
	}
}

Action chargerEvade_OnUpdate(BehaviorAction action, int actor, float interval, ActionResult result) {
	if (!isAiCharger(actor)) {
		return Plugin_Continue;
	}
	if (!g_cvAntiRetreat.BoolValue) {
		clearEvadeMoveCommandTracking(actor);
		return Plugin_Continue;
	}
	// 撞停准备控人的时候有时候会触发 Evade 行为
	if (isChargerCharging(actor) ||
		IsValidSurvivor(L4D2_GetQueuedPummelVictim(actor)) ||
		IsValidSurvivor(L4D_GetVictimCharger(actor)) ||
		IsValidSurvivor(L4D_GetVictimCarry(actor))
	) {
		return Plugin_Continue;
	}

	static int target;
	target = GetClientOfUserId(g_AiChargers[actor].m_iTarget);
	if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
		return Plugin_Continue;
	}
	
	static float movePos[3];
	if (!getEvadeMoveDestination(target, movePos)) {
		log.debugAll("[ChargerEvadeOnUpdate]: Failed to resolve target %N's move destination", target);
		return Plugin_Continue;
	}

	/* static float movePos_cpy[3];
	movePos_cpy = movePos;
	movePos_cpy[2] += 200.0;
	ShowPos(COLOR_GREEN, movePos, movePos_cpy); */

	g_AiChargers[actor].m_vecEvadeMoveToPos = movePos;
	g_AiChargers[actor].m_flLastEvadeMoveToCheckTime = GetEngineTime();
	g_AiChargers[actor].m_bEvadeMoveCommandActive = true;

	/*
	* accepted 大概率是 false, 不知道为什么, 使用 nb_debug BEHAVIOR 可以看到 BehaviorMoveTo << ChargerEvade << ChargerAttack
	* 但是 actions 拓展的 OnActionCreated 却无法捕捉到 BehaviorMoveTo 的创建, 无论是 raw action 还是验证过的有效 action 都无法捕捉
	*/
	static bool accepted;
	accepted = L4D2_CommandABot(actor, target, BOT_CMD_MOVE, movePos);
	log.debugAll("[ChargerEvadeOnUpdate]: CommandABot MOVE acctpted: %d", accepted);

	/*
	* 不能在这里直接 action.Done(), 因为 CommandABot 这个 Action 创建成功之后, BehaviorMoveTo 应当暂停 ChargerEvade
	* 如果直接 Done, 那么由 ChargerEvade 派生出来的 BehaviorMoveTo 也会被跟着 ChargerEvade 释放掉
	*/
	return Plugin_Changed;
}

void chargerEvade_OnEnd(BehaviorAction action, int actor, BehaviorAction nextAction, ActionResult result) {
	if (!isAiCharger(actor))
		return;

	g_AiChargers[actor].m_bEvadeMoveCommandActive = false;
	g_AiChargers[actor].m_flLastEvadeMoveToCheckTime = 0.0;
	ZeroVector(g_AiChargers[actor].m_vecEvadeMoveToPos);
}

Action chargerChargeAtVictim_OnUpdate(BehaviorAction action, int actor, float interval, ActionResult result) {
	if (!isAiCharger(actor))
		return Plugin_Continue;

	/*
		防止 Charger 刷新后满足冲锋条件, 引擎立即让其冲锋, 但插件进入 APPROACH STATE 会设置能力延时, 导致其无法进行冲锋而在原地罚站
		既然插件接管了, 就必须在 CHARGING STATE 中手动冲锋, 其他不在 CHARGING STATE 中的冲锋都视为非法, 直接停止
	*/
	static int curState;
	curState = g_ChargerStateContext[actor].currentStateId;
	if (curState != CH_STATE_CHARGING) {
		log.debugAll("Charger (%N) try to charge, but in approach state, force stop charge", actor);
		action.Done();
		return Plugin_Changed;
	}
	return Plugin_Continue;
}
