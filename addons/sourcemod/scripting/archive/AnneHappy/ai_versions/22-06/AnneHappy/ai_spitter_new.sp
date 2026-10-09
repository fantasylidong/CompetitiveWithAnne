#pragma semicolon 1
#pragma newdecls required

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

public Plugin myinfo = 
{
	name 			= "Ai-Spitter增强",
	author 			= "Breezy，High Cookie，Standalone，Newteee，cravenge，Harry，Sorallll，PaimonQwQ，夜羽真白",
	description 	= "觉得Ai Spitter不够强？ Try this！",
	version 		= "22-4-24",
	url 			= "https://steamcommunity.com/id/saku_ra/"
}

// ConVars

// Ints
int g_iSpitterTarget;
// Floats
float g_fSpitterBhopSpeed, g_fSpitterStartBhopDistance, g_fSpitterAirAngle;
// Bools
bool g_bSpitterBhop, g_bInstantKill;

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_SPITTER 4
#define FL_JUMPING 65922

public void OnPluginStart()
{
	// CreateConVar
	
	
	
	
	
	
	// AddChangeHook
	
	
	
	
	
	
	// GetCvars
	GetCvars();
}

void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_bSpitterBhop = true;
	g_fSpitterBhopSpeed = (90.0);
	g_fSpitterStartBhopDistance = (2000.0);
	g_iSpitterTarget = (3);
	g_bInstantKill = false;
	g_fSpitterAirAngle = (57.0);
}

public Action OnPlayerRunCmd(int spitter, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (IsAiSpitter(spitter))
	{
		if (L4D_IsPlayerStaggering(spitter))
			return Plugin_Continue;
		// 跳着吐痰
		if (buttons & IN_ATTACK)
		{
			buttons |= IN_JUMP;
			if (g_bInstantKill)
			{
				// 延迟10秒处死，防止无声痰
				CreateTimer(10.0, Timer_ForceSuicide, spitter);
			}
			return Plugin_Changed;
		}
		float fSpeed[3], fCurrentSpeed, fAngles[3], fDistance;
		GetEntPropVector(spitter, Prop_Data, "m_vecVelocity", fSpeed);
		fCurrentSpeed = SquareRoot(Pow(fSpeed[0], 2.0) + Pow(fSpeed[1], 2.0));
		fDistance = NearestSurvivorDistance(spitter);
		// 获取状态
		int iFlags = GetEntityFlags(spitter);
		if (fDistance < g_fSpitterStartBhopDistance && fCurrentSpeed > 150.0)
		{
			if (g_bSpitterBhop)
			{
				if (iFlags & FL_ONGROUND)
				{
					float fSpitterEyeAngles[3], fForwardVec[3];
					GetClientEyeAngles(spitter, fSpitterEyeAngles);
					GetAngleVectors(fSpitterEyeAngles, fForwardVec, NULL_VECTOR, NULL_VECTOR);
					NormalizeVector(fForwardVec, fForwardVec);
					ScaleVector(fForwardVec, g_fSpitterBhopSpeed);
					buttons |= IN_JUMP;
					buttons |= IN_DUCK;
					if ((buttons & IN_FORWARD) || (buttons & IN_BACK) || (buttons & IN_MOVELEFT) || (buttons & IN_MOVERIGHT))
					{
						ClientPush(spitter, fForwardVec);
					}
				}
				else if (iFlags == FL_JUMPING)
				{
					int iNearestTarget = NearestSurvivor(spitter);
					// 获取位置
					float fSpitterPos[3], fTargetPos[3];
					GetClientAbsOrigin(spitter, fSpitterPos);	
					if (iNearestTarget > 0)
					{
						GetClientAbsOrigin(iNearestTarget, fTargetPos);
						float fTargetDistance = GetVectorDistance(fTargetPos, fSpitterPos);
						if (fTargetDistance < 100.0)
						{
							// 防止跳过头
							float fAnglesPost[3];
							GetVectorAngles(fSpeed, fAngles);
							fAnglesPost = fAngles;
							fAngles[0] = fAngles[2] = 0.0;
							GetAngleVectors(fAngles, fAngles, NULL_VECTOR, NULL_VECTOR);
							NormalizeVector(fAngles, fAngles);
							// 保存当前位置
							static float fDirection[2][3];
							fDirection[0] = fSpitterPos;
							fDirection[1] = fTargetPos;
							fSpitterPos[2] = fTargetPos[2] = 0.0;
							MakeVectorFromPoints(fSpitterPos, fTargetPos, fSpitterPos);
							NormalizeVector(fSpitterPos, fSpitterPos);
							// 计算角度
							if (RadToDeg(ArcCosine(GetVectorDotProduct(fAngles, fSpitterPos))) > g_fSpitterAirAngle)
							{
								// 重新设置速度方向
								float fNewVelocity[3];
								MakeVectorFromPoints(fDirection[0], fDirection[1], fNewVelocity);
								NormalizeVector(fNewVelocity,fNewVelocity);
								ScaleVector(fNewVelocity,fCurrentSpeed);
								TeleportEntity(spitter, NULL_VECTOR, fAnglesPost, fNewVelocity);
							}
						}
					}
				}
			}
			if (GetEntityMoveType(spitter) & MOVETYPE_LADDER)
			{
				buttons &= ~IN_JUMP;
				buttons &= ~IN_DUCK;
			}
		}
	}
	return Plugin_Continue;
}

public Action Timer_ForceSuicide(Handle timer, int client)
{
	ForcePlayerSuicide(client);
	return Plugin_Continue;
}

// 目标选择
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
	if (IsAiSpitter(specialInfected))
	{
		switch (g_iSpitterTarget)
		{
			case 2:
			{
				int iTarget = GetCrowdPlace();
				if (iTarget > 0)
				{
					curTarget = iTarget;
				}
			}
			case 3:
			{
				if (HasPinnedClient())
				{
					for (int client = 1; client <= MaxClients; client++)
					{
						if (IsValidClient(client) && GetClientTeam(client) == TEAM_SURVIVOR)
						{
							if (IsPinned(client))
							{
								curTarget = client;
								return Plugin_Changed;
							}
						}
					}
				}
				else
				{
					int iTarget = GetCrowdPlace();
					if (iTarget > 0)
					{
						curTarget = iTarget;
						return Plugin_Changed;
					}
				}
			}
		}
	}
	return Plugin_Continue;
}

// ***** 方法 *****
bool IsAiSpitter(int client)
{
	if(IsFakeClient(client) && GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_SPITTER && GetEntProp(client, Prop_Send, "m_isGhost") != 1)
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool IsValidClient(int client)
{
	if (client && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
	{
		return true;
	}
	else
	{
		return false;
	}
}

int GetSurvivorCount()
{
	int iCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsValidClient(i) && GetClientTeam(i) == TEAM_SURVIVOR)
		{
			iCount++;
		}
	}
	return iCount;
}

int NearestSurvivor(int attacker)
{
	int iTarget = -1;
	float minDistance = 100000.0, selfPos[3], targetPos[3];
	GetClientAbsOrigin(attacker, selfPos);
	for (int client = 1; client <= MaxClients; ++client)
	{
		if (IsSurvivor(client) && IsPlayerAlive(client))
		{
			GetClientAbsOrigin(client, targetPos);
			float fDistance = GetVectorDistance(selfPos, targetPos);
			if (fDistance < minDistance)
			{
				minDistance = fDistance;
				iTarget = client;
			}
		}
	}
	return iTarget;
}

bool IsSurvivor(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR)
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock bool IsIncapped(int client)
{
    return view_as<bool>(GetEntProp(client, Prop_Send, "m_isIncapacitated"));
}

// From：http://github.com/PaimonQwQ/L4D2-Plugins/smartspitter.sp
int GetCrowdPlace()
{
	int iCount = GetSurvivorCount();
	if (iCount > 0)
	{
		int index = 0, iTarget = 0;
		int[] iSurvivors = new int[iCount];
		float fDistance[MAXPLAYERS + 1] = {-1.0};
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsValidClient(client) && GetClientTeam(client) == TEAM_SURVIVOR)
			{
				iSurvivors[index++] = client;
			}
		}
		for (int client = 1; client <= MaxClients; client++)
		{
			if (IsValidClient(client) && IsPlayerAlive(client) && GetClientTeam(client) == TEAM_SURVIVOR)
			{
				fDistance[client] = 0.0;
				float fClientPos[3] = {0.0};
				GetClientAbsOrigin(client, fClientPos);
				for (int i = 0; i < iCount; i++)
				{
					float fPos[3] = {0.0};
					GetClientAbsOrigin(iSurvivors[i], fPos);
					fDistance[client] += GetVectorDistance(fClientPos, fPos, true);
				}
			}
		}
		for (int i = 0; i < iCount; i++)
		{
			if (fDistance[iSurvivors[iTarget]] > fDistance[iSurvivors[i]])
			{
				if (fDistance[iSurvivors[i]] != -1.0)
				{
					iTarget = i;
				}
			}
		}
		return iSurvivors[iTarget];
	}
	else
	{
		return -1;
	}
}

float NearestSurvivorDistance(int client)
{
	static int i, iCount;
	static float vPos[3], vTargetPos[3], fDistance[MAXPLAYERS + 1];
	iCount = 0;
	GetClientAbsOrigin(client, vPos);
	for (i = 1; i <= MaxClients; i++)
	{
		if (i != client && IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			GetClientAbsOrigin(i, vTargetPos);
			fDistance[iCount++] = GetVectorDistance(vPos, vTargetPos);
		}
	}
	if (iCount == 0)
	{
		return -1.0;
	}
	SortFloats(fDistance, iCount, Sort_Ascending);
	return fDistance[0];
}

void ClientPush(int client, float fForwardVec[3])
{
	float fCurVelVec[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fCurVelVec);
	for (int i = 0; i < 3; i++)
	{
		fCurVelVec[i] += fForwardVec[i];
	}
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fCurVelVec);
}

bool IsPinned(int client)
{
	bool bIsPinned = false;
	if (IsSurvivor(client))
	{
		if(GetEntPropEnt(client, Prop_Send, "m_tongueOwner") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0) bIsPinned = true;
		// if(GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0) bIsPinned = true;
		if(GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0) bIsPinned = true;
	}		
	return bIsPinned;
}

bool HasPinnedClient()
{
	bool bHasPinnedClient = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsPinned(client))
		{
			bHasPinnedClient = true;
		}
	}
	return bHasPinnedClient;
}
