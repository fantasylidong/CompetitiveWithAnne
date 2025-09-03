#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil>

public Plugin myinfo = 
{
	name 			= "Ai Hunter 2.0",
	author 			= "夜羽真白",
	description 	= "Ai Hunter 增强 2.0 版本",
	version 		= "2023/4/1",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

#define CVAR_FLAG FCVAR_NOTIFY
#define LUNGE_LEFT 45.0
#define LUNGE_RIGHT 315.0
#define INVALID_CLIENT -1
#define INVALID_NAV_AREA 0
#define HURT_CHECK_INTERVAL 0.2
#define CROUCH_HEIGHT 20.0
#define POUNCE_LFET 0
#define POUNCE_RIGHT 1
#define DEBUG 0

// 基本 cvar
ConVar
	g_hFastPounceDistance,
	g_hPounceVerticalAngle,
	g_hPounceAngleMean,
	g_hPounceAngleStd,
	g_hStraightPounceDistance,
	g_hAimOffset,
	g_hNoSightPounceRange,
	g_hBackVision,
	g_hMeleeFirst,
	g_hHighPounceHeight,
	g_hWallDetectDistance,
	g_hAnglePounceCount;
// 其他 cvar
ConVar
	g_hLungeInterval,
	g_hPounceReadyRange,
	g_hPounceLoftAngle,
	g_hPounceGiveUpRange,
	g_hPounceSilenceRange,
	g_hCommitAttackRange,
	g_hLungePower;
bool
	ignoreCrouch,
	hasQueuedLunge[MAXPLAYERS + 1],
	// 是否允许 ht 背飞，[0] 为是否允许取随机数，[1] 为是否允许背飞
	canBackVision[MAXPLAYERS + 1][2];
float
	canLungeTime[MAXPLAYERS + 1],
	meleeMinRange,
	meleeMaxRange,
	noSightPounceRange,
	noSightPounceHeight;
int
	anglePounceCount[MAXPLAYERS + 1][2],
	hunterCurrentTarget[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_hFastPounceDistance = CreateConVar("ai_hunter_fast_pounce_distance", "1000.0", "hunter 开始进行快速突袭的距离", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hPounceVerticalAngle = CreateConVar("ai_hunter_vertical_angle", "7.0", "hunter 突袭的垂直角度不会超过这个大小", CVAR_FLAG, true, 0.0);
	g_hPounceAngleMean = CreateConVar("ai_hunter_angle_mean", "10.0", "由随机数生成的基本角度", CVAR_FLAG, true, 0.0);
	g_hPounceAngleStd = CreateConVar("ai_hunter_angle_std", "20.0", "与基本角度允许的偏差范围", CVAR_FLAG, true, 0.0);
	g_hStraightPounceDistance = CreateConVar("ai_hunter_straight_pounce_distance", "200.0", "hunter 允许直扑的范围", CVAR_FLAG, true, 0.0);
	g_hAimOffset = CreateConVar("ai_hunter_aim_offset", "360.0", "与目标水平角度在这一范围内且在直扑范围外，ht 不会直扑", CVAR_FLAG, true, 0.0, true, 360.0);
	g_hNoSightPounceRange = CreateConVar("ai_hunter_no_sign_pounce_range", "300,0", "hunter 不可见目标时允许飞扑的范围（水平，垂直，逗号分隔，0,0 | x,0 | 0,x=禁用 0 的部分）", CVAR_FLAG);
	g_hBackVision = CreateConVar("ai_hunter_back_vision", "25", "hunter 处在空中时视角背对生还者的概率，0=禁用", CVAR_FLAG, true, 0.0, true, 100.0);
	g_hMeleeFirst = CreateConVar("ai_hunter_melee_first", "300.0,1000.0", "hunter 每次准备突袭时是否先按右键（最小最大距离，逗号分隔，0=禁用）");
	g_hHighPounceHeight = CreateConVar("ai_hunter_high_pounce", "400", "hunter 在与目标多高时会直扑目标", CVAR_FLAG, true, 0.0);
	g_hWallDetectDistance = CreateConVar("ai_hunter_wall_detect_distance", "-1.0", "hunter 视线前方有墙体，有多少概率飞向墙体", CVAR_FLAG, true, 0.0);
	g_hAnglePounceCount = CreateConVar("ai_hunter_angle_diff", "3", "hunter 进行由随机数生成器生成角度侧飞时，左右飞的次数差不能大于这个值", CVAR_FLAG, true, 0.0);
	// 挂钩 cvar 变动
	g_hMeleeFirst.AddChangeHook(meleeFirstRangeChangedHandler);
	g_hNoSightPounceRange.AddChangeHook(noSightPounceRangeChangedHandler);
	// 获取其他 cvar
	g_hLungeInterval = FindConVar("z_lunge_interval");
	g_hPounceReadyRange = FindConVar("hunter_pounce_ready_range");
	g_hPounceLoftAngle = FindConVar("hunter_pounce_max_loft_angle");
	g_hPounceGiveUpRange = FindConVar("hunter_leap_away_give_up_range");
	g_hPounceSilenceRange = FindConVar("z_pounce_silence_range");
	g_hCommitAttackRange = FindConVar("hunter_committed_attack_range");
	g_hLungePower = FindConVar("z_lunge_power");
	// 挂钩事件
	HookEvent("player_spawn", playerSpawnHandler);
	HookEvent("ability_use", abilityUseHandler);
	HookEvent("round_end", roundEndHandler);
	// 获取允许右键的范围
	getHunterMeleeFirstRange();
	// 获取没有视野允许扑的范围
	getNoSightPounceRange();
	// 设置 cvar 值
	setCvarValue(true);
}

public void OnPluginEnd()
{
	setCvarValue(false);
}

public void OnMapEnd()
{
	resetCanLungeTime();
}

public void OnAllPluginsLoaded()
{
	ignoreCrouch = false;
	// hunter patch 是否将 hunter 的跳跃逃跑行为改变
	ConVar g_hCoverLeap = FindConVar("l4d2_hunter_patch_convert_leap");
	if (g_hCoverLeap && g_hCoverLeap.IntValue == 1)
	{
		g_hCoverLeap = FindConVar("l4d2_hunter_patch_crouch_pounce");
		if (g_hCoverLeap && g_hCoverLeap.IntValue == 2)
		{
			ignoreCrouch = true;
		}
	}
	if(ignoreCrouch){
		g_hPounceReadyRange.FloatValue = 0.0;
		FindConVar("z_pounce_crouch_delay").FloatValue =			0.0;
		FindConVar("hunter_committed_attack_range").FloatValue =	0.0;
	}else{
		g_hPounceReadyRange.FloatValue = 3000.0;
		FindConVar("z_pounce_crouch_delay").RestoreDefault();
		FindConVar("hunter_committed_attack_range").FloatValue =	3000.0;
	}
}

void setCvarValue(bool set)
{
	if (set)
	{
		g_hPounceLoftAngle.SetFloat(0.0);
		g_hPounceGiveUpRange.SetFloat(0.0);
		g_hPounceSilenceRange.SetFloat(999999.0);
		return;
	}
	g_hPounceReadyRange.RestoreDefault();
	g_hPounceLoftAngle.RestoreDefault();
	g_hPounceGiveUpRange.RestoreDefault();
	g_hPounceSilenceRange.RestoreDefault();
	g_hCommitAttackRange.RestoreDefault();
}

public Action OnPlayerRunCmd(int hunter, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (!isValidHunter(hunter)) { return Plugin_Continue; }
	static int
		target,
		ability;
	target = hunterCurrentTarget[hunter],
	ability = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	if (!IsValidEntity(ability) || !IsValidEdict(ability) || !IsValidSurvivor(target)) { return Plugin_Continue; }
	// 下一次可以使用能力的时间
	static float
		timestamp,
		gametime,
		selfPos[3],
		targetPos[3],
		targetDistance,
		lungeVector[3],
		lungeVectorNegate[3],
		backVisionChance;
	timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
	gametime = GetGameTime();
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", lungeVector);
	static bool
		hasSight,
		isDucking,
		isLunging;
	hasSight = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_hasVisibleThreats"));
	isDucking = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_bDucked"));
	isLunging = view_as<bool>(GetEntProp(ability, Prop_Send, "m_isLunging"));
	GetClientAbsOrigin(hunter, selfPos);
	GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);
	targetDistance = GetVectorDistance(selfPos, targetPos);
	// 开启飞扑时背身
	if (isLunging)
	{
		if (!canBackVision[hunter][0])
		{
			backVisionChance = GetRandomFloatInRange(0.0, 100.0);
			backVisionChance <= g_hBackVision.FloatValue ? (canBackVision[hunter][1] = true) : (canBackVision[hunter][1] = false);
			canBackVision[hunter][0] = true;
		}
		if (canBackVision[hunter][1])
		{
			// 似乎比获取 lungeVector 并反向的方法准确些，此方法计算与目标之间的向量取反，保持视角背对目标而不是飞扑方向
			MakeVectorFromPoints(selfPos, targetPos, lungeVectorNegate);
			NegateVector(lungeVectorNegate);
			NormalizeVector(lungeVectorNegate, lungeVectorNegate);
			GetVectorAngles(lungeVectorNegate, lungeVectorNegate);
			TeleportEntity(hunter, NULL_VECTOR, lungeVectorNegate, NULL_VECTOR);
			return Plugin_Changed;
		}
		return Plugin_Continue;
	}
	if (!isOnGround(hunter)) { return Plugin_Continue; }
	canBackVision[hunter][0] = false;
	// 有视野和没有视野的情况，没有视野也允许飞
	if (!hasSight && IsValidSurvivor(target))
	{
		// 没有视野的情况，在地上时，允许使用右键
		if (!isDucking) { return Plugin_Changed; }
		// 准备飞扑，使用右键挠
		if (g_hMeleeFirst.BoolValue &&
			((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
			((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
		{
			buttons |= IN_ATTACK2;
		}
		else if (gametime > timestamp)
		{
			// 设置了高度或距离或两个都设置情况下，检查是否符合条件
			if (noSightPounceRange > 0 && targetDistance > noSightPounceRange) { return Plugin_Continue; }
			if (noSightPounceHeight > 0 && FloatAbs(selfPos[2] - targetPos[2]) > noSightPounceHeight) { return Plugin_Continue; }
			if (!hasQueuedLunge[hunter])
			{
				hasQueuedLunge[hunter] = true;
				canLungeTime[hunter] = gametime + g_hLungeInterval.FloatValue;
			}
			else if (gametime > canLungeTime[hunter])
			{
				buttons |= IN_ATTACK;
				hasQueuedLunge[hunter] = false;
			}
		}
		return Plugin_Changed;
	}
	// 有视野的情况，飞扑前按右键
	if (isDucking && g_hMeleeFirst.BoolValue &&
		((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
		((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
	{
		buttons |= IN_ATTACK2;
	}
	if (!isOnGround(hunter) || targetDistance > g_hFastPounceDistance.FloatValue) { return Plugin_Continue; }
	// hunter 与目标的距离小于 g_hFastPounceDistance.FloatValue，开始随机角度快速突袭
	buttons &= ~IN_ATTACK;
	// 如果能力没有好，则不能飞扑，z_lunge_interval = 0.1，将可以飞扑的时间设置为 0.1 秒后
	if (!hasQueuedLunge[hunter])
	{
		hasQueuedLunge[hunter] = true;
		canLungeTime[hunter] = gametime + g_hLungeInterval.FloatValue;
	}
	else if (canLungeTime[hunter] < gametime)
	{
		buttons |= IN_ATTACK;
		hasQueuedLunge[hunter] = false;
	}
	// hunter 在梯子上，禁止跳和蹲
	if (GetEntityMoveType(hunter) & MOVETYPE_LADDER)
	{
		buttons &= ~IN_JUMP;
		buttons &= ~IN_DUCK;
	}
	return Plugin_Changed;
}

public void playerSpawnHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) { return; }
	hasQueuedLunge[client] = canBackVision[client][0] = canBackVision[client][1] = false;
	canLungeTime[client] = 0.0;
	anglePounceCount[client][POUNCE_LFET] = anglePounceCount[client][POUNCE_RIGHT] = 0;
}

public void abilityUseHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) { return; }
	static char ability[32];
	event.GetString("ability", ability, sizeof(ability));
	// 处理 hunter 突袭方向向量，直扑还是侧飞
	if (strcmp(ability, "ability_lunge") == 0)
	{
		hunterOnPounce(client);
	}
}

public void roundEndHandler(Event event, const char[] name, bool dontBroadcast)
{
	resetCanLungeTime();
}

public void hunterOnPounce(int hunter)
{
	if (!isValidHunter(hunter)) { return; }
	static int
		lungeEntity,
		target;
	static float
		selfPos[3],
		targetPos[3],
		selfEyeAngle[3],
		rayEndPos[3];
	lungeEntity = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	GetClientAbsOrigin(hunter, selfPos);
	GetClientEyeAngles(hunter, selfEyeAngle);
	// 向前发出射线检测是否会撞到墙壁
	if (g_hWallDetectDistance.FloatValue > -1.0)
	{
		// https://github.com/umlka/l4d2/blob/main/AI_HardSI/ai_hunter.sp
		selfPos[2] += CROUCH_HEIGHT;
		GetAngleVectors(selfEyeAngle, selfEyeAngle, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(selfEyeAngle, selfEyeAngle);
		rayEndPos = selfEyeAngle;
		ScaleVector(rayEndPos, g_hWallDetectDistance.FloatValue);
		AddVectors(selfPos, rayEndPos, rayEndPos);
		static Handle ray;
		ray = TR_TraceHullFilterEx(selfPos, rayEndPos, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 33.0}), MASK_NPCSOLID_BRUSHONLY, traceRayFilter, hunter);
		if (TR_DidHit(ray))
		{
			TR_GetPlaneNormal(ray, rayEndPos);
			if (RadToDeg(ArcCosine(GetVectorDotProduct(selfEyeAngle, rayEndPos))) > 165.0)
			{
				#if DEBUG
					PrintToConsoleAll("[Ai-Hunter]：前方：%.2f 处检测到墙体，向两边侧飞", GetVectorDistance(selfPos, rayEndPos));
				#endif
				delete ray;
				angleLunge(INVALID_CLIENT, INVALID_CLIENT, lungeEntity, GetRandomIntInRange(0, 1) ? LUNGE_LEFT : LUNGE_RIGHT);
				return;
			}
		}
		delete ray;
	}
	// 没开墙体检测或前方没有检测到墙体
	target = hunterCurrentTarget[hunter];
	if (!IsValidSurvivor(target)) { return; }
	GetClientAbsOrigin(target, targetPos);
	// 目标正在看着 hunter 且距离大于直扑限制距离同时高度小于直接高扑的高度，侧飞
	// 目标没有正在看着 hunter 且垂直距离大于高扑限制高度时，直扑
	if (isVisibleTo(hunter, target, g_hAimOffset.FloatValue) && (GetClientDistance(hunter, target) > g_hStraightPounceDistance.IntValue || FloatAbs(targetPos[2] - selfPos[2]) < g_hHighPounceHeight.FloatValue))
	{
		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter]：与最近目标：%N 距离：%d，高度：%.2f 可以侧飞", target, GetClientDistance(hunter, target), FloatAbs(targetPos[2] - selfPos[2]));
		#endif
		static int angle;
		angle = xorShiftGetRandomInt(0, g_hPounceAngleMean.IntValue, g_hPounceAngleStd.IntValue);
		// 角度是正值，则 ht 向左飞，反之向右，是否需要角度修正
		if ((angle > 0 && anglePounceCount[hunter][POUNCE_LFET] - anglePounceCount[hunter][POUNCE_RIGHT] > g_hAnglePounceCount.IntValue) ||
			(angle < 0 && anglePounceCount[hunter][POUNCE_RIGHT] - anglePounceCount[hunter][POUNCE_LFET] > g_hAnglePounceCount.IntValue))
		{
			angle = ~angle | 1;
		}
		angle > 0 ? anglePounceCount[hunter][POUNCE_LFET]++ : anglePounceCount[hunter][POUNCE_RIGHT]++;
		angleLunge(hunter, target, lungeEntity, float(angle));
		limitLungeVerticality(lungeEntity);
		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter]：最终随机侧飞角度是：%.2f 度", float(angle));
		#endif
	}
}

stock bool traceRayFilter(int entity, int contentsMask, any data)
{
	// 射线撞到自己或是客户端实体，禁止穿透
	if (entity == data || (entity > 0 && entity <= MaxClients))
	{
		return false;
	}
	// 射线撞到特感，prop_dynamic，prop_physics，坦克石头，女巫，禁止穿透
	static char className[64];
	GetEntityClassname(entity, className, sizeof(className));
	if (className[0] == 'i' || className[0] == 'p' || className[0] == 't' || className[0] == 'w')
	{
		if (strcmp(className, "infected") == 0 ||
			strcmp(className, "witch") == 0 ||
			strcmp(className, "prop_dynamic") == 0 ||
			strcmp(className, "prop_physics") == 0 ||
			strcmp(className, "tank_rock") == 0)
			{
				return false;
			}
	}
	return true;
}

// hunter 目标检测
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (!isValidHunter(specialInfected) || !IsValidSurvivor(curTarget) || !IsPlayerAlive(curTarget)) { return Plugin_Continue; }
	// hunter 和目标都有效，检测可见性
	static int newTarget;
	static float targetPos[3];
	GetEntPropVector(curTarget, Prop_Send, "m_vecOrigin", targetPos);
	// 当前目标不可见，使用 getClosestSurvivor 获取最近的可见目标
	if (!L4D2_IsVisibleToPlayer(specialInfected, TEAM_INFECTED, curTarget, INVALID_NAV_AREA, targetPos))
	{
		// 不可见，更换新的最近可见目标
		newTarget = getClosestSurvivor(specialInfected);
		// 如果 getClosestSurvivor 返回 INVALID_CLIENT 则使用默认目标
		if (!IsValidSurvivor(newTarget))
		{
			hunterCurrentTarget[specialInfected] = curTarget;
			return Plugin_Continue;
		}
		// 新目标可见，更改目标
		hunterCurrentTarget[specialInfected] = newTarget;
		curTarget = newTarget;
		return Plugin_Changed;
	}
	// 当前目标可见，给 hunterCurrentTarget 赋值，避免 OnPlayerRunCmd 中拿不到目标
	hunterCurrentTarget[specialInfected] = curTarget;
	return Plugin_Continue;
}

// ****************
//		Stuff
// ****************
bool isValidHunter(int client)
{
	return GetInfectedClass(client) == ZC_HUNTER && IsFakeClient(client) && IsPlayerAlive(client);
}

// hunter 获取最近目标
static int getClosestSurvivor(int client)
{
	if (!isValidHunter(client)) { return INVALID_CLIENT; }
	static int i;
	static float selfPos[3], targetPos[3];
	static ArrayList targetList;
	targetList = new ArrayList(2);
	GetClientAbsOrigin(client, selfPos);
	for (i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i) || IsClientPinned(i)) { continue; }
		GetEntPropVector(i, Prop_Send, "m_vecOrigin", targetPos);
		// 获取目标时，如果不可见目标，则跳过这个不可见的最近目标
		if (!L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, i, INVALID_NAV_AREA, targetPos)) { continue; }
		targetList.Set(targetList.Push(GetVectorDistance(selfPos, targetPos)), i, 1);
	}
	if (targetList.Length < 1)
	{
		delete targetList;
		return INVALID_CLIENT;
	}
	targetList.Sort(Sort_Ascending, Sort_Float);
	i = targetList.Get(0, 1);
	delete targetList;
	return i;
}

stock bool isSurvivorWatchingHunter(int hunter, int target, float offset)
{
	if (!isValidHunter(hunter) || !IsValidSurvivor(target) || !IsPlayerAlive(target)) { return false; }
	if (getPlayerAimingOffset(hunter, target) > offset) { return false; }
	return true;
}

float getPlayerAimingOffset(int hunter, int target)
{
	static float
		selfEyeAngle[3],
		selfPos[3],
		targetPos[3];
	GetClientEyeAngles(hunter, selfEyeAngle);
	selfEyeAngle[0] = selfEyeAngle[2] = 0.0;
	GetAngleVectors(selfEyeAngle, selfEyeAngle, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(selfEyeAngle, selfEyeAngle);
	GetClientAbsOrigin(hunter, selfPos);
	GetClientAbsOrigin(target, targetPos);
	selfPos[2] = targetPos[2] = 0.0;
	MakeVectorFromPoints(selfPos, targetPos, selfPos);
	NormalizeVector(selfPos, selfPos);
	return RadToDeg(ArcCosine(GetVectorDotProduct(selfEyeAngle, selfPos)));
}

// 限制 hunter 飞行的垂直角度
void limitLungeVerticality(int ability)
{
	if (!IsValidEntity(ability) || !IsValidEdict(ability)) { return; }
	static float
		verticleAngle,
		queueLunged[3],
		resultLunged[3];
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", queueLunged);
	verticleAngle = DegToRad(g_hPounceVerticalAngle.FloatValue);
	resultLunged[1] = queueLunged[1] * Cosine(verticleAngle) - queueLunged[2] * Sine(verticleAngle);
	resultLunged[2] = queueLunged[1] * Sine(verticleAngle) + queueLunged[2] * Cosine(verticleAngle);
	resultLunged[0] = queueLunged[0] * Cosine(verticleAngle) + queueLunged[2] * Sine(verticleAngle);
	resultLunged[2] = queueLunged[0] * -Sine(verticleAngle) + queueLunged[2] * Cosine(verticleAngle);
	SetEntPropVector(ability, Prop_Send, "m_queuedLunge", resultLunged);
}

// 限制 hunter 飞行水平角度
void angleLunge(int hunter, int target, int lungeEntity, float turnAngle)
{
	// 能力无效，返回
	if (!IsValidEntity(lungeEntity) || !IsValidEdict(lungeEntity)) { return; }
	static float
		lungeVec[3],
		resultVec[3];
	GetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", lungeVec);
	turnAngle = DegToRad(turnAngle);
	// hunter 和目标都有效
	if (isValidHunter(hunter) && IsValidSurvivor(target) && IsPlayerAlive(target))
	{
		static float
			selfPos[3],
			targetPos[3];
		// 将 lungeVector 下次突袭方向向量设置为到目标方向，代替视角锁定
		GetClientAbsOrigin(hunter, selfPos);
		GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);
		SubtractVectors(targetPos, selfPos, lungeVec);
		NormalizeVector(lungeVec, lungeVec);
		ScaleVector(lungeVec, g_hLungePower.FloatValue);
	}
	// 增加水平角度
	resultVec[0] = lungeVec[0] * Cosine(turnAngle) - lungeVec[1] * Sine(turnAngle);
	resultVec[1] = lungeVec[0] * Sine(turnAngle) + lungeVec[1] * Cosine(turnAngle);
	resultVec[2] = lungeVec[2];
	SetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", resultVec);
}

static int xorShiftGetRandomInt(int min, int max, int std)
{
	static int x = 123456789, y = 362436069, z = 521288629, w = 88675123;
	static int t;
	t = x ^ (x << 11);
	x = y, y = z, z = w;
	w = w ^ (w >> 19) ^ (t ^ (t >> 8));
	w = w % (max - min) + 1;
	return GetRandomFloatInRange(0.0, 1.0) < 0.5 ? w + std : w - std;
}

bool isOnGround(int client)
{
	if (!isValidHunter(client)) { return false; }
	return GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1;
}

void getHunterMeleeFirstRange()
{
	static char cvarStr[64], tempStr[2][16];
	g_hMeleeFirst.GetString(cvarStr, sizeof(cvarStr));
	if (IsNullString(cvarStr))
	{
		meleeMinRange = 400.0;
		meleeMaxRange = 1000.0;
		return;
	}
	ExplodeString(cvarStr, ",", tempStr, 2, sizeof(tempStr[]));
	meleeMinRange = StringToFloat(tempStr[0]);
	meleeMaxRange = StringToFloat(tempStr[1]);
}

void getNoSightPounceRange()
{
	static char cvarStr[64], tempStr[2][16];
	g_hNoSightPounceRange.GetString(cvarStr, sizeof(cvarStr));
	if (IsNullString(cvarStr))
	{
		noSightPounceRange = 300.0;
		noSightPounceHeight = 250.0;
		return;
	}
	ExplodeString(cvarStr, ",", tempStr, 2, sizeof(tempStr[]));
	noSightPounceRange = StringToFloat(tempStr[0]);
	noSightPounceHeight = StringToFloat(tempStr[1]);
}

bool isVisibleTo(int hunter, int target, float offset)
{
	if (!isValidHunter(hunter) || !IsValidSurvivor(target) || !IsPlayerAlive(target)) { return false; }
	static float
		selfEyePos[3],
		selfEyeAngle[3],
		targetEyePos[3];
	GetClientEyeAngles(hunter, selfEyeAngle);
	selfEyeAngle[0] = selfEyeAngle[2] = 0.0;
	GetAngleVectors(selfEyeAngle, selfEyeAngle, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(selfEyeAngle, selfEyeAngle);
	GetClientEyePosition(hunter, selfEyePos);
	GetClientEyePosition(target, targetEyePos);
	selfEyePos[2] = targetEyePos[2] = 0.0;
	MakeVectorFromPoints(selfEyePos, targetEyePos, selfEyePos);
	NormalizeVector(selfEyePos, selfEyePos);
	// 两向量角度小于 offset，且可视目标，返回 true
	return RadToDeg(ArcCosine(GetVectorDotProduct(selfEyeAngle, selfEyePos))) < offset;
}

void resetCanLungeTime()
{
	static int i;
	for (i = 1; i <= MaxClients; i++)
	{
		canLungeTime[i] = 0.0;
		anglePounceCount[i][POUNCE_LFET] = anglePounceCount[i][POUNCE_RIGHT] = 0;
		hunterCurrentTarget[i] = 0;
	}
}

// Cvar 值变动处理
void meleeFirstRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getHunterMeleeFirstRange();
}

void noSightPounceRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getNoSightPounceRange();
}