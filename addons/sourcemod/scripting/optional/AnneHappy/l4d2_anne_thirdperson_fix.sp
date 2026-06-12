#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.1.1"
#define DEFAULT_CFG_NAMES "AnneHappy,AllCharger,WitchParty,Alone,1vHunters"
#define EXTERNAL_VIEW_TIME 99999.3

ConVar g_cvEnabled;
ConVar g_cvCommands;
ConVar g_cvSpoofGameMode;
ConVar g_cvFakeGameMode;
ConVar g_cvCfgNames;
ConVar g_cvDebug;
ConVar g_cvMPGameMode;
ConVar g_cvReadyCfgName;

bool g_bThirdPerson[MAXPLAYERS + 1];
bool g_bHookedReadyCfgName;

public Plugin myinfo =
{
	name = "Anne Thirdperson Shoulder Fix",
	author = "morzlee, OpenAI",
	description = "Keeps thirdperson available in Anne versus-based configs.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
	CreateConVar("l4d2_anne_thirdperson_fix_version", PLUGIN_VERSION, "Anne thirdperson shoulder fix version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnabled = CreateConVar("l4d2_anne_thirdperson_fix_enabled", "1", "0=Off, 1=enable Anne thirdperson fixes when l4d_ready_cfg_name matches.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCommands = CreateConVar("l4d2_anne_thirdperson_fix_commands", "1", "0=Off, 1=enable !tp/!third commands using m_TimeForceExternalView.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpoofGameMode = CreateConVar("l4d2_anne_thirdperson_fix_spoof_gamemode", "1", "0=Off, 1=send a coop-like mp_gamemode value only to clients so native thirdpersonshoulder can work.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvFakeGameMode = CreateConVar("l4d2_anne_thirdperson_fix_fake_gamemode", "coop", "mp_gamemode value sent only to clients while the server keeps its real value. Empty disables spoofing.", FCVAR_NOTIFY);
	g_cvCfgNames = CreateConVar("l4d2_anne_thirdperson_fix_cfg_names", DEFAULT_CFG_NAMES, "Comma-separated l4d_ready_cfg_name fragments that enable this fix. Empty enables all configs.", FCVAR_NOTIFY);
	g_cvDebug = CreateConVar("l4d2_anne_thirdperson_fix_debug", "0", "0=Off, 1=log client spoof/restore operations.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvMPGameMode = FindConVar("mp_gamemode");
	g_cvReadyCfgName = FindConVar("l4d_ready_cfg_name");

	if (g_cvMPGameMode == null)
	{
		SetFailState("Failed to find mp_gamemode.");
	}

	HookConVarChange(g_cvEnabled, OnControlCvarChanged);
	HookConVarChange(g_cvCommands, OnControlCvarChanged);
	HookConVarChange(g_cvSpoofGameMode, OnControlCvarChanged);
	HookConVarChange(g_cvFakeGameMode, OnControlCvarChanged);
	HookConVarChange(g_cvCfgNames, OnControlCvarChanged);
	HookConVarChange(g_cvMPGameMode, OnControlCvarChanged);

	if (g_cvReadyCfgName != null)
	{
		HookConVarChange(g_cvReadyCfgName, OnControlCvarChanged);
		g_bHookedReadyCfgName = true;
	}

	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("charger_impact", Event_ChargerImpact);

	RegConsoleCmd("sm_tp", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson view.");
	RegConsoleCmd("sm_third", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson view.");
	RegConsoleCmd("sm_thirdperson", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson view.");
	RegConsoleCmd("sm_3rd", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson view.");
	RegConsoleCmd("sm_3rdon", Cmd_ThirdPersonOn, "Enable Anne thirdperson view.");
	RegConsoleCmd("sm_3rdoff", Cmd_ThirdPersonOff, "Disable Anne thirdperson view.");
	RegAdminCmd("sm_anne_thirdperson_status", Cmd_Status, ADMFLAG_ROOT, "Show Anne thirdperson shoulder fix status.");

	QueueApplyAll(0.2);
}

public void OnConfigsExecuted()
{
	RefreshOptionalConVars();
	QueueApplyAll(0.2);
}

public void OnMapStart()
{
	RefreshOptionalConVars();
	ResetThirdPersonState();
	QueueApplyAll(1.0);
}

public void OnMapEnd()
{
	ResetThirdPersonState();
}

public void OnClientPutInServer(int client)
{
	g_bThirdPerson[client] = false;

	if (IsFakeClient(client))
	{
		return;
	}

	int userid = GetClientUserId(client);
	CreateTimer(1.0, Timer_ApplyClient, userid, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(3.0, Timer_ApplyClient, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
	g_bThirdPerson[client] = false;
}

public void OnPluginEnd()
{
	RestoreAllClients();
	ResetThirdPersonState();
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!ShouldAllowCommands())
	{
		ResetThirdPersonState();
	}

	QueueApplyAll(0.2);
}

Action Timer_ApplyAll(Handle timer)
{
	ApplyAllClients();
	return Plugin_Stop;
}

Action Timer_ApplyClient(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (IsHumanClient(client))
	{
		ApplyClient(client);
	}

	return Plugin_Stop;
}

Action Timer_ReapplyThirdPerson(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (IsHumanClient(client) && g_bThirdPerson[client] && IsPlayerAlive(client))
	{
		SetExternalView(client, true);
	}

	return Plugin_Stop;
}

Action Cmd_Status(int client, int args)
{
	char actual[32];
	char fake[32];
	char cfgName[128];
	char cfgNames[256];

	GetActualGameMode(actual, sizeof(actual));
	GetFakeGameMode(fake, sizeof(fake));
	GetReadyCfgName(cfgName, sizeof(cfgName));
	GetAllowedCfgNames(cfgNames, sizeof(cfgNames));

	ReplyToCommand(client, "[AnneThirdperson] active=%d commands=%d spoof=%d enabled=%d actual_mp_gamemode=\"%s\" fake=\"%s\"", ShouldAllowAnneFix() ? 1 : 0, ShouldAllowCommands() ? 1 : 0, ShouldSpoofClients() ? 1 : 0, g_cvEnabled.BoolValue ? 1 : 0, actual, fake);
	ReplyToCommand(client, "[AnneThirdperson] ready_cfg=\"%s\" cfg_names=\"%s\"", cfgName, cfgNames);
	return Plugin_Handled;
}

Action Cmd_ToggleThirdPerson(int client, int args)
{
	if (!CanUseThirdPerson(client))
	{
		return Plugin_Handled;
	}

	SetThirdPerson(client, !g_bThirdPerson[client]);
	return Plugin_Handled;
}

Action Cmd_ThirdPersonOn(int client, int args)
{
	if (!CanUseThirdPerson(client))
	{
		return Plugin_Handled;
	}

	SetThirdPerson(client, true);
	return Plugin_Handled;
}

Action Cmd_ThirdPersonOff(int client, int args)
{
	if (IsHumanClient(client))
	{
		SetThirdPerson(client, false);
	}

	return Plugin_Handled;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		g_bThirdPerson[client] = false;
		if (IsClientInGame(client))
		{
			SetExternalView(client, false);
		}
	}
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsHumanClient(client))
	{
		SetThirdPerson(client, false, true);
	}
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetThirdPersonState();
}

void Event_ChargerImpact(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("victim"));
	if (IsHumanClient(client) && g_bThirdPerson[client])
	{
		CreateTimer(0.2, Timer_ReapplyThirdPerson, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

void QueueApplyAll(float delay)
{
	CreateTimer(delay, Timer_ApplyAll, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ApplyAllClients()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHumanClient(client))
		{
			ApplyClient(client);
		}
	}
}

void ApplyClient(int client)
{
	char value[32];
	bool spoof = ShouldSpoofClients();

	if (spoof)
	{
		GetFakeGameMode(value, sizeof(value));
	}
	else
	{
		GetActualGameMode(value, sizeof(value));
	}

	g_cvMPGameMode.ReplicateToClient(client, value);

	if (g_cvDebug.BoolValue)
	{
		PrintToServer("[AnneThirdperson] %s mp_gamemode=\"%s\" to %N", spoof ? "spoofed" : "restored", value, client);
	}
}

void RestoreAllClients()
{
	if (g_cvMPGameMode == null)
	{
		return;
	}

	char actual[32];
	GetActualGameMode(actual, sizeof(actual));

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHumanClient(client))
		{
			g_cvMPGameMode.ReplicateToClient(client, actual);
		}
	}
}

bool ShouldSpoofClients()
{
	if (!ShouldAllowAnneFix() || !g_cvSpoofGameMode.BoolValue)
	{
		return false;
	}

	char actual[32];
	GetActualGameMode(actual, sizeof(actual));
	if (!StrEqual(actual, "versus", false))
	{
		return false;
	}

	char fake[32];
	GetFakeGameMode(fake, sizeof(fake));
	if (fake[0] == '\0' || StrEqual(fake, actual, false))
	{
		return false;
	}

	return true;
}

bool ShouldAllowCommands()
{
	return ShouldAllowAnneFix() && g_cvCommands.BoolValue;
}

bool ShouldAllowAnneFix()
{
	if (!g_cvEnabled.BoolValue)
	{
		return false;
	}

	char cfgName[128];
	GetReadyCfgName(cfgName, sizeof(cfgName));
	if (cfgName[0] == '\0')
	{
		return false;
	}

	return ReadyCfgMatches(cfgName);
}

bool ReadyCfgMatches(const char[] cfgName)
{
	char cfgNames[256];
	GetAllowedCfgNames(cfgNames, sizeof(cfgNames));
	if (cfgNames[0] == '\0')
	{
		return true;
	}

	char tokens[16][64];
	int count = ExplodeString(cfgNames, ",", tokens, sizeof(tokens), sizeof(tokens[]));
	for (int i = 0; i < count; i++)
	{
		TrimString(tokens[i]);
		if (tokens[i][0] != '\0' && StrContains(cfgName, tokens[i], false) != -1)
		{
			return true;
		}
	}

	return false;
}

bool CanUseThirdPerson(int client)
{
	if (!IsHumanClient(client))
	{
		return false;
	}

	if (!ShouldAllowCommands())
	{
		PrintToChat(client, "[AnneThirdperson] Thirdperson is not enabled in this config.");
		return false;
	}

	if (!IsPlayerAlive(client) || GetClientTeam(client) != 2)
	{
		PrintToChat(client, "[AnneThirdperson] Survivors can use this while alive.");
		return false;
	}

	return true;
}

void SetThirdPerson(int client, bool enable, bool silent = false)
{
	if (!IsHumanClient(client))
	{
		return;
	}

	g_bThirdPerson[client] = enable;
	SetExternalView(client, enable);

	if (!silent)
	{
		PrintToChat(client, "[AnneThirdperson] Thirdperson %s.", enable ? "ON" : "OFF");
	}
}

void SetExternalView(int client, bool enable)
{
	SetEntPropFloat(client, Prop_Send, "m_TimeForceExternalView", enable ? EXTERNAL_VIEW_TIME : 0.0);
}

void ResetThirdPersonState()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		g_bThirdPerson[client] = false;
		if (IsClientInGame(client))
		{
			SetExternalView(client, false);
		}
	}
}

void RefreshOptionalConVars()
{
	if (g_cvReadyCfgName == null)
	{
		g_cvReadyCfgName = FindConVar("l4d_ready_cfg_name");
		if (g_cvReadyCfgName != null && !g_bHookedReadyCfgName)
		{
			HookConVarChange(g_cvReadyCfgName, OnControlCvarChanged);
			g_bHookedReadyCfgName = true;
		}
	}
}

void GetActualGameMode(char[] buffer, int maxlen)
{
	g_cvMPGameMode.GetString(buffer, maxlen);
	TrimString(buffer);
}

void GetFakeGameMode(char[] buffer, int maxlen)
{
	g_cvFakeGameMode.GetString(buffer, maxlen);
	TrimString(buffer);
}

void GetAllowedCfgNames(char[] buffer, int maxlen)
{
	g_cvCfgNames.GetString(buffer, maxlen);
	TrimString(buffer);
}

void GetReadyCfgName(char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	RefreshOptionalConVars();
	if (g_cvReadyCfgName == null)
	{
		return;
	}

	g_cvReadyCfgName.GetString(buffer, maxlen);
	TrimString(buffer);
}

bool IsHumanClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}
