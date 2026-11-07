/*====================================================
1.4.1
	- Restore mission lists through the live registry, never a cached engine pointer.

1.4
	- Restore the mission's original "meleeweapons" on map end and plugin unload.
	- No longer needs the "KeyValues::FindKey" gamedata.
	- Code cleanup.

1.3
	- Fixed the meleeweapons list if some 3rd party map mission do not declare the "meleeweapons".
	- Save the initial meleeweapons list. After changing the new mission, the "meleeweapons" will be restored and redeclared.

1.2
	- Fixed didn't take effect in time if added Cvars to server.cfg. Thanks to "Target_7" for reporting.

1.1
	- Fixed broken windows signatures.
	- Not forces map to reload any more.
	- Thanks to "Silvers" for reporting and help.

1.0
	- Initial release
======================================================*/
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA "l4d2_melee_spawn_control"
#define MELEE_LIST_LENGTH 255
#define MELEE_MAX_ENTRIES 32
#define MELEE_NAME_LENGTH 40

// Used when a mission doesn't declare "meleeweapons".
#define DEFAULT_MELEE_LIST "fireaxe;frying_pan;machete;baseball_bat;crowbar;cricket_bat;tonfa;katana;electric_guitar;knife;riotshield;golfclub;shovel;pitchfork"

Handle
	g_hSDKKvGetString,
	g_hSDKKvSetString,
	g_hSDKKvGetName,
	g_hSDKGetAllMissions;

ConVar
	g_hCvarMeleeSpawn,
	g_hCvarAddMelee;

StringMap g_smInitialMelee; // Mission's original melee list

Address g_pMatchExtL4D;
char g_sMissionName[PLATFORM_MAX_PATH];
char g_sMissionMelee[MELEE_LIST_LENGTH];
char g_sAppliedMelee[MELEE_LIST_LENGTH];

public Plugin myinfo =
{
	name = "l4d2 melee spawn control",
	author = "IA/NanaNana",
	description = "Unlock melee weapons",
	version = "1.4.1",
	url = "http://forums.alliedmods.net/showthread.php?t=327605"
};

public void OnPluginStart()
{
	GameData hGameData = new GameData(GAMEDATA);
	if (hGameData == null) {
		SetFailState("Could not find gamedata \"" ... GAMEDATA ... ".txt\"");
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "KeyValues::GetString");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_String, SDKPass_Pointer);
	g_hSDKKvGetString = EndPrepSDKCall();
	if (g_hSDKKvGetString == null) {
		SetFailState("KeyValues::GetString sig invalid.");
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "KeyValues::SetString");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hSDKKvSetString = EndPrepSDKCall();
	if (g_hSDKKvSetString == null) {
		SetFailState("KeyValues::SetString sig invalid.");
	}

	g_pMatchExtL4D = hGameData.GetAddress("g_pMatchExtL4D");
	if (g_pMatchExtL4D == Address_Null) {
		SetFailState("g_pMatchExtL4D address invalid.");
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetVirtual(0);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKGetAllMissions = EndPrepSDKCall();
	if (g_hSDKGetAllMissions == null) {
		SetFailState("GetAllMissions SDKCall invalid.");
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "KeyValues::GetName");
	PrepSDKCall_SetReturnInfo(SDKType_String, SDKPass_Pointer);
	g_hSDKKvGetName = EndPrepSDKCall();
	if (g_hSDKKvGetName == null) {
		SetFailState("KeyValues::GetName sig invalid.");
	}

	DynamicDetour hDetour = DynamicDetour.FromConf(hGameData, "OnGetMissionInfo");
	if (hDetour == null || !hDetour.Enable(Hook_Post, Detour_OnGetMissionInfo)) {
		SetFailState("Failed to detour \"CTerrorGameRules::GetMissionInfo\".");
	}

	delete hGameData;

	g_smInitialMelee = new StringMap();

	g_hCvarMeleeSpawn = CreateConVar("l4d2_melee_spawn", "", "Melee weapon list for unlock, use ',' to separate between names, e.g: pitchfork,shovel. Empty for no change");
	g_hCvarAddMelee = CreateConVar("l4d2_add_melee", "", "Add melee weapons to map basis melee spawn or l4d2_melee_spawn, use ',' to separate between names. Empty for don't add");
}

public void OnMapEnd()
{
	RestoreMissionInfo();
}

public void OnPluginEnd()
{
	RestoreMissionInfo();
}

void RestoreMissionInfo()
{
	if (g_sMissionName[0] == '\0') {
		return;
	}

	// GetMissionInfo returns engine-owned data which can be freed by a mission reload.
	// Resolve the name against the current registry; never dereference the old result.
	Address pMissions = SDKCall(g_hSDKGetAllMissions, g_pMatchExtL4D);
	if (pMissions != Address_Null) {
		char sPath[PLATFORM_MAX_PATH + 16], sCurrent[MELEE_LIST_LENGTH];
		FormatEx(sPath, sizeof(sPath), "%s/meleeweapons", g_sMissionName);
		SDKCall(g_hSDKKvGetString, pMissions, sCurrent, sizeof(sCurrent), sPath, "");
		// Missing data was already discarded/reloaded. Do not recreate removed missions.
		if (sCurrent[0] != '\0' && strcmp(sCurrent, g_sAppliedMelee) == 0
			&& strcmp(sCurrent, g_sMissionMelee) != 0) {
			SDKCall(g_hSDKKvSetString, pMissions, sPath, g_sMissionMelee);
		}
	}
	g_sMissionName[0] = '\0';
}

MRESReturn Detour_OnGetMissionInfo(DHookReturn hReturn)
{
	// The list is read while the map loads, later calls are left alone.
	if (GetGameTime() > 5.0) {
		return MRES_Ignored;
	}

	Address pMissionInfo = hReturn.Value;
	if (pMissionInfo == Address_Null) {
		return MRES_Ignored;
	}

	char sMissionKey[PLATFORM_MAX_PATH], sInitial[MELEE_LIST_LENGTH];
	SDKCall(g_hSDKKvGetName, pMissionInfo, sMissionKey, sizeof(sMissionKey));
	if (sMissionKey[0] == '\0' || StrContains(sMissionKey, "/") != -1) {
		return MRES_Ignored;
	}

	if (!g_smInitialMelee.GetString(sMissionKey, sInitial, sizeof(sInitial))) {
		SDKCall(g_hSDKKvGetString, pMissionInfo, sInitial, sizeof(sInitial), "meleeweapons", "");

		if (sInitial[0] == '\0') {
			strcopy(sInitial, sizeof(sInitial), DEFAULT_MELEE_LIST);
			SDKCall(g_hSDKKvSetString, pMissionInfo, "meleeweapons", sInitial);
		}

		g_smInitialMelee.SetString(sMissionKey, sInitial, false);
	}

	if (strcmp(g_sMissionName, sMissionKey) != 0) {
		RestoreMissionInfo();
	}

	strcopy(g_sMissionName, sizeof(g_sMissionName), sMissionKey);
	strcopy(g_sMissionMelee, sizeof(g_sMissionMelee), sInitial);
	strcopy(g_sAppliedMelee, sizeof(g_sAppliedMelee), sInitial);

	char sSpawn[MELEE_LIST_LENGTH], sAdd[MELEE_LIST_LENGTH];
	g_hCvarMeleeSpawn.GetString(sSpawn, sizeof(sSpawn));
	g_hCvarAddMelee.GetString(sAdd, sizeof(sAdd));
	ReplaceString(sSpawn, sizeof(sSpawn), " ", "");
	ReplaceString(sAdd, sizeof(sAdd), " ", "");

	// Nothing configured, make sure the mission has its own list.
	if (sSpawn[0] == '\0' && sAdd[0] == '\0') {
		char sCurrent[MELEE_LIST_LENGTH];
		SDKCall(g_hSDKKvGetString, pMissionInfo, sCurrent, sizeof(sCurrent), "meleeweapons", "");

		if (strcmp(sCurrent, sInitial) != 0) {
			SDKCall(g_hSDKKvSetString, pMissionInfo, "meleeweapons", sInitial);
		}

		return MRES_Ignored;
	}

	ReplaceString(sInitial, sizeof(sInitial), ";", ",");
	if (sSpawn[0] == '\0') {
		strcopy(sSpawn, sizeof(sSpawn), sInitial);
	}

	char sBase[MELEE_MAX_ENTRIES][MELEE_NAME_LENGTH], sExtra[MELEE_MAX_ENTRIES][MELEE_NAME_LENGTH];
	int iBaseCount = ExplodeString(sSpawn, ",", sBase, sizeof(sBase), sizeof(sBase[]));
	int iExtraCount = ExplodeString(sAdd, ",", sExtra, sizeof(sExtra), sizeof(sExtra[]));

	// Append the added weapons that aren't in the list yet.
	for (int i = 0; i < iExtraCount; i++) {
		if (sExtra[i][0] == '\0' || IsInList(sExtra[i], sBase, iBaseCount)) {
			continue;
		}

		Format(sSpawn, sizeof(sSpawn), "%s,%s", sSpawn, sExtra[i]);
	}

	// Same as the mission's own list, nothing to change.
	if (strcmp(sSpawn, sInitial) == 0) {
		return MRES_Ignored;
	}

	ReplaceString(sSpawn, sizeof(sSpawn), ",", ";");
	SDKCall(g_hSDKKvSetString, pMissionInfo, "meleeweapons", sSpawn);
	strcopy(g_sAppliedMelee, sizeof(g_sAppliedMelee), sSpawn);

	return MRES_Ignored;
}

bool IsInList(const char[] sName, const char[][] sList, int iCount)
{
	for (int i = 0; i < iCount; i++) {
		if (strcmp(sName, sList[i], false) == 0) {
			return true;
		}
	}

	return false;
}
