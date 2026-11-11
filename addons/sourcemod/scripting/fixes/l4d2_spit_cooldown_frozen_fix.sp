#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.2"

public Plugin myinfo = 
{
	name = "[L4D2] Spit Cooldown Frozen Fix",
	author = "Forgetest",
	description = "Simple fix for spit cooldown being \"frozen\".",
	version = PLUGIN_VERSION,
	url = "https://github.com/Target5150/MoYu_Server_Stupid_Plugins"
};

ConVar z_spit_interval;
int g_iRoundSerial;

public void OnPluginStart()
{
	z_spit_interval = FindConVar("z_spit_interval");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("ability_use", Event_AbilityUse);
}

public void OnMapStart()
{
	g_iRoundSerial++;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_iRoundSerial++;
}

void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
	char sAbility[16];
	event.GetString("ability", sAbility, sizeof(sAbility));
	if (strncmp(sAbility, "ability_", 8) == 0 && strcmp(sAbility[8], "spit") == 0)
	{
		// duration of spit animation seems to vary from [1.160003, 1.190002] on 100t sv
		DataPack dp;
		CreateDataTimer(1.2, Timer_CheckSpitAbility, dp, TIMER_FLAG_NO_MAPCHANGE);
		dp.WriteCell(event.GetInt("userid"));
		dp.WriteCell(g_iRoundSerial);
	}
}

Action Timer_CheckSpitAbility(Handle timer, DataPack dp)
{
	dp.Reset();
	int userid = dp.ReadCell();
	int roundSerial = dp.ReadCell();
	if (roundSerial == g_iRoundSerial)
	{
		CheckSpitAbility(userid);
	}
	return Plugin_Stop;
}

void CheckSpitAbility(int userid)
{
	int client = GetClientOfUserId(userid);
	if (!client || GetEntProp(client, Prop_Send, "m_zombieClass") != 4 || !IsPlayerAlive(client))
	{
		return;
	}
	
	int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
	if (ability == -1)
	{
		return;
	}
	
	// potential freezing detected
	if (GetEntPropFloat(ability, Prop_Send, "m_nextActivationTimer", 0) == 3600.0)
	{
		float interval = z_spit_interval.FloatValue;
		SetEntPropFloat(ability, Prop_Send, "m_nextActivationTimer", interval, 0);
		SetEntPropFloat(ability, Prop_Send, "m_nextActivationTimer", GetGameTime() + interval, 1);
		SetEntProp(ability, Prop_Send, "m_bHasBeenActivated", false);
	}
}
