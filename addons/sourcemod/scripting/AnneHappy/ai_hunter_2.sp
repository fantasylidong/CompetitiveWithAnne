#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil>

#define GetRandomFloatInRange(%1,%2) GetRandomFloat(%1,%2)
#define GetRandomIntInRange(%1,%2)   GetRandomInt(%1,%2)

public Plugin myinfo = 
{
	name         = "Ai Hunter 2.0 (Anne tuned)",
	author       = "夜羽真白 + ChatGPT for 东",
	description  = "Ai Hunter 增强 2.0（防撞栅栏/空中轻修正/近距-高差盲扑/预判领跑）",
	version      = "2025-09-07",
	url          = "https://steamcommunity.com/id/saku_ra/"
}

// ==================== 常量 / 定义 ====================
#define CVAR_FLAG               FCVAR_NOTIFY
#define LUNGE_LEFT              45.0
#define LUNGE_RIGHT             315.0
#define INVALID_CLIENT          -1
#define INVALID_NAV_AREA        0
#define HURT_CHECK_INTERVAL     0.2
#define CROUCH_HEIGHT           20.0
#define POUNCE_LFET             0
#define POUNCE_RIGHT            1
#define DEBUG                   0

// ==================== CVar ====================
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

// 新增
ConVar
	g_hNoSightCloseLunge,
	g_hVerticalDirectPounce,
	g_hAirSteerDeg,
	g_hAirSteerTime,
	g_hDeflectProbe,
	g_hLeadMs,
	g_hFenceAsWall;

// ==================== 运行态 ====================
bool  ignoreCrouch;

bool
	hasQueuedLunge[MAXPLAYERS + 1],
	canBackVision[MAXPLAYERS + 1][2];

bool  g_bWasLunging[MAXPLAYERS + 1];
float g_fLungeStartAt[MAXPLAYERS + 1];

float
	canLungeTime[MAXPLAYERS + 1],
	meleeMinRange,
	meleeMaxRange,
	noSightPounceRange,
	noSightPounceHeight;

int
	anglePounceCount[MAXPLAYERS + 1][2],
	hunterCurrentTarget[MAXPLAYERS + 1];

// ==================== 启停 ====================
public void OnPluginStart()
{
	// 基本参数
	g_hFastPounceDistance    = CreateConVar("ai_hunter_fast_pounce_distance", "1000.0", "hunter 开始进行快速突袭的距离", CVAR_FLAG, true, 0.0, true, 10000.0);
	g_hPounceVerticalAngle   = CreateConVar("ai_hunter_vertical_angle", "7.0", "hunter 突袭的垂直角度不会超过这个大小", CVAR_FLAG, true, 0.0, true, 89.0);
	g_hPounceAngleMean       = CreateConVar("ai_hunter_angle_mean", "10.0", "由随机数生成的基本角度", CVAR_FLAG, true, 0.0, true, 90.0);
	g_hPounceAngleStd        = CreateConVar("ai_hunter_angle_std", "20.0", "与基本角度允许的偏差范围", CVAR_FLAG, true, 0.0, true, 90.0);
	g_hStraightPounceDistance= CreateConVar("ai_hunter_straight_pounce_distance", "200.0", "hunter 允许直扑的范围", CVAR_FLAG, true, 0.0, true, 2000.0);
	g_hAimOffset             = CreateConVar("ai_hunter_aim_offset", "360.0", "与目标水平角度在这一范围内且在直扑范围外，ht 不会直扑", CVAR_FLAG, true, 0.0, true, 360.0);
	g_hNoSightPounceRange    = CreateConVar("ai_hunter_no_sign_pounce_range", "300,0", "不可见目标时允许飞扑的范围（水平,垂直；0禁用对应项）", CVAR_FLAG);
	g_hBackVision            = CreateConVar("ai_hunter_back_vision", "25", "空中背对生还者的概率，0=禁用", CVAR_FLAG, true, 0.0, true, 100.0);
	g_hMeleeFirst            = CreateConVar("ai_hunter_melee_first", "300.0,1000.0", "起扑前右键范围[min,max]，0禁用");
	g_hHighPounceHeight      = CreateConVar("ai_hunter_high_pounce", "400.0", "高差不足此值时更倾向侧飞", CVAR_FLAG, true, 0.0, true, 2000.0);
	g_hWallDetectDistance    = CreateConVar("ai_hunter_wall_detect_distance", "-1.0", "旧：前向探测距离（建议用 ai_hunter_deflect_probe）", CVAR_FLAG, false, 0.0);
	g_hAnglePounceCount      = CreateConVar("ai_hunter_angle_diff", "3", "左右侧飞次数差不得超过该值", CVAR_FLAG, true, 0.0, true, 10.0);

	// 新增参数
	g_hNoSightCloseLunge     = CreateConVar("ai_hunter_nosight_close_lunge", "200.0", "无视野且距离<=此值允许盲扑(0禁用)", CVAR_FLAG, true, 0.0, true, 1000.0);
	g_hVerticalDirectPounce  = CreateConVar("ai_hunter_vertical_direct_pounce", "200.0", "高度差>=此值时强制直扑", CVAR_FLAG, true, 0.0, true, 2000.0);
	g_hAirSteerDeg           = CreateConVar("ai_hunter_air_steer_deg", "10.0", "空中每tick最大水平修正角(度)", CVAR_FLAG, true, 0.0, true, 45.0);
	g_hAirSteerTime          = CreateConVar("ai_hunter_air_steer_time", "0.18", "起跳后允许空中修正的时间窗口(秒)", CVAR_FLAG, true, 0.0, true, 0.50);
	g_hDeflectProbe          = CreateConVar("ai_hunter_deflect_probe", "480.0", "起跳前前向障碍探测距离(-1禁用)", CVAR_FLAG);
	g_hLeadMs                = CreateConVar("ai_hunter_lead_ms", "160", "预判领跑毫秒(0禁用)", CVAR_FLAG, true, 0.0, true, 400.0);
	g_hFenceAsWall           = CreateConVar("ai_hunter_fence_as_wall", "1", "把链网栅栏等GRATE视作墙", CVAR_FLAG, true, 0.0, true, 1.0);

	// 变动钩子
	g_hMeleeFirst.AddChangeHook(meleeFirstRangeChangedHandler);
	g_hNoSightPounceRange.AddChangeHook(noSightPounceRangeChangedHandler);

	// 引擎 cvar
	g_hLungeInterval       = FindConVar("z_lunge_interval");
	g_hPounceReadyRange    = FindConVar("hunter_pounce_ready_range");
	g_hPounceLoftAngle     = FindConVar("hunter_pounce_max_loft_angle");
	g_hPounceGiveUpRange   = FindConVar("hunter_leap_away_give_up_range");
	g_hPounceSilenceRange  = FindConVar("z_pounce_silence_range");
	g_hCommitAttackRange   = FindConVar("hunter_committed_attack_range");
	g_hLungePower          = FindConVar("z_lunge_power");

	// 事件
	HookEvent("player_spawn", playerSpawnHandler);
	HookEvent("ability_use", abilityUseHandler);
	HookEvent("round_end", roundEndHandler);

	getHunterMeleeFirstRange();
	getNoSightPounceRange();
	setCvarValue(true);
}

public void OnPluginEnd()                   { setCvarValue(false); }
public void OnMapEnd()                      { resetCanLungeTime(); }

public void OnAllPluginsLoaded()
{
	ignoreCrouch = false;
	ConVar g_hCoverLeap = FindConVar("l4d2_hunter_patch_convert_leap");
	if (g_hCoverLeap && g_hCoverLeap.IntValue == 1)
	{
		g_hCoverLeap = FindConVar("l4d2_hunter_patch_crouch_pounce");
		if (g_hCoverLeap && g_hCoverLeap.IntValue == 2) ignoreCrouch = true;
	}

	if (ignoreCrouch)
	{
		g_hPounceReadyRange.FloatValue = 0.0;
		FindConVar("z_pounce_crouch_delay").FloatValue        = 0.0;
		FindConVar("hunter_committed_attack_range").FloatValue = 0.0;
	}
	else
	{
		g_hPounceReadyRange.FloatValue = 3000.0;
		FindConVar("z_pounce_crouch_delay").RestoreDefault();
		FindConVar("hunter_committed_attack_range").FloatValue = 3000.0;
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

// ==================== Cmd 主循环 ====================
public Action OnPlayerRunCmd(int hunter, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (!isValidHunter(hunter)) { return Plugin_Continue; }

	static int target, ability;
	target  = hunterCurrentTarget[hunter];
	ability = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	if (!IsValidEntity(ability) || !IsValidEdict(ability) || !IsValidSurvivor(target)) { return Plugin_Continue; }

	static float timestamp, gametime, selfPos[3], targetPos[3], targetDistance;
	static float lungeVector[3], lungeVectorNegate[3], backVisionChance;
	static bool  hasSight, isDucking, isLunging;

	timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
	gametime  = GetGameTime();

	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", lungeVector);
	hasSight  = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_hasVisibleThreats"));
	isDucking = view_as<bool>(GetEntProp(hunter, Prop_Send, "m_bDucked"));
	isLunging = view_as<bool>(GetEntProp(ability, Prop_Send, "m_isLunging"));

	GetClientAbsOrigin(hunter, selfPos);
	GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);
	targetDistance = GetVectorDistance(selfPos, targetPos);

	// ========== 空中阶段 ==========
	if (isLunging)
	{
		if (!g_bWasLunging[hunter])
		{
			g_bWasLunging[hunter]   = true;
			g_fLungeStartAt[hunter] = gametime;
		}

		float life = gametime - g_fLungeStartAt[hunter];
		if (life <= g_hAirSteerTime.FloatValue)
		{
			AirSteerTowardTargetOrDeflect(hunter, target, ability);
		}

		if (!canBackVision[hunter][0])
		{
			backVisionChance = GetRandomFloatInRange(0.0, 100.0);
			canBackVision[hunter][1] = (backVisionChance <= g_hBackVision.FloatValue);
			canBackVision[hunter][0] = true;
		}
		if (canBackVision[hunter][1])
		{
			MakeVectorFromPoints(selfPos, targetPos, lungeVectorNegate);
			NegateVector(lungeVectorNegate);
			NormalizeVector(lungeVectorNegate, lungeVectorNegate);
			GetVectorAngles(lungeVectorNegate, lungeVectorNegate);
			TeleportEntity(hunter, NULL_VECTOR, lungeVectorNegate, NULL_VECTOR);
			return Plugin_Changed;
		}
		return Plugin_Changed;
	}
	else
	{
		g_bWasLunging[hunter] = false;
	}

	if (!isOnGround(hunter)) { return Plugin_Continue; }
	canBackVision[hunter][0] = false;

	// ========== 无视野：允许贴脸/高差盲扑 ==========
	if (!hasSight && IsValidSurvivor(target))
	{
		if (!isDucking) { return Plugin_Changed; }

		if (g_hMeleeFirst.BoolValue &&
		    ((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
		    ((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
		{
			buttons |= IN_ATTACK2;
		}
		else if (gametime > timestamp)
		{
			float dz = FloatAbs(selfPos[2] - targetPos[2]);
			bool allowBlind = (g_hNoSightCloseLunge.FloatValue > 0.0 && targetDistance <= g_hNoSightCloseLunge.FloatValue)
			               || (dz >= g_hVerticalDirectPounce.FloatValue);

			if (!allowBlind)
			{
				if ((noSightPounceRange > 0 && targetDistance > noSightPounceRange) ||
				    (noSightPounceHeight > 0 && dz > noSightPounceHeight))
				{
					return Plugin_Continue; // 走位靠近
				}
			}

			if (!hasQueuedLunge[hunter])
			{
				hasQueuedLunge[hunter] = true;
				canLungeTime[hunter]   = gametime + g_hLungeInterval.FloatValue;
			}
			else if (gametime > canLungeTime[hunter])
			{
				AlignLungeVectorToPredicted(hunter, target, ability);
				buttons |= IN_ATTACK;
				hasQueuedLunge[hunter] = false;
			}
		}
		return Plugin_Changed;
	}

	// ========== 有视野：起跳前右键 ==========
	if (isDucking && g_hMeleeFirst.BoolValue &&
	    ((gametime > timestamp - 0.1) && (gametime < timestamp)) &&
	    ((targetDistance < meleeMaxRange) && (targetDistance > meleeMinRange)))
	{
		buttons |= IN_ATTACK2;
	}

	if (!isOnGround(hunter) || targetDistance > g_hFastPounceDistance.FloatValue) { return Plugin_Continue; }

	buttons &= ~IN_ATTACK;
	if (!hasQueuedLunge[hunter])
	{
		hasQueuedLunge[hunter] = true;
		canLungeTime[hunter]   = gametime + g_hLungeInterval.FloatValue;
	}
	else if (canLungeTime[hunter] < gametime)
	{
		buttons |= IN_ATTACK;
		hasQueuedLunge[hunter] = false;
	}

	if (GetEntityMoveType(hunter) & MOVETYPE_LADDER)
	{
		buttons &= ~IN_JUMP;
		buttons &= ~IN_DUCK;
	}
	return Plugin_Changed;
}

// ==================== 事件 ====================
public void playerSpawnHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) { return; }

	hasQueuedLunge[client]       = false;
	canBackVision[client][0]     = false;
	canBackVision[client][1]     = false;
	canLungeTime[client]         = 0.0;
	g_bWasLunging[client]        = false;
	g_fLungeStartAt[client]      = 0.0;
	anglePounceCount[client][POUNCE_LFET]  = 0;
	anglePounceCount[client][POUNCE_RIGHT] = 0;
}

public void abilityUseHandler(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!isValidHunter(client)) { return; }

	static char ability[32];
	event.GetString("ability", ability, sizeof(ability));
	if (strcmp(ability, "ability_lunge") == 0)
	{
		hunterOnPounce(client);
	}
}

public void roundEndHandler(Event event, const char[] name, bool dontBroadcast)
{
	resetCanLungeTime();
}

// ==================== 起跳时决策 ====================
public void hunterOnPounce(int hunter)
{
	if (!isValidHunter(hunter)) { return; }

	static int   lungeEntity, target;
	static float selfPos[3], targetPos[3], selfEyeAngle[3];

	lungeEntity = GetEntPropEnt(hunter, Prop_Send, "m_customAbility");
	GetClientAbsOrigin(hunter, selfPos);
	GetClientEyeAngles(hunter, selfEyeAngle);

	// ---------- 起跳前障碍探测 ----------
	float probe = g_hDeflectProbe.FloatValue;
	if (probe <= 0.0)
	{
		float legacy = g_hWallDetectDistance.FloatValue;
		if (legacy > 0.0) probe = legacy;
	}
	if (probe > 0.0)
	{
		float start[3];
		start[0] = selfPos[0];
		start[1] = selfPos[1];
		start[2] = selfPos[2] + CROUCH_HEIGHT;

		float fwd[3];
		GetAngleVectors(selfEyeAngle, fwd, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(fwd, fwd);

		float plane[3], hitDist;
		bool hit = TraceAheadAsHunter(hunter, start, fwd, probe, plane, hitDist);
		if (hit)
		{
			float dp = GetVectorDotProduct(fwd, plane);
			float theta = RadToDeg(ArcCosine(dp));
			if (theta > 165.0)
			{
				float deflect = ComputeDeflectYawFromPlane(fwd, plane);
				angleLunge(INVALID_CLIENT, INVALID_CLIENT, lungeEntity, deflect);
				limitLungeVerticality(lungeEntity);
				#if DEBUG
					PrintToConsoleAll("[Ai-Hunter] 前方%.0fuu命中障碍, 偏转=%.1f°(θ=%.1f°)", hitDist, deflect, theta);
				#endif
				return;
			}
		}
	}

	// ---------- 侧飞 / 直扑 ----------
	target = hunterCurrentTarget[hunter];
	if (!IsValidSurvivor(target)) { return; }

	GetClientAbsOrigin(target, targetPos);

	float dz = FloatAbs(targetPos[2] - selfPos[2]);
	bool  forceDirectByHeight = (dz >= g_hVerticalDirectPounce.FloatValue);

	if (isVisibleTo(hunter, target, g_hAimOffset.FloatValue) &&
	    !forceDirectByHeight &&
	    (GetClientDistance(hunter, target) > g_hStraightPounceDistance.IntValue ||
	     dz < g_hHighPounceHeight.FloatValue))
	{
		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter] 侧飞候选, 目标:%N 距离:%d 高差:%.2f", target, GetClientDistance(hunter, target), dz);
		#endif

		AlignLungeVectorToPredicted(hunter, target, lungeEntity);

		int angle = xorShiftGetRandomInt(0, g_hPounceAngleMean.IntValue, g_hPounceAngleStd.IntValue);
		if ((angle > 0 && anglePounceCount[hunter][POUNCE_LFET]  - anglePounceCount[hunter][POUNCE_RIGHT] > g_hAnglePounceCount.IntValue) ||
		    (angle < 0 && anglePounceCount[hunter][POUNCE_RIGHT] - anglePounceCount[hunter][POUNCE_LFET]  > g_hAnglePounceCount.IntValue))
		{
			angle = ~angle | 1;
		}
		(angle > 0) ? anglePounceCount[hunter][POUNCE_LFET]++ : anglePounceCount[hunter][POUNCE_RIGHT]++;

		angleLunge(hunter, target, lungeEntity, float(angle));
		limitLungeVerticality(lungeEntity);

		#if DEBUG
			PrintToConsoleAll("[Ai-Hunter] 最终侧飞角度: %.2f°", float(angle));
		#endif
	}
	else
	{
		AlignLungeVectorToPredicted(hunter, target, lungeEntity);
		angleLunge(hunter, target, lungeEntity, 0.0);
		limitLungeVerticality(lungeEntity);

		#if DEBUG
			if (forceDirectByHeight)
				PrintToConsoleAll("[Ai-Hunter] 高差%.1f>=%.1f, 强制直扑", dz, g_hVerticalDirectPounce.FloatValue);
		#endif
	}
}

// ==================== Trace / 预判 / 空中修正 ====================
stock bool TraceHitWorldAndProps(int entity, int contentsMask, any self)
{
	if (entity == self) return false;
	if (1 <= entity && entity <= MaxClients) return false;
	return true;
}

static bool TraceAheadAsHunter(int hunter, const float start[3], const float fwd[3], float dist,
                               float outPlane[3], float &outHitDist)
{
	float endpos[3];
	endpos[0] = start[0] + fwd[0] * dist;
	endpos[1] = start[1] + fwd[1] * dist;
	endpos[2] = start[2] + fwd[2] * dist;

	int mask = MASK_PLAYERSOLID | CONTENTS_MONSTERCLIP;
	if (g_hFenceAsWall.BoolValue) mask |= CONTENTS_GRATE;

	Handle ray = TR_TraceHullFilterEx(start, endpos,
		view_as<float>({-16.0, -16.0, 0.0}),
		view_as<float>({ 16.0,  16.0, 33.0}),
		mask, TraceHitWorldAndProps, hunter);

	bool hit = TR_DidHit(ray);
	if (hit)
	{
		TR_GetPlaneNormal(ray, outPlane);
		float hp[3];
		TR_GetEndPosition(hp, ray);
		outHitDist = GetVectorDistance(start, hp);
	}
	delete ray;
	return hit;
}

static float ComputeDeflectYawFromPlane(const float fwd[3], const float planeNorm[3])
{
	float base = 55.0;

	float u[3];
	u[0] = fwd[0]; u[1] = fwd[1]; u[2] = 0.0;

	float n[3];
	n[0] = planeNorm[0]; n[1] = planeNorm[1]; n[2] = 0.0;

	NormalizeVector(u, u);
	NormalizeVector(n, n);

	float crossZ = u[0]*n[1] - u[1]*n[0];
	float sign   = (crossZ >= 0.0) ? 1.0 : -1.0;

	return base * sign;
}

static void AlignLungeVectorToPredicted(int hunter, int target, int ability)
{
	if (!IsValidEntity(ability) || !IsValidEdict(ability)) return;
	if (!IsValidSurvivor(target)) return;

	float hp[3], tp[3], tv[3], v[3];
	GetClientAbsOrigin(hunter, hp);
	GetEntPropVector(target, Prop_Send, "m_vecOrigin", tp);
	GetEntPropVector(target, Prop_Data, "m_vecVelocity", tv);

	float dist = GetVectorDistance(hp, tp);
	float pwr  = g_hLungePower.FloatValue;
	float t    = (pwr > 0.0) ? (dist / pwr) : 0.2;
	t += (float(g_hLeadMs.IntValue) / 1000.0);

	float pred[3];
	pred[0] = tp[0] + tv[0]*t;
	pred[1] = tp[1] + tv[1]*t;
	pred[2] = tp[2];

	SubtractVectors(pred, hp, v);
	NormalizeVector(v, v);
	ScaleVector(v, pwr);

	SetEntPropVector(ability, Prop_Send, "m_queuedLunge", v);
}

static void AirSteerTowardTargetOrDeflect(int hunter, int target, int ability)
{
	if (!IsValidEntity(ability) || !IsValidEdict(ability)) return;

	float v[3];
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", v);
	if (GetVectorLength(v) <= 0.01) return;

	float fwd[3];
	fwd[0] = v[0]; fwd[1] = v[1]; fwd[2] = 0.0;
	NormalizeVector(fwd, fwd);

	float start[3], plane[3], hitDist;
	GetClientEyePosition(hunter, start);
	bool hit = TraceAheadAsHunter(hunter, start, fwd, 160.0, plane, hitDist);

	float yawDelta = 0.0;
	if (hit && hitDist < 120.0)
	{
		yawDelta = ComputeDeflectYawFromPlane(fwd, plane);
	}
	else if (IsValidSurvivor(target))
	{
		float hp[3], tp[3];
		GetClientAbsOrigin(hunter, hp);
		GetEntPropVector(target, Prop_Send, "m_vecOrigin", tp);
		hp[2] = tp[2] = 0.0;

		float toTgt[3];
		MakeVectorFromPoints(hp, tp, toTgt);
		NormalizeVector(toTgt, toTgt);

		float cosang = GetVectorDotProduct(fwd, toTgt);
		cosang = fclamp(cosang, -1.0, 1.0);
		float ang = RadToDeg(ArcCosine(cosang));

		float crossZ = fwd[0]*toTgt[1] - fwd[1]*toTgt[0];
		float sign   = (crossZ >= 0.0) ? 1.0 : -1.0;

		float limit  = g_hAirSteerDeg.FloatValue;
		yawDelta     = sign * FloatMin(ang, limit);
	}

	if (yawDelta != 0.0)
	{
		float angRad = DegToRad(yawDelta);
		float nv[3];
		nv[0] = v[0] * Cosine(angRad) - v[1] * Sine(angRad);
		nv[1] = v[0] * Sine(angRad) + v[1] * Cosine(angRad);
		nv[2] = v[2];

		SetEntPropVector(ability, Prop_Send, "m_queuedLunge", nv);
		limitLungeVerticality(ability);
	}
}

// ==================== 选择目标 ====================
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (!isValidHunter(specialInfected) || !IsValidSurvivor(curTarget) || !IsPlayerAlive(curTarget))
	{
		return Plugin_Continue;
	}

	static int newTarget;
	static float targetPos[3];
	GetEntPropVector(curTarget, Prop_Send, "m_vecOrigin", targetPos);

	if (!L4D2_IsVisibleToPlayer(specialInfected, TEAM_INFECTED, curTarget, INVALID_NAV_AREA, targetPos))
	{
		newTarget = getClosestSurvivor(specialInfected);
		if (!IsValidSurvivor(newTarget))
		{
			hunterCurrentTarget[specialInfected] = curTarget;
			return Plugin_Continue;
		}
		hunterCurrentTarget[specialInfected] = newTarget;
		curTarget = newTarget;
		return Plugin_Changed;
	}

	hunterCurrentTarget[specialInfected] = curTarget;
	return Plugin_Continue;
}

// ==================== 工具函数 ====================
bool isValidHunter(int client)
{
	return GetInfectedClass(client) == ZC_HUNTER && IsFakeClient(client) && IsPlayerAlive(client);
}

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

float getPlayerAimingOffset(int hunter, int target)
{
	static float selfEyeAngle[3], selfPos[3], targetPos[3];
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

bool isSurvivorWatchingHunter(int hunter, int target, float offset)
{
	if (!isValidHunter(hunter) || !IsValidSurvivor(target) || !IsPlayerAlive(target)) { return false; }
	if (getPlayerAimingOffset(hunter, target) > offset) { return false; }
	return true;
}

// 限制飞行垂直角
void limitLungeVerticality(int ability)
{
	if (!IsValidEntity(ability) || !IsValidEdict(ability)) { return; }

	static float verticleAngle, queueLunged[3], resultLunged[3];
	GetEntPropVector(ability, Prop_Send, "m_queuedLunge", queueLunged);

	verticleAngle  = DegToRad(g_hPounceVerticalAngle.FloatValue);
	resultLungeD_rot(queueLunged, verticleAngle, resultLunged);

	SetEntPropVector(ability, Prop_Send, "m_queuedLunge", resultLunged);
}

static void resultLungeD_rot(const float inV[3], float rad, float outV[3])
{
	outV[1] = inV[1] * Cosine(rad) - inV[2] * Sine(rad);
	outV[2] = inV[1] * Sine(rad) + inV[2] * Cosine(rad);

	outV[0] = inV[0] * Cosine(rad) + inV[2] * Sine(rad);
	outV[2] = inV[0] * -Sine(rad) + inV[2] * Cosine(rad);
}

void angleLunge(int hunter, int target, int lungeEntity, float turnAngle)
{
	if (!IsValidEntity(lungeEntity) || !IsValidEdict(lungeEntity)) { return; }

	static float lungeVec[3], resultVec[3];
	GetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", lungeVec);

	turnAngle = DegToRad(turnAngle);

	if (isValidHunter(hunter) && IsValidSurvivor(target) && IsPlayerAlive(target))
	{
		static float selfPos[3], targetPos[3];
		GetClientAbsOrigin(hunter, selfPos);
		GetEntPropVector(target, Prop_Send, "m_vecOrigin", targetPos);
		SubtractVectors(targetPos, selfPos, lungeVec);
		NormalizeVector(lungeVec, lungeVec);
		ScaleVector(lungeVec, g_hLungePower.FloatValue);
	}

	resultVec[0] = lungeVec[0] * Cosine(turnAngle) - lungeVec[1] * Sine(turnAngle);
	resultVec[1] = lungeVec[0] * Sine(turnAngle) + lungeVec[1] * Cosine(turnAngle);
	resultVec[2] = lungeVec[2];

	SetEntPropVector(lungeEntity, Prop_Send, "m_queuedLunge", resultVec);
}

static int xorShiftGetRandomInt(int min, int max, int std)
{
	static int x = 123456789, y = 362436069, z = 521288629, w = 88675123;
	int t = x ^ (x << 11);
	x = y; y = z; z = w;
	w = w ^ (w >> 19) ^ (t ^ (t >> 8));
	int range = (max - min + 1);
	int base = (range != 0) ? (min + (w % range)) : min;
	return (GetRandomFloat(0.0, 1.0) < 0.5) ? (base + std) : (base - std);
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
		noSightPounceRange  = 300.0;
		noSightPounceHeight = 250.0;
		return;
	}
	ExplodeString(cvarStr, ",", tempStr, 2, sizeof(tempStr[]));
	noSightPounceRange  = StringToFloat(tempStr[0]);
	noSightPounceHeight = StringToFloat(tempStr[1]);
}

bool isVisibleTo(int hunter, int target, float offset)
{
	if (!isValidHunter(hunter) || !IsValidSurvivor(target) || !IsPlayerAlive(target)) { return false; }

	static float selfEyePos[3], selfEyeAngle[3], targetEyePos[3];
	GetClientEyeAngles(hunter, selfEyeAngle);
	selfEyeAngle[0] = selfEyeAngle[2] = 0.0;
	GetAngleVectors(selfEyeAngle, selfEyeAngle, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(selfEyeAngle, selfEyeAngle);

	GetClientEyePosition(hunter, selfEyePos);
	GetClientEyePosition(target, targetEyePos);
	selfEyePos[2] = targetEyePos[2] = 0.0;

	MakeVectorFromPoints(selfEyePos, targetEyePos, selfEyePos);
	NormalizeVector(selfEyePos, selfEyePos);

	return RadToDeg(ArcCosine(GetVectorDotProduct(selfEyeAngle, selfEyePos))) < offset;
}

void resetCanLungeTime()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		canLungeTime[i] = 0.0;
		anglePounceCount[i][POUNCE_LFET]  = 0;
		anglePounceCount[i][POUNCE_RIGHT] = 0;
		hunterCurrentTarget[i] = 0;
		g_bWasLunging[i]   = false;
		g_fLungeStartAt[i] = 0.0;
	}
}

// Cvar 变动
void meleeFirstRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getHunterMeleeFirstRange();
}
void noSightPounceRangeChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getNoSightPounceRange();
}

// clamp
static float fclamp(float x, float lo, float hi)
{
	if (x < lo) return lo;
	if (x > hi) return hi;
	return x;
}

// --- Math helpers --- 
stock float FloatMax(float a, float b) { return (a > b) ? a : b; } 
stock float FloatMin(float a, float b) { return (a < b) ? a : b; }
stock float Clamp01(float v) { if (v < 0.0) return 0.0; if (v > 1.0) return 1.0; return v; }
