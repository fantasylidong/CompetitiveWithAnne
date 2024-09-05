#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <treeutil>

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define CVAR_FLAGS		FCVAR_NOTIFY
#define DEBUG_ALL 0
#define NAV_MESH_HEIGHT 20.0
#include <l4d2_saferoom_detect>

#define PLUGIN_VERSION "2.2"
ConVar 	g_hCvarEnable;
ConVar 	g_hCvarStuckInterval;
ConVar 	g_hCvarNonStuckRadius;
ConVar  g_hCvarRusherPunish;
ConVar  g_hCvarRusherDist;
ConVar  g_hCvarRusherCheckTimes;
ConVar  g_hCvarRusherCheckInterv;
ConVar  g_hCvarRusherMinPlayers;

Handle 	g_hTimerRusher = null;

float 	g_pos[MAXPLAYERS+1][3];
float	g_fTankClawRange;

int  	g_iSurvivorNum = 0,g_iSurvivors[MAXPLAYERS + 1] = {0};
int 	g_bEnabled;
int 	g_iTimes[MAXPLAYERS+1];
int 	g_iStuckTimes[MAXPLAYERS+1];
int 	g_iRushTimes[MAXPLAYERS+1];
int		g_iTanksCount;
bool successTeleport = true;
/*
	ChangeLog:
	2.2
		L4D2_IsVisibleToPlayer函数对tank好像不怎么起作用，更换为原来的处理
	2.1
		更改PlayerVisibleToSDK函数为left4dhooks里L4D2_IsVisibleToPlayer函数（两个相同，只是不再需要自己处理sdk和签名）
	2.0
		救援关不启用跑男惩罚
	1.9
		更改PlayerVisibleTo函数为PlayerVisibleToSDK函数

	1.8
		增加所有生还者都在tank进度前时不触发跑男惩罚
		
	1.7
		生还者进度超过98%的也不会传送（防止传送到安全门内）这种情况改为用l4d2_saferoom_detect解决
	
	1.6
		去除tank在梯子上不能传送的限制（极少数情况tank在梯子上卡住了）
		
	1.5
		修改tank传送可能被卡住的情况
		
	1.4
		救援关不启动rush传送，修改Tank流程检测.生还者进度超过98%的也不会传送（防止传送到安全门内）
	 
	1.3 
		增加倒地被控玩家不进入检测
	
	1.2 
	    增加tank流程检测
	
	1.1 (01-Mar-2019)
	 	修改tank传送逻辑
	
	1.0 (12-4-2022)
	    版本发布
	
*/
public Plugin myinfo = 
{
	name = "Anne Stuck Tank Teleport System",
	author = "东",
	description = "当tank卡住时传送tank到靠近玩家但是玩家看不到的地方，有求生跑男时会传送到跑男位置",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
}

public void OnPluginStart()
{
	CreateConVar(							"l4d2_Anne_stuck_tank_teleport",				PLUGIN_VERSION,	"Plugin version", FCVAR_DONTRECORD );
	g_hCvarEnable = CreateConVar(			"l4d2_Anne_stuck_tank_teleport_enable",					"1",		"Enable plugin (1 - On / 0 - Off)", CVAR_FLAGS );	
	g_hCvarStuckInterval = CreateConVar(	"l4d2_Anne_stuck_tank_teleport_check_interval",			"3",		"Time intervals (in sec.) tank stuck should be checked", CVAR_FLAGS );
	g_hCvarNonStuckRadius = CreateConVar(	"l4d2_Anne_stuck_tank_teleport_non_stuck_radius",		"20",		"Maximum radius where tank is cosidered non-stucked when not moved during X (9) sec. (see l4d2_Anne_stuck_tank_teleport_check_interval ConVar)", CVAR_FLAGS );
	g_hCvarRusherPunish = CreateConVar(		"l4d2_Anne_stuck_tank_teleport_rusher_punish",			"1",		"Punish the player who rush too far from the nearest tank by teleporting tank to him? (0 - No / 1 - Yes)", CVAR_FLAGS );
	g_hCvarRusherDist = CreateConVar(		"l4d2_Anne_stuck_tank_teleport_rusher_dist",			"2800",		"Maximum distance to the nearest tank considered as rusher", CVAR_FLAGS );
	g_hCvarRusherCheckTimes = CreateConVar(	"l4d2_Anne_stuck_tank_teleport_rusher_check_times",		"6",		"Number of checks before finally considering player as rusher", CVAR_FLAGS );
	g_hCvarRusherCheckInterv = CreateConVar("l4d2_Anne_stuck_tank_teleport_rusher_check_interval",	"3",		"Interval (in sec.) between each check for rusher", CVAR_FLAGS );	
	g_hCvarRusherMinPlayers = CreateConVar(	"l4d_TankAntiStuck_rusher_minplayers",		"2",		"Minimum living players allowed for 'Rusher player' rule to work", CVAR_FLAGS );
	HookEvent("tank_spawn",       		Event_TankSpawn,  	EventHookMode_Post);
	HookEvent("player_death",   		Event_PlayerDeath,	EventHookMode_Pre);
	HookEvent("round_start", 			Event_RoundStart,	EventHookMode_PostNoCopy);
	HookEvent("round_end", 				Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("finale_win", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("mission_lost", 			Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("map_transition", 		Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("player_disconnect", 		Event_PlayerDisconnect, EventHookMode_Pre);	
	//AutoExecConfig(true,			"l4d2_Anne_stuck_tank_teleport");
	
	HookConVarChange(g_hCvarEnable,				ConVarChanged);
	HookConVarChange(g_hCvarRusherPunish,		ConVarChanged);
	
	GetCvars();
	
	for (int i = 1; i <= MaxClients; i++) {
		if (i != 0 && IsClientInGame(i)) {
			if (IsTank(i))
				BeginTankTracing(i);
		}
	}
}

void BeginTankTracing(int client)
{
	g_iStuckTimes[client] = 0;
	GetClientAbsOrigin(client, g_pos[client]);
	//3s种检查一次tank的移动距离
	CreateTimer(g_hCvarStuckInterval.FloatValue, Timer_CheckPos, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_bEnabled = g_hCvarEnable.BoolValue;	
	if (g_hTimerRusher != null) {
		delete g_hTimerRusher;
		g_hTimerRusher = null;
	}
}
#define g_fmindistance 400.0
//判断该坐标是否可以看到生还或者距离小于300码
stock bool PlayerVisibleTo(float spawnpos[3])
{
	float pos[3];
	g_iSurvivorNum = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsValidSurvivor(i) && IsPlayerAlive(i))
		{
			g_iSurvivors[g_iSurvivorNum] = i;
			g_iSurvivorNum++;
			GetClientEyePosition(i, pos);
			if(PosIsVisibleTo(i, spawnpos) || GetVectorDistance(spawnpos, pos) < g_fmindistance)
			{
				return true;
			}
		}	
	}
	return false;
}
//判断从该坐标发射的射线是否击中目标
stock bool PosIsVisibleTo(int client, const float targetposition[3])
{
	float position[3], vAngles[3], vLookAt[3], spawnPos[3];
	GetClientEyePosition(client, position);
	MakeVectorFromPoints(targetposition, position, vLookAt);
	GetVectorAngles(vLookAt, vAngles);
	Handle trace = TR_TraceRayFilterEx(targetposition, vAngles, MASK_VISIBLE, RayType_Infinite, TraceFilter, client);
	bool isVisible;
	isVisible = false;
	if(TR_DidHit(trace))
	{
		static float vStart[3];
		TR_GetEndPosition(vStart, trace);
		if((GetVectorDistance(targetposition, vStart, false) + 75.0) >= GetVectorDistance(position, targetposition))
		{
			isVisible = true;
		}
		else
		{
			spawnPos = targetposition;
			spawnPos[2] += 20.0;
			MakeVectorFromPoints(spawnPos, position, vLookAt);
			GetVectorAngles(vLookAt, vAngles);
			Handle trace2 = TR_TraceRayFilterEx(spawnPos, vAngles, MASK_VISIBLE, RayType_Infinite, TraceFilter, client);
			if(TR_DidHit(trace2))
			{
				TR_GetEndPosition(vStart, trace2);
				if((GetVectorDistance(spawnPos, vStart, false) + 75.0) >= GetVectorDistance(position, spawnPos))
				isVisible = true;
			}
			else
			{
				isVisible = true;
			}
			delete trace2;
//			CloseHandle(trace2);
		}
	}
	else
	{
		isVisible = true;
	}
	delete trace;
//	CloseHandle(trace);
	return isVisible;
}

bool TraceFilter(int entity, int contentsMask, any data)
{
	if(entity == data || (entity >= 1 && entity <= MaxClients))
    {
        return false;
    }
	return true;
}

//thanks fdxx https://github.com/fdxx/l4d2_plugins/blob/main/l4d2_si_spawn_control.sp
stock bool PlayerVisibleToSDK(float targetposition[3], bool IsTeleport = false){
	static float fTargetPos[3];

	float position[3];
	fTargetPos = targetposition;
	fTargetPos[2] += 62.0; //眼睛位置

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client))
		{
			GetClientEyePosition(client, position);
			//传送的时候无视倒地或者挂边生还者得实现
			if(IsTeleport && IsClientIncapped(client)){
				continue;
			}
			//太近直接返回看见
			if(GetVectorDistance(targetposition, position) < g_fmindistance)
			{
				#if(DEBUG_ALL)
					PrintToConsoleAll("找位：被玩家%N看见1", client);
				#endif
				return true;
			}
			if (L4D2_IsVisibleToPlayer(client, 2, 3, 0, targetposition))
			{
				#if(DEBUG_ALL)
					PrintToConsoleAll("找位：被玩家%N看见2", client);
				#endif
				return true;
			}
			if (L4D2_IsVisibleToPlayer(client, 2, 3, 0, fTargetPos))
			{
				#if(DEBUG_ALL)
					PrintToConsoleAll("找位：被玩家%N看见3", client);
				#endif
				return true;
			}
		}
	}

	return false;
}

bool IsOnValidMesh(float fReferencePos[3])
{
	Address pNavArea = L4D2Direct_GetTerrorNavArea(fReferencePos);
	if (pNavArea != Address_Null && !(L4D_GetNavArea_SpawnAttributes(pNavArea) & CHECKPOINT))
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool IsPlayerStuck(float fSpawnPos[3])
{
	//似乎所有客户端的尺寸都一样
	static const float fClientMinSize[3] = {-16.0, -16.0, 0.0};
	static const float fClientMaxSize[3] = {16.0, 16.0, 72.0};

	static bool bHit;
	static Handle hTrace;

	hTrace = TR_TraceHullFilterEx(fSpawnPos, fSpawnPos, fClientMinSize, fClientMaxSize, MASK_PLAYERSOLID, TraceFilter_Stuck);
	bHit = TR_DidHit(hTrace);

	delete hTrace;
	return bHit;
}

stock bool TraceFilter_Stuck(int entity, int contentsMask)
{
	if (entity <= MaxClients || !IsValidEntity(entity))
	{
		return false;
	}
	else{
		static char sClassName[20];
		GetEntityClassname(entity, sClassName, sizeof(sClassName));
		if (strcmp(sClassName, "env_physics_blocker") == 0 && !EnvBlockType(entity)){
			return false;
		}
	}
	return true;
}

stock bool EnvBlockType(int entity){
	int BlockType = GetEntProp(entity, Prop_Data, "m_nBlockType");
	//阻拦ai infected
	if(BlockType == 1 || BlockType == 2){
		return false;
	}
	else{
		return true;
	}
}

// 传送卡住坦克
public void SDK_UpdateThink(int client)
{
	TeleportTank(client);
}

#define g_fTeleportDistance 1000.0
public void TeleportTank(int client){
		static float fEyePos[3] = {0.0}, fSelfEyePos[3] = {0.0};
		GetClientEyePosition(client, fEyePos);
		float fSpawnPos[3] = {0.0}, fSurvivorPos[3] = {0.0}, fDirection[3] = {0.0}, fEndPos[3] = {0.0}, fMins[3] = {0.0}, fMaxs[3] = {0.0};
		int g_iTargetSurvivor= GetRandomSurvivor(1, -1);
		if (IsValidSurvivor(g_iTargetSurvivor))
		{
			GetClientEyePosition(g_iTargetSurvivor, fSurvivorPos);
			GetClientEyePosition(client, fSelfEyePos);
			fMins[0] = fSurvivorPos[0] - g_fTeleportDistance;
			fMaxs[0] = fSurvivorPos[0] + g_fTeleportDistance;
			fMins[1] = fSurvivorPos[1] - g_fTeleportDistance;
			fMaxs[1] = fSurvivorPos[1] + g_fTeleportDistance;
			fMaxs[2] = fSurvivorPos[2] + g_fTeleportDistance;
			fDirection[0] = 90.0;
			fDirection[1] = fDirection[2] = 0.0;
			fSpawnPos[0] = GetRandomFloat(fMins[0], fMaxs[0]);
			fSpawnPos[1] = GetRandomFloat(fMins[1], fMaxs[1]);
			fSpawnPos[2] = GetRandomFloat(fSurvivorPos[2], fMaxs[2]);
			int count2=0;
			#if(DEBUG_ALL)
				PrintToConsoleAll("Tank找位置传送中.坐标系为：%N", g_iTargetSurvivor);
			#endif
			while (PlayerVisibleTo(fSpawnPos) || !IsOnValidMesh(fSpawnPos) || IsPlayerStuck(fSpawnPos))
			{
				count2 ++;
				if(count2 > 20)
				{
					break;
				}
				fSpawnPos[0] = GetRandomFloat(fMins[0], fMaxs[0]);
				fSpawnPos[1] = GetRandomFloat(fMins[1], fMaxs[1]);
				fSpawnPos[2] = GetRandomFloat(fSurvivorPos[2], fMaxs[2]);
				TR_TraceRay(fSpawnPos, fDirection, MASK_SOLID, RayType_Infinite);
				if(TR_DidHit())
				{
					TR_GetEndPosition(fEndPos);
					fSpawnPos = fEndPos;
					fSpawnPos[2] += NAV_MESH_HEIGHT;
				}
			}
			if (count2<= 20)
			{
				for (int count = 0; count < g_iSurvivorNum; count++)
				{
					int index = g_iSurvivors[count];
					if (IsClientInGame(index))
					{
						GetClientEyePosition(index, fSurvivorPos);
						fSurvivorPos[2] -= 60.0;
						Address nav1 = L4D_GetNearestNavArea(fSpawnPos, 120.0, false, false, false, TEAM_INFECTED);
						Address nav2 = L4D_GetNearestNavArea(fSurvivorPos, 120.0, false, false, false, TEAM_INFECTED);
						if (L4D2_NavAreaBuildPath(nav1, nav2, g_fTeleportDistance * 1.73, TEAM_INFECTED, false) && GetVectorDistance(fSurvivorPos, fSpawnPos) >= 400.0 && nav1 != nav2)
						{
							TeleportEntity(client, fSpawnPos, NULL_VECTOR, NULL_VECTOR);
							SDKUnhook(client, SDKHook_PostThinkPost, SDK_UpdateThink);
							int newtarget = GetClosetMobileSurvivor(client);
							if (IsValidSurvivor(newtarget))
							{
								Logic_RunScript(COMMANDABOT_RESET, GetClientUserId(client), GetClientUserId(newtarget));
								Logic_RunScript(COMMANDABOT_ATTACK, GetClientUserId(client), GetClientUserId(newtarget));
							}
							PrintHintTextToAll("请注意，Tank被卡住了开始传送到生还者附近.");
							successTeleport = true;
							return;
						}
					}
				}
			}else{
				#if (DEBUG_ALL)
					PrintToConsoleAll("Tank没找到位置复活.");
				#endif
			}
		}
}

public void Event_TankSpawn(Event hEvent, const char[] name, bool dontBroadcast) 
{
	if (!g_bEnabled) return;
	
	static int client;
	client = GetClientOfUserId(hEvent.GetInt("userid"));
	BeginTankTracing(client);
	BeginRusherTracing();		
}
public void Event_PlayerDeath(Event hEvent, const char[] name, bool dontBroadcast) 
{
	if (!g_bEnabled) return;
	
	static int client;
	client = GetClientOfUserId(hEvent.GetInt("userid"));
	
	if (client != 0) {
		if (IsTank(client)) {
			CreateTimer(1.0, Timer_UpdateTankCount, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		else {
			if (GetClientTeam(client) == 2) {
				ResetClientStat(client);
			}
		}
	}
	successTeleport = true;
}
void ResetClientStat(int client)
{
	g_pos[client][0] = 0.0;
	g_pos[client][1] = 0.0;
	g_pos[client][2] = 0.0;
	g_iRushTimes[client] = 0;
}
public Action Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast) 
{
	return Plugin_Continue;
}
public Action Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast) 
{
	return Plugin_Continue;
}
public void Event_PlayerDisconnect(Event hEvent, const char[] name, bool dontBroadcast) 
{
	ResetClientStat(GetClientOfUserId(hEvent.GetInt("userid")));
}
public Action Timer_UpdateTankCount(Handle timer) {
	UpdateTankCount();
	return Plugin_Continue;
}

void UpdateTankCount() {
	static int cnt;
	cnt = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsTank(i))
			cnt++;
	
	g_iTanksCount = cnt;
	
	if (cnt == 0) {
		if (g_hTimerRusher != null) {
			delete g_hTimerRusher;
			g_hTimerRusher = null;
		}
	}
}
void BeginRusherTracing(bool bResetStat = true)
{
	if (g_hCvarRusherPunish.BoolValue) {
		
		if (bResetStat) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsFakeClient(i)) {
					GetClientAbsOrigin(i, g_pos[i]);
					g_iRushTimes[i] = 0;
				}
			}
		}
		if (g_hCvarRusherPunish.BoolValue) {
			if (g_hTimerRusher == null)
				g_hTimerRusher = CreateTimer(g_hCvarRusherCheckInterv.FloatValue, Timer_CheckRusher, _, TIMER_REPEAT);
		}
	}
}
public Action Timer_CheckRusher(Handle timer) {
	#if (DEBUG_ALL)
		PrintToConsoleAll("检测是否有跑男");
	#endif
	static float pos[3], postank[3], distance;
	static int tank, i;
	
	if (g_iTanksCount == 1)
		return Plugin_Continue;
	
	if(L4D_IsMissionFinalMap())
		return Plugin_Stop;
	
	
	for (i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsFakeClient(i) && IsPlayerAlive(i))
		{
			GetClientAbsOrigin(i, pos);
			if (L4D_IsPlayerIncapacitated(i)||L4D_IsPlayerPinned(i)) {
				break;
			}
			
			if (GetSurvivorCountAlive() >= g_hCvarRusherMinPlayers.IntValue) {
				
				tank = GetNearestTank(i);
				
				if (tank != 0) {
					GetClientAbsOrigin(tank, postank);
				
					distance = GetVectorDistance(pos, postank, false);
					//增加限制条件，tank的路程图不能在生还者前面，否则会碰到刷tank后生还者距离过远，直接传送到生还者附近
					if (distance > g_hCvarRusherDist.FloatValue) {
						
						if (g_iRushTimes[i] >= g_hCvarRusherCheckTimes.IntValue) {
							#if (DEBUG_ALL)
								PrintToConsoleAll("tank与\x03%N的距离为：%f，坦克的路程为:%f，生还者的路程为:%f",distance,L4D2Direct_GetFlowDistance(tank),L4D2Direct_GetFlowDistance(i));
							#endif
							TeleportToSurvivorInPlace(tank, i);
							PrintToChatAll("\x03%N \x04 因为当求生跑男，Tank开始传送惩罚.", i);
														
							g_iRushTimes[i] = 0;
						}
						else {
							Address nav = L4D_GetLastKnownArea(i);
							if(L4D2Direct_GetFlowDistance(tank)!= 0.0 && L4D2Direct_GetFlowDistance(i)!=0.0&& L4D2Direct_GetFlowDistance(tank)<L4D2Direct_GetFlowDistance(i) && !L4D_IsMissionFinalMap() && !(L4D_GetNavArea_SpawnAttributes(nav) & CHECKPOINT) && !IsAllSurAheadTankFlow(tank))
								g_iRushTimes[i]++;
						}
					}
					else {
						g_iRushTimes[i] = 0;
					}
				}
			}
		}
	}
	return Plugin_Continue;
}

bool IsAllSurAheadTankFlow(int tank){
	//bool flag = false;
	for(int i = 1; i <= MaxClients; i++){
		if(IsValidSurvivor(i)){
			//没有获取到任何一方的flow时，返回false
			if(L4D2Direct_GetFlowDistance(i) < L4D2Direct_GetFlowDistance(tank) || L4D2Direct_GetFlowDistance(i) == 0.0 || L4D2Direct_GetFlowDistance(tank) == 0.0)
				return false;				
		}
	}
	return true;
}

int GetNearestTank(int client) {
	static float tpos[3], spos[3], dist, mindist;
	static int iNearClient;
	iNearClient = 0;
	mindist = 0.0;
	GetClientAbsOrigin(client, tpos);
	
	for (int i = 1; i <= MaxClients; i++) {
		if (i != client && IsTank(i)) {
			GetClientAbsOrigin(i, spos);
			dist = GetVectorDistance(tpos, spos, false);
			if (dist < mindist || mindist < 0.1) {
				mindist = dist;
				iNearClient = i;
			}
		}
	}
	return iNearClient;
}
int GetSurvivorCountAlive() {
	static int cnt, i;
	cnt = 0;
	for (i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
			cnt++;
	}
	return cnt;
}
void TeleportToSurvivorInPlace(int client, int survivor) {
	
	static float pos[3];
	GetClientAbsOrigin(survivor, pos);
	pos[0] += 10.0;
	pos[1] += 5.0;
	pos[2] += 5.0;
	
	TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
}
stock bool IsTank(int client)
{
	if( client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == 3 )
	{
		int class = GetEntProp(client, Prop_Send, "m_zombieClass");
		if( class == 8)
			return true;
	}
	return false;
}

public void OnMapStart() {
	static int i;
	g_hTimerRusher = null;
	for (i = 1; i < MaxClients; i++)
		g_iTimes[i] = 0;
	successTeleport = true;
}
public void OnMapEnd() {
	g_iTanksCount = 0;
}

public Action Timer_CheckPos(Handle timer, int UserId)
{
	#if (DEBUG_ALL)
		PrintToConsoleAll("开始检查tank是否卡住");
	#endif
	static int tank;
	tank = GetClientOfUserId(UserId);
	if (tank != 0 && IsClientInGame(tank) && IsPlayerAlive(tank)) {
		
		static float pos[3];
		GetClientAbsOrigin(tank, pos);
		
		static float distance;
		distance = GetVectorDistance(pos, g_pos[tank], false);
		#if (DEBUG_ALL)
			PrintToConsoleAll("tank目前位置和前位置相差:%f",distance);
		#endif
		if (distance < g_hCvarNonStuckRadius.FloatValue && !IsIncappedNearBy(pos) && !IsTankAttacking(tank)) {
			
			if ( g_iStuckTimes[tank] > 6 && successTeleport) {
				SDKHook(tank, SDKHook_PostThinkPost, SDK_UpdateThink);
				successTeleport = false;
			}
			g_iStuckTimes[tank]++;
		#if (DEBUG_ALL)
			PrintToConsoleAll("tank检测卡住次数:%d",g_iStuckTimes[tank]);
		#endif
		}
		else {
			g_iStuckTimes[tank] = 0;
		}
		
		g_pos[tank] = pos;
	}
	else
		return Plugin_Stop;
	
	return Plugin_Continue;
}
bool IsTankAttacking(int tank)
{
	return GetEntProp(tank, Prop_Send, "m_fireLayerSequence") > 0;
}
bool IsIncappedNearBy(float vOrigin[3])
{
	static int i;
	static float vOriginPlayer[3];
	
	for (i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i) && IsIncapped(i))
		{
			GetClientAbsOrigin(i, vOriginPlayer);
			if (GetVectorDistance(vOriginPlayer, vOrigin) <= g_fTankClawRange)
				return true;
		}
	}
	return false;
}


stock bool IsIncapped(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) == 1;
}

