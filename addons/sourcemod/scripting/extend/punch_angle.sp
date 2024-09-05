#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <dhooks>
#undef REQUIRE_PLUGIN
#include <rpg>
#define PLUGIN_NAME				"Punch Angle"
#define PLUGIN_AUTHOR			"sorallll, 东"
#define PLUGIN_DESCRIPTION		"去除开枪抖动"
#define PLUGIN_VERSION			"1.1.0"
#define PLUGIN_URL				""

#define GAMEDATA				"punch_angle"

ConVar
	g_cvZGunVerticalPu;

public Plugin myinfo = {
	name = PLUGIN_NAME,
	author = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = PLUGIN_URL
};
bool
	g_bRPGSystemAvailable = false;

//Startup
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	//API
	RegPluginLibrary("punch_angle");
	return APLRes_Success;
}

public void OnAllPluginsLoaded(){
	g_bRPGSystemAvailable = LibraryExists("rpg");
}
public void OnLibraryAdded(const char[] name)
{
    if ( StrEqual(name, "rpg") ) { g_bRPGSystemAvailable = true; }
}
public void OnLibraryRemoved(const char[] name)
{
    if ( StrEqual(name, "rpg") ) { g_bRPGSystemAvailable = false; }
}

public void OnPluginStart() {
	char buffer[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, buffer, sizeof buffer, "gamedata/%s.txt", GAMEDATA);
	if (!FileExists(buffer))
		SetFailState("\n==========\nMissing required file: \"%s\".\n==========", buffer);

	GameData hGameData = new GameData(GAMEDATA);
	if (!hGameData)
		SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	DynamicDetour dDetour = DynamicDetour.FromConf(hGameData, "DD::CBasePlayer::SetPunchAngle");
	if (!dDetour)
		SetFailState("Failed to create DynamicDetour: \"DD::CBasePlayer::SetPunchAngle\"");

	if (!dDetour.Enable(Hook_Pre, DD_CBasePlayer_SetPunchAngle_Pre))
		SetFailState("Failed to detour pre: \"DD::CBasePlayer::SetPunchAngle\"");

	delete hGameData;

	g_cvZGunVerticalPu = FindConVar("z_gun_vertical_punch");
}

public void OnPluginEnd() {
	g_cvZGunVerticalPu.RestoreDefault();
}

public void OnConfigsExecuted() {
	g_cvZGunVerticalPu.IntValue = 0;
}

MRESReturn DD_CBasePlayer_SetPunchAngle_Pre(int pThis, DHookReturn hReturn, DHookParam hParams) {
	/*if (pThis < 1 || pThis > MaxClients || !IsClientInGame(pThis))
		return MRES_Ignored;*/

	if (GetClientTeam(pThis) != 2 || !IsPlayerAlive(pThis) || (g_bRPGSystemAvailable && L4D_RPG_GetValue(pThis ,INDEX_RECOIL)))
		return MRES_Ignored;

	hReturn.Value = 0;
	return MRES_Supercede;
}