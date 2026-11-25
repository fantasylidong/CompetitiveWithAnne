#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "1.1-anne1"
#define GAMEDATA_FILE "l4d2_vomit_collision_fix"
#define TEAM_SURVIVOR 2

// What CVomit and CVomitParticle return from PhysicsSolidMaskForEntity
#define VOMIT_MASK (MASK_SOLID & ~CONTENTS_GRATE)

// A vomit trace once a survivor needs hitbox testing
#define VOMIT_HITBOX_MASK (VOMIT_MASK | CONTENTS_HITBOX)

public Plugin myinfo =
{
	name = "[L4D2] Vomit Collision Fix",
	author = "Forgetest, Sir",
	description = "Incapacitated and pounced/pummeled survivors stop blocking Boomer vomit aimed past them once they're biled.",
	version = PLUGIN_VERSION,
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

DynamicHook
	g_hPhysicsSolidMask,
	g_hTestHitboxes;

int g_iDownCheckTick = -1;
bool g_bAnyDown;

int g_iHitboxHook[MAXPLAYERS + 1] = {INVALID_HOOK_ID, ...};
bool g_bHitboxHooked;
Handle g_hUnhookTimer;

// How often to check whether the hitbox hooks are still needed
#define UNHOOK_CHECK_INTERVAL 1.0

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (!gd)
	{
		SetFailState("Missing gamedata \"%s\"", GAMEDATA_FILE);
	}

	g_hPhysicsSolidMask = DynamicHook.FromConf(gd, "CBaseEntity::PhysicsSolidMaskForEntity");
	g_hTestHitboxes = DynamicHook.FromConf(gd, "CBaseEntity::TestHitboxes");
	delete gd;

	if (!g_hPhysicsSolidMask || !g_hTestHitboxes)
	{
		SetFailState("Failed to set up hooks from gamedata \"%s\"", GAMEDATA_FILE);
	}

	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "ability_vomit")) != -1)
	{
		OnEntityCreated(entity, "ability_vomit");
	}

	while ((entity = FindEntityByClassname(entity, "vomit_particle")) != -1)
	{
		OnEntityCreated(entity, "vomit_particle");
	}
}

public void OnMapStart()
{
	g_iDownCheckTick = -1;
}

public void OnMapEnd()
{
	UnhookPlayerHitboxes();
}

public void OnClientDisconnect(int client)
{
	if (g_iHitboxHook[client] != INVALID_HOOK_ID)
	{
		DynamicHook.RemoveHook(g_iHitboxHook[client]);
		g_iHitboxHook[client] = INVALID_HOOK_ID;
	}
}

public void OnClientPutInServer(int client)
{
	if (g_bHitboxHooked && g_iHitboxHook[client] == INVALID_HOOK_ID)
	{
		g_iHitboxHook[client] = g_hTestHitboxes.HookEntity(Hook_Pre, client, CTerrorPlayer_TestHitboxes);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// Just to cover both scenarios, we check vomit_particle to support AI Boomers
	if ((classname[0] == 'a' && strcmp(classname, "ability_vomit") == 0) || (classname[0] == 'v' && strcmp(classname, "vomit_particle") == 0))
	{
		g_hPhysicsSolidMask.HookEntity(Hook_Post, entity, Vomit_PhysicsSolidMaskForEntity_Post);
	}
}

// Called for every vomit trace, just before it runs.
MRESReturn Vomit_PhysicsSolidMaskForEntity_Post(DHookReturn hReturn)
{
	if (!IsAnySurvivorVomitedAndDown())
	{
		return MRES_Ignored;
	}

	HookPlayerHitboxes();

	hReturn.Value = hReturn.Value | CONTENTS_HITBOX;
	return MRES_Override;
}

/*
	Anne: upstream v1.1 hooked every client on every vomit tick and unhooked them on the next frame.
	Each DynamicHook.HookEntity builds a DHooks manager, JITs a thunk and mprotects/patches the vtable,
	so a sustained vomit with 10-28 SI on the server cost thousands of hook create/destroy cycles per
	second and caused heavy sv spikes. Linux runs these traces on the main thread (the Windows worker
	thread crash v1.1 worked around does not apply), so keep the hooks attached for as long as a biled
	survivor is down and only remove them once nobody needs them anymore.
*/
void HookPlayerHitboxes()
{
	if (g_bHitboxHooked)
	{
		return;
	}

	g_bHitboxHooked = true;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_iHitboxHook[i] == INVALID_HOOK_ID)
		{
			g_iHitboxHook[i] = g_hTestHitboxes.HookEntity(Hook_Pre, i, CTerrorPlayer_TestHitboxes);
		}
	}

	delete g_hUnhookTimer;
	g_hUnhookTimer = CreateTimer(UNHOOK_CHECK_INTERVAL, Timer_CheckUnhook, _, TIMER_REPEAT);
}

Action Timer_CheckUnhook(Handle timer)
{
	if (IsAnySurvivorVomitedAndDown())
	{
		return Plugin_Continue;
	}

	g_hUnhookTimer = null;
	UnhookPlayerHitboxes();
	return Plugin_Stop;
}

void UnhookPlayerHitboxes()
{
	delete g_hUnhookTimer;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_iHitboxHook[i] != INVALID_HOOK_ID)
		{
			DynamicHook.RemoveHook(g_iHitboxHook[i]);
			g_iHitboxHook[i] = INVALID_HOOK_ID;
		}
	}

	g_bHitboxHooked = false;
}

/*
	A mask with CONTENTS_HITBOX will replace the bounding box result with the hitbox one, so a ray
	that misses the hitboxes passes through the player.
	Returning false makes the game test the bounding box instead (normal behavior)
*/
MRESReturn CTerrorPlayer_TestHitboxes(int pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (hParams.Get(2) != VOMIT_HITBOX_MASK || IsSurvivorVomitedAndDown(pThis))
	{
		return MRES_Ignored;
	}

	hReturn.Value = false;
	return MRES_Supercede;
}

// Checked once per tick, optimization
bool IsAnySurvivorVomitedAndDown()
{
	int tick = GetGameTickCount();
	if (tick == g_iDownCheckTick)
	{
		return g_bAnyDown;
	}

	g_iDownCheckTick = tick;
	g_bAnyDown = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsSurvivorVomitedAndDown(i))
		{
			g_bAnyDown = true;
			break;
		}
	}

	return g_bAnyDown;
}

/*
	The bounding box of a survivor lying on the ground is still as tall as a standing one, with nothing but air above
	the body. It should take the vomit like any other survivor, but shouldn't keep blocking vomit aimed past them after.
*/
bool IsSurvivorVomitedAndDown(int client)
{
	if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client) || GetEntPropFloat(client, Prop_Send, "m_itTimer", 1) <= GetGameTime())
	{
		return false;
	}

	if (GetEntProp(client, Prop_Send, "m_isIncapacitated"))
	{
		return !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
	}

	return GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0 || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0;
}
