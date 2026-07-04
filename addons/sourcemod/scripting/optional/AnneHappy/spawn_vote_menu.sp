#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dbi>
#include <builtinvotes>
#include <builtinvotes_stocks>
#include <colors>
#undef REQUIRE_PLUGIN
#include <extra_menu>

#define PLUGIN_VERSION "1.0.1"
#define VOTE_TIME 20
#define MENU_TIME MENU_TIME_FOREVER
#define SPAWN_MENU_UNSET -999999
#define MAX_SPAWN_PRESETS 16
#define SPAWN_PRESET_NAME_LENGTH 64
#define PRESET_TABLE_LENGTH 64
#define PRESET_MODE_LENGTH 16
#define PRESET_AUTHOR_LENGTH 64
#define CAMPAIGN_PRESET_OPTION_FIRST 7
#define ANNE_PRESET_OPTION_FIRST 7

enum SpawnVoteMode
{
	SpawnVoteMode_None = 0,
	SpawnVoteMode_Campaign,
	SpawnVoteMode_Anne
}

enum
{
	CAMPAIGN_OPTION_STATUS = 0,
	CAMPAIGN_OPTION_LIMIT,
	CAMPAIGN_OPTION_INTERVAL,
	CAMPAIGN_OPTION_ASSAULT,
	CAMPAIGN_OPTION_TANK_TOGETHER,
	CAMPAIGN_OPTION_RELAX,
	CAMPAIGN_OPTION_APPLY
}

enum
{
	ANNE_OPTION_STATUS = 0,
	ANNE_OPTION_LIMIT,
	ANNE_OPTION_INTERVAL,
	ANNE_OPTION_AUTO_MODE,
	ANNE_OPTION_DISTANCE,
	ANNE_OPTION_TELEPORT_CHECK,
	ANNE_OPTION_APPLY
}

public Plugin myinfo =
{
	name = "Anne Spawn Vote Menu",
	author = "morzlee",
	description = "ExtraMenu based spawn tuning vote menu for Anne and campaign modes.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

int g_iCampaignMenu = -1;
int g_iAnneMenu = -1;
Handle g_hVote = INVALID_HANDLE;

SpawnVoteMode g_iPendingMode = SpawnVoteMode_None;
int g_iPendingLimit;
int g_iPendingInterval;
int g_iPendingAutoMode;
int g_iPendingDistance;
int g_iPendingTeleportCheck;
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
char g_sPendingPresetName[SPAWN_PRESET_NAME_LENGTH];

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("vote.phrases");
	LoadTranslations("spawn_vote_menu.phrases");

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
	CreateMenusIfReady();
}

public void OnAllPluginsLoaded()
{
	RefreshSpawnVoteConVars();
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "extra_menu"))
	{
		CreateMenusIfReady();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "extra_menu"))
	{
		DeleteSpawnVoteMenus();
	}
}

public void OnPluginEnd()
{
	DeleteSpawnVoteMenus();
	ClosePresetDatabase();
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
	if (EnsurePresetDatabase())
	{
		LoadSpawnPresets();
	}
	RebuildSpawnVoteMenus();

	switch (mode)
	{
		case SpawnVoteMode_Campaign:
		{
			if (!DisplayCampaignSpawnVoteMenu(client))
			{
				CPrintToChat(client, "%t", "SpawnVote_MenuBackendUnavailable");
			}
		}
		case SpawnVoteMode_Anne:
		{
			if (!DisplayAnneSpawnVoteMenu(client))
			{
				CPrintToChat(client, "%t", "SpawnVote_MenuBackendUnavailable");
			}
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
		RebuildSpawnVoteMenus();
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
		RebuildSpawnVoteMenus();
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
}

SpawnVoteMode DetectSpawnVoteMode()
{
	if (IsPluginRunningByFile("optional/AnneHappy/infected_control.smx")
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

void CreateMenusIfReady()
{
	RefreshSpawnVoteConVars();

	if (!CanBuildExtraMenus())
	{
		return;
	}

	if (g_iCampaignMenu == -1)
	{
		g_iCampaignMenu = ExtraMenu_Create(false, "", false);
		BuildCampaignMenu(g_iCampaignMenu);
	}

	if (g_iAnneMenu == -1)
	{
		g_iAnneMenu = ExtraMenu_Create(false, "", false);
		BuildAnneMenu(g_iAnneMenu);
	}
}

void RebuildSpawnVoteMenus()
{
	DeleteSpawnVoteMenus();
	CreateMenusIfReady();
}

void DeleteSpawnVoteMenus()
{
	if (GetFeatureStatus(FeatureType_Native, "ExtraMenu_Delete") != FeatureStatus_Available)
	{
		g_iCampaignMenu = -1;
		g_iAnneMenu = -1;
		return;
	}

	if (g_iCampaignMenu != -1)
	{
		ExtraMenu_Delete(g_iCampaignMenu);
		g_iCampaignMenu = -1;
	}

	if (g_iAnneMenu != -1)
	{
		ExtraMenu_Delete(g_iAnneMenu);
		g_iAnneMenu = -1;
	}
}

bool CanBuildExtraMenus()
{
	return GetFeatureStatus(FeatureType_Native, "ExtraMenu_Create") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "ExtraMenu_AddEntry") == FeatureStatus_Available
		&& GetFeatureStatus(FeatureType_Native, "ExtraMenu_AddOptions") == FeatureStatus_Available;
}

bool CanDisplayExtraMenus()
{
	return GetFeatureStatus(FeatureType_Native, "ExtraMenu_Display") == FeatureStatus_Available;
}

bool DisplayCampaignSpawnVoteMenu(int client)
{
	if (g_iCampaignMenu == -1)
	{
		CreateMenusIfReady();
	}

	if (g_iCampaignMenu == -1 || !CanDisplayExtraMenus())
	{
		return false;
	}

	return ExtraMenu_Display(client, g_iCampaignMenu, MENU_TIME);
}

bool DisplayAnneSpawnVoteMenu(int client)
{
	if (g_iAnneMenu == -1)
	{
		CreateMenusIfReady();
	}

	if (g_iAnneMenu == -1 || !CanDisplayExtraMenus())
	{
		return false;
	}

	return ExtraMenu_Display(client, g_iAnneMenu, MENU_TIME);
}

bool IsPluginRunningByFile(const char[] filename)
{
	Handle plugin = FindPluginByFile(filename);
	return plugin != INVALID_HANDLE && GetPluginStatus(plugin) == Plugin_Running;
}

void BuildCampaignMenu(int menu)
{
	ExtraMenu_AddEntry(menu, "洛琪导航控制菜单:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "W/S移动、A/D控制", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "通用选项:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "1. 插件状态: 战役模式", MENU_SELECT_ONLY);
	ExtraMenu_AddEntry(menu, "2. 特感上限: [_OPT_]特", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvDirCount, 8), 1, 1, 30);
	ExtraMenu_AddEntry(menu, "3. 刷新时间: [_OPT_]秒", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvDirInterval, 30), 1, 0, 120);
	ExtraMenu_AddEntry(menu, "4. 特感强攻: _OPT_", MENU_SELECT_ONOFF, false, GetConVarIntOrDefault(g_cvDirLockTempo, 0));
	ExtraMenu_AddEntry(menu, "5. 坦克同刷: _OPT_", MENU_SELECT_ONOFF, false, GetConVarIntOrDefault(g_cvDirAllowTank, 1));
	ExtraMenu_AddEntry(menu, "6. Relax阶段: _OPT_", MENU_SELECT_ONOFF, false, GetConVarIntOrDefault(g_cvDirRelaxEnable, 1));
	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "应用:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "1. 应用当前设置", MENU_SELECT_ONLY, true);
	AddCampaignPresetEntries(menu);
}

void BuildAnneMenu(int menu)
{
	ExtraMenu_AddEntry(menu, "洛琪导航控制菜单:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "W/S移动、A/D控制", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "通用选项:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "1. 插件状态: Anne模式", MENU_SELECT_ONLY);
	ExtraMenu_AddEntry(menu, "2. 特感上限: [_OPT_]特", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvAnneLimit, 4), 1, 1, 30);
	ExtraMenu_AddEntry(menu, "3. 刷新时间: [_OPT_]秒", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvAnneInterval, 16), 1, 0, 120);
	ExtraMenu_AddEntry(menu, "4. 刷特模式: _OPT_", MENU_SELECT_LIST, false, GetConVarIntOrDefault(g_cvAnneAutoSpawn, 1) == 1 ? 0 : 1);
	ExtraMenu_AddOptions(menu, "自动时间|固定时间");
	ExtraMenu_AddEntry(menu, "5. 刷特距离: [_OPT_]码", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvAnneDistance, 250), 50, 0, 1500);
	ExtraMenu_AddEntry(menu, "6. 传送检测: [_OPT_]秒", MENU_SELECT_ADD, false, GetConVarIntOrDefault(g_cvAnneTeleportCheck, 5), 1, 0, 30);
	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "应用:", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "1. 应用当前设置", MENU_SELECT_ONLY, true);
	AddAnnePresetEntries(menu);
}

public void ExtraMenu_OnSelect(int client, int menu_id, int option, int value)
{
	if (menu_id == g_iCampaignMenu)
	{
		HandleCampaignSelect(client, option, value);
	}
	else if (menu_id == g_iAnneMenu)
	{
		HandleAnneSelect(client, option, value);
	}
}

void HandleCampaignSelect(int client, int option, int value)
{
	if (option >= CAMPAIGN_PRESET_OPTION_FIRST && option < CAMPAIGN_PRESET_OPTION_FIRST + g_iCampaignPresetCount)
	{
		StartPresetApplyVote(client, SpawnVoteMode_Campaign, option - CAMPAIGN_PRESET_OPTION_FIRST);
		return;
	}

	switch (option)
	{
		case CAMPAIGN_OPTION_STATUS:
		{
			CPrintToChat(client, "%t", "SpawnVote_CampaignStatus");
		}
		case CAMPAIGN_OPTION_LIMIT:
		{
			g_iPendingLimit = value;
		}
		case CAMPAIGN_OPTION_INTERVAL:
		{
			g_iPendingInterval = value;
		}
		case CAMPAIGN_OPTION_ASSAULT:
		{
			g_iPendingAssault = value;
		}
		case CAMPAIGN_OPTION_TANK_TOGETHER:
		{
			g_iPendingTankTogether = value;
		}
		case CAMPAIGN_OPTION_RELAX:
		{
			g_iPendingRelax = value;
		}
		case CAMPAIGN_OPTION_APPLY:
		{
			g_bPendingPreset = false;
			g_sPendingPresetName[0] = '\0';
			PrepareCampaignPendingFromCurrent();
			StartApplyVote(client, SpawnVoteMode_Campaign);
		}
		case -1:
		{
			CPrintToChat(client, "%t", "SpawnVote_MenuClosed");
		}
	}
}

void HandleAnneSelect(int client, int option, int value)
{
	if (option >= ANNE_PRESET_OPTION_FIRST && option < ANNE_PRESET_OPTION_FIRST + g_iAnnePresetCount)
	{
		StartPresetApplyVote(client, SpawnVoteMode_Anne, option - ANNE_PRESET_OPTION_FIRST);
		return;
	}

	switch (option)
	{
		case ANNE_OPTION_STATUS:
		{
			CPrintToChat(client, "%t", "SpawnVote_AnneStatus");
		}
		case ANNE_OPTION_LIMIT:
		{
			g_iPendingLimit = value;
		}
		case ANNE_OPTION_INTERVAL:
		{
			g_iPendingInterval = value;
		}
		case ANNE_OPTION_AUTO_MODE:
		{
			g_iPendingAutoMode = (value == 0) ? 1 : 0;
		}
		case ANNE_OPTION_DISTANCE:
		{
			g_iPendingDistance = value;
		}
		case ANNE_OPTION_TELEPORT_CHECK:
		{
			g_iPendingTeleportCheck = value;
		}
		case ANNE_OPTION_APPLY:
		{
			g_bPendingPreset = false;
			g_sPendingPresetName[0] = '\0';
			PrepareAnnePendingFromCurrent();
			StartApplyVote(client, SpawnVoteMode_Anne);
		}
		case -1:
		{
			CPrintToChat(client, "%t", "SpawnVote_MenuClosed");
		}
	}
}

void ResetPendingSpawnSettings()
{
	g_iPendingMode = SpawnVoteMode_None;
	g_iPendingLimit = SPAWN_MENU_UNSET;
	g_iPendingInterval = SPAWN_MENU_UNSET;
	g_iPendingAutoMode = SPAWN_MENU_UNSET;
	g_iPendingDistance = SPAWN_MENU_UNSET;
	g_iPendingTeleportCheck = SPAWN_MENU_UNSET;
	g_iPendingAssault = SPAWN_MENU_UNSET;
	g_iPendingTankTogether = SPAWN_MENU_UNSET;
	g_iPendingRelax = SPAWN_MENU_UNSET;
	g_bPendingPreset = false;
	g_sPendingPresetName[0] = '\0';
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

bool StartPresetApplyVote(int client, SpawnVoteMode mode, int presetIndex)
{
	ResetPendingSpawnSettings();

	if (mode == SpawnVoteMode_Campaign)
	{
		if (presetIndex < 0 || presetIndex >= g_iCampaignPresetCount)
		{
			return false;
		}

		strcopy(g_sPendingPresetName, sizeof(g_sPendingPresetName), g_sCampaignPresetNames[presetIndex]);
		g_iPendingLimit = g_iCampaignPresetLimit[presetIndex];
		g_iPendingInterval = g_iCampaignPresetInterval[presetIndex];
		g_iPendingAssault = g_iCampaignPresetAssault[presetIndex];
		g_iPendingTankTogether = g_iCampaignPresetTankTogether[presetIndex];
		g_iPendingRelax = g_iCampaignPresetRelax[presetIndex];
		ResolvePendingRelaxFromCurrent();
		g_bPendingPreset = true;
		bool started = StartApplyVote(client, mode);
		if (!started)
		{
			ResetPendingSpawnSettings();
		}
		return started;
	}

	if (mode == SpawnVoteMode_Anne)
	{
		if (presetIndex < 0 || presetIndex >= g_iAnnePresetCount)
		{
			return false;
		}

		strcopy(g_sPendingPresetName, sizeof(g_sPendingPresetName), g_sAnnePresetNames[presetIndex]);
		g_iPendingLimit = g_iAnnePresetLimit[presetIndex];
		g_iPendingInterval = g_iAnnePresetInterval[presetIndex];
		g_iPendingAutoMode = g_iAnnePresetAutoMode[presetIndex];
		g_iPendingDistance = g_iAnnePresetDistance[presetIndex];
		g_iPendingTeleportCheck = g_iAnnePresetTeleportCheck[presetIndex];
		g_bPendingPreset = true;
		bool started = StartApplyVote(client, mode);
		if (!started)
		{
			ResetPendingSpawnSettings();
		}
		return started;
	}

	return false;
}

void FormatVoteTitle(char[] buffer, int maxlen, SpawnVoteMode mode)
{
	if (g_bPendingPreset)
	{
		if (mode == SpawnVoteMode_Campaign)
		{
			char relax[32];
			FormatRelaxState(relax, sizeof(relax), LANG_SERVER, g_iPendingRelax);
			Format(buffer, maxlen, "%T", "SpawnVote_PresetVoteTitleRelax", LANG_SERVER, g_sPendingPresetName, relax);
			return;
		}

		Format(buffer, maxlen, "%T", "SpawnVote_PresetVoteTitle", LANG_SERVER, g_sPendingPresetName);
		return;
	}

	if (mode == SpawnVoteMode_Campaign)
	{
		char relax[32];
		FormatRelaxState(relax, sizeof(relax), LANG_SERVER, g_iPendingRelax);
		Format(buffer, maxlen, "%T", "SpawnVote_CampaignVoteTitleRelax", LANG_SERVER, g_iPendingLimit, g_iPendingInterval, relax);
	}
	else
	{
		Format(buffer, maxlen, "%T", "SpawnVote_AnneVoteTitle", LANG_SERVER, g_iPendingLimit, g_iPendingInterval);
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
			Format(message, sizeof(message), "%T", "SpawnVote_AppliedVoteTitle", LANG_SERVER);
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
			g_cvAnneLimit.SetInt(g_iPendingLimit);
		}
		if (g_cvAnneInterval != null)
		{
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

void FormatRelaxState(char[] buffer, int maxlen, int target, int value)
{
	if (value == SPAWN_MENU_UNSET)
	{
		value = 1;
	}

	if (value != 0)
	{
		Format(buffer, maxlen, "%T", "SpawnVote_RelaxOn", target);
	}
	else
	{
		Format(buffer, maxlen, "%T", "SpawnVote_RelaxOff", target);
	}
}

void AddCampaignPresetEntries(int menu)
{
	if (g_iCampaignPresetCount == 0)
	{
		return;
	}

	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "常用预设:", MENU_ENTRY);
	for (int i = 0; i < g_iCampaignPresetCount; i++)
	{
		char entry[SPAWN_PRESET_NAME_LENGTH + 16];
		FormatEx(entry, sizeof(entry), "%d. %s", i + 1, g_sCampaignPresetNames[i]);
		ExtraMenu_AddEntry(menu, entry, MENU_SELECT_ONLY, true);
	}
}

void AddAnnePresetEntries(int menu)
{
	if (g_iAnnePresetCount == 0)
	{
		return;
	}

	ExtraMenu_AddEntry(menu, " ", MENU_ENTRY);
	ExtraMenu_AddEntry(menu, "常用预设:", MENU_ENTRY);
	for (int i = 0; i < g_iAnnePresetCount; i++)
	{
		char entry[SPAWN_PRESET_NAME_LENGTH + 16];
		FormatEx(entry, sizeof(entry), "%d. %s", i + 1, g_sAnnePresetNames[i]);
		ExtraMenu_AddEntry(menu, entry, MENU_SELECT_ONLY, true);
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
