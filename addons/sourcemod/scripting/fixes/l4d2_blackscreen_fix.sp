#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <stringtables_data>

#define PRIORITY_CONFIG "data/restrict_strings.cfg"
#define DEFERRED_CONFIG "data/deferred_strings.cfg"
#define MAX_DEFERRED_GROUPS 128

ArrayList g_aDownloadables;
ArrayList g_aPriority;
ArrayList g_aDeferred;

ConVar g_cvDeferredGroupCount;

int g_iDeferredGroupOrder[MAX_DEFERRED_GROUPS];
int g_iDeferredGroupOrderCount;
int g_iDeferredGroupOrderCursor;
int g_iPlannedDeferredCount = -1;
int g_iPlannedGroupCount = -1;
int g_iLastDeferredGroup = -1;
bool g_bDownloadablesSaved;
bool g_bRestoredThisMap;

public Plugin myinfo =
{
	name = "[L4D & L4D2] Staged FastDL / Black Screen Fix",
	author = "BHaType, Dragokas, AnneHappy",
	description = "Keeps priority downloads on connect and downloads optional assets in batches during map transitions",
	version = "1.2.0"
};

public void OnPluginStart()
{
	g_aDownloadables = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_aPriority = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_aDeferred = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	g_cvDeferredGroupCount = CreateConVar(
		"sm_fixscreen_deferred_group_count",
		"8",
		"Number of groups used to split deferred files; one shuffled group is restored per real map change (0 disables deferred downloads).",
		FCVAR_NONE,
		true,
		0.0,
		true,
		float(MAX_DEFERRED_GROUPS)
	);

	RegAdminCmd("sm_get_restricted_strings", CMD_GetPriorityFiles, ADMFLAG_ROOT, "List files downloaded when a player first connects");
	RegAdminCmd("sm_restore_st", CMD_RestoreDownloadables, ADMFLAG_ROOT, "Restore every saved downloadables string-table item");

	AddCommandListener(ServerCmd_ChangeLevel, "changelevel");
}

public void OnMapStart()
{
	g_bDownloadablesSaved = false;
	g_bRestoredThisMap = false;
	CreateTimer(0.1, Timer_SaveDownloadables, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SaveDownloadables(Handle timer)
{
	SaveDownloadables();
	return Plugin_Stop;
}

void SaveDownloadables()
{
	if (!LoadFileList(PRIORITY_CONFIG, g_aPriority, true))
	{
		LogError("[FixScreen] Priority config '%s' is missing; leaving the downloadables table unchanged.", PRIORITY_CONFIG);
		return;
	}

	LoadFileList(DEFERRED_CONFIG, g_aDeferred, false);

	int table = FindStringTable("downloadables");
	if (table == INVALID_STRING_TABLE)
	{
		LogError("[FixScreen] Cannot find the 'downloadables' string table.");
		return;
	}

	g_aDownloadables.Clear();

	int count = GetStringTableNumStrings(table);
	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < count; i++)
	{
		ReadStringTable(table, i, path, sizeof(path));
		if (path[0] != '\0' && g_aDownloadables.FindString(path) == -1)
			g_aDownloadables.PushString(path);
	}

	INetworkStringTable downloadables = INetworkStringTable(table);
	downloadables.DeleteStrings();
	AddFileListToDownloadsTable(g_aPriority);

	g_bDownloadablesSaved = true;
	PrintToServer(
		"[FixScreen] Saved %d downloadables; keeping %d priority files on first connect and staging %d deferred files.",
		g_aDownloadables.Length,
		g_aPriority.Length,
		g_aDeferred.Length
	);
}

public Action ServerCmd_ChangeLevel(int client, const char[] command, int argc)
{
	if (!g_bDownloadablesSaved || g_bRestoredThisMap)
		return Plugin_Continue;

	RestoreTransitionDownloadables();
	g_bRestoredThisMap = true;
	return Plugin_Continue;
}

void RestoreTransitionDownloadables()
{
	char path[PLATFORM_MAX_PATH];
	int regularCount;

	for (int i = 0; i < g_aDownloadables.Length; i++)
	{
		g_aDownloadables.GetString(i, path, sizeof(path));
		if (g_aDeferred.FindString(path) != -1)
			continue;

		AddFileToDownloadsTable(path);
		regularCount++;
	}

	int selectedGroup;
	int groupCount;
	int deferredCount = AddRandomDeferredGroup(selectedGroup, groupCount);
	PrintToServer(
		"[FixScreen] Restored %d regular files and deferred group %d/%d (%d files) for this map change.",
		regularCount,
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
	int added;
	for (int i = 0; i < groupSize; i++)
	{
		int index = start + i;
		g_aDeferred.GetString(index, path, sizeof(path));
		if (g_aDownloadables.FindString(path) != -1)
		{
			AddFileToDownloadsTable(path);
			added++;
		}
	}

	return added;
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

public Action CMD_RestoreDownloadables(int client, int args)
{
	if (!g_bDownloadablesSaved)
	{
		ReplyToCommand(client, "Cannot restore: the downloadables string table has not been saved.");
		return Plugin_Handled;
	}

	AddFileListToDownloadsTable(g_aDownloadables);
	ReplyToCommand(client, "Restored %d downloadables string-table items.", g_aDownloadables.Length);
	return Plugin_Handled;
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
