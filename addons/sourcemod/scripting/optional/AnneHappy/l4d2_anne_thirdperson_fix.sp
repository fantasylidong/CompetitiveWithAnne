#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.4.0"
#define DEFAULT_CFG_NAMES "AnneHappy,AllCharger,WitchParty,Alone,1vHunters"
#define COMMAND_DELAY 0.1

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
	description = "Enables !tp by spoofing mp_gamemode before client thirdpersonshoulder.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
	CreateConVar("l4d2_anne_thirdperson_fix_version", PLUGIN_VERSION, "Anne thirdperson shoulder fix version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnabled = CreateConVar("l4d2_anne_thirdperson_fix_enabled", "1", "0=Off, 1=enable Anne thirdperson fixes when l4d_ready_cfg_name matches.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCommands = CreateConVar("l4d2_anne_thirdperson_fix_commands", "1", "0=Off, 1=enable !tp/!third commands.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpoofGameMode = CreateConVar("l4d2_anne_thirdperson_fix_spoof_gamemode", "1", "0=Off, 1=spoof mp_gamemode before running thirdpersonshoulder for !tp.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvFakeGameMode = CreateConVar("l4d2_anne_thirdperson_fix_fake_gamemode", "coop", "mp_gamemode value sent only to the !tp client before enabling thirdpersonshoulder.", FCVAR_NOTIFY);
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
	HookEvent("player_team", Event_PlayerTeam);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);

	RegConsoleCmd("sm_tp", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson shoulder view.");
	RegConsoleCmd("sm_third", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson shoulder view.");
	RegConsoleCmd("sm_thirdperson", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson shoulder view.");
	RegConsoleCmd("sm_3rd", Cmd_ToggleThirdPerson, "Toggle Anne thirdperson shoulder view.");
	RegConsoleCmd("sm_3rdon", Cmd_ThirdPersonOn, "Enable Anne thirdperson shoulder view.");
	RegConsoleCmd("sm_3rdoff", Cmd_ThirdPersonOff, "Disable Anne thirdperson shoulder view.");
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
	ResetThirdPersonState(false);
	QueueApplyAll(1.0);
}

public void OnMapEnd()
{
	ResetThirdPersonState(false);
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
	ResetThirdPersonState(false);
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!ShouldAllowCommands())
	{
		ResetThirdPersonState(true);
		return;
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

Action Timer_RunThirdPersonShoulder(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (IsHumanClient(client))
	{
		ClientCommand(client, "thirdpersonshoulder");
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

	ReplyToCommand(client, "[AnneThirdperson] active=%d commands=%d spoof_ready=%d thirdperson_clients=%d enabled=%d actual_mp_gamemode=\"%s\" fake=\"%s\"", ShouldAllowAnneFix() ? 1 : 0, ShouldAllowCommands() ? 1 : 0, ShouldSpoofClients() ? 1 : 0, CountThirdPersonClients(), g_cvEnabled.BoolValue ? 1 : 0, actual, fake);
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
			ApplyClient(client);
		}
	}
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsHumanClient(client) && g_bThirdPerson[client])
	{
		SetThirdPerson(client, false, true);
	}
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (IsHumanClient(client) && g_bThirdPerson[client])
	{
		SetThirdPerson(client, false, true);
	}
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	ResetThirdPersonState(true);
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
	if (!IsHumanClient(client) || g_cvMPGameMode == null)
	{
		return;
	}

	char value[32];
	if (ShouldSpoofClient(client))
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
		PrintToServer("[AnneThirdperson] replicated mp_gamemode=\"%s\" to %N", value, client);
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
			g_bThirdPerson[client] = false;
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

bool ShouldSpoofClient(int client)
{
	return g_bThirdPerson[client] && ShouldSpoofClients() && IsPlayerAlive(client) && GetClientTeam(client) == 2;
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

	if (g_bThirdPerson[client] == enable)
	{
		if (!silent)
		{
			PrintToChat(client, "[AnneThirdperson] Thirdperson already %s.", enable ? "ON" : "OFF");
		}
		return;
	}

	g_bThirdPerson[client] = enable;
	ApplyClient(client);
	CreateTimer(COMMAND_DELAY, Timer_RunThirdPersonShoulder, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	if (!silent)
	{
		PrintToChat(client, "[AnneThirdperson] Thirdperson %s.", enable ? "ON" : "OFF");
	}
}

void ResetThirdPersonState(bool runClientCommand)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHumanClient(client) && g_bThirdPerson[client] && runClientCommand)
		{
			SetThirdPerson(client, false, true);
		}
		else
		{
			g_bThirdPerson[client] = false;
			if (IsClientInGame(client))
			{
				ApplyClient(client);
			}
		}
	}
}

int CountThirdPersonClients()
{
	int count;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHumanClient(client) && g_bThirdPerson[client])
		{
			count++;
		}
	}

	return count;
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
