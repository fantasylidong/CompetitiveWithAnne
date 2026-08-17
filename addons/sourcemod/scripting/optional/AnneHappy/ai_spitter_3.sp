#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil>
#include <anne_nextbot>
#include "ai_path_snapshot.inc"
#include "ai_path_movement.inc"

#define CVAR_FLAG FCVAR_NONE
#define SPITTER_JUMP_DELAY 1.0
#define CHECK_PINNED_TIME 1.0
#define SPITTER_KILL_DELAY 10.0

public Plugin myinfo = 
{
		name 			= "Ai Spitter 3.0",
	author 			= "夜羽真白",
		description 	= "Ai Spitter 增强 3.0（anne_nextbot Path Follow）",
		version 		= "3.0.4",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

ConVar
	g_hAllowBhop,
	g_hBhopSpeed,
	g_hBhopStartDistance,
	g_hPathBhop,
	g_hPathLookAheadDepth,
	g_hPathLaneOffset,
	g_hTargetPolicy,
	g_hPinnedPriority,
	g_hKilledAfterSpit,
	g_hSpitRange;
float
	clientDelay[MAXPLAYERS + 1][8];
int
	pinnedPriority[6] = {0},
	pinnedTarget = -1,
	crowdedTarget = -1;
Handle
	checkPinnedTimer = null;

enum
{
	DEFAULT_TARGET = 1,
	NEAREST_TARGET,
	PINNED_TARGET,
	CROWDED_TARGET
}

public void OnPluginStart()
{
	g_hAllowBhop = CreateConVar("ai_SpitterBhop", "1", "是否开启 Spitter 连跳功能", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hBhopSpeed = CreateConVar("ai_SpitterBhopSpeed", "100", "Spitter 连跳的速度", CVAR_FLAG, true, 0.0);
	g_hBhopStartDistance = CreateConVar("ai_SpitterBhopStartDistance", "2500.0", "Spitter 距离最近生还者多远时开始连跳", CVAR_FLAG, true, 0.0);
	g_hPathBhop = CreateConVar("ai_spitter3_path_bhop", "1", "是否优先使用 anne_nextbot 路径前视连跳", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hPathLookAheadDepth = CreateConVar("ai_spitter3_path_lookahead_depth", "6", "路径连跳最大前视节点数", CVAR_FLAG, true, 1.0, true, 16.0);
	g_hPathLaneOffset = CreateConVar("ai_spitter3_path_lane_offset", "12.0", "路径连跳的最大稳定侧向分流距离", CVAR_FLAG, true, 0.0, true, 40.0);
	g_hTargetPolicy = CreateConVar("ai_SpitterTarget", "3", "Spitter 目标选择：1=默认 2=最近 3=被控优先，否则第一个生还 4=人多处", CVAR_FLAG, true, 1.0, true, 4.0);
	g_hPinnedPriority = CreateConVar("ai_SpitterPinnedPr", "6,3,1,5", "被控目标优先级（被控特感编号，逗号分隔）", CVAR_FLAG);
	g_hKilledAfterSpit = CreateConVar("ai_SpiiterDieAfterSpit", "0", "是否开启 Spitter 吐完痰后处死功能", CVAR_FLAG, true, 0.0, true, 1.0);
	// HookEvent
	HookEvent("ability_use", abilityUseHandler);
	// AddChangeHook
	g_hSpitRange = FindConVar("z_spit_range");
	g_hPinnedPriority.AddChangeHook(pinnedPriorityCvarChangedHandler);
	// GetPriority
	getPinnedPriority();
	// CreateTimer
	delete checkPinnedTimer;
	checkPinnedTimer = CreateTimer(CHECK_PINNED_TIME, checkPinnedAndCrowdTargetHandler, _, TIMER_REPEAT);
}

public void OnAllPluginsLoaded()
{
	if (!LibraryExists(ANNE_NEXTBOT_LIBRARY) || !AnneNextBot_IsActive())
		SetFailState("ai_spitter3 requires anne_nextbot");
	if (!AIPathSnapshot_Setup())
		SetFailState("ai_spitter3 failed to prepare path snapshot calls");
	if (!AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Spitter, true))
		SetFailState("ai_spitter3 failed to enable the anne_nextbot path broker");
}

public void OnPluginEnd()
{
	if (LibraryExists(ANNE_NEXTBOT_LIBRARY))
	{
		AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Spitter, false);
	}
	delete checkPinnedTimer;
}

public void AnneNextBot_OnSpitterPathSnapshotUpdated(int client)
{
	if (isAiSpitter(client) && !AIPathSnapshot_IsReady(client))
		AIPathMovement_Reset(client);
}

void pinnedPriorityCvarChangedHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
	getPinnedPriority();
}

public void abilityUseHandler(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_hKilledAfterSpit.BoolValue) { return; }
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (isAiSpitter(client) && IsPlayerAlive(client)) { CreateTimer(SPITTER_KILL_DELAY, killSpitterHandler, client); }
}

public Action killSpitterHandler(Handle timer, int client)
{
	if (!isAiSpitter(client) || !IsPlayerAlive(client)) { return Plugin_Continue; }
	ForcePlayerSuicide(client);
	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int spitter, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if (!isAiSpitter(spitter) || !IsPlayerAlive(spitter)) { return Plugin_Continue; }
	static float velVec[3], eyeAngle[3], curSpeed;
	static int targetDist;
	GetEntPropVector(spitter, Prop_Data, "m_vecVelocity", velVec);
	curSpeed = SquareRoot(Pow(velVec[0], 2.0) + Pow(velVec[1], 2.0));
	targetDist = GetClosetSurvivorDistance(spitter);
	if (buttons & (IN_ATTACK | IN_ATTACK2))
		AIPathMovement_Reset(spitter);
	if (GetEntityMoveType(spitter) & MOVETYPE_LADDER)
	{
		AIPathMovement_Reset(spitter);
		buttons &= ~IN_JUMP;
		buttons &= ~IN_DUCK;
		return Plugin_Changed;
	}
	if ((buttons & IN_ATTACK) && delayExpired(spitter, 0, SPITTER_JUMP_DELAY))
	{
		AIPathMovement_Reset(spitter);
		delayStart(spitter, 0);
		buttons |= IN_JUMP;
		return Plugin_Changed;
	}
	bool onGround = (GetEntityFlags(spitter) & FL_ONGROUND) != 0;
	if (!onGround)
	{
		if (AIPathMovement_IsPathHopActive(spitter))
		{
			float correctedVelocity[3];
			if (AIPathMovement_ComputePathAirCorrection(spitter, velVec, 25.0, 1.0, 89.0, 0.3, 0.3, 0.12, correctedVelocity))
			{
				velVec = correctedVelocity;
				TeleportEntity(spitter, NULL_VECTOR, NULL_VECTOR, correctedVelocity);
			}
			AIPathMovement_AlignFacing(velVec, angles);
			return Plugin_Changed;
		}
		return Plugin_Continue;
	}
	AIPathMovement_Reset(spitter);
	if (!(targetDist < g_hBhopStartDistance.FloatValue && curSpeed > 150.0) || !g_hAllowBhop.BoolValue) { return Plugin_Continue; }
	// 上次起跳安全检查因地形失败且仍在冷却期内时跳过尝试，避免受阻时每帧重复整套 trace
	if (AIPathMovement_IsRouteCheckThrottled(spitter)) { return Plugin_Continue; }
	GetClientEyeAngles(spitter, eyeAngle);
	bool pathGuided = false;
	float pathGoal[3];
	if (g_hPathBhop.BoolValue && AIPathSnapshot_IsReady(spitter) && !AIPathSnapshot_HasSpecialMoveAhead(spitter, 2))
	{
		float selfPos[3];
		float maxEstimateDist = curSpeed * 0.50;
		if (maxEstimateDist < 130.0)
			maxEstimateDist = 130.0;
		float laneOffset = AIPathSnapshot_GetSuggestedLateralOffset(spitter, g_hPathLaneOffset.FloatValue);
		if (AIPathSnapshot_GetLookAheadGoal(spitter, maxEstimateDist, laneOffset, pathGoal, g_hPathLookAheadDepth.IntValue))
		{
			GetClientAbsOrigin(spitter, selfPos);
			MakeVectorFromPoints(selfPos, pathGoal, eyeAngle);
			eyeAngle[2] = 0.0;
			GetVectorAngles(eyeAngle, eyeAngle);
			pathGuided = true;
		}
	}
	if (pathGuided)
	{
		buttons &= ~(IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_LEFT | IN_RIGHT);
		buttons |= IN_FORWARD;
	}
	buttons |= IN_JUMP;
	buttons |= IN_DUCK;
	float proposedVelocity[3], pushVelocity[3];
	GetAngleVectors(eyeAngle, pushVelocity, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(pushVelocity, pushVelocity);
	ScaleVector(pushVelocity, g_hBhopSpeed.FloatValue);
	GetEntPropVector(spitter, Prop_Data, "m_vecAbsVelocity", proposedVelocity);
	AddVectors(proposedVelocity, pushVelocity, proposedVelocity);
	bool hasSight = view_as<bool>(GetEntProp(spitter, Prop_Send, "m_hasVisibleThreats"));
	if (!AIPathMovement_IsJumpRouteSafe(
		spitter,
		proposedVelocity,
		AIPathMovement_GetJumpAirTime(),
		56.0,
		hasSight,
		89.0
	))
	{
		AIPathMovement_MarkRouteCheckFailure(spitter);
		return Plugin_Continue;
	}
	bool hopped = spitterDoBhop(spitter, buttons, eyeAngle);
	if (pathGuided && hopped)
	{
		float pathVelocity[3];
		GetEntPropVector(spitter, Prop_Data, "m_vecAbsVelocity", pathVelocity);
		AIPathMovement_AlignFacing(pathVelocity, angles);
		AIPathMovement_BeginPathHop(spitter, pathGoal, AIPathMovement_GetHorizontalSpeed(pathVelocity));
	}
	return Plugin_Changed;
}

public void OnClientDisconnect(int client)
{
	AIPathMovement_Reset(client);
}

public void OnClientPutInServer(int client)
{
	AIPathMovement_Reset(client);
}

public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (!isAiSpitter(specialInfected) || !IsPlayerAlive(specialInfected)) { return Plugin_Continue; }
	static int newTarget;
	static float selfPos[3], targetPos[3];
	GetClientAbsOrigin(specialInfected, selfPos);
	switch (g_hTargetPolicy.IntValue)
	{
		case NEAREST_TARGET:
		{
			newTarget = GetClosetSurvivor(specialInfected);
			if (!IsValidSurvivor(newTarget) || !IsPlayerAlive(newTarget)) { return Plugin_Continue; }
			curTarget = newTarget;
			return Plugin_Changed;
		}
		case PINNED_TARGET:
		{
			if (IsValidSurvivor(pinnedTarget) && IsPlayerAlive(pinnedTarget))
			{
				GetEntPropVector(pinnedTarget, Prop_Send, "m_vecOrigin", targetPos);
				if (GetVectorDistance(selfPos, targetPos) > g_hSpitRange.FloatValue) { return Plugin_Continue; }
				curTarget = pinnedTarget;
				return Plugin_Changed;
			}
		}
		case CROWDED_TARGET:
		{
			if (IsValidSurvivor(crowdedTarget) && IsPlayerAlive(crowdedTarget))
			{
				GetEntPropVector(crowdedTarget, Prop_Send, "m_vecOrigin", targetPos);
				if (GetVectorDistance(selfPos, targetPos) > g_hSpitRange.FloatValue) { return Plugin_Continue; }
				curTarget = crowdedTarget;
				return Plugin_Changed;
			}
		}
	}
	return Plugin_Continue;
}

// 方法
bool spitterDoBhop(int client, int& buttons, float eyeAngle[3])
{
	if ((buttons & IN_FORWARD) || (buttons & IN_MOVELEFT) || (buttons & IN_MOVERIGHT))
	{
		clientPush(client, eyeAngle, g_hBhopSpeed.FloatValue);
		return true;
	}
	return false;
}

void clientPush(int client, float eyeAngle[3], float force)
{
	static float eyeAngleVec[3], velVec[3];
	GetAngleVectors(eyeAngle, eyeAngleVec, NULL_VECTOR, NULL_VECTOR);
	NormalizeVector(eyeAngleVec, eyeAngleVec);
	ScaleVector(eyeAngleVec, force);
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velVec);
	AddVectors(velVec, eyeAngleVec, velVec);
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velVec);
}

bool isAiSpitter(int client)
{
	return GetInfectedClass(client) == ZC_SPITTER && IsFakeClient(client);
}

void delayStart(int client, int no)
{
	if (!IsValidClient(client)) { return; }
	clientDelay[client][no] = GetGameTime();
}

bool delayExpired(int client, int no, float ttl)
{
	return GetGameTime() - clientDelay[client][no] > ttl;
}

void getPinnedPriority()
{
	char priority[32] = {'\0'}, result[6][4];
	g_hPinnedPriority.GetString(priority, sizeof(priority));
	ExplodeString(priority, ",", result, 6, 4);
	for (int i = 0; i < 6; i++)
	{
		if (result[i][0] == '\0') { continue; }
		pinnedPriority[i] = StringToInt(result[i]);
	}
}

public Action checkPinnedAndCrowdTargetHandler(Handle timer)
{
	pinnedTarget = getTargetByPriority();
	crowdedTarget = getCrowdTarget();
	return Plugin_Continue;
}

int getTargetByPriority()
{
	static int i, pummelTarget, pouncedTarget, pulledTarget, jockedTarget;
	static float flow;
	static ArrayList flowList;
	pummelTarget = pouncedTarget = pulledTarget = jockedTarget = -1;
	flow = 0.0;
	flowList = new ArrayList(2);
	for (i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)) { continue; }
		flow = L4D2Direct_GetFlowDistance(i);
		if (flow && flow != -9999.0) { flowList.Set(flowList.Push(flow), i, 1); }
		// 检测被撞
		if (GetEntPropEnt(i, Prop_Send, "m_pummelAttacker") > 0)
		{
			pummelTarget = i;
			continue;
		}
		// 检测被扑
		if (GetEntPropEnt(i, Prop_Send, "m_pounceAttacker") > 0)
		{
			pouncedTarget = i;
			continue;
		}
		// 检测被拉
		if (GetEntPropEnt(i, Prop_Send, "m_tongueOwner") > 0)
		{
			pulledTarget = i;
			continue;
		}
		// 检测被骑
		if (GetEntPropEnt(i, Prop_Send, "m_jockeyAttacker") > 0)
		{
			jockedTarget = i;
			continue;
		}
	}
	// 没有人被控，选取路程最高的玩家
	if (!IsValidSurvivor(pummelTarget) && !IsValidSurvivor(pouncedTarget) && !IsValidSurvivor(pulledTarget) && !IsValidSurvivor(jockedTarget))
	{
		// 没有活着的生还者，返回 -1
		if (flowList.Length < 1)
		{
			delete flowList;
			return -1;
		}
		flowList.Sort(Sort_Descending, Sort_Float);
		i = flowList.Get(0, 1);
		delete flowList;
		return i;
	}
	// 后续按优先级选取被控玩家，不再使用路程列表，先释放防止句柄泄漏
	delete flowList;
	// 根据优先级选取被控玩家
	for (i = 0; i < 6; i++)
	{
		switch (pinnedPriority[i])
		{
			case ZC_SMOKER: { if (IsValidSurvivor(pulledTarget)) { return pulledTarget; } }
			case ZC_HUNTER: { if (IsValidSurvivor(pouncedTarget)) { return pouncedTarget; } }
			case ZC_JOCKEY: { if (IsValidSurvivor(jockedTarget)) { return jockedTarget; } }
			case ZC_CHARGER: { if (IsValidSurvivor(pummelTarget)) { return pummelTarget; } }
		}
	}
	return -1;
}

int getCrowdTarget()
{
	static int i, j, index;
	static float selfPos[3], targetPos[3];
	static ArrayList flowList;
	flowList = new ArrayList(2);
	for (i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR	|| !IsPlayerAlive(i)) { continue; }
		GetClientAbsOrigin(i, selfPos);
		index = flowList.Push(i);
		// Push 只写入块内第一格，第二格（距离和）需要显式清零
		flowList.Set(index, 0.0, 1);
		for (j = 1; j <= MaxClients; j++)
		{
			if (!IsClientInGame(j) || GetClientTeam(j) != TEAM_SURVIVOR	|| !IsPlayerAlive(j) || i == j) { continue; }
			GetEntPropVector(j, Prop_Send, "m_vecOrigin", targetPos);
			flowList.Set(index, view_as<float>(flowList.Get(index, 1)) + GetVectorDistance(selfPos, targetPos), 1);
		}
	}
	if (flowList.Length < 1)
	{
		delete flowList;
		return -1;
	}
	flowList.SortCustom(sortByDistanceAsc);
	i = flowList.Get(0, 0);
	delete flowList;
	return i;
}

int sortByDistanceAsc(int index1, int index2, ArrayList array, Handle hndl)
{
	return FloatCompare(array.Get(index1, 1), array.Get(index2, 1));
}
