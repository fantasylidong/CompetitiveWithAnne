/*
	Coinflip

	by purpletreefactory
	Credit for the idea goes to Fig
	This version was made out of convenience

	1.0.2: added e-z-p-z commands, removed unnecessary colors.inc, removed generation of config file
	1.1.0: new syntax rewrite + in-game players only + invalid roll sizes fall back to the default
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#define DEFAULT_SIDES 20

ConVar g_cvDelay;

int
	g_iLastFlip,
	g_iLastRoll;

public Plugin myinfo =
{
	name = "Coinflip",
	author = "purpletreefactory, epilimic",
	description = "purpletreefactory's version of coinflip",
	version = "1.1.0",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	LoadTranslations("coinflip.phrases");
	g_cvDelay = CreateConVar("coinflip_delay", "-1", "Time delay in seconds between allowed coinflips. Set at -1 if no delay at all is desired.");

	RegConsoleCmd("sm_coinflip", Cmd_Coinflip);
	RegConsoleCmd("sm_cf", Cmd_Coinflip);
	RegConsoleCmd("sm_flip", Cmd_Coinflip);
	RegConsoleCmd("sm_roll", Cmd_Roll);
	RegConsoleCmd("sm_picknumber", Cmd_Roll);
}

Action Cmd_Coinflip(int client, int args)
{
	if (!client || !IsClientInGame(client) || IsOnCooldown(client, g_iLastFlip))
		return Plugin_Handled;

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	CPrintToChatAll("%t %t", "Tag", (GetURandomInt() & 1) ? "Tails" : "Heads", name);
	return Plugin_Handled;
}

Action Cmd_Roll(int client, int args)
{
	if (!client || !IsClientInGame(client) || IsOnCooldown(client, g_iLastRoll))
		return Plugin_Handled;

	// No argument, non-numeric, zero or negative input all use the default die
	int sides = GetCmdArgInt(1);
	if (sides < 1)
		sides = DEFAULT_SIDES;

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	CPrintToChatAll("%t %t", "Tag", "rolled", name, sides, GetRandomInt(1, sides));
	return Plugin_Handled;
}

bool IsOnCooldown(int client, int &last)
{
	int now = GetTime();
	if (now - last > g_cvDelay.IntValue)
	{
		last = now;
		return false;
	}

	CPrintToChat(client, "%t %t", "Tag", "Cooldown", g_cvDelay.IntValue);
	return true;
}
