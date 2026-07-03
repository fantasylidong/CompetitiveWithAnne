#if defined _l4d_stats_quarter_rank_included
	#endinput
#endif
#define _l4d_stats_quarter_rank_included

// 季度榜模块。
// 每次 AddScore 同步写入当前季度积分；每个季度保留独立记录。

new Handle:cvar_QuarterRankEnable = INVALID_HANDLE;
new bool:g_bQuarterRankTableReady = false;
new g_iQuarterRankKey = 0;
new QuarterRankTotal = 0;
new ClientQuarterPoints[MAXPLAYERS + 1];
new ClientQuarterPlayTime[MAXPLAYERS + 1];
new ClientQuarterRank[MAXPLAYERS + 1];
new CheckQuarterPlayerPoint[100];

stock QuarterRank_CreateCvars()
{
	cvar_QuarterRankEnable = CreateConVar("l4d_stats_quarter_rank_enable", "1", "是否启用季度积分榜。0=关闭, 1=开启", 0, true, 0.0, true, 1.0);
}

stock QuarterRank_GetCurrentKey()
{
	decl String:YearText[8];
	decl String:MonthText[4];
	FormatTime(YearText, sizeof(YearText), "%Y", GetTime());
	FormatTime(MonthText, sizeof(MonthText), "%m", GetTime());

	new Year = StringToInt(YearText);
	new Month = StringToInt(MonthText);
	new Quarter = ((Month - 1) / 3) + 1;

	return Year * 10 + Quarter;
}

stock QuarterRank_GetCurrentQuarter()
{
	return QuarterRank_GetCurrentKey();
}

stock QuarterRank_FormatCurrentQuarter(String:buffer[], maxlength)
{
	new QuarterKey = QuarterRank_GetCurrentQuarter();
	new Year = QuarterKey / 10;
	new Quarter = QuarterKey % 10;
	Format(buffer, maxlength, "%i年第%i季度", Year, Quarter);
}

stock QuarterRank_ResetLocalCache()
{
	QuarterRankTotal = 0;

	for (new i = 1; i <= MaxClients; i++)
	{
		ClientQuarterPoints[i] = 0;
		ClientQuarterPlayTime[i] = 0;
		ClientQuarterRank[i] = 0;
	}

	for (new i = 0; i < 100; i++)
	{
		CheckQuarterPlayerPoint[i] = 0;
	}
}

stock QuarterRank_EnsureCurrentQuarter()
{
	new CurrentKey = QuarterRank_GetCurrentKey();
	if (g_iQuarterRankKey != CurrentKey)
	{
		g_iQuarterRankKey = CurrentKey;
		QuarterRank_ResetLocalCache();
	}

	if (db == INVALID_HANDLE || g_bQuarterRankTableReady)
		return;

	QuarterRank_MigrateSchema();
}

stock bool:QuarterRank_MigrateSchema()
{
	if (db == INVALID_HANDLE)
		return false;

	if (cvar_QuarterRankEnable == INVALID_HANDLE || !GetConVarBool(cvar_QuarterRankEnable))
		return false;

	decl String:query[512];
	Format(query, sizeof(query), "SHOW KEYS FROM `%sscore_quarter` WHERE Key_name = 'PRIMARY'", DbPrefix);

	new Handle:hndl = SQL_Query(db, query);
	if (hndl == INVALID_HANDLE)
	{
		decl String:Error[256];
		if (SQL_GetError(db, Error, sizeof(Error)))
			LogError("QuarterRank_MigrateSchema failed to inspect score_quarter primary key: %s", Error);
		else
			LogError("QuarterRank_MigrateSchema failed to inspect score_quarter primary key: unknown");

		g_bQuarterRankTableReady = false;
		return false;
	}

	new PrimaryColumnCount = 0;
	new SteamIDSeq = 0;
	new QuarterKeySeq = 0;
	decl String:ColumnName[64];

	while (SQL_FetchRow(hndl))
	{
		PrimaryColumnCount++;
		SQL_FetchString(hndl, 4, ColumnName, sizeof(ColumnName));
		if (StrEqual(ColumnName, "steamid", false))
			SteamIDSeq = SQL_FetchInt(hndl, 3);
		else if (StrEqual(ColumnName, "quarter_key", false))
			QuarterKeySeq = SQL_FetchInt(hndl, 3);
	}

	CloseHandle(hndl);

	if (PrimaryColumnCount == 2 && SteamIDSeq == 1 && QuarterKeySeq == 2)
	{
		g_bQuarterRankTableReady = true;
		return true;
	}

	if (PrimaryColumnCount == 0)
		Format(query, sizeof(query), "ALTER TABLE `%sscore_quarter` ADD PRIMARY KEY (`steamid`, `quarter_key`)", DbPrefix);
	else
		Format(query, sizeof(query), "ALTER TABLE `%sscore_quarter` DROP PRIMARY KEY, ADD PRIMARY KEY (`steamid`, `quarter_key`)", DbPrefix);

	if (!SQL_FastQuery(db, query))
	{
		decl String:Error[256];
		if (SQL_GetError(db, Error, sizeof(Error)))
			LogError("QuarterRank_MigrateSchema failed to migrate score_quarter primary key: %s", Error);
		else
			LogError("QuarterRank_MigrateSchema failed to migrate score_quarter primary key: unknown");

		g_bQuarterRankTableReady = false;
		return false;
	}

	g_bQuarterRankTableReady = true;
	LogMessage("[l4d_stats] score_quarter 已迁移为按玩家和季度共同分组的主键。");
	return true;
}

stock bool:QuarterRank_Enabled()
{
	if (cvar_QuarterRankEnable == INVALID_HANDLE || !GetConVarBool(cvar_QuarterRankEnable))
		return false;

	if (db == INVALID_HANDLE)
		return false;

	if (!g_bQuarterRankTableReady && !QuarterRank_MigrateSchema())
		return false;

	return true;
}

stock bool:QuarterRank_RecoverIfNeeded()
{
	if (cvar_QuarterRankEnable == INVALID_HANDLE || !GetConVarBool(cvar_QuarterRankEnable))
		return false;

	if (db == INVALID_HANDLE && !ConnectDB())
	{
		return false;
	}

	QuarterRank_EnsureCurrentQuarter();

	return QuarterRank_Enabled();
}

stock QuarterRank_GetModePointsColumn(Client, String:buffer[], maxlength)
{
	Stats_GetPointsColumnForTeam(GetClientTeam(Client), buffer, maxlength);
	if (StrEqual(buffer, "points"))
		Format(buffer, maxlength, "points_coop");
}

stock QuarterRank_RecordScore(Client, Score)
{
	if (Score == 0)
		return;

	QuarterRank_EnsureCurrentQuarter();

	if (!QuarterRank_Enabled() || !Stats_IsValidHumanClient(Client))
		return;

	ClientQuarterPoints[Client] += Score;
	if (ClientQuarterPoints[Client] < 0)
		ClientQuarterPoints[Client] = 0;

	decl String:SteamID[MAX_LINE_WIDTH];
	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	new InsertScore = Score;
	if (InsertScore < 0)
		InsertScore = 0;

	decl String:ModePointsColumn[32];
	QuarterRank_GetModePointsColumn(Client, ModePointsColumn, sizeof(ModePointsColumn));

	decl String:query[1024];
	Format(query, sizeof(query), "INSERT INTO `%sscore_quarter` (steamid, quarter_key, points, `%s`, updated) VALUES ('%s', %i, %i, %i, UNIX_TIMESTAMP()) ON DUPLICATE KEY UPDATE points = GREATEST(points + %i, 0), `%s` = GREATEST(`%s` + %i, 0), updated = VALUES(updated)",
		DbPrefix, ModePointsColumn, EscSteamID, g_iQuarterRankKey, InsertScore, InsertScore, Score, ModePointsColumn, ModePointsColumn, Score);
	SendSQLUpdate(query);
}

stock QuarterRank_RecordField(Client, const String:Field[], Amount)
{
	if (Amount <= 0)
		return;

	QuarterRank_EnsureCurrentQuarter();

	if (!QuarterRank_Enabled() || StatsDisabled() || !Stats_IsValidHumanClient(Client))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:query[1024];
	Format(query, sizeof(query), "INSERT INTO `%sscore_quarter` (steamid, quarter_key, `%s`, updated) VALUES ('%s', %i, %i, UNIX_TIMESTAMP()) ON DUPLICATE KEY UPDATE `%s` = `%s` + VALUES(`%s`), updated = VALUES(updated)",
		DbPrefix, Field, EscSteamID, g_iQuarterRankKey, Amount, Field, Field, Field);
	SendSQLUpdate(query);
}

stock QuarterRank_RecordInfectedKill(Client, const String:InfectedType[], Kills, Headshots = 0)
{
	if (Kills <= 0)
		return;

	QuarterRank_EnsureCurrentQuarter();

	if (!QuarterRank_Enabled() || StatsDisabled() || !Stats_IsValidHumanClient(Client))
		return;

	if (Headshots < 0)
		Headshots = 0;

	decl String:SteamID[MAX_LINE_WIDTH];
	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:KillColumn[32];
	Format(KillColumn, sizeof(KillColumn), "kill_%s", InfectedType);

	decl String:query[1024];
	Format(query, sizeof(query), "INSERT INTO `%sscore_quarter` (steamid, quarter_key, kills, headshots, `%s`, updated) VALUES ('%s', %i, %i, %i, %i, UNIX_TIMESTAMP()) ON DUPLICATE KEY UPDATE kills = kills + VALUES(kills), headshots = headshots + VALUES(headshots), `%s` = `%s` + VALUES(`%s`), updated = VALUES(updated)",
		DbPrefix, KillColumn, EscSteamID, g_iQuarterRankKey, Kills, Headshots, Kills, KillColumn, KillColumn, KillColumn);
	SendSQLUpdate(query);
}

stock QuarterRank_RecordPlaytime(Client, Minutes)
{
	if (Minutes <= 0)
		return;

	QuarterRank_EnsureCurrentQuarter();

	if (!QuarterRank_Enabled() || StatsDisabled() || !Stats_IsValidHumanClient(Client))
		return;

	new team = GetClientTeam(Client);
	if (team != TEAM_SURVIVORS && team != TEAM_INFECTED)
		return;

	ClientQuarterPlayTime[Client] += Minutes;

	decl String:SteamID[MAX_LINE_WIDTH];
	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:query[512];
	Format(query, sizeof(query), "INSERT INTO `%sscore_quarter` (steamid, quarter_key, playtime, updated) VALUES ('%s', %i, %i, UNIX_TIMESTAMP()) ON DUPLICATE KEY UPDATE playtime = playtime + VALUES(playtime), updated = VALUES(updated)",
		DbPrefix, EscSteamID, g_iQuarterRankKey, Minutes);
	SendSQLUpdate(query);
}

stock QuarterRank_QueryClient(Client)
{
	if (!QuarterRank_Enabled() || !Stats_IsValidHumanClient(Client))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, SteamID, sizeof(SteamID));
	QuarterRank_QueryClientPointsSteamID(Client, SteamID);
}

stock QuarterRank_QueryClientPointsSteamID(Client, const String:SteamID[], SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = QuarterRank_GetClientPoints;

	QuarterRank_EnsureCurrentQuarter();

	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:query[512];
	Format(query, sizeof(query), "SELECT points, playtime FROM `%sscore_quarter` WHERE steamid = '%s' AND quarter_key = %i", DbPrefix, EscSteamID, g_iQuarterRankKey);
	SQL_TQuery(db, callback, query, Client);
}

stock QuarterRank_QueryClientPointsDP(Handle:dp, SQLTCallback:callback)
{
	QuarterRank_EnsureCurrentQuarter();
	if (!QuarterRank_Enabled())
	{
		SQL_TQuery(db, callback, "SELECT 0, 0", dp);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	ResetPack(dp);
	ReadPackCell(dp);
	ReadPackString(dp, SteamID, sizeof(SteamID));

	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:query[512];
	Format(query, sizeof(query), "SELECT points, playtime FROM `%sscore_quarter` WHERE steamid = '%s' AND quarter_key = %i", DbPrefix, EscSteamID, g_iQuarterRankKey);
	SQL_TQuery(db, callback, query, dp);
}

public QuarterRank_GetClientPoints(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("QuarterRank_GetClientPoints Query failed: %s", error);
		return;
	}

	ClientQuarterPoints[client] = 0;
	ClientQuarterPlayTime[client] = 0;
	if (SQL_FetchRow(hndl))
	{
		ClientQuarterPoints[client] = SQL_FetchInt(hndl, 0);
		ClientQuarterPlayTime[client] = SQL_FetchInt(hndl, 1);
	}
}

stock QuarterRank_QueryClientRank(Client, SQLTCallback:callback=INVALID_FUNCTION)
{
	if (callback == INVALID_FUNCTION)
		callback = QuarterRank_GetClientRank;

	QuarterRank_EnsureCurrentQuarter();

	decl String:query[512];
	if (ClientQuarterPoints[Client] <= 0)
		Format(query, sizeof(query), "SELECT 0");
	else
		Format(query, sizeof(query), "SELECT COUNT(*) FROM `%sscore_quarter` WHERE quarter_key = %i AND points >= %i AND points > 0", DbPrefix, g_iQuarterRankKey, ClientQuarterPoints[Client]);

	SQL_TQuery(db, callback, query, Client);
}

stock QuarterRank_QueryClientRankDP(Handle:dp, SQLTCallback:callback)
{
	QuarterRank_EnsureCurrentQuarter();
	if (!QuarterRank_Enabled())
	{
		SQL_TQuery(db, callback, "SELECT 0", dp);
		return;
	}

	ResetPack(dp);
	new Client = ReadPackCell(dp);

	decl String:query[512];
	if (ClientQuarterPoints[Client] <= 0)
		Format(query, sizeof(query), "SELECT 0");
	else
		Format(query, sizeof(query), "SELECT COUNT(*) FROM `%sscore_quarter` WHERE quarter_key = %i AND points >= %i AND points > 0", DbPrefix, g_iQuarterRankKey, ClientQuarterPoints[Client]);

	SQL_TQuery(db, callback, query, dp);
}

public QuarterRank_GetClientRank(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if (!client)
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("QuarterRank_GetClientRank Query failed: %s", error);
		return;
	}

	ClientQuarterRank[client] = 0;
	if (SQL_FetchRow(hndl))
		ClientQuarterRank[client] = SQL_FetchInt(hndl, 0);
}

stock QuarterRank_QueryTotal(SQLTCallback:callback=INVALID_FUNCTION, any:data=0)
{
	if (callback == INVALID_FUNCTION)
		callback = QuarterRank_GetTotal;

	QuarterRank_EnsureCurrentQuarter();

	decl String:query[256];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM `%sscore_quarter` WHERE quarter_key = %i AND points > 0", DbPrefix, g_iQuarterRankKey);
	SQL_TQuery(db, callback, query, data);
}

stock QuarterRank_QueryTotalDP(Handle:dp, SQLTCallback:callback)
{
	QuarterRank_EnsureCurrentQuarter();
	if (!QuarterRank_Enabled())
	{
		SQL_TQuery(db, callback, "SELECT 0", dp);
		return;
	}

	decl String:query[256];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM `%sscore_quarter` WHERE quarter_key = %i AND points > 0", DbPrefix, g_iQuarterRankKey);
	SQL_TQuery(db, callback, query, dp);
}

public QuarterRank_GetTotal(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QuarterRank_GetTotal Query failed: %s", error);
		return;
	}

	QuarterRankTotal = 0;
	if (SQL_FetchRow(hndl))
		QuarterRankTotal = SQL_FetchInt(hndl, 0);
}

stock QuarterRank_QueryTop100Scores()
{
	if (!QuarterRank_Enabled())
		return;

	QuarterRank_EnsureCurrentQuarter();

	decl String:query[256];
	Format(query, sizeof(query), "SELECT points FROM `%sscore_quarter` WHERE quarter_key = %i AND points > 0 ORDER BY points DESC LIMIT 100", DbPrefix, g_iQuarterRankKey);
	SQL_TQuery(db, QuarterRank_GetTop100Scores, query, 0);
}

public QuarterRank_GetTop100Scores(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("QuarterRank_GetTop100Scores failed! Reason: %s", error);
		return;
	}

	new i = 0;
	while (i < 100)
	{
		CheckQuarterPlayerPoint[i++] = 0;
	}

	i = 0;
	while (SQL_FetchRow(hndl) && i < 100)
	{
		CheckQuarterPlayerPoint[i++] = SQL_FetchInt(hndl, 0);
	}
}
