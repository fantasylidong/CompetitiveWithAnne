#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define BUFFER_TIME 0.5

bool g_bBlocked[MAXPLAYERS + 1];
bool g_bPreThinkHooked[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "[L4D/2] Incap Fire Fix",
	author      = "Sir",
	description = "Lets incapacitated survivors fire their weapon normally (with sound) while holding shove",
	version     = "1.1.0",
	url         = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	HookEvent("player_incapacitated", Event_PlayerIncapacitated, EventHookMode_Post);
	HookEvent("revive_success", Event_ReviveSuccess, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerStopped, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("bot_player_replace", Event_PlayerReplaced, EventHookMode_Post);
	HookEvent("player_bot_replace", Event_PlayerReplaced, EventHookMode_Post);
	HookEvent("round_start", Event_RoundState, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundState, EventHookMode_PostNoCopy);

	SyncAllClients();
}

public void OnMapEnd()
{
	StopAllTracking(false);
}

public void OnPluginEnd()
{
	StopAllTracking(true);
}

public void OnClientPutInServer(int client)
{
	g_bBlocked[client] = false;
	g_bPreThinkHooked[client] = false;
	QueueClientSync(GetClientUserId(client));
}

public void OnClientDisconnect(int client)
{
	StopClientTracking(client, false);
}

void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast)
{
	QueueClientSync(event.GetInt("userid"));
}

void Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
	StopClientTracking(GetClientOfUserId(event.GetInt("subject")), true);
}

void Event_PlayerStopped(Event event, const char[] name, bool dontBroadcast)
{
	StopClientTracking(GetClientOfUserId(event.GetInt("userid")), true);
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);

	if (event.GetInt("team") == 2)
		QueueClientSync(userid);
	else
		StopClientTracking(client, true);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	QueueClientSync(event.GetInt("userid"));
}

void Event_PlayerReplaced(Event event, const char[] name, bool dontBroadcast)
{
	QueueClientSync(event.GetInt("player"));
	QueueClientSync(event.GetInt("bot"));
}

void Event_RoundState(Event event, const char[] name, bool dontBroadcast)
{
	StopAllTracking(true);
}

void QueueClientSync(int userid)
{
	if (userid > 0)
		RequestFrame(Frame_SyncClient, userid);
}

void Frame_SyncClient(any userid)
{
	SyncClient(GetClientOfUserId(userid));
}

void SyncAllClients()
{
	for (int client = 1; client <= MaxClients; client++)
		SyncClient(client);
}

void SyncClient(int client)
{
	if (IsIncapacitatedSurvivor(client))
		StartClientTracking(client);
	else
		StopClientTracking(client, true);
}

void StartClientTracking(int client)
{
	if (g_bPreThinkHooked[client])
		return;

	SDKHook(client, SDKHook_PreThink, OnIncapacitatedPreThink);
	g_bPreThinkHooked[client] = true;
}

void StopClientTracking(int client, bool restoreWeapon)
{
	if (client < 1 || client > MaxClients)
		return;

	if (g_bPreThinkHooked[client])
	{
		if (IsClientInGame(client))
			SDKUnhook(client, SDKHook_PreThink, OnIncapacitatedPreThink);

		g_bPreThinkHooked[client] = false;
	}

	if (restoreWeapon)
		RestoreSecondaryAttack(client);
	else
		g_bBlocked[client] = false;
}

void StopAllTracking(bool restoreWeapons)
{
	for (int client = 1; client <= MaxClients; client++)
		StopClientTracking(client, restoreWeapons);
}

void OnIncapacitatedPreThink(int client)
{
	if (!IsIncapacitatedSurvivor(client))
	{
		StopClientTracking(client, true);
		return;
	}

	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon == -1 || GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
		return;

	SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime() + BUFFER_TIME);
	g_bBlocked[client] = true;
}

void RestoreSecondaryAttack(int client)
{
	if (!g_bBlocked[client])
		return;

	if (IsClientInGame(client))
	{
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		if (weapon != -1)
			SetEntPropFloat(weapon, Prop_Send, "m_flNextSecondaryAttack", GetGameTime());
	}

	g_bBlocked[client] = false;
}

bool IsIncapacitatedSurvivor(int client)
{
	return client >= 1
		&& client <= MaxClients
		&& IsClientInGame(client)
		&& IsPlayerAlive(client)
		&& GetClientTeam(client) == 2
		&& GetEntProp(client, Prop_Send, "m_isIncapacitated", 1) > 0;
}
