#pragma semicolon 1 
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#include <treeutil>
#include <logger2>
//#include <vector_show>

#define CVAR_FLAGS FCVAR_NOTIFY
#define PLUGIN_PREFIX "Ai-Tank3"

#define GAMEDATA "l4d2_ai_tank3"

#define DEFAULT_THROW_FORCE 		800.0
#define DEFAULT_SV_GRAVITY 			800.0
#define DEFAULT_SWING_RANGE 		56.0
#define ROCK_FL_GRAVITY 			0.4				// 石头重力因子

#define PLAYER_HEIGHT 				72.0
#define PLAYER_EYE_HEIGHT 			62.0
#define PLAYER_CHEST 				52.0
#define TANK_HEIGHT 				84.0
#define JUMP_HEIGHT 				56.0

#define THROW_UNDERHEAD_POS_Z 		33.38		// e 砖出手坐标
#define THROW_OVERSHOULDER_POS_Z 	93.58 	// 单手过头出手坐标
#define THROW_OVERHEAD_POS_Z 		104.01		// 双手过头出手坐标

#define JUMP_SPEED_Z 				300.0

ConVar
	g_cvPluginName,
	g_cvLogLevel;

ConVar
	g_cvEnable,
	g_cvTankBhop,
	g_cvBhopMinDist,
	g_cvBhopMaxDist,
	g_cvBhopMinSpeed,
	g_cvBhopMaxSpeed,
	g_cvBhopImpulse,
	g_cvBhopNoVision,
	g_cvThrowMinDist,
	g_cvThrowMaxDist,
	g_cvAirVecModifyDegree,
	g_cvAirVecModifyMaxDegree,
	g_cvAirVecModifyInterval,
	g_cvClimbAnimRate,
	g_cvRockTargetAdjust,
	g_cvBackFist,
	g_cvBackFistRange,
	g_cvBackFistAllowMaxSpd,
	g_cvPunchLockVision,
	g_cvJumpRock,
	// NEW: 通背拳窗口秒数
	g_cvBackFistWindow;

ConVar
	g_cvBhopNoVisionMaxAng;

ConVar
	cvTankSwingRange;

StringMap
	g_hThrowAnimMap,
	g_hClimbAnimMap;

Handle
	g_hSdkTankClawSweepFist;

bool
	g_bLateLoad;

float
	g_fTankSwingRange;

enum struct AiTank {
	int		target; 					// 攻击目标 (userId)
	float	lastAirVecModifyTime; 		// 上次空中速度修正时间 (EngineTime)
	float	nextAttackTime; 			// 下次挥拳时间 (EngineTime)
	bool	wasThrowing; 				// 是否正在扔石头
	float	lastHopSpeed; 				// 上次起跳时的速度
	// NEW: 通背拳窗口到期时间（EngineTime，<=0 表示未开启）
	float	backFistExpire;

	void initData() {
		this.target = -1;
		this.lastAirVecModifyTime = 0.0;
		this.nextAttackTime = 0.0;
		this.wasThrowing = false;
		this.lastHopSpeed = 0.0;
		this.backFistExpire = 0.0;
	}
}
AiTank g_AiTanks[MAXPLAYERS + 1];

Logger log;

enum TankSequenceType {
	tankSequence_Throw,
	tankSequence_Climb,
}

#include "./stocks.sp"

public Plugin myinfo = 
{
	name 			= "Ai-Tank 3",
	author 			= "夜羽真白",
	description 	= "Ai Tank 增强 3.0 版本",
	version 		= "1.0.0.0",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	EngineVersion version = GetEngineVersion();
	if (version != Engine_Left4Dead2) {
		strcopy(error, err_max, "本插件仅支持 Left 4 Dead 2");
		return APLRes_SilentFailure;
	}
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart() {

	// plugin enable?
	g_cvEnable = CreateConVar("ai_tank3_enable", "1", "是否启用插件, 0=禁用, 1=启用", CVAR_FLAGS, true, 0.0, true, 1.0);
	// allow tank to bhop?
	g_cvTankBhop = CreateConVar("ai_tank_bhop", "1", "是否允许坦克连跳, 0=禁用, 1=启用", CVAR_FLAGS, true, 0.0, true, 1.0);
	// tank can bhop when he and his target are within the distance (ai_tank3_bhop_min_dist, ai_tank3_bhop_max_dist) 
	g_cvBhopMinDist = CreateConVar("ai_Tank_StopDistance", "135", "停止连跳的最小距离", CVAR_FLAGS, true, 0.0);
	g_cvBhopMaxDist = CreateConVar("ai_tank3_bhop_max_dist", "9999", "开始连跳的最大距离", CVAR_FLAGS, true, 0.0);
	// when tank's speed is higher than 'ai_tank3_bhop_min_speed', he is allowed to bhop, and his max bhop speed will not above 'ai_tank3_bhop_max_speed'
	g_cvBhopMinSpeed = CreateConVar("ai_tank3_bhop_min_speed", "200", "连跳的最小速度", CVAR_FLAGS, true, 0.0);
	g_cvBhopMaxSpeed = CreateConVar("ai_tank3_bhop_max_speed", "1000", "连跳的最大速度", CVAR_FLAGS, true, 0.0);
	// used to control the speed acceleration during tank each jump from the ground
	g_cvBhopImpulse = CreateConVar("ai_tank3_bhop_impulse", "60", "连跳的加速度", CVAR_FLAGS, true, 0.0);
	// allow tank to bhop when he has no sight to any survivor
	g_cvBhopNoVision = CreateConVar("ai_tank3_bhop_no_vision", "1", "是否允许坦克在无生还者视野时连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
	// when tank has no sight of any survivors, he is allowed to bhop when his speed vector and eye angle forward vector within this degree
	g_cvBhopNoVisionMaxAng = CreateConVar("_ai_tank3_bhop_nvis_maxang", "75.0", "无生还者视野时速度向量与视角前向向量在这个角度范围内, 允许连跳", CVAR_FLAGS, true, 0.0);
	// when the angle that tank's speed vector and his direction vector towards the target is within (ai_tank3_airvec_modify_degree, ai_tank3_airvec_modify_degree_max), when tank is in air, tank will modify the speed vector at interval: ai_tank3_airvec_modify_interval (this will push tank to his target direction)
	g_cvAirVecModifyDegree = CreateConVar("ai_tank3_airvec_modify_degree", "45.0", "在空中速度方向与自身到目标方向角度超过这个值进行速度修正", CVAR_FLAGS, true, 0.0);
	g_cvAirVecModifyMaxDegree = CreateConVar("ai_tank3_airvec_modify_degree_max", "135.0", "在空中速度方向与自身到目标方向角度超过这个值不进行速度修正", CVAR_FLAGS, true, 0.0);
	g_cvAirVecModifyInterval = CreateConVar("ai_tank3_airvec_modify_interval", "0.3", "空中速度修正间隔", CVAR_FLAGS, true, 0.1);
	// tank is allowed to throw rock when he and his target are within the distance (ai_tank3_throw_min_dist, ai_tank3_throw_max_dist)
	g_cvThrowMinDist = CreateConVar("ai_tank3_throw_min_dist", "0", "允许扔石头的最小距离(小于这个距离不允许扔)", CVAR_FLAGS, true, 0.0);
	g_cvThrowMaxDist = CreateConVar("ai_tank3_throw_max_dist", "800", "允许扔石头的最大距离(大于这个距离不允许扔)", CVAR_FLAGS, true, 0.0);
	// you can use the value of 'ai_tank3_climb_anim_rate' to accelerate the animation rate when tank is climbing over some obstacle
	g_cvClimbAnimRate = CreateConVar("ai_tank3_climb_anim_rate", "5.0", "Tank攀爬动画播放速率(是否加速攀爬动作, 1.0=正常倍速)", CVAR_FLAGS, true, 0.0);
	// when tank throwing rock and his target is not visible, allow tank to switch target and throw to new survivor that is visible and closest to tank?
	g_cvRockTargetAdjust = CreateConVar("ai_tank3_rock_target_adjust", "1", "扔石头时目标不可见是否允许切换目标", CVAR_FLAGS, true, 0.0, true, 1.0);
	// allow tank to punch survivor who is behind him?
	g_cvBackFist = CreateConVar("ai_tank3_back_fist", "1", "是否允许Tank使用通背拳(在背后的人也会被拍)", CVAR_FLAGS, true, 0.0, true, 1.0);
	// allow tank to punch survivor who is behind him and within this range (set to -1 to use default: tank_swing_range)
	g_cvBackFistRange = CreateConVar("ai_tank3_back_fist_range", "128.0", "允许使用通背拳时背后的打击检测距离, -1 使用默认(tank_swing_range)", CVAR_FLAGS, true, -1.0);
	// allow tank to punch survivor who is behind him when his speed is lower than this value (最大速度)
	g_cvBackFistAllowMaxSpd = CreateConVar("ai_tank3_back_fist_max_spd", "50.0", "允许使用通背拳时Tank的最大速度（超过则禁用）", CVAR_FLAGS, true, -1.0);
	// allow tank to lock his vision to his target when punching?
	g_cvPunchLockVision = CreateConVar("ai_tank3_punch_lock_vision", "1", "是否允许Tank打拳时锁定视角到目标", CVAR_FLAGS, true, 0.0, true, 1.0);
	// allow tank to jump when he starts to grab a rock
	g_cvJumpRock = CreateConVar("ai_tank3_jump_rock", "1", "是否允许Tank使用跳砖", CVAR_FLAGS, true, 0.0, true, 1.0);
	// NEW: 通背拳窗口（秒）
	g_cvBackFistWindow = CreateConVar("ai_tank3_back_fist_window", "3.0", "通背拳允许持续时间窗口（秒）。坦克爪击命中生还者后开启/刷新；到期自动关闭", CVAR_FLAGS, true, 0.0);

	// 日志记录 logging
	g_cvPluginName = CreateConVar("ai_tank3_plugin_name", "ai_tank3");

	char cvName[64];
	g_cvPluginName.GetString(cvName, sizeof(cvName));
	FormatEx(cvName, sizeof(cvName), "%s_log_level", cvName);
	// log level: 1=off, 2=console, 4=log file, 8=chat, 16=server console, 32=error file, add them together
	g_cvLogLevel = CreateConVar(cvName, "32", "日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 数字相加", CVAR_FLAGS);

	HookEvent("round_start", evtRoundStart);
	HookEvent("round_end", evtRoundEnd);
	// NEW: 爪击命中时刷新通背拳窗口
	HookEvent("player_hurt", evtPlayerHurt, EventHookMode_Post);

	log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);
	// 初始化动画序列 HashMap
	initAnimMap();

	if (g_bLateLoad) {
		for (int i = 1; i <= MaxClients; i++) {
			if (!IsValidClient(i))
				continue;
			OnClientPutInServer(i);
		}
	}

}

public void OnAllPluginsLoaded() {
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(path))
		SetFailState("Mising required gamedata file: %s.", path);

	Handle hGamedata = LoadGameConfigFile(GAMEDATA);
	if (!hGamedata)
		SetFailState("Failed to load %s gamedata.", GAMEDATA);

	// ============================================================
	// CTankClaw::SweepFist
	// ============================================================
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGamedata, SDKConf_Signature, "CTankClaw::SweepFist");
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSdkTankClawSweepFist = EndPrepSDKCall();
	if (!g_hSdkTankClawSweepFist)
		SetFailState("Failed to find signature for CTankClaw::SweepFist.");

	delete hGamedata;
}

public void OnConfigsExecuted() {
	cvTankSwingRange = FindConVar("tank_swing_range");
	g_fTankSwingRange = !cvTankSwingRange ? DEFAULT_SWING_RANGE : cvTankSwingRange.FloatValue;
	if (!cvTankSwingRange)
		cvTankSwingRange.AddChangeHook(changeHookTankSwingRange);
}

public void OnPluginEnd() {
	delete log;
	delete g_hThrowAnimMap;
	delete g_hClimbAnimMap;
}

void evtRoundStart(Event event, const char[] name, bool dontBroadcast) {
	// NEW: 清空所有坦克的通背拳窗口
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i)) continue;
		g_AiTanks[i].backFistExpire = 0.0;
	}
}

void evtRoundEnd(Event event, const char[] name, bool dontBroadcast) {
	// NEW: 结束时也清空
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsValidClient(i)) continue;
		g_AiTanks[i].backFistExpire = 0.0;
	}
}

public void OnMapStart() {
//	vectorShowOnMapStart();
}

public void OnMapEnd() {

}

void changeHookTankSwingRange(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_fTankSwingRange = convar.FloatValue;
	log.debugAll("tank_swing_range changed to %d", convar.IntValue);
}

stock void initAnimMap() {
	if (!g_hThrowAnimMap)
		g_hThrowAnimMap = new StringMap();
	if (!g_hClimbAnimMap)
		g_hClimbAnimMap = new StringMap();
	
	// 扔石头动画 ActivityName
	g_hThrowAnimMap.SetValue("ACT_SIGNAL2", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL3", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL_ADVANCE", true);
	// 攀爬动画 ActivityName
	g_hClimbAnimMap.SetValue("ACT_RANGE_ATTACK1", true);
	g_hClimbAnimMap.SetValue("ACT_RANGE_ATTACK2", true);
	g_hClimbAnimMap.SetValue("ACT_RANGE_ATTACK1_LOW", true);
	g_hClimbAnimMap.SetValue("ACT_RANGE_ATTACK2_LOW", true);
	g_hClimbAnimMap.SetValue("ACT_DIESIMPLE", true);
	g_hClimbAnimMap.SetValue("ACT_DIEBACKWARD", true);
	g_hClimbAnimMap.SetValue("ACT_DIEFORWARD", true);
	g_hClimbAnimMap.SetValue("ACT_DIEVIOLENT", true);
}

// ============================================================
// Main
// ============================================================
public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3]) {
	if (!g_cvEnable.BoolValue || !isAiTank(client))
		return Plugin_Continue;
	
	static int target;
	target = GetClientOfUserId(g_AiTanks[client].target);
	if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
		return Plugin_Continue;
	static float pos[3], targetPos[3], dist;
	GetClientAbsOrigin(client, pos);
	GetClientAbsOrigin(target, targetPos);
	dist = GetVectorDistance(pos, targetPos);

	// 打拳时是否锁定视角
	punchLockVision(client, target, pos, targetPos);
	// 检查是否允许扔石头
	checkEnableThrow(client, buttons, pos, targetPos, dist);
	// 检查是否允许连跳
	checkEnableBhop(client, target, buttons, pos, targetPos, dist);

	return Plugin_Continue;
}

// 保证一直能够获取到 Tank 当前目标
public Action L4D2_OnChooseVictim(int client, int &curTarget) {
	if (!isAiTank(client) || !IsValidSurvivor(curTarget))
		return Plugin_Continue;
	
	// 检查当前的目标和目标缓存中的目标是否一致
	static int cachedTarget;
	cachedTarget = GetClientOfUserId(g_AiTanks[client].target);
	if (!IsValidClient(cachedTarget) || cachedTarget != curTarget)
		g_AiTanks[client].target = GetClientUserId(curTarget);
	
	return Plugin_Continue;
}

// ============================================================
// 通背拳 Back Fist
// ============================================================
// 小工具：当前是否允许通背拳（窗口 + 地面 + 基础开关）
stock bool IsBackFistAllowedNow(int tank)
{
	if (!g_cvBackFist.BoolValue)             return false;
	if (!isAiTank(tank))                     return false;
	if (!IsClientOnGround(tank))             return false;                // 必须在地上
	if (GetEntityMoveType(tank) == MOVETYPE_LADDER) return false;        // 梯子上不行
	float now = GetEngineTime();
	return (g_AiTanks[tank].backFistExpire > 0.0 && now <= g_AiTanks[tank].backFistExpire);
}

public void L4D_TankClaw_DoSwing_Post(int tank, int claw) {
	if (!g_cvBackFist.BoolValue)
		return;
	if (!isAiTank(tank))
		return;

	// 速度阈值：速度过高则不允许通背拳（按你的要求保留）
	static float vAbsVelVec[3], speed;
	GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
	speed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
	if (speed > g_cvBackFistAllowMaxSpd.FloatValue)
		return;

	// 时间窗口 + 地面限制
	if (!IsBackFistAllowedNow(tank))
		return;

	static float pos[3], targetPos[3], fistRange;
	fistRange = g_cvBackFistRange.IntValue >= 0 ? g_cvBackFistRange.FloatValue : g_fTankSwingRange;

	GetClientEyePosition(tank, pos);
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
			continue;
		GetClientEyePosition(i, targetPos);
		if (GetVectorDistance(pos, targetPos) > fistRange)
			continue;
		if (!clientIsVisibleToClient(tank, i))
			continue;

		// SweepFist 从 start 到 end 扫描, 检测碰撞
		SDKCall(g_hSdkTankClawSweepFist, claw, targetPos, targetPos);
	}
}

// NEW: 爪击命中 -> 刷新通背拳窗口
void evtPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (!IsValidSurvivor(victim))        return;
	if (!IsValidClient(attacker))        return;
	if (!isAiTank(attacker))             return;

	// 仅认“爪击”
	char wep[64];
	GetEventString(event, "weapon", wep, sizeof(wep));
	bool isClaw = StrEqual(wep, "tank_claw", false) || StrEqual(wep, "tank", false);
	if (!isClaw) {
		int claw = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
		if (claw > 0 && IsValidEdict(claw)) {
			char cls[64];
			GetEntityClassname(claw, cls, sizeof(cls));
			if (StrEqual(cls, "weapon_tank_claw", false)) {
				isClaw = true;
			}
		}
	}
	if (!isClaw) return;

	// 命中 -> 开启/刷新窗口
	g_AiTanks[attacker].backFistExpire = GetEngineTime() + g_cvBackFistWindow.FloatValue;
	// log.debugAll("%N claw hit -> backfist window refresh to %.2f", attacker, g_AiTanks[attacker].backFistExpire);
}

Action punchLockVision(int client, int target, const float pos[3], const float targetPos[3]) {
	if (!g_cvPunchLockVision.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
		return Plugin_Continue;

	static int claw;
	claw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (!claw || !IsValidEdict(claw))
		return Plugin_Continue;

	if (!HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack"))
		return Plugin_Continue;

	static float nextAtk;
	nextAtk = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
	if (g_AiTanks[client].nextAttackTime < GetEngineTime() && nextAtk > GetGameTime()) {
		static float vLookAt[3], vDir[3];
		MakeVectorFromPoints(pos, targetPos, vLookAt);
		GetVectorAngles(vLookAt, vDir);
		TeleportEntity(client, NULL_VECTOR, vDir, NULL_VECTOR);
	}
	g_AiTanks[client].nextAttackTime = nextAtk;
	return Plugin_Continue;
}

// ============================================================
// 连跳操作 BunnyHop
// ============================================================
Action checkEnableBhop(int client, int target, int& buttons, const float pos[3], const float targetPos[3], float dist) {
	if (!g_cvTankBhop.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
		return Plugin_Continue;
	
	if (L4D_IsPlayerStaggering(client))
		return Plugin_Continue;

	// 爬梯子时或者水深超过浅水, 则不允许连跳
	if (GetEntityMoveType(client) == MOVETYPE_LADDER || GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
		return Plugin_Continue;

	static float velVec[3], vel;
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
	// 仅检测水平速度是否满足连跳速度要求
	vel = SquareRoot(Pow(velVec[0], 2.0) + Pow(velVec[1], 2.0));
	if (vel < g_cvBhopMinSpeed.FloatValue)
		return Plugin_Continue;

	if (dist < g_cvBhopMinDist.FloatValue || dist > g_cvBhopMaxDist.FloatValue)
		return Plugin_Continue;

	static float vAbsVelVec[3], vTargetAbsVelVec[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
	GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

	// 在地上的时候, 开始连跳
	static bool visible;
	static float l_targetPos[3];
	l_targetPos = targetPos;
	visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, 0, 0, l_targetPos);
	if (IsClientOnGround(client) && nextTickPosCheck(client, visible)) {
		static float vPredict[3], vDir[3], vFwd[3], vRight[3];
		// 不可见目标的情况下, 使用当前速度向量方向进行连跳加速
		if (!visible) {
			NormalizeVector(velVec, vFwd);
		} else {
			// 计算目标下一帧的位置, 然后根据这个位置进行连跳加速
			AddVectors(targetPos, vTargetAbsVelVec, vPredict);
			MakeVectorFromPoints(pos, vPredict, vDir);
			vDir[2] = 0.0;
			NormalizeVector(vDir, vDir);
			// 将 vFwd 设为 vDir, 后续一致使用 vFwd 作为前向向量
			vFwd = vDir;
		}

		// 无生还视野不允许连跳
		if (!g_cvBhopNoVision.BoolValue && !visible)
			return Plugin_Continue;

		buttons |= IN_DUCK;
		buttons |= IN_JUMP;

		static bool fwdOnly, backOnly, leftOnly, rightOnly;
		fwdOnly = ((buttons & IN_FORWARD) && !(buttons & IN_BACK));
		backOnly = ((buttons & IN_BACK) && !(buttons & IN_FORWARD));
		leftOnly = ((buttons & IN_LEFT) && !(buttons & IN_RIGHT));
		rightOnly = ((buttons & IN_RIGHT) && !(buttons & IN_LEFT));

		if (fwdOnly) {
			NormalizeVector(vFwd, vFwd);
			ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
			AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
		} else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0)) {
			// 仅按后退键, 向当前速度方向进行加速
			vFwd[0] = velVec[0];
			vFwd[1] = velVec[1];
			vFwd[2] = 0.0;
			NormalizeVector(vFwd, vFwd);
			ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
			AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
		} else {
			// 按左右方向键的时候, 基于当前前向加速度方向计算侧向向量
			static float baseFwd[3];
			if (fwdOnly) {
				baseFwd[0] = vFwd[0];
				baseFwd[1] = vFwd[1];
				baseFwd[2] = 0.0;
			} else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0)) {
				baseFwd[0] = velVec[0];
				baseFwd[1] = velVec[1];
				baseFwd[2] = 0.0;
			} else {
				baseFwd[0] = vDir[0];
				baseFwd[1] = vDir[1];
				baseFwd[2] = 0.0;
			}
			// 计算左向或者右向向量进行加速
			GetVectorCrossProduct({0.0, 0.0, 1.0}, baseFwd, vRight);
			NormalizeVector(vRight, vRight);
			if (rightOnly ^ leftOnly) {
				vRight[2] = 0.0;
				ScaleVector(vRight, g_cvBhopImpulse.FloatValue * (rightOnly ? 1.0 : -1.0));
				AddVectors(vAbsVelVec, vRight, vAbsVelVec);
			}
		}
		// 记录起跳时的速度
		g_AiTanks[client].lastHopSpeed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
		return Plugin_Changed;
	}

	// 检查空速是否大于限制速度
	if (vel > g_cvBhopMaxSpeed.FloatValue) {
		NormalizeVector(velVec, velVec);
		ScaleVector(velVec, g_cvBhopMaxSpeed.FloatValue);
		SetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
	}
	// 在空中的时候, 检查是否连跳过头
	static float angle, vDir[3], vAbsVelVecCpy[3];
	vAbsVelVecCpy = vAbsVelVec;
	NormalizeVector(vAbsVelVec, vAbsVelVec);
	MakeVectorFromPoints(pos, targetPos, vDir);
	NormalizeVector(vDir, vDir);
	vAbsVelVec[2] = vDir[2] = 0.0;

	// 防止玩家在坦克上方或者下方时频繁触发空中速度修正
	static float dx, dz, pitch;
	dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
	dz = targetPos[2] - pos[2];
	pitch = RadToDeg(ArcTangent(dz / dx));
	// 如果玩家不在坦克的攻击范围内且俯仰角大于 45 度, 放弃速度修正
	// if target is not in tank's attack range and pitch is greater than 45.0, give up air speed modification
	if (dz > (JUMP_HEIGHT + TANK_HEIGHT + g_fTankSwingRange) && pitch > 45.0)
		return Plugin_Continue;

	/**
	* 空中速度修正, 条件必须满足:
	1. 可视
	2. 当前速度方向向量和到目标的位置向量夹角在 min 和 max 间
	3. 没有按后退键才允许修正
	4. 速度方向修正间隔大于 g_cvAirVecModifyInterval.FloatValue (可选)
	**/
	angle = RadToDeg(ArcCosine(GetVectorDotProduct(vAbsVelVec, vDir)));

	static bool inAngleRange, notPressBack, delayExpired;
	inAngleRange = (angle >= g_cvAirVecModifyDegree.FloatValue && angle <= g_cvAirVecModifyMaxDegree.FloatValue);
	notPressBack = !(buttons & IN_BACK);
	delayExpired = (GetEngineTime() - g_AiTanks[client].lastAirVecModifyTime) > g_cvAirVecModifyInterval.FloatValue;
	log.debugAll("Condition visible=%d, inAngleRange=%d, notPressBack=%d, delayExpired=%d", visible, inAngleRange, notPressBack, delayExpired);

	if (visible && inAngleRange && notPressBack && delayExpired)  {
		log.debugAll("%N triggered air speed modify, current vector angle: %.2f", client, angle);
		// 将方向向量缩放成原速度大小, 刚起跳时加速度可能没有应用, 缩放使用的速度为起跳前的速度, 导致连跳无法加速, 因此这里保存加速度并取最大速度缩放
		NormalizeVector(vDir, vDir);
		if (vel < g_AiTanks[client].lastHopSpeed)
			vel = g_AiTanks[client].lastHopSpeed;
		ScaleVector(vDir, vel);
		vDir[2] = vAbsVelVecCpy[2];
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vDir);
		// 记录空中速度方向修正时间
		g_AiTanks[client].lastAirVecModifyTime = GetEngineTime();
	}
	return Plugin_Changed;
}

stock bool nextTickPosCheck(int client, bool visible) {
	if (!isAiTank(client))
		return false;

	static float vMins[3], vMaxs[3];
	GetClientMins(client, vMins);
	GetClientMaxs(client, vMaxs);

	static float pos[3], endPos[3], velVec[3], vel;
	GetClientAbsOrigin(client, pos);
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
	vel = GetVectorLength(velVec);
	NormalizeVector(velVec, velVec);
	// 为下一帧检测的位置留出一些余量 (bbox 宽度 + 3), endPos 为下一帧位置
	ScaleVector(velVec, vel + FloatAbs(vMaxs[0] - vMins[0]) + 3.0);
	AddVectors(pos, velVec, endPos);
	pos[2] += 10.0;
	endPos[2] += 10.0;

	// 射线检测
	static Handle hTrace;
	hTrace = TR_TraceHullFilterEx(pos, endPos, {-36.0, -36.0, 10.0}, {36.0, 36.0, 72.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
	if (TR_DidHit(hTrace)) {
		// 防止下次连跳速度方向撞墙 (速度方向与墙的法向量垂直为 180 度)
		static float rayEndPos[3], hitNormal[3];
		TR_GetEndPosition(rayEndPos, hTrace);
		TR_GetPlaneNormal(hTrace, hitNormal);
		NormalizeVector(hitNormal, hitNormal);
		NormalizeVector(velVec, velVec);
		if (RadToDeg(ArcCosine(GetVectorDotProduct(hitNormal, velVec))) > 165.0) {
			delete hTrace;
			return false;
		}
	}

	if (!visible) {
		// 无视野情况, 计算视角与速度向量夹角, 若太大则禁止连跳
		static float eyeAng[3], dir[3], angle;
		GetClientEyeAngles(client, eyeAng);
		GetAngleVectors(eyeAng, dir, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(dir, dir);
		NormalizeVector(velVec, velVec);
		dir[2] = velVec[2] = 0.0;
		angle = RadToDeg(ArcCosine(GetVectorDotProduct(dir, velVec)));
		if (floatIsNan(angle) || angle > g_cvBhopNoVisionMaxAng.FloatValue) {
			delete hTrace;
			return false;
		}
	}

	delete hTrace;
	// 检测下一帧向下的位置是否会死亡
	static float downPos[3];
	downPos = endPos;
	downPos[2] -= 99999.0;
	hTrace = TR_TraceHullFilterEx(endPos, downPos, {-16.0, -16.0, 0.0}, {16.0, 16.0, 0.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
	// 太高了, 返回 false
	if (!TR_DidHit(hTrace)) {
		delete hTrace;
		return false;
	}

	static int hitEnt;
	hitEnt = TR_GetEntityIndex(hTrace);
	if (IsValidEntity(hitEnt)) {
		static char className[32];
		GetEntityClassname(hitEnt, className, sizeof(className));
		if (strcmp(className, "trigger_hurt", false) == 0) {
			delete hTrace;
			return false;
		}
	}
	delete hTrace;
	return true;
}

// ============================================================
// 动画加速 Climb Animation Acceleration
// ============================================================
public void OnClientPutInServer(int client) {
	g_AiTanks[client].initData();
	AnimHookEnable(client, INVALID_FUNCTION, tankAnimHookPostCb);
}

/**
* SDKhook Callback
* @param client 坦克
* @return void
**/
void climbRateModifyHookHandler(int client) {
	if (!isAiTank(client))
		return;
	
	static int animSeq;
	animSeq = GetEntProp(client, Prop_Data, "m_nSequence");
	if (!isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Climb))) {
		SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", 1.0);
		SDKUnhook(client, SDKHook_PostThinkPost, climbRateModifyHookHandler);
		return;
	}
	SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", g_cvClimbAnimRate.FloatValue);
}

/**
* Animation Hook Callback
* @param tank 坦克
* @param sequence 动画序列
* @return Action
**/
Action tankAnimHookPostCb(int tank, int &sequence) {
	if (!isAiTank(tank)) {
		AnimHookDisable(tank, tankAnimHookPostCb);
		return Plugin_Continue;
	}

	// 如果想要扔石头的时候一直看着目标, 把 OnRockRelease 的代码放到下面即可
	if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Throw))) {
		// Tank 扔石头时
		if (!g_cvJumpRock.BoolValue)
			return Plugin_Continue;
		if (g_AiTanks[tank].wasThrowing)
			return Plugin_Continue;
		
		makeTankJumpRock(tank);
		g_AiTanks[tank].wasThrowing = true;
		CreateTimer(0.5, timerResetThrowingFlagHandler, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	} else if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Climb))) {
		if (GetEntPropFloat(tank, Prop_Send, "m_flPlaybackRate") != g_cvClimbAnimRate.FloatValue)
			SDKHook(tank, SDKHook_PostThinkPost, climbRateModifyHookHandler);
	}
	return Plugin_Continue;
}

bool isMatchedSequence(int sequence, TankSequenceType seqType) {
	if (sequence < 0)
		return false;

	static char seqName[64];
	if (!AnimGetActivity(sequence, seqName, sizeof(seqName)))
		return false;

	switch (seqType) {
		case view_as<TankSequenceType>(tankSequence_Throw): {
			return g_hThrowAnimMap.ContainsKey(seqName);
		} case view_as<TankSequenceType>(tankSequence_Climb): {
			return g_hClimbAnimMap.ContainsKey(seqName);
		}
	}
	return false;
}

// ============================================================
// 扔石头操作 Rock Throwing
// ============================================================
void makeTankJumpRock(int tank) {
	if (!isAiTank(tank))
		return;
	
	static float vAbsVelVec[3];
	GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
	vAbsVelVec[2] += JUMP_SPEED_Z;
	TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
}

Action timerResetThrowingFlagHandler(Handle timer, int userId) {
	static int tank;
	tank = GetClientOfUserId(userId);
	if (!isAiTank(tank))
		return Plugin_Stop;
	
	static int animSeq;
	animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
	if (!isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Throw))) {
		g_AiTanks[tank].wasThrowing = false;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

Action checkEnableThrow(int client, int& buttons, const float pos[3], const float targetPos[3], float dist) {
	if (!isAiTank(client))
		return Plugin_Continue;
	
	static float l_pos[3], l_targetPos[3];
	l_pos = pos;
	l_targetPos = targetPos;
	l_pos[2] = l_targetPos[2] = 0.0;
	if (dist < g_cvThrowMinDist.FloatValue || dist > g_cvThrowMaxDist.FloatValue)
		buttons &= ~IN_ATTACK2;

	return Plugin_Changed;
}

public Action L4D_TankRock_OnRelease(int tank, int rock, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3]) {
	if (!isAiTank(tank))
		return Plugin_Continue;
	if (!HasEntProp(rock, Prop_Data, "m_flGravity"))
		return Plugin_Continue;

	static ConVar cv_ThrowForce, cv_Gravity;
	if (!cv_ThrowForce)
		cv_ThrowForce = FindConVar("z_tank_throw_force");
	if (!cv_Gravity)
		cv_Gravity = FindConVar("sv_gravity");

	static float throwSpeed, svGravity;
	throwSpeed = !cv_ThrowForce ? DEFAULT_THROW_FORCE : cv_ThrowForce.FloatValue;
	svGravity = !cv_Gravity ? DEFAULT_SV_GRAVITY : cv_Gravity.FloatValue;

	static int target, newRockTarget;
	newRockTarget = -1;
	target = GetClientOfUserId(g_AiTanks[tank].target);
	if (!IsValidSurvivor(target))
		return Plugin_Continue;

	// 石头出手时, 选择最近的可视目标 (坦克与目标坐标连线间没有障碍挡住)
	if (g_cvRockTargetAdjust.BoolValue) {
		static ArrayList targets;
		if (!targets)
			targets = new ArrayList(2);
		
		static float pos[3], targetPos[3];
		GetClientEyePosition(tank, pos);
		for (int i = 1; i <= MaxClients; i++) {
			if (tank == i || !IsValidSurvivor(i) || !IsPlayerAlive(i) || IsClientIncapped(i) || isPinnedByHunterOrCharger(i))
				continue;
			if (!clientIsVisibleToClient(tank, i))
				continue;

			GetClientEyePosition(i, targetPos);
			targets.Set(targets.Push(GetVectorDistance(pos, targetPos)), i, 1);
		}

		// 选择距离最近的新目标
		if (targets.Length > 0) {
			SortADTArray(targets, Sort_Ascending, Sort_Float);
			newRockTarget = targets.Get(0, 1);
		}
		delete targets;
	}

	if (IsValidSurvivor(newRockTarget))
		log.debugAll("%N throw rock, current rock target: %N", tank, newRockTarget);
	else
		log.debugAll("%N throw rock, no any visible target, use default target: %N", tank, target);

	// 计算扔石头的时候视角调整角度
	static float pitch, rockGravityScale;
	static int aimTarget;
	rockGravityScale = GetEntPropFloat(rock, Prop_Data, "m_flGravity");
	aimTarget = IsValidSurvivor(newRockTarget) ? newRockTarget : target;
	pitch = calculateThrowAngle(tank, aimTarget, throwSpeed, svGravity * rockGravityScale);
	if (pitch > 90.0 || pitch < -90.0)
		return Plugin_Continue;

	static float pos[3], targetPos[3], predPos[3], vTargetAbsVelVec[3], aimAng[3];
	GetClientAbsOrigin(tank, pos);
	// 获取目标下一帧位置
	GetClientAbsOrigin(aimTarget, targetPos);
	GetEntPropVector(aimTarget, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

	// 石头偏航角度修正
	static float dx, vx, t, yawCenter, yawThrow;
	dx = SquareRoot(Pow(vecPos[0] - targetPos[0], 2.0) + Pow(vecPos[1] - targetPos[1], 2.0));
	// 石头水平飞行速度
	vx = throwSpeed * Cosine(DegToRad(pitch));
	// 计算目标不动的情况下石头飞行时间 t, 用作预测
	t = dx / vx;
	// 预测位置
	predPos[0] = targetPos[0] + vTargetAbsVelVec[0] * t;
	predPos[1] = targetPos[1] + vTargetAbsVelVec[1] * t;
	predPos[2] = targetPos[2] + vTargetAbsVelVec[2] * t;
	yawCenter = ArcTangent2(predPos[1] - pos[1], predPos[0] - pos[0]);
	yawThrow = ArcTangent2(predPos[1] - vecPos[1], predPos[0] - vecPos[0]);
	yawThrow = RadToDeg(yawThrow - yawCenter);

	// 计算方向
	MakeVectorFromPoints(pos, predPos, aimAng);
	GetVectorAngles(aimAng, aimAng);
	// pitch 上抬角度
	aimAng[0] = -pitch;
	// yaw 水平偏航
	aimAng[1] += yawThrow;
	if (aimAng[1] > 180.0)
		aimAng[1] -= 360.0;
	if (aimAng[1] < -180.0)
		aimAng[1] += 360.0;
	// roll = 0
	aimAng[2] = 0.0;
	GetAngleVectors(aimAng, aimAng, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(aimAng, aimAng);
	ScaleVector(aimAng, throwSpeed);

	vecVel = aimAng;
	return Plugin_Changed;
}

/**
* 计算石头出手角度
* @param tank 坦克
* @param target 目标
* @param vSpeed 石头出手速度
* @param g 石头受到重力加速度 sv_gravity * GetEntProp(rock, Porp_Data, "m_flGravity") ≈ 0.4
* @return float 上抬或下压角度
**/
float calculateThrowAngle(int tank, int target, float vSpeed = 800.0, float g = 320.0) {
	if (!isAiTank(tank) || !IsValidSurvivor(target))
		return -9999.0;
	
	static float pos[3], targetPos[3];
	GetClientAbsOrigin(tank, pos);

	static int animSeq;
	animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
	switch (animSeq) {
		// 49, 单手过头, 50, 低抛, 51, 双手过头
		case L4D2_ACT_SIGNAL3: {
			pos[2] += THROW_UNDERHEAD_POS_Z;
		} case L4D2_ACT_SIGNAL2: {
			pos[2] += THROW_OVERSHOULDER_POS_Z;
		} case L4D2_ACT_SIGNAL_ADVANCE: {
			pos[2] += THROW_OVERHEAD_POS_Z;
		}
	}

	GetClientAbsOrigin(target, targetPos);
	targetPos[2] += PLAYER_CHEST;
	// 水平距离和高度差
	static float dx, dz;
	dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
	dz = targetPos[2] - pos[2];

	// 石头初速度, 预先计算 v^2 和 v^4
	static float v2, v4, delta;
	v2 = Pow(vSpeed, 2.0);
	v4 = Pow(vSpeed, 4.0);
	// 通过求根公式解出 tanθ 的值, sqrt{b^2 - 4ac} = sqrt{d^2 - \frac{g^2d^4}{v_0^4} - \frac{2gd^2 \delta{h}}{v_0^2}}
	// root 就是 v_0^4 - g(g*d^2 + 2*\delta{h}*v_0^2), 就是 b^2 - 4ac, 如果小于 0 表示没有解, 石头不能命中
	delta = v4 - g * (g * dx * dx + 2.0 * dz * v2);
	if (delta < 0.0) {
		log.debugAll("%N: [%.2f, %.2f, %.2f], target %N: [%.2f, %.2f, %.2f], dist: %.2f, height diff: %.2f, rockspeed: %.2f, gravity: %.2f, rock is unreachable",
			tank, pos[0], pos[1], pos[2], target, targetPos[0], targetPos[1], targetPos[2], dx, dz, vSpeed, g);
		return -9999.0;
	}
	
	// 低抛解, 取减号分支
	float tanTheta = (v2 - SquareRoot(delta)) / (g * dx);
	log.debugAll("%N: [%.2f, %.2f, %.2f], target %N: [%.2f, %.2f, %.2f], dist: %.2f, height diff: %.2f, rockspeed: %.2f, gravity: %.2f, rock is reachable",
			tank, pos[0], pos[1], pos[2], target, targetPos[0], targetPos[1], targetPos[2], dx, dz, vSpeed, g);
	// 反三角得到弧度, 然后计算角度
	return RadToDeg(ArcTangent(tanTheta));
}
