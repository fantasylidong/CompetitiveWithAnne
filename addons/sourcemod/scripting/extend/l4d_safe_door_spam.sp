/*
*	Saferoom Door Spam Protection
*	Copyright (C) 2022 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION		"1.21"

/*=======================================================================================
	Plugin Info:

*	Name	:	[L4D & L4D2] Saferoom Door Spam Protection
*	Author	:	SilverShot
*	Descrp	:	Control opening of first saferoom door prevent spamming the last door.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=324394
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.21 (10-May-2022)
	- Now requires "Left4DHooks" plugin version 1.101 or newer to accurately get the first and last saferoom doors.

	- Added Spanish translations. Thanks to "Toranks" for providing.
	- Changed cvar "l4d_safe_spam_fall_time" to make the saferoom door fall after "l4d_safe_spam_fall_touch*" and "l4d_safe_spam_lock*" cvars unlock the door.
	- Renamed cvars "l4d_safe_spam_fall_touch" and "l4d_safe_spam_fall_touch_2" to "l4d_safe_spam_touch" and "l4d_safe_spam_touch_2" as they only control unlocking after touching.
	- Fixed the plugin not locking the first saferoom door when the "l4d_safe_spam_open" cvar was set to "0".
	- Fixed not always preventing doors from being locked on certain levels.
	- Fixed some conflicts when the last saferoom door was locked by other plugins. Thanks to "Voevoda" for reporting.

	- Thanks to "Voevoda" and "Toranks" for testing.

1.20 (09-May-2022)
	- Fixed the saferoom door not unlocking when the "l4d_safe_spam_fall_touch" cvars are 0.0.
	- Fixed the saferoom door auto falling before the timer expires when only using the "l4d_safe_spam_lock" cvars.
	- Time hint until unlocked is now only displayed once per second. These hints are only shown to the user attempting to open the saferoom door.

1.19 (08-May-2022)
	- Added cvars "l4d_safe_spam_fall_touch" and "l4d_safe_spam_fall_touch_2" to determine how long after someone tries to open the first saferoom door before it falls.
	- Added cvars "l4d_safe_spam_lock" and "l4d_safe_spam_lock_2" to determine how long the first saferoom door should remain locked after round start.
	- Both cvars allow for setting the time on the second round of versus and for round restarts in coop.
	- Changed cvar "l4d_safe_spam_hint" to allow showing hints when the saferoom door is automatically opened.
	- Thanks to "Voevoda" for the feature requests and lots of help testing.

	- Translation files updated. Thanks to "KasperH" and "Voevoda" for updating the Hungarian and Russian translations respectively.

1.18 (01-Sep-2021)
	- Fixed a 2nd door dropping when used enough. Thanks to "Primeas" for reporting.
	- Fixed "in solid list (not solid)" server console spam. Thanks to "Tonblader" for reporting.

1.17 (26-Aug-2021)
	- Fixed the door sometimes interfering instead of being non-solid. Thanks to "Ja-Forces" for reporting.

1.16 (26-Aug-2021)
	- Fixed crashing in L4D1. Thanks to "Ja-Forces" for reporting.
	- Restricted the "l4d_safe_spam_skin" cvar to L4D2 only.

1.15 (26-Aug-2021)
	- Fixed playing the incorrect unlock sound when the "l4d_safe_spam_open" cvar was set to "0". Thanks to "TBK Duy" for reporting.

1.14 (24-Aug-2021)
	- Fixed using the wrong falling sounds when changing door skins. Thanks to "Tonblader" for reporting.

1.13 (21-Aug-2021)
	- Fixed using the wrong door sounds when changing door skins. Thanks to "Tonblader" for reporting.
	- Fixed some doors falling the wrong way when changing door skins. Thanks to "Tonblader" for reporting.
	- Fixed some doors using the wrong angle when changing door skins.
	- Fixed the saferoom door auto falling if the "l4d_safe_spam_open" cvar was set to 1.

1.12a (17-Aug-2021)
	- Added Hungarian translations. Thanks to "KasperH" for providing.

1.12 (13-Aug-2021)
	- Added cvar "l4d_safe_spam_skin" to control the skin of Saferoom Doors. Requested by "Tonblader".

1.11 (05-Jul-2021)
	- L4D2: plugin compatibility update with "[L4D2] Saferoom Lock: Scavenge" plugin by "Eärendil" version 1.2+ only.
	- Thanks to "GL_INS" for reporting and testing.
	- Thanks to "Eärendil" for supporting the compatibility.

	- Changed method of locking doors after opening/closing. No more hackish workarounds.
	- Fixed some saferoom doors falling the wrong way when "l4d_safe_spam_physics" cvar was enabled.
	- Should now correctly detect the starting saferoom door for auto falling. Thanks to "Krevik" for reporting.

1.10 (30-Jun-2021)
	- Fixed the saferoom door not auto falling on some maps.
	- Now displays the handle falling.
	- Now swaps attachments from the old door to the new door.
	- Now supports multiple ending saferoom doors.

1.9 (26-Jun-2021)
	- Fixed cvar "l4d_safe_spam_fall_time" value "0.0" from making the door auto fall. Thanks to "Primeas" for reporting.

1.8 (21-Jun-2021)
	- Fixed not using an entity reference which could rarely throw errors otherwise.

	- Modified update from "pan0s" adding auto falling saferoom door feature.
	- Added cvar "l4d_safe_spam_fall_time" to control if the first saferoom door auto falls.
	- Added command "sm_door_last" to make a locked saferoom door fall over. Should mostly be the first saferoom door.

1.7 (15-Feb-2021)
	- Added cvar "l4d_safe_spam_physics" to allow the doors physics to persist or freeze after a specified amount of time. Requested by "yzybb".
	- Added Russian translations. Thanks to "Kleiner" for providing.

1.6 (05-Oct-2020)
	- Added cvar "l4d_safe_spam_last" to control the last saferoom door state on round start: opened, closed or map default. Thanks to "Tonblader" for requesting.

1.5 (20-Sep-2020)
	- Blocked door falling on L4D2 "Questionable Ethics" 2nd map (qe2_ep2) to prevent breaking gameplay. Thanks to "Alex101192" for reporting.
	- Fixed the door not always falling in the right direction on some maps.

1.4 (20-Sep-2020)
	- Added a sound effect for when the door breaks and falls.
	- Fixed the door not always falling on some maps.

1.3 (18-Sep-2020)
	- Changed cvar "l4d_safe_spam_open" adding option "2" to make the door fall. Thanks to "yzybb" for requesting.

1.2 (05-Jun-2020)
	- Added cvar "l4d_safe_spam_hint" to control displaying messages when saferoom doors are opened/closed.
	- Added translations support. Thanks to "Tonblader" for requesting.

1.1 (15-May-2020)
	- Initial release.

1.0 (30-Aug-2013)
	- Initial creation.

======================================================================================*/

#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <left4dhooks>

#define CVAR_FLAGS				FCVAR_NOTIFY

#define SOUND_BREAK1			"physics/metal/metal_box_break1.wav"
#define SOUND_BREAK2			"physics/metal/metal_box_break2.wav"
#define SOUND_BREAK3			"physics/wood/wood_crate_break4.wav"
#define SOUND_BREAK4			"physics/wood/wood_crate_break5.wav"
#define SOUND_DOOR_D1			"doors/door_metal_large_open1.wav"
#define SOUND_DOOR_D2			"doors/door_checkpoint_close1.wav"
#define SOUND_DOOR_LS1			"doors/door_metal_gate_close1.wav"
#define SOUND_DOOR_LS2			"doors/door1_stop.wav"
#define SOUND_DOOR_LSU			"doors/CheckpointPlankRemove.wav"
#define SOUND_DOOR_LSU2			"doors/CheckpointPlankRemove2.wav"
#define SOUND_DOOR_DEU			"doors/CheckpointBarRemove.wav"

#define MODEL_BOUNDING			"models/props/cs_militia/silo_01.mdl"
#define MODEL_DEFAULT1			"models/props_doors/checkpoint_door_01.mdl"
#define MODEL_DEFAULT2			"models/props_doors/checkpoint_door_-02.mdl"
#define MODEL_OTHER01			"models/props_doors/checkpoint_door_-01.mdl"
#define MODEL_STAND1			"models/lighthouse/checkpoint_door_lighthouse01.mdl"
#define MODEL_STAND2			"models/lighthouse/checkpoint_door_lighthouse02.mdl"
#define MODEL_STANDM			"models/lighthouse/checkpoint_door_lighthouse01_metal.mdl"


ConVar g_hCvarAllow, g_hCvarMPGameMode, g_hCvarModes, g_hCvarModesOff, g_hCvarModesTog, g_hCvarHint, g_hCvarLast, g_hCvarOpen, g_hCvarSkin, g_hCvarPhysics, g_hCvarTimeClose, g_hCvarLock, g_hCvarLock2, g_hCvarTimeOpen, g_hCvarType, g_hCvarFallTime, g_hCvarTouch, g_hCvarTouch2;
bool g_bCvarAllow, g_bMapStarted, g_bMapBlocked, g_bLeft4Dead2, g_bGameStart, g_bRestarted, g_bOpened, g_bTimer, g_bBlock;
int g_iRoundStart, g_iPlayerSpawn, g_iLastDoor, g_iDoorType[2048], g_iFirstFlags, g_iLastFlags, g_iCvarHint, g_iCvarLast, g_iCvarOpen, g_iCvarSkin, g_iCvarType, g_iLockedDoor, g_iHint[MAXPLAYERS+1];
float g_fLastDoor, g_fTimeLock, g_fTimeFall, g_fUseTime, g_fCvarPhysics, g_fCvarTimeClose, g_fCvarLock, g_fCvarLock2, g_fCvarTimeOpen, g_fCvarFallTime, g_fCvarTouch, g_fCvarTouch2;
Handle g_hTimerFall, g_hLastTimer;

bool g_bSaferoomLocked; // Prevent forcing doors shut when another plugin is doing so. This prevents a recursive loop between the plugins causing a memory leak - This was prevalent in the old version using RequestFrame.
bool g_bSoundHooked, g_bSoundWatch, g_bSoundHookDone; // Replace sounds when changing door skin
// l4d_safe_spam_open 1; l4d_safe_spam_skin 2;

enum
{
	TYPE_DEFAULT,
	TYPE_OTHER01,
	TYPE_STAND
}



// ====================================================================================================
//					PLUGIN INFO / START
// ====================================================================================================
public Plugin myinfo =
{
	name = "[L4D & L4D2] Saferoom Door Spam Protection",
	author = "SilverShot",
	description = "Control opening of first saferoom door prevent spamming the last door.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=324394"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test == Engine_Left4Dead ) g_bLeft4Dead2 = false;
	else if( test == Engine_Left4Dead2 ) g_bLeft4Dead2 = true;
	else
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	ConVar version = FindConVar("left4dhooks_version");
	if( version != null )
	{
		char sVer[16];
		version.GetString(sVer, sizeof(sVer));

		float ver = StringToFloat(sVer);
		if( ver >= 1.101 )
		{
			return;
		}
	}

	SetFailState("This plugin requires Left4DHooks version 1.01 or newer. Please update.");
}



// ==================================================
// 					PLUGIN START
// ==================================================
public void OnPluginStart()
{
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "translations/safe_door_spam.phrases.txt");
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	LoadTranslations("safe_door_spam.phrases");

	g_hCvarAllow =		CreateConVar(	"l4d_safe_spam_allow",			"1",			"0=Plugin off, 1=Plugin on.", CVAR_FLAGS);
	g_hCvarModes =		CreateConVar(	"l4d_safe_spam_modes",			"",				"Turn on the plugin in these game modes, separate by commas (no spaces). (Empty = all).", CVAR_FLAGS);
	g_hCvarModesOff =	CreateConVar(	"l4d_safe_spam_modes_off",		"",				"Turn off the plugin in these game modes, separate by commas (no spaces). (Empty = none).", CVAR_FLAGS);
	g_hCvarModesTog =	CreateConVar(	"l4d_safe_spam_modes_tog",		"0",			"Turn on the plugin in these game modes. 0=All, 1=Coop, 2=Survival, 4=Versus, 8=Scavenge. Add numbers together.", CVAR_FLAGS);
	g_hCvarFallTime =	CreateConVar(	"l4d_safe_spam_fall_time",		"0.0",			"0.0=Off. How many seconds after round start (or after unlocking by l4d_safe_spam_lock* and l4d_safe_spam_lock* cvars) until the locked saferoom door will automatically fall. Unless manually opened.", CVAR_FLAGS);
	g_hCvarHint =		CreateConVar(	"l4d_safe_spam_hint",			"0",			"0=Off. 1=Display a message showing who opened or closed the saferoom door. 2=Display a message when saferoom door is auto unlocked (_touch and _lock cvars). 3=Both.", CVAR_FLAGS);
	g_hCvarLast =		CreateConVar(	"l4d_safe_spam_last",			"0",			"Final door state on round start: 0=Use map default. 1=Close last door. 2=Open last door.", CVAR_FLAGS);
	g_hCvarLock =		CreateConVar(	"l4d_safe_spam_lock",			"0.0",			"0.0=Off. How many seconds after round start will the saferoom door remain locked.", CVAR_FLAGS);
	g_hCvarLock2 =		CreateConVar(	"l4d_safe_spam_lock_2",			"0.0",			"0.0=Off. How many seconds after round start will the saferoom door remain locked. For the second+ round of a map.", CVAR_FLAGS);
	g_hCvarTouch =		CreateConVar(	"l4d_safe_spam_touch",			"0.0",			"0.0=Off. How many seconds after attempting to open the locked saferoom door until it will unlock (overrides the _time cvar).", CVAR_FLAGS);
	g_hCvarTouch2 =		CreateConVar(	"l4d_safe_spam_touch_2",		"0.0",			"0.0=Off. How many seconds after attempting to open the locked saferoom door until it will unlock (overrides the _time cvar). For the second+ round of a map.", CVAR_FLAGS);
	g_hCvarOpen =		CreateConVar(	"l4d_safe_spam_open",			"2",			"0=Off, 1=Keep the first saferoom door open once opened, 2=Make the first saferoom door fall once opened.", CVAR_FLAGS);
	g_hCvarPhysics =	CreateConVar(	"l4d_safe_spam_physics",		"3.0",			"0.0=Always has physics. How many seconds until the fallen doors physics are disabled.", CVAR_FLAGS);
	if( g_bLeft4Dead2 )
		g_hCvarSkin =	CreateConVar(	"l4d_safe_spam_skin",			"0",			"0=Map default. 1=Classic. 2=Last Stand. Which door model to use on the first and last saferooms.", CVAR_FLAGS);
	g_hCvarTimeClose =	CreateConVar(	"l4d_safe_spam_time_close",		"0.0",			"How many seconds to block after closing the last saferoom door.", CVAR_FLAGS);
	g_hCvarTimeOpen =	CreateConVar(	"l4d_safe_spam_time_open",		"0.0",			"How many seconds to block after opening the last saferoom door.", CVAR_FLAGS);
	g_hCvarType =		CreateConVar(	"l4d_safe_spam_type",			"3",			"0=Off. When the last saferoom door is used enable the timeout on: 1=Open, 2=Close, 3=Both.", CVAR_FLAGS);

	CreateConVar(						"l4d_safe_spam_version",		PLUGIN_VERSION,	"Saferoom Door Spam Protection plugin version",	FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true, "l4d_safe_spam");

	g_hCvarMPGameMode = FindConVar("mp_gamemode");
	g_hCvarMPGameMode.AddChangeHook(ConVarChanged_Allow);
	g_hCvarAllow.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModes.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesOff.AddChangeHook(ConVarChanged_Allow);
	g_hCvarModesTog.AddChangeHook(ConVarChanged_Allow);
	g_hCvarFallTime.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarTouch.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarTouch2.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarHint.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarLast.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarPhysics.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarLock.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarLock2.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarOpen.AddChangeHook(ConVarChanged_Cvars);
	if( g_bLeft4Dead2 )
		g_hCvarSkin.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarTimeClose.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarTimeOpen.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarType.AddChangeHook(ConVarChanged_Cvars);

	RegAdminCmd("sm_door_drop", CmdDoorDrop, ADMFLAG_ROOT, "Test command to make a targeted door fall over (will likely only work correctly on Saferoom doors).");
	RegAdminCmd("sm_door_fall", CmdDoorLast, ADMFLAG_ROOT, "Test command to make the first locked saferoom door fall over.");
}

public Action CmdDoorDrop(int client, int args)
{
	int entity = GetClientAimTarget(client, false);
	if( entity != -1 )
	{
		char sClass[64];
		GetEdictClassname(entity, sClass, sizeof(sClass));
		if( strncmp(sClass, "prop_door", 9) == 0 )
		{
			// OnFrameOpen(entity);
			g_bBlock = false;
			OnFirst("", entity, 0, 0.0);
		}
	}

	return Plugin_Handled;
}

public Action CmdDoorLast(int client, int args)
{
	if( g_iLockedDoor == -1 || EntRefToEntIndex(g_iLockedDoor) == INVALID_ENT_REFERENCE )
	{
		ReplyToCommand(client, "Locked door not found.");
		return Plugin_Handled;
	}

	g_bBlock = false;
	OnFirst("", g_iLockedDoor, 0, 0.0);

	ReplyToCommand(client, "Locked door %d dropped", g_iLockedDoor);

	return Plugin_Handled;
}



// ====================================================================================================
//					FORWARDS FROM OTHER PLUGINS
// ====================================================================================================
public void SLS_OnDoorStatusChanged(bool locked)
{
	g_bSaferoomLocked = locked;
}



// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	IsAllowed();
}

public void ConVarChanged_Allow(Handle convar, const char[] oldValue, const char[] newValue)
{
	IsAllowed();
}

public void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	int last = g_iCvarOpen;

	g_iCvarHint = g_hCvarHint.IntValue;
	g_iCvarLast = g_hCvarLast.IntValue;
	g_fCvarPhysics = g_hCvarPhysics.FloatValue;
	g_fCvarLock = g_hCvarLock.FloatValue;
	g_fCvarLock2 = g_hCvarLock2.FloatValue;
	g_iCvarOpen = g_hCvarOpen.IntValue;
	if( g_bLeft4Dead2 )
		g_iCvarSkin = g_hCvarSkin.IntValue;
	g_fCvarTimeClose = g_hCvarTimeClose.FloatValue;
	g_fCvarTimeOpen = g_hCvarTimeOpen.FloatValue;
	g_iCvarType = g_hCvarType.IntValue;
	g_fCvarFallTime = g_hCvarFallTime.FloatValue;
	g_fCvarTouch = g_hCvarTouch.FloatValue;
	g_fCvarTouch2 = g_hCvarTouch2.FloatValue;

	if( last != g_iCvarOpen )
	{
		if( g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
		{
			UnhookSingleEntityOutput(g_iLockedDoor, "OnOpen", OnFirst);
		}

		if( g_iLastDoor && EntRefToEntIndex(g_iLastDoor) != INVALID_ENT_REFERENCE )
		{
			UnhookSingleEntityOutput(g_iLastDoor, "OnOpen", OnOpen);
			UnhookSingleEntityOutput(g_iLastDoor, "OnClose", OnClose);
		}
	}
}

void IsAllowed()
{
	bool bAllow = GetConVarBool(g_hCvarAllow);
	bool bAllowMode = IsAllowedGameMode();
	GetCvars();

	if( g_bCvarAllow == false && bAllow == true && bAllowMode == true )
	{
		g_bCvarAllow = true;
		InitPlugin();
		HookEvents(true);
	}
	else if( g_bCvarAllow == true && (bAllow == false || bAllowMode == false) )
	{
		g_bCvarAllow = false;
		HookEvents(false);
		ResetPlugin();

		delete g_hTimerFall;

		if( g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
		{
			UnhookSingleEntityOutput(g_iLockedDoor, "OnOpen", OnFirst);
		}

		if( g_iLastDoor && EntRefToEntIndex(g_iLastDoor) != INVALID_ENT_REFERENCE )
		{
			UnhookSingleEntityOutput(g_iLastDoor, "OnOpen", OnOpen);
			UnhookSingleEntityOutput(g_iLastDoor, "OnClose", OnClose);
		}
	}
}

int g_iCurrentMode;
bool IsAllowedGameMode()
{
	if( g_hCvarMPGameMode == null )
		return false;

	int iCvarModesTog = g_hCvarModesTog.IntValue;
	if( iCvarModesTog != 0 )
	{
		if( g_bMapStarted == false )
			return false;

		g_iCurrentMode = 0;

		int entity = CreateEntityByName("info_gamemode");
		if( IsValidEntity(entity) )
		{
			DispatchSpawn(entity);
			HookSingleEntityOutput(entity, "OnCoop", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnSurvival", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnVersus", OnGamemode, true);
			HookSingleEntityOutput(entity, "OnScavenge", OnGamemode, true);
			ActivateEntity(entity);
			AcceptEntityInput(entity, "PostSpawnActivate");
			if( IsValidEntity(entity) ) // Because sometimes "PostSpawnActivate" seems to kill the ent.
				RemoveEdict(entity); // Because multiple plugins creating at once, avoid too many duplicate ents in the same frame
		}

		if( g_iCurrentMode == 0 )
			return false;

		if( !(iCvarModesTog & g_iCurrentMode) )
			return false;
	}

	char sGameModes[64], sGameMode[64];
	g_hCvarMPGameMode.GetString(sGameMode, sizeof(sGameMode));
	Format(sGameMode, sizeof(sGameMode), ",%s,", sGameMode);

	g_hCvarModes.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) == -1 )
			return false;
	}

	g_hCvarModesOff.GetString(sGameModes, sizeof(sGameModes));
	if( sGameModes[0] )
	{
		Format(sGameModes, sizeof(sGameModes), ",%s,", sGameModes);
		if( StrContains(sGameModes, sGameMode, false) != -1 )
			return false;
	}

	return true;
}

public void OnGamemode(const char[] output, int caller, int activator, float delay)
{
	if( strcmp(output, "OnCoop") == 0 )
		g_iCurrentMode = 1;
	else if( strcmp(output, "OnSurvival") == 0 )
		g_iCurrentMode = 2;
	else if( strcmp(output, "OnVersus") == 0 )
		g_iCurrentMode = 4;
	else if( strcmp(output, "OnScavenge") == 0 )
		g_iCurrentMode = 8;
}



// ====================================================================================================
//					EVENTS
// ====================================================================================================
void HookEvents(bool hook)
{
	if( hook )
	{
		HookEvent("round_end",			Event_RoundEnd,		EventHookMode_PostNoCopy);
		HookEvent("round_start",		Event_RoundStart,	EventHookMode_PostNoCopy);
		HookEvent("player_spawn",		Event_PlayerSpawn,	EventHookMode_PostNoCopy);
		HookEvent("player_team",		Event_PlayerTeam);
		HookEvent("door_open",			Event_DoorOpen);
		HookEvent("door_close",			Event_DoorClose);
		if( g_bLeft4Dead2 )
			HookEvent("player_use",		Event_PlayerUse);
	}
	else
	{
		UnhookEvent("round_end",		Event_RoundEnd,		EventHookMode_PostNoCopy);
		UnhookEvent("round_start",		Event_RoundStart,	EventHookMode_PostNoCopy);
		UnhookEvent("player_spawn",		Event_PlayerSpawn,	EventHookMode_PostNoCopy);
		UnhookEvent("player_team",		Event_PlayerTeam);
		UnhookEvent("door_open",		Event_DoorOpen);
		UnhookEvent("door_close",		Event_DoorClose);
		if( g_bLeft4Dead2 )
			UnhookEvent("player_use",	Event_PlayerUse);
	}
}

public void OnMapStart()
{
	PrecacheSound(SOUND_BREAK1);
	PrecacheSound(SOUND_BREAK2);
	PrecacheSound(SOUND_BREAK3);
	PrecacheSound(SOUND_BREAK4);
	PrecacheSound(SOUND_DOOR_D1);
	PrecacheSound(SOUND_DOOR_D2);
	PrecacheSound(SOUND_DOOR_LS1);
	PrecacheSound(SOUND_DOOR_LS2);
	PrecacheSound(SOUND_DOOR_LSU);
	PrecacheSound(SOUND_DOOR_LSU2);
	PrecacheSound(SOUND_DOOR_DEU);

	PrecacheModel(MODEL_DEFAULT1);
	PrecacheModel(MODEL_DEFAULT2);
	PrecacheModel(MODEL_STAND1);
	PrecacheModel(MODEL_STAND2);
	PrecacheModel(MODEL_STANDM);

	g_bMapStarted = true;

	if( g_bLeft4Dead2 )
	{
		char sMap[10];
		GetCurrentMap(sMap, sizeof(sMap));

		if( strcmp(sMap, "qe2_ep2") == 0 )
			g_bMapBlocked = true;
		else
			g_bMapBlocked = false;
	}
}

public Action OnSoundHook(int clients[64], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags)
{
	if( g_bSoundWatch )
	{
		// Should use "g_iDoorType[entity] == TYPE_STAND" instead of "g_iCvarSkin" to determine, but since the DoorType var doesn't exactly track the correct type this is safer, only breaks the sound if changing skin cvar after changing the model during gameplay.

		// if( g_iCvarSkin == 2 && strcmp(sample, SOUND_DOOR_DEU) == 0 )
		if( g_iCvarSkin == 2 && sample[0] == 'd' && sample[5] == '/' && sample[6] == 'C' && sample[16] == 'B' )
		{
			// PrintToChatAll("Changed1 %d [%s]", g_iCvarSkin, sample);
			sample = GetRandomInt(0, 1) == 0 ? SOUND_DOOR_LSU : SOUND_DOOR_LSU2;
			return Plugin_Changed;
		}
		// else if( g_iCvarSkin == 1 && strncmp(sample, SOUND_DOOR_LSU, 27) == 0 )
		else if( g_iCvarSkin == 1 && sample[0] == 'd' && sample[5] == '/' && sample[6] == 'C' && sample[16] == 'P' )
		{
			// PrintToChatAll("Changed2 %d [%s]", g_iCvarSkin, sample);
			sample = SOUND_DOOR_DEU;
			return Plugin_Changed;
		}
	}

	return Plugin_Continue;
}

public void OnMapEnd()
{
	g_bRestarted = false;
	g_bMapStarted = false;
	ResetPlugin();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRestarted = true;
	ResetPlugin();
}

void ResetPlugin()
{
	g_iRoundStart = 0;
	g_iPlayerSpawn = 0;
	g_fUseTime = 0.0;
	g_bBlock = false;
	g_bOpened = false;
	g_bGameStart = false;
	g_bSoundWatch = false;
	g_bSoundHookDone = false;
	g_bSaferoomLocked = false;

	for( int i = 1; i <= MaxClients; i++ )
	{
		g_iHint[i] = 0;
	}

	delete g_hTimerFall;
	delete g_hLastTimer;

	if( g_bSoundHooked )
	{
		g_bSoundHooked = false;
		RemoveNormalSoundHook(OnSoundHook);
	}
}

// Replace unlocking door sound
public void Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
	int entity = event.GetInt("targetid");
	if( EntIndexToEntRef(entity) == g_iLockedDoor && GetEntProp(entity, Prop_Send, "m_bLocked") == 1 )
	{
		if( g_bBlock && (GetGameTime() < g_fTimeLock || g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch) )
		{
			int client = GetClientOfUserId(event.GetInt("userid"));
			OnUseEntity(entity, client, 0, Use_On, 0.0);
		}

		if( g_bSoundHookDone == false )
		{
			g_bSoundHookDone = true;

			if( !g_bSoundHooked )
			{
				AddNormalSoundHook(OnSoundHook);
				CreateTimer(0.1, TimerRemoveSoundHook);
				g_bSoundHooked = true;
			}

			g_bSoundWatch = true;
		}
	}
}

public Action OnUseEntity(int entity, int client, int caller, UseType type, float value)
{
	if( entity > MaxClients && client && GetClientTeam(client) == 2 )
	{
		float gametime = GetGameTime();

		// Door set to auto open after X seconds?
		if( gametime < g_fTimeLock )
		{
			g_bBlock = true;

			// Reset lock
			if( !g_bTimer )
			{
				g_bTimer = true;
				g_iFirstFlags = GetEntProp(entity, Prop_Send, "m_spawnflags");
				CreateTimer(0.1, TimeResetFirst, _, TIMER_FLAG_NO_MAPCHANGE);
			}

			// Keep locked
			AcceptEntityInput(entity, "Close");
			AcceptEntityInput(entity, "Lock");

			SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
			SetEntProp(entity, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent

			// Auto open after touch timer
			if( g_hTimerFall == null && g_fCvarFallTime )
			{
				float delay = g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch;
				if( delay == 0.0 )
				{
					g_fTimeFall = g_fTimeLock;

					if( g_fCvarFallTime )
					{
						g_hTimerFall = CreateTimer(g_fCvarFallTime + (g_fTimeLock - gametime), HandleAutoFallTimer, false, TIMER_FLAG_NO_MAPCHANGE);
					}
					// else
					CreateTimer(g_fTimeLock - gametime, HandleAutoUnlock, false, TIMER_FLAG_NO_MAPCHANGE);
				}
			}

			// Delay until open
			if( g_fUseTime != gametime )
			{
				g_fUseTime = gametime;

				float delay = g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch;
				int secs = RoundToCeil(g_fTimeLock - gametime + delay);
				if( secs != g_iHint[client] )
				{
					g_iHint[client] = secs;
					CPrintToChat(client, "%T", "Door_Wait", client, secs);
				}
			}
		}
		// Door set to auto open after X seconds when someone tries to open?
		else if( g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch )
		{
			g_bBlock = true;

			// Reset lock
			if( !g_bTimer )
			{
				g_bTimer = true;
				g_iFirstFlags = GetEntProp(entity, Prop_Send, "m_spawnflags");
				CreateTimer(0.1, TimeResetFirst, _, TIMER_FLAG_NO_MAPCHANGE);
			}

			// Keep locked
			AcceptEntityInput(entity, "Close");
			AcceptEntityInput(entity, "Lock");

			SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
			SetEntProp(entity, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent

			// Auto open after touch timer
			if( g_hTimerFall == null )
			{
				float delay = g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch;
				g_fTimeFall = gametime + delay;
				if( g_fCvarFallTime )
				{
					g_hTimerFall = CreateTimer(delay + g_fCvarFallTime, HandleAutoFallTimer, false, TIMER_FLAG_NO_MAPCHANGE);
				}
				// else
				CreateTimer(delay, HandleAutoUnlock, false, TIMER_FLAG_NO_MAPCHANGE);
			}

			// Delay until open
			if( g_fUseTime != gametime )
			{
				g_fUseTime = gametime;

				float time = g_fTimeFall - gametime;
				if( time < 0.0 ) time = 0.0;

				int secs = RoundToCeil(time);
				if( secs != g_iHint[client] )
				{
					g_iHint[client] = secs;
					CPrintToChat(client, "%T", "Door_Wait", client, secs);
				}
			}
		}

		if( !g_bTimer )
		{
			g_bBlock = false;

			AcceptEntityInput(entity, "Close");
			AcceptEntityInput(entity, "Lock");

			SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
			SetEntProp(entity, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent

			SDKUnhook(entity, SDKHook_Use, OnUseEntity);
			RequestFrame(OnFrameUnblock);
		}

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnFrameUnblock()
{
	if( g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
	{
		SetEntProp(g_iLockedDoor, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSED);
		SetEntProp(g_iLockedDoor, Prop_Send, "m_spawnflags", g_iFirstFlags);
	}
}

public Action TimerRemoveSoundHook(Handle timer)
{
	if( g_bSoundHooked )
	{
		RemoveNormalSoundHook(OnSoundHook);
		g_bSoundHooked = false;
		g_bSoundWatch = false;
	}

	return Plugin_Continue;
}

public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if( g_fCvarFallTime && g_iCvarOpen != 1 )
	{
		int team = event.GetInt("team");
		if( team == 2 && !g_bGameStart )
		{
			g_bGameStart = true; // Game is ready to start.
			ReadyToFallLockedDoor();
		}
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iRoundStart == 1 && g_iPlayerSpawn == 0 )
		InitPlugin();
	g_iPlayerSpawn = 1;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if( g_iRoundStart == 0 && g_iPlayerSpawn == 1 )
		InitPlugin();
	g_iRoundStart = 1;
}

public void Event_DoorOpen(Event event, const char[] name, bool dontBroadcast)
{
	if( !g_bBlock && event.GetBool("checkpoint") )
	{
		DoorPrint(event, true);
		g_bOpened = true;
	}
}

public void Event_DoorClose(Event event, const char[] name, bool dontBroadcast)
{
	if( !g_bBlock && event.GetBool("checkpoint") )
		DoorPrint(event, false);
}

void DoorPrint(Event event, bool open)
{
	if( g_iCvarHint & 1 && g_fLastDoor < GetGameTime() + 0.05 )
	{
		int client = GetClientOfUserId(event.GetInt("userid"));
		if( client )
		{
			for( int i = 1; i <= MaxClients; i++ )
			{
				if( IsClientInGame(i) && !IsFakeClient(i) )
				{
					CPrintToChat(i, "%T", open ? "Door_Open" : "Door_Close", i, client);
				}
			}
		}
	}
}



// ====================================================================================================
//					SETUP / SOUND HOOK
// ====================================================================================================
void InitPlugin()
{
	int entity;
	g_bGameStart = true;
	g_bOpened = false;
	g_bTimer = false;
	g_fLastDoor = 0.0;
	g_fTimeLock = GetGameTime() + (g_bRestarted ? g_fCvarLock2 : g_fCvarLock);

	// Using Left4DHooks to find starting and ending saferoom doors
	g_iLockedDoor = L4D_GetCheckpointFirst();
	g_iLastDoor = L4D_GetCheckpointLast();

	if( g_iLockedDoor == -1 ) g_iLockedDoor = 0;
	if( g_iLastDoor == -1 ) g_iLastDoor = 0;

// PrintToServer("SAFE_SPAM A %d",g_iLockedDoor);
// PrintToServer("SAFE_SPAM B %d",g_iLastDoor);

	// First saferoom door
	if( g_iLockedDoor && GetEntProp(g_iLockedDoor, Prop_Send, "m_bLocked") == 1 )
	{
		entity = g_iLockedDoor;
		g_iLockedDoor = EntIndexToEntRef(g_iLockedDoor);

		// Rotate to correct angle if required
		g_iDoorType[entity] = TYPE_DEFAULT;

		if( g_bLeft4Dead2 )
		{
			if( g_iCvarSkin )
			{
				static char modelname[64];
				GetEntPropString(g_iLockedDoor, Prop_Data, "m_ModelName", modelname, sizeof(modelname));

				if( strcmp(modelname, MODEL_OTHER01) == 0 )
				{
					g_iDoorType[entity] = TYPE_OTHER01;

					float vAng[3], vPos[3];
					GetEntPropVector(g_iLockedDoor, Prop_Data, "m_angRotation", vAng);
					GetEntPropVector(g_iLockedDoor, Prop_Data, "m_vecOrigin", vPos);

					MoveSideway(vPos, vAng, vPos, 53.6);
					vAng[1] += 180.0;
					TeleportEntity(g_iLockedDoor, vPos, vAng, NULL_VECTOR);
				}
				else
				{
					g_iDoorType[entity] = TYPE_STAND;
				}
			}

			// Skin and sound
			switch( g_iCvarSkin )
			{
				case 1:
				{
					SetEntityModel(g_iLockedDoor, MODEL_DEFAULT1);
					SetEntPropString(g_iLockedDoor, Prop_Data, "m_SoundClose", "Doors.Checkpoint.FullClose1");
					SetEntPropString(g_iLockedDoor, Prop_Data, "m_SoundOpen", "Doors.Checkpoint.FullOpen1");
				}
				case 2:
				{
					SetEntityModel(g_iLockedDoor, MODEL_STAND1);
					SetEntPropString(g_iLockedDoor, Prop_Data, "m_SoundClose", "Doors.Glass.FullOpen1");
					SetEntPropString(g_iLockedDoor, Prop_Data, "m_SoundOpen", "Doors.Wood.FullOpen1");
					// SetEntPropString(g_iLockedDoor, Prop_Data, "m_SoundUnlock", "Doors.Wood.FullOpen1"); // Doesn't seem to work, requires sound hook override
					// SetEntPropString(g_iLockedDoor, Prop_Data, "m_ls.sUnlockedSound", "Doors.Wood.FullOpen1"); // Doesn't seem to work, requires sound hook override
				}
			}

			// Attach metal bars
			if( g_iCvarSkin == 2 )
			{
				int metal = CreateEntityByName("prop_dynamic");
				if( metal != -1 )
				{
					DispatchKeyValue(metal, "model", MODEL_STANDM);
					SetVariantString("!activator");
					AcceptEntityInput(metal, "SetParent", g_iLockedDoor);
					TeleportEntity(metal, view_as<float>({ -1.0, 0.0, 0.0}), view_as<float>({ 0.0, 0.0, 0.0}), NULL_VECTOR);
					DispatchSpawn(metal);
				}
			}
		}

		// Hooks for opening and closing, preventing open on round start
		if( g_iCvarOpen && !g_bMapBlocked )
		{
			if( g_iCvarOpen == 1 )
			{
				SetVariantString("OnOpen !self:Lock::0.0:-1");
				AcceptEntityInput(g_iLockedDoor, "AddOutput");
			} else {
				HookSingleEntityOutput(g_iLockedDoor, "OnOpen", OnFirst);
			}
		}

		if( (g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch) || (g_bRestarted ? g_fCvarLock2 : g_fCvarLock) )
		{
			SetEntProp(g_iLockedDoor, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
			SDKHook(g_iLockedDoor, SDKHook_Use, OnUseEntity);

			if( g_fCvarFallTime && (g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch) == 0.0 )
			{
				float delay = (g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch) + (g_bRestarted ? g_fCvarLock2 : g_fCvarLock);
				g_fTimeFall = GetGameTime() + delay + g_fCvarFallTime;
				g_hTimerFall = CreateTimer(delay + g_fCvarFallTime, HandleAutoFallTimer, true, TIMER_FLAG_NO_MAPCHANGE);
			}
		}
	} else {
		g_iLockedDoor = 0;
	}



	// Last saferoom door
	if( g_iLastDoor )
	{
		entity = g_iLastDoor;
		g_iLastDoor = EntIndexToEntRef(g_iLastDoor);

		// Rotate to correct angle if required
		g_iDoorType[entity] = TYPE_DEFAULT;

		if( g_bLeft4Dead2 )
		{
			if( g_iCvarSkin )
			{
				static char modelname[64];
				GetEntPropString(g_iLastDoor, Prop_Data, "m_ModelName", modelname, sizeof(modelname));

				if( strcmp(modelname, MODEL_OTHER01) == 0 )
				{
					g_iDoorType[entity] = TYPE_OTHER01;

					float vAng[3], vPos[3];
					GetEntPropVector(g_iLastDoor, Prop_Data, "m_angRotation", vAng);
					GetEntPropVector(g_iLastDoor, Prop_Data, "m_vecOrigin", vPos);

					MoveSideway(vPos, vAng, vPos, 53.6);
					vAng[1] += 180.0;
					TeleportEntity(g_iLastDoor, vPos, vAng, NULL_VECTOR);
				}
			}

			// Skin and sound
			switch( g_iCvarSkin )
			{
				case 1:
				{
					SetEntityModel(g_iLastDoor, MODEL_DEFAULT2);
					SetEntPropString(g_iLastDoor, Prop_Data, "m_SoundClose", "Doors.Checkpoint.FullClose1");
					SetEntPropString(g_iLastDoor, Prop_Data, "m_SoundOpen", "Doors.Checkpoint.FullOpen1");
				}
				case 2:
				{
					SetEntityModel(g_iLastDoor, MODEL_STAND2);
					SetEntPropString(g_iLastDoor, Prop_Data, "m_SoundClose", "Doors.Glass.FullOpen1");
					SetEntPropString(g_iLastDoor, Prop_Data, "m_SoundOpen", "Doors.Wood.FullOpen1");
					// SetEntPropString(g_iLastDoor, Prop_Data, "m_SoundUnlock", "Doors.Wood.FullOpen1"); // Doesn't seem to work, requires sound hook override
					// SetEntPropString(g_iLastDoor, Prop_Data, "m_ls.sUnlockedSound", "Doors.Wood.FullOpen1"); // Doesn't seem to work, requires sound hook override
				}
			}

			if( g_iCvarSkin )
			{
				for( int att = 0; att < 2048; att++ )
				{
					if( IsValidEdict(att) )
					{
						if( HasEntProp(att, Prop_Send, "moveparent") && GetEntPropEnt(att, Prop_Send, "moveparent") == g_iLastDoor )
						{
							SetVariantString("!activator");
							AcceptEntityInput(att, "SetParent", g_iLastDoor);
						}
					}
				}
			}
		}

		// Hooks etc
		if( g_iCvarLast == 1 )			AcceptEntityInput(g_iLastDoor, "Close");
		else if( g_iCvarLast == 2 )		AcceptEntityInput(g_iLastDoor, "Open");

		if( g_iCvarType )
		{
			HookSingleEntityOutput(g_iLastDoor, "OnOpen", OnOpen);
			HookSingleEntityOutput(g_iLastDoor, "OnClose", OnClose);
		}
	}

	if( g_fCvarFallTime && g_iCvarOpen != 1 )
		ReadyToFallLockedDoor();
}

void MoveSideway(const float vPos[3], const float vAng[3], float vReturn[3], float fDistance)
{
	fDistance *= -1.0;
	float vDir[3];
	GetAngleVectors(vAng, NULL_VECTOR, vDir, NULL_VECTOR);
	vReturn = vPos;
	vReturn[0] += vDir[0] * fDistance;
	vReturn[1] += vDir[1] * fDistance;
}



// ====================================================================================================
//					AUTO FALL
// ====================================================================================================
public void ReadyToFallLockedDoor()
{
	if( (g_bRestarted ? g_fCvarTouch2 : g_fCvarTouch) || (g_bRestarted ? g_fCvarLock2 : g_fCvarLock) ) return;
	if( !g_iLockedDoor || EntRefToEntIndex(g_iLockedDoor) == INVALID_ENT_REFERENCE ) return;

	delete g_hTimerFall;
	g_hTimerFall = CreateTimer(g_fCvarFallTime, HandleAutoFallTimer, true, TIMER_FLAG_NO_MAPCHANGE);
}

public Action HandleAutoFallTimer(Handle timer, bool main)
{
	if( g_iCvarOpen != 1 && !g_bOpened && !g_bMapBlocked && g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
	{
		g_bTimer = false;
		g_bBlock = false;

		SetEntProp(g_iLockedDoor, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSED);
		SDKUnhook(g_iLockedDoor, SDKHook_Use, OnUseEntity);

		if( !main && g_iCvarHint & 2 )
		{
			for( int i = 1; i <= MaxClients; i++ )
			{
				if( IsClientInGame(i) && !IsFakeClient(i) )
				{
					CPrintToChat(i, "%T", "Door_Unlocked", i);
				}
			}
		}

		OnFirst("", g_iLockedDoor, 0, 0.0);
	}

	g_hTimerFall = null;

	return Plugin_Continue;
}

public Action HandleAutoUnlock(Handle timer)
{
	if( g_iCvarOpen != 1 && !g_bOpened && !g_bMapBlocked && g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
	{
		g_bTimer = false;
		g_bBlock = false;

		SetEntProp(g_iLockedDoor, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSED);
		SDKUnhook(g_iLockedDoor, SDKHook_Use, OnUseEntity);
	}

	return Plugin_Continue;
}



// ====================================================================================================
//					DOOR FUNCTION
// ====================================================================================================
public void OnFirst(const char[] output, int entity, int activator, float delay)
{
	// RequestFrame(OnFrameOpen, EntIndexToEntRef(entity));
// }

// public void OnFrameOpen(int entity)
// {
	// entity = EntRefToEntIndex(entity);
	// if( entity == INVALID_ENT_REFERENCE ) return;

	// Prevent opening if holding +USE and supposed to be blocked
	if( g_bBlock )
	{
		// AcceptEntityInput(entity, "Open");
		AcceptEntityInput(entity, "Close");
		AcceptEntityInput(entity, "Lock");
		SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
		return;
	}

	g_bOpened = true;

	char sModel[64];
	GetEntPropString(entity, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

	float vPos[3], vAng[3], vDir[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vPos);
	GetEntPropVector(entity, Prop_Send, "m_angRotation", vAng);
	// GetEntPropVector(entity, Prop_Data, "m_angRotationOpenForward", vDir);

	// Make old door non-solid, so physics door does not collide and stutter
	// Collison group fixes "in solid list (not solid)"
	SetEntProp(entity, Prop_Send, "m_CollisionGroup", 1);
	SetEntProp(entity, Prop_Data, "m_CollisionGroup", 1);

	// Teleport up to prevent using and door shadow showing. Must stay alive or L4D1 crashes.
	vPos[2] += 10000.0;
	TeleportEntity(entity, vPos, NULL_VECTOR, NULL_VECTOR);
	vPos[2] -= 10000.0;

	// Hide old door
	SetEntityRenderMode(entity, RENDER_TRANSALPHA);
	SetEntityRenderColor(entity, 0, 0, 0, 0);

	// Deleting crashes the game in L4D1.. so instead we'll keep it alive (but invisible and non-solid) and unhook.
	UnhookSingleEntityOutput(entity, "OnOpen", OnFirst);

	// Create new physics door
	int door = CreateEntityByName("prop_physics");
	DispatchKeyValue(door, "spawnflags", "4"); // Prevent collision - make non-solid
	DispatchKeyValue(door, "model", sModel);
	DispatchSpawn(door);

	// Teleport to current door, ready to take it's attachments
	TeleportEntity(door, vPos, vAng, NULL_VECTOR);

	// Stop movement
	if( g_fCvarPhysics )
	{
		char sTemp[64];
		FormatEx(sTemp, sizeof(sTemp), "OnUser1 !self:DisableMotion::%f:1", g_fCvarPhysics);
		SetVariantString(sTemp);
		AcceptEntityInput(door, "AddOutput");
		AcceptEntityInput(door, "FireUser1");
	}

	// Handle fall animation from old door
	SetVariantString("unlock");
	AcceptEntityInput(entity, "SetAnimation");

	SetEntProp(entity, Prop_Send, "m_eDoorState", DOOR_STATE_CLOSING_IN_PROGRESS);
	SetEntProp(entity, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent

	// Wait for handle to fall (does not work for wooden handle - Last Stand: TODO FIXME) - deleting crashes in L4D1 so keeping it alive.
	// SetVariantString("OnUser4 !self:Kill::1.0:1");
	// AcceptEntityInput(entity, "AddOutput");
	// AcceptEntityInput(entity, "FireUser4");

	// Find attachments, swap to our new door
	entity = EntRefToEntIndex(entity);

	for( int att = 0; att < 2048; att++ )
	{
		if( IsValidEdict(att) )
		{
			if( HasEntProp(att, Prop_Send, "moveparent") && GetEntPropEnt(att, Prop_Send, "moveparent") == entity )
			{
				SetVariantString("!activator");
				AcceptEntityInput(att, "SetParent", door);
			}
		}
	}

	// Tilt ang away
	GetAngleVectors(vAng, vDir, NULL_VECTOR, NULL_VECTOR);
	float dist;

	if( g_iDoorType[entity] == TYPE_DEFAULT && strcmp(sModel, MODEL_OTHER01) == 0 )
		dist = -10.0;
	else
		dist = 10.0;

	// Move pos away, change ang and push
	vPos[0] += (vDir[0] * dist);
	vPos[1] += (vDir[1] * dist);
	vAng[0] = dist;
	vDir[0] = 0.0;
	if( g_iDoorType[entity] == TYPE_OTHER01 )
		vDir[1] = -10.0;
	else
		vDir[1] = vAng[1] < 270.0 ? 10.0 : -10.0 * dist;
	vDir[2] = 0.0;

	TeleportEntity(door, vPos, vAng, vDir);

	if( sModel[7] == 'l' )
		EmitSoundToAll(GetRandomInt(0, 1) ? SOUND_BREAK3 : SOUND_BREAK4, door);
	else
		EmitSoundToAll(GetRandomInt(0, 1) ? SOUND_BREAK1 : SOUND_BREAK2, door);
}

public void OnClose(const char[] output, int entity, int activator, float delay)
{
	OnUseDoor(entity, false);
}

public void OnOpen(const char[] output, int entity, int activator, float delay)
{
	OnUseDoor(entity, true);
}

void OnUseDoor(int entity, bool open)
{
	// Blocked by other plugins
	if( g_bSaferoomLocked )
		return;

	if( !g_iLastDoor || EntRefToEntIndex(g_iLastDoor) != entity )
		return;

	// Timer already blocking
	if( g_hLastTimer != null )
		return;

	// Block open/close
	if( (open && g_iCvarType & 1) || (!open && g_iCvarType & 2) )
	{
		g_iLastFlags = GetEntProp(g_iLastDoor, Prop_Send, "m_spawnflags");
		SetEntProp(g_iLastDoor, Prop_Send, "m_spawnflags", DOOR_FLAG_SILENT|DOOR_FLAG_IGNORE_USE); // Prevent +USE + Door silent
		g_hLastTimer = CreateTimer(open ? g_fCvarTimeOpen : g_fCvarTimeClose, TimeReset);

		g_fLastDoor = GetGameTime() + (open ? g_fCvarTimeOpen : g_fCvarTimeClose);
	}
}

public Action TimeReset(Handle timer)
{
	if( g_iLastDoor && EntRefToEntIndex(g_iLastDoor) != INVALID_ENT_REFERENCE )
	{
		SetEntProp(g_iLastDoor, Prop_Send, "m_spawnflags", g_iLastFlags);
	}

	g_hLastTimer = null;

	return Plugin_Continue;
}

public Action TimeResetFirst(Handle timer, int index)
{
	if( g_bTimer )
	{
		g_bTimer = false;

		if( g_iLockedDoor && EntRefToEntIndex(g_iLockedDoor) != INVALID_ENT_REFERENCE )
		{
			SetEntProp(g_iLockedDoor, Prop_Send, "m_spawnflags", g_iFirstFlags);
		}
	}
	return Plugin_Continue;
}



/* OLD METHOD: Kept for demonstration purposes.
bool g_bWatch;

public void OnClose(const char[] output, int entity, int activator, float delay)
{
	OnUseDoor(false);
}

public void OnOpen(const char[] output, int entity, int activator, float delay)
{
	OnUseDoor(true);
}

void OnUseDoor(bool open)
{
	if( g_fLastDoor > GetGameTime() )
	{
		if( g_bWatch )
		{
			g_bWatch = false;
			RequestFrame(open ? DoClose : DoOpen);
		}
	}
	else
	{
		if( (open && g_iCvarType & 1) )
		{
			g_fLastDoor = GetGameTime() + g_fCvarTimeOpen;
			g_bWatch = true;
		}
		if( !open && g_iCvarType & 2 )
		{
			g_fLastDoor = GetGameTime() + g_fCvarTimeClose;
			g_bWatch = true;
		}
	}
}

public void OnFrame(bool open)
{
	RequestFrame(open ? DoClose : DoOpen);
}

public void DoClose(int na) // "int na" to support compiling on SourceMod 1.8
{
	if( g_fLastDoor > GetGameTime() )
	{
		for( int i = 0; i < MAX_DOORS; i++ )
		{
			if( g_iLastDoor[i] && EntRefToEntIndex(g_iLastDoor[i]) != INVALID_ENT_REFERENCE )
			{
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundClose", "");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundOpen", "");
				AcceptEntityInput(g_iLastDoor[i], "Close");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundClose", "Doors.Checkpoint.FullClose1");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundOpen", "Doors.Checkpoint.FullOpen1");
				g_bWatch = true;
			}
		}
	}
}

public void DoOpen(int na)
{
	if( g_fLastDoor > GetGameTime() )
	{
		for( int i = 0; i < MAX_DOORS; i++ )
		{
			if( g_iLastDoor[i] && EntRefToEntIndex(g_iLastDoor[i]) != INVALID_ENT_REFERENCE )
			{
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundClose", "");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundOpen", "");
				AcceptEntityInput(g_iLastDoor[i], "Open");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundClose", "Doors.Checkpoint.FullClose1");
				SetEntPropString(g_iLastDoor[i], Prop_Data, "m_SoundOpen", "Doors.Checkpoint.FullOpen1");
				g_bWatch = true;
			}
		}
	}
}
// */



// ====================================================================================================
//					COLORS.INC REPLACEMENT
// ====================================================================================================
void CPrintToChat(int client, char[] message, any ...)
{
	static char buffer[256];
	VFormat(buffer, sizeof(buffer), message, 3);

	ReplaceString(buffer, sizeof(buffer), "{default}",		"\x01");
	ReplaceString(buffer, sizeof(buffer), "{white}",		"\x01");
	ReplaceString(buffer, sizeof(buffer), "{cyan}",			"\x03");
	ReplaceString(buffer, sizeof(buffer), "{lightgreen}",	"\x03");
	ReplaceString(buffer, sizeof(buffer), "{orange}",		"\x04");
	ReplaceString(buffer, sizeof(buffer), "{green}",		"\x04"); // Actually orange in L4D2, but replicating colors.inc behaviour
	ReplaceString(buffer, sizeof(buffer), "{olive}",		"\x05");
	PrintToChat(client, buffer);
}