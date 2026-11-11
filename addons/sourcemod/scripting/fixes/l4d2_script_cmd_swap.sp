#define PLUGIN_VERSION		"1.0"
#define BUFFER_SIZE			8192

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>



public Plugin myinfo =
{
	name = "[L4D2] Script Command Swap - Mem Leak Fix",
	author = "SilverShot (Timocop's idea)",
	description = "Blocks the script command and replaces with a logic_script entity to execute the code instead.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=317128"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
		return APLRes_SilentFailure;
	}
	return APLRes_Success;
}

ConVar g_hCvarCheats;

public void OnPluginStart()
{
	CreateConVar("l4d2_script_cmd_swap_version", PLUGIN_VERSION, "Script Cmd Swap version.", FCVAR_NONE|FCVAR_DONTRECORD);
	g_hCvarCheats = FindConVar("sv_cheats");
	AddCommandListener(CmdScript, "script");
}

Action CmdScript(int client, const char[] command, int arg)
{
	if( client != 0 && (g_hCvarCheats == null || !g_hCvarCheats.BoolValue) && !CheckCommandAccess(client, "script", ADMFLAG_RCON, true) )
	{
		return Plugin_Continue;
	}

	static char args[BUFFER_SIZE];
	GetCmdArgString(args, sizeof(args));
	RunScriptRaw(args);
	return Plugin_Handled;
}

void RunScriptRaw(const char[] sCode)
{
	static int iScriptLogic = INVALID_ENT_REFERENCE;
	int entity = EntRefToEntIndex(iScriptLogic);
	if( entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity) )
	{
		entity = CreateEntityByName("logic_script");
		if( entity == -1 || !IsValidEntity(entity) )
			SetFailState("Could not create 'logic_script'");

		DispatchSpawn(entity);
		iScriptLogic = EntIndexToEntRef(entity);
	}

	SetVariantString(sCode);
	AcceptEntityInput(entity, "RunScriptCode");
}

// Credit to Timocop on VScript function
/**
* Runs a single line of VScript code.
* NOTE: Dont use the "script" console command, it starts a new instance and leaks memory. Use this instead!
*
* @param sCode        The code to run.
* @noreturn
*/
stock void L4D2_RunScript(char[] sCode, any ...)
{
	static char sBuffer[BUFFER_SIZE];
	VFormat(sBuffer, sizeof(sBuffer), sCode, 2);
	RunScriptRaw(sBuffer);
}