#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#include "../include/treeutil.inc"

#define CVAR_FLAG FCVAR_NOTIFY
#define EYE_ANGLE_UP_HEIGHT 15.0
#define NAV_MESH_HEIGHT 20.0
#define FALL_DETECT_HEIGHT 120.0
#define COMMAND_INTERVAL 1.0
#define PLAYER_HEIGHT 72.0

enum AimType
{
	AimEye,
	AimBody,
	AimChest
};

public Plugin myinfo = 
{
	name 			= "Ai Boomer 2.0",
	author 			= "夜羽真白",
	description 	= "Ai Boomer 增强 2.0 版本",
	version 		= "2.0.0.0",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

ConVar g_hVomitRange, g_hVomitDuration, g_hVomitInterval;
// Bools
bool can_bile[MAXPLAYERS + 1] = { true }, in_bile_interval[MAXPLAYERS + 1] = { false };
// Ints，bile_frame 0 位：当前目标索引，1 位：循环次数
int bile_frame[MAXPLAYERS + 1][2];
// Handles
Handle bile_interval_timer[MAXPLAYERS + 1] = { null };
// Lists
ArrayList targetList[MAXPLAYERS + 1] = { null };

public void OnPluginStart()
{
	// CreateConVars
	
	
	
	
	
	
	
	g_hVomitRange = FindConVar("z_vomit_range");
	g_hVomitDuration = FindConVar("z_vomit_duration");
	g_hVomitInterval = FindConVar("z_vomit_interval");
	// HookEvents
	HookEvent("player_spawn", evt_PlayerSpawn);
	HookEvent("player_shoved", evt_PlayerShoved);
	// SetConVars
	SetConVarFloat(FindConVar("boomer_exposed_time_tolerance"), 10000.0);
	SetConVarFloat(FindConVar("boomer_vomit_delay"), 0.1);
}
public void OnPluginEnd()
{
	ResetConVar(FindConVar("boomer_exposed_time_tolerance"));
	ResetConVar(FindConVar("boomer_vomit_delay"));
	for (int i = 0; i < MAXPLAYERS + 1; i++) { delete targetList[i]; }
}

public void evt_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsBoomer(client))
	{
		in_bile_interval[client] = true;
		CreateTimer(1.5, Timer_ResetAbility, client);
	}
}
public void evt_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsBoomer(client))
	{
		can_bile[client] = true;
		in_bile_interval[client] = false;
		bile_frame[client][0] = bile_frame[client][1] = 0;
		delete bile_interval_timer[client];
		// Build ArrayList
		if (targetList[client] != null) { targetList[client].Clear(); }
		else { targetList[client] = new ArrayList(2); }
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
	if (IsBoomer(client))
	{
		float self_pos[3] = {0.0}, self_eye_pos[3] = {0.0}, targetPos[3] = {0.0}, target_eye_pos[3] = {0.0}, vec_speed[3] = {0.0}, cur_speed = 0.0;
		int flags = GetEntityFlags(client), target = GetClientAimTarget(client, true), closet_survivor_dist = GetClosetSurvivorDistance(client);
		bool has_sight = view_as<bool>(GetEntProp(client, Prop_Send, "m_hasVisibleThreats"));
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vec_speed);
		cur_speed = SquareRoot(Pow(vec_speed[0], 2.0) + Pow(vec_speed[1], 2.0));
		GetClientAbsOrigin(client, self_pos);
		GetClientEyePosition(client, self_eye_pos);
		if (has_sight && IsValidSurvivor(target) && !in_bile_interval[client] && targetList[client].Length < 1)
		{
			float aim_angles[3] = {0.0}, dist = GetVectorDistance(self_pos, targetPos), height = self_pos[2] - targetPos[2];
			ComputeAimAngles(client, target, aim_angles, AimEye);
			if (true)
			{
				if (height == 0.0 || height < 0.0) { aim_angles[0] -= dist / (PLAYER_HEIGHT * 4.3); }
				else if (height > 0.0) { aim_angles[0] -= dist / (PLAYER_HEIGHT * 5); }
			}
			TeleportEntity(client, NULL_VECTOR, aim_angles, NULL_VECTOR);
		}
		if (targetList[client].Length >= 1 && !in_bile_interval[client] && true)
		{
			if (bile_frame[client][0] < targetList[client].Length && bile_frame[client][1] < (5))
			{
				float aimAngles[3] = {0.0}, dist = GetVectorDistance(self_pos, targetPos), height = 0.0;
				int turnTarget = targetList[client].Get(bile_frame[client][0], 1);
				height = self_pos[2] - targetPos[2];
				ComputeAimAngles(client, turnTarget, aimAngles, AimEye);
				if (true)
				{
					if (height == 0.0 || height < 0.0) { aimAngles[0] -= dist / (PLAYER_HEIGHT * 4.3); }
					else if (height > 0.0) { aimAngles[0] -= dist / (PLAYER_HEIGHT * 5); }
				}
				TeleportEntity(client, NULL_VECTOR, aimAngles, NULL_VECTOR);
				bile_frame[client][1] += 1;
			}
			else if (bile_frame[client][0] >= targetList[client].Length)
			{
				targetList[client].Clear();
				bile_frame[client][0] = bile_frame[client][1] = 0;
			}
			else
			{
				bile_frame[client][0] += 1;
				bile_frame[client][1] = 0;
			}
		}
		// 靠近生还者，立即喷吐
		if ((flags & FL_ONGROUND) && IsValidSurvivor(target) && has_sight && closet_survivor_dist <= RoundToNearest(0.8 * g_hVomitRange.FloatValue) && !in_bile_interval[client] && can_bile[client] && Player_IsVisible_To(target, client))
		{
			buttons |= IN_FORWARD;
			buttons |= IN_ATTACK;
			if (can_bile[client]) { CreateTimer(g_hVomitDuration.FloatValue, Timer_ResetBile, client); }
			can_bile[client] = false;
		}
		// 目标是被控或者倒地的生还，则令其蹲下攻击
		if (IsValidSurvivor(target) && (IsClientIncapped(target) || IsClientPinned(target)))
		{
			buttons |= IN_DUCK;
			buttons |= IN_ATTACK2;
		}
		// 强行被喷
		if (false && (buttons & IN_ATTACK) && !in_bile_interval[client] && IsValidSurvivor(target))
		{
			in_bile_interval[client] = true;
			for (int i = 1; i <= MaxClients; i++)
			{
				if (IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(i))
				{
					GetClientEyePosition(i, target_eye_pos);
					Handle hTrace = TR_TraceRayFilterEx(self_eye_pos, target_eye_pos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, client);
					if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i)
					{
						if (GetVectorDistance(self_eye_pos, target_eye_pos) <= g_hVomitRange.FloatValue)
						{
							L4D_CTerrorPlayer_OnVomitedUpon(i, client);
						}
					}
					delete hTrace;
				}
			}
			CreateTimer(g_hVomitInterval.FloatValue, Timer_ResetAbility, client);
		}
		// 连跳
		if (true && has_sight && (flags & FL_ONGROUND) && 0.5 * g_hVomitRange.FloatValue < closet_survivor_dist < 10000.0 && cur_speed > 160.0 && IsValidSurvivor(target))
		{
			float vel_buffer[3] = {0.0};
			GetClientAbsOrigin(target, targetPos);
			vel_buffer = CalculateVel(self_pos, targetPos, (150.0));
			buttons |= IN_JUMP;
			buttons |= IN_DUCK;
			if (Do_Bhop(client, buttons, vel_buffer))
			{
				return Plugin_Changed;
			}
		}
		// 爬梯时，禁止连跳
		if (GetEntityMoveType(client) & MOVETYPE_LADDER)
		{
			buttons &= ~IN_JUMP;
			buttons &= ~IN_DUCK;
		}
	}
	return Plugin_Continue;
}
// 重置胖子能力使用限制
public Action Timer_ResetAbility(Handle timer, int client)
{
	if (IsBoomer(client) && IsPlayerAlive(client))
	{
		can_bile[client] = true;
		in_bile_interval[client] = false;
		return Plugin_Continue;
	}
	return Plugin_Stop;
}
public Action Timer_ResetBile(Handle timer, int client)
{
	if (IsBoomer(client) && IsPlayerAlive(client))
	{
		can_bile[client] = false;
		in_bile_interval[client] = true;
		// 喷吐时间过后，清除目标集合数据
		targetList[client].Clear();
		bile_frame[client][0] = bile_frame[client][1] = 0;
		CreateTimer(g_hVomitInterval.FloatValue, Timer_ResetAbility, client);
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

// 获取目标
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (IsBoomer(specialInfected) && IsPlayerAlive(specialInfected))
	{
		float eyePos[3] = {0.0}, targetEyePos[3] = {0.0}, dist = 0.0;
		GetClientEyePosition(specialInfected, eyePos);
		// 寻找范围内符合要求的玩家，优先找被控或者倒地的
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i) && (IsClientIncapped(i) || IsClientPinned(i)))
			{
				GetClientEyePosition(i, targetEyePos);
				eyePos[2] = targetEyePos[2] = 0.0;
				dist = GetVectorDistance(eyePos, targetEyePos);
				if ((300.0) > 0.0 && dist <= (300.0))
				{
					Handle hTrace = TR_TraceRayFilterEx(eyePos, targetEyePos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, specialInfected);
					if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i)
					{
						curTarget = i;
						return Plugin_Changed;
					}
					delete hTrace;
				}
			}
		}
	}
	return Plugin_Continue;
}

// 当生还被胖子喷中时，开始计算范围内的玩家
public Action L4D_OnVomitedUpon(int victim, int &attacker, bool &boomerExplosion)
{
	// 当前 Boomer 目标集合中没有目标，开始获取目标
	if (IsBoomer(attacker) && targetList[attacker].Length < 1)
	{
		float eyePos[3] = {0.0}, targetEyePos[3] = {0.0}, dist = 0.0;
		GetClientEyePosition(attacker, eyePos);
		for (int i = 1; i <= MaxClients; i++)
		{
			if (i != victim && IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
			{
				GetClientEyePosition(i, targetEyePos);
				eyePos[2] = targetEyePos[2] = 0.0;
				dist = GetVectorDistance(eyePos, targetEyePos);
				if (dist <= g_hVomitRange.FloatValue + 100.0)
				{
					Handle trace = TR_TraceRayFilterEx(eyePos, targetEyePos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, attacker);
					if (!TR_DidHit(trace) || TR_GetEntityIndex(trace) == i)
					{
						int index = targetList[attacker].Push(dist);
						targetList[attacker].Set(index, i, 1);
					}
					delete trace;
				}
			}
		}
		if (targetList[attacker].Length > 1)
		{
			targetList[attacker].Sort(Sort_Ascending, Sort_Float);
		}
/* 		PrintToConsoleAll("输出 boomer 目标数组");
		for (int i = 0; i < targetList[attacker].Length; i++)
		{
			PrintToConsoleAll("第：%d 个，%d - %N，距离：%.2f", i + 1, targetList[attacker].Get(i, 1), targetList[attacker].Get(i, 1), targetList[attacker].Get(i, 0));
		} */
	}
	return Plugin_Continue;
}

// 方法，是否 AI 胖子
bool IsBoomer(int client)
{
	return view_as<bool>(GetInfectedClass(client) == view_as<int>(ZC_BOOMER) && IsFakeClient(client));
}
// 计算与目标之间的向量
float[] CalculateVel(float self_pos[3], float target_pos[3], float force)
{
	float vecbuffer[3] = {0.0};
	SubtractVectors(target_pos, self_pos, vecbuffer);
	NormalizeVector(vecbuffer, vecbuffer);
	ScaleVector(vecbuffer, force);
	return vecbuffer;
}
// 检测下一帧的位置是否会撞墙或向下受到伤害或会掉落
bool Dont_HitWall_Or_Fall(int client, float vel[3])
{
	bool hullrayhit = false;
	int down_hullray_hitent = -1;
	char down_hullray_hitent_classname[16] = {'\0'};
	float selfpos[3] = {0.0}, resultpos[3] = {0.0}, mins[3] = {0.0}, maxs[3] = {0.0}, hullray_endpos[3] = {0.0}, down_hullray_startpos[3] = {0.0}, down_hullray_endpos[3] = {0.0}, down_hullray_hitpos[3] = {0.0};
	GetClientAbsOrigin(client, selfpos);
	AddVectors(selfpos, vel, resultpos);
	GetClientMins(client, mins);
	GetClientMaxs(client, maxs);
	selfpos[2] += NAV_MESH_HEIGHT;
	resultpos[2] += NAV_MESH_HEIGHT;
	// 由自身位置 +NAV_MESH_HEIGHT 高度 向前射出大小为 mins，maxs 的固体，检测前方 NAV_MESH_HEIGHT 距离是否能撞到，撞到则不允许连跳
	Handle hTrace = TR_TraceHullFilterEx(selfpos, resultpos, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilter);
	if (TR_DidHit(hTrace))
	{
		hullrayhit = true;
		TR_GetEndPosition(hullray_endpos, hTrace);
		if (GetVectorDistance(selfpos, hullray_endpos) <= NAV_MESH_HEIGHT)
		{
			delete hTrace;
			return false;
		}
	}
	delete hTrace;
	resultpos[2] -= NAV_MESH_HEIGHT;
	// 没有撞到，则说明前方 g_hAttackRange 距离内没有障碍物，接着进行下一帧理论位置向下的检测，检测是否有会对自身造成伤害的位置
	if (!hullrayhit)
	{
		down_hullray_startpos = resultpos;
	}
	CopyVectors(down_hullray_startpos, down_hullray_endpos);
	down_hullray_endpos[2] -= 100000.0;
	Handle hDownTrace = TR_TraceHullFilterEx(down_hullray_startpos, down_hullray_endpos, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilter);
	if (TR_DidHit(hDownTrace))
	{
		TR_GetEndPosition(down_hullray_hitpos, hDownTrace);
		// 如果向下的射线撞到的位置减去起始位置的高度大于 FALL_DETECT_HEIGHT 则说明会掉下去，返回 false
		if (FloatAbs(down_hullray_startpos[2] - down_hullray_hitpos[2]) > FALL_DETECT_HEIGHT)
		{
			delete hDownTrace;
			return false;
		}
		down_hullray_hitent = TR_GetEntityIndex(hDownTrace);
		GetEdictClassname(down_hullray_hitent, down_hullray_hitent_classname, sizeof(down_hullray_hitent_classname));
		if (strcmp(down_hullray_hitent_classname, "trigger_hurt") == 0)
		{
			delete hDownTrace;
			return false;
		}
		delete hDownTrace;
		return true;
	}
	delete hDownTrace;
	return false;
}
bool TR_EntityFilter(int entity, int mask)
{
	if (entity <= MaxClients)
	{
		return false;
	}
	else if (entity > MaxClients)
	{
		char classname[16] = {'\0'};
		GetEdictClassname(entity, classname, sizeof(classname));
		if (strcmp(classname, "infected") == 0 || strcmp(classname, "witch") == 0 || strcmp(classname, "prop_physics") == 0 || strcmp(classname, "tank_rock") == 0)
		{
			return false;
		}
	}
	return true;
}
// 胖子连跳
bool Do_Bhop(int client, int &buttons, float vec[3])
{
	if (buttons & IN_FORWARD || buttons & IN_MOVELEFT || buttons & IN_MOVERIGHT)
	{
		if (ClientPush(client, vec))
		{
			return true;
		}
	}
	return false;
}
bool ClientPush(int client, float vec[3])
{
	float curvel[3] = {0.0};
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", curvel);
	AddVectors(curvel, vec, curvel);
	if (Dont_HitWall_Or_Fall(client, curvel))
	{
		if (GetVectorLength(curvel) <= 250.0)
		{
			NormalizeVector(curvel, curvel);
			ScaleVector(curvel, 251.0);
		}
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, curvel);
		return true;
	}
	return false;
}

void ComputeAimAngles(int client, int target, float angles[3], AimType type = AimEye)
{
	float selfpos[3], targetpos[3], lookat[3];
	GetClientEyePosition(client, selfpos);
	switch (type)
	{
		case AimEye:
		{
			GetClientEyePosition(target, targetpos);
		}
		case AimBody:
		{
			GetClientAbsOrigin(target, targetpos);
		}
		case AimChest:
		{
			GetClientAbsOrigin(target, targetpos);
			targetpos[2] += 45.0;
		}
	}
	MakeVectorFromPoints(selfpos, targetpos, lookat);
	GetVectorAngles(lookat, angles);
}

