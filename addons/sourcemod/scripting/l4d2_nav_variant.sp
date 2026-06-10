#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "0.1"
#define GAMEDATA_FILE "l4d2_nav_variant"
#define DEFAULT_CONFIG "configs/nav_variants.cfg"
#define DEFAULT_VARIANT "anne"
#define DEFAULT_STRIPPER_PATH "cfg/stripper/zonemod_anne"
#define FILESYSTEM_OBJECT_OFFSET 4

public Plugin myinfo =
{
	name = "L4D2 Nav Variant Loader",
	author = "morzlee, OpenAI",
	description = "Redirects selected .nav loads to configured variants.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

ConVar g_cvEnable;
ConVar g_cvVariant;
ConVar g_cvConfig;
ConVar g_cvRequiredCfg;
ConVar g_cvRequiredStripperPath;
ConVar g_cvDebug;
ConVar g_cvReadyCfgName;
ConVar g_cvStripperCfgPath;

DynamicHook g_hReadFileHook;
int g_iReadFilePreHookId = INVALID_HOOK_ID;
int g_iReadFilePostHookId = INVALID_HOOK_ID;

Handle g_hSDKReleaseCachedNavData;
Address g_pFileSystem = Address_Null;
Address g_pNavMesh = Address_Null;

KeyValues g_kvNavVariants;
bool g_bConfigLoaded;
bool g_bClearQueued;
bool g_bHookedReadyCfgName;
bool g_bHookedStripperCfgPath;
bool g_bPendingNavRead;
bool g_bLastReadWasRedirect;
bool g_bLastReadSucceeded;
int g_iRedirectCount;
int g_iMissingFileCount;
char g_sLastMap[64];
char g_sLastVariant[64];
char g_sLastStripperPath[PLATFORM_MAX_PATH];
char g_sLastOriginal[PLATFORM_MAX_PATH];
char g_sLastReplacement[PLATFORM_MAX_PATH];
char g_sLastStatus[192];
char g_sPendingOriginal[PLATFORM_MAX_PATH];
char g_sPendingReplacement[PLATFORM_MAX_PATH];
char g_sClearReason[128];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
	if (GetEngineVersion() != Engine_Left4Dead2)
	{
		strcopy(error, errMax, "Plugin supports L4D2 only.");
		return APLRes_SilentFailure;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvEnable = CreateConVar("l4d2_nav_variant_enable", "1", "Enable nav variant redirection.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvVariant = CreateConVar("l4d2_nav_variant_name", DEFAULT_VARIANT, "Active nav variant name when the current stripper path is eligible. Empty means use the map's default nav.");
	g_cvConfig = CreateConVar("l4d2_nav_variant_config", DEFAULT_CONFIG, "Path under addons/sourcemod for nav variant KeyValues config.");
	g_cvRequiredCfg = CreateConVar("l4d2_nav_variant_required_cfg", "", "Optional l4d_ready_cfg_name substring guard. Empty means l4d2_nav_variant_name alone controls redirection.");
	g_cvRequiredStripperPath = CreateConVar("l4d2_nav_variant_stripper_path", DEFAULT_STRIPPER_PATH, "Require stripper_cfg_path to equal this path. Empty disables this guard.");
	g_cvDebug = CreateConVar("l4d2_nav_variant_debug", "0", "Print nav variant decisions to the server log.", FCVAR_NONE, true, 0.0, true, 1.0);
	CreateConVar("l4d2_nav_variant_version", PLUGIN_VERSION, "L4D2 Nav Variant Loader version.", FCVAR_DONTRECORD);

	HookConVarChange(g_cvEnable, OnNavCvarChanged);
	HookConVarChange(g_cvVariant, OnNavCvarChanged);
	HookConVarChange(g_cvConfig, OnConfigCvarChanged);
	HookConVarChange(g_cvRequiredCfg, OnNavCvarChanged);
	HookConVarChange(g_cvRequiredStripperPath, OnNavCvarChanged);

	RegAdminCmd("sm_nav_variant_reload", Cmd_ReloadConfig, ADMFLAG_ROOT, "Reload nav variant config.");
	RegAdminCmd("sm_nav_variant_clearcache", Cmd_ClearCache, ADMFLAG_ROOT, "Clear cached nav file data for the next nav load.");
	RegAdminCmd("sm_nav_variant_status", Cmd_Status, ADMFLAG_ROOT, "Show nav variant state and last redirected read result.");

	InitGameData();
	LoadNavConfig();
	EnsureReadyCfgNameHook();
	EnsureStripperCfgPathHook();
}

public void OnConfigsExecuted()
{
	EnsureReadyCfgNameHook();
	EnsureStripperCfgPathHook();
}

public void OnMapStart()
{
	ResetLastStatus("not attempted for current map");
}

public void OnPluginEnd()
{
	if (g_iReadFilePreHookId != INVALID_HOOK_ID)
	{
		DynamicHook.RemoveHook(g_iReadFilePreHookId);
		g_iReadFilePreHookId = INVALID_HOOK_ID;
	}

	if (g_iReadFilePostHookId != INVALID_HOOK_ID)
	{
		DynamicHook.RemoveHook(g_iReadFilePostHookId);
		g_iReadFilePostHookId = INVALID_HOOK_ID;
	}

	delete g_kvNavVariants;
}

Action Cmd_ReloadConfig(int client, int args)
{
	LoadNavConfig();
	QueueClearNavCache("config reloaded");
	ResetLastStatus("config reloaded; not attempted for current map");
	ReplyToCommand(client, "[NavVariant] Reloaded %s.", g_bConfigLoaded ? "successfully" : "with no valid config");
	return Plugin_Handled;
}

Action Cmd_ClearCache(int client, int args)
{
	ClearNavCache("manual command");
	ResetLastStatus("cache cleared; not attempted for current map");
	ReplyToCommand(client, "[NavVariant] Requested nav cache clear for the next nav load.");
	return Plugin_Handled;
}

Action Cmd_Status(int client, int args)
{
	char variantName[64];
	char requiredStripper[PLATFORM_MAX_PATH];
	char currentStripper[PLATFORM_MAX_PATH];
	char mapName[64];
	char replacement[PLATFORM_MAX_PATH];

	g_cvVariant.GetString(variantName, sizeof(variantName));
	g_cvRequiredStripperPath.GetString(requiredStripper, sizeof(requiredStripper));
	TrimString(variantName);
	NormalizePath(requiredStripper);
	GetCurrentStripperPath(currentStripper, sizeof(currentStripper));
	GetCurrentMap(mapName, sizeof(mapName));

	bool active = ShouldUseVariant(variantName, sizeof(variantName));
	bool configured = FindReplacementNav(mapName, variantName, replacement, sizeof(replacement));
	bool exists = configured && FileExists(replacement, true, "GAME");
	bool lastMatchesCurrent = IsLastStatusForCurrentContext(mapName, variantName, currentStripper, replacement);
	bool currentFileReadSucceeded = lastMatchesCurrent && g_bLastReadWasRedirect && g_bLastReadSucceeded;
	char currentStatus[192];
	GetCurrentStatus(active, configured, exists, lastMatchesCurrent, currentStatus, sizeof(currentStatus));

	ReplyToCommand(client, "[NavVariant] active=%d enabled=%d config=%d variant=\"%s\"", active, g_cvEnable.BoolValue, g_bConfigLoaded, variantName);
	ReplyToCommand(client, "[NavVariant] stripper=\"%s\" required=\"%s\"", currentStripper, requiredStripper);
	ReplyToCommand(client, "[NavVariant] map=\"%s\" configured=%d exists=%d replacement=\"%s\"", mapName, configured, exists, replacement);
	ReplyToCommand(client, "[NavVariant] current_file_read_success=%d current_status=\"%s\"", currentFileReadSucceeded, currentStatus);
	ReplyToCommand(client, "[NavVariant] redirects=%d missing_files=%d last_matches_current=%d last_redirect=%d last_file_read_success=%d", g_iRedirectCount, g_iMissingFileCount, lastMatchesCurrent, g_bLastReadWasRedirect, g_bLastReadSucceeded);
	ReplyToCommand(client, "[NavVariant] last_map=\"%s\" last_variant=\"%s\" last_stripper=\"%s\"", g_sLastMap, g_sLastVariant, g_sLastStripperPath);
	ReplyToCommand(client, "[NavVariant] last_original=\"%s\" last_replacement=\"%s\"", g_sLastOriginal, g_sLastReplacement);
	ReplyToCommand(client, "[NavVariant] last_status=\"%s\"", g_sLastStatus);
	return Plugin_Handled;
}

void OnNavCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	QueueClearNavCache("nav cvar changed");
	ResetLastStatus("nav cvar changed; not attempted for current map");
}

void OnConfigCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	LoadNavConfig();
	QueueClearNavCache("config cvar changed");
	ResetLastStatus("config cvar changed; not attempted for current map");
}

void OnReadyCfgNameChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	QueueClearNavCache("ready cfg changed");
	ResetLastStatus("ready cfg changed; not attempted for current map");
}

void OnStripperCfgPathChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	QueueClearNavCache("stripper cfg changed");
	ResetLastStatus("stripper cfg changed; not attempted for current map");
}

void InitGameData()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (gd == null)
	{
		SetFailState("Missing gamedata \"%s.txt\".", GAMEDATA_FILE);
	}

	Address fileSystem = gd.GetAddress("fileSystem");
	if (fileSystem == Address_Null)
	{
		SetFailState("Failed to find address: fileSystem.");
	}

	g_pFileSystem = fileSystem + view_as<Address>(FILESYSTEM_OBJECT_OFFSET);
	if (g_pFileSystem == Address_Null)
	{
		SetFailState("Failed to resolve IBaseFileSystem pointer.");
	}

	g_pNavMesh = gd.GetAddress("TerrorNavMesh");
	if (g_pNavMesh == Address_Null)
	{
		SetFailState("Failed to find address: TerrorNavMesh.");
	}

	int readFileOffset = gd.GetOffset("IBaseFileSystem::ReadFile");
	if (readFileOffset == -1)
	{
		SetFailState("Failed to find offset: IBaseFileSystem::ReadFile.");
	}

	g_hReadFileHook = new DynamicHook(readFileOffset, HookType_Raw, ReturnType_Bool, ThisPointer_Address);
	if (g_hReadFileHook == null)
	{
		SetFailState("Failed to create IBaseFileSystem::ReadFile hook.");
	}

	g_hReadFileHook.AddParam(HookParamType_CharPtr);
	g_hReadFileHook.AddParam(HookParamType_CharPtr);
	g_hReadFileHook.AddParam(HookParamType_ObjectPtr);
	g_hReadFileHook.AddParam(HookParamType_Int);
	g_hReadFileHook.AddParam(HookParamType_Int);
	g_hReadFileHook.AddParam(HookParamType_Int);

	g_iReadFilePreHookId = g_hReadFileHook.HookRaw(Hook_Pre, g_pFileSystem, DTR_ReadFile);
	if (g_iReadFilePreHookId == INVALID_HOOK_ID)
	{
		SetFailState("Failed to hook IBaseFileSystem::ReadFile.");
	}

	g_iReadFilePostHookId = g_hReadFileHook.HookRaw(Hook_Post, g_pFileSystem, DTR_ReadFile_Post);
	if (g_iReadFilePostHookId == INVALID_HOOK_ID)
	{
		SetFailState("Failed to hook IBaseFileSystem::ReadFile post.");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CNavMesh::ReleaseCachedNavData"))
	{
		SetFailState("Failed to find signature: CNavMesh::ReleaseCachedNavData.");
	}

	g_hSDKReleaseCachedNavData = EndPrepSDKCall();
	if (g_hSDKReleaseCachedNavData == null)
	{
		SetFailState("Failed to create SDKCall: CNavMesh::ReleaseCachedNavData.");
	}

	delete gd;
}

void EnsureReadyCfgNameHook()
{
	if (g_bHookedReadyCfgName)
	{
		return;
	}

	g_cvReadyCfgName = FindConVar("l4d_ready_cfg_name");
	if (g_cvReadyCfgName == null)
	{
		return;
	}

	HookConVarChange(g_cvReadyCfgName, OnReadyCfgNameChanged);
	g_bHookedReadyCfgName = true;
}

void EnsureStripperCfgPathHook()
{
	if (g_bHookedStripperCfgPath)
	{
		return;
	}

	g_cvStripperCfgPath = FindConVar("stripper_cfg_path");
	if (g_cvStripperCfgPath == null)
	{
		return;
	}

	HookConVarChange(g_cvStripperCfgPath, OnStripperCfgPathChanged);
	g_bHookedStripperCfgPath = true;
}

void LoadNavConfig()
{
	delete g_kvNavVariants;
	g_bConfigLoaded = false;

	char configPath[PLATFORM_MAX_PATH];
	g_cvConfig.GetString(configPath, sizeof(configPath));
	TrimString(configPath);

	if (configPath[0] == '\0')
	{
		DebugLog("No config path set.");
		return;
	}

	char fullPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, fullPath, sizeof(fullPath), "%s", configPath);

	g_kvNavVariants = new KeyValues("NavVariants");
	if (!g_kvNavVariants.ImportFromFile(fullPath))
	{
		DebugLog("Config not loaded: %s", fullPath);
		return;
	}

	g_bConfigLoaded = true;
	DebugLog("Loaded config: %s", fullPath);
}

MRESReturn DTR_ReadFile(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	char variantName[64];
	if (!ShouldUseVariant(variantName, sizeof(variantName)))
	{
		return MRES_Ignored;
	}

	if (hParams.IsNull(1) || hParams.IsNull(2))
	{
		return MRES_Ignored;
	}

	char path[PLATFORM_MAX_PATH];
	hParams.GetString(1, path, sizeof(path));
	NormalizeSlashes(path);

	char pathID[32];
	hParams.GetString(2, pathID, sizeof(pathID));
	if (!StrEqual(pathID, "GAME", false))
	{
		return MRES_Ignored;
	}

	char mapName[64];
	if (!ExtractDefaultNavMapName(path, mapName, sizeof(mapName)))
	{
		return MRES_Ignored;
	}

	char replacement[PLATFORM_MAX_PATH];
	if (!FindReplacementNav(mapName, variantName, replacement, sizeof(replacement)))
	{
		SaveLastStatus(mapName, variantName, path, "", "no configured variant for this map");
		DebugLog("No nav variant for map \"%s\" variant \"%s\".", mapName, variantName);
		return MRES_Ignored;
	}

	if (!IsSafeNavPath(replacement))
	{
		LogError("Rejected unsafe nav variant path for %s/%s: %s", mapName, variantName, replacement);
		return MRES_Ignored;
	}

	if (!FileExists(replacement, true, "GAME"))
	{
		g_iMissingFileCount++;
		SaveLastStatus(mapName, variantName, path, replacement, "configured variant file is missing");
		LogError("Configured nav variant does not exist in GAME path for %s/%s: %s", mapName, variantName, replacement);
		return MRES_Ignored;
	}

	g_bPendingNavRead = true;
	strcopy(g_sPendingOriginal, sizeof(g_sPendingOriginal), path);
	strcopy(g_sPendingReplacement, sizeof(g_sPendingReplacement), replacement);
	SaveLastStatus(mapName, variantName, path, replacement, "redirect pending");
	hParams.SetString(1, replacement);
	DebugLog("Redirect nav: %s -> %s", path, replacement);
	return MRES_ChangedHandled;
}

MRESReturn DTR_ReadFile_Post(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
	if (!g_bPendingNavRead)
	{
		return MRES_Ignored;
	}

	char path[PLATFORM_MAX_PATH];
	hParams.GetString(1, path, sizeof(path));
	NormalizeSlashes(path);
	if (!StrEqual(path, g_sPendingReplacement, false))
	{
		return MRES_Ignored;
	}

	g_bPendingNavRead = false;
	g_bLastReadWasRedirect = true;
	g_bLastReadSucceeded = view_as<bool>(hReturn.Value);
	g_iRedirectCount++;

	if (g_bLastReadSucceeded)
	{
		Format(g_sLastStatus, sizeof(g_sLastStatus), "redirected file read succeeded");
		LogMessage("[NavVariant] Redirected nav file read succeeded: %s -> %s", g_sPendingOriginal, g_sPendingReplacement);
	}
	else
	{
		Format(g_sLastStatus, sizeof(g_sLastStatus), "redirected file read failed");
		LogError("[NavVariant] Redirected nav file read failed: %s -> %s", g_sPendingOriginal, g_sPendingReplacement);
	}

	return MRES_Ignored;
}

bool ShouldUseVariant(char[] variantName, int variantSize)
{
	variantName[0] = '\0';

	if (!g_cvEnable.BoolValue || !g_bConfigLoaded)
	{
		return false;
	}

	g_cvVariant.GetString(variantName, variantSize);
	TrimString(variantName);
	if (variantName[0] == '\0')
	{
		return false;
	}

	if (!IsRequiredStripperPathActive())
	{
		return false;
	}

	char requiredCfg[128];
	g_cvRequiredCfg.GetString(requiredCfg, sizeof(requiredCfg));
	TrimString(requiredCfg);
	if (requiredCfg[0] == '\0')
	{
		return true;
	}

	EnsureReadyCfgNameHook();
	if (g_cvReadyCfgName == null)
	{
		DebugLog("Required cfg guard is set but l4d_ready_cfg_name is missing.");
		return false;
	}

	char readyCfg[128];
	g_cvReadyCfgName.GetString(readyCfg, sizeof(readyCfg));
	return StrContains(readyCfg, requiredCfg, false) != -1;
}

bool IsRequiredStripperPathActive()
{
	char requiredPath[PLATFORM_MAX_PATH];
	g_cvRequiredStripperPath.GetString(requiredPath, sizeof(requiredPath));
	NormalizePath(requiredPath);
	if (requiredPath[0] == '\0')
	{
		return true;
	}

	char currentPath[PLATFORM_MAX_PATH];
	if (!GetCurrentStripperPath(currentPath, sizeof(currentPath)))
	{
		DebugLog("Required stripper guard is set but stripper_cfg_path is missing.");
		return false;
	}

	return StrEqual(currentPath, requiredPath, false);
}

bool GetCurrentStripperPath(char[] path, int pathSize)
{
	path[0] = '\0';

	EnsureStripperCfgPathHook();
	if (g_cvStripperCfgPath == null)
	{
		return false;
	}

	g_cvStripperCfgPath.GetString(path, pathSize);
	NormalizePath(path);
	return path[0] != '\0';
}

bool ExtractDefaultNavMapName(const char[] path, char[] mapName, int mapNameSize)
{
	mapName[0] = '\0';

	if (StrContains(path, "maps/", false) != 0)
	{
		return false;
	}

	int len = strlen(path);
	if (len <= 9 || !StrEqual(path[len - 4], ".nav", false))
	{
		return false;
	}

	char relPath[PLATFORM_MAX_PATH];
	strcopy(relPath, sizeof(relPath), path[5]);
	if (FindCharInString(relPath, '/') != -1)
	{
		return false;
	}

	relPath[strlen(relPath) - 4] = '\0';
	strcopy(mapName, mapNameSize, relPath);
	return mapName[0] != '\0';
}

bool FindReplacementNav(const char[] mapName, const char[] variantName, char[] replacement, int replacementSize)
{
	replacement[0] = '\0';

	if (g_kvNavVariants == null)
	{
		return false;
	}

	g_kvNavVariants.Rewind();
	if (!g_kvNavVariants.JumpToKey(mapName, false))
	{
		g_kvNavVariants.Rewind();
		return false;
	}

	g_kvNavVariants.GetString(variantName, replacement, replacementSize, "");
	g_kvNavVariants.Rewind();
	TrimString(replacement);
	NormalizeSlashes(replacement);

	return replacement[0] != '\0';
}

bool IsSafeNavPath(const char[] path)
{
	if (StrContains(path, "maps/", false) != 0)
	{
		return false;
	}

	if (StrContains(path, "..", false) != -1)
	{
		return false;
	}

	if (path[0] == '/' || path[0] == '\\')
	{
		return false;
	}

	int len = strlen(path);
	if (len <= 4 || len >= 256)
	{
		return false;
	}

	return StrEqual(path[len - 4], ".nav", false);
}

void NormalizeSlashes(char[] path)
{
	for (int i = 0; path[i] != '\0'; i++)
	{
		if (path[i] == '\\')
		{
			path[i] = '/';
		}
	}
}

void NormalizePath(char[] path)
{
	TrimString(path);
	NormalizeSlashes(path);

	int len = strlen(path);
	while (len > 0 && path[len - 1] == '/')
	{
		path[len - 1] = '\0';
		len--;
	}
}

bool IsLastStatusForCurrentContext(const char[] mapName, const char[] variantName, const char[] stripperPath, const char[] replacement)
{
	if (g_sLastStatus[0] == '\0')
	{
		return false;
	}

	if (!StrEqual(g_sLastMap, mapName, false) || !StrEqual(g_sLastVariant, variantName, false))
	{
		return false;
	}

	if (!StrEqual(g_sLastStripperPath, stripperPath, false))
	{
		return false;
	}

	if (replacement[0] == '\0')
	{
		return g_sLastReplacement[0] == '\0';
	}

	return StrEqual(g_sLastReplacement, replacement, false);
}

void GetCurrentStatus(bool active, bool configured, bool exists, bool lastMatchesCurrent, char[] status, int statusSize)
{
	if (!active)
	{
		strcopy(status, statusSize, "inactive for current stripper/config");
		return;
	}

	if (!configured)
	{
		strcopy(status, statusSize, "no configured variant for this map");
		return;
	}

	if (!exists)
	{
		strcopy(status, statusSize, "configured variant file is missing");
		return;
	}

	if (!lastMatchesCurrent)
	{
		strcopy(status, statusSize, "not attempted for current map/config");
		return;
	}

	strcopy(status, statusSize, g_sLastStatus);
}

void ResetLastStatus(const char[] status)
{
	g_bPendingNavRead = false;
	g_bLastReadWasRedirect = false;
	g_bLastReadSucceeded = false;
	g_sLastMap[0] = '\0';
	g_sLastVariant[0] = '\0';
	g_sLastStripperPath[0] = '\0';
	g_sLastOriginal[0] = '\0';
	g_sLastReplacement[0] = '\0';
	strcopy(g_sLastStatus, sizeof(g_sLastStatus), status);
}

void SaveLastStatus(const char[] mapName, const char[] variantName, const char[] original, const char[] replacement, const char[] status)
{
	g_bLastReadWasRedirect = false;
	g_bLastReadSucceeded = false;
	strcopy(g_sLastMap, sizeof(g_sLastMap), mapName);
	strcopy(g_sLastVariant, sizeof(g_sLastVariant), variantName);
	GetCurrentStripperPath(g_sLastStripperPath, sizeof(g_sLastStripperPath));
	strcopy(g_sLastOriginal, sizeof(g_sLastOriginal), original);
	strcopy(g_sLastReplacement, sizeof(g_sLastReplacement), replacement);
	strcopy(g_sLastStatus, sizeof(g_sLastStatus), status);
}

void QueueClearNavCache(const char[] reason)
{
	strcopy(g_sClearReason, sizeof(g_sClearReason), reason);
	if (g_bClearQueued)
	{
		return;
	}

	g_bClearQueued = true;
	RequestFrame(Frame_ClearNavCache);
}

void Frame_ClearNavCache(any data)
{
	g_bClearQueued = false;
	ClearNavCache(g_sClearReason);
}

void ClearNavCache(const char[] reason)
{
	if (g_hSDKReleaseCachedNavData == null || g_pNavMesh == Address_Null)
	{
		return;
	}

	SDKCall(g_hSDKReleaseCachedNavData, g_pNavMesh);
	DebugLog("Cleared nav cache: %s", reason);
}

void DebugLog(const char[] format, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogMessage("%s", buffer);
}
