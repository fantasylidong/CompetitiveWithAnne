#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dbi>
#include <builtinvotes>
#include <builtinvotes_stocks>
#include <colors>
#include <anne_cvar_shield>

#define PLUGIN_VERSION "1.0.5"
#define VOTE_TIME 20
#define MENU_TIME MENU_TIME_FOREVER
#define SPAWN_MENU_UNSET -999999
#define SPAWN_VOTE_MENU_INFO_LENGTH 128
#define SPAWN_VOTE_COMMAND_LENGTH 128
#define ANNE_LIMIT_MIN 1
#define ANNE_LIMIT_MAX 24
#define MAX_SPAWN_PRESETS 16
#define SPAWN_PRESET_NAME_LENGTH 64
#define PRESET_TABLE_LENGTH 64
#define PRESET_MODE_LENGTH 16
#define PRESET_AUTHOR_LENGTH 64
#define NATIVE_VOTE_LANGUAGE_CODE "chi"

enum SpawnVoteMode
{
	SpawnVoteMode_None = 0,
	SpawnVoteMode_Campaign,
	SpawnVoteMode_Anne
}

public Plugin myinfo =
{
	name = "Anne Spawn Vote Menu",
	author = "morzlee",
	description = "SourceMod menu based spawn tuning vote menu for Anne and campaign modes.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

Handle g_hVote = INVALID_HANDLE;
KeyValues g_kvNativeVotePhrases = null;

SpawnVoteMode g_iPendingMode = SpawnVoteMode_None;
int g_iPendingLimit;
int g_iPendingInterval;
int g_iPendingAutoMode;
int g_iPendingDistance;
int g_iPendingTeleportCheck;
int g_iPendingTraitorEnable;
int g_iPendingAssault;
int g_iPendingTankTogether;
int g_iPendingRelax;
int g_iLastRequester;

ConVar g_cvDirCount;
ConVar g_cvDirInterval;
ConVar g_cvDirLockTempo;
ConVar g_cvDirAllowTank;
ConVar g_cvDirRelaxEnable;
ConVar g_cvAnneLimit;
ConVar g_cvAnneInterval;
ConVar g_cvAnneAutoSpawn;
ConVar g_cvAnneDistance;
ConVar g_cvAnneTeleportCheck;
ConVar g_cvAnneTraitorEnable;
ConVar g_cvVoteCfgFile;
ConVar g_cvPresetDbConfig;
ConVar g_cvPresetTable;

Database g_hPresetDb = null;
bool g_bPresetSchemaReady;
bool g_bPresetDbIsMySQL;

char g_sCampaignPresetNames[MAX_SPAWN_PRESETS][SPAWN_PRESET_NAME_LENGTH];
int g_iCampaignPresetLimit[MAX_SPAWN_PRESETS];
int g_iCampaignPresetInterval[MAX_SPAWN_PRESETS];
int g_iCampaignPresetAssault[MAX_SPAWN_PRESETS];
int g_iCampaignPresetTankTogether[MAX_SPAWN_PRESETS];
int g_iCampaignPresetRelax[MAX_SPAWN_PRESETS];
int g_iCampaignPresetCount;

char g_sAnnePresetNames[MAX_SPAWN_PRESETS][SPAWN_PRESET_NAME_LENGTH];
int g_iAnnePresetLimit[MAX_SPAWN_PRESETS];
int g_iAnnePresetInterval[MAX_SPAWN_PRESETS];
int g_iAnnePresetAutoMode[MAX_SPAWN_PRESETS];
int g_iAnnePresetDistance[MAX_SPAWN_PRESETS];
int g_iAnnePresetTeleportCheck[MAX_SPAWN_PRESETS];
int g_iAnnePresetCount;

bool g_bPendingPreset;
bool g_bPendingConfigCommand;
char g_sPendingPresetName[SPAWN_PRESET_NAME_LENGTH];
char g_sPendingExecCommand[SPAWN_VOTE_COMMAND_LENGTH];
char g_sPendingChangeSummary[128];

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("vote.phrases");
	LoadTranslations("spawn_vote_menu.phrases");
	LoadNativeVotePhrases();

	RegConsoleCmd("sm_spawnvote", Cmd_SpawnVote, "打开刷特投票菜单");
	RegConsoleCmd("sm_sivote", Cmd_SpawnVote, "打开刷特投票菜单");
	RegConsoleCmd("sm刷特", Cmd_SpawnVote, "打开刷特投票菜单");
	RegAdminCmd("sm_spawnpreset_save", Cmd_SaveSpawnPreset, ADMFLAG_CONFIG, "保存当前刷特设置为预设: sm_spawnpreset_save <名字>");
	RegAdminCmd("sm_spawnpreset_delete", Cmd_DeleteSpawnPreset, ADMFLAG_CONFIG, "删除刷特预设: sm_spawnpreset_delete <名字>");
	RegConsoleCmd("sm_spawnpreset_list", Cmd_ListSpawnPresets, "列出当前模式刷特预设");

	g_cvPresetDbConfig = CreateConVar("sm_spawnvote_preset_db", "storage-local", "刷特预设数据库配置名，支持 MySQL 或 SQLite");
	g_cvPresetTable = CreateConVar("sm_spawnvote_preset_table", "spawn_vote_presets", "刷特预设数据库表名");

	ResetPendingSpawnSettings();
	RefreshSpawnVoteConVars();
	ConnectPresetDatabase();
}

public void OnAllPluginsLoaded()
{
	RefreshSpawnVoteConVars();
}

public void OnPluginEnd()
{
	ClosePresetDatabase();
	CloseNativeVotePhrases();
}

Action Cmd_SpawnVote(int client, int args)
{
	if (!IsValidPlayer(client))
	{
		return Plugin_Handled;
	}

	if (!IsPlayer(client))
	{
		CPrintToChat(client, "%t", "SpawnVote_SpectatorsNotAllowed");
		return Plugin_Handled;
	}

	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(client, "%t", "SpawnVote_AlreadyVoteProgress");
		return Plugin_Handled;
	}

	RefreshSpawnVoteConVars();
	SpawnVoteMode mode = DetectSpawnVoteMode();
	ResetPendingSpawnSettings();

	switch (mode)
	{
		case SpawnVoteMode_Campaign:
		{
			DisplayCampaignSpawnVoteMenu(client);
		}
		case SpawnVoteMode_Anne:
		{
			DisplayAnneSpawnVoteMenu(client);
		}
		default:
		{
			CPrintToChat(client, "%t", "SpawnVote_NoSpawnController");
		}
	}

	return Plugin_Handled;
}

Action Cmd_SaveSpawnPreset(int client, int args)
{
	if (args < 1)
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetNameRequired");
		return Plugin_Handled;
	}

	if (!EnsurePresetDatabase())
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetDbUnavailable");
		return Plugin_Handled;
	}

	RefreshSpawnVoteConVars();
	SpawnVoteMode mode = DetectSpawnVoteMode();
	if (mode == SpawnVoteMode_None)
	{
		ReplyToPresetCommand(client, "SpawnVote_NoSpawnController");
		return Plugin_Handled;
	}

	char name[SPAWN_PRESET_NAME_LENGTH];
	GetCmdArgString(name, sizeof(name));
	StripQuotes(name);
	TrimString(name);
	if (name[0] == '\0')
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetNameRequired");
		return Plugin_Handled;
	}

	ResetPendingSpawnSettings();
	if (mode == SpawnVoteMode_Campaign)
	{
		PrepareCampaignPendingFromCurrent();
	}
	else
	{
		PrepareAnnePendingFromCurrent();
	}

	if (SaveCurrentSpawnPreset(client, mode, name))
	{
		LoadSpawnPresets();
		ReplyToPresetSaved(client, name);
	}
	else
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetDbUnavailable");
	}

	return Plugin_Handled;
}

Action Cmd_DeleteSpawnPreset(int client, int args)
{
	if (args < 1)
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetNameRequired");
		return Plugin_Handled;
	}

	if (!EnsurePresetDatabase())
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetDbUnavailable");
		return Plugin_Handled;
	}

	RefreshSpawnVoteConVars();
	SpawnVoteMode mode = DetectSpawnVoteMode();
	if (mode == SpawnVoteMode_None)
	{
		ReplyToPresetCommand(client, "SpawnVote_NoSpawnController");
		return Plugin_Handled;
	}

	char name[SPAWN_PRESET_NAME_LENGTH];
	GetCmdArgString(name, sizeof(name));
	StripQuotes(name);
	TrimString(name);
	if (name[0] == '\0')
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetNameRequired");
		return Plugin_Handled;
	}

	if (DeleteSpawnPreset(mode, name))
	{
		LoadSpawnPresets();
		ReplyToPresetDeleted(client, name);
	}
	else
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetDbUnavailable");
	}

	return Plugin_Handled;
}

Action Cmd_ListSpawnPresets(int client, int args)
{
	if (!EnsurePresetDatabase())
	{
		ReplyToPresetCommand(client, "SpawnVote_PresetDbUnavailable");
		return Plugin_Handled;
	}

	RefreshSpawnVoteConVars();
	SpawnVoteMode mode = DetectSpawnVoteMode();
	if (mode == SpawnVoteMode_None)
	{
		ReplyToPresetCommand(client, "SpawnVote_NoSpawnController");
		return Plugin_Handled;
	}

	LoadSpawnPresets();

	char modeName[64];
	GetPresetModeDisplayName(client, mode, modeName, sizeof(modeName));
	ReplyToPresetListHeader(client, modeName);

	if (mode == SpawnVoteMode_Campaign)
	{
		if (g_iCampaignPresetCount == 0)
		{
			ReplyToPresetCommand(client, "SpawnVote_PresetListEmpty");
			return Plugin_Handled;
		}

		for (int i = 0; i < g_iCampaignPresetCount; i++)
		{
			ReplyToPresetListItem(client, g_sCampaignPresetNames[i]);
		}
	}
	else
	{
		if (g_iAnnePresetCount == 0)
		{
			ReplyToPresetCommand(client, "SpawnVote_PresetListEmpty");
			return Plugin_Handled;
		}

		for (int i = 0; i < g_iAnnePresetCount; i++)
		{
			ReplyToPresetListItem(client, g_sAnnePresetNames[i]);
		}
	}

	return Plugin_Handled;
}

void RefreshSpawnVoteConVars()
{
	g_cvDirCount = FindConVar("dirspawn_count");
	g_cvDirInterval = FindConVar("dirspawn_interval");
	g_cvDirLockTempo = FindConVar("dirspawn_lock_tempo");
	g_cvDirAllowTank = FindConVar("dirspawn_allow_si_with_tank");
	g_cvDirRelaxEnable = FindConVar("dirspawn_relax_enable");
	g_cvAnneLimit = FindConVar("l4d_infected_limit");
	g_cvAnneInterval = FindConVar("versus_special_respawn_interval");
	g_cvAnneAutoSpawn = FindConVar("inf_EnableAutoSpawnTime");
	g_cvAnneDistance = FindConVar("inf_SpawnDistanceMin");
	g_cvAnneTeleportCheck = FindConVar("inf_TeleportCheckTime");
	g_cvAnneTraitorEnable = FindConVar("inf_traitor_enable");
	g_cvVoteCfgFile = FindConVar("votecfgfile");
}

SpawnVoteMode DetectSpawnVoteMode()
{
	if (HasAnneInfectedControlController()
		&& g_cvAnneLimit != null
		&& g_cvAnneInterval != null
		&& g_cvAnneAutoSpawn != null)
	{
		return SpawnVoteMode_Anne;
	}

	if (IsPluginRunningByFile("optional/AnneHappy/l4d2_dirspawn.smx")
		&& g_cvDirCount != null
		&& g_cvDirInterval != null)
	{
		return SpawnVoteMode_Campaign;
	}

	return SpawnVoteMode_None;
}

bool HasAnneInfectedControlController()
{
	return LibraryExists("infected_control")
		|| IsPluginRunningByFile("optional/AnneHappy/infected_control.smx")
		|| IsAnyVersionedInfectedControlRunning();
}

bool IsAnyVersionedInfectedControlRunning()
{
	Handle iter = GetPluginIterator();
	bool found = false;

	while (MorePlugins(iter))
	{
		Handle plugin = ReadPlugin(iter);
		if (plugin == INVALID_HANDLE || GetPluginStatus(plugin) != Plugin_Running)
		{
			continue;
		}

		char filename[PLATFORM_MAX_PATH];
		GetPluginFilename(plugin, filename, sizeof(filename));
		if (StrContains(filename, "optional/AnneHappy/infected_control", false) == 0
			&& StrContains(filename, ".smx", false) != -1)
		{
			found = true;
			break;
		}
	}

	CloseHandle(iter);
	return found;
}

bool TryAuthorizeCvarShieldTarget(const char[] cvarName, int value)
{
	if (GetFeatureStatus(FeatureType_Native, "AnneCvarShield_AuthorizeTarget") != FeatureStatus_Available)
	{
		return false;
	}

	return AnneCvarShield_AuthorizeTarget(cvarName, value);
}

bool DisplayCampaignSpawnVoteMenu(int client)
{
	PrepareCampaignPendingFromCurrent();

	Menu menu = new Menu(SpawnVoteMenuHandler);
	BuildCampaignMenu(menu);
	menu.ExitButton = true;

	bool displayed = menu.Display(client, MENU_TIME);
	if (!displayed)
	{
		delete menu;
	}
	return displayed;
}

bool DisplayAnneSpawnVoteMenu(int client)
{
	PrepareAnnePendingFromCurrent();

	Menu menu = new Menu(SpawnVoteMenuHandler);
	BuildAnneMenu(menu);
	menu.ExitButton = true;

	bool displayed = menu.Display(client, MENU_TIME);
	if (!displayed)
	{
		delete menu;
	}
	return displayed;
}

bool IsPluginRunningByFile(const char[] filename)
{
	Handle plugin = FindPluginByFile(filename);
	return plugin != INVALID_HANDLE && GetPluginStatus(plugin) == Plugin_Running;
}

void BuildCampaignMenu(Menu menu)
{
	menu.SetTitle("刷特设置\n选择投票选项:");
	AddCampaignCfgVoteEntries(menu);
}

void BuildAnneMenu(Menu menu)
{
	menu.SetTitle("刷特设置\n选择特感数量:");
	AddAnneLimitVoteEntries(menu);
}

public int SpawnVoteMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}

	if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_Exit && IsValidPlayer(client))
		{
			CPrintToChat(client, "%t", "SpawnVote_MenuClosed");
		}
		return 0;
	}

	if (action != MenuAction_Select)
	{
		return 0;
	}

	char info[SPAWN_VOTE_MENU_INFO_LENGTH];
	char display[SPAWN_VOTE_MENU_INFO_LENGTH];
	int style;
	menu.GetItem(item, info, sizeof(info), style, display, sizeof(display));

	if (IsCampaignMenuInfo(info))
	{
		HandleCampaignSelect(client, info, display);
	}
	else if (IsAnneMenuInfo(info))
	{
		HandleAnneSelect(client, info, display);
	}

	return 0;
}

bool IsCampaignMenuInfo(const char[] info)
{
	return info[0] == 'c';
}

bool IsAnneMenuInfo(const char[] info)
{
	return info[0] == 'a';
}

void HandleCampaignSelect(int client, const char[] info, const char[] display)
{
	if (StrContains(info, "cvc:", false) == 0)
	{
		if (!StartConfigApplyVote(client, SpawnVoteMode_Campaign, info[4], display))
		{
			DisplayCampaignSpawnVoteMenu(client);
		}
		return;
	}
}

void HandleAnneSelect(int client, const char[] info, const char[] display)
{
	if (StrContains(info, "avc:", false) == 0)
	{
		if (!StartConfigApplyVote(client, SpawnVoteMode_Anne, info[4], display))
		{
			DisplayAnneSpawnVoteMenu(client);
		}
		return;
	}
}

bool StartConfigApplyVote(int client, SpawnVoteMode mode, const char[] command, const char[] message)
{
	ResetPendingSpawnSettings();
	g_bPendingConfigCommand = true;
	strcopy(g_sPendingExecCommand, sizeof(g_sPendingExecCommand), command);
	strcopy(g_sPendingChangeSummary, sizeof(g_sPendingChangeSummary), message);

	bool started = StartApplyVote(client, mode);
	if (!started)
	{
		ResetPendingSpawnSettings();
	}

	return started;
}

void ResetPendingSpawnSettings()
{
	g_iPendingMode = SpawnVoteMode_None;
	g_iPendingLimit = SPAWN_MENU_UNSET;
	g_iPendingInterval = SPAWN_MENU_UNSET;
	g_iPendingAutoMode = SPAWN_MENU_UNSET;
	g_iPendingDistance = SPAWN_MENU_UNSET;
	g_iPendingTeleportCheck = SPAWN_MENU_UNSET;
	g_iPendingTraitorEnable = SPAWN_MENU_UNSET;
	g_iPendingAssault = SPAWN_MENU_UNSET;
	g_iPendingTankTogether = SPAWN_MENU_UNSET;
	g_iPendingRelax = SPAWN_MENU_UNSET;
	g_bPendingPreset = false;
	g_bPendingConfigCommand = false;
	g_sPendingPresetName[0] = '\0';
	g_sPendingExecCommand[0] = '\0';
	g_sPendingChangeSummary[0] = '\0';
}

void PrepareCampaignPendingFromCurrent()
{
	RefreshSpawnVoteConVars();
	if (g_iPendingLimit == SPAWN_MENU_UNSET && g_cvDirCount != null)
	{
		g_iPendingLimit = g_cvDirCount.IntValue;
	}
	if (g_iPendingInterval == SPAWN_MENU_UNSET && g_cvDirInterval != null)
	{
		g_iPendingInterval = g_cvDirInterval.IntValue;
	}
	if (g_iPendingAssault == SPAWN_MENU_UNSET && g_cvDirLockTempo != null)
	{
		g_iPendingAssault = g_cvDirLockTempo.IntValue;
	}
	if (g_iPendingTankTogether == SPAWN_MENU_UNSET && g_cvDirAllowTank != null)
	{
		g_iPendingTankTogether = g_cvDirAllowTank.IntValue;
	}
	if (g_iPendingRelax == SPAWN_MENU_UNSET && g_cvDirRelaxEnable != null)
	{
		g_iPendingRelax = g_cvDirRelaxEnable.IntValue;
	}
}

void PrepareAnnePendingFromCurrent()
{
	RefreshSpawnVoteConVars();
	if (g_iPendingLimit == SPAWN_MENU_UNSET && g_cvAnneLimit != null)
	{
		g_iPendingLimit = g_cvAnneLimit.IntValue;
	}
	if (g_iPendingInterval == SPAWN_MENU_UNSET && g_cvAnneInterval != null)
	{
		g_iPendingInterval = g_cvAnneInterval.IntValue;
	}
	if (g_iPendingAutoMode == SPAWN_MENU_UNSET && g_cvAnneAutoSpawn != null)
	{
		g_iPendingAutoMode = g_cvAnneAutoSpawn.IntValue;
	}
	if (g_iPendingDistance == SPAWN_MENU_UNSET && g_cvAnneDistance != null)
	{
		g_iPendingDistance = g_cvAnneDistance.IntValue;
	}
	if (g_iPendingTeleportCheck == SPAWN_MENU_UNSET && g_cvAnneTeleportCheck != null)
	{
		g_iPendingTeleportCheck = g_cvAnneTeleportCheck.IntValue;
	}
	if (g_iPendingTraitorEnable == SPAWN_MENU_UNSET)
	{
		g_iPendingTraitorEnable = GetConVarIntOrDefault(g_cvAnneTraitorEnable, 1);
	}
}

bool StartApplyVote(int client, SpawnVoteMode mode)
{
	if (IsBuiltinVoteInProgress())
	{
		CPrintToChat(client, "%t", "SpawnVote_AlreadyVoteProgress");
		return false;
	}

	g_iPendingMode = mode;
	g_iLastRequester = GetClientUserId(client);

	char title[128];
	FormatVoteTitle(title, sizeof(title), mode);

	g_hVote = CreateBuiltinVote(VoteActionHandler, BuiltinVoteType_Custom_YesNo, BuiltinVoteAction_Cancel | BuiltinVoteAction_VoteEnd | BuiltinVoteAction_End);
	SetBuiltinVoteArgument(g_hVote, title);
	SetBuiltinVoteInitiator(g_hVote, client);
	SetBuiltinVoteResultCallback(g_hVote, VoteResultHandler);
	DisplayBuiltinVoteToAllNonSpectators(g_hVote, VOTE_TIME);
	FakeClientCommand(client, "Vote Yes");
	CPrintToChatAll("%t", "SpawnVote_InitiatedVote", client);
	return true;
}

void FormatVoteTitle(char[] buffer, int maxlen, SpawnVoteMode mode)
{
	if (g_bPendingConfigCommand)
	{
		FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_PresetVoteTitle", g_sPendingChangeSummary);
		return;
	}

	if (g_bPendingPreset)
	{
		if (mode == SpawnVoteMode_Campaign)
		{
			char relax[32];
			FormatNativeVoteOnOffState(relax, sizeof(relax), g_iPendingRelax);
			FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_PresetVoteTitleRelax", g_sPendingPresetName, relax);
			return;
		}

		FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_PresetVoteTitle", g_sPendingPresetName);
		return;
	}

	if (g_sPendingChangeSummary[0] != '\0')
	{
		FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_ChangeVoteTitle", g_sPendingChangeSummary);
		return;
	}

	if (mode == SpawnVoteMode_Campaign)
	{
		char relax[32];
		FormatNativeVoteOnOffState(relax, sizeof(relax), g_iPendingRelax);
		FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_CampaignVoteTitleRelax", g_iPendingLimit, g_iPendingInterval, relax);
	}
	else
	{
		char traitorState[32];
		FormatNativeVoteOnOffState(traitorState, sizeof(traitorState), g_iPendingTraitorEnable);
		FormatNativeVotePhrase(buffer, maxlen, "SpawnVote_AnneVoteTitleTraitor",
			g_iPendingLimit, g_iPendingInterval, traitorState);
	}
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
	for (int i = 0; i < num_items; i++)
	{
		if (item_info[i][BUILTINVOTEINFO_ITEM_INDEX] == BUILTINVOTES_VOTE_YES
			&& item_info[i][BUILTINVOTEINFO_ITEM_VOTES] >= RoundToCeil(float(num_votes) * 0.6))
		{
			char message[64];
			FormatNativeVotePhrase(message, sizeof(message), "SpawnVote_AppliedVoteTitle");
			DisplayBuiltinVotePass(vote, message);
			ApplyPendingSpawnSettings();
			AnnounceAppliedSettings();
			return;
		}
	}

	DisplayBuiltinVoteFail(vote, BuiltinVoteFail_Loses);
}

void ApplyPendingSpawnSettings()
{
	RefreshSpawnVoteConVars();

	if (g_bPendingConfigCommand)
	{
		ServerCommand("%s", g_sPendingExecCommand);
		return;
	}

	if (g_iPendingMode == SpawnVoteMode_Campaign)
	{
		if (g_cvDirCount != null)
		{
			g_cvDirCount.SetInt(g_iPendingLimit);
		}
		if (g_cvDirInterval != null)
		{
			g_cvDirInterval.SetInt(g_iPendingInterval);
		}
		if (g_cvDirLockTempo != null)
		{
			g_cvDirLockTempo.SetInt(g_iPendingAssault);
		}
		if (g_cvDirAllowTank != null)
		{
			g_cvDirAllowTank.SetInt(g_iPendingTankTogether);
		}
		if (g_cvDirRelaxEnable != null)
		{
			ResolvePendingRelaxFromCurrent();
			g_cvDirRelaxEnable.SetInt(g_iPendingRelax);
		}
		ServerCommand("sm_dirspawn_apply");
	}
	else if (g_iPendingMode == SpawnVoteMode_Anne)
	{
		if (g_cvAnneLimit != null)
		{
			TryAuthorizeCvarShieldTarget("l4d_infected_limit", g_iPendingLimit);
			g_cvAnneLimit.SetInt(g_iPendingLimit);
		}
		if (g_cvAnneInterval != null)
		{
			TryAuthorizeCvarShieldTarget("versus_special_respawn_interval", g_iPendingInterval);
			g_cvAnneInterval.SetInt(g_iPendingInterval);
		}
		if (g_cvAnneAutoSpawn != null)
		{
			g_cvAnneAutoSpawn.SetInt(g_iPendingAutoMode);
		}
		if (g_cvAnneDistance != null)
		{
			g_cvAnneDistance.SetInt(g_iPendingDistance);
		}
		if (g_cvAnneTeleportCheck != null)
		{
			g_cvAnneTeleportCheck.SetInt(g_iPendingTeleportCheck);
		}
		if (g_cvAnneTraitorEnable != null && g_iPendingTraitorEnable != SPAWN_MENU_UNSET)
		{
			g_cvAnneTraitorEnable.SetInt(g_iPendingTraitorEnable);
		}
	}
}

void AnnounceAppliedSettings()
{
	int requester = GetClientOfUserId(g_iLastRequester);
	if (requester > 0)
	{
		CPrintToChatAll("%t", "SpawnVote_AppliedByRequester", requester);
	}
	else
	{
		CPrintToChatAll("%t", "SpawnVote_Applied");
	}
}

bool IsValidPlayer(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client);
}

bool IsPlayer(int client)
{
	int team = GetClientTeam(client);
	return team == 2 || team == 3;
}

int GetConVarIntOrDefault(ConVar convar, int fallback)
{
	if (convar == null)
	{
		return fallback;
	}

	return convar.IntValue;
}

void ResolvePendingRelaxFromCurrent()
{
	if (g_iPendingRelax != SPAWN_MENU_UNSET)
	{
		return;
	}

	if (g_cvDirRelaxEnable != null)
	{
		g_iPendingRelax = g_cvDirRelaxEnable.IntValue;
		return;
	}

	g_iPendingRelax = 1;
}

void FormatNativeVoteOnOffState(char[] buffer, int maxlen, int value)
{
	if (value == SPAWN_MENU_UNSET)
	{
		value = 1;
	}

	FormatNativeVotePhrase(buffer, maxlen, value != 0 ? "SpawnVote_RelaxOn" : "SpawnVote_RelaxOff");
}

void FormatNativeVotePhrase(char[] buffer, int maxlen, const char[] phrase, any ...)
{
	char format[256];
	if (!GetNativeVotePhraseTemplate(phrase, format, sizeof(format)))
	{
		strcopy(format, sizeof(format), phrase);
	}

	VFormat(buffer, maxlen, format, 4);
}

bool GetNativeVotePhraseTemplate(const char[] phrase, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	if (g_kvNativeVotePhrases == null)
	{
		LoadNativeVotePhrases();
	}

	if (g_kvNativeVotePhrases == null)
	{
		return false;
	}

	if (!g_kvNativeVotePhrases.JumpToKey(phrase))
	{
		g_kvNativeVotePhrases.Rewind();
		return false;
	}

	g_kvNativeVotePhrases.GetString(NATIVE_VOTE_LANGUAGE_CODE, buffer, maxlen);
	g_kvNativeVotePhrases.Rewind();
	return buffer[0] != '\0';
}

void LoadNativeVotePhrases()
{
	CloseNativeVotePhrases();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "translations/%s/spawn_vote_menu.phrases.txt", NATIVE_VOTE_LANGUAGE_CODE);

	KeyValues phrases = new KeyValues("Phrases");
	if (!phrases.ImportFromFile(path))
	{
		delete phrases;
		LogError("[SpawnVote] failed to load native vote phrases from \"%s\".", path);
		return;
	}

	g_kvNativeVotePhrases = phrases;
}

void CloseNativeVotePhrases()
{
	if (g_kvNativeVotePhrases != null)
	{
		delete g_kvNativeVotePhrases;
		g_kvNativeVotePhrases = null;
	}
}

void AddCampaignCfgVoteEntries(Menu menu)
{
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/campaign_easy.cfg", "普通战役 轻松（8特/35s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/campaign_standard.cfg", "普通战役 标准（8特/30s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/campaign_dense.cfg", "普通战役 稠密（10特/25s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/realism_stable.cfg", "绝境 稳压（10特/20s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/realism_high.cfg", "绝境 高压（12特/10s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/realism_brutal.cfg", "绝境 凶猛（14特/8s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/nonstop_12t0s.cfg", "12特/0s 不停刷");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/nonstop_20t0s.cfg", "20特/0s 不停刷");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/nonstop_28t0s.cfg", "28特/0s 不停刷（经典）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/nonstop_30t0s.cfg", "30特/0s 不停刷（极限）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/harass_light.cfg", "（12特/20s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/harass_mid.cfg", "（14特/25s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/harass_wavey.cfg", " （16特/30s）");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/native_campaign.cfg", "原生战役");
	AddCfgVoteEntry(menu, "cvc", "exec sourcemod/dirspawn_presets/native_realism.cfg", "原生绝境");
}

void AddAnneLimitVoteEntries(Menu menu)
{
	char folder[16];
	GetAnneLimitVoteFolder(folder, sizeof(folder));

	for (int limit = ANNE_LIMIT_MIN; limit <= ANNE_LIMIT_MAX; limit++)
	{
		char command[SPAWN_VOTE_COMMAND_LENGTH];
		char text[32];
		FormatEx(command, sizeof(command), "exec vote/%s/AnneHappy%d.cfg", folder, limit);
		FormatEx(text, sizeof(text), "%d特", limit);
		AddCfgVoteEntry(menu, "avc", command, text);
	}
}

void AddCfgVoteEntry(Menu menu, const char[] prefix, const char[] command, const char[] message)
{
	char info[SPAWN_VOTE_MENU_INFO_LENGTH];
	FormatEx(info, sizeof(info), "%s:%s", prefix, command);
	menu.AddItem(info, message);
}

void GetAnneLimitVoteFolder(char[] folder, int maxlen)
{
	char voteFile[128];
	GetCurrentVoteConfigFile(voteFile, sizeof(voteFile));

	if (StrContains(voteFile, "shotgun", false) != -1)
	{
		strcopy(folder, maxlen, "hardcore");
		return;
	}

	strcopy(folder, maxlen, StrContains(voteFile, "hardcore", false) != -1 ? "hardcore" : "normal");
}

void GetCurrentVoteConfigFile(char[] voteFile, int maxlen)
{
	voteFile[0] = '\0';
	if (g_cvVoteCfgFile == null)
	{
		g_cvVoteCfgFile = FindConVar("votecfgfile");
	}

	if (g_cvVoteCfgFile != null)
	{
		g_cvVoteCfgFile.GetString(voteFile, maxlen);
	}
}

bool EnsurePresetDatabase()
{
	if (g_hPresetDb == null)
	{
		ConnectPresetDatabase();
	}
	else if (!g_bPresetSchemaReady)
	{
		CreatePresetTable();
	}

	return g_hPresetDb != null && g_bPresetSchemaReady;
}

void ConnectPresetDatabase()
{
	if (g_hPresetDb != null)
	{
		return;
	}

	char configName[PRESET_TABLE_LENGTH];
	g_cvPresetDbConfig.GetString(configName, sizeof(configName));
	TrimString(configName);
	if (configName[0] == '\0')
	{
		strcopy(configName, sizeof(configName), "storage-local");
	}

	char error[256];
	if (!SQL_CheckConfig(configName))
	{
		LogError("[SpawnVote] preset database config \"%s\" is missing.", configName);
		return;
	}

	g_hPresetDb = SQL_Connect(configName, false, error, sizeof(error));
	if (g_hPresetDb == null)
	{
		LogError("[SpawnVote] failed to connect preset database \"%s\": %s", configName, error);
		return;
	}

	ReadPresetDatabaseDriver();
	if (g_bPresetDbIsMySQL)
	{
		SQL_SetCharset(g_hPresetDb, "utf8mb4");
	}
	CreatePresetTable();
	LoadSpawnPresets();
}

void ReadPresetDatabaseDriver()
{
	char ident[16];
	SQL_ReadDriver(g_hPresetDb, ident, sizeof(ident));
	g_bPresetDbIsMySQL = StrEqual(ident, "mysql", false);
}

void ClosePresetDatabase()
{
	if (g_hPresetDb != null)
	{
		delete g_hPresetDb;
		g_hPresetDb = null;
	}

	g_bPresetSchemaReady = false;
	g_bPresetDbIsMySQL = false;
}

void CreatePresetTable()
{
	g_bPresetSchemaReady = false;

	if (g_hPresetDb == null)
	{
		return;
	}

	char table[PRESET_TABLE_LENGTH];
	if (!GetPresetTableName(table, sizeof(table)))
	{
		return;
	}

	char query[2048];
	if (g_bPresetDbIsMySQL)
	{
		FormatEx(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS `%s` ("
			... "`mode` varchar(16) NOT NULL,"
			... "`name` varchar(64) NOT NULL,"
			... "`limit_value` int NOT NULL DEFAULT 0,"
			... "`interval_value` int NOT NULL DEFAULT 0,"
			... "`auto_mode` int NOT NULL DEFAULT -1,"
			... "`distance` int NOT NULL DEFAULT -1,"
			... "`teleport_check` int NOT NULL DEFAULT -1,"
			... "`assault` int NOT NULL DEFAULT -1,"
			... "`tank_together` int NOT NULL DEFAULT -1,"
			... "`created_by` varchar(64) NOT NULL DEFAULT '',"
			... "`created_at` int NOT NULL DEFAULT 0,"
			... "`updated_at` int NOT NULL DEFAULT 0,"
			... "PRIMARY KEY (`mode`, `name`)"
			... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
			table);
	}
	else
	{
		FormatEx(query, sizeof(query),
			"CREATE TABLE IF NOT EXISTS `%s` ("
			... "`mode` TEXT NOT NULL,"
			... "`name` TEXT NOT NULL,"
			... "`limit_value` INTEGER NOT NULL DEFAULT 0,"
			... "`interval_value` INTEGER NOT NULL DEFAULT 0,"
			... "`auto_mode` INTEGER NOT NULL DEFAULT -1,"
			... "`distance` INTEGER NOT NULL DEFAULT -1,"
			... "`teleport_check` INTEGER NOT NULL DEFAULT -1,"
			... "`assault` INTEGER NOT NULL DEFAULT -1,"
			... "`tank_together` INTEGER NOT NULL DEFAULT -1,"
			... "`created_by` TEXT NOT NULL DEFAULT '',"
			... "`created_at` INTEGER NOT NULL DEFAULT 0,"
			... "`updated_at` INTEGER NOT NULL DEFAULT 0,"
			... "PRIMARY KEY (`mode`, `name`)"
			... ")",
			table);
	}

	if (!SQL_FastQuery(g_hPresetDb, query))
	{
		char error[256];
		SQL_GetError(g_hPresetDb, error, sizeof(error));
		LogError("[SpawnVote] failed to create preset table: %s", error);
		return;
	}

	g_bPresetSchemaReady = true;
}

void LoadSpawnPresets()
{
	ClearSpawnPresets();

	if (g_hPresetDb == null || !g_bPresetSchemaReady)
	{
		return;
	}

	char table[PRESET_TABLE_LENGTH];
	if (!GetPresetTableName(table, sizeof(table)))
	{
		return;
	}

	char query[512];
	FormatEx(query, sizeof(query),
		"SELECT `mode`, `name`, `limit_value`, `interval_value`, `auto_mode`, `distance`, `teleport_check`, `assault`, `tank_together` FROM `%s` ORDER BY `mode`, `name`",
		table);

	DBResultSet results = SQL_Query(g_hPresetDb, query);
	if (results == null)
	{
		char error[256];
		SQL_GetError(g_hPresetDb, error, sizeof(error));
		LogError("[SpawnVote] failed to load presets: %s", error);
		return;
	}

	while (results.FetchRow())
	{
		char mode[PRESET_MODE_LENGTH];
		char name[SPAWN_PRESET_NAME_LENGTH];
		results.FetchString(0, mode, sizeof(mode));
		results.FetchString(1, name, sizeof(name));

		if (StrEqual(mode, "campaign", false))
		{
			if (g_iCampaignPresetCount >= MAX_SPAWN_PRESETS)
			{
				continue;
			}

			int index = g_iCampaignPresetCount++;
			strcopy(g_sCampaignPresetNames[index], sizeof(g_sCampaignPresetNames[]), name);
			g_iCampaignPresetLimit[index] = results.FetchInt(2);
			g_iCampaignPresetInterval[index] = results.FetchInt(3);
			g_iCampaignPresetAssault[index] = results.FetchInt(7);
			g_iCampaignPresetTankTogether[index] = results.FetchInt(8);
			g_iCampaignPresetRelax[index] = SPAWN_MENU_UNSET;
		}
		else if (StrEqual(mode, "anne", false))
		{
			if (g_iAnnePresetCount >= MAX_SPAWN_PRESETS)
			{
				continue;
			}

			int index = g_iAnnePresetCount++;
			strcopy(g_sAnnePresetNames[index], sizeof(g_sAnnePresetNames[]), name);
			g_iAnnePresetLimit[index] = results.FetchInt(2);
			g_iAnnePresetInterval[index] = results.FetchInt(3);
			g_iAnnePresetAutoMode[index] = results.FetchInt(4);
			g_iAnnePresetDistance[index] = results.FetchInt(5);
			g_iAnnePresetTeleportCheck[index] = results.FetchInt(6);
		}
	}

	delete results;
}

void ClearSpawnPresets()
{
	g_iCampaignPresetCount = 0;
	g_iAnnePresetCount = 0;
}

bool SaveCurrentSpawnPreset(int client, SpawnVoteMode mode, const char[] name)
{
	if (g_hPresetDb == null || !g_bPresetSchemaReady)
	{
		return false;
	}

	char table[PRESET_TABLE_LENGTH];
	if (!GetPresetTableName(table, sizeof(table)))
	{
		return false;
	}

	char modeName[PRESET_MODE_LENGTH];
	GetPresetModeName(mode, modeName, sizeof(modeName));

	char author[PRESET_AUTHOR_LENGTH];
	GetPresetAuthor(client, author, sizeof(author));

	char escMode[PRESET_MODE_LENGTH * 2 + 1];
	char escName[SPAWN_PRESET_NAME_LENGTH * 2 + 1];
	char escAuthor[PRESET_AUTHOR_LENGTH * 2 + 1];
	if (!SQL_EscapeString(g_hPresetDb, modeName, escMode, sizeof(escMode))
		|| !SQL_EscapeString(g_hPresetDb, name, escName, sizeof(escName))
		|| !SQL_EscapeString(g_hPresetDb, author, escAuthor, sizeof(escAuthor)))
	{
		return false;
	}

	int now = GetTime();
	if (g_bPresetDbIsMySQL)
	{
		return SaveCurrentSpawnPresetMySQL(name, table, escMode, escName, escAuthor, mode, now);
	}

	return SaveCurrentSpawnPresetSQLite(name, table, escMode, escName, escAuthor, mode, now);
}

bool SaveCurrentSpawnPresetMySQL(const char[] name, const char[] table, const char[] escMode, const char[] escName, const char[] escAuthor, SpawnVoteMode mode, int now)
{
	char query[2048];
	FormatEx(query, sizeof(query),
		"INSERT INTO `%s` (`mode`, `name`, `limit_value`, `interval_value`, `auto_mode`, `distance`, `teleport_check`, `assault`, `tank_together`, `created_by`, `created_at`, `updated_at`) "
		... "VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, '%s', %d, %d) "
		... "ON DUPLICATE KEY UPDATE "
		... "`limit_value` = VALUES(`limit_value`), "
		... "`interval_value` = VALUES(`interval_value`), "
		... "`auto_mode` = VALUES(`auto_mode`), "
		... "`distance` = VALUES(`distance`), "
		... "`teleport_check` = VALUES(`teleport_check`), "
		... "`assault` = VALUES(`assault`), "
		... "`tank_together` = VALUES(`tank_together`), "
		... "`created_by` = VALUES(`created_by`), "
		... "`updated_at` = VALUES(`updated_at`)",
		table,
		escMode,
		escName,
		g_iPendingLimit,
		g_iPendingInterval,
		mode == SpawnVoteMode_Anne ? g_iPendingAutoMode : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingDistance : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingTeleportCheck : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingAssault : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingTankTogether : -1,
		escAuthor,
		now,
		now);

	if (!SQL_FastQuery(g_hPresetDb, query))
	{
		LogPresetSaveError(name);
		return false;
	}

	return true;
}

bool SaveCurrentSpawnPresetSQLite(const char[] name, const char[] table, const char[] escMode, const char[] escName, const char[] escAuthor, SpawnVoteMode mode, int now)
{
	char query[2048];
	FormatEx(query, sizeof(query),
		"INSERT OR IGNORE INTO `%s` (`mode`, `name`, `limit_value`, `interval_value`, `auto_mode`, `distance`, `teleport_check`, `assault`, `tank_together`, `created_by`, `created_at`, `updated_at`) "
		... "VALUES ('%s', '%s', %d, %d, %d, %d, %d, %d, %d, '%s', %d, %d)",
		table,
		escMode,
		escName,
		g_iPendingLimit,
		g_iPendingInterval,
		mode == SpawnVoteMode_Anne ? g_iPendingAutoMode : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingDistance : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingTeleportCheck : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingAssault : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingTankTogether : -1,
		escAuthor,
		now,
		now);

	if (!SQL_FastQuery(g_hPresetDb, query))
	{
		LogPresetSaveError(name);
		return false;
	}

	FormatEx(query, sizeof(query),
		"UPDATE `%s` SET "
		... "`limit_value` = %d, "
		... "`interval_value` = %d, "
		... "`auto_mode` = %d, "
		... "`distance` = %d, "
		... "`teleport_check` = %d, "
		... "`assault` = %d, "
		... "`tank_together` = %d, "
		... "`created_by` = '%s', "
		... "`updated_at` = %d WHERE `mode` = '%s' AND `name` = '%s'",
		table,
		g_iPendingLimit,
		g_iPendingInterval,
		mode == SpawnVoteMode_Anne ? g_iPendingAutoMode : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingDistance : -1,
		mode == SpawnVoteMode_Anne ? g_iPendingTeleportCheck : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingAssault : -1,
		mode == SpawnVoteMode_Campaign ? g_iPendingTankTogether : -1,
		escAuthor,
		now,
		escMode,
		escName);

	if (!SQL_FastQuery(g_hPresetDb, query))
	{
		LogPresetSaveError(name);
		return false;
	}

	return true;
}

void LogPresetSaveError(const char[] name)
{
	char error[256];
	SQL_GetError(g_hPresetDb, error, sizeof(error));
	LogError("[SpawnVote] failed to save preset \"%s\": %s", name, error);
}

bool DeleteSpawnPreset(SpawnVoteMode mode, const char[] name)
{
	if (g_hPresetDb == null || !g_bPresetSchemaReady)
	{
		return false;
	}

	char table[PRESET_TABLE_LENGTH];
	if (!GetPresetTableName(table, sizeof(table)))
	{
		return false;
	}

	char modeName[PRESET_MODE_LENGTH];
	GetPresetModeName(mode, modeName, sizeof(modeName));

	char escMode[PRESET_MODE_LENGTH * 2 + 1];
	char escName[SPAWN_PRESET_NAME_LENGTH * 2 + 1];
	if (!SQL_EscapeString(g_hPresetDb, modeName, escMode, sizeof(escMode))
		|| !SQL_EscapeString(g_hPresetDb, name, escName, sizeof(escName)))
	{
		return false;
	}

	char query[512];
	FormatEx(query, sizeof(query),
		"DELETE FROM `%s` WHERE `mode` = '%s' AND `name` = '%s'",
		table,
		escMode,
		escName);

	if (!SQL_FastQuery(g_hPresetDb, query))
	{
		char error[256];
		SQL_GetError(g_hPresetDb, error, sizeof(error));
		LogError("[SpawnVote] failed to delete preset \"%s\": %s", name, error);
		return false;
	}

	return true;
}

bool GetPresetTableName(char[] table, int maxlen)
{
	g_cvPresetTable.GetString(table, maxlen);
	TrimString(table);
	if (table[0] == '\0')
	{
		strcopy(table, maxlen, "spawn_vote_presets");
	}

	if (!IsSafeSqlIdentifier(table))
	{
		LogError("[SpawnVote] unsafe preset table name \"%s\".", table);
		return false;
	}

	return true;
}

bool IsSafeSqlIdentifier(const char[] name)
{
	int length = strlen(name);
	if (length < 1)
	{
		return false;
	}

	for (int i = 0; i < length; i++)
	{
		int c = name[i];
		if (!((c >= 'a' && c <= 'z')
			|| (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9')
			|| c == '_'))
		{
			return false;
		}
	}

	return true;
}

void GetPresetModeName(SpawnVoteMode mode, char[] buffer, int maxlen)
{
	if (mode == SpawnVoteMode_Campaign)
	{
		strcopy(buffer, maxlen, "campaign");
	}
	else if (mode == SpawnVoteMode_Anne)
	{
		strcopy(buffer, maxlen, "anne");
	}
	else
	{
		strcopy(buffer, maxlen, "none");
	}
}

void GetPresetModeDisplayName(int client, SpawnVoteMode mode, char[] buffer, int maxlen)
{
	int target = LANG_SERVER;
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		target = client;
	}

	if (mode == SpawnVoteMode_Campaign)
	{
		Format(buffer, maxlen, "%T", "SpawnVote_ModeCampaign", target);
	}
	else if (mode == SpawnVoteMode_Anne)
	{
		Format(buffer, maxlen, "%T", "SpawnVote_ModeAnne", target);
	}
	else
	{
		Format(buffer, maxlen, "%T", "SpawnVote_ModeUnknown", target);
	}
}

void GetPresetAuthor(int client, char[] buffer, int maxlen)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		if (GetClientAuthId(client, AuthId_Steam2, buffer, maxlen, true))
		{
			return;
		}

		GetClientName(client, buffer, maxlen);
		return;
	}

	strcopy(buffer, maxlen, "console");
}

void ReplyToPresetCommand(int client, const char[] phrase)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CPrintToChat(client, "%t", phrase);
	}
	else
	{
		ReplyToCommand(client, "%t", phrase);
	}
}

void ReplyToPresetSaved(int client, const char[] name)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CPrintToChat(client, "%t", "SpawnVote_PresetSaved", name);
	}
	else
	{
		ReplyToCommand(client, "%t", "SpawnVote_PresetSaved", name);
	}
}

void ReplyToPresetDeleted(int client, const char[] name)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CPrintToChat(client, "%t", "SpawnVote_PresetDeleted", name);
	}
	else
	{
		ReplyToCommand(client, "%t", "SpawnVote_PresetDeleted", name);
	}
}

void ReplyToPresetListHeader(int client, const char[] modeName)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CPrintToChat(client, "%t", "SpawnVote_PresetListHeader", modeName);
	}
	else
	{
		ReplyToCommand(client, "%t", "SpawnVote_PresetListHeader", modeName);
	}
}

void ReplyToPresetListItem(int client, const char[] name)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		CPrintToChat(client, "%t", "SpawnVote_PresetListItem", name);
	}
	else
	{
		ReplyToCommand(client, "%t", "SpawnVote_PresetListItem", name);
	}
}
