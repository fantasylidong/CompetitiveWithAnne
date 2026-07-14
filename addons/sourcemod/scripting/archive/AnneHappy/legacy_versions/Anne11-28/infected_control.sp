#pragma semicolon 1
#pragma newdecls required
#define DEBUG 0
// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#undef REQUIRE_PLUGIN
#include <ai_smoker_new>
#include <si_target_limit>


#define CVAR_FLAG FCVAR_NOTIFY
#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
// 特感种类
#define ZC_SPITTER 4
#define ZC_TANK 8
// 数据
#define NAV_MESH_HEIGHT 20.0
#define PLAYER_HEIGHT 72.0
#define PLAYER_CHEST 45.0

// 启用特感类型
#define ENABLE_SMOKER			(1 << 0)		
#define ENABLE_BOOMER			(1 << 1)		
#define ENABLE_HUNTER			(1 << 2)		
#define ENABLE_SPITTER			(1 << 3)		
#define ENABLE_JOCKEY			(1 << 4)		
#define ENABLE_CHARGER			(1 << 5)	

// Spitter吐口水之后能传送的时间
#define SPIT_INTERVAL 2.0


stock const char InfectedName[10][] =
{
	"common",
	"smoker",
	"boomer",
	"hunter",
	"spitter",
	"jockey",
	"charger",
	"witch",
	"tank",
	"survivor"
};


#if (DEBUG)
char sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control.txt";
#endif
// 插件基本信息，根据 GPL 许可证条款，需要修改插件请勿修改此信息！
public Plugin myinfo = 
{
	name 			= "Direct InfectedSpawn",
	author 			= "Caibiii, 夜羽真白，东",
	description 	= "特感刷新控制，传送落后特感",
	version 		= "2022.11.01",
	url 			= "https://github.com/fantasylidong/CompetitiveWithAnne"
}

// Cvars
ConVar 
	g_hSpawnDistanceMin, 
	g_hSpawnDistanceMax, 
	g_hTeleportSi, 
	g_hTeleportDistance, 
	g_hSiLimit, 
	g_hSiInterval, 
	g_hMaxPlayerZombies, 
	g_hTeleportCheckTime, 
	g_hEnableSIoption, 
	g_hAllChargerMode,
	g_hAddDamageToSmoker,
	g_hIgnoreIncappedSurvivorSight, 
	g_hVsBossFlowBuffer,
	g_hAllHunterMode;

// Ints
int 
	g_iSiLimit, 						//特感数量
	g_iRushManIndex,					//跑男id
	g_iWaveTime, 						//Debug时输出这是第几波刷特
	g_iTotalSINum = 0,					//总共还活着的特感
	g_iEnableSIoption = 63,				//可生成的特感种类
	g_iTeleportCheckTime = 5,   		//特感传送要求的不被看到的次数(1s检查一次)
	g_iSINum[6] = {0},					//记录当前还存活的特感数量
	g_ArraySIlimit[6] = {0}, 			//记录去除队列里特感数量后还能生成的特感
	g_iTeleCount[MAXPLAYERS + 1] = {0}, //每个特感传送的不被看到次数
	g_iTargetSurvivor = -1, 			//OnGameFrame参数里，以该目标生成生成网络，寻找生成目标
	g_iQueueIndex = 0,					//当前生成队列长度
	g_iTeleportIndex = 0,				//当前传送队列长度
	g_iSpawnMaxCount = 0, 				//当前可生成特感数量
	g_iSurvivorNum = 0, 				//活着的生还者数量
	g_iSurvivors[MAXPLAYERS + 1] = {0}; //活着生还者的索引

// Floats
float 
	g_fSpitterSpitTime[MAXPLAYERS + 1], //Spitter吐口水时间
	g_fSpawnDistanceMin, 				//特感的最小生成距离
	g_fSpawnDistanceMax, 				//特感的最大生成距离
	g_fSpawnDistance, 					//特感的当前生成距离
	g_fTeleportDistanceMin, 			//特感传送距离生还的最小距离
	g_fTeleportDistance,				//特感当前传送生成距离
	g_fSiInterval;						//特感的生成时间间隔
// Bools
bool 
	g_bTeleportSi, 						//是否开启特感传送检测
	g_bPickRushMan,						//是否针对跑男
	g_bAddDamageToSmoker,				//是否对smoker增伤（一般alone模式开启）
	g_bIgnoreIncappedSurvivorSight,		//是否忽略倒地生还者的视线
	g_bIsLate = false, 					//text插件是否发送开启刷特命令
	g_bSmokerAvailable = false,			//ai_smoker_new是否存在
	g_bTargetSystemAvailable = false;	//目标选择插件是否存在
// Handle
Handle 
	g_hTeleHandle = INVALID_HANDLE, 	//传送sdk Handle
	g_hRushManNotifyForward = INVALID_HANDLE; //检测到跑男提醒Target_limit插件放开单人目标限制
// ArrayList
ArrayList 
	aThreadHandle, 						//刷特线程
	aTeleportQueue,						//传送队列
	aSpawnQueue;						//刷特队列

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
	RegPluginLibrary("infected_control");
	g_hRushManNotifyForward = CreateGlobalForward("OnDetectRushman", ET_Ignore, Param_Cell);
	return APLRes_Success;
}

public void OnAllPluginsLoaded(){
	g_bTargetSystemAvailable = LibraryExists("si_target_limit");
	g_bSmokerAvailable = LibraryExists("ai_smoker_new");
}
public void OnLibraryAdded(const char[] name)
{
    if ( StrEqual(name, "si_target_limit") ) { g_bTargetSystemAvailable = true; }
	else if( StrEqual(name, "ai_smoker_new") ) { g_bSmokerAvailable = true; }
}
public void OnLibraryRemoved(const char[] name)
{
    if ( StrEqual(name, "si_target_limit") ) { g_bTargetSystemAvailable = false; }
	else if( StrEqual(name, "ai_smoker_new") ) { g_bSmokerAvailable = false; }
}
public void OnPluginStart()
{
	// CreateConVar
	g_hSpawnDistanceMin = CreateConVar("inf_SpawnDistanceMin", "250.0", "特感复活离生还者最近的距离限制", CVAR_FLAG, true, 0.0);
	g_hSpawnDistanceMax = CreateConVar("inf_SpawnDistanceMax", "1500.0", "特感复活离生还者最远的距离限制", CVAR_FLAG, true, g_hSpawnDistanceMin.FloatValue);
	g_hTeleportSi = CreateConVar("inf_TeleportSi", "1", "是否开启特感距离生还者一定距离将其传送至生还者周围", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hTeleportCheckTime = CreateConVar("inf_TeleportCheckTime", "5", "特感几秒后没被看到开始传送", CVAR_FLAG, true, 0.0);
	g_hEnableSIoption = CreateConVar("inf_EnableSIoption", "63", "启用生成的特感类型，1 smoker 2 boomer 4 hunter 8 spitter 16 jockey 32 charger,把你想要生成的特感值加起来", CVAR_FLAG, true, 0.0, true, 63.0);
	g_hAllChargerMode = CreateConVar("inf_AllChargerMode", "0", "是否是全牛模式", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAllHunterMode = CreateConVar("inf_AllHunterMode", "0", "是否是全猎人模式", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hIgnoreIncappedSurvivorSight = CreateConVar("inf_IgnoreIncappedSurvivorSight", "1", "特感传送检测是否被看到的时候是否忽略倒地生还者视线", CVAR_FLAG, true, 0.0, true, 1.0);
	g_hAddDamageToSmoker= CreateConVar("inf_AddDamageToSmoker", "0", "单人模式smoker拉人时是否5倍伤害", CVAR_FLAG, true, 0.0, true, 1.0);
	//传送会根据这个数值画一个以选定生还者为核心，两边各长inf_TeleportDistance单位距离，高inf_TeleportDistance距离的长方形区域内找复活位置,PS传送最好近一点
	g_hTeleportDistance = CreateConVar("inf_TeleportDistance", "600.0", "特感传送区域的最小复活大小", CVAR_FLAG, true, g_hSpawnDistanceMin.FloatValue);
	g_hSiLimit = CreateConVar("l4d_infected_limit", "6", "一次刷出多少特感", CVAR_FLAG, true, 0.0);
	g_hSiInterval = CreateConVar("versus_special_respawn_interval", "16.0", "对抗模式下刷特时间控制", CVAR_FLAG, true, 0.0);
	g_hMaxPlayerZombies = FindConVar("z_max_player_zombies");
	g_hVsBossFlowBuffer = FindConVar("versus_boss_buffer");
	SetConVarInt(FindConVar("director_no_specials"), 1);
	// HookEvents
	HookEvent("player_death", evt_PlayerDeath, EventHookMode_PostNoCopy);
	HookEvent("round_start", evt_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("finale_win", evt_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("map_transition", evt_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("mission_lost", evt_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_hurt", evt_PlayerHurt, EventHookMode_PostNoCopy);
	HookEvent("ability_use", evt_GetSpitTime, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", evt_PlayerSpawn, EventHookMode_PostNoCopy);
	// AddChangeHook
	g_hSpawnDistanceMax.AddChangeHook(ConVarChanged_Cvars);
	g_hSpawnDistanceMin.AddChangeHook(ConVarChanged_Cvars);
	g_hTeleportSi.AddChangeHook(ConVarChanged_Cvars);
	g_hTeleportCheckTime.AddChangeHook(ConVarChanged_Cvars);
	g_hTeleportDistance.AddChangeHook(ConVarChanged_Cvars);
	g_hSiInterval.AddChangeHook(ConVarChanged_Cvars);
	g_hIgnoreIncappedSurvivorSight.AddChangeHook(ConVarChanged_Cvars);
	g_hEnableSIoption.AddChangeHook(ConVarChanged_Cvars);
	g_hAllChargerMode.AddChangeHook(ConVarChanged_Cvars);
	g_hAllHunterMode.AddChangeHook(ConVarChanged_Cvars);
	g_hAddDamageToSmoker.AddChangeHook(ConVarChanged_Cvars);
	g_hSiLimit.AddChangeHook(MaxPlayerZombiesChanged_Cvars);
	
	// ArrayList
	aThreadHandle = new ArrayList();
	aSpawnQueue = new ArrayList();
	aTeleportQueue = new ArrayList();
	// GetCvars
	GetCvars();
	GetSiLimit();
	// SetConVarBonus
	SetConVarBounds(g_hMaxPlayerZombies, ConVarBound_Upper, true, g_hSiLimit.FloatValue);
	// Debug
	RegAdminCmd("sm_startspawn", Cmd_StartSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
	RegAdminCmd("sm_stopspawn", Cmd_StopSpawn, ADMFLAG_ROOT, "管理员重置刷特时钟");
}

public void OnPluginEnd() {
	if(g_hAllChargerMode.BoolValue){
		FindConVar("z_charger_health").RestoreDefault();
		FindConVar("z_charge_max_speed").RestoreDefault();
		FindConVar("z_charge_start_speed").RestoreDefault();
		FindConVar("z_charger_pound_dmg").RestoreDefault();
		FindConVar("z_charge_max_damage").RestoreDefault();
		FindConVar("z_charge_interval").RestoreDefault();
	}
}

void TweakSettings() {
	if(g_hAllChargerMode.BoolValue){
		FindConVar("z_charger_health").SetFloat(500.0);
		FindConVar("z_charge_max_speed").SetFloat(750.0);
		FindConVar("z_charge_start_speed").SetFloat(350.0);
		FindConVar("z_charger_pound_dmg").SetFloat(10.0);
		FindConVar("z_charge_max_damage").SetFloat(6.0);
		FindConVar("z_charge_interval").SetFloat(2.0);
	}
}

// 向量绘制
// #include "vector/vector_show.sp"

stock Action Cmd_StartSpawn(int client, int args)
{
	if (L4D_HasAnySurvivorLeftSafeArea())
	{
		ResetStatus();
		CreateTimer(0.1, SpawnFirstInfected);
		GetSiLimit();
		TweakSettings();
	}
	return Plugin_Handled;
}

stock Action Cmd_StopSpawn(int client, int args)
{
	StopSpawn();
	return Plugin_Handled;
}

// *********************
//		获取Cvar值
// *********************
void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void MaxPlayerZombiesChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iSiLimit = g_hSiLimit.IntValue;
	CreateTimer(0.1, MaxSpecialsSet);
}

void GetCvars()
{
	g_fSpawnDistanceMax = g_hSpawnDistanceMax.FloatValue;
	g_fSpawnDistanceMin = g_hSpawnDistanceMin.FloatValue;
	g_bTeleportSi = g_hTeleportSi.BoolValue;
	g_fTeleportDistanceMin = g_hTeleportDistance.FloatValue;
	g_fSiInterval = g_hSiInterval.FloatValue;
	g_iSiLimit = g_hSiLimit.IntValue;
	g_iTeleportCheckTime = g_hTeleportCheckTime.IntValue;
	g_iEnableSIoption = g_hEnableSIoption.IntValue;
	g_bAddDamageToSmoker = g_hAddDamageToSmoker.BoolValue;
	g_bIgnoreIncappedSurvivorSight = g_hIgnoreIncappedSurvivorSight.BoolValue;
	if(g_hAllChargerMode.BoolValue){
		TweakSettings();
	}
}

public Action MaxSpecialsSet(Handle timer)
{
	SetConVarBounds(g_hMaxPlayerZombies, ConVarBound_Upper, true, g_hSiLimit.FloatValue);
	g_hMaxPlayerZombies.IntValue = g_iSiLimit;
	return Plugin_Continue;
}

// *********************
//		    事件
// *********************
//Spitter出生重置能力
public void evt_PlayerSpawn(Event event, const char[] name, bool dont_broadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(IsSpitter(client))
	{
		g_fSpitterSpitTime[client] = GetGameTime();
	}
}

//获取spitter口水时间
public void evt_GetSpitTime(Event event, const char[] name, bool dont_broadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client) || !IsFakeClient(client))
		return;

	static char ability[16];
	event.GetString("ability", ability, sizeof ability);
	if (strcmp(ability, "ability_spit") == 0)
	{
		g_fSpitterSpitTime[client] = GetGameTime();
	}
}

/* 玩家受伤,增加对smoker得伤害 */
public void evt_PlayerHurt(Event event, const char[] name, bool dont_broadcast)
{
	if(g_bAddDamageToSmoker){
		int victim = GetClientOfUserId(GetEventInt(event, "userid"));
		int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
		int damage = GetEventInt(event, "dmg_health");
		int eventhealth = GetEventInt(event, "health");
		int AddDamage = 0;
		if (IsValidSurvivor(attacker) && IsInfectedBot(victim) && GetEntProp(victim, Prop_Send, "m_zombieClass") == 1)
		{
			if( GetEntPropEnt(victim, Prop_Send, "m_tongueVictim") > 0 )
			{
				AddDamage = damage * 5;
			}
			int health = eventhealth - AddDamage;
			if (health < 1)
			{
				health = 0;
			}
			SetEntityHealth(victim, health);
			SetEventInt(event, "health", health);
		}
	}
}

public void InitStatus(){
	if (g_hTeleHandle != INVALID_HANDLE)
	{
		delete g_hTeleHandle;
		g_hTeleHandle = INVALID_HANDLE;
	}
	g_bPickRushMan = false;
	g_bIsLate = false;
	g_iSpawnMaxCount = 0;
	// 从 ArrayList 末端往前判断删除时钟，如果从前往后，因为 ArrayList 会通过前移后面的索引来填补前面擦除的空位，导致有时钟句柄无法擦除
	for (int hTimerHandle = aThreadHandle.Length - 1; hTimerHandle >= 0; hTimerHandle--)
	{
		KillTimer(aThreadHandle.Get(hTimerHandle));
		aThreadHandle.Erase(hTimerHandle);
	}
	aThreadHandle.Clear();
	aSpawnQueue.Clear();
	aTeleportQueue.Clear();
	g_iQueueIndex = 0;
	g_iTeleportIndex = 0;
	g_iWaveTime=0;
	for(int i = 0; i <= MAXPLAYERS; i++)
	{
		g_fSpitterSpitTime[i] = 0.0;
	}
	for(int i = 0; i < 6; i++){
		g_iSINum[i] =0;
	}
}

public void StopSpawn(){
	InitStatus();
}

public void evt_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	InitStatus();
	CreateTimer(0.1, MaxSpecialsSet);
	CreateTimer(3.0, SafeRoomReset, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void evt_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	InitStatus();
}

public void evt_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsInfectedBot(client))
	{
		int type = GetEntProp(client, Prop_Send, "m_zombieClass");
		//防止无声口水
		if (type != ZC_SPITTER)
		{
			CreateTimer(0.5, Timer_KickBot, client);
		}
		if(type >= 1 && type <=6){
			if(g_iSINum[type - 1] > 0)
			{
				g_iSINum[type - 1] --;
			}
			else
			{
				g_iSINum[type - 1] = 0;
			}
			if(g_iTotalSINum > 0)
			{
				g_iTotalSINum --;
			}
			else
			{
				g_iTotalSINum = 0;
			}
		}
		g_iTeleCount[client] = 0;
	}	
}

public Action Timer_KickBot(Handle timer, int client)
{
	if (IsClientInGame(client) && !IsClientInKickQueue(client) && IsFakeClient(client))
	{
		//Debug_Print("踢出特感%N",client);
		KickClient(client, "You are worthless and was kicked by console");
	}
	return Plugin_Continue;
}

// *********************
//		  功能部分
// *********************
public void OnGameFrame()
{
	// 根据情况动态调整 z_maxplayers_zombie 数值
	if (g_iSiLimit > g_hMaxPlayerZombies.IntValue)
	{
		CreateTimer(0.1, MaxSpecialsSet);
	}
	if (g_iTeleportIndex <= 0 && g_iQueueIndex < g_iSiLimit)
	{
		int zombieclass = 0;
		if(g_hAllChargerMode.BoolValue){
			zombieclass =  6;
		}
		else if(g_hAllHunterMode.BoolValue){
			zombieclass =  3;
		}else{
			zombieclass = GetRandomInt(1,6);
		}		
		if (zombieclass != 0 && MeetRequire(zombieclass) && !HasReachedLimit(zombieclass) && g_iQueueIndex < g_iSiLimit)
		{
			//这里增加一些boomer和spitter生成的判定，让bommer和spitter比较晚生成
			aSpawnQueue.Push(g_iQueueIndex);
			aSpawnQueue.Set(g_iQueueIndex, zombieclass, 0, false);
			g_ArraySIlimit[zombieclass - 1] -= 1;
			g_iQueueIndex += 1;
			Debug_Print("<刷特队列> 当前入队特感：%s，当前队列长度：%d，当前队列索引位置：%d", InfectedName[zombieclass], aSpawnQueue.Length, g_iQueueIndex);
		}
	}
	if (g_bIsLate)
	{
		if (g_iSiLimit > g_iTotalSINum)
		{
			if(g_iTeleportIndex > 0)
			{
				g_iTargetSurvivor = GetTargetSurvivor();
				if(g_fTeleportDistance < g_fSpawnDistanceMax)
				{
					g_fTeleportDistance += 10.0;
				}
				float fSpawnPos[3] = {0.0};
				if(GetSpawnPos(fSpawnPos, g_iTargetSurvivor, g_fTeleportDistance, true))	
				{
					int iZombieClass = aTeleportQueue.Get(0);
					if(!(iZombieClass >= 1 && iZombieClass <= 6))
					{
						Debug_Print("特感类型读取错误，读取的特感类型为：%d", iZombieClass);
						aTeleportQueue.Erase(0);
						g_iTeleportIndex -= 1;
						return;
					}
					if(SpawnInfected(fSpawnPos, g_fTeleportDistance, iZombieClass, true)){
						g_iSINum[iZombieClass - 1] += 1;
						g_iTotalSINum += 1;
						if (aTeleportQueue.Length > 0 && g_iTeleportIndex > 0)
						{
							aTeleportQueue.Erase(0);
							g_iTeleportIndex -= 1;
						}
						print_type(iZombieClass, g_fSpawnDistance, true);
					}
					else
					{
						if (g_iTeleportIndex <= 0)
						{
							aTeleportQueue.Clear();
							g_iTeleportIndex = 0;
						}
					}
				}
			}
			//传送队列优先处理，防止普通刷特刷出来把特感数量刷满了
			if(g_iSpawnMaxCount > 0 && g_iTeleportIndex <= 0 && g_iQueueIndex > 0)
			{
				g_iTargetSurvivor = GetTargetSurvivor();
				if(g_fSpawnDistance < g_fSpawnDistanceMax)
				{
					g_fSpawnDistance += 5.0;
				}
				float fSpawnPos[3] = {0.0};
				if(GetSpawnPos(fSpawnPos, g_iTargetSurvivor, g_fSpawnDistance))	{
					int iZombieClass = aSpawnQueue.Get(0);
					if(SpawnInfected(fSpawnPos, g_fSpawnDistance, iZombieClass)){
						g_iSpawnMaxCount -= 1;
						g_iSINum[iZombieClass - 1] += 1;
						g_iTotalSINum += 1;
						if (aSpawnQueue.Length > 0 && g_iQueueIndex > 0)
						{
							aSpawnQueue.Erase(0);
							g_iQueueIndex -= 1;
						}
						print_type(iZombieClass, g_fSpawnDistance);
					}
					else
					{
						if (HasReachedLimit(iZombieClass))
						{
							ReachedLimit(iZombieClass);
						}
						if (g_iQueueIndex <= 0)
						{
							aSpawnQueue.Clear();
							g_iQueueIndex = 0;
						}
					}
				}
			}					
		}
	}
}

stock bool GetSpawnPos(float fSpawnPos[3], int g_iTargetSurvivor, float SpawnDistance, bool IsTeleport = false){
	if(IsValidClient(g_iTargetSurvivor)){
		float fSurvivorPos[3] = {0.0}, fDirection[3] = {0.0}, fEndPos[3] = {0.0}, fMins[3] = {0.0}, fMaxs[3] = {0.0};	
		// 根据指定生还者坐标，拓展刷新范围
		GetClientEyePosition(g_iTargetSurvivor, fSurvivorPos);
		//增加高度，增加刷房顶的几率
		if(SpawnDistance < 500.0)
		{
			fMaxs[2] = fSurvivorPos[2] + 800.0;
		}
		else
		{
			fMaxs[2] = fSurvivorPos[2] + SpawnDistance + 300.0;
		}
		fMins[0] = fSurvivorPos[0] - SpawnDistance;
		fMaxs[0] = fSurvivorPos[0] + SpawnDistance;
		fMins[1] = fSurvivorPos[1] - SpawnDistance;
		fMaxs[1] = fSurvivorPos[1] + SpawnDistance;
		fMaxs[2] = fSurvivorPos[2] + SpawnDistance;
		// 规定射线方向
		fDirection[0] = 90.0;
		fDirection[1] = fDirection[2] = 0.0;
		// 随机刷新位置
		fSpawnPos[0] = GetRandomFloat(fMins[0], fMaxs[0]);
		fSpawnPos[1] = GetRandomFloat(fMins[1], fMaxs[1]);
		fSpawnPos[2] = GetRandomFloat(fSurvivorPos[2], fMaxs[2]);
		// 找位条件，可视，是否在有效 NavMesh，是否卡住，否则先会判断是否在有效 Mesh 与是否卡住导致某些位置刷不出特感
		int count2=0;
		//生成的时候只能在有跑男情况下才特意生成到幸存者前方
		while (PlayerVisibleToSDK(fSpawnPos, IsTeleport) || !IsOnValidMesh(fSpawnPos) || IsPlayerStuck(fSpawnPos) || ((g_bPickRushMan || IsTeleport) && !Is_Pos_Ahead(fSpawnPos, g_iTargetSurvivor)))
		{
			count2++;
			if(count2 > 30)
			{
				return false;
			}
			fSpawnPos[0] = GetRandomFloat(fMins[0], fMaxs[0]);
			fSpawnPos[1] = GetRandomFloat(fMins[1], fMaxs[1]);
			fSpawnPos[2] = GetRandomFloat(fSurvivorPos[2], fMaxs[2]);
			TR_TraceRay(fSpawnPos, fDirection, MASK_PLAYERSOLID, RayType_Infinite);
			if(TR_DidHit())
			{
				TR_GetEndPosition(fEndPos);
				fSpawnPos = fEndPos;
				fSpawnPos[2] += NAV_MESH_HEIGHT;
			}
		}
		return true;
	}
	return false;
}

stock bool SpawnInfected(float fSpawnPos[3], float SpawnDistance, int iZombieClass, bool IsTeleport = false)
{

	float fSurvivorPos[3];
	//Debug_Print("生还者看不到");
	// 生还数量为 4，循环 4 次，检测此位置到生还的距离是否小于 750 是则刷特，此处可以刷新 1 ~ g_iSiLimit 只特感，如果此处刷完，则上面的 SpawnSpecial 将不再刷特
	for (int count = 0; count < g_iSurvivorNum; count++)
	{
		int index = g_iSurvivors[count];
		//不是有效生还者不生成
		if(!IsValidSurvivor(index))
			continue;	

		//生还者倒地或者挂边，也不生成
		if(IsClientIncapped(index)){
			continue;	
		}
		//非跑男模式目标已满，跳过
		if(g_bTargetSystemAvailable && !g_bPickRushMan && IsClientReachLimit(index))
		{
			continue;
		}
		GetClientEyePosition(index, fSurvivorPos);
		fSurvivorPos[2] -= 60.0;
		//获取nav地址
		Address nav1 = L4D_GetNearestNavArea(fSpawnPos, 120.0, false, false, false, TEAM_INFECTED);
		Address nav2 = L4D_GetNearestNavArea(fSurvivorPos, 120.0, false, false, false, TEAM_INFECTED);
		//nav1 和 nav2 必须有网格相连的路，并且生成距离大于SpawnDistance，增加不能是通nav网格的要求
		if (L4D2_NavAreaBuildPath(nav1, nav2, SpawnDistance * 1.73, TEAM_INFECTED, false) && GetVectorDistance(fSurvivorPos, fSpawnPos) >= g_fSpawnDistanceMin && nav1 != nav2)
		{
			if (iZombieClass > 0 && !HasReachedLimit(iZombieClass) && CheckSIOption(iZombieClass))
			{
				if(IsTeleport && g_iTeleportIndex <= 0){
					return false;
				}
				if(!IsTeleport && g_iSpawnMaxCount <= 0){
					return false;
				}
				int entityindex = L4D2_SpawnSpecial(iZombieClass, fSpawnPos, view_as<float>({0.0, 0.0, 0.0}));
				if (IsValidEntity(entityindex) && IsValidEdict(entityindex))
				{
					return true;
				}
			}
		}
	}
	return false;
}

// 当前在场的某种特感种类数量达到 Cvar 限制，但因为刷新一个特感，出队此元素，之后再入队相同特感元素，则会刷不出来，需要处理重复情况，如果队列长度大于 1 且索引大于 0，说明队列存在
// 首非零元，直接擦除队首元素并令队列索引 -1 即可，时间复杂度为 O(1)，如果队列中只有一个元素，则循环 1-6 的特感种类替换此元素（一般不会出现），时间复杂度为 O(n)
// 如：当前存在 2 个 Smoker 未死亡，Smoker 的 Cvar 限制为 2 ，这时入队一个 Smoker 元素，则会导致无法刷出特感
void ReachedLimit(int type)
{
	if (aSpawnQueue.Length > 1 && g_iQueueIndex > 0)
	{
		Debug_Print("%s上限已到，无法生成，且队列不为空，删除第一个队列元素", InfectedName[type]);
		aSpawnQueue.Erase(0);
		g_iQueueIndex -= 1;
	}
	else
	{
		for (int i = 1; i <= 6; i++)
		{
			if (CheckSIOption(i) && !HasReachedLimit(i))
			{
				Debug_Print("%s上限已到，无法生成，当前队列为空，遍历1-6类型发现%s类型未满", InfectedName[type], InfectedName[i]);
				aSpawnQueue.Set(0, i, 0, false);
			}
		}
	}
}

public int CheckSIOption(int type){
    switch (type)
    {
        case 1:
        {
            return ENABLE_SMOKER & g_iEnableSIoption;
        }
        case 2:
        {
            return ENABLE_BOOMER & g_iEnableSIoption;
        }
        case 3:
        {
            return ENABLE_HUNTER & g_iEnableSIoption;
        }
        case 4:
        {
            return ENABLE_SPITTER & g_iEnableSIoption;
        }
        case 5:
        {
            return ENABLE_JOCKEY & g_iEnableSIoption;
        }
        case 6:
        {
            return ENABLE_CHARGER & g_iEnableSIoption;
        }
    }
    return 0;
}


// 当前某种特感数量是否达到 Convar 值限制
bool HasReachedLimit(int zombieclass)
{
	int count = 0;	char convar[16] = {'\0'};
	for (int infected = 1; infected <= MaxClients; infected++)
	{
		if (IsClientConnected(infected) && IsClientInGame(infected) && GetEntProp(infected, Prop_Send, "m_zombieClass") == zombieclass)
		{
			count += 1;
		}
	}
	if((g_hAllChargerMode.BoolValue || g_hAllHunterMode.BoolValue) && count == g_iSiLimit){
		return true;
	}
	else if((g_hAllChargerMode.BoolValue || g_hAllHunterMode.BoolValue) && count < g_iSiLimit){
		return false;
	}
	FormatEx(convar, sizeof(convar), "z_%s_limit", InfectedName[zombieclass]);
	if (count == GetConVarInt(FindConVar(convar)))
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock void print_type(int iType, float SpawnDistance, bool Isteleport = false){
	if (iType >= 1 && iType <=6)
	{
		Debug_Print(" %s生成一只%s，当前%s数量：%d,特感总数量 %d, 真实特感数量：%d, 找位最大单位距离：%f", Isteleport?"传送":"", InfectedName[iType], InfectedName[iType], g_iSINum[iType -1], g_iTotalSINum, GetCurrentSINum(), SpawnDistance);
	}
}

// 初始 & 动态刷特时钟
public Action SpawnFirstInfected(Handle timer)
{
	if (!g_bIsLate)
	{
		g_bIsLate = true;
		if (g_hSiInterval.FloatValue > 9.0)
		{
			Handle aSpawnTimer = CreateTimer(g_fSiInterval + 8.0, SpawnNewInfected, _, TIMER_REPEAT);
			aThreadHandle.Push(aSpawnTimer);
			TriggerTimer(aSpawnTimer, true);
		}
		else
		{
			Handle aSpawnTimer = CreateTimer(g_fSiInterval + 4.0, SpawnNewInfected, _, TIMER_REPEAT);
			aThreadHandle.Push(aSpawnTimer);
			TriggerTimer(aSpawnTimer, true);
		}
		if (g_bTeleportSi)
		{
			g_hTeleHandle = CreateTimer(1.0, Timer_PositionSi, _, TIMER_REPEAT);
		}
	}
	return Plugin_Continue;
}


public Action SpawnNewInfected(Handle timer)
{
	
	g_iSurvivorNum = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidSurvivor(client) && IsPlayerAlive(client))
		{
			g_iSurvivors[g_iSurvivorNum] = client;
			g_iSurvivorNum += 1;
		}
	}
	if (g_bIsLate)
	{
		if (g_iSiLimit > aThreadHandle.Length)
		{
			if (g_hSiInterval.FloatValue > 9.0)
			{
				Handle aSpawnTimer = CreateTimer(g_fSiInterval + 8.0, SpawnNewInfected, _, TIMER_REPEAT);
				aThreadHandle.Push(aSpawnTimer);
				TriggerTimer(aSpawnTimer, true);
			}
			else
			{
				Handle aSpawnTimer = CreateTimer(g_fSiInterval + 4.0, SpawnNewInfected, _, TIMER_REPEAT);
				aThreadHandle.Push(aSpawnTimer);
				TriggerTimer(aSpawnTimer, true);
			}
		}
		// 其实这个删除没什么用，因为当 aThreadHandle.Length = g_iSiLimit 时，多出来的句柄将不会存入数组
		else if (g_iSiLimit < aThreadHandle.Length)
		{
			for (int iTimerIndex = 0; iTimerIndex < aThreadHandle.Length; iTimerIndex++)
			{
				if (timer == aThreadHandle.Get(iTimerIndex))
				{
					aThreadHandle.Erase(iTimerIndex);
					return Plugin_Stop;
				}
			}
		}
		g_fSpawnDistance = g_fSpawnDistanceMin;

		g_iSpawnMaxCount += 1;
		if (g_iSiLimit == g_iSpawnMaxCount){
			g_iWaveTime++;
			Debug_Print("开始第%d波刷特", g_iWaveTime);
		}
			
		// 当一定时间内刷不出特感，触发时钟使 g_iSpawnMaxCount 超过 g_iSiLimit 值时，最多允许刷出 g_iSiLimit + 2 只特感，防止连续刷 2-3 波的情况
		if (g_iSiLimit < g_iSpawnMaxCount)
		{

			g_iSpawnMaxCount = g_iSiLimit;
			
			Debug_Print("当前特感数量达到上限");
		}

	}
	return Plugin_Continue;
}

// 开局重置特感状态
public Action SafeRoomReset(Handle timer)
{
	ResetStatus();
	return Plugin_Continue;
}

public void ResetStatus(){
	g_iTotalSINum = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsInfectedBot(client) && IsPlayerAlive(client))
		{
			g_iTeleCount[client] = 0;
			int type = GetEntProp(client, Prop_Send, "m_zombieClass");
			g_iSINum[type - 1] += 1;
			g_iTotalSINum += 1;
		}
		if (IsValidSurvivor(client) && !IsPlayerAlive(client))
		{
			L4D_RespawnPlayer(client);
		}
	}
}

// *********************
//		   方法
// *********************stock bool IsAiSmoker(int client)
bool IsInfectedBot(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED && GetEntProp(client, Prop_Send, "m_zombieClass") != 8)
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool IsOnValidMesh(float fReferencePos[3])
{
	Address pNavArea = L4D2Direct_GetTerrorNavArea(fReferencePos);
	if (pNavArea != Address_Null)
	{
		return true;
	}
	else
	{
		return false;
	}
}

//判断该坐标是否可以看到生还或者距离小于g_fSpawnDistanceMin码，减少一层栈函数，增加实时性,单人模式增加2条射线模仿左右眼
stock bool PlayerVisibleTo(float targetposition[3], bool IsTeleport = false)
{
	float position[3], vAngles[3], vLookAt[3], spawnPos[3];
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && IsValidSurvivor(client) && IsPlayerAlive(client))
		{
			//传送的时候无视倒地或者挂边生还者的视线，检测到跑男时，也不关注被控生还者的视线
			if(IsTeleport && (IsClientIncapped(client) || (g_bPickRushMan && IsPinned(client)))){
				if(!g_bIgnoreIncappedSurvivorSight){
					int sum = 0;
					float temp[3];
					for(int i = 0; i < MaxClients; i++){
						if(i != client && IsValidSurvivor(i) && !IsClientIncapped(i)){
							GetClientAbsOrigin(i, temp);
							//倒地生还者500范围内已经没有正常生还者，掠过这个人的视线判断
							if(GetVectorDistance(temp, position) < 500.0){
								sum ++;
							}
						}
					}			
					if(sum == 0){
						Debug_Print("Teleport方法，目标位置已经不能被正常生还者所看到");
						continue;
					}else{
						Debug_Print("Teleport方法，目标位置依旧能被正常生还者看到，sum为：%d", sum);
					}	
				}
				else{
					continue;
				}
						
			}
			GetClientEyePosition(client, position);
			//position[0] += 20;
			if(GetVectorDistance(targetposition, position) < g_fSpawnDistanceMin)
			{
				return true;
			}
			MakeVectorFromPoints(targetposition, position, vLookAt);
			GetVectorAngles(vLookAt, vAngles);
			Handle trace = TR_TraceRayFilterEx(targetposition, vAngles, MASK_VISIBLE, RayType_Infinite, TraceFilter, client);
			if(TR_DidHit(trace))
			{
				static float vStart[3];
				TR_GetEndPosition(vStart, trace);
				if((GetVectorDistance(targetposition, vStart, false) + 75.0) >= GetVectorDistance(position, targetposition))
				{
					return true;
				}
				else
				{
					spawnPos = targetposition;
					spawnPos[2] += 40.0;
					MakeVectorFromPoints(spawnPos, position, vLookAt);
					GetVectorAngles(vLookAt, vAngles);
					Handle trace2 = TR_TraceRayFilterEx(spawnPos, vAngles, MASK_VISIBLE, RayType_Infinite, TraceFilter, client);
					if(TR_DidHit(trace2))
					{
						TR_GetEndPosition(vStart, trace2);
						if((GetVectorDistance(spawnPos, vStart, false) + 75.0) >= GetVectorDistance(position, spawnPos))
							return  true;
					}
					else
					{
						return true;
					}
					delete trace2;
				}
			}
			else
			{
				return true;
			}
			delete trace;
		}
	}
	return false;
}

//thanks fdxx https://github.com/fdxx/l4d2_plugins/blob/main/l4d2_si_spawn_control.sp
stock bool PlayerVisibleToSDK(float targetposition[3], bool IsTeleport = false){
	static float fTargetPos[3];

	float position[3];
	fTargetPos = targetposition;
	fTargetPos[2] += 62.0; //眼睛位置

	//计算该位置是不是和所有人都相隔大于g_fSpawnDistanceMax
	int count = 0, skipcount = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client))
		{
			GetClientEyePosition(client, position);
			//传送的时候无视倒地或者挂边生还者的视线，检测到跑男时，也不关注被控生还者的视线
			if(IsTeleport && (IsClientIncapped(client) || (g_bPickRushMan && IsPinned(client)))){
				if(!g_bIgnoreIncappedSurvivorSight){
					int sum = 0;
					float temp[3];
					for(int i = 1; i <= MaxClients; i++){
						if(i != client && IsValidSurvivor(i) && !IsClientIncapped(i)){
							GetClientAbsOrigin(i, temp);
							//倒地生还者500范围内已经没有正常生还者，掠过这个人的视线判断
							if(GetVectorDistance(temp, position) < 500.0){
								sum ++;
							}
						}
					}			
					if(sum == 0){
						Debug_Print("Teleport方法，目标位置已经不能被正常生还者所看到");
						skipcount++;
						continue;
					}else{
						Debug_Print("Teleport方法，目标位置依旧能被正常生还者看到，sum为：%d", sum);
					}	
				}else{
					skipcount++;
					continue;
				}		
			}
			//太近直接返回看见
			if(GetVectorDistance(targetposition, position) < g_fSpawnDistanceMin)
			{
				return true;
			}
			//太远直接返回没看见
			if(GetVectorDistance(targetposition, position) >= g_fSpawnDistanceMax)
			{
				count++;
				if(count >= (g_iSurvivorNum - skipcount)){
					return false;
				}

			}
			if (L4D2_IsVisibleToPlayer(client, 2, 3, 0, targetposition))
			{
				return true;
			}
			if (L4D2_IsVisibleToPlayer(client, 2, 3, 0, fTargetPos))
			{
				return true;
			}
		}
	}

	return false;
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

stock bool TraceFilter(int entity, int contentsMask)
{
	if (entity <= MaxClients || !IsValidEntity(entity))
	{
		return false;
	}
	else
	{
		static char sClassName[9];
		GetEntityClassname(entity, sClassName, sizeof(sClassName));
		if (strcmp(sClassName, "infected") == 0 || strcmp(sClassName, "witch") == 0)
		{
			return false;
		}
	}
	return true;
}

bool IsPinned(int client)
{
	bool bIsPinned = false;
	if (IsValidSurvivor(client) && IsPlayerAlive(client))
	{
		if(GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0) bIsPinned = true;
	}		
	return bIsPinned;
}

bool IsPinningSomeone(int client)
{
	bool bIsPinning = false;
	if (IsInfectedBot(client))
	{
		if (GetEntPropEnt(client, Prop_Send, "m_tongueVictim") > 0) bIsPinning = true;
		if (GetEntPropEnt(client, Prop_Send, "m_jockeyVictim") > 0) bIsPinning = true;
		if (GetEntPropEnt(client, Prop_Send, "m_pounceVictim") > 0) bIsPinning = true;
		if (GetEntPropEnt(client, Prop_Send, "m_pummelVictim") > 0) bIsPinning = true;
		if (GetEntPropEnt(client, Prop_Send, "m_carryVictim") > 0) bIsPinning = true;
	}
	return bIsPinning;
}

bool CanBeTeleport(int client)
{
	if (IsInfectedBot(client) && IsClientInGame(client)&& IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_TANK && !IsPinningSomeone(client))
	{
		if(g_bSmokerAvailable && IsAiSmoker(client) && !IsSmokerCanUseAbility(client))
		{
			return false;
		}
		if(IsSpitter(client) && GetGameTime() - g_fSpitterSpitTime[client] < SPIT_INTERVAL)
		{
			return false;
		}
		return true;
	}
	else
	{
		return false;
	}
}

//5秒内以1s检测一次，5次没被看到，就可以踢出并加入传送队列
public Action Timer_PositionSi(Handle timer)
{
	//每1s找一次跑男或者是否所有全被控
	if(CheckRushManAndAllPinned())
	{
		return Plugin_Stop;
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		if(CanBeTeleport(client)){
			float fSelfPos[3] = {0.0};
			GetClientEyePosition(client, fSelfPos);
			if (!PlayerVisibleToSDK(fSelfPos, true))
			{
				if (g_iTeleCount[client] > g_iTeleportCheckTime)
				{
					int type = GetInfectedClass(client);
					if(type >= 1 && type <= 6){
						if(g_iTeleportIndex == 0)
						{
							g_fTeleportDistance = g_fTeleportDistanceMin;
						}
						aTeleportQueue.Push(type);
						g_iTeleportIndex += 1;
						Debug_Print("<传送队列> %N踢出，进入传送队列，当前 <传送队列> 队列长度：%d 队列索引：%d 当前记录特感总数为：%d , 真实数量为：%d", client, aTeleportQueue.Length, g_iTeleportIndex, g_iTotalSINum, GetCurrentSINum());
						//不再单独处理spitter防止无声口水，已经在canbeteleport处理
						if(g_iSINum[type - 1] > 0)
						{
							g_iSINum[type - 1] --;
						}
						else
						{
							g_iSINum[type - 1] = 0;
						}
						if(g_iTotalSINum > 0)
						{
							g_iTotalSINum --;
						}
						else
						{
							g_iTotalSINum = 0;
						}
						KickClient(client, "传送刷特，踢出");
						Debug_Print("当前 <传送队列> 队列长度：%d 队列索引：%d 当前记录特感总数为：%d , 真实数量为：%d", aTeleportQueue.Length, g_iTeleportIndex, g_iTotalSINum, GetCurrentSINum());
						g_iTeleCount[client] = 0;
					}
				}
				g_iTeleCount[client] += 1;
			}
			else{
				g_iTeleCount[client] = 0;
			}
		}
		
	}
	//每1s找一次攻击目标，主要用于检测跑男，正常情况ongameframe会调用找攻击目标
	g_iTargetSurvivor = GetTargetSurvivor();
	return Plugin_Continue;
}

stock int GetCurrentSINum()
{
	int sum = 0;
	for(int i = 0; i < MaxClients; i++){
		if(IsInfectedBot(i) && !IsAiTank(i))
		{
			sum ++;
		}
	}
	return sum;
}

stock bool IsSpitter(int client)
{
	if (IsInfectedBot(client) && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_SPITTER)
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool CheckRushManAndAllPinned()
{
	bool TempRushMan = g_bPickRushMan;
	int iSurvivors[8] = {0}, iSurvivorIndex = 0, PinnedNumber = 0;
	float iSurvivorsOrigin[8][3], OriginTemp[3];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsValidSurvivor(client) && IsPlayerAlive(client))
		{
			if(IsPinned(client) || IsClientIncapped(client)){
				PinnedNumber++;
			}
			GetClientAbsOrigin(client, OriginTemp);
			if(iSurvivorIndex < 8)
			{
				iSurvivorsOrigin[iSurvivorIndex] = OriginTemp;
				iSurvivors[iSurvivorIndex++] = client;
			}		
		}
	}
	int target = L4D_GetHighestFlowSurvivor();
	if (iSurvivorIndex > 1 && IsValidClient(target))
	{
		GetClientAbsOrigin(target, OriginTemp);
		for(int i =0; i < iSurvivorIndex; i++){
			if(IsPinned(target) || IsClientIncapped(target) || (iSurvivors[i] != target && GetVectorDistance(iSurvivorsOrigin[i], OriginTemp) <= 1000.0))
			{
				g_bPickRushMan = false;
				g_iRushManIndex = -1;
				if(TempRushMan != g_bPickRushMan){
					StartForward(g_bPickRushMan);
				}
				return PinnedNumber == iSurvivorIndex;
			}
		}
		g_bPickRushMan = true;
		g_iRushManIndex = target;
		if(TempRushMan != g_bPickRushMan){
			StartForward(g_bPickRushMan);
		}
	}
	return PinnedNumber == iSurvivorIndex;
}

int GetTargetSurvivor()
{
	//如果有跑男，抓跑男
	if(g_bPickRushMan && IsValidSurvivor(g_iRushManIndex) && IsPlayerAlive(g_iRushManIndex) && !IsPinned(g_iRushManIndex)){
		return g_iRushManIndex;
	}
	//没有跑男，抓目标未满的生还者
	else
	{
		int iSurvivors[8] = {0} , iSurvivorIndex = 0;
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsValidSurvivor(client) && IsPlayerAlive(client) && (!IsPinned(client) || !IsClientIncapped(client)))
			{
				g_bIsLate = true;
				if(g_bTargetSystemAvailable && IsClientReachLimit(client))
				{
					continue;
				}
				if (iSurvivorIndex < 8)
				{
					iSurvivors[iSurvivorIndex] = client;
					iSurvivorIndex += 1;
				}
			}
		}
		//遍历所有正常人，检测与进度最远的人的距离是否已经大于1000.0，如果是，开启针对跑男模式，否则选择随机未满目标的正常生还者
		if (iSurvivorIndex > 0)
		{
			return iSurvivors[GetRandomInt(0, iSurvivorIndex - 1)];
		}
		else{
			return L4D_GetHighestFlowSurvivor();
		}
	}
}

void StartForward(bool IsRush){
	Debug_Print("跑男检测状态变化，发送forward");
	Call_StartForward(g_hRushManNotifyForward);//转发触发
	Call_PushCell(IsRush);//按顺序将参数push进forward传参列表里
	Call_Finish();//转发结束
}

// 判断是否有效玩家 id，有效返回 true，无效返回 false
stock bool IsValidClient(int client)
{
	if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 判断生还者是否有效，有效返回 true，无效返回 false
stock bool IsValidSurvivor(int client)
{
	if (IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR))
	{
		return true;
	}
	else
	{
		return false;
	}
}
// 判断玩家是否倒地，倒地返回 true，未倒地返回 false
stock bool IsClientIncapped(int client)
{
	if (IsValidClient(client))
	{
		return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
	}
	else
	{
		return false;
	}
}

// 获取特感类型，成功返回特感类型，失败返回 0
stock int GetInfectedClass(int client)
{
	if (IsValidInfected(client))
	{
		return GetEntProp(client, Prop_Send, "m_zombieClass");
	}
	else
	{
		return 0;
	}
}

stock bool IsValidInfected(int client)
{
	if (IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_INFECTED))
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock bool IsAiSmoker(int client)
{
	if (client && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED && GetEntProp(client, Prop_Send, "m_zombieClass") == 1 && GetEntProp(client, Prop_Send, "m_isGhost") != 1)
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock bool IsAiTank(int client)
{
	if (client && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED && GetEntProp(client, Prop_Send, "m_zombieClass") == 8 && GetEntProp(client, Prop_Send, "m_isGhost") != 1)
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock bool IsGhost(int client)
{
    return (IsValidClient(client) && view_as<bool>(GetEntProp(client, Prop_Send, "m_isGhost")));
}

//获取队列里Hunter和Charger数量
stock int getArrayHunterAndChargetNum(){
	int count = 0;
	for(int i = 0; i < aSpawnQueue.Length; i++){
		int type = aSpawnQueue.Get(i);
		if(type == 3 || type == 6){
			count++;
		}
	}
	return count;
}
stock int getArrayDominateSINum(){
	int count = 0;
	for(int i = 0; i < aSpawnQueue.Length; i++){
		int type = aSpawnQueue.Get(i);
		if(type != 2 || type == 4){
			count++;
		}
	}
	return count;
}

// 返回在场特感数量，根据 z_%s_limit 限制每种特感上限
bool MeetRequire(int iType)
{
	if(g_hAllChargerMode.BoolValue || g_hAllHunterMode.BoolValue){
		return true;
	}
	GetSiLimit();
	if (iType == 1)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0))
		{
			return true;
		}
	}
	else if (iType == 2)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0) && ((getArrayDominateSINum() > (g_iSiLimit/4 +1)) || (g_iQueueIndex >= g_iSiLimit -2)))
		{
			return true;
		}
	}
	else if (iType == 3)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0))
		{
			return true;
		}
	}
	else if (iType == 4)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0) && ((getArrayHunterAndChargetNum() > (g_iSiLimit/5 +1) || (g_iQueueIndex >= g_iSiLimit -2))))
		{
			return true;
		}
	}
	else if (iType == 5)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0))
		{
			return true;
		}
	}
	else if (iType == 6)
	{
		if (CheckSIOption(iType) && (g_ArraySIlimit[iType - 1] > 0))
		{
			return true;
		}
	}
	return false;
}

// 特感种类限制数组，刷完一波特感时重新读取 Cvar 数值，重置特感种类限制数量
void GetSiLimit()
{
	g_ArraySIlimit[0] = GetConVarInt(FindConVar("z_smoker_limit"));
	g_ArraySIlimit[1] = GetConVarInt(FindConVar("z_boomer_limit"));
	g_ArraySIlimit[2] = GetConVarInt(FindConVar("z_hunter_limit"));
	g_ArraySIlimit[3] = GetConVarInt(FindConVar("z_spitter_limit"));
	g_ArraySIlimit[4] = GetConVarInt(FindConVar("z_jockey_limit"));
	g_ArraySIlimit[5] = GetConVarInt(FindConVar("z_charger_limit"));
	//删除队列里已有元素
	for(int i = 0; i < aSpawnQueue.Length; i++){
		int type = aSpawnQueue.Get(i);
		if(type > 0 && type < 7){
			if(g_ArraySIlimit[type - 1] > 0){
				g_ArraySIlimit[type - 1]--;
			}			
			else
			{
				g_ArraySIlimit[type - 1] = 0;
			}
		}
	}
}

// 判断一个坐标是否在当前最高路程的生还者前面
bool Is_Pos_Ahead(float refpos[3], int target)
{
	int pos_flow = 0, target_flow = 0;
	Address pNowNav = L4D2Direct_GetTerrorNavArea(refpos);
	if (pNowNav == Address_Null)
	{
		pNowNav = view_as<Address>(L4D_GetNearestNavArea(refpos, 300.0));
	}
	pos_flow = Calculate_Flow(pNowNav);
	//int target = L4D_GetHighestFlowSurvivor();
	if (IsValidSurvivor(target))
	{
		float targetpos[3] = {0.0};
		GetClientAbsOrigin(target, targetpos);
		Address pTargetNav = L4D2Direct_GetTerrorNavArea(targetpos);
		if (pTargetNav == Address_Null)
		{
			pTargetNav = view_as<Address>(L4D_GetNearestNavArea(refpos, 300.0));
		}
		target_flow = Calculate_Flow(pTargetNav);
	}
	return view_as<bool>(pos_flow >= target_flow);
}
int Calculate_Flow(Address pNavArea)
{
	float now_nav_flow = L4D2Direct_GetTerrorNavAreaFlow(pNavArea) / L4D2Direct_GetMapMaxFlowDistance();
	float now_nav_promixity = now_nav_flow + g_hVsBossFlowBuffer.FloatValue / L4D2Direct_GetMapMaxFlowDistance();
	if (now_nav_promixity > 1.0)
	{
		now_nav_promixity = 1.0;
	}
	return RoundToNearest(now_nav_promixity * 100.0);
}

stock void Debug_Print(char[] format, any ...)
{
	#if (DEBUG)
	{
		char sTime[32];
		FormatTime(sTime, sizeof(sTime), "%I-%M-%S", GetTime()); 
		char sBuffer[512];
		VFormat(sBuffer, sizeof(sBuffer), format, 2);
		Format(sBuffer, sizeof(sBuffer), "[%s] %s: %s", "DEBUG", sTime, sBuffer);
	//	PrintToChatAll(sBuffer);
		PrintToConsoleAll(sBuffer);
		PrintToServer(sBuffer);
		LogToFile(sLogFile, sBuffer);
	}
	#endif
}

