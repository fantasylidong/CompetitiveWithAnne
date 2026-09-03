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


#define PLUGIN_VERSION "1.9"
// l4d_target_override 的 TARGET_SI_INDEX 数量（0=Tank，1..6=Smoker..Charger）
#define TARGET_CLASS_COUNT 7

ConVar	
	g_hPluginEnable,
	g_hSI_enable_option,
	g_hLimit_auto,
	g_hLimit_manual,
	g_hRushmanScope,
	g_hSILimit;
char
	g_sLogPath[PLATFORM_MAX_PATH];
bool
	g_bPluginEnable = true;
int 
	g_iSI_enable_option = 0,
	g_iLimit_auto = 0,
	g_iLimit_manual = 0,
	g_iRushmanScope = 1,
	g_iSILimit = 0,
	g_iFlowLeader = -1,
	g_iRushMan = -1,
	g_iBaseTargetLimit = 0;	// 当前推送到 l4d_target_override 职业级 "targeted" 的上限；0=未限制
ConVar
	g_hClassLimitCvars[8];

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
2026.9.2
1.9 修复与 infected_control 的跑男联动：OnDetectRushman(0) 表示跑男解除，此前
    刷特插件只在开启时通知，本插件会一直停留在“跑男放开上限”直到下一回合。
    新增 SI_target_rushman_scope：默认 1 只放开跑男本人的按人上限
    （L4D_TargetOverride_SetTargetedCap），其余生还者保持正常保护；0 为旧行为
    （全体抬到特感总上限）。SI_target_enable 现在真正生效（关闭时清空
    target_override 的 targeted 选项并让所有 native 返回“不限制”）。
    上限重算改为“算一次、推一次”，不再对 MAXPLAYERS 个槽位各推一遍职业级选项；
    手动模式也会在初始化时推送。补齐重算触发点（survivor_rescued /
    defibrillator_used / player_team / 生还者 player_spawn），并每秒校验一次：
    可动人数变化或 target_override 重载配置（sm_to_reload 会把 targeted 归零）
    导致的漂移会被自动纠正。infected_control 重载后不再重复挂钩
    l4d_infected_limit。include 里的库名改为与 RegPluginLibrary 一致的小写。
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

//针对来自infected_control的跑男检测：>0 = 跑男 client index，0 = 跑男状态解除
forward void OnDetectRushman(int DetectRushMan);
public void OnDetectRushman(int DetectRushman){
	int rusher = -1;
	if(DetectRushman > 0 && DetectRushman <= MaxClients && IsClientInGame(DetectRushman)
		&& GetClientTeam(DetectRushman) == 2)
	{
		rusher = DetectRushman;
	}
	Debug_Print("跑男状态改变：%d -> %d", g_iRushMan, rusher);
	SetRushMan(rusher, "rushman forward");
}

void SetRushMan(int rusher, const char[] reason)
{
	if(rusher == g_iRushMan)
		return;

	int old = g_iRushMan;
	g_iRushMan = rusher;

	if(g_iRushmanScope == 0)
	{
		// 旧行为：全体口径随跑男状态切换
		RefreshTargetLimits(reason);
		return;
	}

	SyncClientCap(old);
	SyncClientCap(g_iRushMan);
}

public void  OnPluginStart()
{
	g_hPluginEnable = CreateConVar("SI_target_enable", "1", "是否开启插件", 0, true, 0.0, true, 1.0);//Plugin Enable
	g_hSI_enable_option = CreateConVar("SI_enable_option", "53", "控制类特感掩码（1舌头，2Boomer，4猎人，8Spitter，16猴子，32牛，64Tank）。默认53=舌头+猎人+猴子+牛，共用控制类上限。", 0, true, 0.0, true, 127.0);
	g_hLimit_auto = CreateConVar("SI_target_limit_auto", "1", "自动上限：已启用控制类职业预算 / 可动生还者 + 1。预算为对应 z_*/inf_* 上限之和，并钳在 l4d_infected_limit 内。", 0, true, 0.0, true, 1.0);
	g_hLimit_manual = CreateConVar("SI_target_limit_manual", "3", "服务器不自动情况下手动限制最大目标的值.", 0, false, 0.0, false, 0.0);//If Auto disable, use manual value to control target limit
	g_hRushmanScope = CreateConVar("SI_target_rushman_scope", "1", "infected_control 检测到跑男时放开上限的范围：0=全体生还者抬到特感总上限（旧行为），1=仅跑男本人放开，其余生还者保持正常上限。", 0, true, 0.0, true, 1.0);
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/SI_Target_limit.log");
	
	// 可动生还者数量会变化的事件：死亡/倒地/救起/救援柜/电击/换队/生还者出生
	HookEvent("player_death", evt_SurvivorStateChanged);
	HookEvent("revive_success", evt_SurvivorStateChanged);
	HookEvent("player_incapacitated", evt_SurvivorStateChanged);
	HookEvent("player_ledge_grab", evt_SurvivorStateChanged);
	HookEvent("survivor_rescued", evt_SurvivorStateChanged);
	HookEvent("defibrillator_used", evt_SurvivorStateChanged);
	HookEvent("player_team", evt_SurvivorStateChanged);
	HookEvent("player_spawn", evt_SurvivorStateChanged);
	//创建的Cvar值变化处理
	g_hLimit_auto.AddChangeHook(ConVarChanged_Cvars);
	g_hLimit_manual.AddChangeHook(ConVarChanged_Cvars);
	g_hSI_enable_option.AddChangeHook(ConVarChanged_Cvars);
	g_hPluginEnable.AddChangeHook(ConVarChanged_Cvars);
	g_hRushmanScope.AddChangeHook(ConVarChanged_Cvars);
	
	BindSILimitConVar();
	GetCvars();
	RefreshTargetLimits("plugin start");
	//队首上限×2 / 跑男按人放开：每秒刷新一次队首归属并校验 target_override 侧状态
	CreateTimer(1.0, Timer_UpdateFlowLeader, _, TIMER_REPEAT);
	//AutoExecConfig(true, "RestrictedGameModes");

	RegAdminCmd("sm_targetlimit_status", Cmd_TargetLimitStatus, ADMFLAG_GENERIC, "Show per-survivor SI target counts and limits");
}

public void OnPluginEnd(){
	PushTargetedCap(g_iFlowLeader, 0);
	PushTargetedCap(g_iRushMan, 0);
	clear_target_option();
}

public void clear_target_option(){
		if(!TargetOverrideSetAvailable())
			return;
		for(int i = 0; i < TARGET_CLASS_COUNT; i++){
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, 0);
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED_MASK, 0);
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
		// ConVar 本身在插件卸载后仍存在；不摘钩会在重绑时对同一个 ConVar 挂两次。
		if(g_hSILimit != null)
		{
			g_hSILimit.RemoveChangeHook(ConVarChanged_Cvars);
			g_hSILimit = null;
		}
		g_iSILimit = 0;
		SetRushMan(-1, "infected_control removed");
		RefreshTargetLimits("infected_control removed");
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
	RefreshTargetLimits("rebind");
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

bool TargetOverrideGetOptionAvailable()
{
	return GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_GetOption") == FeatureStatus_Available;
}

// 限制是否处于生效状态：插件开启，且自动模式下能读到 l4d_infected_limit
bool LimitActive()
{
	if(!g_bPluginEnable)
		return false;
	if(g_iLimit_auto && g_hSILimit == null)
		return false;
	return true;
}

// 期望推送到 target_override 职业级 "targeted" 的值（0=不限制）
int ComputeClassTargetLimit()
{
	if(!LimitActive())
		return 0;
	if(g_iRushmanScope == 0 && g_iRushMan > 0 && g_iSILimit > 0)
		return g_iSILimit;
	return ComputeBaseTargetLimit();
}

// 统一入口：算一次上限，推一次职业级选项，再同步按人的 cap 覆盖。
void RefreshTargetLimits(const char[] reason)
{
	g_iBaseTargetLimit = ComputeClassTargetLimit();
	Debug_Print("RefreshTargetLimits(%s): base=%d rushman=%d leader=%d", reason, g_iBaseTargetLimit, g_iRushMan, g_iFlowLeader);
	PushClassOptions();
	SyncClientCap(g_iFlowLeader);
	SyncClientCap(g_iRushMan);
}

void PushClassOptions()
{
	if(!TargetOverrideSetAvailable())
		return;

	bool active = g_iBaseTargetLimit > 0;
	for(int i = 0; i < TARGET_CLASS_COUNT; i++){
		if(active && CheckSIOption(i)){
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, g_iBaseTargetLimit);
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED_MASK, g_iSI_enable_option);
		}	
		else{
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED, 0);
			L4D_TargetOverride_SetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED_MASK, 0);
		}
	}
}

// target_override 重载配置（sm_to_reload / 换图）会把 targeted 归零；每秒对一次账。
bool ClassOptionsDrifted()
{
	if(!TargetOverrideGetOptionAvailable())
		return false;

	for(int i = 0; i < TARGET_CLASS_COUNT; i++){
		int expected = (g_iBaseTargetLimit > 0 && CheckSIOption(i)) ? g_iBaseTargetLimit : 0;
		if(L4D_TargetOverride_GetOption(view_as<TARGET_SI_INDEX>(i), INDEX_TARGETED) != expected)
			return true;
	}
	return false;
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
	if (!LimitActive())
		return 0;
	return CheckSIOption(zombieClass) != 0 ? 1 : 0;
}

public Action Cmd_TargetLimitStatus(int client, int args)
{
	ReplyToCommand(client, "[SI_Target_limit] enable=%d active=%d budget=%d mobile=%d base=%d pushed=%d rushman=%d scope=%d leader=%d",
		g_bPluginEnable ? 1 : 0, LimitActive() ? 1 : 0,
		GetControlSIBudget(), GetMobileSurvivorNum(), ComputeBaseTargetLimit(), g_iBaseTargetLimit,
		g_iRushMan, g_iRushmanScope, g_iFlowLeader);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;
		int total = TargetOverrideGetAvailable()
			? L4D_TargetOverride_GetValue(i, view_as<VALUE_OPTION_INDEX>(VALUE_INDEX_TOTAL)) : -1;
		ReplyToCommand(client, "  %N: targeted=%d limit=%d%s%s%s", i, total,
			GetEffectiveTargetLimit(i),
			i == g_iFlowLeader ? " [leader]" : "",
			i == g_iRushMan ? " [rushman]" : "",
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

//有效目标上限：
//  - 跑男（scope=1）：抬到特感总上限，其余人不受影响；scope=0 时全体基准已经是总上限
//  - 队首（Flow 最高的可动生还者）×2
int GetEffectiveTargetLimit(int client)
{
	int limit = g_iBaseTargetLimit;
	if (limit <= 0)
		return 0;

	if (g_iRushMan > 0)
	{
		if (g_iRushmanScope == 0)
			return limit;
		if (client == g_iRushMan)
			return (g_iSILimit > limit) ? g_iSILimit : limit;
	}

	if (client == g_iFlowLeader)
		limit *= 2;
	return limit;
}

public Action Timer_UpdateFlowLeader(Handle timer)
{
	UpdateFlowLeader();

	// 可动人数变化没有被事件覆盖到（如非常规复活）、或 target_override 重载了配置时自动纠正
	if (ComputeClassTargetLimit() != g_iBaseTargetLimit || ClassOptionsDrifted())
		RefreshTargetLimits("periodic verify");
	else
	{
		SyncClientCap(g_iFlowLeader);
		SyncClientCap(g_iRushMan);
	}
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
		SyncClientCap(old);
		SyncClientCap(g_iFlowLeader);
	}
}

//按人的 cap 覆盖：有效上限与职业级基准不同才需要覆盖，否则写 0 交还给职业级选项
void SyncClientCap(int client)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
		return;

	int effective = GetEffectiveTargetLimit(client);
	PushTargetedCap(client, (effective != g_iBaseTargetLimit) ? effective : 0);
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

public void OnClientDisconnect(int client)
{
	if (client == g_iFlowLeader)
		g_iFlowLeader = -1;
	if (client == g_iRushMan)
		SetRushMan(-1, "rushman disconnected");
}

// 事件 event
public void evt_SurvivorStateChanged(Event event, const char[] name, bool dontBroadcast)
{
	// player_team 用 team/oldteam 判断是否涉及生还者（事件触发时 GetClientTeam 可能还是旧队伍）
	if (StrEqual(name, "player_team"))
	{
		if (event.GetInt("team") != 2 && event.GetInt("oldteam") != 2)
			return;
		RefreshTargetLimits(name);
		return;
	}

	int client;
	if (StrEqual(name, "survivor_rescued"))
		client = GetClientOfUserId(event.GetInt("victim"));
	else if (StrEqual(name, "revive_success") || StrEqual(name, "defibrillator_used"))
		client = GetClientOfUserId(event.GetInt("subject"));
	else
		client = GetClientOfUserId(event.GetInt("userid"));

	if (!IsValidClient(client) || GetClientTeam(client) != 2)
		return;

	RefreshTargetLimits(name);
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
	RefreshTargetLimits("cvar changed");
}

public void OnMapEnd()
{
	SetRushMan(-1, "map end");
}

public void OnMapStart()
{
	RebindDependencies();
}
public Action L4D_OnFirstSurvivorLeftSafeArea(int client){
	SetRushMan(-1, "round start");
	RefreshTargetLimits("first survivor left safe area");
	
    return Plugin_Continue;
}

//随机获得一个未达到目标限制的正常生还者
stock int GetRandomMobileSurvivor(int excluse = -1, bool CheckLimit = false)
{
	int survivors[MAXPLAYERS + 1] = {0}, index = 0;
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
	int count = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client) && !L4D_IsPlayerIncapacitated(client))
		{
			count += 1;
		}
	}
	return count;
}


void GetCvars()
{
	g_bPluginEnable = g_hPluginEnable.BoolValue;
	g_iSI_enable_option = GetConVarInt(g_hSI_enable_option);
	g_iLimit_auto = GetConVarInt(g_hLimit_auto);
	g_iLimit_manual = GetConVarInt(g_hLimit_manual);
	g_iRushmanScope = GetConVarInt(g_hRushmanScope);
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
