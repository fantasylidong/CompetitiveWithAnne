#if defined _l4d_stats_score_log_included
	#endinput
#endif
#define _l4d_stats_score_log_included

#define SCORE_LOG_BATCH_INTERVAL 0.25
#define SCORE_LOG_BATCH_MAX_ROWS 16
#define SCORE_LOG_BATCH_QUERY_SIZE 32768

// 积分流水记录模块。
// 设计目标：每次 AddScore 都写一条独立流水，后续可以按玩家、地图、原因还原分数来源。

new Handle:cvar_ScoreLogEnable = INVALID_HANDLE;
new Handle:cvar_ScoreLogFormulaThreshold = INVALID_HANDLE;
new bool:g_bScoreLogTableReady = true;
new String:g_sScoreLogReason[MAX_LINE_WIDTH] = "";
new String:g_sScoreLogFormula[MAX_MESSAGE_WIDTH] = "";
new g_iScoreLogContextUses = 0;
new Handle:g_hScoreLogFlushTimer = INVALID_HANDLE;
new String:g_sScoreLogBatchQuery[SCORE_LOG_BATCH_QUERY_SIZE] = "";
new g_iScoreLogBatchRows = 0;
new g_iScoreLogBatchLength = 0;

stock ScoreLog_CreateCvars()
{
	cvar_ScoreLogEnable = CreateConVar("l4d_stats_scorelog_enable", "1", "是否记录每次积分加减流水。0=关闭, 1=开启", 0, true, 0.0, true, 1.0);
	cvar_ScoreLogFormulaThreshold = CreateConVar("l4d_stats_scorelog_formula_threshold", "500", "仅当单次正向加分大于该值时写入紧凑公式输入。", 0, true, 0.0);
}

stock ScoreLog_SetContext(const String:Reason[], const String:Formula[], Uses = 1)
{
	strcopy(g_sScoreLogReason, sizeof(g_sScoreLogReason), Reason);
	strcopy(g_sScoreLogFormula, sizeof(g_sScoreLogFormula), Formula);
	g_iScoreLogContextUses = Uses;

	if (g_iScoreLogContextUses <= 0)
		g_iScoreLogContextUses = 1;
}

stock ScoreLog_ClearContext()
{
	g_sScoreLogReason[0] = '\0';
	g_sScoreLogFormula[0] = '\0';
	g_iScoreLogContextUses = 0;
}

stock ScoreLog_ConsumeContext(String:Reason[], ReasonLength, String:Formula[], FormulaLength)
{
	if (g_sScoreLogReason[0] == '\0')
		strcopy(Reason, ReasonLength, "unknown");
	else
		strcopy(Reason, ReasonLength, g_sScoreLogReason);

	strcopy(Formula, FormulaLength, g_sScoreLogFormula);

	if (g_iScoreLogContextUses > 0)
	{
		g_iScoreLogContextUses--;
		if (g_iScoreLogContextUses <= 0)
			ScoreLog_ClearContext();
	}
}

stock ScoreLog_BeginBatch()
{
	g_iScoreLogBatchLength = Format(g_sScoreLogBatchQuery, sizeof(g_sScoreLogBatchQuery),
		"INSERT INTO `%sscore_log` (created, steamid, name, map, gamemode, difficulty, team, score, score_after, reason, formula, round_valid, usebuy, newbie_count, newbie_multiplier) VALUES ",
		DbPrefix);
	g_iScoreLogBatchRows = 0;
}

stock ScoreLog_FlushBatch()
{
	if (g_iScoreLogBatchRows <= 0)
		return;

	if (db != INVALID_HANDLE)
		SendSQLUpdate(g_sScoreLogBatchQuery);

	g_sScoreLogBatchQuery[0] = '\0';
	g_iScoreLogBatchRows = 0;
	g_iScoreLogBatchLength = 0;
}

stock ScoreLog_StopFlushTimer()
{
	new Handle:timer = g_hScoreLogFlushTimer;
	g_hScoreLogFlushTimer = INVALID_HANDLE;

	if (timer != INVALID_HANDLE && IsValidHandle(timer))
		KillTimer(timer);
}

stock ScoreLog_FlushNow()
{
	ScoreLog_StopFlushTimer();
	ScoreLog_FlushBatch();
}

public Action:Timer_ScoreLogFlush(Handle:timer)
{
	if (timer != g_hScoreLogFlushTimer)
		return Plugin_Stop;

	g_hScoreLogFlushTimer = INVALID_HANDLE;

	ScoreLog_FlushBatch();
	return Plugin_Stop;
}

stock ScoreLog_QueueRow(const String:row[])
{
	if (g_iScoreLogBatchRows <= 0)
		ScoreLog_BeginBatch();

	new RowLength = strlen(row);
	new RequiredLength = g_iScoreLogBatchLength + RowLength + 2;
	if (RequiredLength >= sizeof(g_sScoreLogBatchQuery))
	{
		ScoreLog_FlushBatch();
		ScoreLog_BeginBatch();
	}

	if (g_iScoreLogBatchRows > 0)
	{
		g_sScoreLogBatchQuery[g_iScoreLogBatchLength++] = ',';
		g_sScoreLogBatchQuery[g_iScoreLogBatchLength] = '\0';
	}

	strcopy(g_sScoreLogBatchQuery[g_iScoreLogBatchLength], sizeof(g_sScoreLogBatchQuery) - g_iScoreLogBatchLength, row);
	g_iScoreLogBatchLength += RowLength;
	g_iScoreLogBatchRows++;

	if (g_hScoreLogFlushTimer == INVALID_HANDLE)
		g_hScoreLogFlushTimer = CreateTimer(SCORE_LOG_BATCH_INTERVAL, Timer_ScoreLogFlush);

	if (g_iScoreLogBatchRows >= SCORE_LOG_BATCH_MAX_ROWS)
		ScoreLog_FlushBatch();
}

stock ScoreLog_Record(Client, Score)
{
	decl String:Reason[MAX_LINE_WIDTH];
	decl String:Formula[MAX_MESSAGE_WIDTH];
	ScoreLog_ConsumeContext(Reason, sizeof(Reason), Formula, sizeof(Formula));

	if (Score == 0 || cvar_ScoreLogEnable == INVALID_HANDLE || !GetConVarBool(cvar_ScoreLogEnable))
		return;

	if (db == INVALID_HANDLE || !g_bScoreLogTableReady || !Stats_IsValidHumanClient(Client))
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	if (!GetClientRankAuthString(Client, ClientID, sizeof(ClientID)) || Stats_IsInvalidRankAuthString(ClientID))
		return;

	decl String:ClientName[128];
	GetClientName(Client, ClientName, sizeof(ClientName));

	decl String:MapName[128];
	GetCurrentMap(MapName, sizeof(MapName));

	decl String:Difficulty[32];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	decl String:EscClientID[MAX_LINE_WIDTH * 2 + 1];
	decl String:EscClientName[257];
	decl String:EscMapName[257];
	decl String:EscDifficulty[65];
	decl String:EscReason[MAX_LINE_WIDTH * 2 + 1];
	decl String:EscFormula[257];
	decl String:ResolvedFormula[128];
	ResolvedFormula[0] = '\0';
	if (cvar_ScoreLogFormulaThreshold != INVALID_HANDLE &&
		Score > GetConVarInt(cvar_ScoreLogFormulaThreshold) &&
		(StrContains(Formula, "v3c:", true) == 0 || StrContains(Formula, "v3s:", true) == 0 || StrContains(Formula, "v3n:", true) == 0))
	{
		strcopy(ResolvedFormula, sizeof(ResolvedFormula), Formula);
	}
	SQL_EscapeString(db, ClientID, EscClientID, sizeof(EscClientID));
	SQL_EscapeString(db, ClientName, EscClientName, sizeof(EscClientName));
	SQL_EscapeString(db, MapName, EscMapName, sizeof(EscMapName));
	SQL_EscapeString(db, Difficulty, EscDifficulty, sizeof(EscDifficulty));
	SQL_EscapeString(db, Reason, EscReason, sizeof(EscReason));
	SQL_EscapeString(db, ResolvedFormula, EscFormula, sizeof(EscFormula));

	new RoundValid = 1;
	new UseBuy = 0;
	if (g_brpgAvailable)
	{
		RoundValid = L4D_RPG_GetGlobalValue(INDEX_VALID) ? 1 : 0;
		UseBuy = L4D_RPG_GetGlobalValue(INDEX_USEBUY) ? 1 : 0;
	}

	new NewbieCount = NewPlayerBonus_CountNewSurvivors();
	new Float:NewbieMultiplier = NewPlayerBonus_GetMultiplier();

	decl String:row[2048];
	Format(row, sizeof(row),
		"(UNIX_TIMESTAMP(), '%s', '%s', '%s', %i, '%s', %i, %i, %i, '%s', '%s', %i, %i, %i, %.3f)",
		EscClientID,
		EscClientName,
		EscMapName,
		Stats_GetCurrentStatsGamemodeID(),
		EscDifficulty,
		GetClientTeam(Client),
		Score,
		CurrentPoints[Client],
		EscReason,
		EscFormula,
		RoundValid,
		UseBuy,
		NewbieCount,
		NewbieMultiplier);
	ScoreLog_QueueRow(row);
}
