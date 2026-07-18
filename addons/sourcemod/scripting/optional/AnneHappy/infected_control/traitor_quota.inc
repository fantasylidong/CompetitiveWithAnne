#if defined _infected_control_traitor_quota_included
    #endinput
#endif
#define _infected_control_traitor_quota_included

#define TRAITOR_QUOTA_AUTH_LENGTH   64
#define TRAITOR_QUOTA_NAME_LENGTH   64
#define TRAITOR_QUOTA_TABLE_LENGTH  64

static Database g_hTraitorQuotaDb = null;
static bool g_bTraitorQuotaSchemaReady = false;
static bool g_bTraitorQuotaDbIsMySQL = false;

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

    g_bTraitorQuotaSchemaReady = false;
    g_bTraitorQuotaDbIsMySQL = false;
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
        CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaExhausted", used, total);
        return false;
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
        CPrintToChat(client, "%t", "InfectedControl_TraitorQuotaExhausted", used, total);
        return false;
    }

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    int now = GetTime();
    char query[512];
    FormatEx(query, sizeof(query),
        "UPDATE `%s` SET used_count = used_count + %d, `updated_at` = %d WHERE `auth_id` = '%s'",
        table, cost, now, escAuth);

    if (!SQL_FastQuery(g_hTraitorQuotaDb, query))
    {
        TraitorQuota_LogSqlError("consume quota");
        return false;
    }

    return true;
}

bool TraitorQuota_Refund(int client, int cost = 1)
{
    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    int total;
    int used;
    if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth)))
        return false;

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
    int total;
    int used;
    if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth)))
        return false;

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

    return true;
}

static bool TraitorQuota_ReadClientQuota(int client, int &total, int &used, char[] auth = "", int authMaxLen = 0)
{
    total = 0;
    used = 0;

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

    return TraitorQuota_EnsureClientRow(client, localAuth, total, used);
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

static bool TraitorQuota_EnsureClientRow(int client, const char[] auth, int &total, int &used)
{
    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT `total_count`, `used_count`, `quota_day` FROM `%s` WHERE `auth_id` = '%s'",
        table, escAuth);

    DBResultSet results = SQL_Query(g_hTraitorQuotaDb, query);
    if (results == null)
    {
        TraitorQuota_LogSqlError("read quota");
        return false;
    }

    int today = TraitorQuota_GetToday();
    if (results.FetchRow())
    {
        total = results.FetchInt(0);
        used = results.FetchInt(1);
        int quotaDay = results.FetchInt(2);
        delete results;

        if (quotaDay != today)
        {
            used = 0;
            if (!TraitorQuota_ResetClientDay(table, escAuth, today))
                return false;
        }

        if (total < 0)
            total = 0;

        if (!Traitor_IsAdminClient(client))
            total = gCV.iTraitorPublicDailyQuota;

        return true;
    }

    delete results;
    total = Traitor_IsAdminClient(client)
        ? gCV.iTraitorDailyQuota
        : gCV.iTraitorPublicDailyQuota;
    used = 0;
    return TraitorQuota_InsertClientRow(client, table, escAuth, today, total);
}

static bool TraitorQuota_GetTankBlockRemaining(int client, int &remaining)
{
    remaining = 0;

    char auth[TRAITOR_QUOTA_AUTH_LENGTH];
    int total;
    int used;
    if (!TraitorQuota_ReadClientQuota(client, total, used, auth, sizeof(auth)))
        return false;

    char table[TRAITOR_QUOTA_TABLE_LENGTH];
    if (!TraitorQuota_GetTableName(table, sizeof(table)))
        return false;

    char escAuth[TRAITOR_QUOTA_AUTH_LENGTH * 2 + 1];
    if (!SQL_EscapeString(g_hTraitorQuotaDb, auth, escAuth, sizeof(escAuth)))
        return false;

    char query[512];
    FormatEx(query, sizeof(query),
        "SELECT `tank_block_until` FROM `%s` WHERE `auth_id` = '%s'",
        table, escAuth);

    DBResultSet results = SQL_Query(g_hTraitorQuotaDb, query);
    if (results == null)
    {
        TraitorQuota_LogSqlError("read tank block");
        return false;
    }

    int blockUntil = 0;
    if (results.FetchRow())
        blockUntil = results.FetchInt(0);

    delete results;

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
        "INSERT INTO `%s` (`auth_id`, `total_count`, `used_count`, `quota_day`, `tank_block_until`, `last_name`, `updated_at`) "
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
