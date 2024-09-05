/*
	SourcePawn is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	SourceMod is Copyright (C) 2006-2008 AlliedModders LLC.  All rights reserved.
	Pawn and SMALL are Copyright (C) 1997-2008 ITB CompuPhase.
	Source is Copyright (C) Valve Corporation.
	All trademarks are property of their respective owners.

	This program is free software: you can redistribute it and/or modify it
	under the terms of the GNU General Public License as published by the
	Free Software Foundation, either version 3 of the License, or (at your
	option) any later version.

	This program is distributed in the hope that it will be useful, but
	WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
	General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program. If not, see <http://www.gnu.org/licenses/>.
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colors>
#include <sdkhooks>
#include <l4d2util_constants>

enum SIClasses
{
        SMOKER_CLASS=1,
        BOOMER_CLASS,
        HUNTER_CLASS,
        SPITTER_CLASS,
        JOCKEY_CLASS,
        CHARGER_CLASS,
        WITCH_CLASS,
        TANK_CLASS,
        NOTINFECTED_CLASS
}

static char SINames[SIClasses][] =
{
        "",
        "gas",          // smoker
        "exploding",    // boomer
        "hunter",
        "spitter",
        "jockey",
        "charger",
        "witch",
        "tank",
        ""
};

ConVar
	g_hCvarDmgThreshold = null;
Handle
	g_hSpecialInfectedHP[SIClasses] = {INVALID_HANDLE};

#define TAUNT_HIGH_THRESHOLD            0.4
#define TAUNT_MID_THRESHOLD             0.2
#define TAUNT_LOW_THRESHOLD             0.04

public Plugin myinfo =
{
	name = "1v1 EQ",
	author = "Blade + Confogl Team, Tabun, Visor",
	description = "A plugin designed to support 1v1.",
	version = "0.2.1",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	char buffer[17];
	for (int i = 1; i < SIClasses; i++)
	{
		Format(buffer, sizeof(buffer), "z_%s_health", SINames[i]);
		g_hSpecialInfectedHP[i] = FindConVar(buffer);
	}
        
	g_hCvarDmgThreshold = CreateConVar("sm_1v1_dmgthreshold", "24", "Amount of damage done (at once) before SI suicides.", _, true, 1.0);

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
}

public void Event_PlayerHurt(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	int fDamage = hEvent.GetInt("dmg_health");
	if (fDamage < g_hCvarDmgThreshold.IntValue) {
		return;
	}
	
	int iAttacker = GetClientOfUserId(hEvent.GetInt("attacker"));
	if (!IsClientAndInGame(iAttacker) || GetClientTeam(iAttacker) != L4D2Team_Infected) {
		return;
	}
	
	int iZclass = GetEntProp(iAttacker, Prop_Send, "m_zombieClass");
	
	if (iZclass < L4D2Infected_Smoker || iZclass > L4D2Infected_Charger) {
		return;
	}
	
	int iVictim = GetClientOfUserId(hEvent.GetInt("userid"));
	if (!IsClientAndInGame(iVictim) || GetClientTeam(iVictim) != L4D2Team_Survivor) {
		return;
	}
	
	int iRemainingHealth = GetClientHealth(iAttacker);

	// [1v1] Player (Hunter) had 250 health remaining!
	// [1v1] AI (Hunter) had 250 health remaining!
	
	char sName[MAX_NAME_LENGTH];
	if (IsFakeClient(iAttacker)) {
		Format(sName, sizeof(sName), "AI");
	} else {
		GetClientName(iAttacker, sName, sizeof(sName));
	}
	
	CPrintToChatAll("[{olive}伤害报告{default}] {red}%s{default} ({green}%s{default}) 还剩下 {olive}%d{default} 点血!", sName, L4D2_InfectedNames[iZclass], iRemainingHealth);
	
	ForcePlayerSuicide(iAttacker);
	SDKHook(iVictim, SDKHook_PostThinkPost, CancelGetup);
	int maxHealth = GetSpecialInfectedHP(iZclass);
	if (!maxHealth)
		return;    
                
	if (iRemainingHealth == 1)
	{
 		PrintToChat(iVictim, "恼羞成怒，下次对准头部...");
    }
	else if (iRemainingHealth <= RoundToCeil(maxHealth * TAUNT_LOW_THRESHOLD))
    {
		PrintToChat(iVictim, "你看起来很沮丧...");
	}
	else if (iRemainingHealth <= RoundToCeil(maxHealth * TAUNT_MID_THRESHOLD))
    {
		PrintToChat(iVictim, "接近了!");
    }
	else if (iRemainingHealth <= RoundToCeil(maxHealth * TAUNT_HIGH_THRESHOLD))
	{
		PrintToChat(iVictim, "还不错.");
	}
    /*
	if (iRemainingHealth <= 10) {
		CPrintToChat(iVictim, "你不必要愤怒，下次对准头部...");
	}
	*/
}

public Action CancelGetup(int client)
{
	if (IsClientAndInGame(client))
	{
		SetEntPropFloat(client, Prop_Send, "m_flCycle", 1000.0, 0);
	}
	return Plugin_Continue;
}

stock int GetSpecialInfectedHP(int class)
{
    if (g_hSpecialInfectedHP[class] != INVALID_HANDLE)
            return GetConVarInt(g_hSpecialInfectedHP[class]);
    
    return 0;
}

bool IsClientAndInGame(int iClient)
{
	return (iClient > 0 && IsClientInGame(iClient));
}
