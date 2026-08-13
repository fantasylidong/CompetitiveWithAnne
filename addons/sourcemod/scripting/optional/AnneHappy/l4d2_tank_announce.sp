#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <colors>

#define SOUNDEFFECT "ui/pickup_secret01.wav"

// ConVar
ConVar g_hPlaySound, g_hMessageType;
// Ints
int g_iPlaySound, g_iMessageType;

public Plugin myinfo = 
{
	name 			= "Tank刷新提示",
	author 			= "夜羽真白",
	description 	= "当Tank生成时，进行提示",
	version 		= "1.0.1.1",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

public void OnPluginStart()
{
	LoadTranslations("l4d2_tank_announce.phrases");
	// CreateConVar
	g_hPlaySound = CreateConVar("l4d2_tankannounce_playsound", "1", "是否在Tank生成时播放声音", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hMessageType = CreateConVar("l4d2_tankannounce_messagetype", "1", "Tank生成提示的类型：0=不提示，1=聊天框提示，2=中央提示框提示，3=中央文字提示", FCVAR_NOTIFY, true, 0.0, true, 3.0);
	// HookEvent
	HookEvent("player_spawn", evt_PlayerSpawn);
	// AddChangeHook
	g_hPlaySound.AddChangeHook(ConVarChanged_Cvars);
	g_hMessageType.AddChangeHook(ConVarChanged_Cvars);
	// GetValue
	g_iPlaySound = g_hPlaySound.IntValue;
	g_iMessageType = g_hMessageType.IntValue;
}

public void OnMapStart()
{
	PrecacheSound(SOUNDEFFECT, false);
}

public void evt_PlayerSpawn(Event event, char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	char sGameMod[32];	GetConVarString(FindConVar("mp_gamemode"), sGameMod, sizeof(sGameMod));
	// 判断是否玩家Tank
	if (IsAiTank(client))
	{
		switch (g_iMessageType)
		{
			case 1:
			{
				// 非对抗模式下无法使用红色
				if (StrEqual(sGameMod, "versus", false))
				{
					AnnounceTankSpawn(client, "L4D2TankAnnounce_TankControllerGenerated", 1);
				}
				else
				{
					AnnounceTankSpawn(client, "L4D2TankAnnounce_TankControllerGenerated_2", 1);
				}
			}
			case 2:
			{
				AnnounceTankSpawn(client, "L4D2TankAnnounce_Hint", 2);
			}
			case 3:
			{
				AnnounceTankSpawn(client, "L4D2TankAnnounce_Hint", 3);
			}
		}
		if (g_iPlaySound == 1)
		{
			EmitSoundToAll(SOUNDEFFECT); // Selected Sound
		}
	}
}

void AnnounceTankSpawn(int tank, const char[] phrase, int msgType)
{
	char sTankName[MAX_NAME_LENGTH];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || (IsFakeClient(i) && !IsClientSourceTV(i)))
		{
			continue;
		}

		SetGlobalTransTarget(i);
		FormatTankControllerName(tank, i, sTankName, sizeof(sTankName));
		switch (msgType)
		{
			case 1:
			{
				CPrintToChat(i, "%t", phrase, sTankName);
			}
			case 2:
			{
				PrintHintText(i, "%t", phrase, sTankName);
			}
			case 3:
			{
				PrintCenterText(i, "%t", phrase, sTankName);
			}
		}
	}
}

void FormatTankControllerName(int tank, int langClient, char[] buffer, int maxlen)
{
	if (!IsFakeClient(tank))
	{
		FormatEx(buffer, maxlen, "%T", "L4D2TankAnnounce_PlayerName", langClient, tank);
	}
	else
	{
		FormatEx(buffer, maxlen, "%T", "L4D2TankAnnounce_AIName", langClient, tank);
	}
}

bool IsAiTank(int tank)
{
	if (tank <= 0 || !IsClientInGame(tank) || GetClientTeam(tank) != 3 || GetEntProp(tank, Prop_Send, "m_zombieClass") != 8)
	{
		return false;
	}

	return true;
}

void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iPlaySound = g_hPlaySound.IntValue;
	g_iMessageType = g_hMessageType.IntValue;
}

public void OnPluginEnd()
{
	UnhookEvent("player_spawn", evt_PlayerSpawn);
}
