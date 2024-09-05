/*
*	Attachments API
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



#define PLUGIN_VERSION 		"1.10"

/*======================================================================================
	Plugin Info:

*	Name	:	[ANY] Attachments API
*	Author	:	SilverShot
*	Descrp	:	Allows plugins to attach things to weapons. Fixes player attachments when their model changes.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=325651
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.10 (30-Jul-2022)
	- Changes to fix the incorrect weapon showing in OnWeaponSwitch when spawning.
	- Changes to clean up some variables on round end. Probably not required.

1.9 (04-Dec-2021)
	- Changes to fix warnings when compiling on SourceMod 1.11.
	- Fixed leaking 1 handle.

1.8 (27-Jun-2021)
	- Fixed and cleaned some of the plugin code.

	- L4D2: Updated "data/attachments_api.l4d2.cfg" to support changes from the latest update.
	- This fixes model attachment positions which otherwise was broken.

1.7 (20-Apr-2021)
	- Fixed a "Client is not in game" error being thrown. Thanks to "Krufftys Killers" for reporting.

1.6 (01-Oct-2020)
	- Added support for following weapons "m_nSkin" value. Fixes L4D2 new weapon skins.
	- Changes attempting to fix the "prop_dynamic_override" blocking players +USE ability. Thanks to "Lux".

1.5 (25-Jul-2020)
	- Fixed picking up weapons not always triggering "Attachments_OnWeaponSwitch" (game bug).

1.4 (20-Jul-2020)
	- L4D2: Added a fix for climbing ladders, plugin deletes the weapon viewmodel when climbing.
	- This ladder fix will break other plugins using the "Attachments_API" weapon viewmodel.
	- This ladder fix sends out the "Attachments_OnWeaponSwitch" forward with the weapon index -1.
	- Plugins attaching to the viewmodel should be accounting for "Attachments_OnWeaponSwitch" to -1 anyway.
	- Other games that hide weapons when climbing ladders need adding, please report if required.

1.3 (11-Jul-2020)
	- Fixed not triggering weapon equip when a player dropped their last weapon and equipped the same one again.

1.2 (05-Jul-2020)
	- Fixed invalid entity errors from version 1.1 update. Thanks to "Krufftys Killers" for reporting.

1.1 (04-Jul-2020)
	- Changed weapon switch to detect the actual current weapon, fixes some issues where the wrong weapon was being detected.
	- Fixed weapon switch forward triggering multiple times for the same weapon.
	- Fixed "attachments_api.cfg" cvars config not being generated.
	- Removed accidental IsFakeClient line that prevented monitoring bots for changing model. Thanks to "Alex101192" for reporting.

1.0 (01-Jul-2020)
	- Initial release.

========================================================================================
	Thanks:

	This plugin was made using source code from the following plugins.
	If I have used your code and not credited you, please let me know.

*	"Mitchell" for "[CS:GO] Weapon Attachment API" - Using the "findModelString" function.
	https://forums.alliedmods.net/showthread.php?t=281542

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define CVAR_FLAGS				FCVAR_NOTIFY
#define DEBUG_TEST				0

#define SF_PHYSPROP_PREVENT_PICKUP		(1 << 9)
#define EFL_DONTBLOCKLOS		(1 << 25)
#define EF_BONEMERGE			(1 << 0)
#define EF_NOSHADOW				(1 << 4)
#define EF_BONEMERGE_FASTCULL	(1 << 7)
#define EF_PARENT_ANIMATES		(1 << 9)

#define MAX_SLOTS				1	// Maximum weapon slots. (L4D/2): 0=Pistol. 1=Primary. 2=Grenades. 3=Medkit. 4=Pills.
#define MAX_MODEL				128	// Maximum modelname string length

#define PATH_READ				"data/attachments_api"		// Appends ".game.cfg" to the filename
#define PATH_SAVE				"data/attachments_new.cfg" 	// The .qc parsed file save location



ConVar g_hCvarCheck, g_hCvarEquip, g_hCvarModels, g_hCvarWeapons;
bool g_bLateLoad, g_bCvarModels, g_bCvarWeapons, g_bMissingConfig;
float g_fCvarCheck, g_fCvarEquip;

int g_iLastWeapon[MAXPLAYERS+1];
int g_iLastModel[MAXPLAYERS+1] = {-1, ...};		// Players last model, for detecting model changes
int g_iViewsModel[MAXPLAYERS+1];				// Views model entity, for tracking and deletion
int g_iWorldModel[MAXPLAYERS+1];				// World model entity, for tracking and deletion
bool g_bOnLadder[MAXPLAYERS+1];					// True when on a ladder and they had a valid viewmodel weapon, to re-create after climbing
bool g_bManualDrop;								// When manually sending weapon drop forward, for ladder fix

char g_sConfigPath[PLATFORM_MAX_PATH];			// Attachments config path
StringMap g_hMapModels;							// StringMap to store modelname and associated temp ArrayList handle of attachments
ArrayList g_hMapAttach;							// Temporary ArrayList to store attachment list
Handle g_hTimerCheck;							// Check for model change
Handle g_hTimerSwap[MAXPLAYERS+1];				// Drop/Equip weapons timer

EngineVersion g_iEngine;
int g_iMaxEntities;

GlobalForward g_hForward_WeaponSwitch;
GlobalForward g_hForward_ModelChanged;
GlobalForward g_hForward_OnPluginEnd;
GlobalForward g_hForward_OnLateLoad;



// ====================================================================================================
//					PLUGIN INFO / START / END
// ====================================================================================================
public Plugin myinfo =
{
	name = "[ANY] Attachments API",
	author = "SilverShot",
	description = "Allows plugins to attach things to weapons. Fixes player attachments when their model changes.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=325651"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	// Setup
	RegPluginLibrary("attachments_api");

	g_iEngine = GetEngineVersion();

	// Natives
	CreateNative("Attachments_GetViewModel",	Native_GetViewModel);
	CreateNative("Attachments_GetWorldModel",	Native_GetWorldModel);
	CreateNative("Attachments_HasAttachment",	Native_HasAttachment);

	// Forwards
	g_hForward_WeaponSwitch =	new GlobalForward("Attachments_OnWeaponSwitch",		ET_Ignore, Param_Cell, Param_Cell, Param_Cell, Param_Cell);
	g_hForward_ModelChanged =	new GlobalForward("Attachments_OnModelChanged",		ET_Ignore, Param_Cell);
	g_hForward_OnPluginEnd =	new GlobalForward("Attachments_OnPluginEnd",		ET_Ignore);
	g_hForward_OnLateLoad =		new GlobalForward("Attachments_OnLateLoad",			ET_Ignore);

	// Late
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	// Cvars
	char sChk[4];
	if( g_iEngine == Engine_Left4Dead || g_iEngine == Engine_Left4Dead2 )
		sChk = "1";
	else
		sChk = "0";

	g_hCvarCheck = CreateConVar(			"attachments_api_check",		"0.1",				"How often to check if a players model has changed. Requires \"attachments_api_models\" value \"1\" to enable.", CVAR_FLAGS );
	g_hCvarEquip = CreateConVar(			"attachments_api_equip",		"0.1",				"When weapons have attachments and a players model has changed, how long to drop the weapon before re-equipping to fix.", CVAR_FLAGS );
	g_hCvarModels = CreateConVar(			"attachments_api_models",		sChk,				"0=Off, 1=Detect when a players model changes to fix attachments to players (required by plugins attaching stuff to players).", CVAR_FLAGS );
	g_hCvarWeapons = CreateConVar(			"attachments_api_weapons",		sChk,				"0=Off, 1=Detect when a players model changes to fix attachments to weapons (required by plugins attaching stuff to weapons).", CVAR_FLAGS );
	CreateConVar(							"attachments_api_version",		PLUGIN_VERSION,		"Attachments API plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig(true, "attachments_api");

	g_hCvarCheck.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarEquip.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarModels.AddChangeHook(ConVarChanged_Cvars);
	g_hCvarWeapons.AddChangeHook(ConVarChanged_Cvars);



	// Commands
	RegAdminCmd("sm_attachment_qc",			CmdParseQC,	ADMFLAG_ROOT, "Parses .qc files to get model attachment names. Usage: sm_attachment_qc <folder path to .qc files>. Saves to sourcemod/data/attachments_new.cfg.");
	RegAdminCmd("sm_attachment_reload",		CmdReload,	ADMFLAG_ROOT, "Reload the attachments config: sourcemod/data/attachments_api.<game>.cfg.");



	// Events
	if( g_iEngine == Engine_Left4Dead2 )
		HookEvent("weapon_drop",			Event_WeaponDrop);
	else if( g_iEngine == Engine_CSGO )
		HookEvent("item_remove",			Event_WeaponDrop);

	HookEvent("player_use",					Event_PlayerUse);
	HookEvent("player_spawn",				Event_PlayerSpawn);
	HookEvent("round_start",				Event_RoundStart);
	HookEvent("round_end",					Event_RoundEnd);



	// Load config
	BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), "%s.", PATH_READ);

	switch( g_iEngine )
	{
		case Engine_Left4Dead:		StrCat(g_sConfigPath, sizeof(g_sConfigPath), "l4d1.cfg");
		case Engine_Left4Dead2:		StrCat(g_sConfigPath, sizeof(g_sConfigPath), "l4d2.cfg");
		case Engine_CSGO:			StrCat(g_sConfigPath, sizeof(g_sConfigPath), "csgo.cfg");
		case Engine_CSS:			StrCat(g_sConfigPath, sizeof(g_sConfigPath), "css.cfg");
		default:					StrCat(g_sConfigPath, sizeof(g_sConfigPath), ".game.cfg");
	}

	ParseConfig();

	g_iMaxEntities = GetMaxEntities();

	// Forward
	if( g_bLateLoad )
	{
		CreateTimer(0.2, TimerLateLoad); // Delay required otherwise plugins fail to reload
	}
}

Action TimerLateLoad(Handle timer)
{
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( IsClientInGame(i) )
		{
			OnClientPutInServer(i);
		}
	}

	Call_StartForward(g_hForward_OnLateLoad);
	Call_Finish();

	return Plugin_Continue;
}

public void OnPluginEnd()
{
	// Forward
	Call_StartForward(g_hForward_OnPluginEnd);
	Call_Finish();

	for( int i = 1; i <= MaxClients; i++ )
	{
		if( g_iViewsModel[i] && EntRefToEntIndex(g_iViewsModel[i]) != INVALID_ENT_REFERENCE )
			RemoveEntity(g_iViewsModel[i]);

		if( g_iWorldModel[i] && EntRefToEntIndex(g_iWorldModel[i]) != INVALID_ENT_REFERENCE )
			RemoveEntity(g_iWorldModel[i]);
	}
}



// ====================================================================================================
//					CVARS
// ====================================================================================================
public void OnConfigsExecuted()
{
	GetCvars();

	// Store current model indexes
	if( g_bLateLoad )
	{
		g_bLateLoad = false;
		for( int i = 1; i <= MaxClients; i++ )
		{
			if( IsClientInGame(i) && IsPlayerAlive(i) )
			{
				g_iLastModel[i] = GetEntProp(i, Prop_Data, "m_nModelIndex", 2);
			}
		}

		if( (g_bCvarModels && !g_bMissingConfig) || g_bCvarWeapons )
			g_hTimerCheck = CreateTimer(g_fCvarCheck, TimerCheck, _, TIMER_REPEAT);
	}
}

void ConVarChanged_Cvars(Handle convar, const char[] oldValue, const char[] newValue)
{
	GetCvars();
}

void GetCvars()
{
	g_fCvarCheck = g_hCvarCheck.FloatValue;
	g_fCvarEquip = g_hCvarEquip.FloatValue;
	g_bCvarModels = g_hCvarModels.BoolValue;
	g_bCvarWeapons = g_hCvarWeapons.BoolValue;

	if( g_bCvarModels && g_bMissingConfig )
	{
		LogError("\n==========\nMissing required file: \"%s\".\nYou have \"attachments_api_models\" cvar enabled but missing the required file.\nRead installation instructions again.\n==========", g_sConfigPath);
	}

	delete g_hTimerCheck;
	if( (g_bCvarModels && !g_bMissingConfig) || g_bCvarWeapons )
		g_hTimerCheck = CreateTimer(g_fCvarCheck, TimerCheck, _, TIMER_REPEAT);
}



// ====================================================================================================
//					COMMANDS
// ====================================================================================================
Action CmdReload(int client, int args)
{
	float fTime = GetEngineTime();
	ParseConfig();
	ReplyToCommand(client, "Finished reload the data config in %f seconds.", GetEngineTime() - fTime);
	return Plugin_Handled;
}

Action CmdParseQC(int client, int args)
{
	// Require arg
	if( args != 1 )
	{
		ReplyToCommand(client, "Usage: sm_attachment_qc <folder path to .qc files>");
		return Plugin_Handled;
	}

	// Process
	ReplyToCommand(client, "[QC] Processing started. Please wait a few seconds.");

	// Delay, so chat message sends
	char sDir[PLATFORM_MAX_PATH];
	GetCmdArg(1, sDir, sizeof(sDir));

	DataPack dPack = new DataPack();
	dPack.WriteCell(client ? GetClientUserId(client) : 0);
	dPack.WriteString(sDir);

	CreateTimer(0.1, TimreQC, dPack);

	return Plugin_Handled;
}

Action TimreQC(Handle timer, DataPack dPack)
{
	dPack.Reset();

	int client = dPack.ReadCell();

	if( client )
	{
		client = GetClientOfUserId(client);
		if( !client )
		{
			delete dPack;
			return Plugin_Continue;
		}
	}

	float fTime = GetEngineTime();

	// Check dir path
	char sDir[PLATFORM_MAX_PATH];
	dPack.ReadString(sDir, sizeof(sDir));

	delete dPack;

	// Process
	if( DirExists(sDir) == false )
	{
		ReplyToCommand(client, "Invalid folder path.");
		return Plugin_Continue;
	}

	// Open dir
	DirectoryListing hDir = OpenDirectory(sDir);
	if( hDir == null )
	{
		ReplyToCommand(client, "Failed to open folder path.");
		return Plugin_Continue;
	}
	delete hDir;

	char sPath[PLATFORM_MAX_PATH];
	char sModel[128];
	char sLine[128];
	FileType type;
	File hFile;
	bool bFound;
	int count;
	int index;
	int pos;

	// Save file
	BuildPath(Path_SM, sPath, sizeof(sPath), PATH_SAVE);
	File hSave = OpenFile(sPath, "w+");
	hSave.WriteLine("\"attachments\"");
	hSave.WriteLine("{");

	// Loop through files
	hDir = OpenDirectory(sDir, true, NULL_STRING);
	while( hDir.GetNext(sPath, sizeof(sPath), type) )
	{
		// Ignore "." and ".."
		if( strcmp(sPath, ".") && strcmp(sPath, "..") )
		{
			// Match .qc file
			int len = strlen(sPath);
			if( len > 3 &&
				sPath[len - 3] == '.' &&
				sPath[len - 2] == 'q' &&
				sPath[len - 1] == 'c'
			)
			{
				// Open file
				bFound = false;
				index = 0;

				Format(sPath, sizeof(sPath), "%s/%s", sDir, sPath);
				hFile = OpenFile(sPath, "rb", true, NULL_STRING);

				while( hFile.EndOfFile() == false && hFile.ReadLine(sLine, sizeof(sLine)) )
				{
					// Get modelname
					if( strncmp(sLine, "$modelname ", 11) == 0 )
					{
						pos = FindCharInString(sLine[12], '"');
						sLine[pos + 12] = 0;
						strcopy(sModel, sizeof(sModel), sLine[12]);
					}
					// Get attachment names
					else if( strncmp(sLine, "$attachment ", 12) == 0 )
					{
						// New entry, write model as section name
						if( bFound == false )
						{
							count++;
							bFound = true;

							StrToLowerCase(sModel, sModel, sizeof(sModel));
							hSave.WriteLine("	\"models/%s\"", sModel);
							hSave.WriteLine("	{");
						}

						pos = FindCharInString(sLine[13], '"');
						sLine[pos + 13] = 0;

						// Write attachment
						hSave.WriteLine("		\"%d\"		\"%s\"", ++index, sLine[13]);
					}
				}

				delete hFile;

				// Finish section
				if( bFound == true )
				{
					hSave.WriteLine("	}");
				}
			}
		}
	}

	hSave.WriteLine("}");

	delete hDir;
	delete hSave;

	ReplyToCommand(client, "[QC] Finished parsing %d .qc files in %f seconds. Saved to: %s", count, GetEngineTime() - fTime, PATH_SAVE);

	return Plugin_Continue;
}



// ====================================================================================================
//					CONFIG
// ====================================================================================================
void ParseConfig()
{
	// Delete any stored StringMap handles
	if( g_hMapModels != null )
	{
		StringMapSnapshot hSnap = g_hMapModels.Snapshot();
		int len = hSnap.Length;
		char sKey[MAX_MODEL];

		// Loop through current g_hMapModels list
		for( int i = 0; i < len; i++ )
		{
			hSnap.GetKey(i, sKey, sizeof(sKey));
			g_hMapModels.GetValue(sKey, g_hMapAttach);
			delete g_hMapAttach;
		}

		delete hSnap;
	}

	// Create new StringMap
	delete g_hMapModels;
	g_hMapModels = new StringMap();

	// Parse config
	if( FileExists(g_sConfigPath) == false )
	{
		g_bMissingConfig = true;
	} else {
		g_bMissingConfig = false;
		ParseConfigFile(g_sConfigPath);
	}
}

bool ParseConfigFile(const char[] file)
{
	SMCParser parser = new SMCParser();
	SMC_SetReaders(parser, ColorConfig_NewSection, ColorConfig_KeyValue, ColorConfig_EndSection);
	parser.OnEnd = ColorConfig_End;

	char error[128];
	int line = 0, col = 0;
	SMCError result = parser.ParseFile(file, line, col);

	if( result != SMCError_Okay )
	{
		parser.GetErrorString(result, error, sizeof(error));
		SetFailState("%s on line %d, col %d of %s [%d]", error, line, col, file, result);
	}

	delete parser;
	return (result == SMCError_Okay);
}

SMCResult ColorConfig_NewSection(Handle parser, const char[] section, bool quotes)
{
	g_hMapAttach = new ArrayList(ByteCountToCells(MAX_MODEL));
	g_hMapModels.SetValue(section, g_hMapAttach);

	return SMCParse_Continue;
}

SMCResult ColorConfig_KeyValue(Handle parser, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
	g_hMapAttach.PushString(value);

	return SMCParse_Continue;
}

SMCResult ColorConfig_EndSection(Handle parser)
{
	return SMCParse_Continue;
}

void ColorConfig_End(Handle parser, bool halted, bool failed)
{
	if( failed )
		SetFailState("Error: Cannot load the Neon Beam Color menu.");
}



// ====================================================================================================
//					MODEL CHANGE CHECKS
// ====================================================================================================
public void OnMapEnd()
{
	delete g_hTimerCheck;

	for( int i = 1; i < MAXPLAYERS; i++ )
	{
		g_iLastModel[i] = -1;
		g_iLastWeapon[i] = -1;
	}
}

void Event_WeaponDrop(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if( client )
	{
		// CSGO: Delete bone weapon so weapon skins can change.
		if( g_iEngine == Engine_CSGO )
		{
			if( g_iViewsModel[client] && EntRefToEntIndex(g_iViewsModel[client]) != INVALID_ENT_REFERENCE )
			{
				RemoveEntity(g_iViewsModel[client]);
				g_iViewsModel[client] = 0;
			}
			if( g_iWorldModel[client] && EntRefToEntIndex(g_iWorldModel[client]) != INVALID_ENT_REFERENCE )
			{
				RemoveEntity(g_iWorldModel[client]);
				g_iWorldModel[client] = 0;
			}
		}

		OnWeaponDrop(client, 0);
	}
}

// Fix weapon pickup not firing weapon switch sometimes (game bug, noticeable in L4D/2 when picking up second pistol)
void Event_PlayerUse(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if( client )
	{
		int last = g_iLastWeapon[client] == -1 ? -1 : EntRefToEntIndex(g_iLastWeapon[client]);
		int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");

		if( last != weapon )
		{
			OnWeaponSwitch(client, weapon);
		}
	}
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	if( client )
	{
		g_iLastModel[client] = GetEntProp(client, Prop_Data, "m_nModelIndex", 2);
		g_iLastWeapon[client] = -1;
		g_bOnLadder[client] = false;
		RequestFrame(OnFrameSpawn, userid); // Because spawning and adding weapons can happen too fast so OnWeaponSwitch fires with the wrong m_hActiveWeapon weapon. Delaying and triggering again allows the fake model to correctly change.
	}
}

void OnFrameSpawn(int client)
{
	client = GetClientOfUserId(client);
	if( client && IsClientInGame(client) )
	{
		OnWeaponSwitch(client, 0);
	}
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bManualDrop = false;

	// Monitor for model change
	delete g_hTimerCheck;
	if( (g_bCvarModels && !g_bMissingConfig) || g_bCvarWeapons )
	{
		g_hTimerCheck = CreateTimer(g_fCvarCheck, TimerCheck, _, TIMER_REPEAT);
	}
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	delete g_hTimerCheck;

	// Extra cleanup, doesn't seem to be required, but might as well
	for( int i = 1; i <= MaxClients; i++ )
	{
		if( g_iViewsModel[i] && EntRefToEntIndex(g_iViewsModel[i]) != INVALID_ENT_REFERENCE )
			RemoveEntity(g_iViewsModel[i]);

		if( g_iWorldModel[i] && EntRefToEntIndex(g_iWorldModel[i]) != INVALID_ENT_REFERENCE )
			RemoveEntity(g_iWorldModel[i]);

		g_iViewsModel[i] = 0;
		g_iWorldModel[i] = 0;
		g_iLastModel[i] = -1;
		g_iLastWeapon[i] = -1;
		g_bOnLadder[i] = false;
		delete g_hTimerSwap[i];
	}
}

Action TimerCheck(Handle timer)
{
	static char sTemp[MAX_MODEL], sModel[MAX_MODEL];
	int att, last, model, weapon;
	ArrayList hListOld;
	ArrayList hListNew;

	// Loop clients
	for( int client = 1; client <= MaxClients; client++ )
	{
		// Validate alive
		if( IsClientInGame(client) && IsPlayerAlive(client) )
		{
			model = GetEntProp(client, Prop_Data, "m_nModelIndex", 2);

			// Model changed
			if( g_iLastModel[client] != model )
			{
				last = g_iLastModel[client];
				g_iLastModel[client] = model;


				// Forward
				Call_StartForward(g_hForward_ModelChanged);
				Call_PushCell(client);
				Call_Finish();


				// Re-equip weapons to fix attachments to weapons (Charms and Glare plugin and any others which may use)
				if( g_bCvarWeapons && last != -1 )
				{
					if(
						(g_iViewsModel[client] && EntRefToEntIndex(g_iViewsModel[client]) != INVALID_ENT_REFERENCE)
						||
						(g_iWorldModel[client] && EntRefToEntIndex(g_iWorldModel[client]) != INVALID_ENT_REFERENCE)
					)
					{
						weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
						if( weapon != -1 )
						{
							DataPack dPack = new DataPack();
							dPack.WriteCell(GetClientUserId(client));
							dPack.WriteCell(EntIndexToEntRef(weapon)); // Save last held weapon to switch back

							g_hTimerSwap[client] = CreateTimer(g_fCvarEquip, TimerWeapons, dPack);

							// Loop through weapons and drop
							for( int i = 0; i <= MAX_SLOTS; i++ )
							{
								weapon = GetPlayerWeaponSlot(client, i);
								if( weapon != -1 && GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity") == client ) // This shouldn't be required, but seems some plugins are causing this error to occur.
								{
									dPack.WriteCell(EntIndexToEntRef(weapon));

									// Teleport somewhere else, otherwise it drops on floor next to them potentially allowing others to pickup.
									SDKHooks_DropWeapon(client, weapon);

									// Because "SDKHooks_DropWeapon" throws "[SM] Exception reported: Could not read vecVelocity vector" when setting position to drop at, even with velocity set. WTF
									TeleportEntity(weapon, view_as<float>({10.0, 100.0, 1000.0}), NULL_VECTOR, NULL_VECTOR);
								}
							}
						}
					}
				}

				// Get last modelname
				if( g_bCvarModels && g_bMissingConfig == false && last != -1 && findModelString(last, sModel, sizeof(sModel)) > 0 )
				{
					// Last model has ArrayList attachments list
					if( g_hMapModels.GetValue(sModel, hListOld) )
					{
						// Get new modelname
						if( findModelString(model, sModel, sizeof(sModel)) > 0 )
						{
							// New model has ArrayList attachments list
							if( g_hMapModels.GetValue(sModel, hListNew) )
							{
								// Loop through entities
								for( int i = MaxClients + 1; i < g_iMaxEntities; i++ )
								{
									// Valid and attached to our client
									if( IsValidEdict(i) && HasEntProp(i, Prop_Send, "moveparent") && GetEntPropEnt(i, Prop_Send, "moveparent") == client )
									{
										GetEdictClassname(i, sTemp, sizeof(sTemp));
										if( strncmp(sTemp, "weapon_", 7) ) // Ignore weapons
										{
											// Get attachment index
											att = GetEntProp(i, Prop_Send, "m_iParentAttachment") - 1;

											// From attachment index get attachment string
											if( att != -1 && att < hListOld.Length && hListOld.GetString(att, sTemp, sizeof(sTemp)) )
											{
												// Match attachment string and get new index
												att = hListNew.FindString(sTemp);
												if( att > -1 )
												{
													SetEntProp(i, Prop_Send, "m_iParentAttachment", att + 1);
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}

	return Plugin_Continue;
}

Action TimerWeapons(Handle timer, DataPack dPack)
{
	dPack.Reset();
	int client = dPack.ReadCell();
	int active = dPack.ReadCell();
	int weapon;

	client = GetClientOfUserId(client);
	if( client && IsClientInGame(client) && IsPlayerAlive(client) )
	{
		while( dPack.IsReadable() )
		{
			weapon = dPack.ReadCell();
			if( EntRefToEntIndex(weapon) != INVALID_ENT_REFERENCE )
			{
				EquipPlayerWeapon(client, weapon);
				SetEntPropEnt(client, Prop_Data, "m_hActiveWeapon", weapon);
				AcceptEntityInput(weapon, "HideWeapon"); // Makes it not invisible.. logic
			}
		}

		if( EntRefToEntIndex(active) != INVALID_ENT_REFERENCE )
		{
			SetEntPropEnt(client, Prop_Data, "m_hActiveWeapon", active);
		}

		g_hTimerSwap[client] = null;
	}

	delete dPack;

	return Plugin_Continue;
}

public void OnClientPutInServer(int client)
{
	// Hook switch weapons, to change model/fix attachment
	SDKUnhook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitch);
	SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitch);

	// Hook drop weapon
	SDKUnhook(client, SDKHook_WeaponDropPost, OnWeaponDrop);
	SDKHook(client, SDKHook_WeaponDropPost, OnWeaponDrop);
}

public void OnClientDisconnect(int client)
{
	g_hTimerSwap[client] = null;
}



// ====================================================================================================
//					RUN CMD - LADDER FIX
// ====================================================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
	if( g_iEngine == Engine_Left4Dead || g_iEngine == Engine_Left4Dead2 )
	{
		if( g_iViewsModel[client] && EntRefToEntIndex(g_iViewsModel[client]) != INVALID_ENT_REFERENCE && GetEntityMoveType(client) == MOVETYPE_LADDER )
		{
			RemoveEntity(g_iViewsModel[client]);
			g_iViewsModel[client] = 0;

			g_bOnLadder[client] = true;

			g_bManualDrop = true;
			OnWeaponDrop(client, 0);
			g_bManualDrop = false;
		}
		else if( g_bOnLadder[client] && GetEntityMoveType(client) != MOVETYPE_LADDER )
		{
			g_bOnLadder[client] = false;

			int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
			OnWeaponSwitch(client, weapon);
		}
	}

	return Plugin_Continue;
}



// ====================================================================================================
//					REPLICA ATTACHMENT
// ====================================================================================================
int Native_HasAttachment(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	bool viewmodel = GetNativeCell(2);

	if( viewmodel )
	{
		int bone = g_iViewsModel[client];
		if( bone && EntRefToEntIndex(bone) != INVALID_ENT_REFERENCE )
		{
			return EntRefToEntIndex(bone);
		}
	}
	else
	{
		int bone = g_iWorldModel[client];
		if( bone && EntRefToEntIndex(bone) != INVALID_ENT_REFERENCE )
		{
			return EntRefToEntIndex(bone);
		}
	}

	return 0;
}

int Native_GetViewModel(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if( IsPlayerAlive(client) )
	{
		int weapon = GetNativeCell(2);
		return CreateReplica(client, weapon, true);
	}
	return 0;
}

int Native_GetWorldModel(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if( IsPlayerAlive(client) )
	{
		int weapon = GetNativeCell(2);
		return CreateReplica(client, weapon, false);
	}
	return 0;
}

int CreateReplica(int client, int weapon, bool viewmodel)
{
	// Already exists
	if( viewmodel == true )
	{
		int bone = g_iViewsModel[client];
		if( bone && EntRefToEntIndex(bone) != INVALID_ENT_REFERENCE )
		{
			return EntRefToEntIndex(bone);
		}
	}
	else
	{
		int bone = g_iWorldModel[client];
		if( bone && EntRefToEntIndex(bone) != INVALID_ENT_REFERENCE )
		{
			return EntRefToEntIndex(bone);
		}
	}

	// Model
	static char sModel[MAX_MODEL];
	if( viewmodel )
		GetEntPropString(weapon, Prop_Data, "m_ModelName", sModel, sizeof(sModel));
	else
		findModelString(GetEntProp(weapon, Prop_Send, "m_iWorldModelIndex"), sModel, sizeof(sModel));

	// Create replica
	// Can't attach directly to weapon, have to attach fake hidden bone merged version and attach to that instead.
	int bone = CreateEntityByName("prop_dynamic_override");

	SDKHook(bone, SDKHook_Use, OnUse); // Prevent bug on "prop_dynamic_override" where +USE attempts to pickup or something which deletes the weapon. Thanks to "Voevoda" for reporting the bug.
	DispatchKeyValue(bone, "model", sModel); // Placeholder to prevent error on spawn, weapon model is changed whenever the weapon switches
	DispatchKeyValue(bone, "solid", "0");
	DispatchKeyValue(bone, "spawnflags", "256");
	DispatchSpawn(bone);
	AcceptEntityInput(bone, "DisableShadow");

	SetEntProp(bone, Prop_Data, "m_nSkin", GetEntProp(weapon, Prop_Data, "m_nSkin"));
	SetEntProp(bone, Prop_Data, "m_iEFlags", GetEntProp(bone, Prop_Data, "m_iEFlags") | EFL_DONTBLOCKLOS | SF_PHYSPROP_PREVENT_PICKUP);
	SetEntProp(bone, Prop_Send, "m_nSolidType", 6, 1);

	// Hide replica
	SetEntityRenderMode(bone, RENDER_NONE); // This makes the replica invisible
	TeleportEntity(bone, view_as<float>({0.0,0.0,0.0}), NULL_VECTOR, NULL_VECTOR);

	// Save entity
	if( viewmodel )
		g_iViewsModel[client] = EntIndexToEntRef(bone);
	else
		g_iWorldModel[client] = EntIndexToEntRef(bone);

	// Attach
	SetAttached(bone, weapon);

	// Testing:
	#if DEBUG_TEST
	if( viewmodel )
		SetEntityRenderColor(bone, 255, 0, 0); // Make viewmodel replica red
	else
		SetEntityRenderColor(bone, 0, 255, 0); // Make worldmodel replica green
	#endif

	return bone;
}

Action OnUse(int entity, int activator, int caller, UseType type, float value)
{
	return Plugin_Handled;
}

void OnWeaponDrop(int client, int weapon)
{
	if( g_bManualDrop || GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon") == -1 )
	{
		g_iLastWeapon[client] = -1;

		int ent_world = g_iWorldModel[client];
		if( ent_world )
		{
			ent_world = EntRefToEntIndex(ent_world);
		} else {
			ent_world = -1;
		}

		int ent_views = g_iViewsModel[client];
		if( ent_views )
		{
			ent_views = EntRefToEntIndex(ent_views);
		} else {
			ent_views = -1;
		}

		// Forward
		Call_StartForward(g_hForward_WeaponSwitch);
		Call_PushCell(client);
		Call_PushCell(-1);
		Call_PushCell(ent_views);
		Call_PushCell(ent_world);
		Call_Finish();
	}
}

void OnWeaponSwitch(int client, int weapon)
{
	// Ignore if drop weapon in progress
	if( g_hTimerSwap[client] ) return;

	// Ignore switch until after model change stuff. Maybe not required anymore. TODO: FIXME: TEST
	int model = GetEntProp(client, Prop_Data, "m_nModelIndex", 2);
	if( g_iLastModel[client] != model )
	{
		return;
	}

	static char sModel[MAX_MODEL];
	weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon"); // Since L4D/2 switches to pistol but never returns to the actual active weapon.

	// Prevent multiple triggers for the same weapon
	if( weapon == -1 )
	{
		if( g_iLastWeapon[client] == -1 ) return;
		g_iLastWeapon[client] = -1;

		// Forward
		int ent_views = g_iViewsModel[client];
		if( !ent_views || (ent_views = EntRefToEntIndex(ent_views)) == INVALID_ENT_REFERENCE )
			ent_views = -1;

		int ent_world = g_iWorldModel[client];
		if( !ent_world || (ent_world = EntRefToEntIndex(ent_world)) == INVALID_ENT_REFERENCE )
			ent_world = -1;

		Call_StartForward(g_hForward_WeaponSwitch);
		Call_PushCell(client);
		Call_PushCell(weapon);
		Call_PushCell(ent_views);
		Call_PushCell(ent_world);
		Call_Finish();

		return;
	} else {
		if( g_iLastWeapon[client] == EntIndexToEntRef(weapon) ) return;
		g_iLastWeapon[client] = EntIndexToEntRef(weapon);
	}

	// PrintToServer("Attachments_API::OnWeaponSwitch (%N) %d", client, weapon);

	// Fix World model
	int ent_world = g_iWorldModel[client];
	if( ent_world && (ent_world = EntRefToEntIndex(ent_world)) != INVALID_ENT_REFERENCE )
	{
		findModelString(GetEntProp(weapon, Prop_Send, "m_iWorldModelIndex"), sModel, sizeof(sModel));

		SetEntityModel(ent_world, sModel);
		AcceptEntityInput(ent_world, "ClearParent");
		SetAttached(ent_world, weapon);
	} else {
		ent_world = -1;
	}

	// Fix View model
	int ent_views = g_iViewsModel[client];
	if( ent_views && (ent_views = EntRefToEntIndex(ent_views)) != INVALID_ENT_REFERENCE )
	{
		int viewmodel = GetEntPropEnt(client, Prop_Data, "m_hViewModel");
		GetEntPropString(viewmodel, Prop_Data, "m_ModelName", sModel, sizeof(sModel));

		SetEntityModel(ent_views, sModel);
		AcceptEntityInput(ent_views, "ClearParent");
		SetAttached(ent_views, viewmodel);
	} else {
		ent_views = -1;
	}

	// Forward
	Call_StartForward(g_hForward_WeaponSwitch);
	Call_PushCell(client);
	Call_PushCell(weapon);
	Call_PushCell(ent_views);
	Call_PushCell(ent_world);
	Call_Finish();
}

// Lux: As a note this should only be used for dummy entity other entities need to remove EF_BONEMERGE_FASTCULL flag.
/*
*	Recreated "SetAttached" entity input from "prop_dynamic_ornament"
*/
stock void SetAttached(int iEntToAttach, int iEntToAttachTo)
{
	SetVariantString("!activator");
	AcceptEntityInput(iEntToAttach, "SetParent", iEntToAttachTo);

	SetEntityMoveType(iEntToAttach, MOVETYPE_NONE);

	#if DEBUG_TEST
	SetEntityRenderMode(iEntToAttach, RENDER_TRANSALPHA); // Make visible, for testing.
	#endif

	SetEntProp(iEntToAttach, Prop_Send, "m_fEffects", EF_BONEMERGE|EF_NOSHADOW|EF_BONEMERGE_FASTCULL|EF_PARENT_ANIMATES);

	// Thanks smlib for flag understanding
	int iFlags = GetEntProp(iEntToAttach, Prop_Data, "m_usSolidFlags", 2);
	iFlags = iFlags |= 0x0004;
	SetEntProp(iEntToAttach, Prop_Data, "m_usSolidFlags", iFlags, 2);

	TeleportEntity(iEntToAttach, view_as<float>({0.0, 0.0, 0.0}), view_as<float>({0.0, 0.0, 0.0}), NULL_VECTOR);
}



// ====================================================================================================
//					HELPERS
// ====================================================================================================
int findModelString(int modelIndex, char[] modelString, int string_size)
{
	static int stringTable = INVALID_STRING_TABLE;
	if( stringTable == INVALID_STRING_TABLE )
	{
		stringTable = FindStringTable("modelprecache");
	}
	return ReadStringTable(stringTable, modelIndex, modelString, string_size);
}

void StrToLowerCase(const char[] input, char[] output, int maxlength)
{
	int pos;
	while( input[pos] != 0 && pos < maxlength )
	{
		output[pos] = CharToLower(input[pos]);
		pos++;
	}

	output[pos] = 0;
}