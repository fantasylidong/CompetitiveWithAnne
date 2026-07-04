#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>
#undef REQUIRE_PLUGIN
#include <veterans>
#include <confogl>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0"
#define TOTAL_BEGINNER_MINUTES (50 * 60)
#define TOTAL_INTERMEDIATE_MINUTES (200 * 60)
#define SERVER_AUTO_STOP_MINUTES (20 * 60)

#define AUTO_GUIDE_INITIAL_DELAY 10.0
#define AUTO_GUIDE_RETRY_DELAY 5.0
#define AUTO_GUIDE_MAX_RETRIES 10

enum GuideTier
{
	GuideTier_Beginner = 0,
	GuideTier_Intermediate,
	GuideTier_Experienced
};

public Plugin myinfo =
{
	name = "Anne New Player Guide",
	author = "morzlee",
	description = "Recommends Anne server gameplay paths for newer players.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

bool g_bAutoShown[MAXPLAYERS + 1];
bool g_bVeteransAvailable = false;
bool g_bConfoglAvailable = false;
bool g_bLeft4DHooksAvailable = false;
int g_iRetryCount[MAXPLAYERS + 1];

ConVar g_hEnabled = null;
ConVar g_hInitialDelay = null;
ConVar g_hRetryDelay = null;
ConVar g_hMaxRetries = null;
ConVar g_hServerAutoStopMinutes = null;
ConVar g_hSuppressWhenModeLoaded = null;

public void OnPluginStart()
{
	LoadTranslations("new_player_guide.phrases");

	g_hEnabled = CreateConVar("sm_new_player_guide_enable", "1", "Enable automatic new player guide prompts.", _, true, 0.0, true, 1.0);
	g_hInitialDelay = CreateConVar("sm_new_player_guide_initial_delay", "10.0", "Delay before the first automatic guide prompt check.", _, true, 1.0, true, 120.0);
	g_hRetryDelay = CreateConVar("sm_new_player_guide_retry_delay", "5.0", "Delay between playtime API retries.", _, true, 1.0, true, 60.0);
	g_hMaxRetries = CreateConVar("sm_new_player_guide_max_retries", "10", "How many times to wait for playtime data before showing the beginner guide.", _, true, 0.0, true, 30.0);
	g_hServerAutoStopMinutes = CreateConVar("sm_new_player_guide_server_stop_minutes", "1200", "This-server playtime in minutes after which automatic guide prompts stop.", _, true, 0.0, true, 100000.0);
	g_hSuppressWhenModeLoaded = CreateConVar("sm_new_player_guide_suppress_mode_loaded", "1", "Suppress automatic guide prompts when Confogl match mode is loaded.", _, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_guide", Command_Guide);
	RegConsoleCmd("sm_modes", Command_Guide);
	RegConsoleCmd("sm_modeguide", Command_Guide);

	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

	AutoExecConfig(true, "new_player_guide");
	RefreshLibraries();
}

public void OnAllPluginsLoaded()
{
	RefreshLibraries();
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "veterans"))
	{
		g_bVeteransAvailable = true;
	}
	else if (StrEqual(name, "confogl"))
	{
		g_bConfoglAvailable = true;
	}
	else if (StrEqual(name, "left4dhooks"))
	{
		g_bLeft4DHooksAvailable = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "veterans"))
	{
		g_bVeteransAvailable = false;
	}
	else if (StrEqual(name, "confogl"))
	{
		g_bConfoglAvailable = false;
	}
	else if (StrEqual(name, "left4dhooks"))
	{
		g_bLeft4DHooksAvailable = false;
	}
}

public void OnClientPutInServer(int client)
{
	g_bAutoShown[client] = false;
	g_iRetryCount[client] = 0;

	if (IsValidHumanClient(client))
	{
		QueueAutoGuide(client, g_hInitialDelay.FloatValue);
	}
}

public void OnClientDisconnect(int client)
{
	g_bAutoShown[client] = false;
	g_iRetryCount[client] = 0;
}

public void l4dstats_SuccessGetPlayerTime(int client)
{
	QueueAutoGuide(client, 1.0);
}

public void l4dstats_AnnounceGameTime(int client)
{
	QueueAutoGuide(client, 1.0);
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	int team = event.GetInt("team");

	if (team == 2 || team == 3)
	{
		QueueAutoGuide(client, 3.0);
	}

	return Plugin_Continue;
}

public Action Command_Guide(int client, int args)
{
	if (!IsValidHumanClient(client))
	{
		return Plugin_Handled;
	}

	ShowGuide(client, true);
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

	if (!CanReadVeterans())
	{
		RetryAutoGuide(client);
		return;
	}

	int totalMinutes = GetBestTotalMinutes(client);
	int serverMinutes = GetServerMinutes(client);

	if (!IsPlaytimeReady(totalMinutes, serverMinutes) && RetryAutoGuide(client))
	{
		return;
	}

	if (serverMinutes >= GetServerAutoStopMinutes())
	{
		return;
	}

	ShowAutoGuidePanel(client);
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

void ShowGuide(int client, bool manual)
{
	int totalMinutes = GetBestTotalMinutes(client);
	int serverMinutes = GetServerMinutes(client);

	char totalHours[16];
	char serverHours[16];
	char stopHours[16];
	FormatHours(totalMinutes, totalHours, sizeof(totalHours));
	FormatHours(serverMinutes, serverHours, sizeof(serverHours));
	FormatHours(GetServerAutoStopMinutes(), stopHours, sizeof(stopHours));

	CPrintToChat(client, "%t", "NPG_Header", totalHours, serverHours);

	switch (GetGuideTier(totalMinutes))
	{
		case GuideTier_Beginner:
		{
			CPrintToChat(client, "%t", "NPG_Beginner");
		}
		case GuideTier_Intermediate:
		{
			CPrintToChat(client, "%t", "NPG_Intermediate");
		}
		case GuideTier_Experienced:
		{
			CPrintToChat(client, "%t", "NPG_Experienced");
		}
	}

	CPrintToChat(client, "%t", "NPG_Commands");
	CPrintToChat(client, "%t", "NPG_AutoStops", stopHours);

	if (manual && IsServerModeLoaded())
	{
		CPrintToChat(client, "%t", "NPG_MatchLoaded");
	}
}

void ShowAutoGuidePanel(int client)
{
	int totalMinutes = GetBestTotalMinutes(client);
	int serverMinutes = GetServerMinutes(client);

	char totalHours[16];
	char serverHours[16];
	char stopHours[16];
	FormatHours(totalMinutes, totalHours, sizeof(totalHours));
	FormatHours(serverMinutes, serverHours, sizeof(serverHours));
	FormatHours(GetServerAutoStopMinutes(), stopHours, sizeof(stopHours));

	char buffer[192];
	Panel panel = new Panel();

	FormatEx(buffer, sizeof(buffer), "%T", "NPG_PanelTitle", client);
	panel.SetTitle(buffer);

	FormatEx(buffer, sizeof(buffer), "%T", "NPG_PanelPlaytime", client, totalHours, serverHours);
	panel.DrawText(buffer);
	panel.DrawText(" ");

	switch (GetGuideTier(totalMinutes))
	{
		case GuideTier_Beginner:
		{
			AddGuidePanelText(client, panel, "NPG_PanelBeginner");
		}
		case GuideTier_Intermediate:
		{
			AddGuidePanelText(client, panel, "NPG_PanelIntermediate");
		}
		case GuideTier_Experienced:
		{
			AddGuidePanelText(client, panel, "NPG_PanelExperienced");
		}
	}

	panel.DrawText(" ");
	AddGuidePanelText(client, panel, "NPG_PanelCommands1");
	AddGuidePanelText(client, panel, "NPG_PanelCommands2");

	FormatEx(buffer, sizeof(buffer), "%T", "NPG_PanelAutoStops", client, stopHours);
	panel.DrawText(buffer);
	panel.DrawItem("", ITEMDRAW_SPACER);

	FormatEx(buffer, sizeof(buffer), "%T", "NPG_PanelClose", client);
	panel.CurrentKey = GetMaxPageItems(panel.Style);
	panel.DrawItem(buffer, ITEMDRAW_CONTROL);

	panel.Send(client, GuidePanelHandler, 45);
	delete panel;
}

void AddGuidePanelText(int client, Panel panel, const char[] phrase)
{
	char buffer[192];
	FormatEx(buffer, sizeof(buffer), "%T", phrase, client);
	panel.DrawText(buffer);
}

public int GuidePanelHandler(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}

GuideTier GetGuideTier(int totalMinutes)
{
	if (totalMinutes < TOTAL_BEGINNER_MINUTES)
	{
		return GuideTier_Beginner;
	}

	if (totalMinutes < TOTAL_INTERMEDIATE_MINUTES)
	{
		return GuideTier_Intermediate;
	}

	return GuideTier_Experienced;
}

int GetBestTotalMinutes(int client)
{
	int totalMinutes = GetTotalMinutes(client);
	if (totalMinutes > 0)
	{
		return totalMinutes;
	}

	int realMinutes = GetRealMinutes(client);
	if (realMinutes > 0)
	{
		return realMinutes;
	}

	return 0;
}

int GetTotalMinutes(int client)
{
	if (!CanReadVeterans())
	{
		return 0;
	}

	return Veterans_Get(client, TIME_TOTAL);
}

int GetRealMinutes(int client)
{
	if (!CanReadVeterans())
	{
		return 0;
	}

	return Veterans_Get(client, TIME_REAL);
}

int GetServerMinutes(int client)
{
	if (!CanReadVeterans())
	{
		return 0;
	}

	return Veterans_Get(client, TIME_SERVER);
}

bool IsPlaytimeReady(int totalMinutes, int serverMinutes)
{
	return totalMinutes > 0 || serverMinutes > 0;
}

int GetServerAutoStopMinutes()
{
	int minutes = g_hServerAutoStopMinutes.IntValue;
	if (minutes <= 0)
	{
		return SERVER_AUTO_STOP_MINUTES;
	}

	return minutes;
}

void FormatHours(int minutes, char[] buffer, int maxLength)
{
	if (minutes <= 0)
	{
		strcopy(buffer, maxLength, "0");
		return;
	}

	Format(buffer, maxLength, "%.1f", float(minutes) / 60.0);
}

bool CanReadVeterans()
{
	return g_bVeteransAvailable && GetFeatureStatus(FeatureType_Native, "Veterans_Get") == FeatureStatus_Available;
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
	g_bVeteransAvailable = LibraryExists("veterans");
	g_bConfoglAvailable = LibraryExists("confogl");
	g_bLeft4DHooksAvailable = LibraryExists("left4dhooks");
}
