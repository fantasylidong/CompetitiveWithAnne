#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PRIORITY_CONFIG "data/restrict_strings.cfg"
#define DEFERRED_CONFIG "data/deferred_strings.cfg"
#define MAX_DEFERRED_GROUPS 128

static const char g_sDanceModels[][] =
{
	"models/player/custom_player/foxhound/fortnite_dances_emotes_ok.mdl",
	"models/player/custom_player/foxhound/fortnite_dances_emotes_ok.vvd",
	"models/player/custom_player/foxhound/fortnite_dances_emotes_ok.dx90.vtx"
};

ArrayList g_aPriority;
ArrayList g_aDeferred;

ConVar g_cvDeferredGroupCount;

int g_iDeferredGroupOrder[MAX_DEFERRED_GROUPS];
int g_iDeferredGroupOrderCount;
int g_iDeferredGroupOrderCursor;
int g_iPlannedDeferredCount = -1;
int g_iPlannedGroupCount = -1;
int g_iLastDeferredGroup = -1;
bool g_bTransitionBatchAdded;
bool g_bPriorityAddedThisMap;
bool g_bLateLoad;

public Plugin myinfo =
{
	name = "[L4D & L4D2] Additive Staged FastDL",
	author = "BHaType, Dragokas, AnneHappy",
	description = "Adds priority downloads on map start and optional assets in batches during map transitions",
	version = "1.3.0"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_aPriority = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_aDeferred = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	g_cvDeferredGroupCount = CreateConVar(
		"sm_fixscreen_deferred_group_count",
		"8",
		"Number of groups used to split deferred files; one shuffled group is added per real map change (0 disables deferred downloads).",
		FCVAR_NONE,
		true,
		0.0,
		true,
		float(MAX_DEFERRED_GROUPS)
	);

	RegAdminCmd("sm_get_restricted_strings", CMD_GetPriorityFiles, ADMFLAG_ROOT, "List files added when a player first connects");

	HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
	AddCommandListener(ServerCmd_ChangeLevel, "changelevel");

	if (g_bLateLoad)
		CreateTimer(0.1, Timer_AddPriorityFiles, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
	g_bTransitionBatchAdded = false;
	g_bPriorityAddedThisMap = false;
	CreateTimer(0.1, Timer_AddPriorityFiles, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_AddPriorityFiles(Handle timer)
{
	if (g_bPriorityAddedThisMap)
		return Plugin_Stop;

	if (!LoadFileList(PRIORITY_CONFIG, g_aPriority, true))
		return Plugin_Stop;

	LoadFileList(DEFERRED_CONFIG, g_aDeferred, false);
	AddFileListToDownloadsTable(g_aPriority);
	g_bPriorityAddedThisMap = true;

	PrintToServer(
		"[FixScreen] Added %d priority files; %d deferred files are available for additive transition batches.",
		g_aPriority.Length,
		g_aDeferred.Length
	);
	return Plugin_Stop;
}

public void Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
	AddTransitionDownloadables();
}

public Action ServerCmd_ChangeLevel(int client, const char[] command, int argc)
{
	AddTransitionDownloadables();
	return Plugin_Continue;
}

void AddTransitionDownloadables()
{
	if (g_bTransitionBatchAdded)
		return;

	if (g_aDeferred.Length == 0)
		LoadFileList(DEFERRED_CONFIG, g_aDeferred, false);

	for (int i = 0; i < sizeof(g_sDanceModels); i++)
		AddFileToDownloadsTable(g_sDanceModels[i]);

	int selectedGroup;
	int groupCount;
	int deferredCount = AddRandomDeferredGroup(selectedGroup, groupCount);
	g_bTransitionBatchAdded = true;

	PrintToServer(
		"[FixScreen] Added %d dance model files and deferred group %d/%d (%d files) for this map change.",
		sizeof(g_sDanceModels),
		selectedGroup + 1,
		groupCount,
		deferredCount
	);
}

int AddRandomDeferredGroup(int &selectedGroup, int &groupCount)
{
	int total = g_aDeferred.Length;
	groupCount = g_cvDeferredGroupCount.IntValue;
	selectedGroup = -1;

	if (total == 0 || groupCount <= 0)
	{
		groupCount = 0;
		return 0;
	}

	if (groupCount > total)
		groupCount = total;

	EnsureDeferredGroupOrder(total, groupCount);
	selectedGroup = g_iDeferredGroupOrder[g_iDeferredGroupOrderCursor++];
	g_iLastDeferredGroup = selectedGroup;

	int baseSize = total / groupCount;
	int largerGroups = total % groupCount;
	int groupSize = baseSize + (selectedGroup < largerGroups ? 1 : 0);
	int start = selectedGroup * baseSize;
	start += (selectedGroup < largerGroups) ? selectedGroup : largerGroups;

	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < groupSize; i++)
	{
		g_aDeferred.GetString(start + i, path, sizeof(path));
		AddFileToDownloadsTable(path);
	}

	return groupSize;
}

void EnsureDeferredGroupOrder(int deferredCount, int groupCount)
{
	bool planChanged = (deferredCount != g_iPlannedDeferredCount || groupCount != g_iPlannedGroupCount);
	if (!planChanged && g_iDeferredGroupOrderCursor < g_iDeferredGroupOrderCount)
		return;

	if (planChanged)
		g_iLastDeferredGroup = -1;

	for (int i = 0; i < groupCount; i++)
		g_iDeferredGroupOrder[i] = i;

	for (int i = groupCount - 1; i > 0; i--)
	{
		int other = GetRandomInt(0, i);
		int swap = g_iDeferredGroupOrder[i];
		g_iDeferredGroupOrder[i] = g_iDeferredGroupOrder[other];
		g_iDeferredGroupOrder[other] = swap;
	}

	if (groupCount > 1 && g_iLastDeferredGroup >= 0 && g_iDeferredGroupOrder[0] == g_iLastDeferredGroup)
	{
		int other = GetRandomInt(1, groupCount - 1);
		g_iDeferredGroupOrder[0] = g_iDeferredGroupOrder[other];
		g_iDeferredGroupOrder[other] = g_iLastDeferredGroup;
	}

	g_iDeferredGroupOrderCount = groupCount;
	g_iDeferredGroupOrderCursor = 0;
	g_iPlannedDeferredCount = deferredCount;
	g_iPlannedGroupCount = groupCount;
}

public Action CMD_GetPriorityFiles(int client, int args)
{
	if (!LoadFileList(PRIORITY_CONFIG, g_aPriority, true))
	{
		ReplyToCommand(client, "No config '%s' was found.", PRIORITY_CONFIG);
		return Plugin_Handled;
	}

	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < g_aPriority.Length; i++)
	{
		g_aPriority.GetString(i, path, sizeof(path));
		ReplyToCommand(client, "%d. %s", i + 1, path);
	}

	return Plugin_Handled;
}

bool LoadFileList(const char[] relativePath, ArrayList list, bool reportMissing)
{
	list.Clear();

	char fullPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, fullPath, sizeof(fullPath), relativePath);
	if (!FileExists(fullPath))
	{
		if (reportMissing)
			LogError("[FixScreen] Missing file list: %s", relativePath);
		return false;
	}

	File file = OpenFile(fullPath, "r");
	if (file == null)
	{
		LogError("[FixScreen] Cannot open file list: %s", relativePath);
		return false;
	}

	char line[PLATFORM_MAX_PATH];
	while (file.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		if (line[0] == '\0' || strncmp(line, "//", 2, false) == 0)
			continue;

		if (list.FindString(line) == -1)
			list.PushString(line);
	}

	delete file;
	return true;
}

void AddFileListToDownloadsTable(ArrayList list)
{
	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < list.Length; i++)
	{
		list.GetString(i, path, sizeof(path));
		AddFileToDownloadsTable(path);
	}
}
