#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#include <sourcescramble>

ArrayList gAlwaysPatches;
ArrayList gNeriPatches;

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
