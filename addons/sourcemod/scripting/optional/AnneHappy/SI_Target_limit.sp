#pragma newdecls required
#define DEBUG 0
#define ZC_SMOKER		1
#define ZC_BOOMER		2
#define ZC_HUNTER		3
#define ZC_SPITTER		4
#define ZC_JOCKEY		5
#define ZC_CHARGER		6
#define ZC_TANK			8
#define ENABLE_SMOKER			(1 << 0)		
#define ENABLE_BOOMER			(1 << 1)		
#define ENABLE_HUNTER			(1 << 2)		
#define ENABLE_SPITTER			(1 << 3)		
#define ENABLE_JOCKEY			(1 << 4)		
#define ENABLE_CHARGER			(1 << 5)		
#define ENABLE_TANK				(1 << 6)		
#if (DEBUG)
char sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/SITargetLimit.txt";
#endif
/**/
#pragma semicolon 1
#include <sourcemod>
#include <left4dhooks>
#undef REQUIRE_PLUGIN
#include <l4d_target_override>


#define PLUGIN_VERSION "1.8"
ConVar	
	g_hPluginEnable,
	g_hSI_enable_option,
	g_hLimit_auto,
	g_hLimit_manual,
	g_hSILimit;
char
	g_sLogPath[PLATFORM_MAX_PATH];
bool 
	g_bDetectRushMan = false;
int 
	g_iSI_enable_option = 0,
	g_iLimit_auto = 0,
	g_iLimit_manual = 0,
	g_iSILimit = 0,
	g_iFlowLeader = -1;
ConVar
	g_hClassLimitCvars[8];
enum struct PlayerStruct{
	int targetLimit;
	void PlayerStruct(){
		if(g_iLimit_auto){
			if(g_hSILimit == null){
				this.targetLimit = 0;
				return;
			}
			this.targetLimit = ComputeBaseTargetLimit();
			this.target_override_set(this.targetLimit);
		}
			
		else{
			this.targetLimit = g_iLimit_manual;
		}
	}
	void SetTargetLimit(int number){
		if(g_iLimit_auto){
			if(g_hSILimit == null){
				this.targetLimit = 0;
				return;
			}
			if(g_bDetectRushMan){
				this.targetLimit = g_iSILimit;
			}else{
				this.targetLimit = number;
			}	
			this.target_override_set(this.targetLimit);		
		}
		else
		{
			this.targetLimit = g_iLimit_manual;
			this.target_override_set(this.targetLimit);
		}
	}
	void target_override_set(int num){
		if(!TargetOverrideSetAvailable())
			return;
		for(int i = 0; i < 7; i++){
			if(CheckSIOption(i)){
				L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, num);
				L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED_MASK, g_iSI_enable_option);
			}	
			else{
				L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, 0);
				L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED_MASK, 0);
			}
		}
	}
}

PlayerStruct player[MAXPLAYERS + 1];
bool infected[MAXPLAYERS + 1];
public Plugin myinfo =
{
	name = "SI target limit",
	author = "东",
	description = "限制单个玩家被特感选为目标的最大数量",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/"
}
/*
Changelog
2026.8.29
1.8 账本统一：新增 IsClassTargetLimited native，供各特感 AI 插件在
    L4D2_OnChooseVictim 改靶前判断该职业是否受控制类上限约束；配合
    l4d_target_override 2.27 的 SetLastVictim，两条改靶通道共用同一份
    per-survivor 锁定计数。新增 sm_targetlimit_status 管理员调试命令。
1.7 控制类特感（舌头/猎人/猴子/牛）共用独立上限：控制类预算 / 可动生还 + 1。
    预算取已启用控制职业的 z_ / inf_ 上限之和，并钳在 l4d_infected_limit 内。
    Boomer/Spitter/Tank 不占这个池；计数只统计控制类锁定。
2026.8.26
1.6 队首（Flow 最高的可动生还者）目标上限 ×2：GetClientTargetLimit 返回有效上限，
    并通过 L4D_TargetOverride_SetTargetedCap 同步给目标分配，让刷特容量口径和
    AI 实际锁定口径一致；可选依赖晚加载/卸载时安全停用并自动重绑
2026.8.25
1.5 提供当前玩家目标上限 Native，供刷特插件计算生成容量
2022.9.20
1.4 适配infected_control的跑男针对
1.3 适配l4d_target_override
1.0 初始版本发布
*/

//针对来自infected_control的跑男检测特殊处理
forward void OnDetectRushman(int DetectRushMan);
public void OnDetectRushman(int DetectRushman){
	Debug_Print("跑男状态改变，当前状态为：%d", DetectRushman);
	if(DetectRushman){
		g_bDetectRushMan = true;
		for(int i = 0; i < MAXPLAYERS +1; i++)
		{
			player[i].SetTargetLimit(g_iSILimit);
		}
	}else
	{
		g_bDetectRushMan = false;
		int normalSur = ComputeBaseTargetLimit();
		for(int i = 0; i < MAXPLAYERS +1; i++){
			player[i].SetTargetLimit(normalSur);
		}
	}
}

public void  OnPluginStart()
{
	g_hPluginEnable = CreateConVar("SI_target_enable", "1", "是否开启插件", 0, true, 0.0, true, 1.0);//Plugin Enable
	g_hSI_enable_option = CreateConVar("SI_enable_option", "53", "控制类特感掩码（1舌头，2Boomer，4猎人，8Spitter，16猴子，32牛，64Tank）。默认53=舌头+猎人+猴子+牛，共用控制类上限。", 0, true, 0.0, true, 127.0);
	g_hLimit_auto = CreateConVar("SI_target_limit_auto", "1", "自动上限：已启用控制类职业预算 / 可动生还者 + 1。预算为对应 z_*/inf_* 上限之和，并钳在 l4d_infected_limit 内。", 0, true, 0.0, true, 1.0);
	g_hLimit_manual = CreateConVar("SI_target_limit_manual", "3", "服务器不自动情况下手动限制最大目标的值.", 0, false, 0.0, false, 0.0);//If Auto disable, use manual value to control target limit
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/SI_Target_limit.log");
	
	// HookEvents
	HookEvent("player_spawn", evt_PlayerSpawn);
	//用来检测可活动的生还者数量，动态修改
	//detect alive survivor
	HookEvent("player_death", evt_PlayerDeath);
	//HookEvent("infected_death", evt_InfectedDeath);
	HookEvent("revive_success", evt_PlayerRevive);
	HookEvent("player_incapacitated", evt_PlayerIncap);
	//创建的Cvar值变化处理
	g_hLimit_auto.AddChangeHook(ConVarChanged_Cvars);
	g_hLimit_manual.AddChangeHook(ConVarChanged_Cvars);
	g_hSI_enable_option.AddChangeHook(ConVarChanged_Cvars);
	g_hPluginEnable.AddChangeHook(ConVarChanged_Cvars);
	
	BindSILimitConVar();
	GetCvars();
	StructInit();
	//队首上限×2：每秒刷新一次队首归属并同步目标分配侧的按玩家上限
	CreateTimer(1.0, Timer_UpdateFlowLeader, _, TIMER_REPEAT);
	//AutoExecConfig(true, "RestrictedGameModes");

	RegAdminCmd("sm_targetlimit_status", Cmd_TargetLimitStatus, ADMFLAG_GENERIC, "Show per-survivor SI target counts and limits");
}

public void OnPluginEnd(){
	if(g_iFlowLeader > 0){
		PushTargetedCap(g_iFlowLeader, 0);
	}
	clear_target_option();
}

public void clear_target_option(){
		if(!TargetOverrideSetAvailable())
			return;
		for(int i = 0; i < 7; i++){
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, 0);
			//Debug_Print("所有不启用特感target值更改为 %d", L4D_TargetOverride_GetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED));
		}
	}

//创建Native函数给其他插件使用
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	//API
	RegPluginLibrary("si_target_limit");
	
	CreateNative("GetClientTargetNum", Native_GetClientTargetNum);
	CreateNative("IsClientReachLimit", Native_IsClientReachLimit);
	CreateNative("GetClientTargetLimit", Native_GetClientTargetLimit);
	CreateNative("IsClassTargetLimited", Native_IsClassTargetLimited);
	
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	RebindDependencies();
}

public void OnLibraryAdded(const char[] name)
{
	if(StrEqual(name, "infected_control") || StrEqual(name, "l4d_target_override"))
		RequestFrame(Frame_RebindDependencies);
}

public void OnLibraryRemoved(const char[] name)
{
	if(StrEqual(name, "infected_control"))
	{
		g_hSILimit = null;
		g_iSILimit = 0;
	}
}

public void Frame_RebindDependencies(any data)
{
	RebindDependencies();
}

void RebindDependencies()
{
	BindSILimitConVar();
	BindClassLimitCvars();
	GetCvars();
	StructInit();
}

bool BindSILimitConVar()
{
	if(g_hSILimit != null)
		return true;

	ConVar siLimit = FindConVar("l4d_infected_limit");
	if(siLimit == null)
		return false;

	g_hSILimit = siLimit;
	g_hSILimit.AddChangeHook(ConVarChanged_Cvars);
	return true;
}

bool TargetOverrideSetAvailable()
{
	return GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_SetOption") == FeatureStatus_Available;
}

bool TargetOverrideGetAvailable()
{
	return GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_GetValue") == FeatureStatus_Available;
}



//API
public int Native_GetClientTargetNum(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	//Debug_Print("GetClientTargetNum Native called");
	
	if(!TargetOverrideGetAvailable())
		return 0;
	return L4D_TargetOverride_GetValue(client, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL));
}

public int Native_IsClientReachLimit(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	//Debug_Print("IsClientReachLimit Native被调用");
	//Debug_Print("IsClientReachLimit Native called");
	return IsReachLimit(client);
}

public int Native_GetClientTargetLimit(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", client);
	}
	if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	return GetEffectiveTargetLimit(client);
}

//该职业是否受控制类目标上限约束（供 AI 插件在改靶前判断口径）
public int Native_IsClassTargetLimited(Handle plugin, int numParams)
{
	int zombieClass = GetNativeCell(1);
	if (!g_hPluginEnable.BoolValue)
		return 0;
	return CheckSIOption(zombieClass) != 0 ? 1 : 0;
}

public Action Cmd_TargetLimitStatus(int client, int args)
{
	ReplyToCommand(client, "[SI_Target_limit] budget=%d mobile=%d base=%d rushman=%d leader=%d",
		GetControlSIBudget(), GetMobileSurvivorNum(), ComputeBaseTargetLimit(),
		g_bDetectRushMan ? 1 : 0, g_iFlowLeader);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;
		int total = TargetOverrideGetAvailable()
			? L4D_TargetOverride_GetValue(i, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)) : -1;
		ReplyToCommand(client, "  %N: targeted=%d limit=%d%s%s", i, total,
			GetEffectiveTargetLimit(i),
			i == g_iFlowLeader ? " [leader]" : "",
			L4D_IsPlayerIncapacitated(i) ? " [incap]" : "");
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i))
			continue;
		int victim = TargetOverrideGetAvailable()
			? L4D_TargetOverride_GetValue(i, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_VICTIM)) : 0;
		int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
		char victimName[64] = "none";
		if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim))
			GetClientName(victim, victimName, sizeof(victimName));
		ReplyToCommand(client, "  SI %N (class %d%s): victim=%s", i, zc,
			CheckSIOption(zc) ? "*" : "", victimName);
	}
	return Plugin_Handled;
}

//有效目标上限：队首（Flow 最高的可动生还者）×2。跑男模式下所有人的
//上限已经抬到特感总上限，不再叠加。
int GetEffectiveTargetLimit(int client)
{
	int limit = player[client].targetLimit;
	if (limit > 0 && !g_bDetectRushMan && client == g_iFlowLeader)
	{
		limit *= 2;
	}
	return limit;
}

public Action Timer_UpdateFlowLeader(Handle timer)
{
	UpdateFlowLeader();
	return Plugin_Continue;
}

void UpdateFlowLeader()
{
	int leader = -1;
	float best = -1.0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || GetClientTeam(i) != 2
			|| !IsPlayerAlive(i) || L4D_IsPlayerIncapacitated(i))
		{
			continue;
		}
		float d = L4D2Direct_GetFlowDistance(i);
		if (d < 0.0)
			continue;
		if (d > best)
		{
			best = d;
			leader = i;
		}
	}

	if (leader != g_iFlowLeader)
	{
		int old = g_iFlowLeader;
		g_iFlowLeader = leader;
		if (old > 0)
		{
			PushTargetedCap(old, 0);
		}
	}
	//有效上限会随 limit 重算而变化，统一每秒同步一次
	if (g_iFlowLeader > 0)
	{
		PushTargetedCap(g_iFlowLeader, GetEffectiveTargetLimit(g_iFlowLeader));
	}
}

//把按玩家的 targeted 上限推给 l4d_target_override（native 不存在时静默跳过）
void PushTargetedCap(int client, int cap)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
		return;
	if (GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_SetTargetedCap")
		!= FeatureStatus_Available)
	{
		return;
	}
	L4D_TargetOverride_SetTargetedCap(client, cap);
}

// 事件 event
public void evt_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(IsValidClient(client) && GetClientTeam(client) == 3){
		infected[client] = view_as<bool>(CheckSIOption(GetEntProp(client, Prop_Send, "m_zombieClass")));
	}
}

public void evt_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(IsValidClient(client) ){
		if(GetClientTeam(client) == 2){
			int normalSur = ComputeBaseTargetLimit();
			for(int i = 0; i < MAXPLAYERS +1; i++){
				player[i].SetTargetLimit(normalSur);
			}
		}
		if(GetClientTeam(client) == 3 && infected[client]){
			infected[client] = false;
		}
	}
	
}
/*
public void evt_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("infected_id"));
	if(IsValidClient(client) && GetClientTeam(client) == 3 && infected[client].enable){
		if(infected[client].target > 0){
			if( player[infected[client].target].targetSum > 0 ){
				player[infected[client].target].targetSum --;
				Debug_Print("%N 已死亡，原来的目标 %N 上限减1 为 %d(%d)", client, infected[client].target, player[infected[client].target].targetSum, player[infected[client].target].targetLimit);
			}
		}	
		else{
				Debug_Print("%N 已死亡，无目标", client);
		}	
		
		infected[client].target = -1;
		infected[client].enable = false;
	}
	
}
*/

public void evt_PlayerRevive(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("subject"));
	if(IsValidClient(client) && GetClientTeam(client) == 2){
		int normalSur = ComputeBaseTargetLimit();
		for(int i = 0; i < MAXPLAYERS +1; i++){
			player[i].SetTargetLimit(normalSur);
		}
	}
}

public void evt_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if(IsValidClient(client) && GetClientTeam(client) == 2){
		int normalSur = ComputeBaseTargetLimit();
		for(int i = 0; i < MAXPLAYERS +1; i++){
			player[i].SetTargetLimit(normalSur);
		}
	}
}


//Check SI enable option
public int CheckSIOption(int iZombieClass){
    switch (iZombieClass)
    {
        case 1:
        {
            return 1 << 0 & g_iSI_enable_option;
        }
        case 2:
        {
            return 1 << 1 & g_iSI_enable_option;
        }
        case 3:
        {
            return 1 << 2 & g_iSI_enable_option;
        }
        case 4:
        {
            return 1 << 3 & g_iSI_enable_option;
        }
        case 5:
        {
            return 1 << 4 & g_iSI_enable_option;
        }
        case 6:
        {
            return 1 << 5 & g_iSI_enable_option;
        }
        case 0:
        {
            return 1 << 6 & g_iSI_enable_option;
        }
		case 8:
        {
            return 1 << 6 & g_iSI_enable_option;
        }
    }
    return 0;
}

// *********************
//		获取Cvar值 GetCvar
// *********************
void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
	if(g_iLimit_auto && g_hSILimit == null)
		return;
	int normalSur = ComputeBaseTargetLimit();
	for(int i = 0; i < MAXPLAYERS +1; i++){
		player[i].SetTargetLimit(normalSur);
	}
}

//Init Struct
public void StructInit(){
	if(g_iLimit_auto && g_hSILimit == null)
		return;
	for(int i = 0; i < MAXPLAYERS + 1; i++)
	{
		player[i].PlayerStruct();
		infected[i] = false;
	}
	g_bDetectRushMan = false;
}

public void OnMapEnd()
{
	//GetCvars();
	StructInit();
}

public void OnMapStart()
{
	RebindDependencies();
}
public Action L4D_OnFirstSurvivorLeftSafeArea(int client){
	//GetCvars();
    StructInit();
	
    return Plugin_Continue;
}
/*
//SI choose another target, delete originalTarget limit
public void deleteOrginalTarget(int specialInfected){
	//将特感原来的目标的targetSum减1 original target minus 1
	if(infected[specialInfected].target > 0 && player[infected[specialInfected].target].targetSum > 0){
		Debug_Print("%N 原来的目标为 %N[%N] (%d/%d)[%d]", specialInfected, \
														infected[specialInfected].target, \
														L4D_TargetOverride_GetValue(specialInfected, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_VICTIM)), \
														player[infected[specialInfected].target].targetSum, \
														player[infected[specialInfected].target].targetLimit);
		player[infected[specialInfected].target].targetSum --;
		//清除当前特感的值
		infected[specialInfected].target = -1;
	}
}


//Deal with SI change target
//特感选择目标，对对应特感进行处理
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget){
	if(IsValidClient(specialInfected) && GetClientTeam(specialInfected) == 3 && g_bPluginEnable && infected[specialInfected].enable && infected[specialInfected].target != curTarget){
		if(IsValidClient(curTarget) && GetClientTeam(curTarget) == 2){
			//如果转换的目标已经达到限制
			if(player[curTarget].IsReachLimit()){
				//如果原来有目标，保持原来目标不变
				if(infected[specialInfected].target > 0 && !player[infected[specialInfected].target].IsReachLimit()){
					int temp = infected[specialInfected].target;
					Debug_Print("%N 选择的目标 %N 已经到达上限 %d(%d) 个，切换为目标未满的原目标 %N %d(%d)", specialInfected, curTarget, player[curTarget].targetSum, player[curTarget].targetLimit, temp, player[temp].targetSum, player[temp].targetLimit);
					curTarget = infected[specialInfected].target;
					return Plugin_Changed;
				}
				//如果没有其他目标，获取其他没达到目标限制的正常生还者分给这个特感
				int temp = GetRandomMobileSurvivor(curTarget, true);
				//没有这样的人了，依旧用调用的切换对象
				if(temp == 0)
				{
					//curTarget = temp;
					deleteOrginalTarget(specialInfected);
					player[curTarget].targetSum ++;
					infected[specialInfected].target = curTarget;
					Debug_Print("%N 已经没有可选择的目标,选择默认目标 %N %d(%d)", specialInfected, curTarget, player[curTarget].targetSum, player[curTarget].targetLimit);
					return Plugin_Continue;
				//有，切换目标
				}else{	
					deleteOrginalTarget(specialInfected);
					infected[specialInfected].target = temp;
					player[temp].targetSum ++;
					Debug_Print("%N 选择的目标 %N 已经到达上限 %d(%d) 个，将目标更换为 %N %d(%d)", specialInfected, curTarget, player[curTarget].targetSum, player[curTarget].targetLimit, temp, player[temp].targetSum, player[temp].targetLimit);
					curTarget = temp;
					return Plugin_Changed;
				}			
			}else{
				deleteOrginalTarget(specialInfected);
				player[curTarget].targetSum ++;				
				infected[specialInfected].target = curTarget;
				Debug_Print("%N 选择目标为%N %d(%d)", specialInfected, curTarget, player[curTarget].targetSum, player[curTarget].targetLimit);
			}
		}
	}
	return Plugin_Continue;
}

public Action L4D_OnTargetOverride(int specialInfected, int &curTarget, int order){
	if(IsValidClient(specialInfected) && GetClientTeam(specialInfected) == 3 && g_bPluginEnable && infected[specialInfected].enable && infected[specialInfected].target != curTarget){
		if(IsValidClient(curTarget) && GetClientTeam(curTarget) == 2){
			//如果转换的目标已经达到限制
			if(player[curTarget].IsReachLimit()){
				//如果原来有目标，保持原来目标不变
				if(infected[specialInfected].target > 0 && !player[infected[specialInfected].target].IsReachLimit()){
					int temp = infected[specialInfected].target;
					Debug_Print("%N 选择的目标 %N 已经到达上限 (%d/%d)[%d/%d] 个，切换为目标未满的原目标 %N[%N] (%d/%d)[%d/%d]", specialInfected, \
																													curTarget, \
																													player[curTarget].targetSum, \
																													player[curTarget].targetLimit, \
																													L4D_TargetOverride_GetValue(curTarget, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)), \
																													temp, \
																													L4D_TargetOverride_GetValue(specialInfected, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_VICTIM)), \
																													player[temp].targetSum, \
																													player[temp].targetLimit,  \
																													L4D_TargetOverride_GetValue(temp, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)));
					curTarget = infected[specialInfected].target;
					return Plugin_Changed;
				}
				//如果没有其他目标，获取其他没达到目标限制的正常生还者分给这个特感
				int temp = GetRandomMobileSurvivor(curTarget, true);
				//没有这样的人了，依旧用调用的切换对象
				if(temp == 0)
				{
					//curTarget = temp;
					deleteOrginalTarget(specialInfected);
					player[curTarget].targetSum ++;
					infected[specialInfected].target = curTarget;
					Debug_Print("%N 已经没有可选择的目标,选择默认目标 %N (%d/%d)[%d]", specialInfected, \
																					curTarget, \
																					player[curTarget].targetSum, \
																					player[curTarget].targetLimit,  \
																					L4D_TargetOverride_GetValue(curTarget, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)));
					return Plugin_Continue;
				//有，切换目标
				}else{	
					deleteOrginalTarget(specialInfected);
					infected[specialInfected].target = temp;
					player[temp].targetSum ++;
					Debug_Print("%N 选择的目标 %N 已经到达上限 (%d/%d)[%d] 个，将目标更换为 %N (%d/%d)[%d]", specialInfected, \
																										curTarget, \
																										player[curTarget].targetSum, \
																										player[curTarget].targetLimit,  \
																										L4D_TargetOverride_GetValue(curTarget, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)), \
																										temp, \
																										player[temp].targetSum, \
																										player[temp].targetLimit, \
																										L4D_TargetOverride_GetValue(temp, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)));
					curTarget = temp;
					return Plugin_Changed;
				}			
			}else{
				deleteOrginalTarget(specialInfected);
				player[curTarget].targetSum ++;				
				infected[specialInfected].target = curTarget;
				Debug_Print("%N 选择目标为%N (%d/%d)[%d]", specialInfected, curTarget, player[curTarget].targetSum, player[curTarget].targetLimit, \
															L4D_TargetOverride_GetValue(curTarget, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)));
			}
		}
	}
	return Plugin_Continue;
}
*/
//不再对目标进行处理，只进行track
#if (DEBUG)
public Action L4D_OnTargetOverride(int specialInfected, int &curTarget, int order){
	if(IsValidClient(specialInfected) && GetClientTeam(specialInfected) == 3 && g_bPluginEnable && infected[specialInfected]){
		if(IsValidClient(curTarget) && GetClientTeam(curTarget) == 2){			
			//Debug_Print("%N 选择目标为%N (%d/%d)", specialInfected, curTarget, L4D_TargetOverride_GetValue(curTarget, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)), player[curTarget].targetLimit);
		}
	}
	return Plugin_Continue;
}
#endif

//随机获得一个未达到目标限制的正常生还者
stock int GetRandomMobileSurvivor(int excluse = -1, bool CheckLimit = false)
{
	int survivors[16] = {0}, index = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client) && !L4D_IsPlayerIncapacitated(client) && client != excluse)
		{
			if(CheckLimit && IsReachLimit(client))
				continue;
			survivors[index] = client;
			index += 1;
		}
	}
	if (index > 0)
	{
		return survivors[GetRandomInt(0, index - 1)];
	}
	return 0;
}

//返回总的正常生还者个数
stock int GetMobileSurvivorNum()
{
	int survivors[16] = {0}, index = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client) && !L4D_IsPlayerIncapacitated(client))
		{
			survivors[index] = client;
			index += 1;
		}
	}
	return index;
}


void GetCvars()
{
	g_iSI_enable_option = GetConVarInt(g_hSI_enable_option);
	g_iLimit_auto = GetConVarInt(g_hLimit_auto);
	g_iLimit_manual = GetConVarInt(g_hLimit_manual);
	g_iSILimit = g_hSILimit == null ? 0 : GetConVarInt(g_hSILimit);
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
int ReadClassCap(const char[] infName, const char[] zName)
{
	ConVar inf = FindConVar(infName);
	if(inf != null && inf.IntValue >= 0)
		return inf.IntValue;
	ConVar z = FindConVar(zName);
	return z == null ? 0 : z.IntValue;
}

int GetControlSIBudget()
{
	int n = 0;
	if(g_iSI_enable_option & ENABLE_SMOKER)
		n += ReadClassCap("inf_smoker_limit", "z_smoker_limit");
	if(g_iSI_enable_option & ENABLE_HUNTER)
		n += ReadClassCap("inf_hunter_limit", "z_hunter_limit");
	if(g_iSI_enable_option & ENABLE_JOCKEY)
		n += ReadClassCap("inf_jockey_limit", "z_jockey_limit");
	if(g_iSI_enable_option & ENABLE_CHARGER)
		n += ReadClassCap("inf_charger_limit", "z_charger_limit");
	if(n < 1)
		n = g_iSILimit;
	if(g_iSILimit > 0 && n > g_iSILimit)
		n = g_iSILimit;
	return n;
}

int ComputeBaseTargetLimit()
{
	if(!g_iLimit_auto)
		return g_iLimit_manual;
	int temp = GetMobileSurvivorNum();
	if(temp < 1) temp = 1;
	return (GetControlSIBudget() / temp) + 1;
}

void BindClassLimitCvars()
{
	static const char names[][] = {
		"z_smoker_limit", "z_hunter_limit", "z_jockey_limit", "z_charger_limit",
		"inf_smoker_limit", "inf_hunter_limit", "inf_jockey_limit", "inf_charger_limit"
	};
	for(int i = 0; i < 8; i++)
	{
		ConVar c = FindConVar(names[i]);
		if(c == null || c == g_hClassLimitCvars[i])
			continue;
		g_hClassLimitCvars[i] = c;
		c.AddChangeHook(ConVarChanged_Cvars);
	}
}

stock bool IsReachLimit(int client){
			int limit = GetEffectiveTargetLimit(client);
			return limit > 0 && TargetOverrideGetAvailable()
				&& L4D_TargetOverride_GetValue(client, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)) >= limit;
		}

stock void Debug_Print(char[] format, any ...)
{
#if DEBUG == 0
	#pragma unused format
#endif
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
