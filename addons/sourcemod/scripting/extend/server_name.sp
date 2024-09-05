#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
ConVar
	cvarServerNameFormatCase1,
	cvarMpGameMode,
	cvarSI,
	cvarMpGameMin,
	cvarHostName,
	cvarMainName,
	cvarMod,
	cvarHostPort;
Handle
	HostName = INVALID_HANDLE;
char
	SavePath[256],
	g_sDefaultN[68];
static Handle
	g_hHostNameFormat; 

public void OnPluginStart()
{
	HostName = CreateKeyValues("AnneHappy");
	BuildPath(Path_SM, SavePath, 255, "configs/hostname/hostname.txt");
	if (FileExists(SavePath))
	{
		FileToKeyValues(HostName, SavePath);
	}
	cvarHostName	= FindConVar("hostname");
	cvarHostPort = FindConVar("hostport");
	cvarMainName = CreateConVar("sn_main_name", "Anne电信服");
	g_hHostNameFormat = CreateConVar("sn_hostname_format", "{hostname}{gamemode}");
	cvarServerNameFormatCase1 = CreateConVar("sn_hostname_format1", "{AnneHappy}{Full}{MOD}{Confogl}");
	cvarMod = FindConVar("l4d2_addons_eclipse");
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("player_bot_replace", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("bot_player_replace", Event_PlayerTeam, EventHookMode_Post);
}

public void OnPluginEnd(){
	cvarMpGameMode = null;
	cvarMpGameMin = null;
	cvarMpGameMode = null;
	cvarMod = null;
}

public void OnAllPluginsLoaded()
{
	cvarSI = FindConVar("l4d_infected_limit");
	cvarMpGameMin = FindConVar("versus_special_respawn_interval");
	cvarMpGameMode = FindConVar("l4d_ready_cfg_name");
	cvarMod = FindConVar("l4d2_addons_eclipse");
}

public void OnConfigsExecuted()
{	
	if(cvarSI != null){
		cvarSI.AddChangeHook(OnCvarChanged);
	}else if(FindConVar("l4d_infected_limit") != null){
		cvarSI = FindConVar("l4d_infected_limit");
		cvarSI.AddChangeHook(OnCvarChanged);
	}
	if(cvarMpGameMin != null){
		cvarMpGameMin.AddChangeHook(OnCvarChanged);
	}else if(FindConVar("versus_special_respawn_interval") != null){
		cvarMpGameMin = FindConVar("versus_special_respawn_interval");
		cvarMpGameMin.AddChangeHook(OnCvarChanged);
	}
	if(cvarMpGameMode != null){
		cvarMpGameMode.AddChangeHook(OnCvarChanged);
	}else if(FindConVar("l4d_ready_cfg_name")){
		cvarMpGameMode = FindConVar("l4d_ready_cfg_name");
		cvarMpGameMode.AddChangeHook(OnCvarChanged);
	}
	if(cvarMod != null){
		cvarMod.AddChangeHook(OnCvarChanged);
	}else if(FindConVar("l4d2_addons_eclipse")){
		cvarMpGameMode = FindConVar("l4d2_addons_eclipse");
		cvarMpGameMode.AddChangeHook(OnCvarChanged);
	}
	Update();
}

public void Event_PlayerTeam( Event hEvent, const char[] sName, bool bDontBroadcast )
{
	Update();
}

public void OnMapStart()
{
	HostName = CreateKeyValues("AnneHappy");
	BuildPath(Path_SM, SavePath, 255, "configs/hostname/hostname.txt");
	FileToKeyValues(HostName, SavePath);
}

public void Update(){

	if(cvarMpGameMode == null){
		ChangeServerName();
	}else{
		UpdateServerName();
	}
}

public void OnCvarChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
	Update();
}

public void UpdateServerName(){
	char sReadyUpCfgName[128], FinalHostname[128], buffer[128];
	bool IsAnne = false;
	GetConVarString(cvarServerNameFormatCase1, FinalHostname, sizeof(FinalHostname));
	GetConVarString(cvarMpGameMode, sReadyUpCfgName, sizeof(sReadyUpCfgName));	
	if(StrContains(sReadyUpCfgName, "AnneHappy", false)!=-1){
		if(StrContains(sReadyUpCfgName, "HardCore", false)!=-1)
			ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[硬核药役]");
		else
			ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[普通药役]");
		IsAnne = true;
	}	
	else if(StrContains(sReadyUpCfgName, "AllCharger", false)!=-1){
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[牛牛冲刺]");
		IsAnne = true;
	}	
	else if(StrContains(sReadyUpCfgName, "1vHunters", false)!=-1)
		{ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[HT训练]");IsAnne = true;}
	else if(StrContains(sReadyUpCfgName, "WitchParty", false)!=-1)
		{ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[女巫派对]");IsAnne = true;}
	else if(StrContains(sReadyUpCfgName, "Alone", false)!=-1)
		{ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}","[单人装逼]");IsAnne = true;}
	else{
		GetConVarString(cvarMpGameMode, buffer, sizeof(buffer));
		Format(buffer, sizeof(buffer),"[%s]", buffer);
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", buffer);
		IsAnne = false;
	}
	if(cvarSI != null && IsAnne){
		Format(buffer, sizeof(buffer),"[%d特%d秒]", GetConVarInt(cvarSI), GetConVarInt(cvarMpGameMin));
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}",buffer);
	}else{
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}","");
	}
	if(IsTeamFull(IsAnne)){
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "");
	}else
	{
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "[缺人]");
	}
	if(cvarMod == null || (cvarMod != null && GetConVarInt(cvarMod) != 0)){
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "");
	}else
	{
		ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "[无MOD]");
	}
	ChangeServerName(FinalHostname);
}

bool IsTeamFull(bool IsAnne = false){
	int sum = 0;
	for(int i = 1; i <= MaxClients; i++){
		if(IsPlayer(i) && !IsFakeClient(i)){
			sum ++;
		}
	}
	if(sum == 0){
		return true;
	}
	if(IsAnne){
		return sum >= (GetConVarInt(FindConVar("survivor_limit")));
	}else{
		return sum >= (GetConVarInt(FindConVar("survivor_limit")) + GetConVarInt(FindConVar("z_max_player_zombies")));
	}
	
}
bool IsPlayer(int client)
{
	if(IsValidClient(client) && (GetClientTeam(client) == 2 || GetClientTeam(client) == 3)){
		return true;
	}
	else{
		return false;
	}
}


void ChangeServerName(char[] sReadyUpCfgName = "")
{
	char sPath[128], ServerPort[128];
	GetConVarString(cvarHostPort, ServerPort, sizeof(ServerPort));
	KvJumpToKey(HostName, ServerPort, false);
	KvGetString(HostName,"servername", sPath, sizeof(sPath));
	KvGoBack(HostName);
	char sNewName[128];
	if(strlen(sPath) == 0)
	{
		GetConVarString(cvarMainName, sNewName, sizeof(sNewName));
	}
	else
	{
		GetConVarString(g_hHostNameFormat, sNewName, sizeof(sNewName));
		ReplaceString(sNewName, sizeof(sNewName), "{hostname}", sPath);
		ReplaceString(sNewName, sizeof(sNewName), "{gamemode}", sReadyUpCfgName);
	}
	SetConVarString(cvarHostName, sNewName);
	SetConVarString(cvarMainName, sNewName);
	Format(g_sDefaultN, sizeof(g_sDefaultN), "%s", sNewName);
}

public bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}