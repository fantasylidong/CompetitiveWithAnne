/**
 * End-user License Agreements
 * Half-Year warranty since deal, fix any bug for free
 * 
 * If Distribute, copy or share this code without permission, will void the warranty and we will not support anymore 
 * 
 * You can install on server and use the function of this plugin to receive sponsorships
 * 
 * You are free to modify source code for your convenience, but this will void the warranty. 
 * In case of bugs or malfunctions resulting from such modifications, we will not be responsible.
 * 
 * Once you receive this sp file, you are deemed to have agreed, understood and applied to the content above.
 * 
 * -----------------------------------------------------------------------------
 * 終端使用者授權合約
 * 以交易日期計算只有半年保固期，半年內插件有問題或者出現bug或者有優化可以免費更新修復到好
 * 
 * 未經同意，隨意散播發布、複製、分享這個插件與這個插件的代碼，將失去保固期並不再提供支援
 * 
 * 你可以使用、安裝到伺服器上、用此插件的功能營利或獲得贊助
 * 
 * 你可以修改源碼，以利於自己能方便使用，但這將導致保固期失效；出現Bug或不能正常使用的情況，後果自行承擔
 * 
 * 一旦拿到此插件源碼即視為您對該內容已認同、了解及適用
 * 
 * -----------------------------------------------------------------------------
 * 终端使用者授权合约
 * 以交易日期计算只有半年保固期，半年内插件有问题或者出现bug或者有优化可以免费更新修复到好
 * 
 * 未经同意，随意散播发布、复制、分享这个插件与这个插件的代码，将失去保固期并不再提供支援
 * 
 * 你可以使用、安装到伺服器上、用此插件的功能营利或获得赞助
 * 
 * 你可以修改源码，以利于自己能方便使用，但这将导致保固期失效；出现Bug或不能正常使用的情况，后果自行承担
 * 
 * 一旦拿到此插件源码即视为您对该内容已认同、了解及适用
 */

/**
 * 晚上6-11点，非管理员只能玩大于等于4人的模式，2v2或者3v3，小于4人的模式就卸载模式，并写个提示
 * 检测survivor_limit和那个特感人数就行
 * 相加小于4，就卸载模式，卸载可以confogl自带的，sm_resetmatch
 * 时间给个Convar更改
 * 晚上有人玩1人模式太占资源了
 * 检测所有玩家里是否有管理员，没有的话就卸载模式。
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>      // https://github.com/fbef0102/L4D1_2-Plugins/releases

#define PLUGIN_VERSION			"1.0-2024/10/21"
#define PLUGIN_NAME			    "l4d_player_count_unload_mode"
#define DEBUG 0

public Plugin myinfo =
{
	name = "[L4D2 - ZM環境] 人數不夠卸載模式",
	author = "HarryPotter",
	description = "This is custom plugin",
	version = PLUGIN_VERSION,
	url = "https://steamcommunity.com/profiles/76561198026784913/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion test = GetEngineVersion();

    if( test != Engine_Left4Dead2 )
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

#define CVAR_FLAGS                    FCVAR_NOTIFY
#define CVAR_FLAGS_PLUGIN_VERSION     FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_SPONLY

#define TEAM_SPECTATOR		1
#define TEAM_SURVIVOR		2
#define TEAM_INFECTED		3

ConVar survivor_limit, z_max_player_zombies;
int g_iCvarSurvivorLimit, g_iCvarInfectedMax;

ConVar g_hCvarEnable, g_hCvarTime, g_hCvarCount, g_hCvarFlag, g_hCvarDelay;
bool g_bCvarEnable;
int g_iCvarCount;
float g_fCvarDelay;
char g_sCvarime[128], g_sCvarFlag[AdminFlags_TOTAL];

enum struct ETimeData
{
    char m_sTime[12];
    int m_iCvarStartHour;
    int m_iCvarStartMin;
    int m_iCvarEndHour;
    int m_iCvarEndMin;
}

ArrayList g_aTimeList;

int 
    g_iRoundStart, 
    g_iPlayerSpawn,
    g_iRoundCounter;

bool 
    g_bPluginStart;

Handle
    g_hDetectTimer;

public void OnPluginStart()
{ 
    survivor_limit = FindConVar("survivor_limit");
    z_max_player_zombies = FindConVar("z_max_player_zombies");

    g_hCvarEnable 		= CreateConVar( PLUGIN_NAME ... "_enable",        "1",              "0=Plugin off, 1=Plugin on.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvarTime 		= CreateConVar(	PLUGIN_NAME ... "_time", 		  "18:00~22:59",    "檢測的時間段, 寫法xx:xx~xx:xx (二十四小時制), 寫多時間段請用逗號區隔", CVAR_FLAGS);
    g_hCvarCount        = CreateConVar(	PLUGIN_NAME ... "_count", 		  "3",              "檢測 survivor_limit + infected 空位 <= 此數值之時，強制執行sm_resetmatch, 卸載模式", CVAR_FLAGS, true, 1.0, true, 32.0);
    g_hCvarFlag         = CreateConVar(	PLUGIN_NAME ... "_flag", 		  "b",              "有這權限的管理員在場就不會被強制卸載模式", CVAR_FLAGS);
    g_hCvarDelay        = CreateConVar(	PLUGIN_NAME ... "_delay", 		  "60.0",           "地圖載入此秒數後才會檢測時間與人數", CVAR_FLAGS, true, 0.0);
    CreateConVar(                       PLUGIN_NAME ... "_version",       PLUGIN_VERSION, PLUGIN_NAME ... " Plugin Version", CVAR_FLAGS_PLUGIN_VERSION);
    //AutoExecConfig(true,                PLUGIN_NAME);

    GetCvars();
    GetTimeCvars();
    survivor_limit.AddChangeHook(ConVarChanged_Cvars);
    z_max_player_zombies.AddChangeHook(ConVarChanged_Cvars);
    g_hCvarEnable.AddChangeHook(ConVarChanged_Cvars);
    g_hCvarTime.AddChangeHook(ConVarChanged_TimeCvars);
    g_hCvarCount.AddChangeHook(ConVarChanged_TimeCvars);
    g_hCvarFlag.AddChangeHook(ConVarChanged_TimeCvars);
    g_hCvarDelay.AddChangeHook(ConVarChanged_TimeCvars);

    HookEvent("round_start",            Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_spawn",           Event_PlayerSpawn);
    HookEvent("round_end",				Event_RoundEnd,		EventHookMode_PostNoCopy); //trigger twice in versus/survival/scavenge mode, one when all survivors wipe out or make it to saferom, one when first round ends (second round_start begins).
    HookEvent("map_transition", 		Event_RoundEnd,		EventHookMode_PostNoCopy); //1. all survivors make it to saferoom in and server is about to change next level in coop mode (does not trigger round_end), 2. all survivors make it to saferoom in versus
    HookEvent("mission_lost", 			Event_RoundEnd,		EventHookMode_PostNoCopy); //all survivors wipe out in coop mode (also triggers round_end)
    HookEvent("finale_vehicle_leaving", Event_RoundEnd,		EventHookMode_PostNoCopy); //final map final rescue vehicle leaving  (does not trigger round_end)

    HookEvent("player_team",            Event_PlayerTeam);
}

// Cvars-------------------------------

void ConVarChanged_Cvars(ConVar hCvar, const char[] sOldVal, const char[] sNewVal)
{
	GetCvars();
}

void ConVarChanged_TimeCvars(ConVar hCvar, const char[] sOldVal, const char[] sNewVal)
{
    GetCvars();
    GetTimeCvars();
}

void GetCvars()
{
    g_iCvarSurvivorLimit = survivor_limit.IntValue;
    g_iCvarInfectedMax = z_max_player_zombies.IntValue;

    g_bCvarEnable = g_hCvarEnable.BoolValue;
    g_hCvarTime.GetString(g_sCvarime, sizeof(g_sCvarime));
    g_iCvarCount = g_hCvarCount.IntValue;
    g_hCvarFlag.GetString(g_sCvarFlag, sizeof(g_sCvarFlag));
    g_fCvarDelay = g_hCvarDelay.FloatValue;
}

void GetTimeCvars()
{
    delete g_aTimeList;
    g_aTimeList = new ArrayList(sizeof(ETimeData));

    char sCvarimeCopy[128], sTime[12];
    FormatEx(sCvarimeCopy, sizeof(sCvarimeCopy), "%s", g_sCvarime);
    int index = SplitString(sCvarimeCopy, ",", sTime, sizeof(sTime));
    if(index >= 0)
    {
        do
        {
            //LogError("Time: %s, index: %d", sTime, index);
            ETimeData eTimeData;
            ConvertStringTimeToInt(sTime, eTimeData);
            g_aTimeList.PushArray(eTimeData);

            FormatEx(sCvarimeCopy, sizeof(sCvarimeCopy), "%s", sCvarimeCopy[index]);
            index = SplitString(sCvarimeCopy, ",", sTime, sizeof(sTime));
        }
        while(index != -1);
    }

    //LogError("last Time: %s", sCvarimeCopy);
    ETimeData eTimeData;
    ConvertStringTimeToInt(sCvarimeCopy, eTimeData);
    g_aTimeList.PushArray(eTimeData);
}

// Sourcemod API Forward-------------------------------

public void OnMapStart()
{
    g_iRoundCounter = 1;
}

public void OnMapEnd()
{
    ClearDefault();
    ResetTimer();

    g_bPluginStart = false;
}

// Event-------------------------------

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) 
{
    if( g_iRoundCounter != 1) return;
    g_iRoundCounter++;

    if( g_iPlayerSpawn == 1 && g_iRoundStart == 0 )
        CreateTimer(0.5, Timer_PluginStart, _, TIMER_FLAG_NO_MAPCHANGE);
    g_iRoundStart = 1;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{ 
    if( g_iPlayerSpawn == 0 && g_iRoundStart == 1 )
        CreateTimer(0.5, Timer_PluginStart, _, TIMER_FLAG_NO_MAPCHANGE);
    g_iPlayerSpawn = 1;
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) 
{
    ClearDefault();
    ResetTimer();          // ← 必须停掉
    g_bPluginStart = false; // ← 暂停检测，等下个回合再启动
}


void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) 
{
    if(!g_bCvarEnable || !g_bPluginStart || g_hDetectTimer != null) return;

    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client && IsClientInGame(client) && !IsFakeClient(client))
    {
        delete g_hDetectTimer; 
        g_hDetectTimer = CreateTimer(1.0, Timer_DetectPlayerCount);
    }
}

// Timer & Frame-------------------------------

Action Timer_PluginStart(Handle timer)
{
    ClearDefault();

    delete g_hDetectTimer; 
    g_hDetectTimer = CreateTimer(g_fCvarDelay, Timer_DetectPlayerCount);

    g_bPluginStart = true;

    return Plugin_Continue;
}

Action Timer_DetectPlayerCount(Handle timer)
{
    g_hDetectTimer = null;

    if(!g_bCvarEnable)
        return Plugin_Continue;
    
    if(g_iCvarSurvivorLimit + GetInfectedSlots() > g_iCvarCount) 
        return Plugin_Continue;

    bool bIsInCvarTime = false;
    ETimeData eTimeData;
    static char sSystemTimeHour[4], sSystemTimeMin[4];
    int iSystemTimeHour, iSystemTimeMin;
    FormatTime(sSystemTimeHour, sizeof(sSystemTimeHour), "%H", GetTime());
    FormatTime(sSystemTimeMin, sizeof(sSystemTimeMin), "%M", GetTime());
    iSystemTimeHour = StringToInt(sSystemTimeHour);
    iSystemTimeMin = StringToInt(sSystemTimeMin);
    for(int i = 0; i < g_aTimeList.Length; i++)
    {
        g_aTimeList.GetArray(i, eTimeData);
        if(IsBetweenTime(iSystemTimeHour, iSystemTimeMin, eTimeData))
        {
            bIsInCvarTime = true;
            break;
        }
    }

    if(!bIsInCvarTime)
        return Plugin_Continue;

    if (IsAnyAdminOnline())
        return Plugin_Continue;

    ServerCommand("sm_resetmatch");
    CPrintToChatAll("管理员不在场，此时间段模式人数不足 {green}%d{default} 人，{green}强制卸载模式!!!!", g_iCvarCount);
   
    return Plugin_Continue;
}

bool IsAnyAdminOnline()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (HasAccess(i, g_sCvarFlag)) return true;
    }
    return false;
}
// Function-------------------------------

void ConvertStringTimeToInt(char[] sTime, ETimeData eTimeData)
{
	static char sTwoTime[2][6], sStartTime[2][3], sEndTime[2][3];
	if(ExplodeString(sTime, "~", sTwoTime, 2, sizeof(sTwoTime[])) != 2)
	{
		LogError("Convar \"_time\" %s error", sTime);
		return;
	}

	if(ExplodeString(sTwoTime[0], ":", sStartTime, 2, sizeof(sStartTime[])) != 2)
	{
		LogError("Convar \"_time\" %s error", sTime);
		return;
	}

	eTimeData.m_iCvarStartHour = StringToInt(sStartTime[0]);
	eTimeData.m_iCvarStartMin = StringToInt(sStartTime[1]);

	if(ExplodeString(sTwoTime[1], ":", sEndTime, 2, sizeof(sEndTime[])) != 2)
	{
		LogError("Convar \"_time\" %s error", sTime);
		return;
	}

	eTimeData.m_iCvarEndHour = StringToInt(sEndTime[0]);
	eTimeData.m_iCvarEndMin = StringToInt(sEndTime[1]);
}

bool IsBetweenTime(int sysH, int sysM, ETimeData d)
{
    int sys  = sysH*60 + sysM;
    int beg  = d.m_iCvarStartHour*60 + d.m_iCvarStartMin;
    int end  = d.m_iCvarEndHour*60   + d.m_iCvarEndMin;

    if (beg == end) return true;                 // 覆盖整天
    if (beg < end)  return (sys >= beg && sys <= end);
    // 跨零点
    return (sys >= beg || sys <= end);
}

// Others-------------------------------

bool IsAnne()
{
    char plugin_name[256];
    ConVar cvar_mode = FindConVar("l4d_ready_cfg_name");
    if(cvar_mode == null) return false;
    cvar_mode.GetString(plugin_name, sizeof(plugin_name));

    if(StrContains(plugin_name, "AnneHappy", false) != -1 
        || StrContains(plugin_name, "AllCharger", false) != -1 
        || StrContains(plugin_name, "1vHunters", false) != -1 
        || StrContains(plugin_name, "WitchParty", false) != -1
        || StrContains(plugin_name, "Alone", false) != -1)
    {
        return true;
    }

    return false;
}

int GetInfectedSlots()
{
    if(IsAnne())
    {
        return 0;
    }
    else
    {
        return g_iCvarInfectedMax;
    }
}

void ClearDefault()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;
}

void ResetTimer()
{
    delete g_hDetectTimer;
}

bool HasAccess(int client, char[] sAcclvl)
{
	// no permissions set
	if (strlen(sAcclvl) == 0)
		return true;

	else if (StrEqual(sAcclvl, "-1"))
		return false;

	// check permissions
	int flag = GetUserFlagBits(client);
	if ( flag & ReadFlagString(sAcclvl) || flag & ADMFLAG_ROOT )
	{
		return true;
	}

	return false;
}