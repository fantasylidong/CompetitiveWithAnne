#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colors>
#undef REQUIRE_PLUGIN
#include <l4dstats>
#include <confogl>
#include <left4dhooks>
#include <rpg>

#define PLUGIN_VERSION "2.0"
#define SERVER_AUTO_STOP_MINUTES (30 * 60)
#define PERMANENT_DISABLE_MINUTES (10 * 60)

#define AUTO_GUIDE_INITIAL_DELAY 1.0
#define AUTO_GUIDE_RETRY_DELAY 5.0
#define AUTO_GUIDE_MAX_RETRIES 10
#define SERVER_TIME_RETRY_DELAY 1.0
#define SERVER_TIME_MAX_RETRIES 1
#define GUIDE_MENU_TIMEOUT 60
#define MODE_BLOCK_NOTICE_INTERVAL 3

enum GuideParent
{
	GuideParent_Home = 0,
	GuideParent_Coop,
	GuideParent_Versus
};

public Plugin myinfo =
{
	name = "Anne Telecom Server Mode Guide",
	author = "morzlee",
	description = "Guides players through Anne server PvE and versus mode choices.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

static const char g_sSoloConfigs[][] =
{
	"hunters",
	"alone",
	"not0721_mutation4_solo",
	"not0721_realism_solo",
	"not0721_coop_solo"
};

static const char g_sSoloPhrases[][] =
{
	"NPG_Mode_HTTraining",
	"NPG_Mode_Alone",
	"NPG_Mode_Not0721MutationSolo",
	"NPG_Mode_RealismSolo",
	"NPG_Mode_CampaignSolo"
};

static const char g_sEasyConfigs[][] =
{
	"coop",
	"purecoop",
	"not0721_coop_base",
	"not0721_mutation4_noobplus",
	"not0721_community5_noobplus",
	"not0721_community5_multi",
	"not0721_community5_ez"
};

static const char g_sEasyPhrases[][] =
{
	"NPG_Mode_AnneCoop",
	"NPG_Mode_PureCoop",
	"NPG_Mode_Not0721CoopBase",
	"NPG_Mode_Not0721MutationNoobPlus",
	"NPG_Mode_Not0721CommunityNoobPlus",
	"NPG_Mode_Not0721CommunityMulti",
	"NPG_Mode_Not0721CommunityEZ"
};

static const char g_sNormalConfigs[][] =
{
	"annehappy",
	"mutation4",
	"puremutation4",
	"realism",
	"purerealism",
	"not0721_coop_hard",
	"not0721_mutation4_ez",
	"not0721_community5_610",
	"not0721_realism_miaomei"
};

static const char g_sNormalPhrases[][] =
{
	"NPG_Mode_AnneHappy",
	"NPG_Mode_AnneMutation",
	"NPG_Mode_PureMutation",
	"NPG_Mode_AnneRealism",
	"NPG_Mode_PureRealism",
	"NPG_Mode_Not0721CoopHard",
	"NPG_Mode_Not0721MutationEZ",
	"NPG_Mode_Not0721Community610",
	"NPG_Mode_Not0721RealismMiaomei"
};

static const char g_sHardConfigs[][] =
{
	"annehappy_hardcore",
	"annehappy_shotgun",
	"purecommunity5",
	"not0721_coop_fuckmap",
	"not0721_coop_himiko",
	"not0721_mutation4",
	"not0721_mutation4_except",
	"not0721_community2",
	"not0721_community5",
	"not0721_community5_himiko",
	"not0721_community5_jimen"
};

static const char g_sHardPhrases[][] =
{
	"NPG_Mode_AnneHardcore",
	"NPG_Mode_AnneShotgun",
	"NPG_Mode_PureCommunity5",
	"NPG_Mode_Not0721Fuckmap",
	"NPG_Mode_Not0721CoopHimiko",
	"NPG_Mode_Not0721Mutation",
	"NPG_Mode_Not0721MutationExcept",
	"NPG_Mode_Not0721Community2",
	"NPG_Mode_Not0721Community5",
	"NPG_Mode_Not0721CommunityHimiko",
	"NPG_Mode_Not0721CommunityJimen"
};

static const char g_sFunConfigs[][] =
{
	"allcharger",
	"not0721_coop_fire",
	"witchparty",
	"not0721_coop_wtf"
};

static const char g_sFunPhrases[][] =
{
	"NPG_Mode_AllCharger",
	"NPG_Mode_InfiniteFire",
	"NPG_Mode_WitchParty",
	"NPG_Mode_Not0721WTF"
};

static const char g_sVersus1Configs[][] =
{
	"zm1v1", "nextmod1v1", "amrv1v1", "eq1v1", "zh1v1"
};

static const char g_sVersus1Names[][] =
{
	"1v1 ZoneMod", "1v1 NextMod", "1v1 Acemod RV", "1v1 EQ", "1v1 ZoneHunters"
};

static const char g_sVersus2Configs[][] =
{
	"zm2v2", "nextmod2v2", "amrv2v2", "eq2v2", "zh2v2"
};

static const char g_sVersus2Names[][] =
{
	"2v2 ZoneMod", "2v2 NextMod", "2v2 Acemod RV", "2v2 EQ", "2v2 ZoneHunters"
};

static const char g_sVersus3Configs[][] =
{
	"zm3v3", "nextmod3v3", "amrv3v3", "eq3v3", "zh3v3"
};

static const char g_sVersus3Names[][] =
{
	"3v3 ZoneMod", "3v3 NextMod", "3v3 Acemod RV", "3v3 EQ", "3v3 ZoneHunters"
};

static const char g_sVersus4Configs[][] =
{
	"zonemod",
	"zoneretro",
	"neomod",
	"nextmod",
	"pmelite",
	"deadman",
	"acemodrv",
	"eq",
	"apex",
	"zonehunters"
};

static const char g_sVersus4Names[][] =
{
	"ZoneMod 4v4",
	"ZoneMod Retro 4v4",
	"NeoMod 4v4",
	"NextMod 4v4",
	"Promod Elite 4v4",
	"Deadman 4v4",
	"Acemod RV 4v4",
	"Equilibrium 4v4",
	"Apex 4v4",
	"ZoneHunters 4v4"
};

bool g_bAutoShown[MAXPLAYERS + 1];
bool g_bL4DStatsAvailable = false;
bool g_bConfoglAvailable = false;
bool g_bLeft4DHooksAvailable = false;
bool g_bRpgAvailable = false;
int g_iRetryCount[MAXPLAYERS + 1];
int g_iServerTimeRetryCount[MAXPLAYERS + 1];
bool g_bSafeReturnPositionSet[MAXPLAYERS + 1];
float g_vSafeReturnPosition[MAXPLAYERS + 1][3];
bool g_bFallbackSafeReturnPositionSet = false;
float g_vFallbackSafeReturnPosition[3];
int g_iLastModeBlockNotice[MAXPLAYERS + 1];

ConVar g_hEnabled = null;
ConVar g_hInitialDelay = null;
ConVar g_hRetryDelay = null;
ConVar g_hMaxRetries = null;
ConVar g_hServerAutoStopMinutes = null;
ConVar g_hPermanentDisableMinutes = null;
ConVar g_hSuppressWhenModeLoaded = null;

public void OnPluginStart()
{
	LoadTranslations("new_player_guide.phrases");

	g_hEnabled = CreateConVar("sm_anne_mode_guide_enable", "1", "Enable automatic Anne mode guide prompts.", _, true, 0.0, true, 1.0);
	g_hInitialDelay = CreateConVar("sm_anne_mode_guide_initial_delay", "1.0", "Delay before the first automatic mode guide check.", _, true, 1.0, true, 120.0);
	g_hRetryDelay = CreateConVar("sm_anne_mode_guide_retry_delay", "5.0", "Delay between playtime and preference retries.", _, true, 1.0, true, 60.0);
	g_hMaxRetries = CreateConVar("sm_anne_mode_guide_max_retries", "10", "How many times to wait for playtime and preference data.", _, true, 0.0, true, 30.0);
	g_hServerAutoStopMinutes = CreateConVar("sm_anne_mode_guide_server_stop_minutes", "1800", "This-server playtime in minutes after which automatic prompts stop.", _, true, 0.0, true, 100000.0);
	g_hPermanentDisableMinutes = CreateConVar("sm_anne_mode_guide_permanent_disable_minutes", "600", "This-server playtime in minutes required before the permanent prompt toggle appears.", _, true, 0.0, true, 100000.0);
	g_hSuppressWhenModeLoaded = CreateConVar("sm_anne_mode_guide_suppress_mode_loaded", "1", "Suppress automatic prompts when a Confogl match mode is loaded.", _, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_guide", Command_Guide);
	RegConsoleCmd("sm_modes", Command_Guide);
	RegConsoleCmd("sm_modeguide", Command_Guide);
	RegConsoleCmd("sm_anneguide", Command_Guide);

	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	AutoExecConfig(true, "anne_mode_guide");
	RefreshLibraries();
	ResetSafeReturnPositions();
	CreateTimer(0.5, Timer_CaptureSafeReturnPositions, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
	ResetSafeReturnPositions();
	CreateTimer(1.0, Timer_CaptureSafeReturnPositions, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnAllPluginsLoaded()
{
	RefreshLibraries();
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "l4d_stats"))
	{
		g_bL4DStatsAvailable = true;
	}
	else if (StrEqual(name, "confogl"))
	{
		g_bConfoglAvailable = true;
	}
	else if (StrEqual(name, "left4dhooks"))
	{
		g_bLeft4DHooksAvailable = true;
	}
	else if (StrEqual(name, "rpg"))
	{
		g_bRpgAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "l4d_stats"))
	{
		g_bL4DStatsAvailable = false;
	}
	else if (StrEqual(name, "confogl"))
	{
		g_bConfoglAvailable = false;
	}
	else if (StrEqual(name, "left4dhooks"))
	{
		g_bLeft4DHooksAvailable = false;
	}
	else if (StrEqual(name, "rpg"))
	{
		g_bRpgAvailable = false;
	}
}

public void OnClientPutInServer(int client)
{
	g_bAutoShown[client] = false;
	g_iRetryCount[client] = 0;
	g_iServerTimeRetryCount[client] = 0;
	g_bSafeReturnPositionSet[client] = false;
	g_iLastModeBlockNotice[client] = 0;

	if (IsValidHumanClient(client))
	{
		QueueAutoGuide(client, g_hInitialDelay.FloatValue);
	}
}

public void OnClientDisconnect(int client)
{
	g_bAutoShown[client] = false;
	g_iRetryCount[client] = 0;
	g_iServerTimeRetryCount[client] = 0;
	g_bSafeReturnPositionSet[client] = false;
	g_iLastModeBlockNotice[client] = 0;
}

public void l4dstats_SuccessGetPlayerTime(int client)
{
	g_iServerTimeRetryCount[client] = SERVER_TIME_MAX_RETRIES;
	QueueAutoGuide(client, 0.1);
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	int client = GetClientOfUserId(userid);
	int team = event.GetInt("team");

	if (team == 2)
	{
		CreateTimer(0.2, Timer_CaptureClientSafeReturnPosition, userid, TIMER_FLAG_NO_MAPCHANGE);
	}
	else if (1 <= client <= MaxClients)
	{
		g_bSafeReturnPositionSet[client] = false;
	}

	if (team == 2 || team == 3)
	{
		QueueAutoGuide(client, 1.0);
	}

	return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.2, Timer_CaptureClientSafeReturnPosition, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetSafeReturnPositions();
	CreateTimer(0.5, Timer_CaptureSafeReturnPositions, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
	if (!ShouldBlockUntilModeSelected())
	{
		return Plugin_Continue;
	}

	TeleportSurvivorToSafeReturnPosition(client);
	if (IsValidHumanClient(client))
	{
		int now = GetTime();
		if (g_iLastModeBlockNotice[client] == 0 || now - g_iLastModeBlockNotice[client] >= MODE_BLOCK_NOTICE_INTERVAL)
		{
			g_iLastModeBlockNotice[client] = now;
			CPrintToChat(client, "%t", "NPG_ModeSelectionRequired");
			ShowMainGuideMenu(client, GUIDE_MENU_TIMEOUT);
		}
	}

	return Plugin_Handled;
}

public Action Command_Guide(int client, int args)
{
	if (!IsValidHumanClient(client))
	{
		return Plugin_Handled;
	}

	ShowMainGuideMenu(client, GUIDE_MENU_TIMEOUT);
	return Plugin_Handled;
}

void QueueAutoGuide(int client, float delay)
{
	if (!IsValidHumanClient(client) || g_bAutoShown[client])
	{
		return;
	}

	CreateTimer(delay, Timer_AutoGuide, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AutoGuide(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidHumanClient(client))
	{
		return Plugin_Stop;
	}

	TryAutoGuide(client);
	return Plugin_Stop;
}

void TryAutoGuide(int client)
{
	if (!g_hEnabled.BoolValue || g_bAutoShown[client])
	{
		return;
	}

	if (g_hSuppressWhenModeLoaded.BoolValue && IsServerModeLoaded())
	{
		return;
	}

	if (!IsFirstMapForAutoGuide())
	{
		return;
	}

	if (!IsServerPlaytimeReady(client) && RetryServerPlaytime(client))
	{
		return;
	}

	int serverMinutes = GetServerMinutes(client);
	if (serverMinutes >= GetServerAutoStopMinutes())
	{
		return;
	}

	bool preferenceReady;
	bool promptEnabled;
	GetGuidePromptPreference(client, preferenceReady, promptEnabled);
	if (!preferenceReady && RetryAutoGuide(client))
	{
		return;
	}

	if (preferenceReady && !promptEnabled)
	{
		return;
	}

	ShowMainGuideMenu(client, GUIDE_MENU_TIMEOUT);
	g_bAutoShown[client] = true;
}

bool RetryAutoGuide(int client)
{
	if (g_iRetryCount[client] >= g_hMaxRetries.IntValue)
	{
		return false;
	}

	g_iRetryCount[client]++;
	QueueAutoGuide(client, g_hRetryDelay.FloatValue);
	return true;
}

bool RetryServerPlaytime(int client)
{
	if (g_iServerTimeRetryCount[client] >= SERVER_TIME_MAX_RETRIES)
	{
		return false;
	}

	g_iServerTimeRetryCount[client]++;
	QueueAutoGuide(client, SERVER_TIME_RETRY_DELAY);
	return true;
}

void ResetSafeReturnPositions()
{
	g_bFallbackSafeReturnPositionSet = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		g_bSafeReturnPositionSet[client] = false;
		g_iLastModeBlockNotice[client] = 0;
	}
}

public Action Timer_CaptureSafeReturnPositions(Handle timer, any data)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		CaptureSafeReturnPosition(client);
	}

	return Plugin_Stop;
}

public Action Timer_CaptureClientSafeReturnPosition(Handle timer, any userid)
{
	CaptureSafeReturnPosition(GetClientOfUserId(userid));
	return Plugin_Stop;
}

void CaptureSafeReturnPosition(int client)
{
	if (!IsValidAliveSurvivor(client))
	{
		return;
	}

	GetClientAbsOrigin(client, g_vSafeReturnPosition[client]);
	g_bSafeReturnPositionSet[client] = true;
	if (!g_bFallbackSafeReturnPositionSet)
	{
		g_vFallbackSafeReturnPosition[0] = g_vSafeReturnPosition[client][0];
		g_vFallbackSafeReturnPosition[1] = g_vSafeReturnPosition[client][1];
		g_vFallbackSafeReturnPosition[2] = g_vSafeReturnPosition[client][2];
		g_bFallbackSafeReturnPositionSet = true;
	}
}

void TeleportSurvivorToSafeReturnPosition(int client)
{
	if (!IsValidAliveSurvivor(client))
	{
		return;
	}

	float position[3];
	if (g_bSafeReturnPositionSet[client])
	{
		position[0] = g_vSafeReturnPosition[client][0];
		position[1] = g_vSafeReturnPosition[client][1];
		position[2] = g_vSafeReturnPosition[client][2];
	}
	else if (g_bFallbackSafeReturnPositionSet)
	{
		position[0] = g_vFallbackSafeReturnPosition[0];
		position[1] = g_vFallbackSafeReturnPosition[1];
		position[2] = g_vFallbackSafeReturnPosition[2];
	}
	else
	{
		return;
	}

	position[2] += 5.0;
	float velocity[3] = {0.0, 0.0, 0.0};
	TeleportEntity(client, position, NULL_VECTOR, velocity);
}

bool ShouldBlockUntilModeSelected()
{
	return g_hEnabled != null
		&& g_hEnabled.BoolValue
		&& g_bConfoglAvailable
		&& GetFeatureStatus(FeatureType_Native, "LGO_IsMatchModeLoaded") == FeatureStatus_Available
		&& !LGO_IsMatchModeLoaded();
}

bool IsValidAliveSurvivor(int client)
{
	return 1 <= client <= MaxClients
		&& IsClientInGame(client)
		&& IsPlayerAlive(client)
		&& GetClientTeam(client) == 2;
}

void ShowMainGuideMenu(int client, int timeout)
{
	char title[256];
	char serverHours[32];
	FormatServerPlaytime(client, GetServerMinutes(client), serverHours, sizeof(serverHours));
	FormatEx(title, sizeof(title), "%T", "NPG_MenuTitle", client, serverHours);

	Menu menu = new Menu(MainGuideMenuHandler);
	menu.SetTitle(title);
	AddTranslatedMenuItem(menu, client, "solo", "NPG_CategorySolo");
	AddTranslatedMenuItem(menu, client, "coop", "NPG_CategoryCoop");
	AddTranslatedMenuItem(menu, client, "versus", "NPG_CategoryVersus");

	bool preferenceReady;
	bool promptEnabled;
	GetGuidePromptPreference(client, preferenceReady, promptEnabled);
	if (preferenceReady && CanPersistGuidePreference(client))
	{
		AddTranslatedMenuItem(menu, client, "prompt_toggle", promptEnabled ? "NPG_PermanentDisable" : "NPG_PermanentEnable");
	}

	menu.ExitButton = true;
	menu.Display(client, timeout);
}

public int MainGuideMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Select)
	{
		char info[64];
		menu.GetItem(param2, info, sizeof(info));
		if (StrEqual(info, "solo"))
		{
			ShowSoloMenu(param1);
		}
		else if (StrEqual(info, "coop"))
		{
			ShowCoopProfileMenu(param1);
		}
		else if (StrEqual(info, "versus"))
		{
			ShowVersusSizeMenu(param1);
		}
		else if (StrEqual(info, "prompt_toggle"))
		{
			ToggleGuidePreference(param1);
		}
	}

	return 0;
}

void ShowSoloMenu(int client)
{
	Menu menu = CreateTranslatedModeMenu(client, "NPG_TitleSolo", g_sSoloConfigs, g_sSoloPhrases, sizeof(g_sSoloConfigs), SoloMenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowCoopProfileMenu(int client)
{
	Menu menu = CreateGuideMenu(client, "NPG_TitleCoopProfile", CoopProfileMenuHandler);
	AddTranslatedMenuItem(menu, client, "easy", "NPG_ProfileNew");
	AddTranslatedMenuItem(menu, client, "normal", "NPG_ProfileExperienced");
	AddTranslatedMenuItem(menu, client, "hard", "NPG_ProfileHardcore");
	AddTranslatedMenuItem(menu, client, "fun", "NPG_ProfileFun");
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

public int CoopProfileMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowMainGuideMenu(param1, GUIDE_MENU_TIMEOUT);
	}
	else if (action == MenuAction_Select)
	{
		char info[32];
		menu.GetItem(param2, info, sizeof(info));
		if (StrEqual(info, "easy"))
		{
			ShowEasyMenu(param1);
		}
		else if (StrEqual(info, "normal"))
		{
			ShowNormalMenu(param1);
		}
		else if (StrEqual(info, "hard"))
		{
			ShowHardMenu(param1);
		}
		else if (StrEqual(info, "fun"))
		{
			ShowFunMenu(param1);
		}
	}

	return 0;
}

void ShowEasyMenu(int client)
{
	Menu menu = CreateTranslatedModeMenu(client, "NPG_TitleEasy", g_sEasyConfigs, g_sEasyPhrases, sizeof(g_sEasyConfigs), EasyMenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowNormalMenu(int client)
{
	Menu menu = CreateTranslatedModeMenu(client, "NPG_TitleNormal", g_sNormalConfigs, g_sNormalPhrases, sizeof(g_sNormalConfigs), NormalMenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowHardMenu(int client)
{
	Menu menu = CreateTranslatedModeMenu(client, "NPG_TitleHard", g_sHardConfigs, g_sHardPhrases, sizeof(g_sHardConfigs), HardMenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowFunMenu(int client)
{
	Menu menu = CreateTranslatedModeMenu(client, "NPG_TitleFun", g_sFunConfigs, g_sFunPhrases, sizeof(g_sFunConfigs), FunMenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowVersusSizeMenu(int client)
{
	Menu menu = CreateGuideMenu(client, "NPG_TitleVersusSize", VersusSizeMenuHandler);
	menu.AddItem("1v1", "1v1");
	menu.AddItem("2v2", "2v2");
	menu.AddItem("3v3", "3v3");
	menu.AddItem("4v4", "4v4");
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

public int VersusSizeMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel && param2 == MenuCancel_ExitBack)
	{
		ShowMainGuideMenu(param1, GUIDE_MENU_TIMEOUT);
	}
	else if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(param2, info, sizeof(info));
		if (StrEqual(info, "1v1"))
		{
			ShowVersus1Menu(param1);
		}
		else if (StrEqual(info, "2v2"))
		{
			ShowVersus2Menu(param1);
		}
		else if (StrEqual(info, "3v3"))
		{
			ShowVersus3Menu(param1);
		}
		else if (StrEqual(info, "4v4"))
		{
			ShowVersus4Menu(param1);
		}
	}

	return 0;
}

void ShowVersus1Menu(int client)
{
	Menu menu = CreateNamedModeMenu(client, "NPG_TitleVersus1", g_sVersus1Configs, g_sVersus1Names, sizeof(g_sVersus1Configs), Versus1MenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowVersus2Menu(int client)
{
	Menu menu = CreateNamedModeMenu(client, "NPG_TitleVersus2", g_sVersus2Configs, g_sVersus2Names, sizeof(g_sVersus2Configs), Versus2MenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowVersus3Menu(int client)
{
	Menu menu = CreateNamedModeMenu(client, "NPG_TitleVersus3", g_sVersus3Configs, g_sVersus3Names, sizeof(g_sVersus3Configs), Versus3MenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

void ShowVersus4Menu(int client)
{
	Menu menu = CreateNamedModeMenu(client, "NPG_TitleVersus4", g_sVersus4Configs, g_sVersus4Names, sizeof(g_sVersus4Configs), Versus4MenuHandler);
	menu.Display(client, GUIDE_MENU_TIMEOUT);
}

public int SoloMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Home);
}

public int EasyMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Coop);
}

public int NormalMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Coop);
}

public int HardMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Coop);
}

public int FunMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Coop);
}

public int Versus1MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Versus);
}

public int Versus2MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Versus);
}

public int Versus3MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Versus);
}

public int Versus4MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return HandleModeMenuAction(menu, action, param1, param2, GuideParent_Versus);
}

int HandleModeMenuAction(Menu menu, MenuAction action, int client, int item, GuideParent parent)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
	{
		ShowParentMenu(client, parent);
	}
	else if (action == MenuAction_Select)
	{
		char config[64];
		menu.GetItem(item, config, sizeof(config));
		FakeClientCommand(client, "sm_match %s", config);
	}

	return 0;
}

void ShowParentMenu(int client, GuideParent parent)
{
	switch (parent)
	{
		case GuideParent_Coop:
		{
			ShowCoopProfileMenu(client);
		}
		case GuideParent_Versus:
		{
			ShowVersusSizeMenu(client);
		}
		default:
		{
			ShowMainGuideMenu(client, GUIDE_MENU_TIMEOUT);
		}
	}
}

Menu CreateGuideMenu(int client, const char[] titlePhrase, MenuHandler handler)
{
	char title[192];
	FormatEx(title, sizeof(title), "%T", titlePhrase, client);
	Menu menu = new Menu(handler);
	menu.SetTitle(title);
	menu.ExitBackButton = true;
	return menu;
}

Menu CreateTranslatedModeMenu(int client, const char[] titlePhrase, const char[][] configs, const char[][] phrases, int count, MenuHandler handler)
{
	Menu menu = CreateGuideMenu(client, titlePhrase, handler);
	for (int i = 0; i < count; i++)
	{
		AddTranslatedMenuItem(menu, client, configs[i], phrases[i]);
	}
	return menu;
}

Menu CreateNamedModeMenu(int client, const char[] titlePhrase, const char[][] configs, const char[][] names, int count, MenuHandler handler)
{
	Menu menu = CreateGuideMenu(client, titlePhrase, handler);
	for (int i = 0; i < count; i++)
	{
		menu.AddItem(configs[i], names[i]);
	}
	return menu;
}

void AddTranslatedMenuItem(Menu menu, int client, const char[] info, const char[] phrase, int draw = ITEMDRAW_DEFAULT)
{
	char buffer[192];
	FormatEx(buffer, sizeof(buffer), "%T", phrase, client);
	menu.AddItem(info, buffer, draw);
}

void ToggleGuidePreference(int client)
{
	bool ready;
	bool enabled;
	GetGuidePromptPreference(client, ready, enabled);
	if (!ready || !CanPersistGuidePreference(client)
		|| !L4D_RPG_SetAnneGuidePrompt(client, !enabled))
	{
		CPrintToChat(client, "%t", "NPG_PreferenceUnavailable");
		return;
	}

	CPrintToChat(client, "%t", enabled ? "NPG_PreferenceDisabled" : "NPG_PreferenceEnabled");
}

void GetGuidePromptPreference(int client, bool &ready, bool &enabled)
{
	ready = true;
	enabled = true;
	if (!g_bRpgAvailable
		|| GetFeatureStatus(FeatureType_Native, "L4D_RPG_GetAnneGuidePrompt") != FeatureStatus_Available)
	{
		return;
	}

	int value = L4D_RPG_GetAnneGuidePrompt(client);
	if (value < 0)
	{
		ready = false;
		return;
	}

	enabled = value != 0;
}

bool CanPersistGuidePreference(int client)
{
	return g_bRpgAvailable
		&& GetFeatureStatus(FeatureType_Native, "L4D_RPG_SetAnneGuidePrompt") == FeatureStatus_Available
		&& GetServerMinutes(client) > GetPermanentDisableMinutes();
}

int GetServerMinutes(int client)
{
	if (!CanReadServerPlaytime())
	{
		return -1;
	}

	return l4dstats_GetClientPlayTime(client);
}

int GetServerAutoStopMinutes()
{
	int minutes = g_hServerAutoStopMinutes.IntValue;
	return minutes > 0 ? minutes : SERVER_AUTO_STOP_MINUTES;
}

int GetPermanentDisableMinutes()
{
	int minutes = g_hPermanentDisableMinutes.IntValue;
	return minutes > 0 ? minutes : PERMANENT_DISABLE_MINUTES;
}

void FormatServerPlaytime(int client, int minutes, char[] buffer, int maxLength)
{
	if (minutes < 0)
	{
		FormatEx(buffer, maxLength, "%T", "NPG_PlaytimeUnknown", client);
		return;
	}

	Format(buffer, maxLength, "%.1f h", float(minutes) / 60.0);
}

bool CanReadServerPlaytime()
{
	return g_bL4DStatsAvailable
		&& GetFeatureStatus(FeatureType_Native, "l4dstats_GetClientPlayTime") == FeatureStatus_Available;
}

bool IsServerPlaytimeReady(int client)
{
	return g_bL4DStatsAvailable
		&& GetFeatureStatus(FeatureType_Native, "l4dstats_IsClientScoreReady") == FeatureStatus_Available
		&& l4dstats_IsClientScoreReady(client) != 0;
}

bool IsServerModeLoaded()
{
	if (!g_bConfoglAvailable || GetFeatureStatus(FeatureType_Native, "LGO_IsMatchModeLoaded") != FeatureStatus_Available)
	{
		return false;
	}

	return LGO_IsMatchModeLoaded();
}

bool IsFirstMapForAutoGuide()
{
	if (!g_bLeft4DHooksAvailable || GetFeatureStatus(FeatureType_Native, "L4D_IsFirstMapInScenario") != FeatureStatus_Available)
	{
		return false;
	}

	return L4D_IsFirstMapInScenario();
}

bool IsValidHumanClient(int client)
{
	return 1 <= client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

void RefreshLibraries()
{
	g_bL4DStatsAvailable = LibraryExists("l4d_stats");
	g_bConfoglAvailable = LibraryExists("confogl");
	g_bLeft4DHooksAvailable = LibraryExists("left4dhooks");
	g_bRpgAvailable = LibraryExists("rpg");
}
