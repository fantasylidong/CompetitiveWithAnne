#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#undef REQUIRE_EXTENSIONS
#include <SteamWorks>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION "1.1.7"
#define MAX_REPORT_SAMPLES 128
#define NET_PROBE_INTERVAL 1.0

enum NetworkMetric
{
	MetricLatencyIncoming = 0,
	MetricLatencyOutgoing,
	MetricLossIncoming,
	MetricLossOutgoing,
	MetricChokeIncoming,
	MetricChokeOutgoing,
	MetricPacketsIncoming,
	MetricPacketsOutgoing,
	NetworkMetricCount
};

ConVar
	g_hEnable,
	g_hCheckInterval,
	g_hPingLimit,
	g_hLossLimit,
	g_hChokeLimit,
	g_hBadSamples,
	g_hWarnCooldown,
	g_hIpPageUrl,
	g_hIntroDelay,
	g_hReportEnable,
	g_hReportUrl,
	g_hReportInterval,
	g_hReportChokeLimit,
	g_hReportLossLimit,
	g_hReportBadSamples,
	g_hReportRecoverySamples;

Handle g_hTimer;
int g_iProbeTicks;

bool g_bEnable;
bool g_bReportEnable;
float g_fCheckInterval;
int g_iPingLimit;
float g_fLossLimit;
float g_fChokeLimit;
int g_iBadSamples;
float g_fWarnCooldown;
float g_fIntroDelay;
int g_iReportInterval;
float g_fReportChokeLimit;
float g_fReportLossLimit;
int g_iReportBadSamples;
int g_iReportRecoverySamples;
char g_sIpPageUrl[192];
char g_sReportUrl[256];

int g_iBadCount[MAXPLAYERS + 1];
int g_iWarnCount[MAXPLAYERS + 1];
int g_iGoodCount[MAXPLAYERS + 1];
float g_fLastWarnAt[MAXPLAYERS + 1];
bool g_bIncidentActive[MAXPLAYERS + 1];
bool g_bDisconnectReported[MAXPLAYERS + 1];
int g_iSessionStartedAt[MAXPLAYERS + 1];
int g_iWindowStartedAt[MAXPLAYERS + 1];
int g_iSampleCount[MAXPLAYERS + 1];
int g_iBadSampleCount[MAXPLAYERS + 1];
int g_iTimeoutSampleCount[MAXPLAYERS + 1];
int g_iMaxConsecutiveBad[MAXPLAYERS + 1];
char g_sPlayerIp[MAXPLAYERS + 1][46];
char g_sPlayerSteamId[MAXPLAYERS + 1][32];

float g_fProbeSum[MAXPLAYERS + 1][NetworkMetricCount];
float g_fProbePeak[MAXPLAYERS + 1][NetworkMetricCount];
int g_iProbeCount[MAXPLAYERS + 1][NetworkMetricCount];
bool g_bProbeTimingOut[MAXPLAYERS + 1];

float g_fMetricSum[MAXPLAYERS + 1][NetworkMetricCount];
float g_fMetricMax[MAXPLAYERS + 1][NetworkMetricCount];
float g_fMetricSamples[MAXPLAYERS + 1][NetworkMetricCount][MAX_REPORT_SAMPLES];
int g_iMetricValidCount[MAXPLAYERS + 1][NetworkMetricCount];
int g_iMetricStoredCount[MAXPLAYERS + 1][NetworkMetricCount];
int g_iMetricWriteIndex[MAXPLAYERS + 1][NetworkMetricCount];

float g_fLastReportErrorAt;

public Plugin myinfo =
{
	name = "Network Quality Hint",
	author = "Anne",
	description = "Samples player network quality, reports summaries and incidents, and shows reconnect hints.",
	version = PLUGIN_VERSION,
	url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
	LoadTranslations("network_quality_hint.phrases");
	CreateConVar("nqh_version", PLUGIN_VERSION, "Network Quality Hint version.", FCVAR_NONE | FCVAR_DONTRECORD);

	g_hEnable = CreateConVar("nqh_enable", "1", "Enable network quality checks.", _, true, 0.0, true, 1.0);
	g_hCheckInterval = CreateConVar("nqh_check_interval", "5.0", "Seconds between local network checks. Metrics are probed every second and averaged over this window; samples are not uploaded individually.", _, true, 5.0, true, 300.0);
	g_hPingLimit = CreateConVar("nqh_ping_limit", "120", "Warn when ping is higher than this value in ms. -1 disables ping checks.", _, true, -1.0);
	g_hLossLimit = CreateConVar("nqh_loss_limit", "2.0", "Warn when client-to-server packet loss is higher than this percent. -1 disables loss checks.", _, true, -1.0);
	g_hChokeLimit = CreateConVar("nqh_choke_limit", "5.0", "Warn when choke is higher than this percent. -1 disables choke checks.", _, true, -1.0);
	g_hBadSamples = CreateConVar("nqh_bad_samples", "3", "Consecutive bad samples required before warning the player.", _, true, 1.0, true, 20.0);
	g_hWarnCooldown = CreateConVar("nqh_warn_cooldown", "180.0", "Seconds before warning the same player again.", _, true, 30.0, true, 1800.0);
	g_hIpPageUrl = CreateConVar("nqh_ip_page_url", "https://anne.trygek.com/ip.php", "Web page that lists server IPs and copyable connect commands.");
	g_hIntroDelay = CreateConVar("nqh_intro_delay", "25.0", "Seconds after join before printing a one-time status hint. 0 disables it.", _, true, 0.0, true, 300.0);
	g_hReportEnable = CreateConVar("nqh_report_enable", "0", "Enable optional HTTPS player connection quality reports when a URL is configured.", _, true, 0.0, true, 1.0);
	g_hReportUrl = CreateConVar("nqh_report_url", "http://anne.trygek.com/api/player/connection_quality.php", "HTTP endpoint for player connection quality reports.");
	g_hReportInterval = CreateConVar("nqh_report_interval", "600", "Seconds between normal summary reports. Incidents and disconnects report immediately.", _, true, 60.0, true, 3600.0);
	g_hReportChokeLimit = CreateConVar("nqh_report_choke_limit", "20.0", "Report a choke incident only when choke is higher than this percent. -1 disables choke incidents. Local chat warnings still use nqh_choke_limit.", _, true, -1.0);
	g_hReportLossLimit = CreateConVar("nqh_report_loss_limit", "5.0", "Report a loss incident only when client-to-server packet loss is higher than this percent. -1 disables loss incidents. Local chat warnings still use nqh_loss_limit.", _, true, -1.0);
	g_hReportBadSamples = CreateConVar("nqh_report_bad_samples", "1", "Consecutive bad local samples required to report an incident.", _, true, 1.0, true, 20.0);
	g_hReportRecoverySamples = CreateConVar("nqh_report_recovery_samples", "3", "Consecutive good local samples required to report recovery.", _, true, 1.0, true, 20.0);

	RegConsoleCmd("sm_net", Command_NetStatus, "Show your network status.");
	RegConsoleCmd("sm_ping", Command_NetStatus, "Show your network status.");
	RegConsoleCmd("sm_loss", Command_NetStatus, "Show your network status.");
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

	HookConVarChange(g_hEnable, OnCvarChanged);
	HookConVarChange(g_hCheckInterval, OnCvarChanged);
	HookConVarChange(g_hPingLimit, OnCvarChanged);
	HookConVarChange(g_hLossLimit, OnCvarChanged);
	HookConVarChange(g_hChokeLimit, OnCvarChanged);
	HookConVarChange(g_hBadSamples, OnCvarChanged);
	HookConVarChange(g_hWarnCooldown, OnCvarChanged);
	HookConVarChange(g_hIpPageUrl, OnCvarChanged);
	HookConVarChange(g_hIntroDelay, OnCvarChanged);
	HookConVarChange(g_hReportEnable, OnCvarChanged);
	HookConVarChange(g_hReportUrl, OnCvarChanged);
	HookConVarChange(g_hReportInterval, OnCvarChanged);
	HookConVarChange(g_hReportChokeLimit, OnCvarChanged);
	HookConVarChange(g_hReportLossLimit, OnCvarChanged);
	HookConVarChange(g_hReportBadSamples, OnCvarChanged);
	HookConVarChange(g_hReportRecoverySamples, OnCvarChanged);

	AutoExecConfig(true, "network_quality_hint");
	ReadCvars();
	RestartTimer();
	LogReportStatus();
}

public void OnMapStart()
{
	RestartTimer();
}

public void OnMapEnd()
{
	StopTimer();
}

public void OnClientPutInServer(int client)
{
	ResetClientState(client);
	CacheClientIdentity(client);

	if (g_bEnable && g_fIntroDelay > 0.0 && !IsFakeClient(client)) {
		CreateTimer(g_fIntroDelay, Timer_IntroHint, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (client > 0 && client <= MaxClients && !IsFakeClient(client)) {
		CacheClientIdentity(client);
	}
}

public void OnClientDisconnect(int client)
{
	if (!g_bDisconnectReported[client] && g_iSessionStartedAt[client] > 0) {
		SendQualityReport(client, "disconnect", "unknown", "");
	}
	ResetClientState(client);
	g_iSessionStartedAt[client] = 0;
	g_iWindowStartedAt[client] = 0;
}

Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || g_iSessionStartedAt[client] <= 0 || g_bDisconnectReported[client]) {
		return Plugin_Continue;
	}

	char reason[256];
	event.GetString("reason", reason, sizeof(reason));
	char code[32];
	ClassifyDisconnectReason(reason, code, sizeof(code));
	SendQualityReport(client, "disconnect", code, reason);
	g_bDisconnectReported[client] = true;
	return Plugin_Continue;
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	float oldInterval = g_fCheckInterval;
	ReadCvars();

	if (convar == g_hEnable || convar == g_hCheckInterval || oldInterval != g_fCheckInterval) {
		RestartTimer();
	}
}

void ReadCvars()
{
	g_bEnable = g_hEnable.BoolValue;
	g_bReportEnable = g_hReportEnable.BoolValue;
	g_fCheckInterval = g_hCheckInterval.FloatValue;
	g_iPingLimit = g_hPingLimit.IntValue;
	g_fLossLimit = g_hLossLimit.FloatValue;
	g_fChokeLimit = g_hChokeLimit.FloatValue;
	g_iBadSamples = g_hBadSamples.IntValue;
	g_fWarnCooldown = g_hWarnCooldown.FloatValue;
	g_fIntroDelay = g_hIntroDelay.FloatValue;
	g_iReportInterval = g_hReportInterval.IntValue;
	g_fReportChokeLimit = g_hReportChokeLimit.FloatValue;
	g_fReportLossLimit = g_hReportLossLimit.FloatValue;
	g_iReportBadSamples = g_hReportBadSamples.IntValue;
	g_iReportRecoverySamples = g_hReportRecoverySamples.IntValue;

	g_hIpPageUrl.GetString(g_sIpPageUrl, sizeof(g_sIpPageUrl));
	g_hReportUrl.GetString(g_sReportUrl, sizeof(g_sReportUrl));
}

void RestartTimer()
{
	StopTimer();
	g_iProbeTicks = 0;
	if (g_bEnable) {
		g_hTimer = CreateTimer(NET_PROBE_INTERVAL, Timer_ProbeClients, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

void StopTimer()
{
	if (g_hTimer != null) {
		KillTimer(g_hTimer);
		g_hTimer = null;
	}
}

Action Timer_IntroHint(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (IsHumanInGame(client)) {
		PrintClientStatus(client, false);
	}
	return Plugin_Stop;
}

// Engine loss/choke are ~1 second moving averages. Reading them once per check
// interval only saw a random 1-second slice, so bursty choke (hordes, big
// snapshots) was almost never caught. Probe every second and judge the whole window.
Action Timer_ProbeClients(Handle timer)
{
	if (!g_bEnable) {
		return Plugin_Continue;
	}

	bool check = ++g_iProbeTicks >= RoundToNearest(g_fCheckInterval / NET_PROBE_INTERVAL);
	if (check) {
		g_iProbeTicks = 0;
	}
	for (int client = 1; client <= MaxClients; client++) {
		if (IsHumanInGame(client)) {
			ProbeClient(client);
			if (check) {
				CheckClient(client);
			}
		}
	}
	return Plugin_Continue;
}

void ProbeClient(int client)
{
	AddProbe(client, MetricLatencyIncoming, GetClientAvgLatency(client, NetFlow_Incoming) * 1000.0);
	AddProbe(client, MetricLatencyOutgoing, GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0);
	AddProbe(client, MetricLossIncoming, GetNetworkPctRaw(GetClientAvgLoss(client, NetFlow_Incoming)));
	AddProbe(client, MetricLossOutgoing, GetNetworkPctRaw(GetClientAvgLoss(client, NetFlow_Outgoing)));
	AddProbe(client, MetricChokeIncoming, GetNetworkPctRaw(GetClientAvgChoke(client, NetFlow_Incoming)));
	AddProbe(client, MetricChokeOutgoing, GetNetworkPctRaw(GetClientAvgChoke(client, NetFlow_Outgoing)));
	AddProbe(client, MetricPacketsIncoming, GetClientAvgPackets(client, NetFlow_Incoming));
	AddProbe(client, MetricPacketsOutgoing, GetClientAvgPackets(client, NetFlow_Outgoing));
	if (IsClientTimingOut(client)) {
		g_bProbeTimingOut[client] = true;
	}
}

void AddProbe(int client, NetworkMetric metric, float value)
{
	if (value < 0.0) {
		return;
	}
	if (g_iProbeCount[client][metric] == 0 || value > g_fProbePeak[client][metric]) {
		g_fProbePeak[client][metric] = value;
	}
	g_fProbeSum[client][metric] += value;
	g_iProbeCount[client][metric]++;
}

float GetProbeAverage(int client, NetworkMetric metric)
{
	int count = g_iProbeCount[client][metric];
	return count > 0 ? g_fProbeSum[client][metric] / float(count) : -1.0;
}

void ResetProbeWindow(int client)
{
	g_bProbeTimingOut[client] = false;
	for (int metric = 0; metric < view_as<int>(NetworkMetricCount); metric++) {
		g_fProbeSum[client][metric] = 0.0;
		g_fProbePeak[client][metric] = 0.0;
		g_iProbeCount[client][metric] = 0;
	}
}

void CheckClient(int client)
{
	// The server never learns which of its own packets were dropped, so outgoing
	// loss is always 0. Loss is judged on what the server receives from the player.
	float latencyOutgoing = GetProbeAverage(client, MetricLatencyOutgoing);
	float lossIncoming = GetProbeAverage(client, MetricLossIncoming);
	float chokeOutgoing = GetProbeAverage(client, MetricChokeOutgoing);
	bool timingOut = g_bProbeTimingOut[client];

	for (int metric = 0; metric < view_as<int>(NetworkMetricCount); metric++) {
		AddMetricSample(client, view_as<NetworkMetric>(metric));
	}
	ResetProbeWindow(client);
	g_iSampleCount[client]++;

	int ping = latencyOutgoing < 0.0 ? 0 : RoundToNearest(latencyOutgoing);
	float loss = lossIncoming < 0.0 ? 0.0 : lossIncoming;
	float choke = chokeOutgoing < 0.0 ? 0.0 : chokeOutgoing;
	bool badPing = g_iPingLimit >= 0 && latencyOutgoing >= 0.0 && ping > g_iPingLimit;
	bool warnLoss = g_fLossLimit >= 0.0 && lossIncoming >= 0.0 && lossIncoming > g_fLossLimit;
	bool reportLoss = g_fReportLossLimit >= 0.0 && lossIncoming >= 0.0 && lossIncoming > g_fReportLossLimit;
	bool warnChoke = g_fChokeLimit >= 0.0 && chokeOutgoing >= 0.0 && chokeOutgoing > g_fChokeLimit;
	bool reportChoke = g_fReportChokeLimit >= 0.0 && chokeOutgoing >= 0.0 && chokeOutgoing > g_fReportChokeLimit;
	bool warnBad = timingOut || badPing || warnLoss || warnChoke;
	bool reportBad = timingOut || reportLoss || badPing || reportChoke;

	if (timingOut) {
		g_iTimeoutSampleCount[client]++;
	}
	if (reportBad) {
		g_iBadSampleCount[client]++;
		g_iBadCount[client]++;
		g_iGoodCount[client] = 0;
		if (g_iBadCount[client] > g_iMaxConsecutiveBad[client]) {
			g_iMaxConsecutiveBad[client] = g_iBadCount[client];
		}
		if (!g_bIncidentActive[client] && g_iBadCount[client] >= g_iReportBadSamples) {
			char incidentCode[32];
			ClassifyIncidentReason(timingOut, reportLoss, badPing, reportChoke, incidentCode, sizeof(incidentCode));
			SendQualityReport(client, "incident", incidentCode, "");
			g_bIncidentActive[client] = true;
		}
	} else {
		g_iBadCount[client] = 0;
		g_iGoodCount[client]++;
		if (g_bIncidentActive[client] && g_iGoodCount[client] >= g_iReportRecoverySamples) {
			SendQualityReport(client, "recovery", "recovered", "");
			g_bIncidentActive[client] = false;
			g_iGoodCount[client] = 0;
		}
	}

	if (warnBad) {
		g_iWarnCount[client]++;
		MaybeWarnPlayer(client, ping, loss, choke, badPing, warnLoss, warnChoke);
	} else {
		g_iWarnCount[client] = 0;
	}

	if (g_iWindowStartedAt[client] > 0 && GetTime() - g_iWindowStartedAt[client] >= g_iReportInterval) {
		SendQualityReport(client, "summary", "periodic", "");
	}
}

void MaybeWarnPlayer(int client, int ping, float loss, float choke, bool badPing, bool badLoss, bool badChoke)
{
	if (g_iWarnCount[client] < g_iBadSamples) {
		return;
	}
	float now = GetEngineTime();
	if (now - g_fLastWarnAt[client] < g_fWarnCooldown) {
		return;
	}
	g_fLastWarnAt[client] = now;
	PrintNetworkWarning(client, ping, loss, choke, badPing, badLoss, badChoke);
}

Action Command_NetStatus(int client, int args)
{
	if (client <= 0) {
		ReplyToCommand(client, "[Network] This command is only available in game.");
		return Plugin_Handled;
	}
	if (!IsClientInGame(client)) {
		return Plugin_Handled;
	}
	PrintClientStatus(client, true);
	return Plugin_Handled;
}

void PrintClientStatus(int client, bool includeRouteHint)
{
	int ping = GetClientPingMs(client);
	float loss = GetClientLossPct(client);
	float choke = GetClientChokePct(client);
	char tag[64];
	FormatEx(tag, sizeof(tag), "%T", "NetworkQualityHint_Tag", client);
	CPrintToChat(client, "%t", "NetworkQualityHint_CurrentNetworkPingMSLoss", tag, ping, loss, choke);

	if (includeRouteHint) {
		float clientChoke = GetClientIncomingChokePct(client);
		char pageUrl[512];
		BuildServerPageUrl(pageUrl, sizeof(pageUrl));
		CPrintToChat(client, "%t", "NetworkQualityHint_DetectionCaliberChokeUseDirection", tag, clientChoke);
		CPrintToChat(client, "%t", "NetworkQualityHint_AbnormalDelayPacketLossOpen", tag, pageUrl);
	}
}

void PrintNetworkWarning(int client, int ping, float loss, float choke, bool badPing, bool badLoss, bool badChoke)
{
	char tag[64];
	char reason[192];
	char pageUrl[512];
	FormatEx(tag, sizeof(tag), "%T", "NetworkQualityHint_Tag", client);
	BuildReason(client, reason, sizeof(reason), badPing, badLoss, badChoke);
	BuildServerPageUrl(pageUrl, sizeof(pageUrl));
	CPrintToChat(client, "%t", "NetworkQualityHint_AbnormalityNetworkStatusDetectedCurrent", tag, reason, ping, loss, choke);
	CPrintToChat(client, "%t", "NetworkQualityHint_OpenIPPageCopyConnect", tag, pageUrl);
	CPrintToChat(client, "%t", "NetworkQualityHint_ThirdLineServersGivePriority", tag);
}

// One report sample per check window: the window average feeds avg/p95, the
// highest 1-second probe feeds max.
void AddMetricSample(int client, NetworkMetric metric)
{
	if (g_iProbeCount[client][metric] <= 0) {
		return;
	}
	float value = GetProbeAverage(client, metric);
	float peak = g_fProbePeak[client][metric];
	g_fMetricSum[client][metric] += value;
	if (g_iMetricValidCount[client][metric] == 0 || peak > g_fMetricMax[client][metric]) {
		g_fMetricMax[client][metric] = peak;
	}
	g_iMetricValidCount[client][metric]++;
	int index = g_iMetricWriteIndex[client][metric];
	g_fMetricSamples[client][metric][index] = value;
	g_iMetricWriteIndex[client][metric] = (index + 1) % MAX_REPORT_SAMPLES;
	if (g_iMetricStoredCount[client][metric] < MAX_REPORT_SAMPLES) {
		g_iMetricStoredCount[client][metric]++;
	}
}

float GetMetricAverage(int client, NetworkMetric metric)
{
	int count = g_iMetricValidCount[client][metric];
	return count > 0 ? g_fMetricSum[client][metric] / float(count) : -1.0;
}

float GetMetricP95(int client, NetworkMetric metric)
{
	int count = g_iMetricStoredCount[client][metric];
	if (count <= 0) {
		return -1.0;
	}
	float values[MAX_REPORT_SAMPLES];
	for (int i = 0; i < count; i++) {
		values[i] = g_fMetricSamples[client][metric][i];
	}
	for (int i = 1; i < count; i++) {
		float value = values[i];
		int j = i - 1;
		while (j >= 0 && values[j] > value) {
			values[j + 1] = values[j];
			j--;
		}
		values[j + 1] = value;
	}
	int index = RoundToCeil(float(count) * 0.95) - 1;
	return values[index < 0 ? 0 : index];
}

void SendQualityReport(int client, const char[] eventKind, const char[] disconnectCode, const char[] disconnectReason)
{
	if (g_iSampleCount[client] <= 0 && !StrEqual(eventKind, "disconnect")) {
		return;
	}
	int now = GetTime();
	if (!CanReportQuality()) {
		ResetReportWindow(client, now);
		return;
	}

	CacheClientIdentity(client);
	if (g_sPlayerIp[client][0] == '\0') {
		ResetReportWindow(client, now);
		return;
	}
	Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, g_sReportUrl);
	if (request == null) {
		LogReportFailure("unable to create SteamWorks HTTP request");
		ResetReportWindow(client, now);
		return;
	}

	SteamWorks_SetHTTPRequestHeaderValue(request, "Accept", "application/json");
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "schema_version", "1");

	char serverId[256], serverName[256], mapName[64];
	int serverPort;
	GetReportServerIdentity(serverId, sizeof(serverId), serverName, sizeof(serverName), serverPort);
	GetCurrentMap(mapName, sizeof(mapName));
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "server_id", serverId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "server_name", serverName);
	SetRequestInt(request, "server_port", serverPort);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "map_name", mapName);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "player_ip", g_sPlayerIp[client]);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "steam_id", g_sPlayerSteamId[client]);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "event_kind", eventKind);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "disconnect_code", disconnectCode);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, "disconnect_reason", disconnectReason);
	SetRequestInt(request, "window_started_at", g_iWindowStartedAt[client] > 0 ? g_iWindowStartedAt[client] : now);
	SetRequestInt(request, "window_ended_at", now);
	SetRequestInt(request, "captured_at", now);
	SetRequestInt(request, "connection_seconds", g_iSessionStartedAt[client] > 0 ? now - g_iSessionStartedAt[client] : 0);
	SetRequestInt(request, "sample_count", g_iSampleCount[client]);
	SetRequestInt(request, "bad_sample_count", g_iBadSampleCount[client]);
	SetRequestInt(request, "timeout_sample_count", g_iTimeoutSampleCount[client]);
	SetRequestInt(request, "max_consecutive_bad", g_iMaxConsecutiveBad[client]);

	SetRequestMetric(request, "latency_in", client, MetricLatencyIncoming, true);
	SetRequestMetric(request, "latency_out", client, MetricLatencyOutgoing, true);
	SetRequestMetric(request, "loss_in", client, MetricLossIncoming, true);
	SetRequestMetric(request, "loss_out", client, MetricLossOutgoing, true);
	SetRequestMetric(request, "choke_in", client, MetricChokeIncoming, true);
	SetRequestMetric(request, "choke_out", client, MetricChokeOutgoing, true);
	SetRequestMetric(request, "packets_in", client, MetricPacketsIncoming, false);
	SetRequestMetric(request, "packets_out", client, MetricPacketsOutgoing, false);

	SteamWorks_SetHTTPCallbacks(request, OnQualityReportCompleted);
	if (!SteamWorks_SendHTTPRequest(request)) {
		delete request;
		LogReportFailure("unable to send SteamWorks HTTP request");
	}
	ResetReportWindow(client, now);
}

void SetRequestMetric(Handle request, const char[] prefix, int client, NetworkMetric metric, bool includeDistribution)
{
	char name[48];
	FormatEx(name, sizeof(name), "%s_avg", prefix);
	SetRequestFloat(request, name, GetMetricAverage(client, metric));
	if (includeDistribution) {
		FormatEx(name, sizeof(name), "%s_p95", prefix);
		SetRequestFloat(request, name, GetMetricP95(client, metric));
		FormatEx(name, sizeof(name), "%s_max", prefix);
		SetRequestFloat(request, name, g_iMetricValidCount[client][metric] > 0 ? g_fMetricMax[client][metric] : -1.0);
	}
}

void SetRequestInt(Handle request, const char[] name, int value)
{
	char buffer[32];
	IntToString(value, buffer, sizeof(buffer));
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, name, buffer);
}

void SetRequestFloat(Handle request, const char[] name, float value)
{
	char buffer[32];
	FormatEx(buffer, sizeof(buffer), "%.3f", value);
	SteamWorks_SetHTTPRequestGetOrPostParameter(request, name, buffer);
}

public void OnQualityReportCompleted(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
	if (failure || !requestSuccessful || view_as<int>(statusCode) < 200 || view_as<int>(statusCode) >= 300) {
		char message[96];
		FormatEx(message, sizeof(message), "HTTP report failed (status %d)", view_as<int>(statusCode));
		LogReportFailure(message);
	}
	delete request;
}

bool CanReportQuality()
{
	return g_bReportEnable
			&& g_sReportUrl[0] != '\0'
			&& GetFeatureStatus(FeatureType_Native, "SteamWorks_CreateHTTPRequest") == FeatureStatus_Available;
}

void LogReportStatus()
{
	if (!g_bReportEnable) {
		LogMessage("[network-quality] reporting disabled (nqh_report_enable 0); local checks still run");
		return;
	}
	if (g_sReportUrl[0] == '\0') {
		LogError("[network-quality] nqh_report_enable is 1 but nqh_report_url is empty");
		return;
	}
	if (GetFeatureStatus(FeatureType_Native, "SteamWorks_CreateHTTPRequest") != FeatureStatus_Available) {
		LogError("[network-quality] nqh_report_enable is 1 but SteamWorks HTTP is unavailable");
		return;
	}
	LogMessage("[network-quality] reporting enabled -> %s", g_sReportUrl);
}

void LogReportFailure(const char[] message)
{
	float now = GetEngineTime();
	if (now - g_fLastReportErrorAt >= 60.0) {
		LogError("[network-quality] %s", message);
		g_fLastReportErrorAt = now;
	}
}

void CacheClientIdentity(int client)
{
	if (client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client)) {
		return;
	}
	char playerIp[46];
	if (GetClientIP(client, playerIp, sizeof(playerIp), true)) {
		strcopy(g_sPlayerIp[client], sizeof(g_sPlayerIp[]), playerIp);
	}
	char steamId[32];
	if (GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true)) {
		strcopy(g_sPlayerSteamId[client], sizeof(g_sPlayerSteamId[]), steamId);
	}
}

void GetReportServerIdentity(char[] serverId, int serverIdLength, char[] serverName, int serverNameLength, int &serverPort)
{
	ConVar hostname = FindConVar("hostname");
	if (hostname != null) {
		hostname.GetString(serverName, serverNameLength);
	} else {
		strcopy(serverName, serverNameLength, "unknown");
	}
	ConVar hostport = FindConVar("hostport");
	serverPort = hostport == null ? 0 : hostport.IntValue;
	int modeStart = FindCharInString(serverName, '[');
	if (modeStart >= 0) {
		serverName[modeStart] = '\0';
	}
	TrimString(serverName);
	if (serverName[0] == '\0') {
		strcopy(serverName, serverNameLength, "unknown");
	}
	strcopy(serverId, serverIdLength, serverName);
}

void ResetClientState(int client)
{
	g_iBadCount[client] = 0;
	g_iWarnCount[client] = 0;
	g_iGoodCount[client] = 0;
	g_fLastWarnAt[client] = 0.0;
	g_bIncidentActive[client] = false;
	g_bDisconnectReported[client] = false;
	g_iSessionStartedAt[client] = GetTime();
	g_sPlayerIp[client][0] = '\0';
	g_sPlayerSteamId[client][0] = '\0';
	ResetProbeWindow(client);
	ResetReportWindow(client, g_iSessionStartedAt[client]);
}

void ResetReportWindow(int client, int startedAt)
{
	g_iWindowStartedAt[client] = startedAt;
	g_iSampleCount[client] = 0;
	g_iBadSampleCount[client] = 0;
	g_iTimeoutSampleCount[client] = 0;
	g_iMaxConsecutiveBad[client] = 0;
	for (int metric = 0; metric < view_as<int>(NetworkMetricCount); metric++) {
		g_fMetricSum[client][metric] = 0.0;
		g_fMetricMax[client][metric] = 0.0;
		g_iMetricValidCount[client][metric] = 0;
		g_iMetricStoredCount[client][metric] = 0;
		g_iMetricWriteIndex[client][metric] = 0;
	}
}

void ClassifyIncidentReason(bool timingOut, bool badLoss, bool badPing, bool reportChoke, char[] code, int maxlen)
{
	if (timingOut) {
		strcopy(code, maxlen, "timing_out");
	} else if (badLoss) {
		strcopy(code, maxlen, "loss");
	} else if (badPing) {
		strcopy(code, maxlen, "ping");
	} else if (reportChoke) {
		strcopy(code, maxlen, "choke");
	} else {
		strcopy(code, maxlen, "quality_threshold");
	}
}

void ClassifyDisconnectReason(const char[] reason, char[] code, int maxlen)
{
	if (StrContains(reason, "timed out", false) != -1 || StrContains(reason, "timeout", false) != -1) {
		strcopy(code, maxlen, "timeout");
	} else if (StrContains(reason, "Steam", false) != -1 || StrContains(reason, "No Steam logon", false) != -1) {
		strcopy(code, maxlen, "steam");
	} else if (StrContains(reason, "Kicked", false) != -1 || StrContains(reason, "kick", false) != -1) {
		strcopy(code, maxlen, "kicked");
	} else if (StrContains(reason, "by user", false) != -1 || StrContains(reason, "Disconnect by user", false) != -1) {
		strcopy(code, maxlen, "user");
	} else {
		strcopy(code, maxlen, "other");
	}
}

void BuildServerPageUrl(char[] buffer, int maxlen)
{
	char hostname[192];
	char encoded[384];
	ConVar cvarHostname = FindConVar("hostname");
	if (cvarHostname == null) {
		strcopy(buffer, maxlen, g_sIpPageUrl);
		return;
	}
	cvarHostname.GetString(hostname, sizeof(hostname));
	UrlEncode(hostname, encoded, sizeof(encoded));
	if (StrContains(g_sIpPageUrl, "?", false) == -1) {
		Format(buffer, maxlen, "%s?server=%s", g_sIpPageUrl, encoded);
	} else {
		Format(buffer, maxlen, "%s&server=%s", g_sIpPageUrl, encoded);
	}
}

void BuildReason(int client, char[] buffer, int maxlen, bool badPing, bool badLoss, bool badChoke)
{
	buffer[0] = '\0';
	if (badPing) {
		AppendReason(client, buffer, maxlen, "NetworkQualityHint_ReasonPing");
	}
	if (badLoss) {
		AppendReason(client, buffer, maxlen, "NetworkQualityHint_ReasonLoss");
	}
	if (badChoke) {
		AppendReason(client, buffer, maxlen, "NetworkQualityHint_ReasonChoke");
	}
	if (buffer[0] == '\0') {
		AppendReason(client, buffer, maxlen, "NetworkQualityHint_ReasonTimeout");
	}
}

void AppendReason(int client, char[] buffer, int maxlen, const char[] phrase)
{
	char part[64];
	FormatEx(part, sizeof(part), "%T", phrase, client);
	if (buffer[0] != '\0') {
		StrCat(buffer, maxlen, " / ");
	}
	StrCat(buffer, maxlen, part);
}

int GetClientPingMs(int client)
{
	float latency = GetClientAvgLatency(client, NetFlow_Outgoing);
	return latency < 0.0 ? 0 : RoundToNearest(latency * 1000.0);
}

float GetClientLossPct(int client)
{
	float value = GetNetworkPctRaw(GetClientAvgLoss(client, NetFlow_Incoming));
	return value < 0.0 ? 0.0 : value;
}

float GetClientChokePct(int client)
{
	float value = GetNetworkPctRaw(GetClientAvgChoke(client, NetFlow_Outgoing));
	return value < 0.0 ? 0.0 : value;
}

float GetClientIncomingChokePct(int client)
{
	float value = GetNetworkPctRaw(GetClientAvgChoke(client, NetFlow_Incoming));
	return value < 0.0 ? 0.0 : value;
}

float GetNetworkPctRaw(float value)
{
	return value < 0.0 ? -1.0 : value * 100.0;
}

bool IsHumanInGame(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

void UrlEncode(const char[] input, char[] output, int maxlen)
{
	int pos = 0;
	for (int i = 0; input[i] != '\0' && pos < maxlen - 1; i++) {
		int c = input[i] & 0xff;
		if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
			output[pos++] = input[i];
		} else if (c == ' ') {
			if (pos < maxlen - 1) output[pos++] = '+';
		} else if (pos < maxlen - 3) {
			Format(output[pos], maxlen - pos, "%%%02X", c);
			pos += 3;
		}
	}
	output[pos] = '\0';
}
