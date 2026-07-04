#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <builtinvotes>
#include <left4dhooks>
#include <colors>
#undef REQUIRE_PLUGIN
#include <extra_menu>
#include <sourcebanspp>
#include <l4dstats>

#define VOTE_MENU_NAME_LENGTH 128
#define VOTE_MENU_MAX_CATEGORIES 64

bool g_bSourceBansSystemAvailable = false, g_bl4dstatsSystemAvailable = false;
public void OnAllPluginsLoaded(){
	g_bSourceBansSystemAvailable = LibraryExists("sourcebans++");
	g_bl4dstatsSystemAvailable = LibraryExists("l4d_stats");
	QueueCreateExtraVoteMenus();
}
public void OnLibraryAdded(const char[] name)
{
    if ( StrEqual(name, "sourcebans++") ) { g_bSourceBansSystemAvailable = true; }
	else if ( StrEqual(name, "l4d_stats") ) { g_bl4dstatsSystemAvailable = true; }
	else if ( StrEqual(name, "extra_menu") ) { QueueCreateExtraVoteMenus(); }
}
public void OnLibraryRemoved(const char[] name)
{
    if ( StrEqual(name, "sourcebans++") ) { g_bSourceBansSystemAvailable = true; }
	else if ( StrEqual(name, "l4d_stats") ) { g_bl4dstatsSystemAvailable = true; }
	else if ( StrEqual(name, "extra_menu") ) { DeleteExtraVoteMenus(); }
}

public Plugin myinfo =
{
	name = "Vote for run command or cfg file",
	description = "使用!vote投票执行命令或cfg文件",
	author = "东",
	version = "1.4",
	url = "https://github.com/fantasylidong/"
};
/*
1.0 版本 初始发布
1.1 版本 限制旁观使用投票功能
1.2 版本 旁观不参与投票
1.3 版本 增加Cvar控制投票文件, 1.11新语法, 增加sourcebans 1天封禁投票[分数大于300000]
*/

Handle
	g_hVote,
	g_hVoteKick,
	g_hVoteBan,	
	g_hCfgsKV;

ConVar
	g_hVoteFilelocation;

char
	g_sCfg[128],
	g_sVoteFile[128];

int 
	banclient,
	kickclient;

int g_iExtraVoteMenu = -1;
int g_iExtraCommandMenus[VOTE_MENU_MAX_CATEGORIES];
int g_iExtraCommandMenuCount;
char g_sExtraCommandMenuCategories[VOTE_MENU_MAX_CATEGORIES][VOTE_MENU_NAME_LENGTH];
Handle g_hExtraVoteMenuCreateTimer = null;



public void OnPluginStart()
{
	LoadTranslations("vote.phrases");
	char g_sBuffer[128];
	g_hVoteFilelocation = CreateConVar("votecfgfile", "configs/cfgs.txt", "投票文件的位置(位于sourcemod/文件夹)", FCVAR_NOTIFY);
	//GetGameFolderName(g_sBuffer, sizeof(g_sBuffer));
	GetConVarString(g_hVoteFilelocation, g_sVoteFile, sizeof(g_sVoteFile));
	RegConsoleCmd("sm_vote", VoteRequest);
	RegConsoleCmd("sm_votekick", KickRequest);
	RegConsoleCmd("sm_voteban", BanRequest);
	RegAdminCmd("sm_cancelvote", VoteCancle, ADMFLAG_GENERIC, "管理员终止此次投票", "", 0);
	g_hVoteFilelocation.AddChangeHook(FileLocationChanged);
	g_hCfgsKV = CreateKeyValues("Cfgs", "", "");
	BuildPath(Path_SM, g_sBuffer, 128, g_sVoteFile);
	if (!FileToKeyValues(g_hCfgsKV, g_sBuffer))
	{
		SetFailState("无法加载%s文件!", g_sVoteFile);
	}
	QueueCreateExtraVoteMenus();
}

public void FileLocationChanged(ConVar convar, const char[] oldValue, const char[] newValue){
	char g_sBuffer[128];
	DeleteExtraVoteMenus();
	GetConVarString(g_hVoteFilelocation, g_sVoteFile, sizeof(g_sVoteFile));
	//GetGameFolderName(g_sBuffer, sizeof(g_sBuffer));
	g_hCfgsKV = CreateKeyValues("Cfgs", "", "");
	BuildPath(Path_SM, g_sBuffer, 128, g_sVoteFile);
	if (!FileToKeyValues(g_hCfgsKV, g_sBuffer))
	{
		SetFailState("无法加载%s文件!", g_sVoteFile);
	}
	QueueCreateExtraVoteMenus();
}

public void OnPluginEnd()
{
	if (g_hExtraVoteMenuCreateTimer != null)
	{
		KillTimer(g_hExtraVoteMenuCreateTimer);
		g_hExtraVoteMenuCreateTimer = null;
	}

	DeleteExtraVoteMenus();
}

public Action VoteCancle(int client, int args)
{
	if (IsBuiltinVoteInProgress())
	{
		CancelBuiltinVote();
		CPrintToChatAll("%t", "Vote_AdministratorCanceledCurrentVote");
		return Plugin_Handled;
	}
	ReplyToCommand(client, "%t", "Vote_NoVoteInProgress");
	return Plugin_Handled;
}

// *************************
// 			生还者
// *************************
// 判断是否有效玩家 id，有效返回 true，无效返回 false
stock bool IsValidClient(int client)
{
	if (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client))
	{
		return true;
	}
	else
	{
		return false;
	}
}

stock bool IsPlayer(int client)
{
	int team = GetClientTeam(client);
	return (team == 2 || team == 3);
}

public Action VoteRequest(int client, int args)
{
	if (!client)
	{
		return Plugin_Handled;
	}
	if (IsValidClient(client) && !IsPlayer(client))
	{
		CPrintToChat(client, "%t", "Vote_BystandersNotAllowedVoteExecute");
		return Plugin_Handled;
	}
	if (args > 0)
	{
		char sCfg[128];
		char sBuffer[256];
		GetCmdArg(1, sCfg, sizeof(sCfg));
		BuildPath(Path_SM, sBuffer, sizeof(sBuffer), "../../cfg/%s", sCfg);
		if (DirExists(sBuffer))
		{
			FindConfigName(sCfg, sBuffer, sizeof(sBuffer));
			if (StartVote(client, sBuffer, sCfg))
			{
				strcopy(g_sCfg, sizeof(g_sCfg), sCfg);
				FakeClientCommand(client, "Vote Yes");
			}
			return Plugin_Handled;
		}
	}
	ShowVoteMenu(client);
	return Plugin_Handled;
}

bool FindConfigName(char[] cfg, char[] message, int maxlength)
{
	KvRewind(g_hCfgsKV);
	if (KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		while (KvJumpToKey(g_hCfgsKV, cfg, false))
		{
			if (KvGotoNextKey(g_hCfgsKV, true))
			{
			}
		}
		KvGetString(g_hCfgsKV, "message", message, maxlength, "");
		return true;
	}
	return false;
}

void ShowVoteMenu(int client)
{
	if (DisplayVoteExtraMenu(client))
	{
		return;
	}

	DisplayBuiltinVoteMenu(client);
}

bool DisplayVoteExtraMenu(int client)
{
	if (g_iExtraVoteMenu == -1)
	{
		CreateExtraVoteMenusIfReady();
	}

	if (g_iExtraVoteMenu == -1 || GetFeatureStatus(FeatureType_Native, "ExtraMenu_Display") != FeatureStatus_Available)
	{
		return false;
	}

	return ExtraMenu_Display(client, g_iExtraVoteMenu, MENU_TIME_FOREVER);
}

void DisplayBuiltinVoteMenu(int client)
{
	Handle hMenu = CreateMenu(VoteMenuHandler, MENU_ACTIONS_DEFAULT);
	SetMenuTitle(hMenu, "选择:");
	char sBuffer[64];
	KvRewind(g_hCfgsKV);
	if (KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		do {
			KvGetSectionName(g_hCfgsKV, sBuffer, sizeof(sBuffer));
			AddMenuItem(hMenu, sBuffer, sBuffer, ITEMDRAW_DEFAULT);
		} while (KvGotoNextKey(g_hCfgsKV, true));
	}
	DisplayMenu(hMenu, client, 20);
}

bool DisplayExtraVoteCommandMenu(int client, const char[] category)
{
	if (GetFeatureStatus(FeatureType_Native, "ExtraMenu_Display") != FeatureStatus_Available)
	{
		return false;
	}

	int menu = FindExtraVoteCommandMenu(category);
	if (menu == -1)
	{
		return false;
	}

	return ExtraMenu_Display(client, menu, MENU_TIME_FOREVER);
}

bool DisplayBuiltinVoteCommandMenu(int client, const char[] category)
{
	char sInfo[128];
	char sBuffer[128];
	KvRewind(g_hCfgsKV);
	if (KvJumpToKey(g_hCfgsKV, category, false) && KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		Handle hMenu = CreateMenu(ConfigsMenuHandler, MENU_ACTIONS_DEFAULT);
		Format(sBuffer, sizeof(sBuffer), "选择 %s :", category);
		SetMenuTitle(hMenu, sBuffer);
		do {
			KvGetSectionName(g_hCfgsKV, sInfo,  sizeof(sInfo));
			KvGetString(g_hCfgsKV, "message", sBuffer, sizeof(sBuffer), "");
			int itemStyle = ITEMDRAW_DEFAULT;
			if (L4D_HasAnySurvivorLeftSafeArea() && IsRestartMapVoteCommand(sInfo))
			{
				itemStyle = ITEMDRAW_DISABLED;
			}
			AddMenuItem(hMenu, sInfo, sBuffer, itemStyle);
		} while (KvGotoNextKey(g_hCfgsKV, true));
		DisplayMenu(hMenu, client, 20);
		return true;
	}

	return false;
}

public int VoteMenuHandler(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char sInfo[128];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		HandleVoteCategorySelected(param1, sInfo);
	}
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	return 0;
}

public int ConfigsMenuHandler(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char sInfo[128];
		char sBuffer[128];
		int style;
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo), style, sBuffer, sizeof(sBuffer));
		HandleVoteCommandSelected(param1, sInfo, sBuffer);
	}
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	if (action == MenuAction_Cancel)
	{
		ShowVoteMenu(param1);
	}
	return 0;
}

void HandleVoteCategorySelected(int client, const char[] category)
{
	if (DisplayExtraVoteCommandMenu(client, category))
	{
		return;
	}

	if (!DisplayBuiltinVoteCommandMenu(client, category))
	{
		CPrintToChat(client, "%t", "Vote_NoRelatedFilesExist");
		ShowVoteMenu(client);
	}
}

void HandleVoteCommandSelected(int client, const char[] command, const char[] message)
{
	strcopy(g_sCfg, sizeof(g_sCfg), command);
	if (IsSpawnVoteMenuCommand(command))
	{
		FakeClientCommand(client, command);
	}
	else if (!StrEqual(g_sCfg, "sm_votekick", true))
	{
		if (StartVote(client, message, command))
		{
			FakeClientCommand(client, "Vote Yes");
		}
		else
		{
			ShowVoteMenu(client);
		}
	}
	else
	{
		FakeClientCommand(client, "sm_votekick");
	}
}

public void ExtraMenu_OnSelect(int client, int menu_id, int option, int value)
{
	if (menu_id == g_iExtraVoteMenu)
	{
		if (option < 0)
		{
			return;
		}

		char category[VOTE_MENU_NAME_LENGTH];
		if (FindVoteCategoryByOption(option, category, sizeof(category)))
		{
			HandleVoteCategorySelected(client, category);
		}
		return;
	}

	char category[VOTE_MENU_NAME_LENGTH];
	if (!FindExtraVoteCommandMenuCategory(menu_id, category, sizeof(category)))
	{
		return;
	}

	if (option < 0)
	{
		ShowVoteMenu(client);
		return;
	}

	char command[VOTE_MENU_NAME_LENGTH];
	char message[VOTE_MENU_NAME_LENGTH];
	if (FindVoteCommandByOption(category, option, command, sizeof(command), message, sizeof(message)))
	{
		HandleVoteCommandSelected(client, command, message);
	}
	else
	{
		CPrintToChat(client, "%t", "Vote_NoRelatedFilesExist");
		ShowVoteMenu(client);
	}
}

void QueueCreateExtraVoteMenus()
{
	if (g_hExtraVoteMenuCreateTimer != null)
	{
		return;
	}

	g_hExtraVoteMenuCreateTimer = CreateTimer(0.1, Timer_CreateExtraVoteMenus, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_CreateExtraVoteMenus(Handle timer)
{
	g_hExtraVoteMenuCreateTimer = null;
	CreateExtraVoteMenusIfReady();
	return Plugin_Stop;
}

void CreateExtraVoteMenusIfReady()
{
	if (g_hCfgsKV == null || GetFeatureStatus(FeatureType_Native, "ExtraMenu_Create") != FeatureStatus_Available)
	{
		return;
	}

	DeleteExtraVoteMenus();

	g_iExtraVoteMenu = ExtraMenu_Create(false, "", false);
	if (g_iExtraVoteMenu == -1)
	{
		return;
	}

	ExtraMenu_AddEntry(g_iExtraVoteMenu, "选择:", MENU_ENTRY);

	char category[VOTE_MENU_NAME_LENGTH];
	KvRewind(g_hCfgsKV);
	if (KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		do {
			KvGetSectionName(g_hCfgsKV, category, sizeof(category));
			ExtraMenu_AddEntry(g_iExtraVoteMenu, category, MENU_SELECT_ONLY);
			CreateExtraVoteCommandMenu(category);
		} while (KvGotoNextKey(g_hCfgsKV, true));
	}
}

void CreateExtraVoteCommandMenu(const char[] category)
{
	if (g_iExtraCommandMenuCount >= VOTE_MENU_MAX_CATEGORIES)
	{
		return;
	}

	KvRewind(g_hCfgsKV);
	if (!KvJumpToKey(g_hCfgsKV, category, false) || !KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		return;
	}

	int menu = ExtraMenu_Create(true, "", false);
	if (menu == -1)
	{
		return;
	}

	char entry[VOTE_MENU_NAME_LENGTH];
	Format(entry, sizeof(entry), "选择 %s :", category);
	ExtraMenu_AddEntry(menu, entry, MENU_ENTRY);

	do {
		KvGetString(g_hCfgsKV, "message", entry, sizeof(entry), "");
		ExtraMenu_AddEntry(menu, entry, MENU_SELECT_ONLY, true);
	} while (KvGotoNextKey(g_hCfgsKV, true));

	g_iExtraCommandMenus[g_iExtraCommandMenuCount] = menu;
	strcopy(g_sExtraCommandMenuCategories[g_iExtraCommandMenuCount], VOTE_MENU_NAME_LENGTH, category);
	g_iExtraCommandMenuCount++;
}

void DeleteExtraVoteMenus()
{
	bool canDelete = GetFeatureStatus(FeatureType_Native, "ExtraMenu_Delete") == FeatureStatus_Available;
	if (canDelete && g_iExtraVoteMenu != -1)
	{
		ExtraMenu_Delete(g_iExtraVoteMenu);
	}
	g_iExtraVoteMenu = -1;

	for (int i = 0; i < g_iExtraCommandMenuCount; i++)
	{
		if (canDelete && g_iExtraCommandMenus[i] != -1)
		{
			ExtraMenu_Delete(g_iExtraCommandMenus[i]);
		}
		g_iExtraCommandMenus[i] = -1;
		g_sExtraCommandMenuCategories[i][0] = '\0';
	}
	g_iExtraCommandMenuCount = 0;
}

int FindExtraVoteCommandMenu(const char[] category)
{
	for (int i = 0; i < g_iExtraCommandMenuCount; i++)
	{
		if (StrEqual(g_sExtraCommandMenuCategories[i], category, false))
		{
			return g_iExtraCommandMenus[i];
		}
	}

	return -1;
}

bool FindExtraVoteCommandMenuCategory(int menu, char[] category, int maxlength)
{
	for (int i = 0; i < g_iExtraCommandMenuCount; i++)
	{
		if (g_iExtraCommandMenus[i] == menu)
		{
			strcopy(category, maxlength, g_sExtraCommandMenuCategories[i]);
			return true;
		}
	}

	return false;
}

bool FindVoteCategoryByOption(int option, char[] category, int maxlength)
{
	int currentOption;
	KvRewind(g_hCfgsKV);
	if (KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		do {
			if (currentOption == option)
			{
				KvGetSectionName(g_hCfgsKV, category, maxlength);
				return true;
			}
			currentOption++;
		} while (KvGotoNextKey(g_hCfgsKV, true));
	}

	return false;
}

bool FindVoteCommandByOption(const char[] category, int option, char[] command, int commandMaxLength, char[] message, int messageMaxLength)
{
	int currentOption;
	KvRewind(g_hCfgsKV);
	if (KvJumpToKey(g_hCfgsKV, category, false) && KvGotoFirstSubKey(g_hCfgsKV, true))
	{
		do {
			if (currentOption == option)
			{
				KvGetSectionName(g_hCfgsKV, command, commandMaxLength);
				KvGetString(g_hCfgsKV, "message", message, messageMaxLength, "");
				return true;
			}
			currentOption++;
		} while (KvGotoNextKey(g_hCfgsKV, true));
	}

	return false;
}

bool IsSpawnVoteMenuCommand(const char[] command)
{
	return StrEqual(command, "sm_spawnvote", false)
		|| StrEqual(command, "sm_sivote", false)
		|| StrEqual(command, "sm刷特", false);
}

bool IsRestartMapVoteCommand(const char[] command)
{
	char sCommand[128];
	strcopy(sCommand, sizeof(sCommand), command);
	TrimString(sCommand);

	return StrEqual(sCommand, "sm_restartmap", false);
}

bool StartVote(int client, const char[] cfgname, const char[] command)
{
	if (L4D_HasAnySurvivorLeftSafeArea() && IsRestartMapVoteCommand(command))
	{
		CPrintToChat(client, "%t", "Vote_CannotVoteResetCurrentMap");
		return false;
	}

	if (!IsBuiltinVoteInProgress())
	{
		char sBuffer[64];
		strcopy(g_sCfg, sizeof(g_sCfg), command);
		g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
		Format(sBuffer, 64, "执行 '%s' ?", cfgname);
		SetBuiltinVoteArgument(g_hVote, sBuffer);
		SetBuiltinVoteInitiator(g_hVote, client);
		SetBuiltinVoteResultCallback(g_hVote, VoteResultHandler);
		DisplayBuiltinVoteToAllNonSpectators(g_hVote, 20);
		FakeClientCommand(client, "Vote Yes");
		CPrintToChatAll("%t", "Vote_InitiatedVote", client);
		return true;
	}
	CPrintToChat(client, "%t", "Vote_AlreadyVoteProgress");
	return false;
}

public void VoteActionHandler(Handle vote, BuiltinVoteAction action, int param1, int param2)
{
	switch (action)
	{
		case BuiltinVoteAction_End:
		{
			g_hVote = INVALID_HANDLE;
			CloseHandle(vote);
		}
		case BuiltinVoteAction_Cancel:
		{
			DisplayBuiltinVoteFail(vote, view_as<BuiltinVoteFailReason>(param1));
		}
	}
}

public void VoteResultHandler(Handle vote, int num_votes, int num_clients, const int[][] client_info, int num_items, const int[][] item_info)
{
	for (int i = 0; i< num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES)
		{
			if (item_info[i][BUILTINVOTEINFO_ITEM_VOTES] >= (num_votes * 0.6))
			{
				if (g_hVote == vote)
				{
					DisplayBuiltinVotePass(vote, "文件正在加载...");
					ServerCommand("%s", g_sCfg);
					return;
				}
				if (g_hVoteKick == vote)
				{
					DisplayBuiltinVotePass(vote, "投票已完成...");
					KickClient(kickclient, "投票踢出");
					return;
				}
				if (g_hVoteBan == vote)
				{
					DisplayBuiltinVotePass(vote, "投票已完成...");
					if(g_bSourceBansSystemAvailable){
						SBPP_BanPlayer(0, banclient, 1440, "投票封禁");
					}else
					{
						BanClient(banclient,  1440, ADMFLAG_BAN, "投票封禁", "你已被当前服务器踢出，原因为投票封禁");
					}
				}
			}
		}
	}
	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

public Action KickRequest(int client, int args)
{
	if (client && client <= MaxClients)
	{
		CreateVotekickMenu(client);
		return Plugin_Handled;
	}
	return Plugin_Handled;
}

void CreateVotekickMenu(int client)
{
	Handle menu = CreateMenu(Menu_Voteskick, MENU_ACTIONS_DEFAULT);
	char name[126];
	char info[128];
	char playerid[128];
	SetMenuTitle(menu, "选择踢出玩家");
	int i = 1;
	while (i <= MaxClients)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			Format(playerid, sizeof(playerid), "%i", GetClientUserId(i));
			if (GetClientName(i, name, sizeof(name)))
			{
				Format(info, sizeof(info), "%s", name);
				AddMenuItem(menu, playerid, info, ITEMDRAW_DEFAULT);
			}
		}
		i++;
	}
	DisplayMenu(menu, client, 30);
}

public int Menu_Voteskick(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char name[128];
		GetMenuItem(menu, param2, name, sizeof(name));
		kickclient = GetClientOfUserId(StringToInt(name));
		CPrintToChatAll("%t", "Vote_InitiatesVoteKick", param1, kickclient);
		if (DisplayVoteKickMenu(param1))
		{
			FakeClientCommand(param1, "Vote Yes");
		}
	}
	return 0;
}

public bool DisplayVoteKickMenu(int client)
{
	if (!IsBuiltinVoteInProgress())
	{
		char sBuffer[128];
		g_hVoteKick = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
		Format(sBuffer, 128, "踢出 '%N' ?", kickclient);
		SetBuiltinVoteArgument(g_hVoteKick, sBuffer);
		SetBuiltinVoteInitiator(g_hVoteKick, client);
		SetBuiltinVoteResultCallback(g_hVoteKick, VoteResultHandler);
		DisplayBuiltinVoteToAllNonSpectators(g_hVoteKick, 20);
		FakeClientCommand(client, "Vote Yes");
		CPrintToChatAll("%t", "Vote_InitiatedVote", client);
		return true;
	}
	CPrintToChat(client, "%t", "Vote_AlreadyVoteProgress");
	return false;
}

public Action BanRequest(int client, int args)
{
	if(g_bl4dstatsSystemAvailable){
		if(l4dstats_GetClientScore(client) < 100000){
			CPrintToChat(client, "%t", "Vote_NotPreventBanMisusedRequires");
			return Plugin_Handled;
		}else{
			CPrintToChat(client, "%t", "Vote_UsePowerCautionAbuseBans");
		}
	}
	if (client && client <= MaxClients)
	{
		CreateVoteBanMenu(client);
		return Plugin_Handled;
	}
	return Plugin_Handled;
}

void CreateVoteBanMenu(int client)
{
	Handle menu = CreateMenu(Menu_VotesBan, MENU_ACTIONS_DEFAULT);
	char name[126];
	char info[128];
	char playerid[128];
	SetMenuTitle(menu, "选择封禁玩家");
	int i = 1;
	while (i <= MaxClients)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			Format(playerid, sizeof(playerid), "%i", GetClientUserId(i));
			if (GetClientName(i, name, sizeof(name)))
			{
				Format(info, sizeof(info), "%s", name);
				AddMenuItem(menu, playerid, info, ITEMDRAW_DEFAULT);
			}
		}
		i++;
	}
	DisplayMenu(menu, client, 30);
}

public int Menu_VotesBan(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char name[128];
		GetMenuItem(menu, param2, name, sizeof(name));
			banclient = GetClientOfUserId(StringToInt(name));
			CPrintToChatAll("%t", "Vote_InitiatesVoteBanOneDay", param1, banclient);
			if (DisplayVoteBanMenu(param1))
		{
			FakeClientCommand(param1, "Vote Yes");
		}
	}
	return 0;
}

public bool DisplayVoteBanMenu(int client)
{
	if (!IsBuiltinVoteInProgress())
	{
		int iNumPlayers;
		int iPlayers[MAXPLAYERS];
		int i = 1;
		while (i <= MaxClients)
		{
			if(IsClientInGame(i) && !IsFakeClient(i))
			{
				iNumPlayers++;
				iPlayers[iNumPlayers] = i;
			}
			i++;
		}
		char sBuffer[128];
		g_hVoteBan = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
		Format(sBuffer, 128, "封禁 '%N' 一天?", banclient);
		SetBuiltinVoteArgument(g_hVoteBan, sBuffer);
		SetBuiltinVoteInitiator(g_hVoteBan, client);
		SetBuiltinVoteResultCallback(g_hVoteBan, VoteResultHandler);
		DisplayBuiltinVoteToAll(g_hVoteBan, 20);
		FakeClientCommand(client, "Vote Yes");
		CPrintToChatAll("%t", "Vote_InitiatedVote", client);
		return true;
	}
	CPrintToChat(client, "%t", "Vote_AlreadyVoteProgress");
	return false;
}
