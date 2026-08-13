#pragma semicolon 1
#pragma newdecls required
#pragma tabsize 0
#include <sourcemod>
#include <colors>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <SteamWorks>
#define IsValidClient(%1)		(1 <= %1 <= MaxClients && IsClientInGame(%1))

//#include <smlib>
//#define PLUGIN_VERSION	"2022-08"
ConVar
	g_hCvarInfectedTime,
	g_hCvarInfectedLimit,
	g_hCvarTankBhop,
	g_hCvarWeapon,
	g_hCvarCoop,
	g_hCvarPluginVersion,
	g_hCvarAiDynamicEnable,
	g_hCvarAiCurrentLevel,
	g_hCvarAiCurrentMode,
	g_hCvarAiFixedLevel;

int 
	CommonLimit,
	CommonTime,
	TankBhop,
	Weapon,
	MaxPlayers;
char PLUGIN_VERSION[32];

public void OnPluginStart()
{
	LoadTranslations("text.phrases");
	g_hCvarInfectedTime = FindConVar("versus_special_respawn_interval");
	g_hCvarInfectedLimit = FindConVar("l4d_infected_limit");
	g_hCvarTankBhop = FindConVar("ai_Tank_Bhop");
	RefreshDynamicAiCvars();
	g_hCvarWeapon = CreateConVar("ZonemodWeapon", "0", "", 0, false, 0.0, false, 0.0);
	g_hCvarPluginVersion = CreateConVar("AnnePluginVersion", "Latest", "Anne插件版本");
	if(g_hCvarInfectedTime != null)
		HookConVarChange(g_hCvarInfectedTime, Cvar_InfectedTime);
	if(g_hCvarInfectedLimit != null)
		HookConVarChange(g_hCvarInfectedLimit, Cvar_InfectedLimit);
	if(g_hCvarTankBhop != null)
		HookConVarChange(g_hCvarTankBhop, CvarTankBhop);
	HookConVarChange(g_hCvarWeapon, CvarWeapon);
	HookConVarChange(g_hCvarPluginVersion, CvarPluginVersion);
	if(g_hCvarInfectedTime != null)
		CommonTime = GetConVarInt(g_hCvarInfectedTime);
	if(g_hCvarInfectedLimit != null)
		CommonLimit = GetConVarInt(g_hCvarInfectedLimit);
	if(g_hCvarTankBhop != null)
		TankBhop = GetConVarInt(g_hCvarTankBhop);
	Weapon = GetConVarInt(g_hCvarWeapon);
	RegConsoleCmd("sm_xx",InfectedStatus);
	g_hCvarCoop = CreateConVar("coopmode", "0");
	HookEvent("player_incapacitated_start", Incap_Event, EventHookMode_Post);
	HookEvent("player_incapacitated", Incap_Event, EventHookMode_Post);
	HookEvent("round_start", event_RoundStart);
	HookEvent("player_death", player_death, EventHookMode_Post);
	RegAdminCmd("sm_killall", killall, ADMFLAG_BAN, "处死所有玩家");
}

public void OnAllPluginsLoaded()
{
	RefreshDynamicAiCvars();
}

public void OnPluginEnd()
{
	g_hCvarWeapon.RestoreDefault();
}

public Action player_death(Handle event, char[] name, bool dontBroadcast)
{
	if(IsTeamImmobilised())
	{
		SlaySurvivors();
	}
	return Plugin_Continue;
}

public Action killall(int client, int args)
{
	if(IsValidClient(client) && GetClientTeam(client) == 2)
		SlaySurvivors();
	return Plugin_Handled;
}

public void SlaySurvivors() { //incap everyone
	for(int i=1; i<=MaxClients ; i++)
		if(IsValidPlayer(i,true,false) && GetClientTeam(i)==2)
			ForcePlayerSuicide(i);
}

public void Incap_Event(Handle event, char[] name, bool dontBroadcast)
{
	int  Incap = GetClientOfUserId(GetEventInt(event, "userid"));
	if(GetConVarBool(g_hCvarCoop))
	{
		ForcePlayerSuicide(Incap);
	}
	if(IsTeamImmobilised())
	{
		SlaySurvivors();
	}
}


//离开安全门重新加载插件（理论上不应该在此插件完成）
public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
	ServerCommand("sm_startspawn");
	return Plugin_Continue;
}
public void Cvar_InfectedTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CommonTime = GetConVarInt(g_hCvarInfectedTime);
}
public void Cvar_InfectedLimit(ConVar convar, const char[] oldValue, const char[] newValue)
{
	CommonLimit = GetConVarInt(g_hCvarInfectedLimit);
	char tags[64];
	tags[0] = '\0';
	ConVar readyCfgName = FindConVar("l4d_ready_cfg_name");
	if(readyCfgName != null)
		GetConVarString(readyCfgName, tags, sizeof(tags));
	if (Weapon == 2 && CommonLimit< 10 && ( StrContains(tags, "WitchParty", false) != -1 || StrContains(tags, "AllCharger", false) != -1 || StrContains(tags, "AnneHappy", false) != -1))
	{
		ServerCommand("sm_cvar ZonemodWeapon 0");
		CPrintToChatAll("%t", "Text_NotExceed10SpecialAnne");
	}
}
public void CvarTankBhop(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(g_hCvarTankBhop != null)
		TankBhop = GetConVarInt(g_hCvarTankBhop);
}

public void CvarPluginVersion(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Format(PLUGIN_VERSION, sizeof(PLUGIN_VERSION), "%s", newValue);
	//strcopy(PLUGIN_VERSION, sizeof(PLUGIN_VERSION), newValue);
}


public void CvarWeapon(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Weapon = GetConVarInt(g_hCvarWeapon);
	char tags[64];
	tags[0] = '\0';
	ConVar readyCfgName = FindConVar("l4d_ready_cfg_name");
	if(readyCfgName != null)
		GetConVarString(readyCfgName, tags, sizeof(tags));
	if (Weapon == 1)
	{
		ServerCommand("exec vote/weapon/zonemod.cfg");
	}
	else if (Weapon == 0)
	{
		ServerCommand("exec vote/weapon/AnneHappy.cfg");
	}
	else if (Weapon == 2)
	{
		if(CommonLimit >= 10 || (StrContains(tags, "Alone", false) != -1) || (StrContains(tags, "1vHunters", false) != -1))
			ServerCommand("exec vote/weapon/AnneHappyPlus.cfg");
		else
		{
			CPrintToChatAll("%t", "Text_CannotUseAnneHappyPlus");
			ServerCommand("sm_cvar ZonemodWeapon 0");
		}
			
	}
}


void printinfo(int client = 0, bool All = true)
{
	if(All)
	{
		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsClientInGame(i) && (!IsFakeClient(i) || IsClientSourceTV(i)))
				PrintInfoToClient(i);
		}
		PrintTraitorStatus();
		return;
	}

	PrintInfoToClient(client);
	PrintTraitorStatus(client, false);
}

void AppendChatPart(char[] buffer, int maxlen, const char[] part)
{
	if(part[0] == '\0')
		return;
	if(buffer[0] == '\0')
		strcopy(buffer, maxlen, part);
	else
		Format(buffer, maxlen, "%s %s", buffer, part);
}

void PrintInfoToClient(int client)
{
	if(!IsValidClient(client))
		return;

	SetGlobalTransTarget(client);

	char line1[384];
	char line2[256];
	char line3[384];
	char part[192];
	char weaponName[16];
	char spawnMode[32];
	line1[0] = '\0';
	line3[0] = '\0';

	if(g_hCvarTankBhop != null)
		FormatEx(line1, sizeof(line1), "%t", TankBhop > 0 ? "Text_TankBhopOn" : "Text_TankBhopOff");

	strcopy(weaponName, sizeof(weaponName), Weapon > 1 ? "Anne+" : (Weapon > 0 ? "Zone" : "Anne"));
	FormatEx(part, sizeof(part), "%t", "Text_Weapon", weaponName);
	AppendChatPart(line1, sizeof(line1), part);

	if(BuildAiDifficultyText(client, part, sizeof(part)))
		AppendChatPart(line1, sizeof(line1), part);

	if(PLUGIN_VERSION[0] == '\0')
		GetConVarString(g_hCvarPluginVersion, PLUGIN_VERSION, sizeof(PLUGIN_VERSION));

	ConVar autoSpawnTimeControl = FindConVar("inf_EnableAutoSpawnTime");
	FormatEx(spawnMode, sizeof(spawnMode), "%T",
		(autoSpawnTimeControl != null && autoSpawnTimeControl.BoolValue) ? "Text_SpawnAuto" : "Text_SpawnFixed",
		client);
	FormatEx(line2, sizeof(line2), "%t", "Text_SpecialInfected", spawnMode, CommonLimit, CommonTime, PLUGIN_VERSION);

	ConVar spawnDistanceMin = FindConVar("inf_SpawnDistanceMin");
	if(spawnDistanceMin != null)
	{
		FormatEx(part, sizeof(part), "%t", "Text_SpawnDistanceMin", GetConVarInt(spawnDistanceMin));
		AppendChatPart(line3, sizeof(line3), part);
	}

	ConVar teleportCheckTime = FindConVar("inf_TeleportCheckTime");
	if(teleportCheckTime != null)
	{
		FormatEx(part, sizeof(part), "%t", "Text_TeleportUnseen", GetConVarInt(teleportCheckTime));
		AppendChatPart(line3, sizeof(line3), part);
	}

	ConVar returnBlood = FindConVar("ReturnBlood");
	if(returnBlood != null && GetConVarInt(returnBlood) > 0)
	{
		FormatEx(part, sizeof(part), "%t", "Text_ReturnBloodOn");
		AppendChatPart(line3, sizeof(line3), part);
	}

	ConVar tankConsume = FindConVar("ai_TankConsume");
	ConVar tankSneakTime = FindConVar("ai_TankSneakTime");
	if(tankConsume != null && GetConVarInt(tankConsume) > 0)
	{
		FormatEx(part, sizeof(part), "%t", "Text_TankConsumeOn");
		AppendChatPart(line3, sizeof(line3), part);
	}
	else if(tankSneakTime != null && GetConVarFloat(tankSneakTime) > 0.0)
	{
		FormatEx(part, sizeof(part), "%t", "Text_SneakyTankOn");
		AppendChatPart(line3, sizeof(line3), part);
	}

	CPrintToChat(client, "%s", line1);
	CPrintToChat(client, "%s", line2);
	if(line3[0] != '\0')
		CPrintToChat(client, "%s", line3);
}

void PrintTraitorStatus(int client = 0, bool all = true)
{
	if(!AnneVersionSupportsTraitor())
		return;

	ConVar traitorEnable = FindConVar("inf_traitor_enable");
	ConVar traitorMaxSlots = FindConVar("inf_traitor_max_slots");
	if(traitorEnable == null || traitorMaxSlots == null)
		return;

	char phrase[64];
	strcopy(phrase, sizeof(phrase), traitorEnable.BoolValue
		? "Text_TraitorStatusEnabled"
		: "Text_TraitorStatusDisabled");
	if(!TranslationPhraseExists(phrase))
		return;

	int slots = traitorMaxSlots.IntValue;
	if(all)
		CPrintToChatAll("%t", phrase, slots);
	else if(client >= 1 && client <= MaxClients && IsClientInGame(client))
		CPrintToChat(client, "%t", phrase, slots);
}

bool AnneVersionSupportsTraitor()
{
	if(g_hCvarPluginVersion == null)
		return false;

	char version[32];
	g_hCvarPluginVersion.GetString(version, sizeof(version));
	TrimString(version);
	if(StrEqual(version, "Latest", false))
		return true;

	ReplaceString(version, sizeof(version), ".", "-");
	ReplaceString(version, sizeof(version), "/", "-");

	char parts[3][12];
	if(ExplodeString(version, "-", parts, sizeof(parts), sizeof(parts[])) < 2)
		return false;

	int year = StringToInt(parts[0]);
	int month = StringToInt(parts[1]);
	if(year > 0 && year < 100)
		year += 2000;
	if(month < 1 || month > 12)
		return false;

	return year > 2026 || (year == 2026 && month >= 7);
}

void RefreshDynamicAiCvars()
{
	if(g_hCvarAiDynamicEnable == null)
		g_hCvarAiDynamicEnable = FindConVar("ah_ai_dynamic_enable");
	if(g_hCvarAiCurrentLevel == null)
		g_hCvarAiCurrentLevel = FindConVar("ah_ai_dynamic_current_level");
	if(g_hCvarAiCurrentMode == null)
		g_hCvarAiCurrentMode = FindConVar("ah_ai_dynamic_current_mode");
	if(g_hCvarAiFixedLevel == null)
		g_hCvarAiFixedLevel = FindConVar("ah_ai_dynamic_fixed_level");
}

bool BuildAiDifficultyText(int langClient, char[] buffer, int maxlen)
{
	RefreshDynamicAiCvars();

	if(g_hCvarAiCurrentLevel == null)
		return false;
	if(g_hCvarAiDynamicEnable != null && !g_hCvarAiDynamicEnable.BoolValue)
		return false;

	int level = g_hCvarAiCurrentLevel.IntValue;
	int mode = g_hCvarAiCurrentMode != null ? g_hCvarAiCurrentMode.IntValue : 0;
	int fixedLevel = g_hCvarAiFixedLevel != null ? g_hCvarAiFixedLevel.IntValue : 0;

	if(level <= 0 && fixedLevel > 0)
	{
		level = fixedLevel;
		mode = 1;
	}

	char modeName[16];
	char levelName[16];
	char levelPhrase[32];
	FormatEx(modeName, sizeof(modeName), "%T", mode > 0 ? "Text_AiModeFixed" : "Text_AiModeAuto", langClient);
	GetAiLevelPhrase(level, levelPhrase, sizeof(levelPhrase));
	FormatEx(levelName, sizeof(levelName), "%T", levelPhrase, langClient);
	FormatEx(buffer, maxlen, "%T", "Text_AiDifficulty", langClient, modeName, levelName);
	return true;
}

void GetAiLevelPhrase(int level, char[] buffer, int maxlen)
{
	switch(level)
	{
		case 1:
			strcopy(buffer, maxlen, "Text_AiLevelEasy");
		case 2:
			strcopy(buffer, maxlen, "Text_AiLevelNormal");
		case 3:
			strcopy(buffer, maxlen, "Text_AiLevelHard");
		case 4:
			strcopy(buffer, maxlen, "Text_AiLevelExpert");
		case 5:
			strcopy(buffer, maxlen, "Text_AiLevelExtreme");
		case 6:
			strcopy(buffer, maxlen, "Text_AiLevelNeri");
		default:
			strcopy(buffer, maxlen, "Text_AiLevelPending");
	}
}

public Action InfectedStatus(int Client, int args)
{ 
	printinfo(Client);
	return Plugin_Handled;
}
public void event_RoundStart(Handle event, char[] name, bool dontBroadcast)
{
	printinfo();
}
public void OnClientPutInServer(int Client)
{
	//FormatTime(sBuffer, sizeof(sBuffer), "%Y/%m/%d");
	if (IsValidPlayer(Client, false))
	{
		MaxPlayers ++ ;
		if(MaxPlayers == getBotLimit())
		{
			ConVar gjrj = FindConVar("sb_fix_enabled");
			if(gjrj != null && gjrj.BoolValue)
				SetConVarInt(gjrj, false);
		}
		printinfo(Client, false);
	}
}
stock bool IsValidPlayer(int Client, bool AllowBot = true, bool AllowDeath = true)
{
	if (Client < 1 || Client > MaxClients)
		return false;
	if (!IsClientConnected(Client) || !IsClientInGame(Client))
		return false;
	if (!AllowBot)
	{
		if (IsFakeClient(Client))
			return false;
	}

	if (!AllowDeath)
	{
		if (!IsPlayerAlive(Client))
			return false;
	}	
	return true;
}



bool IsTeamImmobilised() {
	//Check if there is still an upright survivor
	bool bIsTeamImmobilised = true;
	for (int client = 1; client < MaxClients; client++) {
		// If a survivor is found to be alive and neither pinned nor incapacitated
		// team is not immobilised.
		if (Survivor(client) && IsPlayerAlive(client) ) 
		{		
			if (!Incapacitated(client) ) 
			{		
				bIsTeamImmobilised = false;				
			} 
		}
	}
	return bIsTeamImmobilised;
}
stock bool Survivor(int i)
{
    return i > 0 && i <= MaxClients && IsClientInGame(i) && GetClientTeam(i) == 2;
}
stock bool Incapacitated(int client)
{
    bool bIsIncapped = false;
    if (Survivor(client)) 
	{
		if (GetEntProp(client, Prop_Send, "m_isIncapacitated") > 0) bIsIncapped = true;
		if (!IsPlayerAlive(client)) bIsIncapped = true;
	}
    return bIsIncapped;
}

stock int getBotLimit()
{
	return FindConVar("survivor_limit").IntValue;
}
