#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <left4dhooks>

#include <sourcescramble>

ArrayList gAlwaysPatches;
ArrayList gNeriPatches;
DynamicDetour gTongueReadyDetour;

ConVar gCvarNeriPatches;
bool gNeriPatchesEnabled;

public void OnPluginStart()
{
	gAlwaysPatches = new ArrayList();
	gNeriPatches = new ArrayList();
	gCvarNeriPatches = CreateConVar("l4d_air_abilities_patch_neri", "0", "Enable Anne-Neri smoker/boomer air ability patches.", FCVAR_NONE, true, 0.0, true, 1.0);
	gCvarNeriPatches.AddChangeHook(OnNeriPatchesChanged);
	
	GameData data = new GameData("l4d2_air_data");
	LoadAlwaysPatches(data);
	LoadNeriPatches(data);
	gTongueReadyDetour = DynamicDetour.FromConf(data, "CTongue::IsAbilityReadyToFire");
	if ( !gTongueReadyDetour || !gTongueReadyDetour.Enable(Hook_Post, DTR_TongueIsAbilityReadyToFire_Post) )
		LogMessage("Failed to detour \"CTongue::IsAbilityReadyToFire\". Smokers can still fire from ladders.");
	delete data;

	SetNeriPatches(gCvarNeriPatches.BoolValue);
}

public void OnPluginEnd()
{
	DisablePatches(gNeriPatches);
	DisablePatches(gAlwaysPatches);
}

void OnNeriPatchesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	SetNeriPatches(convar.BoolValue);
}

void LoadAlwaysPatches(GameData data)
{
	static const char names[][] =
	{
		"charger",
		"zoom"
	};

	for (int i; i < sizeof names; i++)
	{
		CreatePatch(data, names[i], gAlwaysPatches, true);
	}
}

void LoadNeriPatches(GameData data)
{
	static const char names[][] =
	{
		"vomit",
		"tongue_update_attach_state",
		"tongue_ability"
	};

	for (int i; i < sizeof names; i++)
	{
		CreatePatch(data, names[i], gNeriPatches, false);
	}
}

void CreatePatch(GameData data, const char[] name, ArrayList patches, bool enable)
{
	MemoryPatch patch = MemoryPatch.CreateFromConf(data, name);
	
	if ( !patch )
	{
		LogMessage("Failed to create patch for \"%s\". Skiping...", name);
		return;
	}
	else if ( !patch.Validate() ) 
	{
		LogMessage("Failed to verify patch for \"%s\". Skiping...", name);
		return;
	}
	
	if ( enable && !patch.Enable() )
	{
		LogMessage("Failed to enable patch for \"%s\". Skiping...", name);
		return;
	}

	patches.Push(patch);
}

void SetNeriPatches(bool enable)
{
	if (enable == gNeriPatchesEnabled)
		return;

	for (int i; i < gNeriPatches.Length; i++)
	{
		MemoryPatch patch = view_as<MemoryPatch>(gNeriPatches.Get(i));
		if (enable)
		{
			if (!patch.Enable())
				LogMessage("Failed to enable Anne-Neri air ability patch %d.", i);
		}
		else
		{
			patch.Disable();
		}
	}

	gNeriPatchesEnabled = enable;
}

// Air pulls are air pulls, never ladder pulls, on every tier. The Neri patches drop the FL_ONGROUND check on
// firing, and even vanilla lets a smoker mounted at the foot of a ladder fire, so on a ladder the tongue is
// never ready.
MRESReturn DTR_TongueIsAbilityReadyToFire_Post(int pThis, DHookReturn hReturn)
{
	if (!hReturn.Value)
		return MRES_Ignored;

	int owner = GetEntPropEnt(pThis, Prop_Send, "m_owner");
	if (owner < 1 || owner > MaxClients || GetEntityMoveType(owner) != MOVETYPE_LADDER)
		return MRES_Ignored;

	hReturn.Value = false;
	return MRES_Supercede;
}

// Vanilla roots a smoker whose tongue is out only by capping its run speed at 1.0 and stripping jump/duck
// (CTerrorGameMovement::CheckParameters). Move input survives, so a smoker pressed against a ladder still
// mounts it and climbs at the fixed ladder speed while it drags its victim; the Neri patches also drop the
// "left the ground" tongue break. Drop all move input while the tongue is out, and still let go of a victim
// if the smoker ends up on a ladder anyway.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3])
{
	if (GetClientTeam(client) != 3 || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_zombieClass") != 1 || !IsTongueOut(client))
		return Plugin_Continue;

	int victim = GetEntPropEnt(client, Prop_Send, "m_tongueVictim");
	if (victim > 0 && victim <= MaxClients && IsClientInGame(victim) && GetEntityMoveType(client) == MOVETYPE_LADDER)
		L4D_Smoker_ReleaseVictim(victim, client);

	buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
	vel[0] = 0.0;
	vel[1] = 0.0;
	vel[2] = 0.0;
	return Plugin_Changed;
}

// Same window as CTongue::IsTongueActive(), the one vanilla uses to root the smoker.
bool IsTongueOut(int client)
{
	int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
	if (ability > MaxClients && HasEntProp(ability, Prop_Send, "m_tongueState"))
		return GetEntProp(ability, Prop_Send, "m_tongueState") != 0;

	return GetEntPropEnt(client, Prop_Send, "m_tongueVictim") > 0;
}

void DisablePatches(ArrayList patches)
{
	if (patches == null)
		return;

	for (int i; i < patches.Length; i++)
	{
		MemoryPatch patch = view_as<MemoryPatch>(patches.Get(i));
		patch.Disable();
	}

	delete patches;
}
