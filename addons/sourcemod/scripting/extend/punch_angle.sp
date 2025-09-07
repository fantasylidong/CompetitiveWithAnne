#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <clientprefs>

// ★ 可选依赖 RPG（有就用，没有继续走 Cookie）
#undef REQUIRE_PLUGIN
#include <rpg>

#define PLUGIN_VERSION 		"1.3"
#define GAMEDATA_FILE  		"punch_angle"
#define COOKIE_NAME	   		"punch_angle_cookie"
#define TRANSLATION_FILE 	"punch_angle.phrases"

ConVar
	g_cvZGunVerticalPu,
	g_cvToggle;

Cookie g_hCookie = null;

bool g_bEnable = true;
bool g_bClientCookie[MAXPLAYERS + 1] = { false, ... };
bool g_bRPG = false;

public Plugin myinfo =
{
	name = "[L4D2] Punch Angle (RPG-aware)",
	author = "sorallll, blueblur, + morzlee/ChatGPT",
	description = "Remove recoil when shooting and getting hit. Uses RPG if present.",
	version	= PLUGIN_VERSION,
	url	= "https://github.com/blueblur0730/modified-plugins"
};

// ===== RPG 库检测 =====
public void OnAllPluginsLoaded()                     { g_bRPG = LibraryExists("rpg"); }
public void OnLibraryAdded(const char[] name)        { if (StrEqual(name, "rpg")) g_bRPG = true; }
public void OnLibraryRemoved(const char[] name)      { if (StrEqual(name, "rpg")) g_bRPG = false; }

// Startup
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion version = GetEngineVersion();
	if (version != Engine_Left4Dead2)
	{
		strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game");
		return APLRes_SilentFailure;
	}

	RegPluginLibrary("punch_angle");
	return APLRes_Success;
}

public void OnPluginStart()
{
	IniGameData();
	LoadTranslation(TRANSLATION_FILE);
	CreateConVar("punch_angle_version", PLUGIN_VERSION, "Version of the Punch Angle plugin.",
		FCVAR_NOTIFY | FCVAR_DEVELOPMENTONLY | FCVAR_DONTRECORD);

	g_hCookie = new Cookie(COOKIE_NAME, "Toggles recoil on or off.", CookieAccess_Protected);
	g_hCookie.SetPrefabMenu(CookieMenu_OnOff, "Punch Angle Toggle", CookieSelected, g_hCookie);

	// this cvar reduces recoil when shooting.
	g_cvZGunVerticalPu			= FindConVar("z_gun_vertical_punch");
	if (g_cvZGunVerticalPu != null) g_cvZGunVerticalPu.IntValue = 0;

	g_cvToggle					= CreateConVar("punch_angle_toggle", "1", "Toggles recoil on or off.",
		_, true, 0.0, true, 1.0);
	g_cvToggle.AddChangeHook(OnToggle);
	g_bEnable = g_cvToggle.BoolValue;

	// ★ 命令：玩家自助切换防抖
	RegConsoleCmd("sm_recoil", Cmd_ToggleRecoil);
	RegConsoleCmd("sm_punch",  Cmd_ToggleRecoil);
}

public void OnPluginEnd()
{
	if (g_cvZGunVerticalPu != null)
	{
		// prevent this from replicating to clients.
		g_cvZGunVerticalPu.RestoreDefault(true, false);
	}
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client)) return;

	// ★ 优先 RPG 值
	if (g_bRPG)
	{
		int v = L4D_RPG_GetValue(client, INDEX_RECOIL);
		if (v != -1)
		{
			g_bClientCookie[client] = (v != 0);
			if (g_cvZGunVerticalPu != null)
				g_cvZGunVerticalPu.ReplicateToClient(client, g_bClientCookie[client] ? "0" : "1");
			return;
		}
	}
	// RPG 不可用/失败 → Cookie 流程由 OnClientCookiesCached 覆盖
}

public void OnRPGRecoilChanged(int client, int enabled )
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return;

    g_bClientCookie[client] = (enabled != 0);

    if (g_cvZGunVerticalPu != null)
		g_cvZGunVerticalPu.ReplicateToClient(client, g_bClientCookie[client] ? "0" : "1");
}

public void OnClientCookiesCached(int client)
{
	if (IsFakeClient(client))
		return;

	// ★ 再次尝试 RPG（若库刚刚加载/延迟）
	if (g_bRPG)
	{
		int v = L4D_RPG_GetValue(client, INDEX_RECOIL);
		if (v != -1)
		{
			g_bClientCookie[client] = (v != 0);
			if (g_cvZGunVerticalPu != null)
				g_cvZGunVerticalPu.ReplicateToClient(client, g_bClientCookie[client] ? "0" : "1");
			return;
		}
	}

	// Cookie 回退
	char value[4];
	g_hCookie.Get(client, value, sizeof(value));
	if (value[0] == '\0' || StrEqual(value, "On"))
	{
		g_hCookie.Set(client, "On");
		if (g_cvZGunVerticalPu != null)
			g_cvZGunVerticalPu.ReplicateToClient(client, "0");
		g_bClientCookie[client] = true;
	}
	else
	{
		if (g_cvZGunVerticalPu != null)
			g_cvZGunVerticalPu.ReplicateToClient(client, "1");
		g_bClientCookie[client] = false;
	}
}

void CookieSelected(int client, CookieMenuAction action, Cookie info, char[] buffer, int maxlen)
{
	if (action == CookieMenuAction_DisplayOption)
	{
		PrintToChat(client, "%t", "Select");
	}
	else
	{
		char value[4];
		info.Get(client, value, sizeof(value));
		PrintToChat(client, "%t", "CookieSlected", value);	  // Punch Angle Toggle: %s
	}
}

// ★ 命令：切换并写回 RPG（若可用），否则写回 Cookie
public Action Cmd_ToggleRecoil(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;

	g_bClientCookie[client] = !g_bClientCookie[client];

	if (g_bRPG)
	{
		L4D_RPG_SetValue(client, INDEX_RECOIL, g_bClientCookie[client] ? 1 : 0);
	}
	else
	{
		g_hCookie.Set(client, g_bClientCookie[client] ? "On" : "Off");
	}

	if (g_cvZGunVerticalPu != null)
		g_cvZGunVerticalPu.ReplicateToClient(client, g_bClientCookie[client] ? "0" : "1");

	if (g_bClientCookie[client]) PrintToChat(client, "%t", "Recoil_On");
	else                         PrintToChat(client, "%t", "Recoil_Off");

	return Plugin_Handled;
}

// This removed recoil when you are getting hit.
MRESReturn DD_CBasePlayer_SetPunchAngle_Pre(int pThis, DHookReturn hReturn)
{
	if (GetClientTeam(pThis) != 2 || !IsPlayerAlive(pThis))
		return MRES_Ignored;

	if (g_bEnable && g_bClientCookie[pThis])
	{
		hReturn.Value = 0;
		return MRES_Supercede;
	}

	return MRES_Ignored;
}

void OnToggle(ConVar convar, char[] old_value, char[] new_value)
{
	g_bEnable = convar.BoolValue;
}

void IniGameData()
{
	char buffer[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, buffer, sizeof buffer, "gamedata/%s.txt", GAMEDATA_FILE);
	if (!FileExists(buffer))
		SetFailState("\n==========\nMissing required file: \"%s\".\n==========", buffer);

	GameData hGameData = new GameData(GAMEDATA_FILE);
	if (!hGameData)
		SetFailState("Failed to load gamedata file \"" ... GAMEDATA_FILE... "\".");

	DynamicDetour hDetour = DynamicDetour.FromConf(hGameData, "DD::CBasePlayer::SetPunchAngle");
	if (!hDetour)
		SetFailState("Failed to create DynamicDetour: \"DD::CBasePlayer::SetPunchAngle\"");

	if (!hDetour.Enable(Hook_Pre, DD_CBasePlayer_SetPunchAngle_Pre))
		SetFailState("Failed to detour pre: \"DD::CBasePlayer::SetPunchAngle\"");

	delete hDetour;
	delete hGameData;
}

stock void LoadTranslation(const char[] translation)
{
	char sPath[PLATFORM_MAX_PATH], sName[64];

	Format(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}
