#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define ANNE_DB_PROVIDER
#include <anne_db>

#define PLUGIN_VERSION		"1.0.0"
#define MAX_TARGETS			32
#define LANE_COUNT			2
#define MAX_LANES			(MAX_TARGETS * LANE_COUNT)
#define REQUEST_KIND_NEW	0
#define REQUEST_KIND_LEGACY	1

public Plugin myinfo =
{
	name		= "Anne DB Connection Hub",
	author		= "morzlee",
	description	= "Shares one MySQL connection per database target across plugins.",
	version		= PLUGIN_VERSION,
	url			= "https://github.com/fantasylidong/CompetitiveWithAnne"
};

// 一个物理数据库目标：databases.cfg 里 driver/host/port/user/pass/database 完全相同的配置归为一个。
enum struct DBTarget
{
	char conf[64];		// 用于实际连接的配置名
	char aliases[256];	// 所有指向该目标的配置名
	char display[192];	// host:port/database，不含账号密码
}

// 目标上的一条通道（lane = target * LANE_COUNT + AnneDBLane）。
enum struct LaneState
{
	Database db;
	bool wanted;
	bool connecting;
	bool keepAliveFailing;
	int generation;
	int failures;
	int clonesIssued;
	float nextRetryAt;
	float lastFailAt;
	float connectedAt;
	float lastKeepAliveAt;
	char lastError[256];
}

enum struct PendingRequest
{
	int lane;
	int kind;
	PrivateForward fwd;
	Handle plugin;
	any data;
	float deadline;
}

DBTarget g_Targets[MAX_TARGETS];
LaneState g_Lanes[MAX_LANES];
int g_iTargetCount;
StringMap g_ConfToTarget;
ArrayList g_Requests;
bool g_bDispatchQueued;

static const char g_sLaneNames[LANE_COUNT][] = { "shared", "sync" };

ConVar g_cvCharset;
ConVar g_cvKeepAlive;
ConVar g_cvRequestTimeout;
ConVar g_cvSyncCooldown;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("AnneDB_IsManaged", Native_IsManaged);
	CreateNative("AnneDB_Connect", Native_Connect);
	CreateNative("AnneDB_TConnect", Native_TConnect);
	CreateNative("AnneDB_ConnectSync", Native_ConnectSync);
	CreateNative("AnneDB_IsProviderConnection", Native_IsProviderConnection);
	RegPluginLibrary(ANNE_DB_LIBRARY);
	return APLRes_Success;
}

public void OnPluginStart()
{
	g_cvCharset = CreateConVar("anne_db_charset", "utf8mb4", "共享连接建立后统一设置的字符集，留空不设置。", FCVAR_NONE);
	g_cvKeepAlive = CreateConVar("anne_db_keepalive", "120", "共享连接保活间隔（秒），必须小于 MySQL wait_timeout。0 = 关闭。", FCVAR_NONE, true, 0.0);
	g_cvRequestTimeout = CreateConVar("anne_db_request_timeout", "30", "异步连接请求最长等待秒数，超时后回调失败。", FCVAR_NONE, true, 1.0);
	g_cvSyncCooldown = CreateConVar("anne_db_sync_cooldown", "30", "连接失败后多少秒内同步获取直接返回失败，避免主线程反复阻塞。", FCVAR_NONE, true, 0.0);
	CreateConVar("anne_db_version", PLUGIN_VERSION, "Anne DB Connection Hub version", FCVAR_DONTRECORD);

	g_ConfToTarget = new StringMap();
	g_Requests = new ArrayList(sizeof(PendingRequest));
	LoadTargets();

	RegAdminCmd("sm_annedb_status", Cmd_Status, ADMFLAG_ROOT, "Show shared database connection status in console.");
	CreateTimer(1.0, Timer_Maintenance, _, TIMER_REPEAT);
}

// ============================================================================
// databases.cfg
// ============================================================================

void LoadTargets()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/databases.cfg");

	KeyValues kv = new KeyValues("Databases");
	if (!kv.ImportFromFile(path))
	{
		LogError("[AnneDB] failed to read %s; no database is managed.", path);
		delete kv;
		return;
	}

	char driverDefault[32];
	kv.GetString("driver_default", driverDefault, sizeof(driverDefault), "mysql");

	StringMap keyToTarget = new StringMap();
	if (kv.GotoFirstSubKey())
	{
		char conf[64], driver[32], host[128], database[128], user[128], pass[128], key[640];
		do
		{
			kv.GetSectionName(conf, sizeof(conf));
			kv.GetString("driver", driver, sizeof(driver), "default");
			if (driver[0] == '\0' || StrEqual(driver, "default", false))
				strcopy(driver, sizeof(driver), driverDefault);

			if (!StrEqual(driver, "mysql", false) || !SQL_CheckConfig(conf))
				continue;

			kv.GetString("host", host, sizeof(host));
			kv.GetString("database", database, sizeof(database));
			kv.GetString("user", user, sizeof(user));
			kv.GetString("pass", pass, sizeof(pass));
			int port = kv.GetNum("port", 0);

			// 与 SourceMod MySQL 驱动的 persistent 匹配规则一致。
			Format(key, sizeof(key), "mysql|%s|%d|%s|%s|%s", host, port, user, pass, database);

			int target;
			if (!keyToTarget.GetValue(key, target))
			{
				if (g_iTargetCount >= MAX_TARGETS)
				{
					LogError("[AnneDB] too many database targets, \"%s\" is not managed.", conf);
					continue;
				}

				target = g_iTargetCount++;
				strcopy(g_Targets[target].conf, sizeof(DBTarget::conf), conf);
				g_Targets[target].aliases[0] = '\0';
				if (port > 0)
					FormatEx(g_Targets[target].display, sizeof(DBTarget::display), "%s:%d/%s", host, port, database);
				else
					FormatEx(g_Targets[target].display, sizeof(DBTarget::display), "%s/%s", host, database);
				keyToTarget.SetValue(key, target);
			}

			if (g_Targets[target].aliases[0] != '\0')
				StrCat(g_Targets[target].aliases, sizeof(DBTarget::aliases), ", ");
			StrCat(g_Targets[target].aliases, sizeof(DBTarget::aliases), conf);
			g_ConfToTarget.SetValue(conf, target);
		}
		while (kv.GotoNextKey());
	}

	delete keyToTarget;
	delete kv;
}

bool ResolveLane(const char[] conf, int laneType, int &lane)
{
	int target;
	if (!g_ConfToTarget.GetValue(conf, target))
		return false;

	if (laneType < 0 || laneType >= LANE_COUNT)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid AnneDBLane %d", laneType);
		return false;
	}

	lane = target * LANE_COUNT + laneType;
	return true;
}

// ============================================================================
// Natives
// ============================================================================

public any Native_IsManaged(Handle plugin, int numParams)
{
	char conf[64];
	GetNativeString(1, conf, sizeof(conf));

	int target;
	return g_ConfToTarget.GetValue(conf, target);
}

public any Native_Connect(Handle plugin, int numParams)
{
	return QueueRequest(plugin, REQUEST_KIND_NEW);
}

public any Native_TConnect(Handle plugin, int numParams)
{
	return QueueRequest(plugin, REQUEST_KIND_LEGACY);
}

bool QueueRequest(Handle plugin, int kind)
{
	char conf[64];
	GetNativeString(2, conf, sizeof(conf));

	int lane;
	if (!ResolveLane(conf, GetNativeCell(4), lane))
		return false;

	PendingRequest request;
	request.lane = lane;
	request.kind = kind;
	request.plugin = plugin;
	request.data = GetNativeCell(3);
	request.deadline = GetEngineTime() + g_cvRequestTimeout.FloatValue;
	if (kind == REQUEST_KIND_NEW)
		request.fwd = new PrivateForward(ET_Ignore, Param_Cell, Param_String, Param_Cell);
	else
		request.fwd = new PrivateForward(ET_Ignore, Param_Cell, Param_Cell, Param_String, Param_Cell);
	request.fwd.AddFunction(plugin, GetNativeFunction(1));
	g_Requests.PushArray(request);

	g_Lanes[lane].wanted = true;
	if (g_Lanes[lane].db != null)
		ScheduleDispatch();
	else
		StartLaneConnect(lane);

	return true;
}

public any Native_ConnectSync(Handle plugin, int numParams)
{
	char conf[64];
	GetNativeString(1, conf, sizeof(conf));
	int maxlength = GetNativeCell(3);

	int lane;
	if (!ResolveLane(conf, GetNativeCell(4), lane))
	{
		WriteNativeError(maxlength, "database config is not managed by anne_db");
		return 0;
	}

	bool allowBlock = GetNativeCell(5);
	g_Lanes[lane].wanted = true;

	if (g_Lanes[lane].db == null && allowBlock && !IsLaneCoolingDown(lane))
		ConnectLaneBlocking(lane);

	if (g_Lanes[lane].db == null)
	{
		StartLaneConnect(lane);
		if (g_Lanes[lane].lastError[0] != '\0')
			WriteNativeError(maxlength, g_Lanes[lane].lastError);
		else
			WriteNativeError(maxlength, "anne_db connection is not ready");
		return 0;
	}

	return CloneLaneFor(lane, plugin);
}

public any Native_IsProviderConnection(Handle plugin, int numParams)
{
	Handle database = GetNativeCell(1);
	if (database == null)
		return false;

	for (int lane = 0; lane < g_iTargetCount * LANE_COUNT; lane++)
	{
		if (g_Lanes[lane].db != null && SQL_IsSameConnection(database, g_Lanes[lane].db))
			return true;
	}

	return false;
}

void WriteNativeError(int maxlength, const char[] message)
{
	if (maxlength > 0)
		SetNativeString(2, message, maxlength);
}

// ============================================================================
// Lanes
// ============================================================================

bool IsLaneCoolingDown(int lane)
{
	return g_Lanes[lane].failures > 0
		&& GetEngineTime() - g_Lanes[lane].lastFailAt < g_cvSyncCooldown.FloatValue;
}

void StartLaneConnect(int lane)
{
	if (g_Lanes[lane].db != null || g_Lanes[lane].connecting)
		return;

	if (GetEngineTime() < g_Lanes[lane].nextRetryAt)
		return;

	g_Lanes[lane].connecting = true;
	g_Lanes[lane].generation = (g_Lanes[lane].generation + 1) & 0xFFFF;

	int target = lane / LANE_COUNT;
	Database.Connect(OnLaneConnected, g_Targets[target].conf, (lane << 16) | g_Lanes[lane].generation);
}

void ConnectLaneBlocking(int lane)
{
	int target = lane / LANE_COUNT;
	char error[256];
	Database db = SQL_Connect(g_Targets[target].conf, false, error, sizeof(error));
	if (db == null)
	{
		MarkLaneFailed(lane, error);
		return;
	}

	AdoptLane(lane, db);
}

public void OnLaneConnected(Database db, const char[] error, any data)
{
	int lane = data >> 16;
	int generation = data & 0xFFFF;
	if (lane < 0 || lane >= MAX_LANES || generation != g_Lanes[lane].generation)
	{
		delete db;
		return;
	}

	g_Lanes[lane].connecting = false;

	// 线程连接在途时同步路径已经先连上：保留先到的那条。
	if (g_Lanes[lane].db != null)
	{
		delete db;
		return;
	}

	if (db == null)
	{
		MarkLaneFailed(lane, error);
		return;
	}

	AdoptLane(lane, db);
}

void AdoptLane(int lane, Database db)
{
	char charset[32];
	g_cvCharset.GetString(charset, sizeof(charset));
	if (charset[0] != '\0' && !db.SetCharset(charset))
		LogError("[AnneDB] failed to set charset %s on %s.", charset, g_Targets[lane / LANE_COUNT].display);

	if (g_Lanes[lane].failures > 0)
		LogMessage("[AnneDB] %s %s lane connected after %d failed attempt(s).", g_Targets[lane / LANE_COUNT].display, g_sLaneNames[lane % LANE_COUNT], g_Lanes[lane].failures);

	float now = GetEngineTime();
	g_Lanes[lane].db = db;
	g_Lanes[lane].failures = 0;
	g_Lanes[lane].nextRetryAt = 0.0;
	g_Lanes[lane].connectedAt = now;
	g_Lanes[lane].lastKeepAliveAt = now;
	g_Lanes[lane].keepAliveFailing = false;
	g_Lanes[lane].lastError[0] = '\0';

	// 同步路径是在其他插件的 native 调用里进来的，统一延后一帧派发，避免重入。
	ScheduleDispatch();
}

void MarkLaneFailed(int lane, const char[] error)
{
	float now = GetEngineTime();
	int failures = ++g_Lanes[lane].failures;
	g_Lanes[lane].lastFailAt = now;
	g_Lanes[lane].nextRetryAt = now + GetRetryDelay(failures);
	strcopy(g_Lanes[lane].lastError, sizeof(LaneState::lastError), error);

	if (failures == 1 || failures % 10 == 0)
		LogError("[AnneDB] failed to connect %s %s lane (attempt %d): %s", g_Targets[lane / LANE_COUNT].display, g_sLaneNames[lane % LANE_COUNT], failures, error);
}

float GetRetryDelay(int failures)
{
	float delay = 5.0;
	for (int i = 1; i < failures && delay < 60.0; i++)
		delay *= 2.0;

	return delay > 60.0 ? 60.0 : delay;
}

Database CloneLaneFor(int lane, Handle plugin)
{
	g_Lanes[lane].clonesIssued++;
	return view_as<Database>(CloneHandle(g_Lanes[lane].db, plugin));
}

// ============================================================================
// Request dispatch
// ============================================================================

void ScheduleDispatch()
{
	if (g_bDispatchQueued)
		return;

	g_bDispatchQueued = true;
	RequestFrame(Frame_Dispatch);
}

public void Frame_Dispatch(any data)
{
	g_bDispatchQueued = false;
	DispatchRequests();
}

void DispatchRequests()
{
	if (g_Requests.Length == 0)
		return;

	// 先摘出可派发的请求再回调，回调里重新请求的会留到下一轮。
	float now = GetEngineTime();
	ArrayList ready = new ArrayList(sizeof(PendingRequest));
	PendingRequest request;
	for (int i = 0; i < g_Requests.Length; )
	{
		g_Requests.GetArray(i, request);
		if (g_Lanes[request.lane].db != null || now >= request.deadline)
		{
			ready.PushArray(request);
			g_Requests.Erase(i);
			continue;
		}
		i++;
	}

	for (int i = 0; i < ready.Length; i++)
	{
		ready.GetArray(i, request);
		FireRequest(request);
	}

	delete ready;
}

void FireRequest(PendingRequest request)
{
	if (request.fwd.FunctionCount == 0 || !IsPluginRunning(request.plugin))
	{
		delete request.fwd;
		return;
	}

	int lane = request.lane;
	Database clone = null;
	char error[256];
	if (g_Lanes[lane].db != null)
		clone = CloneLaneFor(lane, request.plugin);
	else if (g_Lanes[lane].lastError[0] != '\0')
		strcopy(error, sizeof(error), g_Lanes[lane].lastError);
	else
		strcopy(error, sizeof(error), "anne_db connection request timed out");

	Call_StartForward(request.fwd);
	if (request.kind == REQUEST_KIND_LEGACY)
	{
		Handle driver = null;
		if (clone != null)
			driver = clone.Driver;
		Call_PushCell(driver);
	}
	Call_PushCell(clone);
	Call_PushString(error);
	Call_PushCell(request.data);
	Call_Finish();

	delete request.fwd;
}

bool IsPluginRunning(Handle plugin)
{
	bool found = false;
	Handle iter = GetPluginIterator();
	while (MorePlugins(iter))
	{
		if (ReadPlugin(iter) == plugin)
		{
			found = true;
			break;
		}
	}
	delete iter;

	return found && GetPluginStatus(plugin) == Plugin_Running;
}

// ============================================================================
// Maintenance: retry, request timeout, keepalive
// ============================================================================

public Action Timer_Maintenance(Handle timer)
{
	float now = GetEngineTime();
	float keepAlive = g_cvKeepAlive.FloatValue;

	for (int lane = 0; lane < g_iTargetCount * LANE_COUNT; lane++)
	{
		if (!g_Lanes[lane].wanted)
			continue;

		Database db = g_Lanes[lane].db;
		if (db == null)
		{
			StartLaneConnect(lane);
			continue;
		}

		// MySQL 自带自动重连，保活只为避免 wait_timeout 回收后第一条查询失败。
		if (keepAlive > 0.0 && now - g_Lanes[lane].lastKeepAliveAt >= keepAlive)
		{
			g_Lanes[lane].lastKeepAliveAt = now;
			db.Query(OnKeepAlive, "SELECT 1", lane, DBPrio_Low);
		}
	}

	if (g_Requests.Length > 0)
		DispatchRequests();

	return Plugin_Continue;
}

public void OnKeepAlive(Database db, DBResultSet results, const char[] error, any data)
{
	int lane = data;
	if (lane < 0 || lane >= MAX_LANES)
		return;

	if (results != null)
	{
		if (g_Lanes[lane].keepAliveFailing)
			LogMessage("[AnneDB] %s %s lane keepalive recovered.", g_Targets[lane / LANE_COUNT].display, g_sLaneNames[lane % LANE_COUNT]);
		g_Lanes[lane].keepAliveFailing = false;
		return;
	}

	strcopy(g_Lanes[lane].lastError, sizeof(LaneState::lastError), error);
	if (!g_Lanes[lane].keepAliveFailing)
		LogError("[AnneDB] %s %s lane keepalive failed: %s", g_Targets[lane / LANE_COUNT].display, g_sLaneNames[lane % LANE_COUNT], error);
	g_Lanes[lane].keepAliveFailing = true;
}

// ============================================================================
// Status
// ============================================================================

public Action Cmd_Status(int client, int args)
{
	float now = GetEngineTime();
	StatusLine(client, "[AnneDB] v%s targets=%d pending=%d keepalive=%.0fs", PLUGIN_VERSION, g_iTargetCount, g_Requests.Length, g_cvKeepAlive.FloatValue);

	for (int target = 0; target < g_iTargetCount; target++)
	{
		StatusLine(client, "#%d %s  confs: %s", target, g_Targets[target].display, g_Targets[target].aliases);

		for (int laneType = 0; laneType < LANE_COUNT; laneType++)
		{
			int lane = target * LANE_COUNT + laneType;
			if (!g_Lanes[lane].wanted && g_Lanes[lane].db == null)
			{
				StatusLine(client, "    %-6s idle", g_sLaneNames[lane % LANE_COUNT]);
				continue;
			}

			if (g_Lanes[lane].db != null)
			{
				StatusLine(client, "    %-6s ready up=%.0fs clones=%d keepalive_ok=%d last_error=%s",
					g_sLaneNames[lane % LANE_COUNT], now - g_Lanes[lane].connectedAt, g_Lanes[lane].clonesIssued,
					!g_Lanes[lane].keepAliveFailing, g_Lanes[lane].lastError);
				continue;
			}

			float retryIn = g_Lanes[lane].nextRetryAt - now;
			StatusLine(client, "    %-6s connecting=%d failures=%d retry_in=%.0fs error=%s",
				g_sLaneNames[lane % LANE_COUNT], g_Lanes[lane].connecting,
				g_Lanes[lane].failures, retryIn > 0.0 ? retryIn : 0.0, g_Lanes[lane].lastError);
		}
	}

	return Plugin_Handled;
}

// 状态只输出到控制台，不进聊天区。
void StatusLine(int client, const char[] format, any ...)
{
	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);

	if (client > 0 && IsClientInGame(client))
		PrintToConsole(client, "%s", buffer);
	else
		PrintToServer("%s", buffer);
}
