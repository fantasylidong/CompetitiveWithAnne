#include <sourcemod>
#undef REQUIRE_EXTENSIONS
#include <geoip>
#define REQUIRE_EXTENSIONS
#include <anne_db>

#pragma semicolon 1
#pragma newdecls required

#define CHATLOG_DB_CONFIG "chatlog"
#define CHATLOG_CLEANUP_INTERVAL 21600.0
#define CHATLOG_IGNORE_SYNC_INTERVAL 60.0
#define CHATLOG_DOOR_AUDIT_COOLDOWN 2.0
#define CHATLOG_MESSAGE_MAX_CHARS 126
#define CHATLOG_AUDIT_DETAIL_MAX_CHARS 255
#define CHATLOG_KEYWORD_MAX_BYTES 128
#define CHATLOG_SEED_BATCH_SIZE 35

bool g_bFullyConnected;
bool g_bAuditConnected;
bool g_bIgnoreTableReady;
bool g_bConnecting;
bool g_bReloadingIgnore;
bool g_bMigratedIgnoreSchema;

Handle g_hCleanupTimer = null;
Handle g_hIgnoreSyncTimer = null;
StringMap g_hIgnoredCommands = null;
ArrayList g_hIgnoredKeywords = null;
Database g_hDatabase = null;

ConVar chatlog_clearTable;
ConVar chatlog_clearTableDuration;
ConVar chatlog_auditEnabled;
ConVar chatlog_auditLifecycle;
ConVar chatlog_auditDuration;
ConVar g_cvHostport;
ConVar g_cvHostname;

int g_iLastChatCmdTick[MAXPLAYERS + 1];
int g_iLastSponsorTick[MAXPLAYERS + 1];
float g_fLastDoorAuditTime[MAXPLAYERS + 1];
char g_sLastChatCmdKey[MAXPLAYERS + 1][64];

static const char g_sAuditActionCommands[][] =
{
	"callvote",
	"unpause",
	"setpause",
	"choose_opendoor",
	"choose_closedoor",
	"go_away_from_keyboard"
};

static const char g_sSponsorCommands[][] =
{
	"sm_donate",
	"sm_wc",
	"sm_wanchen",
	"sm_finish",
	"sm_wccancel"
};

static const char g_sSponsorCommandKeys[][] =
{
	"donate",
	"wc",
	"wanchen",
	"finish",
	"wccancel"
};

// 默认屏蔽的无意义/纯查询/外观/HUD/准备状态指令（可通过 NewAnneWeb 的 chat_audit_ignore 随时开关或追加命令与关键词）
static const char g_sBuiltinIgnoredCommands[][] =
{
	// 外观 / 音效 / HUD / 视角 / 个人偏好菜单
	"hat", "hats", "hatall", "hatoff", "hatshow", "hatshowon", "hatshowoff", "hatview",
	"snd", "dmgmenu", "punch", "recoil", "beam",
	"hud", "hudmenu", "hudlang", "lang", "spechud", "spechudon", "spechudoff", "tankhud", "hide", "show",
	"dance", "dances", "emote", "emotes",
	"ch", "chenghao", "tagslist", "applytags", "setch", "unsetch",
	"qfmenu", "qfadmin", "zdmenu", "blmenu", "blocklimit", "blocklist", "listen",
	"overhand", "overonehand", "underhand",
	"decrease_specspeed", "increase_specspeed", "set_specspeed_increment", "set_specspeed_multi", "set_vertical_increment",
	// 纯只读查询 / 进度 / 排行榜 / 统计 / 娱乐指令
	"cur", "current", "boss", "tank", "witch", "bonus", "hbonus", "damage", "health", "mapinfo", "xx",
	"rank", "rankmenu", "rankmute", "rankmutetoggle", "nextrank", "top10", "top10ppm", "top10q", "qtop10", "quartertop10",
	"showrank", "showppm", "showtimer", "showmotd", "maptimes", "showmaptimes", "timedmaps", "time", "aippm",
	"mvp", "mvpme", "kills", "killsme", "stats", "stats_auto", "skill", "ff", "acc", "skeets", "weaponstats", "weapon_attributes",
	"lerps", "rates", "specrates", "loss", "net", "ping", "check_bhop", "comms", "getteam",
	"help", "searchcmd", "web", "ip", "cfg", "changelog", "motd", "nextmap", "timeleft", "settings",
	"cf", "coinflip", "flip", "roll", "picknumber", "8ball", "teamflip", "tf",
	// 准备面板高频切换
	"ready", "r", "unready", "nr", "toggleready"
};

public Plugin myinfo = {
	name		= "Chat Log",
	author		= "venus, 东",
	description	= "Save pure chat in chat_log and monitor !// chat & sm_ console commands in chat_audit_log with 1-month retention and cmd/keyword filtering",
	version		= "1.5",
	url			= "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
	g_hIgnoredCommands = new StringMap();
	g_hIgnoredKeywords = new ArrayList(ByteCountToCells(CHATLOG_KEYWORD_MAX_BYTES));
	PopulateBuiltinIgnoredCommands();
	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		ResetClientAuditState(i);
	}

	chatlog_clearTable = CreateConVar("sm_chatlog_cleartable_enabled", "1", "Enable/Disable clearing chat_log table (1/0)", 0, true, 0.0, true, 1.0);
	chatlog_clearTableDuration = CreateConVar("sm_chatlog_cleartable_duration", "12 MONTH", "How long chat_log keeps rows before automatic deletion");
	chatlog_auditEnabled = CreateConVar("sm_chatlog_audit_enabled", "1", "Enable/Disable saving command and server audit events to chat_audit_log (1/0)", 0, true, 0.0, true, 1.0);
	chatlog_auditLifecycle = CreateConVar("sm_chatlog_audit_lifecycle", "0", "Enable/Disable map and round lifecycle markers in chat_audit_log when human players are connected (1/0)", 0, true, 0.0, true, 1.0);
	chatlog_auditDuration = CreateConVar("sm_chatlog_audit_duration", "1 MONTH", "How long chat_audit_log keeps rows before automatic deletion (default 1 MONTH)");

	g_cvHostport = FindConVar("hostport");
	g_cvHostname = FindConVar("hostname");

	RegAdminCmd("sm_chatlog_reload_ignore", Command_ReloadIgnore, ADMFLAG_CONFIG, "Reload blocked audit commands and keywords from chat_audit_ignore");

	// 直接在 say / say_team 命令层前置监听所有 ! 与 / 开头的聊天命令，避免被 bequiet / server 等插件提前拦截而漏记
	AddCommandListener(Command_SayAuditListener, "say");
	AddCommandListener(Command_SayAuditListener, "say_team");

	for (int i = 0; i < sizeof(g_sSponsorCommands); i++)
	{
		AddCommandListener(Command_SponsorLog, g_sSponsorCommands[i]);
	}

	for (int i = 0; i < sizeof(g_sAuditActionCommands); i++)
	{
		AddCommandListener(Command_ActionAuditLog, g_sAuditActionCommands[i]);
	}

	// 全局监听所有已注册或未注册的 sm_ 控制台命令（及根命令 sm）
	AddCommandListener(Command_SmAuditListener, "");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

	AutoExecConfig(true, "chatlog");
}

void PopulateBuiltinIgnoredCommands()
{
	if (g_hIgnoredCommands == null)
		return;

	g_hIgnoredCommands.Clear();
	for (int i = 0; i < sizeof(g_sBuiltinIgnoredCommands); i++)
	{
		g_hIgnoredCommands.SetValue(g_sBuiltinIgnoredCommands[i], 1);
	}
}

public Action Command_ReloadIgnore(int client, int args)
{
	if (g_hDatabase == null)
		SQL_ConnectChatLog();

	if (g_hDatabase == null || !g_bIgnoreTableReady)
	{
		if (client == 0)
			PrintToServer("[chatlog] chat_audit_ignore 尚未就绪，暂无法刷新。");
		else
			PrintToConsole(client, "[chatlog] chat_audit_ignore is not ready yet.");
		return Plugin_Handled;
	}

	SQL_ReloadIgnoreRules();
	if (client == 0)
		PrintToServer("[chatlog] 已触发刷新 chat_audit_ignore 屏蔽命令与关键词。");
	else
		PrintToConsole(client, "[chatlog] Triggered chat_audit_ignore reload.");
	return Plugin_Handled;
}

public void OnClientConnected(int client)
{
	ResetClientAuditState(client);
}

void ResetClientAuditState(int client)
{
	g_iLastChatCmdTick[client] = -1;
	g_iLastSponsorTick[client] = -1;
	g_fLastDoorAuditTime[client] = 0.0;
	g_sLastChatCmdKey[client][0] = '\0';
}

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_fLastDoorAuditTime[i] = 0.0;
	}

	if (g_hDatabase == null)
		SQL_ConnectChatLog();
	else if (g_bIgnoreTableReady)
		SQL_ReloadIgnoreRules();

	WriteLifecycleAudit("map_start", "地图开始");
}

public void OnMapEnd()
{
	WriteLifecycleAudit("map_end", "地图结束");
}

public void OnConfigsExecuted()
{
	SQL_ConnectChatLog();
}

void SQL_ConnectChatLog()
{
	if (g_hDatabase != null || g_bConnecting)
		return;

	if (!SQL_CheckConfig(CHATLOG_DB_CONFIG))
	{
		LogError("[chatlog] databases.cfg 缺少 '%s' 配置。", CHATLOG_DB_CONFIG);
		SQL_MarkDatabaseUnavailable();
		return;
	}

	g_bConnecting = true;
	char error[256];
	g_hDatabase = AnneDB_ConnectSyncCompat(CHATLOG_DB_CONFIG, error, sizeof(error));
	g_bConnecting = false;

	if (g_hDatabase == null)
	{
		LogError("[chatlog] 数据库连接失败: %s", error);
		SQL_MarkDatabaseUnavailable();
		return;
	}

	if (!AnneDB_SetCharsetIfOwned(g_hDatabase, "utf8mb4"))
		LogError("[chatlog] 设置数据库字符集 utf8mb4 失败。");

	SQL_CreateTables();
}

void SQL_CreateTables()
{
	g_hDatabase.Query(SQL_CreateChatTableCallback, "\
		CREATE TABLE IF NOT EXISTS `chat_log` ( \
		`id` BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT, \
		`date` DATETIME NULL DEFAULT NULL, \
		`map` VARCHAR(128) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`steamid` VARCHAR(21) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`name` VARCHAR(128) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`message_style` TINYINT(2) NULL DEFAULT 0, \
		`message` VARCHAR(126) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`server` varchar(126) DEFAULT NULL COLLATE 'utf8mb4_general_ci', \
		`port` int(11) DEFAULT NULL , \
		PRIMARY KEY (`id`) USING BTREE, \
		KEY `idx_chat_log_date` (`date`) \
	) \
	DEFAULT CHARSET='utf8mb4' \
	ENGINE=InnoDB \
	;");

	g_hDatabase.Query(SQL_CreateAuditTableCallback, "\
		CREATE TABLE IF NOT EXISTS `chat_audit_log` ( \
		`id` BIGINT(20) UNSIGNED NOT NULL AUTO_INCREMENT, \
		`date` DATETIME NOT NULL, \
		`server` VARCHAR(126) DEFAULT NULL COLLATE 'utf8mb4_general_ci', \
		`port` INT(11) DEFAULT NULL, \
		`map` VARCHAR(128) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`event_type` VARCHAR(24) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`team` VARCHAR(16) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`steamid` VARCHAR(32) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`name` VARCHAR(128) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`ip` VARCHAR(45) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`country` VARCHAR(4) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`detail` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		PRIMARY KEY (`id`) USING BTREE, \
		KEY `idx_chat_audit_log_date` (`date`), \
		KEY `idx_chat_audit_log_steamid_date` (`steamid`, `date`), \
		KEY `idx_chat_audit_log_event_date` (`event_type`, `date`) \
	) \
	DEFAULT CHARSET='utf8mb4' \
	ENGINE=InnoDB \
	;");

	g_hDatabase.Query(SQL_CreateIgnoreTableCallback, "\
		CREATE TABLE IF NOT EXISTS `chat_audit_ignore` ( \
		`match_type` VARCHAR(16) NOT NULL DEFAULT 'cmd' COLLATE 'utf8mb4_general_ci', \
		`command_key` VARCHAR(64) NOT NULL COLLATE 'utf8mb4_general_ci', \
		`enabled` TINYINT(1) NOT NULL DEFAULT 1, \
		`is_builtin` TINYINT(1) NOT NULL DEFAULT 0, \
		`note` VARCHAR(128) NOT NULL DEFAULT '' COLLATE 'utf8mb4_general_ci', \
		`updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
		PRIMARY KEY (`match_type`, `command_key`) USING BTREE, \
		KEY `idx_chat_audit_ignore_enabled` (`enabled`, `match_type`) \
	) \
	DEFAULT CHARSET='utf8mb4' \
	ENGINE=InnoDB \
	;");
}

bool SQL_IsConnectionLostError(const char[] error)
{
	return StrContains(error, "Lost connection", false) != -1
		|| StrContains(error, "server has gone away", false) != -1
		|| StrContains(error, "communication packets", false) != -1;
}

void SQL_MarkDatabaseUnavailable()
{
	g_bFullyConnected = false;
	g_bAuditConnected = false;
	g_bIgnoreTableReady = false;
	g_bConnecting = false;
	g_bReloadingIgnore = false;
	SQL_StopIgnoreSyncTimer();
	if (g_hDatabase != null)
	{
		delete g_hDatabase;
		g_hDatabase = null;
	}
}

void SQL_StartCleanupTimer()
{
	SQL_StopCleanupTimer();
	g_hCleanupTimer = CreateTimer(CHATLOG_CLEANUP_INTERVAL, Timer_CleanupChatLog, _, TIMER_REPEAT);
}

void SQL_StopCleanupTimer()
{
	if (g_hCleanupTimer == null)
		return;

	KillTimer(g_hCleanupTimer);
	g_hCleanupTimer = null;
}

void SQL_StartIgnoreSyncTimer()
{
	SQL_StopIgnoreSyncTimer();
	g_hIgnoreSyncTimer = CreateTimer(CHATLOG_IGNORE_SYNC_INTERVAL, Timer_SyncIgnoreList, _, TIMER_REPEAT);
}

void SQL_StopIgnoreSyncTimer()
{
	if (g_hIgnoreSyncTimer == null)
		return;

	KillTimer(g_hIgnoreSyncTimer);
	g_hIgnoreSyncTimer = null;
}

public Action Timer_CleanupChatLog(Handle timer, any data)
{
	SQL_RunCleanup();
	return Plugin_Continue;
}

public Action Timer_SyncIgnoreList(Handle timer, any data)
{
	if (!chatlog_auditEnabled.BoolValue || !HasHumanClient())
		return Plugin_Continue;

	if (g_hDatabase == null)
	{
		SQL_ConnectChatLog();
		return Plugin_Continue;
	}

	if (g_bIgnoreTableReady)
		SQL_ReloadIgnoreRules();

	return Plugin_Continue;
}

void SQL_RunCleanup()
{
	if (g_hDatabase == null)
		return;

	char szTimeFunction[64];
	char szQuery[256];

	if (g_bFullyConnected && chatlog_clearTable.BoolValue)
	{
		chatlog_clearTableDuration.GetString(szTimeFunction, sizeof(szTimeFunction));
		TrimString(szTimeFunction);
		if (IsSafeSqlInterval(szTimeFunction))
		{
			g_hDatabase.Format(szQuery, sizeof(szQuery), "DELETE FROM chat_log WHERE date < DATE_SUB(NOW(), INTERVAL %s)", szTimeFunction);
			g_hDatabase.Query(SQL_Error, szQuery);
		}
	}

	// 审计日志默认保留 1 个月自动删除，独立于 chat_log 清理开关执行
	if (g_bAuditConnected)
	{
		chatlog_auditDuration.GetString(szTimeFunction, sizeof(szTimeFunction));
		TrimString(szTimeFunction);
		if (IsSafeSqlInterval(szTimeFunction))
		{
			g_hDatabase.Format(szQuery, sizeof(szQuery), "DELETE FROM chat_audit_log WHERE date < DATE_SUB(NOW(), INTERVAL %s)", szTimeFunction);
			g_hDatabase.Query(SQL_Error, szQuery);
		}
	}
}

bool IsSafeSqlInterval(const char[] expr)
{
	if (expr[0] < '1' || expr[0] > '9')
		return false;

	int i = 0;
	while (expr[i] >= '0' && expr[i] <= '9')
	{
		i++;
	}

	if (expr[i] != ' ')
		return false;

	while (expr[i] == ' ')
	{
		i++;
	}

	if (expr[i] == '\0')
		return false;

	for (; expr[i] != '\0'; i++)
	{
		char c = expr[i];
		if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'))
			return false;
	}

	return true;
}

public void SQL_CreateChatTableCallback(Database database, DBResultSet results, const char[] error, int data)
{
	if (results == null)
	{
		LogError("[chatlog] 初始化 chat_log 数据表失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
		return;
	}

	g_bFullyConnected = true;
	SQL_StartCleanupTimer();
	SQL_RunCleanup();
}

public void SQL_CreateAuditTableCallback(Database database, DBResultSet results, const char[] error, int data)
{
	if (results == null)
	{
		LogError("[chatlog] 初始化 chat_audit_log 数据表失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
		return;
	}

	g_bAuditConnected = true;
	SQL_StartCleanupTimer();
	SQL_RunCleanup();
}

public void SQL_CreateIgnoreTableCallback(Database database, DBResultSet results, const char[] error, int data)
{
	if (results == null)
	{
		LogError("[chatlog] 初始化 chat_audit_ignore 数据表失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
		return;
	}

	g_bIgnoreTableReady = true;
	SQL_StartIgnoreSyncTimer();
	SQL_SeedBuiltinIgnoreBatch(0);
}

void SQL_SeedBuiltinIgnoreBatch(int startIndex)
{
	if (g_hDatabase == null || !g_bIgnoreTableReady)
		return;

	int total = sizeof(g_sBuiltinIgnoredCommands);
	if (startIndex >= total)
	{
		SQL_ReloadIgnoreRules();
		return;
	}

	int endIndex = startIndex + CHATLOG_SEED_BATCH_SIZE;
	if (endIndex > total)
		endIndex = total;

	char query[2048];
	int written = strcopy(query, sizeof(query), "INSERT IGNORE INTO chat_audit_ignore (match_type, command_key, enabled, is_builtin, note) VALUES ");
	for (int i = startIndex; i < endIndex; i++)
	{
		written += FormatEx(
			query[written],
			sizeof(query) - written,
			"%s('cmd', '%s', 1, 1, '默认过滤')",
			(i == startIndex) ? "" : ",",
			g_sBuiltinIgnoredCommands[i]
		);
	}

	g_hDatabase.Query(SQL_SeedBuiltinIgnoreCallback, query, endIndex);
}

public void SQL_SeedBuiltinIgnoreCallback(Database database, DBResultSet results, const char[] error, int nextIndex)
{
	if (results == null)
	{
		if (!g_bMigratedIgnoreSchema && StrContains(error, "match_type", false) != -1)
		{
			g_bMigratedIgnoreSchema = true;
			g_hDatabase.Query(SQL_MigrateIgnoreSchemaCallback, "ALTER TABLE `chat_audit_ignore` ADD COLUMN `match_type` VARCHAR(16) NOT NULL DEFAULT 'cmd' FIRST, DROP PRIMARY KEY, ADD PRIMARY KEY (`match_type`, `command_key`) USING BTREE");
			return;
		}

		LogError("[chatlog] 写入默认屏蔽命令失败: %s", error);
		if (SQL_IsConnectionLostError(error))
		{
			SQL_MarkDatabaseUnavailable();
			return;
		}
	}

	SQL_SeedBuiltinIgnoreBatch(nextIndex);
}

public void SQL_MigrateIgnoreSchemaCallback(Database database, DBResultSet results, const char[] error, int data)
{
	if (results == null)
	{
		LogError("[chatlog] 升级 chat_audit_ignore 表结构失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
		return;
	}

	SQL_SeedBuiltinIgnoreBatch(0);
}

void SQL_ReloadIgnoreRules()
{
	if (g_hDatabase == null || !g_bIgnoreTableReady || g_bReloadingIgnore)
		return;

	g_bReloadingIgnore = true;
	g_hDatabase.Query(SQL_ReloadIgnoreCallback, "SELECT match_type, command_key FROM chat_audit_ignore WHERE enabled = 1");
}

public void SQL_ReloadIgnoreCallback(Database database, DBResultSet results, const char[] error, int data)
{
	g_bReloadingIgnore = false;

	if (results == null)
	{
		LogError("[chatlog] 读取 chat_audit_ignore 失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
		return;
	}

	if (g_hIgnoredCommands == null)
		g_hIgnoredCommands = new StringMap();
	else
		g_hIgnoredCommands.Clear();

	if (g_hIgnoredKeywords == null)
		g_hIgnoredKeywords = new ArrayList(ByteCountToCells(CHATLOG_KEYWORD_MAX_BYTES));
	else
		g_hIgnoredKeywords.Clear();

	char matchType[16], rawKey[CHATLOG_KEYWORD_MAX_BYTES], normalizedKey[CHATLOG_KEYWORD_MAX_BYTES];
	while (results.FetchRow())
	{
		results.FetchString(0, matchType, sizeof(matchType));
		results.FetchString(1, rawKey, sizeof(rawKey));

		if (StrEqual(matchType, "keyword", false))
		{
			if (NormalizeKeywordRule(rawKey, normalizedKey, sizeof(normalizedKey)))
				g_hIgnoredKeywords.PushString(normalizedKey);
		}
		else
		{
			if (NormalizeCommandKey(rawKey, normalizedKey, sizeof(normalizedKey)))
				g_hIgnoredCommands.SetValue(normalizedKey, 1);
		}
	}
}

public void OnPluginEnd()
{
	SQL_StopCleanupTimer();
	SQL_StopIgnoreSyncTimer();

	if (g_hDatabase != null)
	{
		delete g_hDatabase;
		g_hDatabase = null;
	}

	if (g_hIgnoredCommands != null)
	{
		delete g_hIgnoredCommands;
		g_hIgnoredCommands = null;
	}

	if (g_hIgnoredKeywords != null)
	{
		delete g_hIgnoredKeywords;
		g_hIgnoredKeywords = null;
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return;

	char steamId[32], clientName[MAX_NAME_LENGTH], ip[45], country[3];
	GetAuditClientIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName), ip, sizeof(ip));

	if (ip[0] != '\0'
		&& GetFeatureStatus(FeatureType_Native, "GeoipCode2") == FeatureStatus_Available
		&& !GeoipCode2(ip, country))
	{
		country[0] = '\0';
	}

	WriteAuditRow("connect", "", steamId, clientName, ip, country, "加入游戏");
}

void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return;

	char steamId[32], clientName[MAX_NAME_LENGTH], ip[45], team[16], reason[192], detail[256];
	GetAuditClientIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName), ip, sizeof(ip));
	if (IsClientInGame(client))
		GetTeamLabel(GetClientTeam(client), team, sizeof(team));

	event.GetString("reason", reason, sizeof(reason));
	TrimString(reason);
	if (reason[0] != '\0')
		FormatEx(detail, sizeof(detail), "离开游戏 (%s)", reason);
	else
		strcopy(detail, sizeof(detail), "离开游戏");

	WriteAuditRow("disconnect", team, steamId, clientName, ip, "", detail);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	WriteLifecycleAudit("round_start", "回合开始");
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	WriteLifecycleAudit("round_end", "回合结束");
}

void WriteLifecycleAudit(const char[] eventType, const char[] label)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || !chatlog_auditLifecycle.BoolValue || !HasHumanClient())
		return;

	WriteAuditRow(eventType, "", "CONSOLE", "Server", "", "", label);
}

bool HasHumanClient()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
			return true;
	}
	return false;
}

// 前置监听 say / say_team，确保所有以 ! 或 / 开头的聊天命令（无论是否注册、是否被 bequiet/server 拦截）均被监测
public Action Command_SayAuditListener(int client, const char[] command, int argc)
{
	if (argc < 1 || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return Plugin_Continue;

	char rawChat[256];
	GetCmdArgString(rawChat, sizeof(rawChat));
	StripQuotes(rawChat);
	int len = strlen(rawChat);
	while (len > 0 && (rawChat[len - 1] == '\r' || rawChat[len - 1] == '\n'))
	{
		rawChat[--len] = '\0';
	}

	if (rawChat[0] != '!' && rawChat[0] != '/')
		return Plugin_Continue;

	RecordChatCommandAudit(client, command, rawChat);
	return Plugin_Continue;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] szArgs)
{
	// 纯聊天只写 chat_log（保留 basecomm 禁言拦截顺序）；! 和 / 命令已由 Command_SayAuditListener 统一监测
	if (szArgs[0] != '\0' && szArgs[0] != '!' && szArgs[0] != '/')
	{
		WriteChatLog(client, command, szArgs);
	}
	return Plugin_Continue;
}

public Action Command_SponsorLog(int client, const char[] command, int argc)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return Plugin_Continue;

	int tick = GetGameTickCount();
	if (g_iLastSponsorTick[client] == tick)
		return Plugin_Continue;

	char cmdKey[64];
	if (!NormalizeCommandKey(command, cmdKey, sizeof(cmdKey)) || IsCommandIgnored(cmdKey))
		return Plugin_Continue;

	g_iLastSponsorTick[client] = tick;
	char detail[32];
	FormatEx(detail, sizeof(detail), "sm_%s", cmdKey);
	WriteClientAudit(client, "sponsor_cmd", detail);
	return Plugin_Continue;
}

public Action Command_ActionAuditLog(int client, const char[] command, int argc)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return Plugin_Continue;

	char cmdKey[64];
	if (!NormalizeCommandKey(command, cmdKey, sizeof(cmdKey)) || IsCommandIgnored(cmdKey))
		return Plugin_Continue;

	if (StrEqual(cmdKey, "choose_opendoor") || StrEqual(cmdKey, "choose_closedoor"))
	{
		float now = GetEngineTime();
		if (g_fLastDoorAuditTime[client] > 0.0 && (now - g_fLastDoorAuditTime[client]) < CHATLOG_DOOR_AUDIT_COOLDOWN)
			return Plugin_Continue;

		g_fLastDoorAuditTime[client] = now;
	}

	char detail[256], rawArgs[192];
	if (StrEqual(cmdKey, "callvote"))
	{
		char issue[32], targetArg[32];
		GetCmdArg(1, issue, sizeof(issue));
		GetCmdArg(2, targetArg, sizeof(targetArg));
		if (StrEqual(issue, "Kick", false) && targetArg[0] != '\0')
		{
			int target = GetClientOfUserId(StringToInt(targetArg));
			if (target > 0 && target <= MaxClients && IsClientConnected(target))
			{
				char targetSteamId[32];
				if (IsFakeClient(target))
					strcopy(targetSteamId, sizeof(targetSteamId), "BOT");
				else if (!GetClientAuthId(target, AuthId_Steam2, targetSteamId, sizeof(targetSteamId)))
					strcopy(targetSteamId, sizeof(targetSteamId), "UNAUTH");

				FormatEx(detail, sizeof(detail), "callvote Kick #%s %N (%s)", targetArg, target, targetSteamId);
			}
		}
	}

	if (detail[0] == '\0')
	{
		GetCmdArgString(rawArgs, sizeof(rawArgs));
		StripQuotes(rawArgs);
		TrimString(rawArgs);
		if (rawArgs[0] != '\0')
			FormatEx(detail, sizeof(detail), "%s %s", command, rawArgs);
		else
			strcopy(detail, sizeof(detail), command);
	}

	WriteClientAudit(client, "action", detail);
	return Plugin_Continue;
}

public Action Command_SmAuditListener(int client, const char[] command, int argc)
{
	if ((command[0] != 's' && command[0] != 'S') || (command[1] != 'm' && command[1] != 'M'))
		return Plugin_Continue;

	if (command[2] != '_' && command[2] != '\0')
		return Plugin_Continue;

	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return Plugin_Continue;

	char cmdKey[64];
	if (!NormalizeCommandKey(command, cmdKey, sizeof(cmdKey)))
		return Plugin_Continue;

	// 赞助相关命令由 Command_SponsorLog 脱敏记录，此处不采集可能含邮箱等隐私的参数
	if (IsSponsorCommandKey(cmdKey))
		return Plugin_Continue;

	if (g_iLastChatCmdTick[client] == GetGameTickCount()
		&& g_sLastChatCmdKey[client][0] != '\0'
		&& StrEqual(cmdKey, g_sLastChatCmdKey[client], false))
	{
		g_sLastChatCmdKey[client][0] = '\0';
		return Plugin_Continue;
	}

	if (IsCommandIgnored(cmdKey))
		return Plugin_Continue;

	char rawArgs[192], detail[256];
	GetCmdArgString(rawArgs, sizeof(rawArgs));
	StripQuotes(rawArgs);
	TrimString(rawArgs);
	if (rawArgs[0] != '\0')
		FormatEx(detail, sizeof(detail), "%s %s", command, rawArgs);
	else
		strcopy(detail, sizeof(detail), command);

	WriteClientAudit(client, "sm_cmd", detail);
	return Plugin_Continue;
}

void RecordChatCommandAudit(int client, const char[] command, const char[] szArgs)
{
	if (!g_bAuditConnected || !chatlog_auditEnabled.BoolValue || client <= 0 || client > MaxClients || !IsClientConnected(client) || IsFakeClient(client))
		return;

	char cmdKey[64];
	if (!NormalizeCommandKey(szArgs, cmdKey, sizeof(cmdKey)))
		return;

	int tick = GetGameTickCount();
	strcopy(g_sLastChatCmdKey[client], sizeof(g_sLastChatCmdKey[]), cmdKey);
	g_iLastChatCmdTick[client] = tick;

	// 赞助命令（如 !wc 邮箱）严禁记录参数，也不进入公开 chat_log，仅脱敏写入 chat_audit_log
	if (IsSponsorCommandKey(cmdKey))
	{
		g_iLastSponsorTick[client] = tick;
		if (!IsCommandIgnored(cmdKey))
		{
			char sanitized[68];
			FormatEx(sanitized, sizeof(sanitized), "%c%s", szArgs[0], cmdKey);
			WriteClientAudit(client, "sponsor_cmd", sanitized);
		}
		return;
	}

	if (IsCommandIgnored(cmdKey))
		return;

	WriteClientAudit(client, StrContains(command, "_", false) != -1 ? "chat_cmd_team" : "chat_cmd", szArgs);
}

bool NormalizeCommandKey(const char[] rawInput, char[] outKey, int maxlen)
{
	outKey[0] = '\0';
	int pos = 0;
	while (rawInput[pos] == ' ' || rawInput[pos] == '\t' || rawInput[pos] == '\r' || rawInput[pos] == '\n' || rawInput[pos] == '"')
	{
		pos++;
	}

	if (rawInput[pos] == '!' || rawInput[pos] == '/')
	{
		pos++;
	}

	char token[64];
	int len = 0;
	while (rawInput[pos] != '\0'
		&& rawInput[pos] != ' '
		&& rawInput[pos] != '\t'
		&& rawInput[pos] != '\r'
		&& rawInput[pos] != '\n'
		&& rawInput[pos] != '"'
		&& rawInput[pos] != ';'
		&& len < sizeof(token) - 1)
	{
		char c = rawInput[pos++];
		if (c >= 'A' && c <= 'Z')
			c = view_as<char>(c + ('a' - 'A'));
		token[len++] = c;
	}
	token[len] = '\0';

	if (len == 0)
		return false;

	int start = 0;
	if (len >= 3 && token[0] == 's' && token[1] == 'm' && token[2] == '_')
		start = 3;

	strcopy(outKey, maxlen, token[start]);
	return outKey[0] != '\0';
}

bool NormalizeKeywordRule(const char[] rawInput, char[] outKeyword, int maxlen)
{
	strcopy(outKeyword, maxlen, rawInput);
	TrimString(outKeyword);
	if (outKeyword[0] == '\0')
		return false;

	for (int i = 0; outKeyword[i] != '\0'; i++)
	{
		if (outKeyword[i] >= 'A' && outKeyword[i] <= 'Z')
			outKeyword[i] = view_as<char>(outKeyword[i] + ('a' - 'A'));
	}
	return true;
}

bool IsCommandIgnored(const char[] cmdKey)
{
	if (cmdKey[0] == '\0' || g_hIgnoredCommands == null)
		return false;

	int dummy;
	return g_hIgnoredCommands.GetValue(cmdKey, dummy);
}

bool IsKeywordIgnored(const char[] text)
{
	if (text[0] == '\0' || g_hIgnoredKeywords == null)
		return false;

	int count = g_hIgnoredKeywords.Length;
	if (count == 0)
		return false;

	char keyword[CHATLOG_KEYWORD_MAX_BYTES];
	for (int i = 0; i < count; i++)
	{
		g_hIgnoredKeywords.GetString(i, keyword, sizeof(keyword));
		if (keyword[0] != '\0' && StrContains(text, keyword, false) != -1)
			return true;
	}
	return false;
}

bool IsSponsorCommandKey(const char[] cmdKey)
{
	for (int i = 0; i < sizeof(g_sSponsorCommandKeys); i++)
	{
		if (StrEqual(cmdKey, g_sSponsorCommandKeys[i], false))
			return true;
	}
	return false;
}

void WriteClientAudit(int client, const char[] eventType, const char[] detail)
{
	char steamId[32], clientName[MAX_NAME_LENGTH], ip[45], team[16];
	GetAuditClientIdentity(client, steamId, sizeof(steamId), clientName, sizeof(clientName), ip, sizeof(ip));
	if (IsClientInGame(client))
		GetTeamLabel(GetClientTeam(client), team, sizeof(team));
	else
		strcopy(team, sizeof(team), "Connecting");

	WriteAuditRow(eventType, team, steamId, clientName, ip, "", detail);
}

void GetAuditClientIdentity(int client, char[] steamId, int steamIdLen, char[] clientName, int nameLen, char[] ip, int ipLen)
{
	if (!GetClientAuthId(client, AuthId_Steam2, steamId, steamIdLen))
		strcopy(steamId, steamIdLen, "UNAUTH");

	if (!GetClientName(client, clientName, nameLen))
		clientName[0] = '\0';

	if (!GetClientIP(client, ip, ipLen, true))
		ip[0] = '\0';
}

void GetTeamLabel(int team, char[] buffer, int maxlen)
{
	switch (team)
	{
		case 1: strcopy(buffer, maxlen, "Spec");
		case 2: strcopy(buffer, maxlen, "Survivor");
		case 3: strcopy(buffer, maxlen, "Infected");
		case 4: strcopy(buffer, maxlen, "Passing");
		default: strcopy(buffer, maxlen, "Unassigned");
	}
}

void TrimUtf8ToMaxChars(char[] text, int maxChars)
{
	int bytePos = 0;
	int charCount = 0;
	while (text[bytePos] != '\0')
	{
		if (charCount >= maxChars)
		{
			text[bytePos] = '\0';
			return;
		}

		int b = text[bytePos] & 0xFF;
		int seqLen = 1;
		if ((b & 0x80) == 0)
			seqLen = 1;
		else if ((b & 0xE0) == 0xC0)
			seqLen = 2;
		else if ((b & 0xF0) == 0xE0)
			seqLen = 3;
		else if ((b & 0xF8) == 0xF0)
			seqLen = 4;
		else
		{
			text[bytePos] = '\0';
			return;
		}

		for (int k = 1; k < seqLen; k++)
		{
			if ((text[bytePos + k] & 0xC0) != 0x80)
			{
				text[bytePos] = '\0';
				return;
			}
		}

		bytePos += seqLen;
		charCount++;
	}
}

void WriteAuditRow(const char[] eventType, const char[] team, const char[] steamId, const char[] clientName, const char[] ip, const char[] country, const char[] rawDetail)
{
	if (!g_bAuditConnected || g_hDatabase == null)
		return;

	// 上传前在内存中比对屏蔽关键词，命中即直接丢弃不发 SQL
	if (IsKeywordIgnored(rawDetail))
		return;

	int serverPort = g_cvHostport != null ? g_cvHostport.IntValue : 0;
	char szTime[32], szMap[128], szServerName[64], szDetail[512], szQuery[1024];
	FormatTime(szTime, sizeof(szTime), "%Y-%m-%d %T", GetTime());
	GetCurrentMap(szMap, sizeof(szMap));
	if (g_cvHostname != null)
		g_cvHostname.GetString(szServerName, sizeof(szServerName));
	else
		szServerName[0] = '\0';

	strcopy(szDetail, sizeof(szDetail), rawDetail);
	TrimUtf8ToMaxChars(szDetail, CHATLOG_AUDIT_DETAIL_MAX_CHARS);

	g_hDatabase.Format(
		szQuery,
		sizeof(szQuery),
		"INSERT INTO chat_audit_log (date, server, port, map, event_type, team, steamid, name, ip, country, detail) VALUES ('%s', '%s', '%d', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s')",
		szTime,
		szServerName,
		serverPort,
		szMap,
		eventType,
		team,
		steamId,
		clientName,
		ip,
		country,
		szDetail
	);
	g_hDatabase.Query(SQL_Error, szQuery);
}

void WriteChatLog(int client, const char[] command, const char[] message)
{
	if (!g_bFullyConnected || g_hDatabase == null || client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
		return;

	int iMsgStyle = StrContains(command, "_", false) != -1 ? 1 : 0;
	int iServerPort = g_cvHostport != null ? g_cvHostport.IntValue : 0;
	char szQuery[768], szTime[32], szMap[128], szSteamID[32], szServerName[64], szMessage[512];
	FormatTime(szTime, sizeof(szTime), "%Y-%m-%d %T", GetTime());
	GetCurrentMap(szMap, sizeof(szMap));

	if (!GetClientAuthId(client, AuthId_Steam2, szSteamID, sizeof(szSteamID)))
		return;

	if (g_cvHostname != null)
		g_cvHostname.GetString(szServerName, sizeof(szServerName));
	else
		szServerName[0] = '\0';

	strcopy(szMessage, sizeof(szMessage), message);
	TrimUtf8ToMaxChars(szMessage, CHATLOG_MESSAGE_MAX_CHARS);

	g_hDatabase.Format(szQuery, sizeof(szQuery), "INSERT INTO chat_log (date, map, steamid, name, message_style, message, server, port) VALUES ('%s', '%s', '%s', '%N', '%d', '%s', '%s', '%d')", szTime, szMap, szSteamID, client, iMsgStyle, szMessage, szServerName, iServerPort);
	g_hDatabase.Query(SQL_Error, szQuery);
}

public void SQL_Error(Database database, DBResultSet results, const char[] error, int data)
{
	if (results == null)
	{
		LogError("[chatlog] SQL 查询失败: %s", error);
		if (SQL_IsConnectionLostError(error))
			SQL_MarkDatabaseUnavailable();
	}
}
