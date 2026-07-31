#if defined _infected_control_traitor_quota_included
    #endinput
#endif
#define _infected_control_traitor_quota_included

#define TRAITOR_QUOTA_AUTH_LENGTH   64
#define TRAITOR_QUOTA_NAME_LENGTH   64
#define TRAITOR_QUOTA_TABLE_LENGTH  64
#define TRAITOR_ADMIN_DB_CONFIG     "sourcebans"
#define TRAITOR_ADMIN_TABLE         "sb_admins"
#define TRAITOR_ADMIN_YEAR_SECONDS  (365 * 24 * 60 * 60)
#define TRAITOR_ADMIN_YEAR_BONUS    50
#define TRAITOR_ADMIN_QUOTA_MAX     10000
#define TRAITOR_ADMIN_CACHE_SECONDS 300
#define TRAITOR_QUOTA_CACHE_SECONDS 30

static Database g_hTraitorQuotaDb = null;
static Database g_hTraitorAdminDb = null;
static bool g_bTraitorQuotaSchemaReady = false;
static bool g_bTraitorQuotaDbIsMySQL = false;
static int g_iTraitorAdminDbRetryAfter = 0;
static int g_iTraitorAdminQuotaCache[MAXPLAYERS + 1];
static int g_iTraitorAdminQuotaCacheUntil[MAXPLAYERS + 1];
static char g_sTraitorAdminQuotaAuth[MAXPLAYERS + 1][TRAITOR_QUOTA_AUTH_LENGTH];
static bool g_bTraitorQuotaCacheReady[MAXPLAYERS + 1];
static int g_iTraitorQuotaCacheUntil[MAXPLAYERS + 1];
static int g_iTraitorQuotaCacheDay[MAXPLAYERS + 1];
static int g_iTraitorQuotaCacheTotal[MAXPLAYERS + 1];
static int g_iTraitorQuotaCacheUsed[MAXPLAYERS + 1];
static int g_iTraitorQuotaCacheTankBlockUntil[MAXPLAYERS + 1];
static char g_sTraitorQuotaCacheAuth[MAXPLAYERS + 1][TRAITOR_QUOTA_AUTH_LENGTH];

bool Traitor_IsAdminClient(int client)
{
    return IsValidClient(client)
        && CheckCommandAccess(client, "infected_control_traitor_admin", ADMFLAG_GENERIC);
}

void TraitorQuota_Init()
{
    TraitorQuota_Connect();
}

void TraitorQuota_Close()
{
    if (g_hTraitorQuotaDb != null)
    {
        delete g_hTraitorQuotaDb;
        g_hTraitorQuotaDb = null;
    }

    if (g_hTraitorAdminDb != null)
    {
        delete g_hTraitorAdminDb;
        g_hTraitorAdminDb = null;
    }

    g_bTraitorQuotaSchemaReady = false;
    g_bTraitorQuotaDbIsMySQL = false;
    g_iTraitorAdminDbRetryAfter = 0;
    TraitorQuota_InvalidateAdminQuotaCache();
}

void TraitorQuota_InvalidateClientCache(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_bTraitorQuotaCacheReady[client] = false;
    g_iTraitorQuotaCacheUntil[client] = 0;
    g_iTraitorQuotaCacheDay[client] = 0;
    g_iTraitorQuotaCacheTotal[client] = 0;
    g_iTraitorQuotaCacheUsed[client] = 0;
    g_iTraitorQuotaCacheTankBlockUntil[client] = 0;
    g_sTraitorQuotaCacheAuth[client][0] = '\0';
}

static void TraitorQuota_StoreClientCache(int client, const char[] auth, int total, int used, int quotaDay, int tankBlockUntil)
{
    if (client < 1 || client > MaxClients)
        return;

    g_bTraitorQuotaCacheReady[client] = true;
    g_iTraitorQuotaCacheUntil[client] = GetTime() + TRAITOR_QUOTA_CACHE_SECONDS;
    g_iTraitorQuotaCacheDay[client] = quotaDay;
    g_iTraitorQuotaCacheTotal[client] = total;
    g_iTraitorQuotaCacheUsed[client] = used;
    g_iTraitorQuotaCacheTankBlockUntil[client] = tankBlockUntil;
    strcopy(g_sTraitorQuotaCacheAuth[client], sizeof(g_sTraitorQuotaCacheAuth[]), auth);
}

void TraitorQuota_InvalidateAdminQuotaCache()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iTraitorAdminQuotaCache[client] = 0;
        g_iTraitorAdminQuotaCacheUntil[client] = 0;
        g_sTraitorAdminQuotaAuth[client][0] = '\0';
        TraitorQuota_InvalidateClientCache(client);
    }
}

bool TraitorQuota_CanUse(int client, int cost = 1)
{
    int total;
    int used;
    if (!TraitorQuota_ReadClientQuota(client, total, used))
        return false;

    if (cost < 1)
        cost = 1;

    if (used + cost > total)
    {
        TraitorQuota_InvalidateClientCache(client);
        if (!TraitorQuota_ReadClientQuota(client, total, used))
            return false;

        if (used + cost > total)
        {
            CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaExhausted", used, total);
            return false;
        }
    }

    return true;
}

bool TraitorQuota_Consume(int client, int cost = 1)
{
    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    int total;
    int used;
    if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth)))
        return false;

    if (cost < 1)
        cost = 1;

    if (used + cost > total)
    {
        TraitorQuota_InvalidateClientCache(client);
        if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth)))
            return false;

        if (used + cost > total)
        {
            CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaExhausted", used, total);
            return false;
        }
    }

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    int now = GetTime();
    int today = TraitorQuota_GetToday();
    char query[1024];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET "
        ... "total_count = %d, "
        ... "used_count = CASE WHEN quota_day <> %d THEN %d ELSE used_count + %d END, "
        ... "quota_day = %d, `updated_at` = %d "
        ... "WHERE `auth_id` = '%s' AND "
        ... "((quota_day <> %d AND %d <= %d) OR (quota_day = %d AND used_count + %d <= %d))",
        table,
        total,
        today, cost, cost,
        today, now,
        escAuth,
        today, cost, total,
        today, cost, total);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("consume quota");
        return false;
    }

    if (SQL_GetAffectedRows(g_hTraitorQuotaDb) <= 0)
    {
        TraitorQuota_InvalidateClientCache(client);

        int freshTotal;
        int freshUsed;
        if (TraitorQuota_ReadClientQuota(client, freshTotal, freshUsed)
            && freshUsed + cost > freshTotal)
        {
            CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaExhausted", freshUsed, freshTotal);
        }
        return false;
    }

    TraitorQuota_StoreClientCache(client, auth, total, used + cost, today, g_iTraitorQuotaCacheTankBlockUntil[client]);

    return true;
}

bool TraitorQuota_Refund(int client, int cost = 1)
{
    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    if (!TraitorQuota_EnsureDatabase()
        || !TraitorQuota_GetClientAuth(client, auth, sizeof(auth)))
    {
        if (IsValidClient(client))
            CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaDbUnavailable");
        return false;
    }

    if (cost < 1)
        cost = 1;

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET used_count = CASE WHEN used_count >= %d THEN used_count - %d ELSE 0 END, `updated_at` = %d WHERE `auth_id` = '%s'",
        table, cost, cost, now, escAuth);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("refund quota");
        return false;
    }

    if (g_bTraitorQuotaCacheReady[client]
        && StrEqual(g_sTraitorQuotaCacheAuth[client], auth, false))
    {
        g_iTraitorQuotaCacheUsed[client] -= cost;
        if (g_iTraitorQuotaCacheUsed[client] < 0)
            g_iTraitorQuotaCacheUsed[client] = 0;
        g_iTraitorQuotaCacheUntil[client] = now + TRAITOR_QUOTA_CACHE_SECONDS;
    }
    else
    {
        TraitorQuota_InvalidateClientCache(client);
    }

    return true;
}

bool TraitorQuota_CanUseTank(int client)
{
    int remaining;
    if (!TraitorQuota_GetTankBlockRemaining(client, remaining))
        return false;

    if (remaining <= 0)
        return true;

    int minutes = (remaining + 59) / 60;
    CPrintToChat(client, "%t", "InfectedControl_TraitorTankBlocked", minutes);
    return false;
}

bool TraitorQuota_BlockTank(int client, int seconds)
{
    if (seconds < 1)
        return false;

    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    if (!TraitorQuota_EnsureDatabase()
        || !TraitorQuota_GetClientAuth(client, auth, sizeof(auth)))
    {
        if (IsValidClient(client))
            CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaDbUnavailable");
        return false;
    }

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    int now = GetTime();
    int blockUntil = now + seconds;
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET tank_block_until = CASE WHEN tank_block_until > %d THEN tank_block_until ELSE %d END, `updated_at` = %d WHERE `auth_id` = '%s'",
        table, blockUntil, blockUntil, now, escAuth);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("block tank traitor");
        return false;
    }

    if (g_bTraitorQuotaCacheReady[client]
        && StrEqual(g_sTraitorQuotaCacheAuth[client], auth, false))
    {
        if (blockUntil > g_iTraitorQuotaCacheTankBlockUntil[client])
            g_iTraitorQuotaCacheTankBlockUntil[client] = blockUntil;
        g_iTraitorQuotaCacheUntil[client] = now + TRAITOR_QUOTA_CACHE_SECONDS;
    }
    else
    {
        TraitorQuota_InvalidateClientCache(client);
    }

    return true;
}

static bool TraitorQuota_ReadClientQuota(int client, int &total, int &used, char[] auth = "", int authMaxLen = 0, int &tankBlockUntil = 0)
{
    total = 0;
    used = 0;
    tankBlockUntil = 0;

    if (!TraitorQuota_EnsureDatabase())
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaDbUnavailable");
        return false;
    }

    char localAuth[TRAITOR_QUOTA_AUTH_LENGTH];
    if (!TraitorQuota_GetClientAuth(client, localAuth, sizeof(localAuth)))
    {
        CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaDbUnavailable");
        return false;
    }

    if (authMaxLen > 0)
        strcopy(auth, authMaxLen, localAuth);

    int today = TraitorQuota_GetToday();
    int now = GetTime();
    if (g_bTraitorQuotaCacheReady[client]
        && g_iTraitorQuotaCacheUntil[client] > now
        && g_iTraitorQuotaCacheDay[client] == today
        && StrEqual(g_sTraitorQuotaCacheAuth[client], localAuth, false))
    {
        total = g_iTraitorQuotaCacheTotal[client];
        used = g_iTraitorQuotaCacheUsed[client];
        tankBlockUntil = g_iTraitorQuotaCacheTankBlockUntil[client];
        return true;
    }

    if (!TraitorQuota_EnsureClientRow(client, localAuth, total, used, tankBlockUntil))
        return false;

    TraitorQuota_StoreClientCache(client, localAuth, total, used, today, tankBlockUntil);
    return true;
}

static bool TraitorQuota_EnsureDatabase()
{
    if (g_hTraitorQuotaDb == null)
    {
        TraitorQuota_Connect();
    }
    else if (!g_bTraitorQuotaSchemaReady)
    {
        TraitorQuota_CreateTable();
    }

    return g_hTraitorQuotaDb != null && g_bTraitorQuotaSchemaReady;
}

static void TraitorQuota_Connect()
{
    if (g_hTraitorQuotaDb != null)
        return;

    char configName[TRAITOR_QUOTA_TABLE_LENGTH];
    gCV.TraitorQuotaDb.GetString(configName, sizeof(configName));
    TrimString(configName);
    if (configName[0] == '\0')
        strcopy(configName, sizeof(configName), DEFAULT_TRAITOR_QUOTA_DB_CONFIG);

    if (!SQL_CheckConfig(configName))
    {
        LogError("[IC][TRAITOR] quota database config \"%s\" is missing.", configName);
        return;
    }

    char error[256];
    g_hTraitorQuotaDb = SQL_Connect(configName, false, error, sizeof(error));
    if (g_hTraitorQuotaDb == null)
    {
        LogError("[IC][TRAITOR] failed to connect quota database \"%s\": %s", configName, error);
        return;
    }

    char ident[16];
    SQL_ReadDriver(g_hTraitorQuotaDb, ident, sizeof(ident));
    g_bTraitorQuotaDbIsMySQL = StrEqual(ident, "mysql", false);
    if (!g_bTraitorQuotaDbIsMySQL)
    {
        LogError("[IC][TRAITOR] quota database \"%s\" must use MySQL; got driver \"%s\".", configName, ident);
        delete g_hTraitorQuotaDb;
        g_hTraitorQuotaDb = null;
        return;
    }

    SQL_SetCharset(g_hTraitorQuotaDb, "utf8mb4");

    TraitorQuota_CreateTable();
}

static void TraitorQuota_CreateTable()
{
    g_bTraitorQuotaSchemaReady = false;

    if (g_hTraitorQuotaDb == null)
        return;

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return;

    char query[1024];
    if (g_bTraitorQuotaDbIsMySQL)
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS `%s` ("
            ... "`auth_id` varchar(64) NOT NULL,"
            ... "`total_count` int NOT NULL DEFAULT 100,"
            ... "`used_count` int NOT NULL DEFAULT 0,"
            ... "`quota_day` int NOT NULL DEFAULT 0,"
            ... "`tank_block_until` int NOT NULL DEFAULT 0,"
            ... "`last_name` varchar(64) NOT NULL DEFAULT '',"
            ... "`updated_at` int NOT NULL DEFAULT 0,"
            ... "PRIMARY KEY (`auth_id`)"
            ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
            table);
    }
    else
    {
        FormatEx(query, sizeof(query),
            "CREATE TABLE IF NOT EXISTS `%s` ("
            ... "`auth_id` TEXT NOT NULL,"
            ... "`total_count` INTEGER NOT NULL DEFAULT 100,"
            ... "`used_count` INTEGER NOT NULL DEFAULT 0,"
            ... "`quota_day` INTEGER NOT NULL DEFAULT 0,"
            ... "`tank_block_until` INTEGER NOT NULL DEFAULT 0,"
            ... "`last_name` TEXT NOT NULL DEFAULT '',"
            ... "`updated_at` INTEGER NOT NULL DEFAULT 0,"
            ... "PRIMARY KEY (`auth_id`)"
            ... ")",
            table);
    }

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("create quota table");
        return;
    }

    if (!TraitorQuota_EnsureTankBlockColumn(table))
        return;

    g_bTraitorQuotaSchemaReady = true;
}

static bool TraitorQuota_EnsureTankBlockColumn(const char[] table)
{
    if (TraitorQuota_TableHasColumn(table, "tank_block_until"))
        return true;

    char typeName[8];
    if (g_bTraitorQuotaDbIsMySQL)
        strcopy(typeName, sizeof(typeName), "int");
    else
        strcopy(typeName, sizeof(typeName), "INTEGER");

    char query[256];
    FormatEx(query, sizeof(query),
        "ALTER TABLE `%s` ADD COLUMN `tank_block_until` %s NOT NULL DEFAULT 0",
        table, typeName);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("add tank block column");
        return false;
    }

    return true;
}

static bool TraitorQuota_TableHasColumn(const char[] table, const char[] column)
{
    char query[256];
    if (g_bTraitorQuotaDbIsMySQL)
        FormatEx(query, sizeof(query), "SHOW COLUMNS FROM `%s` LIKE '%s'", table, column);
    else
        FormatEx(query, sizeof(query), "PRAGMA table_info(`%s`)", table);

    DBResultSet results = SQL_Query(g_hTraitorQuotaDb, query);
    if (results == null)
    {
        TraitorQuota_LogSqlError("inspect quota table");
        return false;
    }

    if (g_bTraitorQuotaDbIsMySQL)
    {
        bool hasColumn = results.FetchRow();
        delete results;
        return hasColumn;
    }

    char name[TRAITOR_QUOTA_TABLE_LENGTH];
    while (results.FetchRow())
    {
        results.FetchString(1, name, sizeof(name));
        if (StrEqual(name, column, false))
        {
            delete results;
            return true;
        }
    }

    delete results;
    return false;
}

static bool TraitorQuota_EnsureClientRow(int client, const char[] auth, int &total, int &used, int &tankBlockUntil, bool allowInsert = true)
{
    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT `total_count`, `used_count`, `quota_day`, `tank_block_until` FROM `%s` WHERE `auth_id` = '%s'",
        table, escAuth);

    DBResultSet results = SQL_Query(g_hTraitorQuotaDb, query);
    if (results == null)
    {
        TraitorQuota_LogSqlError("read quota");
        return false;
    }

    int desiredTotal = Traitor_IsAdminClient(client)
        ? TraitorQuota_GetAdminDailyTotal(client, auth)
        : gCV.iTraitorPublicDailyQuota;
    int today = TraitorQuota_GetToday();
    if (results.FetchRow())
    {
        int storedTotal = results.FetchInt(0);
        used = results.FetchInt(1);
        int quotaDay = results.FetchInt(2);
        tankBlockUntil = results.FetchInt(3);
        delete results;

        if (quotaDay != today)
        {
            used = 0;
            if (!TraitorQuota_ResetClientDay(table, escAuth, today))
                return false;
        }

        total = desiredTotal;
        if (storedTotal != desiredTotal
            && !TraitorQuota_UpdateClientTotal(table, escAuth, desiredTotal))
        {
            return false;
        }

        return true;
    }

    delete results;
    if (!allowInsert)
        return false;

    total = desiredTotal;
    used = 0;
    tankBlockUntil = 0;
    if (!TraitorQuota_InsertClientRow(client, table, escAuth, today, total))
        return false;

    if (SQL_GetAffectedRows(g_hTraitorQuotaDb) == 0)
        return TraitorQuota_EnsureClientRow(client, auth, total, used, tankBlockUntil, false);

    return true;
}

static int TraitorQuota_GetAdminDailyTotal(int client, const char[] auth)
{
    int baseQuota = gCV.iTraitorDailyQuota;
    int now = GetTime();
    if (client >= 1 && client <= MaxClients
        && g_iTraitorAdminQuotaCacheUntil[client] > now
        && StrEqual(g_sTraitorAdminQuotaAuth[client], auth, false))
    {
        return g_iTraitorAdminQuotaCache[client];
    }

    int total = baseQuota;
    if (TraitorQuota_EnsureAdminDatabase())
    {
        char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
        char authSuffix[TRAITOR_QUOTA_AUTH_LENGTH];
        char escAuthSuffix[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
        if (SQL_EscapeString(g_hTraitorAdminDb, auth, escAuth, sizeof(escAuth))
            && strlen(auth) > 8)
        {
            strcopy(authSuffix, sizeof(authSuffix), auth[8]);
            if (SQL_EscapeString(g_hTraitorAdminDb, authSuffix, escAuthSuffix, sizeof(escAuthSuffix)))
            {
                char query[512];
                FormatEx(query, sizeof(query),
                    "SELECT `expires` FROM `%s` "
                    ... "WHERE `authid` = '%s' OR `authid` REGEXP '^STEAM_[0-9]:%s$' "
                    ... "ORDER BY (`authid` = '%s') DESC LIMIT 1",
                    TRAITOR_ADMIN_TABLE, escAuth, escAuthSuffix, escAuth);

                DBResultSet results = SQL_Query(g_hTraitorAdminDb, query);
                if (results == null)
                {
                    TraitorQuota_LogAdminSqlError("read admin expiry");
                }
                else
                {
                    if (results.FetchRow())
                    {
                        int expires = results.FetchInt(0);
                        if (expires > now)
                        {
                            int fullYears = (expires - now) / TRAITOR_ADMIN_YEAR_SECONDS;
                            total += fullYears * TRAITOR_ADMIN_YEAR_BONUS;
                            if (total > TRAITOR_ADMIN_QUOTA_MAX)
                                total = TRAITOR_ADMIN_QUOTA_MAX;
                        }
                    }
                    delete results;
                }
            }
        }
    }

    if (client >= 1 && client <= MaxClients)
    {
        g_iTraitorAdminQuotaCache[client] = total;
        g_iTraitorAdminQuotaCacheUntil[client] = now + TRAITOR_ADMIN_CACHE_SECONDS;
        strcopy(g_sTraitorAdminQuotaAuth[client], sizeof(g_sTraitorAdminQuotaAuth[]), auth);
    }
    return total;
}

static bool TraitorQuota_EnsureAdminDatabase()
{
    if (g_hTraitorAdminDb != null)
        return true;

    int now = GetTime();
    if (g_iTraitorAdminDbRetryAfter > now)
        return false;

    g_iTraitorAdminDbRetryAfter = now + TRAITOR_ADMIN_CACHE_SECONDS;
    if (!SQL_CheckConfig(TRAITOR_ADMIN_DB_CONFIG))
    {
        LogError("[IC][TRAITOR] admin expiry database config \"%s\" is missing.", TRAITOR_ADMIN_DB_CONFIG);
        return false;
    }

    char error[256];
    g_hTraitorAdminDb = SQL_Connect(TRAITOR_ADMIN_DB_CONFIG, false, error, sizeof(error));
    if (g_hTraitorAdminDb == null)
    {
        LogError("[IC][TRAITOR] failed to connect admin expiry database \"%s\": %s", TRAITOR_ADMIN_DB_CONFIG, error);
        return false;
    }

    char ident[16];
    SQL_ReadDriver(g_hTraitorAdminDb, ident, sizeof(ident));
    if (!StrEqual(ident, "mysql", false))
    {
        LogError("[IC][TRAITOR] admin expiry database \"%s\" must use MySQL; got driver \"%s\".", TRAITOR_ADMIN_DB_CONFIG, ident);
        delete g_hTraitorAdminDb;
        g_hTraitorAdminDb = null;
        return false;
    }

    SQL_SetCharset(g_hTraitorAdminDb, "utf8mb4");
    return true;
}

static bool TraitorQuota_GetTankBlockRemaining(int client, int &remaining)
{
    remaining = 0;

    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    int total;
    int used;
    int blockUntil;
    if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth), blockUntil))
        return false;

    int now = GetTime();
    if (blockUntil > now)
        remaining = blockUntil - now;

    return true;
}

static bool TraitorQuota_InsertClientRow(int client, const char[] table, const char[] escAuth, int today, int total)
{
    char name[TRAITOR_QUOTA_NAME_LENGTH];
    char escName[TRAITOR_QUOTA_NAME_LENGTH * 2 + 1];
    GetClientName(client, name, sizeof(name));
    if (!SQL_EscapeString(g_hTraitorQuotaDb, name, escName, sizeof(escName)))
        escName[0] = '\0';

    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "INSERT IGNORE INTO `%s` (`auth_id`, `total_count`, `used_count`, `quota_day`, `tank_block_until`, `last_name`, `updated_at`) "
        ... "VALUES ('%s', %d, 0, %d, 0, '%s', %d)",
        table, escAuth, total, today, escName, now);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("insert quota");
        return false;
    }

    return true;
}

static bool TraitorQuota_ResetClientDay(const char[] table, const char[] escAuth, int today)
{
    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET used_count = 0, quota_day = %d, `updated_at` = %d WHERE `auth_id` = '%s' AND quota_day != %d",
        table, today, now, escAuth, today);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("reset daily quota");
        return false;
    }

    return true;
}

static bool TraitorQuota_UpdateClientTotal(const char[] table, const char[] escAuth, int total)
{
    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET total_count = %d, `updated_at` = %d WHERE `auth_id` = '%s'",
        table, total, now, escAuth);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("update quota total");
        return false;
    }

    return true;
}

static int TraitorQuota_GetToday()
{
    char day[16];
    FormatTime(day, sizeof(day), "%Y%m%d", GetTime());
    return StringToInt(day);
}

static bool TraitorQuota_GetClientAuth(int client, char[] auth, int maxlen)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return false;

    if (!GetClientAuthId(client, AuthId_Steam2, auth, maxlen, true))
        return false;

    return auth[0] != '\0'
        && !StrEqual(auth, "BOT", false)
        && !StrEqual(auth, "STEAM_ID_PENDING", false)
        && !StrEqual(auth, "STEAM_ID_STOP_IGNORING_RETVALS", false);
}

static bool TraitorQuota_GetTableName(char[] table, int maxlen)
{
    gCV.TraitorQuotaTable.GetString(table, maxlen);
    TrimString(table);
    if (table[0] == '\0')
        strcopy(table, maxlen, "infected_control_traitor_quota");

    if (!TraitorQuota_IsSafeSqlIdentifier(table))
    {
        LogError("[IC][TRAITOR] unsafe quota table name \"%s\".", table);
        return false;
    }

    return true;
}

static bool TraitorQuota_IsSafeSqlIdentifier(const char[] name)
{
    int length = strlen(name);
    if (length < 1)
        return false;

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

static void TraitorQuota_LogSqlError(const char[] action)
{
    char error[256];
    SQL_GetError(g_hTraitorQuotaDb, error, sizeof(error));
    LogError("[IC][TRAITOR] failed to %s: %s", action, error);
}

static void TraitorQuota_LogAdminSqlError(const char[] action)
{
    char error[256];
    SQL_GetError(g_hTraitorAdminDb, error, sizeof(error));
    LogError("[IC][TRAITOR] failed to %s: %s", action, error);
}
