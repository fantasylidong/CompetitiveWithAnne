#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sourcescramble>

#define GAMEDATA "l4d2_allow_cs_weapons"

MemoryPatch g_hPatch;

public Plugin myinfo =
{
	name = "[L4D2] Allow CS weapons on every map.",
	author = "Sir",
	description = "Force weapon spawners to ignore the 'no_cs_weapons' KeyValue, allowing for CS weapons on every map.",
	version = "1.2"
};

public void OnPluginStart()
{
	GameData hGameData = new GameData(GAMEDATA);
	if (hGameData == null)
		SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	g_hPatch = MemoryPatch.CreateFromConf(hGameData, "CDirectorItemManager::AreCSWeaponsAllowed");
	delete hGameData;
	if (g_hPatch == null)
		SetFailState("Failed to create patch \"CDirectorItemManager::AreCSWeaponsAllowed\"");
	if (!g_hPatch.Validate())
		SetFailState("Failed to validate patch \"CDirectorItemManager::AreCSWeaponsAllowed\"");
	if (!g_hPatch.Enable())
		SetFailState("Failed to enable patch \"CDirectorItemManager::AreCSWeaponsAllowed\"");
}

public void OnPluginEnd()
{
	// SourceScramble restores the original bytes when the patch handle is closed.
	delete g_hPatch;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (IsWeaponSpawnerClass(classname))
		SDKHook(entity, SDKHook_Spawn, WeaponSpawner_OnSpawn);
}

/*
	Must run before Spawn: spawners with "spawn_without_director" "1" pick their weapon
	inside Spawn() itself, and the entity-level KeyValue is checked before the patched
	CDirectorItemManager::AreCSWeaponsAllowed ever runs, so it has to be cleared here.
*/
Action WeaponSpawner_OnSpawn(int entity)
{
	if (HasEntProp(entity, Prop_Data, "m_bNoCSWeapons"))
		SetEntProp(entity, Prop_Data, "m_bNoCSWeapons", 0);

	return Plugin_Continue;
}

// Matches "weapon_spawn" and every "weapon_<name>_spawn" spawner classname.
bool IsWeaponSpawnerClass(const char[] classname)
{
	if (strncmp(classname, "weapon_", 7) != 0)
		return false;

	int len = strlen(classname);
	return len >= 12 && StrEqual(classname[len - 6], "_spawn");
}
