/*  SM Client Command Logging
 *
 *  Copyright (C) 2017-2021 Francisco 'Franc1sco' García
 * 
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option) 
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT 
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS 
 * FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with 
 * this program. If not, see http://www.gnu.org/licenses/.
 */

#include <sourcemod>
#include <sdktools>

#pragma newdecls required
#pragma semicolon 1

// add here the ignore commands that will not logged (maybe a cfg file in a future)
char ignoredCommands[][] =
{
	"+lookatweapon",
	"-lookatweapon",
	"snd_setsoundparam",
	"vmodenable",
	"vban",
	"menuopen",
	"menuclosed",
	"menuselect",
	"voicemenu",
	
};

char g_sCmdLogPath[256];

#define DATA "2.0.2"

public Plugin myinfo =
{
    name = "SM Client Command Logging",
    author = "Franc1sco franug", 
    description = "Logging every command that the client use", 
    version = DATA, 
    url = "http://steamcommunity.com/id/franug"
};

public void OnPluginStart()
{
	CreateConVar("sm_clientcommandlogging_version", DATA, "", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NONE);
	
	for(int i=0;;i++)
	{
		BuildPath(Path_SM, g_sCmdLogPath, sizeof(g_sCmdLogPath), "logs/CmdLog_%d.log", i);
		if ( !FileExists(g_sCmdLogPath) )
			break;
	}
}

public void OnAllPluginsLoaded()
{
	AddCommandListener(Commands_CommandListener);
}

public Action Commands_CommandListener(int client, const char[] command, int argc)
{
	if (client < 1)
		return;

	char f_sCmdString[2048];
	GetCmdArg(0, f_sCmdString, sizeof(f_sCmdString));
	
	for (int i = 0; i < sizeof(ignoredCommands); i++)
	{
		if(StrEqual(f_sCmdString, ignoredCommands[i]))
			return;	
	}
	
	GetCmdArgString(f_sCmdString, sizeof(f_sCmdString));
	
	if(!IsClientInGame(client))
		LogToFileEx(g_sCmdLogPath, "No ingame client %i used: %s %s", client, command, f_sCmdString);
	else
		LogToFileEx(g_sCmdLogPath, "%L used: %s %s", client, command, f_sCmdString);
}