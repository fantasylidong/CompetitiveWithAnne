#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#define STEAMID_SIZE 32

#define L4D_TEAM_SPECTATE 1
#define L4D_TEAM_SURVIVORS 2
#define LERP_RECHECK_INTERVAL 0.5
#define LERP_LEGAL_CONFIRMATIONS 2

StringMap
    ArrLerpsValue = null,
    ArrLerpsCountChanges = null;

ConVar
    cVarReadyUpLerpChanges = null,
    cVarAllowedLerpChanges = null,
    cVarLerpChangeSpec = null,
    cVarBadLerpAction = null,
    cVarMinLerp = null,
    cVarMaxLerp = null,
    cVarMinUpdateRate = null,
    cVarMaxUpdateRate = null,
    cVarMinInterpRatio = null,
    cVarMaxInterpRatio = null,
    cVarShowLerpTeamChange = null;

bool
    IsLateLoad = false,
    isFirstHalf = true,
    isMatchLife = true,
    isTransfer = false;

// 增加：用于记录玩家的5秒警告定时器
Handle g_hLerpWarningTimer[MAXPLAYERS + 1] = { null, ... };
bool g_bLerpWarningActive[MAXPLAYERS + 1];
int g_iLerpLegalConfirmations[MAXPLAYERS + 1];
int g_iLerpWarningGeneration[MAXPLAYERS + 1];
float g_fQueriedUpdateRate[MAXPLAYERS + 1];
float g_fQueriedInterpRatio[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "LerpMonitor++",
    author = "ProdigySim, Die Teetasse, vintik, A1m`, Modified by Gemini",
    description = "Keep track of players' lerp settings with 5s warning",
    version = "2.4.5",
    url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    IsLateLoad = late;

    CreateNative("LM_GetLerpTime", LM_GetLerpTime);
    CreateNative("LM_GetCurrentLerpTime", LM_GetCurrentLerpTime);
    CreateNative("LM_GetStoredLerpTime", LM_GetStoredLerpTime);

    RegPluginLibrary("lerpmonitor");
    return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("lerpmonitor.phrases");
    cVarAllowedLerpChanges = CreateConVar("sm_allowed_lerp_changes", "1", "Allowed number of lerp changes for a half", _, true, 0.0, true, 20.0);
    cVarLerpChangeSpec = CreateConVar("sm_lerp_change_spec", "1", "Move to spectators on exceeding lerp changes count?", _, true, 0.0, true, 1.0);
    cVarBadLerpAction = CreateConVar("sm_bad_lerp_action", "1", "What to do with a player if he is out of allowed lerp range? 1 - move to spectators, 0 - kick from server", _, true, 0.0, true, 1.0);
    cVarReadyUpLerpChanges = CreateConVar("sm_readyup_lerp_changes", "1", "Allow lerp changes during ready-up", _, true, 0.0, true, 1.0);
    cVarShowLerpTeamChange = CreateConVar("sm_show_lerp_team_changes", "1", "show a message about the player's lerp if he changes the team", _, true, 0.0, true, 1.0);
    cVarMinLerp = CreateConVar("sm_min_lerp", "0.000", "Minimum allowed lerp value", _, true, 0.000, true, 0.500);
    cVarMaxLerp = CreateConVar("sm_max_lerp", "0.067", "Maximum allowed lerp value", _, true, 0.000, true, 0.500);

    RegConsoleCmd("sm_lerps", Lerps_Cmd, "List the Lerps of all players in game");

    cVarMinUpdateRate = FindConVar("sv_minupdaterate");
    cVarMaxUpdateRate = FindConVar("sv_maxupdaterate");
    cVarMinInterpRatio = FindConVar("sv_client_min_interp_ratio");
    cVarMaxInterpRatio = FindConVar("sv_client_max_interp_ratio");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("player_team", OnTeamChange, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
    HookEvent("player_left_start_area", Event_RoundGoesLive, EventHookMode_PostNoCopy);

    ArrLerpsValue = new StringMap();
    ArrLerpsCountChanges = new StringMap();

    LateLoad();
}

void LateLoad()
{
    if (!IsLateLoad) {
        return;
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i) || IsFakeClient(i)) {
            continue;
        }
        ProcessPlayerLerp(i, true);
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client)) {
        CreateTimer(1.0, Process, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// 增加：玩家断开连接时清理定时器，防止报错
public void OnClientDisconnect(int client)
{
    ResetLerpWarning(client);
}

Action Process(Handle hTimer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0) {
        ProcessPlayerLerp(client);
    }
    return Plugin_Stop;
}

public void OnMapStart()
{
    isMatchLife = false;
}

public void OnMapEnd()
{
    isFirstHalf = true;
    ArrLerpsValue.Clear();
    ArrLerpsCountChanges.Clear();

    for (int client = 1; client <= MaxClients; client++) {
        ResetLerpWarning(client);
    }
}

void Event_RoundGoesLive(Event hEvent, const char[] name, bool dontBroadcast)
{
    isMatchLife = true;
}

public void OnClientSettingsChanged(int client)
{
    if (IsValidEdict(client) && !IsFakeClient(client)) {
        ProcessPlayerLerp(client);
    }
}

void Event_PlayerDisconnect(Event hEvent, const char[] name, bool dontBroadcast)
{
    char SteamID[64];
    hEvent.GetString("networkid", SteamID, sizeof(SteamID));

    if (StrContains(SteamID, "STEAM") != 0) {
        return;
    }

    ArrLerpsValue.Remove(SteamID);
}

void OnTeamChange(Event hEvent, const char[] eName, bool dontBroadcast)
{
    if (hEvent.GetInt("team") > L4D_TEAM_SPECTATE) {
        int userid = hEvent.GetInt("userid");
        int client = GetClientOfUserId(userid);
        if (client > 0 && IsClientInGame(client) && !IsFakeClient(client)) {
            if (!isTransfer) {
                CreateTimer(0.1, OnTeamChangeDelay, userid, TIMER_FLAG_NO_MAPCHANGE);
            }
        }
    }
}

Action OnTeamChangeDelay(Handle hTimer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0) {
        ProcessPlayerLerp(client, false, true);
    }
    return Plugin_Stop;
}

void Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast)
{
    CreateTimer(0.5, Timer_RoundEndDelay, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_RoundEndDelay(Handle hTimer)
{
    isFirstHalf = false;
    isTransfer = true;
    isMatchLife = false;
    ArrLerpsCountChanges.Clear();
    return Plugin_Stop;
}

Action Lerps_Cmd(int client, int args)
{
    int iCount = 0;
    if (ArrLerpsValue.Size > 0) {
        ReplyToCommand(client, "[!] Lerp setting list:");

        float fLerpValue;
        char sSteamID[STEAMID_SIZE];
        for (int i = 1; i <= MaxClients; i++) {
            if (IsClientInGame(i) && !IsFakeClient(i)) {
                GetClientAuthId(i, AuthId_Steam2, sSteamID, sizeof(sSteamID));

                if (ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
                    ReplyToCommand(client, "%N [%s]: %.01f", i, sSteamID, fLerpValue * 1000);
                    iCount++;
                }
            }
        }
    }

    if (iCount == 0) {
        ReplyToCommand(client, "There is nothing here!");
    }

    return Plugin_Handled;
}

void Event_RoundStart(Event hEvent, const char[] name, bool dontBroadcast)
{
    if (!isFirstHalf) {
        ArrLerpsCountChanges.Clear();
    }
    CreateTimer(0.5, OnTransfer, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action OnTransfer(Handle hTimer)
{
    isTransfer = false;
    return Plugin_Stop;
}

void ProcessPlayerLerp(int client, bool load = false, bool team = false)
{
    float newLerpTime;
    if (!TryGetLerpTime(client, newLerpTime)) {
        return;
    }

    if (GetClientTeam(client) < L4D_TEAM_SURVIVORS) {
        SetEntPropFloat(client, Prop_Data, "m_fLerpTime", newLerpTime);
        return;
    }

    if (!IsLerpInAllowedRange(newLerpTime)) {
        SetEntPropFloat(client, Prop_Data, "m_fLerpTime", newLerpTime);
        g_iLerpLegalConfirmations[client] = 0;

        if (load) {
            return;
        }

        if (!g_bLerpWarningActive[client]) {
            g_bLerpWarningActive[client] = true;
            g_iLerpWarningGeneration[client]++;
            CPrintToChatEx(client, client, "%t", "Lerpmonitor_LerpWarningLerpValueIllegal", cVarMinLerp.FloatValue * 1000, cVarMaxLerp.FloatValue * 1000);
            ScheduleLerpRecheck(client, 5.0);
        }
        return;
    }

    if (g_bLerpWarningActive[client]) {
        return;
    }

    ApplyPlayerLerp(client, newLerpTime, team);
}

void ApplyPlayerLerp(int client, float newLerpTime, bool team = false)
{
    SetEntPropFloat(client, Prop_Data, "m_fLerpTime", newLerpTime);

    if (GetClientTeam(client) < L4D_TEAM_SURVIVORS) {
        return;
    }

    char steamID[STEAMID_SIZE];
    if (!GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID)) || steamID[0] == '\0') {
        return;
    }

    float currentLerpTime = 0.0;
    if (!ArrLerpsValue.GetValue(steamID, currentLerpTime)) {
        if (team && cVarShowLerpTeamChange.BoolValue) {
            CPrintToChatAllEx(client, "%t", "Lerpmonitor_Lerp", client, newLerpTime * 1000);
        }
        ArrLerpsValue.SetValue(steamID, newLerpTime, true);
        return;
    }

    if (currentLerpTime == newLerpTime) { 
        if (team && cVarShowLerpTeamChange.BoolValue) {
            CPrintToChatAllEx(client, "%t", "Lerpmonitor_Lerp", client, newLerpTime * 1000);
        }
        return;
    }

    if (isMatchLife || !cVarReadyUpLerpChanges.BoolValue) { 
        int count = 0;
        ArrLerpsCountChanges.GetValue(steamID, count);
        count++;

        int max = cVarAllowedLerpChanges.IntValue;
        CPrintToChatAllEx(client, "%t", "Lerpmonitor_LerpChanges", client, newLerpTime * 1000, currentLerpTime * 1000, ((count > max) ? "{teamcolor} ": ""), count, max);

        if (cVarLerpChangeSpec.BoolValue && (count > max)) {
            CPrintToChatAllEx(client, "%t", "Lerpmonitor_LerpMovedSpectatorIllegalLerp", client);
            ChangeClientTeam(client, L4D_TEAM_SPECTATE);
            CPrintToChatEx(client, client, "%t", "Lerpmonitor_LerpIllegalChangeLerpGame", currentLerpTime * 1000);
            return;
        }

        ArrLerpsCountChanges.SetValue(steamID, count); 
    } else {
        CPrintToChatAllEx(client, "%t", "Lerpmonitor_Lerp_2", client, newLerpTime * 1000, currentLerpTime * 1000);
    }

    ArrLerpsValue.SetValue(steamID, newLerpTime); 
}

Action Timer_CheckBadLerpRange(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) {
        return Plugin_Stop;
    }

    if (g_hLerpWarningTimer[client] != timer) {
        return Plugin_Stop;
    }

    g_hLerpWarningTimer[client] = null;
    if (!g_bLerpWarningActive[client]) {
        return Plugin_Stop;
    }

    if (GetClientTeam(client) < L4D_TEAM_SURVIVORS) {
        g_iLerpLegalConfirmations[client] = 0;
        ScheduleLerpRecheck(client, LERP_RECHECK_INTERVAL);
        return Plugin_Stop;
    }

    BeginClientLerpQuery(client);
    return Plugin_Stop;
}

void ScheduleLerpRecheck(int client, float delay)
{
    if (!g_bLerpWarningActive[client] || !IsClientInGame(client)) {
        return;
    }

    if (g_hLerpWarningTimer[client] != null) {
        KillTimer(g_hLerpWarningTimer[client]);
    }

    g_hLerpWarningTimer[client] = CreateTimer(delay, Timer_CheckBadLerpRange, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

void ResetLerpWarning(int client)
{
    if (g_hLerpWarningTimer[client] != null) {
        KillTimer(g_hLerpWarningTimer[client]);
        g_hLerpWarningTimer[client] = null;
    }

    g_bLerpWarningActive[client] = false;
    g_iLerpLegalConfirmations[client] = 0;
    g_iLerpWarningGeneration[client]++;
    g_fQueriedUpdateRate[client] = 0.0;
    g_fQueriedInterpRatio[client] = 0.0;
}

void BeginClientLerpQuery(int client)
{
    QueryCookie cookie = QueryClientConVar(client, "cl_updaterate", ClientLerpQueryFinished, g_iLerpWarningGeneration[client]);
    if (cookie == QUERYCOOKIE_FAILED) {
        RetryClientLerpQuery(client);
    }
}

void RetryClientLerpQuery(int client)
{
    g_iLerpLegalConfirmations[client] = 0;
    ScheduleLerpRecheck(client, LERP_RECHECK_INTERVAL);
}

public void ClientLerpQueryFinished(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any generation)
{
    if (client <= 0 || !IsClientInGame(client) || !g_bLerpWarningActive[client]
        || generation != g_iLerpWarningGeneration[client]) {
        return;
    }

    if (GetClientTeam(client) < L4D_TEAM_SURVIVORS) {
        RetryClientLerpQuery(client);
        return;
    }

    float parsedValue;
    if (result != ConVarQuery_Okay || !TryParseClientFloat(cvarValue, parsedValue)) {
        RetryClientLerpQuery(client);
        return;
    }

    if (StrEqual(cvarName, "cl_updaterate")) {
        g_fQueriedUpdateRate[client] = parsedValue;
        if (QueryClientConVar(client, "cl_interp_ratio", ClientLerpQueryFinished, generation) == QUERYCOOKIE_FAILED) {
            RetryClientLerpQuery(client);
        }
        return;
    }

    if (StrEqual(cvarName, "cl_interp_ratio")) {
        g_fQueriedInterpRatio[client] = parsedValue;
        if (QueryClientConVar(client, "cl_interp", ClientLerpQueryFinished, generation) == QUERYCOOKIE_FAILED) {
            RetryClientLerpQuery(client);
        }
        return;
    }

    float queriedLerpTime;
    if (!StrEqual(cvarName, "cl_interp")
        || !TryCalculateLerpTime(g_fQueriedUpdateRate[client], g_fQueriedInterpRatio[client], parsedValue, queriedLerpTime)) {
        RetryClientLerpQuery(client);
        return;
    }

    LogMessage("[LerpMonitor] Queried %L: cl_updaterate=%.3f cl_interp_ratio=%.3f cl_interp=%.6f lerp=%.3fms",
        client, g_fQueriedUpdateRate[client], g_fQueriedInterpRatio[client], parsedValue, queriedLerpTime * 1000.0);

    if (!IsLerpInAllowedRange(queriedLerpTime)) {
        ResetLerpWarning(client);
        if (cVarBadLerpAction.IntValue == 1) {
            CPrintToChatAllEx(client, "%t", "Lerpmonitor_LerpMovedBystanderDueFailure", client);
            ChangeClientTeam(client, L4D_TEAM_SPECTATE);
        } else {
            CPrintToChatAllEx(client, "%t", "Lerpmonitor_LerpKickedGameHeFailed", client);
            KickClient(client, "Illegal lerp value (min: %.01f, max: %.01f)", cVarMinLerp.FloatValue * 1000, cVarMaxLerp.FloatValue * 1000);
        }
        return;
    }

    g_iLerpLegalConfirmations[client]++;
    if (g_iLerpLegalConfirmations[client] < LERP_LEGAL_CONFIRMATIONS) {
        ScheduleLerpRecheck(client, LERP_RECHECK_INTERVAL);
        return;
    }

    ResetLerpWarning(client);
    CPrintToChatEx(client, client, "%t", "Lerpmonitor_LerpThanksCooperationLerpRestored");
    ApplyPlayerLerp(client, queriedLerpTime);
}

bool TryGetClientInfoFloat(int client, const char[] key, float &value)
{
    char buffer[64];

    if (!GetClientInfo(client, key, buffer, sizeof(buffer))) {
        return false;
    }

    return TryParseClientFloat(buffer, value);
}

bool TryParseClientFloat(const char[] buffer, float &value)
{
    return buffer[0] != '\0'
        && StringToFloatEx(buffer, value) == strlen(buffer)
        && value == value;
}

bool TryGetLerpTime(int client, float &lerpTime)
{
    float clientUpdateRate;
    float flLerpRatio;
    float flLerpAmount;

    if (!TryGetClientInfoFloat(client, "cl_updaterate", clientUpdateRate)
        || !TryGetClientInfoFloat(client, "cl_interp_ratio", flLerpRatio)
        || !TryGetClientInfoFloat(client, "cl_interp", flLerpAmount)) {
        return false;
    }

    return TryCalculateLerpTime(clientUpdateRate, flLerpRatio, flLerpAmount, lerpTime);
}

bool TryCalculateLerpTime(float clientUpdateRate, float flLerpRatio, float flLerpAmount, float &lerpTime)
{
    if (cVarMinUpdateRate == null || cVarMaxUpdateRate == null) {
        return false;
    }

    int updateRate = RoundFloat(clientUpdateRate);
    updateRate = RoundFloat(clamp(float(updateRate), cVarMinUpdateRate.FloatValue, cVarMaxUpdateRate.FloatValue));
    if (updateRate <= 0) {
        return false;
    }

    if (cVarMinInterpRatio != null && cVarMaxInterpRatio != null && cVarMinInterpRatio.FloatValue != -1.0) {
        flLerpRatio = clamp(flLerpRatio, cVarMinInterpRatio.FloatValue, cVarMaxInterpRatio.FloatValue);
    }

    lerpTime = maximum(flLerpAmount, flLerpRatio / updateRate);
    return true;
}

bool IsLerpInAllowedRange(float lerpTime)
{
    return FloatCompare(lerpTime, cVarMinLerp.FloatValue) != -1
        && FloatCompare(lerpTime, cVarMaxLerp.FloatValue) != 1;
}

float maximum(float a, float b)
{
    return (a > b) ? a : b;
}

float clamp(float inc, float low, float high)
{
    return (inc > high) ? high : ((inc < low) ? low : inc);
}

int LM_GetLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);

    char sSteamID[STEAMID_SIZE];
    float fLerpValue = -1.0;
    if (GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID))
        && sSteamID[0] != '\0'
        && ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
        return view_as<int>(fLerpValue);
    }

    if (TryGetLerpTime(client, fLerpValue)) {
        return view_as<int>(fLerpValue);
    }

    return view_as<int>(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));
}

int LM_GetCurrentLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    float fLerpValue;
    if (TryGetLerpTime(client, fLerpValue)) {
        return view_as<int>(fLerpValue);
    }

    return view_as<int>(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));
}

int LM_GetStoredLerpTime(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);

    char sSteamID[STEAMID_SIZE];
    float fLerpValue = -1.0;
    if (GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID))
        && sSteamID[0] != '\0'
        && ArrLerpsValue.GetValue(sSteamID, fLerpValue)) {
        return view_as<int>(fLerpValue);
    }

    return view_as<int>(-1.0);
}
