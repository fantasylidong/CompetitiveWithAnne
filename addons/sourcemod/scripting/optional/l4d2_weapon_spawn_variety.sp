#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#define L4D2UTIL_STOCKS_ONLY 1
#include <l4d2util>

#define MAX_SEL_LEN 32

bool g_bManaged[2049];
bool g_bPool[2049];     // Spawner rolled from a random pool selection ("any_*" / "tier*").
bool g_bMP5Kept[2049];  // MP5 result already passed the keep roll, never roll it again.
StringMap g_hSpawnResults;
ConVar g_hMP5Keep;

public Plugin myinfo =
{
	name = "[L4D/2] T1 Weapon Spawn Variety",
	author = "Sir",
	description = "SMG/T1 shotgun spawners roll their tier pool (any_smg / tier1_shotgun), while keeping random weapon spawns identical between versus halves. (Does not overwrite enforced spawns)",
	version = "1.2-anne1"
};

public void OnPluginStart()
{
	g_hSpawnResults = new StringMap();

	/*
		Anne addition. The engine gives the MP5 the same odds as the other SMGs once CS weapons are allowed.
		This is the chance an MP5 rolled from a random pool is kept, otherwise it becomes an Uzi or a silenced SMG.
		1.0 keeps the engine odds (upstream behaviour), 0.5 gives roughly 1/6 MP5 in any_smg.
	*/
	g_hMP5Keep = CreateConVar("l4d2_spawn_variety_mp5_keep", "1.0",
		"Chance that an MP5 rolled from a random weapon pool is kept. Otherwise it is re-rolled into an Uzi or a silenced SMG. 1.0 = engine odds.",
		FCVAR_NONE, true, 0.0, true, 1.0);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
	g_hSpawnResults.Clear();
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (IsWeaponSpawnerClass(classname))
	{
		g_bManaged[entity] = false;
		g_bPool[entity] = false;
		g_bMP5Kept[entity] = false;
		SDKHook(entity, SDKHook_Spawn, OnSpawnerSpawn);
		SDKHook(entity, SDKHook_SpawnPost, OnSpawnerSpawnPost);
	}
}

/*
	Capture whether this spawner has a random selection, before the engine
	resolves and clears it (spawn_without_director spawns resolve inside Spawn()).
*/
Action OnSpawnerSpawn(int entity)
{
	g_bManaged[entity] = false;

	if (HasEntProp(entity, Prop_Data, "m_iszWeaponToSpawn"))
	{
		char sel[MAX_SEL_LEN];
		GetEntPropString(entity, Prop_Data, "m_iszWeaponToSpawn", sel, sizeof(sel));
		g_bManaged[entity] = IsManagedSelection(sel);
	}

	g_bPool[entity] = g_bManaged[entity];

	return Plugin_Continue;
}

void OnSpawnerSpawnPost(int entity)
{
	// Gamerules and entity creation not available yet at this stage, wait.
	RequestFrame(OnSpawnerSpawnPostFrame, EntIndexToEntRef(entity));
}

void OnSpawnerSpawnPostFrame(int ref)
{
	int entity = EntRefToEntIndex(ref);
	if (entity == INVALID_ENT_REFERENCE)
		return;

	/*
		Fixed T1 spawners become their tier pool so they roll the full set.
		Predefined (Stripper:Source) weapon_* placements and tier spots are not modified.
	*/
	char classname[64];
	GetEntityClassname(entity, classname, sizeof(classname));

	char pool[MAX_SEL_LEN];
	if (GetNativePoolSelection(classname, pool, sizeof(pool)))
	{
		ConvertToSelection(entity, pool);
		return;
	}

	if (!g_bManaged[entity])
		return;

	g_bManaged[entity] = false;

	float origin[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);

	char key[48];
	FormatEx(key, sizeof(key), "%.0f_%.0f_%.0f", origin[0], origin[1], origin[2]);

	int resolved = GetEntProp(entity, Prop_Send, "m_weaponID");
	int stored;

	if (InSecondHalfOfRound() && g_hSpawnResults.GetValue(key, stored))
	{
		// The first half already settled this spot, keep-roll included.
		if (stored != resolved)
			ConvertWeaponSpawn(entity, stored);
		else
			g_bMP5Kept[entity] = true;
	}
	else
	{
		g_hSpawnResults.SetValue(key, RollMP5Keep(entity, resolved), true);
	}
}

/*
	Spawners without `spawn_without_director` are resolved by the director after Spawn(),
	so their MP5 result is not visible yet in the frame after SpawnPost. Catch those here.
*/
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.5, Timer_RollLateMP5, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_RollLateMP5(Handle timer)
{
	if (g_hMP5Keep.FloatValue >= 1.0)
		return Plugin_Stop;

	// Collect first: re-rolling kills the spawner and creates a new weapon_spawn.
	static int spawners[2049];
	int count = 0;
	int entity = -1;
	while ((entity = FindEntityByClassname(entity, "weapon_spawn")) != -1)
	{
		if (entity > 0 && entity < sizeof(g_bPool) && g_bPool[entity] && !g_bMP5Kept[entity])
			spawners[count++] = entity;
	}

	float origin[3];
	char key[48];
	for (int i = 0; i < count; i++)
	{
		entity = spawners[i];
		if (!IsValidEntity(entity))
			continue;

		int resolved = GetEntProp(entity, Prop_Send, "m_weaponID");
		if (resolved != WEPID_SMG_MP5)
			continue;

		GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
		FormatEx(key, sizeof(key), "%.0f_%.0f_%.0f", origin[0], origin[1], origin[2]);

		// A spot settled as MP5 in the first half stays MP5 in the second half.
		int stored;
		if (InSecondHalfOfRound() && g_hSpawnResults.GetValue(key, stored) && stored == WEPID_SMG_MP5)
		{
			g_bMP5Kept[entity] = true;
			continue;
		}

		g_hSpawnResults.SetValue(key, RollMP5Keep(entity, resolved), true);
	}

	return Plugin_Stop;
}

/*
	Applies the MP5 keep chance to a pool result and returns the weapon the spot ends up with.
	Only pool rolls are touched, enforced MP5 placements never get here.
*/
int RollMP5Keep(int entity, int resolved)
{
	if (resolved != WEPID_SMG_MP5 || !g_bPool[entity])
		return resolved;

	if (g_bMP5Kept[entity] || GetURandomFloat() < g_hMP5Keep.FloatValue)
	{
		g_bMP5Kept[entity] = true;
		return resolved;
	}

	int replacement = (GetURandomInt() & 1) ? WEPID_SMG : WEPID_SMG_SILENCED;
	if (ConvertWeaponSpawn(entity, replacement) == -1)
	{
		g_bMP5Kept[entity] = true;
		return resolved;
	}

	return replacement;
}

// Random selections we keep consistent between halves: "any_*" and "tier*".
bool IsManagedSelection(const char[] sel)
{
	return (strncmp(sel, "any", 3) == 0 || strncmp(sel, "tier", 4) == 0);
}

bool GetNativePoolSelection(const char[] classname, char[] sel, int maxlen)
{
	if (StrEqual(classname, "weapon_smg_spawn") || StrEqual(classname, "weapon_smg_silenced_spawn"))
	{
		strcopy(sel, maxlen, "any_smg");
		return true;
	}

	if (StrEqual(classname, "weapon_pumpshotgun_spawn") || StrEqual(classname, "weapon_shotgun_chrome_spawn"))
	{
		strcopy(sel, maxlen, "tier1_shotgun");
		return true;
	}

	return false;
}

/*
	Replaces a spawner with a weapon_spawn using an engine selection.
	`spawn_without_director` makes the engine roll it inside DispatchSpawn, and the new entity re-enters our hooks.
*/
void ConvertToSelection(int entity, const char[] selection)
{
	float origin[3], angles[3];
	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
	GetEntPropVector(entity, Prop_Send, "m_angRotation", angles);

	int newent = CreateEntityByName("weapon_spawn");
	if (newent == -1)
		return;

	AcceptEntityInput(entity, "kill");

	DispatchKeyValue(newent, "weapon_selection", selection);
	DispatchKeyValue(newent, "spawn_without_director", "1");
	DispatchKeyValue(newent, "count", "5");
	TeleportEntity(newent, origin, angles, NULL_VECTOR);
	DispatchSpawn(newent);
}

bool IsWeaponSpawnerClass(const char[] classname)
{
	if (strncmp(classname, "weapon_", 7) != 0)
		return false;

	int len = strlen(classname);
	return len >= 12 && StrEqual(classname[len - 6], "_spawn");
}
