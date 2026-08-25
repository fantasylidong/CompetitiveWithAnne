#if defined _l4d_stats_commands_menus_included
	#endinput
#endif
#define _l4d_stats_commands_menus_included

// 聊天命令、控制台命令、排行榜/地图时间菜单和面板回调。

// DEBUG
//public Action:cmd_StatsTest(client, args)
//{
//	new String:CurrentMode[16];
//	GetConVarString(cvar_Gamemode, CurrentMode, sizeof(CurrentMode));
//	PrintToConsole(0, "Gamemode: %s", CurrentMode);
//	UpdateMapStat("playtime", 10);
//	PrintToConsole(0, "Added 10 seconds to maps table current map.");
//	new Float:ReductionFactor = GetMedkitPointReductionFactor();
//
//	StatsPrintToChat(client, "{lightgreen}ALL SURVIVORS {default}now earns only {green}%i percent {default}of their normal points after using their {olive}%i%s Medkit{default}!", RoundToNearest(ReductionFactor * 100), MedkitsUsedCounter, (MedkitsUsedCounter == 1 ? "st" : (MedkitsUsedCounter == 2 ? "nd" : (MedkitsUsedCounter == 3 ? "rd" : "th"))), GetClientTeam(client));
//}

/*
-----------------------------------------------------------------------------
Chat/command handling and panels for Rank and Top10
-----------------------------------------------------------------------------
*/

public Action:HandleCommands(client, const String:Text[])
{
	if (strcmp(Text, "rankmenu", false) == 0)
	{
		cmd_ShowRankMenu(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rank", false) == 0)
	{
		cmd_ShowRank(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showrank", false) == 0)
	{
		cmd_ShowRanks(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showppm", false) == 0)
	{
		cmd_ShowPPMs(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "top10", false) == 0)
	{
		cmd_ShowTop10(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "top10q", false) == 0 || strcmp(Text, "qtop10", false) == 0 || strcmp(Text, "quartertop10", false) == 0)
	{
		cmd_ShowQuarterTop10(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "top10ppm", false) == 0)
	{
		cmd_ShowTop10PPM(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "nextrank", false) == 0)
	{
		cmd_ShowNextRank(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showtimer", false) == 0)
	{
		cmd_ShowTimedMapsTimer(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "timedmaps", false) == 0)
	{
		cmd_TimedMaps(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showmaptime", false) == 0)
	{
		cmd_ShowMapTimes(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "maptimes", false) == 0)
	{
		cmd_MapTimes(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rankvote", false) == 0)
	{
		cmd_RankVote(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "rankmutetoggle", false) == 0)
	{
		cmd_ToggleClientRankMute(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	else if (strcmp(Text, "showmotd", false) == 0)
	{
		cmd_ShowMotd(client, 0);
		if (GetConVarBool(cvar_SilenceChat))
			return Plugin_Handled;
	}

	return Plugin_Continue;
}

// Parse chat for RANK and TOP10 triggers.
public Action:cmd_Say(client, args)
{
	decl String:Text[192];
	//new String:Command[64];
	new Start = 0;

	GetCmdArgString(Text, sizeof(Text));

	new TextLen = strlen(Text);

	// This apparently happens sometimes?
	if (TextLen <= 0)
	{
		return Plugin_Continue;
	}

	if (Text[TextLen-1] == '"')
	{
		Text[TextLen-1] = '\0';
		Start = 1;
	}

	// Command is never set? This will always result to false.
	//if (strcmp(Command, "say2", false) == 0)
	//	Start += 4;

	return HandleCommands(client, Text[Start]);
}

// Show current Timed Maps timer.
public Action:cmd_ShowTimedMapsTimer(client, args)
{
	if (client != 0 && !IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (client != 0 && IsClientBot(client))
		return Plugin_Handled;

	if (MapTimingStartTime <= 0.0)
	{
		if (client == 0)
		{
				StatsPrintToConsolePhrase(0, "L4DStats_MapTimerNotStarted");
		}
		else
		{
			StatsPrintToChatPreFormatted(client, "L4DStats_MapTimerNotStarted");
		}

		return Plugin_Handled;
	}

	new Float:CurrentMapTimer = GetEngineTime() - MapTimingStartTime;
	decl String:TimeLabel[32];

	SetTimeLabel(CurrentMapTimer, TimeLabel, sizeof(TimeLabel), client > 0 ? client : LANG_SERVER);

	if (client == 0)
		StatsPrintToConsolePhrase(0, "L4DStats_CurrentMapTimeConsole", TimeLabel);
	else
		StatsPrintToChat(client, "L4DStats_CurrentMapTime", TimeLabel);

	return Plugin_Handled;
}

// Begin generating the NEXTRANK display panel.
public Action:cmd_ShowNextRank(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	QueryClientStatsSteamID(client, SteamID, CM_NEXTRANK);

	return Plugin_Handled;
}

// Clear database.
//public Action:cmd_RankAdmin(client, args)
//{
//	if (!client)
//		return Plugin_Handled;
//
//	new Handle:RankAdminPanel = CreatePanel();
//
//	SetPanelTitle(RankAdminPanel, "Rank Admin:");
//
//	DrawPanelItem(RankAdminPanel, "Clear...");
//	DrawPanelItem(RankAdminPanel, "Clear Players");
//	DrawPanelItem(RankAdminPanel, "Clear Maps");
//	DrawPanelItem(RankAdminPanel, "Clear All");
//
//	SendPanelToClient(RankAdminPanel, client, RankAdminPanelHandler, 30);
//	CloseHandle(RankAdminPanel);
//
//	return Plugin_Handled;
//}

DisplayYesNoPanel(client, const String:title[], MenuHandler:handler, delay=30)
{
	if (!client)
		return;

	new Handle:panel = CreatePanel();

	StatsSetPanelTitle(panel, client, title);

	StatsDrawPanelItem(panel, client, "L4DStats_Yes");
	StatsDrawPanelItem(panel, client, "L4DStats_No");

	SendPanelToClient(panel, client, handler, delay);
	CloseHandle(panel);
}

public bool:IsTeamGamemode()
{
	return IsGamemode("versus") ||
				 IsGamemode("realismversus") ||
				 IsGamemode("scavenge") ||
				 IsGamemode("mutation11") ||	// Healthpackalypse!
				 IsGamemode("mutation12") ||	// Realism Versus
				 IsGamemode("mutation13") ||	// Follow the Liter
				 IsGamemode("mutation15") ||	// Versus Survival
				 IsGamemode("mutation18") ||	// Bleed Out Versus
				 IsGamemode("mutation19") ||	// Taaannnkk!
				 IsGamemode("community3") ||	// Riding My Survivor
				 IsGamemode("community6");		// Confogl
}

// Run Team Shuffle.
public Action:cmd_ShuffleTeams(client, args)
{
	if (!IsTeamGamemode())
	{
		StatsPrintToConsolePhrase(client, "L4DStats_TeamShuffleUnavailable");
		return Plugin_Handled;
	}

	if (RankVoteTimer != INVALID_HANDLE)
	{
		CloseHandle(RankVoteTimer);
		RankVoteTimer = INVALID_HANDLE;

		StatsPrintToChatAllPreFormatted("L4DStats_TeamShuffleAdminExecuted");
	}

	StatsPrintToConsolePhrase(client, "L4DStats_TeamShuffleExecuting");
	CreateTimer(1.0, timer_ShuffleTeams);

	return Plugin_Handled;
}

// Set Message Of The Day.
public Action:cmd_SetMotd(client, args)
{
	decl String:arg[1024];

	GetCmdArgString(arg, sizeof(arg));

	UpdateServerSettings(client, "motdmessage", arg);

	return Plugin_Handled;
}

// Clear database.
public Action:cmd_ClearRank(client, args)
{
	if (client == 0)
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearDatabaseServerDisabled");
		return Plugin_Handled;
	}

	new userid = GetClientUserId(client);
	if (userid <= 0)
		return Plugin_Handled;

	if (ClearDatabaseTimer != INVALID_HANDLE)
	{
		CloseHandle(ClearDatabaseTimer);
	}

	ClearDatabaseTimer = INVALID_HANDLE;

	if (ClearDatabaseCaller == userid)
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearDatabaseStarted");
		ClearDatabaseCaller = -1;

		ClearStatsAll(client);

		return Plugin_Handled;
	}

	StatsPrintToConsolePhrase(client, "L4DStats_ClearDatabaseConfirm", CLEAR_DATABASE_CONFIRMTIME);
	ClearDatabaseCaller = userid;

	ClearDatabaseTimer = CreateTimer(CLEAR_DATABASE_CONFIRMTIME, timer_ClearDatabase);

	return Plugin_Handled;
}

public ClearStatsMaps(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	decl String:query[256];
	Format(query, sizeof(query), "SELECT * FROM %smaps WHERE 1 = 2", DbPrefix);

	SQL_TQuery(db, ClearStatsMapsHandler, query, GetClientUserId(client));
}

public ClearStatsAll(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	if (!DoFastQuery(client, "DELETE FROM %stimedmaps", DbPrefix))
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearTimedMapsRollback");
		DoFastQuery(client, "ROLLBACK");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsFailure");

		return;
	}
	DoFastQuery(client, "DELETE FROM `%stimedmap_runs`", DbPrefix);

	if (!DoFastQuery(client, "DELETE FROM %splayers", DbPrefix))
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearPlayersRollback");
		DoFastQuery(client, "ROLLBACK");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsFailure");

		return;
	}

	decl String:query[256];
	Format(query, sizeof(query), "SELECT * FROM %smaps WHERE 1 = 2", DbPrefix);

	SQL_TQuery(db, ClearStatsMapsHandler, query, GetClientUserId(client));
}

public ClearStatsPlayers(client)
{
	if (!DoFastQuery(client, "START TRANSACTION"))
	{
		return;
	}

	if (!DoFastQuery(client, "DELETE FROM %splayers", DbPrefix))
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearPlayersRollback");
		DoFastQuery(client, "ROLLBACK");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsFailure");
	}
	else
	{
		DoFastQuery(client, "COMMIT");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearRanksSuccess");
	}
}

public ClearStatsMapsHandler(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		client = 0;

	if (hndl == INVALID_HANDLE)
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearQueryFailed", error);
		DoFastQuery(client, "ROLLBACK");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsFailure");
		return;
	}

	new FieldCount = SQL_GetFieldCount(hndl);
	decl String:FieldName[MAX_LINE_WIDTH];
	decl String:FieldSet[MAX_LINE_WIDTH];

	new Counter = 0;
	decl String:query[4096];
	Format(query, sizeof(query), "UPDATE %smaps SET", DbPrefix);

	for (new i = 0; i < FieldCount; i++)
	{
		SQL_FieldNumToName(hndl, i, FieldName, sizeof(FieldName));

		if (StrEqual(FieldName, "name", false) ||
				StrEqual(FieldName, "gamemode", false) ||
				StrEqual(FieldName, "custom", false))
		{
			continue;
		}

		if (Counter++ > 0)
		{
			StrCat(query, sizeof(query), ",");
		}

		Format(FieldSet, sizeof(FieldSet), " %s = 0", FieldName);
		StrCat(query, sizeof(query), FieldSet);
	}

	if (!DoFastQuery(client, query))
	{
		StatsPrintToConsolePhrase(client, "L4DStats_ClearMapsRollback");
		DoFastQuery(client, "ROLLBACK");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsFailure");
	}
	else
	{
		DoFastQuery(client, "COMMIT");
		StatsPrintToConsolePhrase(client, "L4DStats_ClearStatsSuccess");
	}
}

bool:DoFastQuery(Client, const String:Query[], any:...)
{
	if (db == INVALID_HANDLE)
		return false;

	new String:FormattedQuery[4096];
	VFormat(FormattedQuery, sizeof(FormattedQuery), Query, 3);

	new String:Error[1024];

	if (!SQL_FastQuery(db, FormattedQuery))
	{
		if (SQL_GetError(db, Error, sizeof(Error)))
		{
			StatsPrintToConsolePhrase(Client, "L4DStats_FastQueryError", Error, FormattedQuery);
			LogError("Fast query failed! (Error = \"%s\") Query = \"%s\"", Error, FormattedQuery);
		}
		else
		{
			StatsPrintToConsolePhrase(Client, "L4DStats_FastQueryFailed", FormattedQuery);
			LogError("Fast query failed! Query = \"%s\"", FormattedQuery);
		}

		return false;
	}

	return true;
}

public Action:timer_ClearDatabase(Handle:timer, any:data)
{
	ClearDatabaseTimer = INVALID_HANDLE;
	ClearDatabaseCaller = -1;
}

// Begin generating the RANKMENU display panel.
public Action:cmd_ShowRankMenu(client, args)
{
	if (client <= 0)
	{
		if (client == 0)
			StatsPrintToConsolePhrase(0, "L4DStats_CommandInGameOnly");

		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	DisplayRankMenu(client);

	return Plugin_Handled;
}

public DisplayRankMenu(client)
{
	new Handle:menu = CreateMenu(Menu_CreateRankMenuHandler);

	StatsSetMenuTitle(menu, client, "L4DStats_RankMenuTitle");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);


	StatsAddMenuItem(menu, "rank", client, "L4DStats_MenuCurrentRank");
	StatsAddMenuItem(menu, "top10", client, "L4DStats_MenuTop10");
	StatsAddMenuItem(menu, "top10q", client, "L4DStats_MenuQuarterTop10");
	StatsAddMenuItem(menu, "top10ppm", client, "L4DStats_MenuTop10PPM");
	StatsAddMenuItem(menu, "nextrank", client, "L4DStats_MenuNextRank");
	StatsAddMenuItem(menu, "showtimer", client, "L4DStats_MenuCurrentMapTime");
	StatsAddMenuItem(menu, "showrank", client, "L4DStats_MenuOtherPlayerRank");
	StatsAddMenuItem(menu, "showppm", client, "L4DStats_MenuOtherPlayerPPM");
	if (GetConVarBool(cvar_EnableRankVote) && IsTeamGamemode())
	{
		StatsAddMenuItem(menu, "rankvote", client, "L4DStats_MenuRankVote");
	}
	StatsAddMenuItem(menu, "timedmaps", client, "L4DStats_MenuAllMapTimes");
	if (IsSingleTeamGamemode())
	{
		StatsAddMenuItem(menu, "maptimes", client, "L4DStats_MenuThisMapTimes");
	}
	if (GetConVarInt(cvar_AnnounceMode))
	{
		StatsAddMenuItem(menu, "showsettings", client, "L4DStats_MenuSettings");
	}
	//AddMenuItem(menu, "showmaptimes", "显示他人地图的游玩时间记录");

	StatsAddMenuItem(menu, "rankabout", client, "L4DStats_MenuAbout");

	DisplayMenu(menu, client, 30);

	if (EnableSounds_Rankmenu_Show && GetConVarBool(cvar_SoundsEnabled))
		EmitSoundToClient(client, StatsSound_Rankmenu_Show);
}

NotServerConsoleCommand()
{
	StatsPrintToConsolePhrase(0, "L4DStats_CommandUnavailableFromServer");
}

// Begin generating the RANK display panel.
public Action:cmd_ShowRank(client, args)
{
	if (client == 0)
	{
		NotServerConsoleCommand();
		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client))
		return Plugin_Handled;

	if (IsClientBot(client))
		return Plugin_Handled;

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	QueryClientStatsSteamID(client, SteamID, CM_RANK);

	return Plugin_Handled;
}

// Generate client's point total.
public GetClientPointsPlayerJoined(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	GetClientPointsWorker(owner, hndl, error, userid, GetClientRankPlayerJoined);
}

// Generate client's point total.
public GetClientPointsRankChange(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	GetClientPointsWorker(owner, hndl, error, userid, GetClientRankRankChange);
}

// Generate client's current-quarter point total before checking quarter rank changes.
public GetClientQuarterPointsRankChange(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientQuarterPointsRankChange Query failed: %s", error);
		return;
	}

	QuarterRank_GetClientPoints(owner, hndl, error, userid);
	QuarterRank_QueryClientRank(client, GetClientQuarterRankRankChange);
}

// Generate client's point total.
GetClientPointsWorker(Handle:owner, Handle:hndl, const String:error[], any:userid, SQLTCallback:callback=INVALID_FUNCTION)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;
	
	if (callback == INVALID_FUNCTION)
	{
		LogError("GetClientPointsWorker method invoke failed: SQLTCallback:callback=INVALID_FUNCTION");
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientPointsWorker Query failed: %s", error);
		return;
	}

	GetClientPoints(owner, hndl, error, userid);
	QueryClientRank(client, callback);
}

// Generate client's point total.
public GetClientPoints(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientPoints Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
	{
		ClientPoints[client] = SQL_FetchInt(hndl, 0);
		ClientScoreReady[client] = true;
	}
}

// Generate client's gamemode point total.
public GetClientGameModePoints(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientGameModePoints Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
	{
		ClientGameModePoints[client][GAMEMODE_COOP] = SQL_FetchInt(hndl, GAMEMODE_COOP);
		ClientGameModePoints[client][GAMEMODE_VERSUS] = SQL_FetchInt(hndl, GAMEMODE_VERSUS);
		ClientGameModePoints[client][GAMEMODE_REALISM] = SQL_FetchInt(hndl, GAMEMODE_REALISM);
		ClientGameModePoints[client][GAMEMODE_SURVIVAL] = SQL_FetchInt(hndl, GAMEMODE_SURVIVAL);
		ClientGameModePoints[client][GAMEMODE_SCAVENGE] = SQL_FetchInt(hndl, GAMEMODE_SCAVENGE);
		ClientGameModePoints[client][GAMEMODE_REALISMVERSUS] = SQL_FetchInt(hndl, GAMEMODE_REALISMVERSUS);
		ClientGameModePoints[client][GAMEMODE_OTHERMUTATIONS] = SQL_FetchInt(hndl, GAMEMODE_OTHERMUTATIONS);
	}
}

// Generate client's next rank.
public DisplayClientNextRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	GetClientNextRank(owner, hndl, error, userid);

	DisplayNextRank(client);
}

// Generate client's next rank.
public GetClientNextRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
		ClientNextRank[client] = SQL_FetchInt(hndl, 0);
	else
		ClientNextRank[client] = 0;
}

// Generate client's rank.
public GetClientRankRankChange(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankRankChange Query failed: %s", error);
		return;
	}

	GetClientRank(owner, hndl, error, userid);

	if (RankChangeLastRank[client] != ClientRank[client])
	{
		new RankChange = RankChangeLastRank[client] - ClientRank[client];

		if (!RankChangeFirstCheck[client] && RankChange == 0)
			return;

		RankChangeLastRank[client] = ClientRank[client];

		if (RankChangeFirstCheck[client])
		{
			RankChangeFirstCheck[client] = false;
			return;
		}

		if (!GetConVarInt(cvar_AnnounceMode) || !GetConVarBool(cvar_AnnounceRankChange))
			return;

		if (RankChange > 0)
		{
			if (!IsClientBot(client) && IsClientConnected(client) && IsClientInGame(client))
				StatsPrintToChat(client, "L4DStats_RankRose", RankChange, RankChangeLastRank[client]);
		}
		else
		{
			RankChange *= -1;
			if (!IsClientBot(client) && IsClientConnected(client) && IsClientInGame(client))
				StatsPrintToChat(client, "L4DStats_RankFell", RankChange, RankChangeLastRank[client]);
		}
	}
}

// Generate client's current-quarter rank and announce quarter rank changes.
public GetClientQuarterRankRankChange(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientQuarterRankRankChange Query failed: %s", error);
		return;
	}

	QuarterRank_GetClientRank(owner, hndl, error, userid);

	new CurrentRank = ClientQuarterRank[client];
	new LastRank = QuarterRankChangeLastRank[client];

	if (QuarterRankChangeFirstCheck[client])
	{
		QuarterRankChangeLastRank[client] = CurrentRank;
		QuarterRankChangeFirstCheck[client] = false;
		return;
	}

	if (LastRank == CurrentRank)
	{
		return;
	}

	QuarterRankChangeLastRank[client] = CurrentRank;

	if (!GetConVarInt(cvar_AnnounceMode) || !GetConVarBool(cvar_AnnounceRankChange))
	{
		return;
	}

	if (!Stats_IsValidHumanClient(client))
	{
		return;
	}

	decl String:QuarterLabel[32];
	QuarterRank_FormatCurrentQuarter(client, QuarterLabel, sizeof(QuarterLabel));

	if (CurrentRank <= 0)
	{
		StatsPrintToChat(client, "L4DStats_QuarterRankingLeft", QuarterLabel);
		return;
	}

	if (LastRank <= 0)
	{
		StatsPrintToChat(client, "L4DStats_QuarterRankingEntered", QuarterLabel, CurrentRank, ClientQuarterPoints[client]);
		return;
	}

	new RankChange = LastRank - CurrentRank;
	if (RankChange > 0)
	{
		StatsPrintToChat(client, "L4DStats_QuarterRankRose", QuarterLabel, RankChange, CurrentRank, ClientQuarterPoints[client]);
	}
	else
	{
		RankChange *= -1;
		StatsPrintToChat(client, "L4DStats_QuarterRankFell", QuarterLabel, RankChange, CurrentRank, ClientQuarterPoints[client]);
	}
}

QueryClientStatsDP_PlayerJoined(Client, const String:SteamID[])
{
	#pragma unused SteamID

	if (!Stats_IsValidHumanClient(Client))
	{
		return;
	}

	decl String:userName[MAX_LINE_WIDTH];
	GetClientName(Client, userName, sizeof(userName));

	if (ClientRank[Client] > 0)
	{
		StatsPrintToChatAll("L4DStats_PlayerJoinedOverallRanked", userName, ClientRank[Client], RankTotal, ClientPoints[Client]);
	}
	else
	{
		StatsPrintToChatAll("L4DStats_PlayerJoinedOverallUnranked", userName);
	}

	if (!QuarterRank_Enabled())
	{
		return;
	}

	if (ClientQuarterRank[Client] > 0)
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!Stats_IsValidHumanClient(i))
				continue;

			decl String:QuarterLabel[32];
			QuarterRank_FormatCurrentQuarter(i, QuarterLabel, sizeof(QuarterLabel));
			StatsPrintToChat(i, "L4DStats_CurrentQuarterRanked", QuarterLabel, ClientQuarterRank[Client], QuarterRankTotal, ClientQuarterPoints[Client]);
		}
	}
	else
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!Stats_IsValidHumanClient(i))
				continue;

			decl String:QuarterLabel[32];
			QuarterRank_FormatCurrentQuarter(i, QuarterLabel, sizeof(QuarterLabel));
			StatsPrintToChat(i, "L4DStats_CurrentQuarterUnranked", QuarterLabel);
		}
	}
}

// Generate client's rank.
public GetClientRankPlayerJoined(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRankPlayerJoined Query failed: %s", error);
		return;
	}

	GetClientRank(owner, hndl, error, userid);

	decl String:userName[MAX_LINE_WIDTH];
	GetClientName(client, userName, sizeof(userName));

	if (ClientRank[client] > 0)
	{
		StatsPrintToChatAll("L4DStats_PlayerJoinedModeRanked", userName, ClientRank[client], ClientPoints[client]);
	}
	else
	{
		StatsPrintToChatAll("L4DStats_PlayerJoinedModeUnranked", userName);
	}
}

// Generate client's rank.
public GetClientRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientRank Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
		ClientRank[client] = SQL_FetchInt(hndl, 0);
}

// Generate client's rank.
public GetClientGameModeRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientGameModeRank Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		ClientGameModeRank[client] = SQL_FetchInt(hndl, 0);
}

// Generate total rank amount.
public GetRankTotal(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetRankTotal Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		RankTotal = SQL_FetchInt(hndl, 0);
}

// Generate total gamemode rank amount.
public GetGameModeRankTotal(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetGameModeRankTotal Query failed: %s", error);
		return;
	}

	while (SQL_FetchRow(hndl))
		GameModeRankTotal = SQL_FetchInt(hndl, 0);
}

// Send the NEXTRANK panel to the client's display.
public DisplayNextRank(client)
{
	if (!client)
		return;

	new Handle:NextRankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];

	StatsSetPanelTitle(NextRankPanel, client, "L4DStats_NextRankTitle");

	if (ClientNextRank[client])
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_NextRankPointsNeeded", ClientNextRank[client]);
		DrawPanelText(NextRankPanel, Value);

		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CurrentRank", ClientRank[client]);
		DrawPanelText(NextRankPanel, Value);
	}
	else
		StatsDrawPanelText(NextRankPanel, client, "L4DStats_AlreadyFirst");

	StatsDrawPanelItem(NextRankPanel, client, "L4DStats_MoreEllipsis");
	StatsDrawPanelItem(NextRankPanel, client, "L4DStats_Close");
	SendPanelToClient(NextRankPanel, client, NextRankPanelHandler, 30);
	CloseHandle(NextRankPanel);
}

// Send the NEXTRANK panel to the client's display.
public DisplayNextRankFull(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayNextRankFull Query failed: %s", error);
		return;
	}

	if(SQL_GetRowCount(hndl) <= 1)
		return;

	new Points;
	decl String:Name[32];

	new Handle:NextRankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];

	StatsSetPanelTitle(NextRankPanel, client, "L4DStats_NextRankTitle");

	if (ClientNextRank[client])
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_NextRankPointsNeeded", ClientNextRank[client]);
		DrawPanelText(NextRankPanel, Value);

		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CurrentRank", ClientRank[client]);
		DrawPanelText(NextRankPanel, Value);
	}
	else
		StatsDrawPanelText(NextRankPanel, client, "L4DStats_AlreadyFirst");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));
		Points = SQL_FetchInt(hndl, 1);

		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PointsAndPlayer", Points, Name);
		DrawPanelText(NextRankPanel, Value);
	}

	StatsDrawPanelItem(NextRankPanel, client, "L4DStats_Close");
	SendPanelToClient(NextRankPanel, client, NextRankFullPanelHandler, 30);
	CloseHandle(NextRankPanel);
}

// Send the RANK panel to the client's display.
public DisplayRank(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayRank Query failed: %s", error);
		return;
	}

	new Float:PPM;
	new Playtime, Points, InfectedKilled, SurvivorsKilled, Headshots;
	new String:Name[32];

	if (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));
		Playtime = SQL_FetchInt(hndl, 1);
		ClientPlayTime[client] = Playtime;
		Points = SQL_FetchInt(hndl, 2);
		InfectedKilled = SQL_FetchInt(hndl, 3);
		SurvivorsKilled = SQL_FetchInt(hndl, 4);
		Headshots = SQL_FetchInt(hndl, 5);
		PPM = float(Points) / float(Playtime);
	}
	else
	{
		GetClientName(client, Name, sizeof(Name));
		Playtime = 0;
		Points = 0;
		InfectedKilled = 0;
		SurvivorsKilled = 0;
		Headshots = 0;
		PPM = 0.0;
	}

	new Handle:RankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];
	new String:URL[MAX_LINE_WIDTH];
	new String:QuarterLabel[32], String:GamemodeLabel[64];

	GetConVarString(cvar_SiteURL, URL, sizeof(URL));
	QuarterRank_FormatCurrentQuarter(client, QuarterLabel, sizeof(QuarterLabel));
	StatsFormatPhrase(client, GamemodeLabel, sizeof(GamemodeLabel), CurrentGamemodeLabel);
	new Float:HeadshotRatio = Headshots == 0 ? 0.00 : float(Headshots)/float(InfectedKilled)*100;

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlayerRankTitle", Name);
	SetPanelTitle(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_OverallRank", ClientRank[client], RankTotal);
	DrawPanelText(RankPanel, Value);

	if (!InvalidGameMode())
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_ModeRank", GamemodeLabel, ClientGameModeRank[client], GameModeRankTotal);
		DrawPanelText(RankPanel, Value);
	}

	if (Playtime > 60)
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlaytimeHours", float(Playtime)/ 60.0);
		DrawPanelText(RankPanel, Value);
	}
	else
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlaytimeMinutes", Playtime);
		DrawPanelText(RankPanel, Value);
	}

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CurrentPoints", Points);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_QuarterPoints", QuarterLabel, ClientQuarterPoints[client]);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_QuarterRank", QuarterLabel, ClientQuarterRank[client], QuarterRankTotal);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PointsPerMinute", PPM);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CommonKilled", InfectedKilled);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_SurvivorsKilled", SurvivorsKilled);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_Headshots", Headshots);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_HeadshotRatio", HeadshotRatio);
	DrawPanelText(RankPanel, Value);

	if (!StrEqual(URL, "", false))
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_FullStatsUrl", URL);
		DrawPanelText(RankPanel, Value);
	}

	//DrawPanelItem(RankPanel, "Next Rank");
	StatsDrawPanelItem(RankPanel, client, "L4DStats_Close");
	SendPanelToClient(RankPanel, client, RankPanelHandler, 30);
	CloseHandle(RankPanel);
}

// Send a read-only RANK panel for another player's SteamID.
// This path intentionally does not write ClientPoints/ClientRank/ClientQuarter* for the viewer.
public DisplayRankSnapshot(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayRankSnapshot Query failed: %s", error);
		return;
	}

	new Float:PPM;
	new Playtime, Points, InfectedKilled, SurvivorsKilled, Headshots;
	new Rank, TotalRank, GameModeRank, GameModeTotal, QuarterPoints, QuarterPlayTime, QuarterRank, QuarterTotal;
	new String:Name[32];

	if (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));
		Playtime = SQL_FetchInt(hndl, 1);
		Points = SQL_FetchInt(hndl, 2);
		InfectedKilled = SQL_FetchInt(hndl, 3);
		SurvivorsKilled = SQL_FetchInt(hndl, 4);
		Headshots = SQL_FetchInt(hndl, 5);
		Rank = SQL_FetchInt(hndl, 6);
		TotalRank = SQL_FetchInt(hndl, 7);
		GameModeRank = SQL_FetchInt(hndl, 8);
		GameModeTotal = SQL_FetchInt(hndl, 9);
		QuarterPoints = SQL_FetchInt(hndl, 10);
		QuarterPlayTime = SQL_FetchInt(hndl, 11);
		QuarterRank = SQL_FetchInt(hndl, 12);
		QuarterTotal = SQL_FetchInt(hndl, 13);
		PPM = Playtime > 0 ? float(Points) / float(Playtime) : 0.0;
	}
	else
	{
		StatsFormatPhrase(client, Name, sizeof(Name), "L4DStats_UnknownPlayer");
		Playtime = 0;
		Points = 0;
		InfectedKilled = 0;
		SurvivorsKilled = 0;
		Headshots = 0;
		Rank = 0;
		TotalRank = 0;
		GameModeRank = 0;
		GameModeTotal = 0;
		QuarterPoints = 0;
		QuarterPlayTime = 0;
		QuarterRank = 0;
		QuarterTotal = 0;
		PPM = 0.0;
	}

	#pragma unused QuarterPlayTime

	ReplaceString(Name, sizeof(Name), "&lt;", "<");
	ReplaceString(Name, sizeof(Name), "&gt;", ">");
	ReplaceString(Name, sizeof(Name), "&#37;", "%");
	ReplaceString(Name, sizeof(Name), "&#61;", "=");
	ReplaceString(Name, sizeof(Name), "&#42;", "*");

	new Handle:RankPanel = CreatePanel();
	new String:Value[MAX_LINE_WIDTH];
	new String:URL[MAX_LINE_WIDTH];
	new String:QuarterLabel[32], String:GamemodeLabel[64];

	GetConVarString(cvar_SiteURL, URL, sizeof(URL));
	QuarterRank_FormatCurrentQuarter(client, QuarterLabel, sizeof(QuarterLabel));
	StatsFormatPhrase(client, GamemodeLabel, sizeof(GamemodeLabel), CurrentGamemodeLabel);
	new Float:HeadshotRatio = InfectedKilled == 0 ? 0.00 : float(Headshots)/float(InfectedKilled)*100;

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlayerRankTitle", Name);
	SetPanelTitle(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_OverallRank", Rank, TotalRank);
	DrawPanelText(RankPanel, Value);

	if (!InvalidGameMode())
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_ModeRank", GamemodeLabel, GameModeRank, GameModeTotal);
		DrawPanelText(RankPanel, Value);
	}

	if (Playtime > 60)
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlaytimeHours", float(Playtime)/ 60.0);
		DrawPanelText(RankPanel, Value);
	}
	else
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PlaytimeMinutes", Playtime);
		DrawPanelText(RankPanel, Value);
	}

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CurrentPoints", Points);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_QuarterPoints", QuarterLabel, QuarterPoints);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_QuarterRank", QuarterLabel, QuarterRank, QuarterTotal);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_PointsPerMinute", PPM);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_CommonKilled", InfectedKilled);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_SurvivorsKilled", SurvivorsKilled);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_Headshots", Headshots);
	DrawPanelText(RankPanel, Value);

	StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_HeadshotRatio", HeadshotRatio);
	DrawPanelText(RankPanel, Value);

	if (!StrEqual(URL, "", false))
	{
		StatsFormatPhrase(client, Value, sizeof(Value), "L4DStats_FullStatsUrl", URL);
		DrawPanelText(RankPanel, Value);
	}

	StatsDrawPanelItem(RankPanel, client, "L4DStats_Close");
	SendPanelToClient(RankPanel, client, RankPanelHandler, 30);
	CloseHandle(RankPanel);
}

public StartRankVote(client)
{
	if (L4DStatsConf == INVALID_HANDLE)
	{
		if (client > 0)
		{
			StatsPrintToChatPreFormatted(client, "L4DStats_RankVoteSettingsFailed");
		}
		else
		{
			StatsPrintToConsolePhrase(0, "L4DStats_RankVoteGamedataMissingConsole");
		}
	}

	else if (!GetConVarBool(cvar_EnableRankVote))
	{
		if (client > 0)
		{
			StatsPrintToChatPreFormatted(client, "L4DStats_RankVoteDisabledChat");
		}
		else
		{
			StatsPrintToConsolePhrase(0, "L4DStats_RankVoteDisabledConsole");
		}
	}

	else
	{
		InitializeRankVote(client);
	}
}

// Toggle client rank mute.
public Action:cmd_ToggleClientRankMute(client, args)
{
	if (client == 0)
		return Plugin_Handled;

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	new String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	ClientRankMute[client] = !ClientRankMute[client];

	decl String:query[256];
	Format(query, sizeof(query), "UPDATE %ssettings SET mute = %i WHERE steamid = '%s'", DbPrefix, (ClientRankMute[client] ? 1 : 0), SteamID);
	SendSQLUpdate(query);

	AnnounceClientRankMute(client);

	return Plugin_Handled;
}

ShowRankMuteUsage(client)
{
	StatsPrintToConsolePhrase(client, "L4DStats_RankMuteUsage");
}

// Show current message of the day.
public Action:cmd_ShowMotd(client, args)
{
	ShowMOTD(client, true);
}

// Set client rank mute.
public Action:cmd_ClientRankMute(client, args)
{
	if (client == 0)
		return Plugin_Handled;

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	if (args != 1)
	{
		ShowRankMuteUsage(client);
		return Plugin_Handled;
	}

	decl String:arg[MAX_LINE_WIDTH];
	GetCmdArgString(arg, sizeof(arg));

	if (!StrEqual(arg, "0") && !StrEqual(arg, "1"))
	{
		ShowRankMuteUsage(client);
		return Plugin_Handled;
	}
	
	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	ClientRankMute[client] = StrEqual(arg, "1");

	decl String:query[256];
	Format(query, sizeof(query), "UPDATE %ssettings SET mute = %s WHERE steamid = '%s'", DbPrefix, arg, SteamID);
	SendSQLUpdate(query);

	AnnounceClientRankMute(client);

	return Plugin_Handled;
}

AnnounceClientRankMute(client)
{
	StatsPrintToChat2(client, true, ClientRankMute[client] ? "L4DStats_RankMessagesMuted" : "L4DStats_RankMessagesUnmuted");
}

// Start RANKVOTE.
public Action:cmd_RankVote(client, args)
{
	if (client == 0)
	{
		StartRankVote(client);
		return Plugin_Handled;
	}

	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
	{
		return Plugin_Handled;
	}

	new ClientFlags = GetUserFlagBits(client);
	new bool:IsAdmin = ((ClientFlags & ADMFLAG_GENERIC) == ADMFLAG_GENERIC);

	new ClientTeam = GetClientTeam(client);

	if (!IsAdmin && ClientTeam != TEAM_SURVIVORS && ClientTeam != TEAM_INFECTED)
	{
		StatsPrintToChatPreFormatted2(client, true, "L4DStats_RankVoteSpectatorDenied");
		return Plugin_Handled;
	}

	StartRankVote(client);

	return Plugin_Handled;
}

// Generate the TIMEDMAPS display menu.
public Action:cmd_TimedMaps(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.mutation FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid", DbPrefix, DbPrefix);
	SQL_TQuery(db, CreateTimedMapsMenu, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Generate the MAPTIME display menu.
public Action:cmd_MapTimes(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:Info[MAX_LINE_WIDTH], String:CurrentMapName[MAX_LINE_WIDTH];

	GetCurrentMap(CurrentMapName, sizeof(CurrentMapName));
	Format(Info, sizeof(Info), "%i\\%s", Stats_GetCurrentStatsGamemodeID(), CurrentMapName);

	DisplayTimedMapsMenu3FromInfo(client, Info);

	return Plugin_Handled;
}

// Generate the SHOWMAPTIME display menu.
public Action:cmd_ShowMapTimes(client, args)
{
	if (client == 0 || !IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	StatsPrintToChatPreFormatted2(client, true, "L4DStats_NotImplemented");

	return Plugin_Handled;
}

// Generate the SHOWPPM display menu.
public Action:cmd_ShowPPMs(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	//Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	//SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT steamid, name, (%s) / (%s) AS ppm FROM %splayers WHERE ", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix);

	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:where[512];
	new counter = 0;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		if (counter++ > 0)
			StrCat(query, sizeof(query), "OR ");

		GetClientRankAuthString(i, SteamID, sizeof(SteamID));
		Format(where, sizeof(where), "steamid = '%s' ", SteamID);
		StrCat(query, sizeof(query), where);
	}

	if (counter == 0)
		return Plugin_Handled;

	if (counter == 1)
	{
		cmd_ShowRank(client, 0);
		return Plugin_Handled;
	}

	StrCat(query, sizeof(query), "ORDER BY ppm DESC");

	SQL_TQuery(db, CreatePPMMenu, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Generate the SHOWRANK display menu.
public Action:cmd_ShowRanks(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	//Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	//SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT steamid, name, %s AS totalpoints FROM %splayers WHERE ", DB_PLAYERS_TOTALPOINTS, DbPrefix);

	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:where[512];
	new counter = 0;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		if (counter++ > 0)
			StrCat(query, sizeof(query), "OR ");

		GetClientRankAuthString(i, SteamID, sizeof(SteamID));
		Format(where, sizeof(where), "steamid = '%s' ", SteamID);
		StrCat(query, sizeof(query), where);
	}

	if (counter == 0)
		return Plugin_Handled;

	if (counter == 1)
	{
		cmd_ShowRank(client, 0);
		return Plugin_Handled;
	}

	StrCat(query, sizeof(query), "ORDER BY totalpoints DESC");

	SQL_TQuery(db, CreateRanksMenu, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Generate the TOPPPM display panel.
public Action:cmd_ShowTop10PPM(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[1024];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT name, (%s) / (%s) AS ppm FROM %splayers WHERE (%s) >= %i ORDER BY ppm DESC, (%s) DESC LIMIT 10", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix, DB_PLAYERS_TOTALPLAYTIME, GetConVarInt(cvar_Top10PPMMin), DB_PLAYERS_TOTALPLAYTIME);
	SQL_TQuery(db, DisplayTop10PPM, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Reget currently score(client)
public Action cmd_ResetScore(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;
	QueryClientPoints(client);
	return Plugin_Handled;
}

// Generate the TOP10 display panel.
public Action:cmd_ShowTop10(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	decl String:query[512];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM %splayers", DbPrefix);
	SQL_TQuery(db, GetRankTotal, query);

	Format(query, sizeof(query), "SELECT name FROM %splayers ORDER BY %s DESC LIMIT 10", DbPrefix, DB_PLAYERS_TOTALPOINTS);
	SQL_TQuery(db, DisplayTop10, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Generate the quarterly TOP10 display panel.
public Action:cmd_ShowQuarterTop10(client, args)
{
	if (!IsClientConnected(client) && !IsClientInGame(client) && IsClientBot(client))
		return Plugin_Handled;

	if (!QuarterRank_Enabled() && !QuarterRank_RecoverIfNeeded())
	{
		StatsPrintToChat(client, "L4DStats_QuarterRankingUnavailable");
		return Plugin_Handled;
	}

	QuarterRank_QueryTotal();

	decl String:query[512];
	Format(query, sizeof(query), "SELECT p.name, q.points FROM `%sscore_quarter` AS q INNER JOIN %splayers AS p ON q.steamid = p.steamid WHERE q.quarter_key = %i AND q.points > 0 ORDER BY q.points DESC LIMIT 10", DbPrefix, DbPrefix, QuarterRank_GetCurrentQuarter());
	SQL_TQuery(db, DisplayQuarterTop10, query, GetClientUserId(client));

	return Plugin_Handled;
}

// Find a player from Top 10 ranking.
public GetClientFromTop10(client, rank)
{
	decl String:query[512];
	Format(query, sizeof(query), "SELECT (%s) as totalpoints, steamid FROM %splayers ORDER BY totalpoints DESC LIMIT %i,1", DB_PLAYERS_TOTALPOINTS, DbPrefix, rank);
	SQL_TQuery(db, GetClientTop10, query, GetClientUserId(client));
}

// Find a player from quarterly Top 10 ranking.
public GetClientFromQuarterTop10(client, rank)
{
	decl String:query[512];
	Format(query, sizeof(query), "SELECT q.points AS totalpoints, q.steamid FROM `%sscore_quarter` AS q WHERE q.quarter_key = %i AND q.points > 0 ORDER BY q.points DESC LIMIT %i,1", DbPrefix, QuarterRank_GetCurrentQuarter(), rank);
	SQL_TQuery(db, GetClientTop10, query, GetClientUserId(client));
}

// Find a player from Top 10 PPM ranking.
public GetClientFromTop10PPM(client, rank)
{
	decl String:query[1024];
	Format(query, sizeof(query), "SELECT (%s) AS totalpoints, steamid, (%s) AS totalplaytime FROM %splayers WHERE (%s) >= %i ORDER BY (totalpoints / totalplaytime) DESC, totalplaytime DESC LIMIT %i,1", DB_PLAYERS_TOTALPOINTS, DB_PLAYERS_TOTALPLAYTIME, DbPrefix, DB_PLAYERS_TOTALPLAYTIME, GetConVarInt(cvar_Top10PPMMin), rank);
	SQL_TQuery(db, GetClientTop10, query, GetClientUserId(client));
}

// Send the Top 10 player's info to the client.
public GetClientTop10(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("GetClientTop10 failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 1, SteamID, sizeof(SteamID));

		QueryClientStatsSteamID(client, SteamID, CM_TOP10);
	}
}

public ExecuteTeamShuffle(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("ExecuteTeamShuffle failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new i, team, maxplayers = MaxClients, client, topteam;
	new SurvivorsLimit = GetConVarInt(cvar_SurvivorLimit), InfectedLimit = GetConVarInt(cvar_InfectedLimit);
	new Handle:PlayersTrie = CreateTrie();
	new Handle:InfectedArray = CreateArray();
	new Handle:SurvivorArray = CreateArray();

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			GetClientRankAuthString(i, SteamID, sizeof(SteamID));

			if (!SetTrieValue(PlayersTrie, SteamID, i, false))
			{
				LogError("ExecuteTeamShuffle failed! Reason: Duplicate SteamID while generating shuffled teams.");
				StatsPrintToChatAllPreFormatted2(true, "L4DStats_TeamShuffleFailed");

				SetConVarBool(cvar_EnableRankVote, false);

				ClearTrie(PlayersTrie);
				CloseHandle(PlayersTrie);

				CloseHandle(hndl);

				return;
			}

			switch (GetClientTeam(i))
			{
				case TEAM_SURVIVORS:
					PushArrayCell(SurvivorArray, i);
				case TEAM_INFECTED:
					PushArrayCell(InfectedArray, i);
			}
		}
	}

	new SurvivorCounter = GetArraySize(SurvivorArray);
	new InfectedCounter = GetArraySize(InfectedArray);

	i = 0;
	topteam = 0;

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));

		if (GetTrieValue(PlayersTrie, SteamID, client))
		{
			team = GetClientTeam(client);

			if (i == 0)
			{
				if (team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
				else
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}

				topteam = team;
				i++;

				continue;
			}

			if (i++ % 2)
			{
				if (topteam == TEAM_SURVIVORS && team == TEAM_INFECTED)
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}
				else if (topteam == TEAM_INFECTED && team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
			}
			else
			{
				if (topteam == TEAM_SURVIVORS && team == TEAM_SURVIVORS)
				{
					RemoveFromArray(SurvivorArray, FindValueInArray(SurvivorArray, client));
				}
				else if (topteam == TEAM_INFECTED && team == TEAM_INFECTED)
				{
					RemoveFromArray(InfectedArray, FindValueInArray(InfectedArray, client));
				}
			}
		}
	}

	if (GetArraySize(SurvivorArray) > 0 || GetArraySize(InfectedArray) > 0)
	{
		new NewSurvivorCounter = SurvivorCounter - GetArraySize(SurvivorArray) + GetArraySize(InfectedArray);
		new NewInfectedCounter = InfectedCounter - GetArraySize(InfectedArray) + GetArraySize(SurvivorArray);

		if (NewSurvivorCounter > SurvivorsLimit || NewInfectedCounter > InfectedLimit)
		{
			LogError("ExecuteTeamShuffle failed! Reason: Team size limits block Rank Vote functionality. (Survivors Limit = %i [%i] / Infected Limit = %i [%i])", SurvivorsLimit, NewSurvivorCounter, InfectedLimit, NewInfectedCounter);
			StatsPrintToChatAllPreFormatted2(true, "L4DStats_TeamShuffleFailed");

			SetConVarBool(cvar_EnableRankVote, false);
		}
		else
		{
			CampaignOver = true;

			decl String:Name[32];

			// Change Survivors team to Spectators (TEMPORARILY)
			for (i = 0; i < GetArraySize(SurvivorArray); i++)
			{
				ChangeRankPlayerTeam(GetArrayCell(SurvivorArray, i), TEAM_SPECTATORS);
			}

			// Change Infected team to Survivors
			for (i = 0; i < GetArraySize(InfectedArray); i++)
			{
				client = GetArrayCell(InfectedArray, i);
				GetClientName(client, Name, sizeof(Name));

				ChangeRankPlayerTeam(client, TEAM_SURVIVORS);

				StatsPrintToChatAll2(true, "L4DStats_PlayerJoinedSurvivors", Name);
			}

			// Change Spectators (TEMPORARILY) team to Infected
			for (i = 0; i < GetArraySize(SurvivorArray); i++)
			{
				client = GetArrayCell(SurvivorArray, i);
				GetClientName(client, Name, sizeof(Name));

				ChangeRankPlayerTeam(client, TEAM_INFECTED);

				StatsPrintToChatAll2(true, "L4DStats_PlayerJoinedInfected", Name);
			}

			StatsPrintToChatAllPreFormatted2(true, "L4DStats_TeamShuffleDone");

			if (EnableSounds_Rankvote && GetConVarBool(cvar_SoundsEnabled))
				EmitSoundToAll(SOUND_RANKVOTE);
		}
	}
	else
	{
		StatsPrintToChatAllPreFormatted2(true, "L4DStats_TeamsAlreadyEven");
	}

	ClearArray(SurvivorArray);
	ClearArray(InfectedArray);
	ClearTrie(PlayersTrie);

	CloseHandle(SurvivorArray);
	CloseHandle(InfectedArray);
	CloseHandle(PlayersTrie);

	CloseHandle(hndl);
}

public CreateRanksMenu(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreateRanksMenu failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new Handle:menu = CreateMenu(Menu_CreateRanksMenuHandler);

	decl String:Name[32], String:DisplayName[MAX_LINE_WIDTH];

	StatsSetMenuTitle(menu, client, "L4DStats_PlayerRanksTitle");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		StatsFormatPhrase(client, DisplayName, sizeof(DisplayName), "L4DStats_PlayerPointsMenuItem", Name, SQL_FetchInt(hndl, 2));

		AddMenuItem(menu, SteamID, DisplayName);
	}

	DisplayMenu(menu, client, 30);
}

public CreateTimedMapsMenu(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		StatsSetPanelTitle(TimedMapsPanel, client, "L4DStats_TimedMapsTitle");

		StatsDrawPanelText(TimedMapsPanel, client, "L4DStats_MapNeverPlayed");
		StatsDrawPanelItem(TimedMapsPanel, client, "L4DStats_Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Gamemode;
	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenuHandler);
	decl String:GamemodeTitle[32], String:GamemodeInfo[2]; //, MutationInfo[MAX_LINE_WIDTH];

	StatsSetMenuTitle(menu, client, "L4DStats_TimedMapsTitle");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		Gamemode = SQL_FetchInt(hndl, 0);
		IntToString(Gamemode, GamemodeInfo, sizeof(GamemodeInfo));

		switch (Gamemode)
		{
		case GAMEMODE_COOP:
				StatsFormatPhrase(client, GamemodeTitle, sizeof(GamemodeTitle), "L4DStats_GamemodeCoop");
			case GAMEMODE_SURVIVAL:
				StatsFormatPhrase(client, GamemodeTitle, sizeof(GamemodeTitle), "L4DStats_GamemodeSurvival");
			case GAMEMODE_REALISM:
				StatsFormatPhrase(client, GamemodeTitle, sizeof(GamemodeTitle), "L4DStats_GamemodeRealism");
			case GAMEMODE_OTHERMUTATIONS:
			{
				StatsFormatPhrase(client, GamemodeTitle, sizeof(GamemodeTitle), "L4DStats_GamemodeMutations");
				//SQL_FetchString(hndl, 1, MutationInfo, sizeof(MutationInfo));
				//Format(GamemodeTitle, sizeof(GamemodeTitle), "Mutations (%s)", MutationInfo);
			}
			default:
				continue;
		}

		if (Stats_GetCurrentStatsGamemodeID() == Gamemode)
			StrCat(GamemodeTitle, sizeof(GamemodeTitle), TM_MENU_CURRENT);

		AddMenuItem(menu, GamemodeInfo, GamemodeTitle);
	}

	DisplayMenu(menu, client, 30);

	return;
}

public Menu_CreateTimedMapsMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[2];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu2FromInfo(param1, Info);
}

bool:TimedMapsMenuInfoMarker(String:Info[], MenuNumber)
{
	if (Info[0] == '\0' || MenuNumber < 2)
		return false;

	new Position = -1, TempPosition;

	for (new i = 0; i < MenuNumber; i++)
	{
		TempPosition = FindCharInString(Info[Position + 1], '\\');

		if (TempPosition < 0)
		{
			if (i + 2 == MenuNumber)
				return true;
			else
				return false;
		}

		Position += 1 + TempPosition;

		if (i + 2 >= MenuNumber)
		{
			Info[Position] = '\0';
			return true;
		}
	}

	return false;
}

public DisplayTimedMapsMenu2FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 2))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	new Gamemode = StringToInt(Info);

	DisplayTimedMapsMenu2(client, Gamemode);
}

public DisplayTimedMapsMenu2(client, Gamemode)
{
	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.map FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i ORDER BY tm.map ASC", DbPrefix, DbPrefix, Gamemode);
	SQL_TQuery(db, CreateTimedMapsMenu2, query, GetClientUserId(client));
}

public CreateTimedMapsMenu2(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu2 failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		StatsSetPanelTitle(TimedMapsPanel, client, "L4DStats_ModeTimesTitle");

		StatsDrawPanelText(TimedMapsPanel, client, "L4DStats_ModeNeverPlayed");
		StatsDrawPanelItem(TimedMapsPanel, client, "L4DStats_Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu2Hndl), Gamemode;
	decl String:Map[MAX_LINE_WIDTH], String:Info[MAX_LINE_WIDTH], String:CurrentMapName[MAX_LINE_WIDTH];

	GetCurrentMap(CurrentMapName, sizeof(CurrentMapName));

	StatsSetMenuTitle(menu, client, "L4DStats_TimedMapsTitle");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		Gamemode = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 1, Map, sizeof(Map));

		Format(Info, sizeof(Info), "%i\\%s", Gamemode, Map);

		if (Stats_GetCurrentStatsGamemodeID() == Gamemode && StrEqual(CurrentMapName, Map))
			StrCat(Map, sizeof(Map), TM_MENU_CURRENT);

		AddMenuItem(menu, Info, Map);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu2Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			cmd_TimedMaps(param1, 0);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu3FromInfo(param1, Info);
}

public DisplayTimedMapsMenu3FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 3))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	decl String:GamemodeInfo[2], String:Map[MAX_LINE_WIDTH];

	strcopy(GamemodeInfo, sizeof(GamemodeInfo), Info);
	GamemodeInfo[1] = 0;

	strcopy(Map, sizeof(Map), Info[2]);

	DisplayTimedMapsMenu3(client, StringToInt(GamemodeInfo), Map);
}

public DisplayTimedMapsMenu3(client, Gamemode, const String:Map[])
{
	new Handle:dp = CreateDataPack();

	WritePackCell(dp, GetClientUserId(client));
	WritePackCell(dp, Gamemode);
	WritePackString(dp, Map);

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	decl String:query[256];
	Format(query, sizeof(query), "SELECT tm.time FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' AND p.steamid = '%s'", DbPrefix, DbPrefix, Gamemode, Map, SteamID);
	SQL_TQuery(db, DisplayTimedMapsMenu3_2, query, dp);
}

public DisplayTimedMapsMenu3_2(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		if (dp != INVALID_HANDLE)
			CloseHandle(dp);

		LogError("DisplayTimedMapsMenu3_2 failed! Reason: %s", error);
		return;
	}

	ResetPack(dp);

	new userid = ReadPackCell(dp);
	new Gamemode = ReadPackCell(dp);
	decl String:Map[MAX_LINE_WIDTH];
	ReadPackString(dp, Map, sizeof(Map));

	CloseHandle(dp);

	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (SQL_FetchRow(hndl))
		ClientMapTime[client] = SQL_FetchFloat(hndl, 0);
	else
		ClientMapTime[client] = 0.0;

	decl String:query[256];
	Format(query, sizeof(query), "SELECT DISTINCT tm.gamemode, tm.map, tm.time FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' ORDER BY tm.time %s", DbPrefix, DbPrefix, Gamemode, Map, (Gamemode == GAMEMODE_SURVIVAL ? "DESC" : "ASC"));
	SQL_TQuery(db, CreateTimedMapsMenu3, query, userid);
}

public CreateTimedMapsMenu3(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu3 failed! Reason: %s", error);
		return;
	}

	if (SQL_GetRowCount(hndl) <= 0)
	{
		new Handle:TimedMapsPanel = CreatePanel();
		StatsSetPanelTitle(TimedMapsPanel, client, "L4DStats_TimedMapsTitle");

		StatsDrawPanelText(TimedMapsPanel, client, "L4DStats_MapNeverPlayed");
		StatsDrawPanelItem(TimedMapsPanel, client, "L4DStats_Close");

		SendPanelToClient(TimedMapsPanel, client, TimedMapsPanelHandler, 30);
		CloseHandle(TimedMapsPanel);

		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu3Hndl), Float:MapTime;
	decl String:Map[MAX_LINE_WIDTH], String:Info[MAX_LINE_WIDTH], String:Value[MAX_LINE_WIDTH];

	StatsSetMenuTitle(menu, client, "L4DStats_TimedMapsTitle");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 1, Map, sizeof(Map));
		MapTime = SQL_FetchFloat(hndl, 2);

		SetTimeLabel(MapTime, Value, sizeof(Value), client);

		Format(Info, sizeof(Info), "%i\\%s\\%f", SQL_FetchInt(hndl, 0), Map, MapTime);

		if (ClientMapTime[client] > 0.0 && ClientMapTime[client] == MapTime)
			StrCat(Value, sizeof(Value), TM_MENU_CURRENT);

		AddMenuItem(menu, Info, Value);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu3Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayTimedMapsMenu2FromInfo(param1, MapTimingMenuInfo[param1]);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	DisplayTimedMapsMenu4FromInfo(param1, Info);
}

public DisplayTimedMapsMenu4FromInfo(client, String:Info[])
{
	if (!TimedMapsMenuInfoMarker(Info, 4))
	{
		cmd_TimedMaps(client, 0);
		return;
	}

	strcopy(MapTimingMenuInfo[client], MAX_LINE_WIDTH, Info);

	decl String:GamemodeInfo[2], String:Map[MAX_LINE_WIDTH];

	strcopy(GamemodeInfo, sizeof(GamemodeInfo), Info);
	GamemodeInfo[1] = 0;

	new Position = FindCharInString(Info[2], '\\');

	if (Position < 0)
	{
		LogError("Timed Maps menu 4 error: Info = \"%s\"", Info);
		return;
	}

	Position += 2;

	strcopy(Map, sizeof(Map), Info[2]);
	Map[Position - 2] = '\0';

	decl String:MapTime[MAX_LINE_WIDTH];
	strcopy(MapTime, sizeof(MapTime), Info[Position + 1]);

	DisplayTimedMapsMenu4(client, StringToInt(GamemodeInfo), Map, StringToFloat(MapTime));
}

public DisplayTimedMapsMenu4(client, Gamemode, const String:Map[], Float:MapTime)
{
	decl String:query[256];
	Format(query, sizeof(query), "SELECT tm.steamid, p.name FROM %stimedmaps AS tm INNER JOIN %splayers AS p ON tm.steamid = p.steamid WHERE tm.gamemode = %i AND tm.map = '%s' AND tm.time = %f ORDER BY p.name ASC", DbPrefix, DbPrefix, Gamemode, Map, MapTime);
	SQL_TQuery(db, CreateTimedMapsMenu4, query, GetClientUserId(client));
}

public CreateTimedMapsMenu4(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreateTimedMapsMenu4 failed! Reason: %s", error);
		return;
	}

	new Handle:menu = CreateMenu(Menu_CreateTimedMapsMenu4Hndl);

	decl String:Name[32], String:SteamID[MAX_LINE_WIDTH];

	StatsSetMenuTitle(menu, client, "L4DStats_TimedMapsTitle");
	SetMenuExitBackButton(menu, true);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		AddMenuItem(menu, SteamID, Name);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateTimedMapsMenu4Hndl(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayTimedMapsMenu3FromInfo(param1, MapTimingMenuInfo[param1]);

		return;
	}

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, SteamID, sizeof(SteamID));

	if (!found)
		return;

	QueryClientStatsSteamID(param1, SteamID, CM_RANK);
}

public CreatePPMMenu(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("CreatePPMMenu failed! Reason: %s", error);
		return;
	}

	decl String:SteamID[MAX_LINE_WIDTH];
	new Handle:menu = CreateMenu(Menu_CreateRanksMenuHandler);

	decl String:Name[32], String:DisplayName[MAX_LINE_WIDTH];

	StatsSetMenuTitle(menu, client, "L4DStats_PlayerPPMTitle");
	SetMenuExitBackButton(menu, false);
	SetMenuExitButton(menu, true);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, SteamID, sizeof(SteamID));
		SQL_FetchString(hndl, 1, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		StatsFormatPhrase(client, DisplayName, sizeof(DisplayName), "L4DStats_PlayerPPMMenuItem", Name, SQL_FetchFloat(hndl, 2));

		AddMenuItem(menu, SteamID, DisplayName);
	}

	DisplayMenu(menu, client, 30);
}

public Menu_CreateRanksMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:SteamID[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, SteamID, sizeof(SteamID));

	if (!found)
		return;

	QueryClientStatsSteamID(param1, SteamID, CM_RANK);
}

public Menu_CreateRankMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:Info[MAX_LINE_WIDTH];
	new bool:found = GetMenuItem(menu, param2, Info, sizeof(Info));

	if (!found)
		return;

	if (strcmp(Info, "rankabout", false) == 0)
	{
		DisplayAboutPanel(param1);
		return;
	}

	else if (strcmp(Info, "showsettings", false) == 0)
	{
		DisplaySettingsPanel(param1);
		return;
	}

	HandleCommands(param1, Info);
}

// Send the RANKABOUT panel to the client's display.
public DisplayAboutPanel(client)
{
	new Handle:panel = CreatePanel();

	StatsSetPanelTitle(panel, client, "L4DStats_AboutTitle");
	StatsDrawPanelText(panel, client, "L4DStats_AboutVersion", PLUGIN_VERSION);
	StatsDrawPanelText(panel, client, "L4DStats_AboutAuthor");
	StatsDrawPanelText(panel, client, "L4DStats_AboutDescription");
	StatsDrawPanelItem(panel, client, "L4DStats_Back");
	StatsDrawPanelItem(panel, client, "L4DStats_Close");

	SendPanelToClient(panel, client, AboutPanelHandler, 30);
	CloseHandle(panel);
}

// Send the RANKABOUT panel to the client's display.
public DisplaySettingsPanel(client)
{
	new Handle:panel = CreatePanel();

	StatsSetPanelTitle(panel, client, "L4DStats_SettingsTitle");
	StatsDrawPanelItem(panel, client, ClientRankMute[client] ? "L4DStats_SettingsUnmute" : "L4DStats_SettingsMute");
	StatsDrawPanelItem(panel, client, "L4DStats_Back");
	StatsDrawPanelItem(panel, client, "L4DStats_Close");

	SendPanelToClient(panel, client, SettingsPanelHandler, 30);
	CloseHandle(panel);
}



// Send the TOP10 panel to the client's display.
public DisplayTop10(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayTop10 failed! Reason: %s", error);
		return;
	}

	new String:Name[32];

	new Handle:Top10Panel = CreatePanel();
	StatsSetPanelTitle(Top10Panel, client, "L4DStats_Top10Title");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		DrawPanelItem(Top10Panel, Name);
	}

	SendPanelToClient(Top10Panel, client, Top10PanelHandler, 30);
	CloseHandle(Top10Panel);
}

// Send the quarterly TOP10 panel to the client's display.
public DisplayQuarterTop10(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayQuarterTop10 failed! Reason: %s", error);
		StatsPrintToChat(client, "L4DStats_QuarterRankingQueryFailed");
		return;
	}

	decl String:Name[32], String:Disp[MAX_LINE_WIDTH], String:QuarterLabel[32];
	QuarterRank_FormatCurrentQuarter(client, QuarterLabel, sizeof(QuarterLabel));

	new Handle:Top10Panel = CreatePanel();
	StatsFormatPhrase(client, Disp, sizeof(Disp), "L4DStats_QuarterTop10Title", QuarterLabel);
	SetPanelTitle(Top10Panel, Disp);

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		StatsFormatPhrase(client, Disp, sizeof(Disp), "L4DStats_PlayerScoreMenuItem", Name, SQL_FetchInt(hndl, 1));
		DrawPanelItem(Top10Panel, Disp);
	}

	SendPanelToClient(Top10Panel, client, QuarterTop10PanelHandler, 30);
	CloseHandle(Top10Panel);
}

// Send the TOP10PPM panel to the client's display.
public DisplayTop10PPM(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (hndl == INVALID_HANDLE)
	{
		LogError("DisplayTop10PPM failed! Reason: %s", error);
		return;
	}

	decl String:Name[32], String:Disp[MAX_LINE_WIDTH];

	new Handle:TopPPMPanel = CreatePanel();
	StatsSetPanelTitle(TopPPMPanel, client, "L4DStats_Top10PPMTitle");

	while (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, Name, sizeof(Name));

		ReplaceString(Name, sizeof(Name), "&lt;", "<");
		ReplaceString(Name, sizeof(Name), "&gt;", ">");
		ReplaceString(Name, sizeof(Name), "&#37;", "%");
		ReplaceString(Name, sizeof(Name), "&#61;", "=");
		ReplaceString(Name, sizeof(Name), "&#42;", "*");

		StatsFormatPhrase(client, Disp, sizeof(Disp), "L4DStats_PlayerPPMMenuItem", Name, SQL_FetchFloat(hndl, 1));

		DrawPanelItem(TopPPMPanel, Disp);
	}

	SendPanelToClient(TopPPMPanel, client, Top10PPMPanelHandler, 30);
	CloseHandle(TopPPMPanel);
}

// Handler for RANK panel.
public RankPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for NEXTRANK panel.
public NextRankPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (param2 == 1)
		QueryClientStats(param1, CM_NEXTRANKFULL);
}

// Handler for NEXTRANK panel.
public NextRankFullPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for TIMEDMAPS panel.
public TimedMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
}

// Handler for RANKADMIN panel.
//public RankAdminPanelHandler(Handle:menu, MenuAction:action, param1, param2)
//{
//	if (action != MenuAction_Select)
//		return;
//
//	if (param2 == 1)
//		DisplayClearPanel(param1);
//	else if (param2 == 2)
//		DisplayYesNoPanel(param1, "Do you really want to clear the player stats?", ClearPlayersPanelHandler);
//	else if (param2 == 3)
//		DisplayYesNoPanel(param1, "Do you really want to clear the map stats?", ClearMapsPanelHandler);
//	else if (param2 == 4)
//		DisplayYesNoPanel(param1, "Do you really want to clear all stats?", ClearAllPanelHandler);
//}

// Handler for RANKADMIN panel.
public ClearPlayersPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsPlayers(param1);
		StatsPrintToChatPreFormatted(param1, "L4DStats_AllPlayerStatsCleared");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsMaps(param1);
		StatsPrintToChatPreFormatted(param1, "L4DStats_AllMapStatsCleared");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearAllPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		ClearStatsAll(param1);
		StatsPrintToChatPreFormatted(param1, "L4DStats_AllStatsCleared");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public CleanPlayersPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		new LastOnTimeMonths = GetConVarInt(cvar_AdminPlayerCleanLastOnTime);
		new PlaytimeMinutes = GetConVarInt(cvar_AdminPlayerCleanPlatime);

		if (LastOnTimeMonths || PlaytimeMinutes)
		{
			new bool:Success = true;

			if (LastOnTimeMonths)
				Success &= DoFastQuery(param1, "DELETE FROM %splayers WHERE lastontime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL %i MONTH))", DbPrefix, LastOnTimeMonths);

			if (PlaytimeMinutes)
				Success &= DoFastQuery(param1, "DELETE FROM %splayers WHERE %s < %i AND lastontime < UNIX_TIMESTAMP(DATE_SUB(NOW(), INTERVAL 1 HOUR))", DbPrefix, DB_PLAYERS_TOTALPLAYTIME, PlaytimeMinutes);

			if (Success)
				StatsPrintToChatPreFormatted(param1, "L4DStats_PlayerCleaningSuccess");
			else
				StatsPrintToChatPreFormatted(param1, "L4DStats_PlayerCleaningFailed");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_PlayerCleaningDisabled");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public RemoveCustomMapsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %smaps WHERE custom = 1", DbPrefix))
			StatsPrintToChatPreFormatted(param1, "L4DStats_CustomMapsRemoved");
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_CustomMapsRemoveFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMAllPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps", DbPrefix))
		{
			DoFastQuery(param1, "DELETE FROM `%stimedmap_runs`", DbPrefix);
			StatsPrintToChatPreFormatted(param1, "L4DStats_AllMapTimesRemoved");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_MapTimesRemoveFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMCoopPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_COOP))
		{
			DoFastQuery(param1, "DELETE FROM `%stimedmap_runs` WHERE gamemode = %i", DbPrefix, GAMEMODE_COOP);
			StatsPrintToChatPreFormatted(param1, "L4DStats_CoopMapTimesClearSuccess");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_CoopMapTimesClearFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMSurvivalPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_SURVIVAL))
		{
			DoFastQuery(param1, "DELETE FROM `%stimedmap_runs` WHERE gamemode = %i", DbPrefix, GAMEMODE_SURVIVAL);
			StatsPrintToChatPreFormatted(param1, "L4DStats_SurvivalMapTimesClearSuccess");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_SurvivalMapTimesClearFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMRealismPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_REALISM))
		{
			DoFastQuery(param1, "DELETE FROM `%stimedmap_runs` WHERE gamemode = %i", DbPrefix, GAMEMODE_REALISM);
			StatsPrintToChatPreFormatted(param1, "L4DStats_RealismMapTimesClearSuccess");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_RealismMapTimesClearFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKADMIN panel.
public ClearTMMutationsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select)
		return;

	if (param2 == 1)
	{
		if (DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE gamemode = %i", DbPrefix, GAMEMODE_OTHERMUTATIONS))
		{
			DoFastQuery(param1, "DELETE FROM `%stimedmap_runs` WHERE gamemode = %i", DbPrefix, GAMEMODE_OTHERMUTATIONS);
			StatsPrintToChatPreFormatted(param1, "L4DStats_MutationMapTimesClearSuccess");
		}
		else
			StatsPrintToChatPreFormatted(param1, "L4DStats_MutationMapTimesClearFailed");
	}
	//else if (param2 == 2)
	//	cmd_RankAdmin(param1, 0);
}

// Handler for RANKVOTE panel.
public RankVotePanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action != MenuAction_Select || RankVoteTimer == INVALID_HANDLE || param1 <= 0 || IsClientBot(param1))
		return;

	if (param2 == 1 || param2 == 2)
	{
		new team = GetClientTeam(param1);

		if (team != TEAM_SURVIVORS && team != TEAM_INFECTED)
			return;

		new OldPlayerRankVote = PlayerRankVote[param1];

		if (param2 == 1)
			PlayerRankVote[param1] = RANKVOTE_YES;
		else if (param2 == 2)
			PlayerRankVote[param1] = RANKVOTE_NO;

		new humans = 0, votes = 0, yesvotes = 0, novotes = 0, WinningVoteCount = 0;

		CheckRankVotes(humans, votes, yesvotes, novotes, WinningVoteCount);

		if (yesvotes >= WinningVoteCount || novotes >= WinningVoteCount)
		{
			if (RankVoteTimer != INVALID_HANDLE)
			{
				CloseHandle(RankVoteTimer);
				RankVoteTimer = INVALID_HANDLE;
			}

			StatsPrintToChatAll(yesvotes >= WinningVoteCount ? "L4DStats_RankVotePassed" : "L4DStats_RankVoteFailed", yesvotes, novotes);

			if (yesvotes >= WinningVoteCount)
				CreateTimer(2.0, timer_ShuffleTeams);
		}

		if (OldPlayerRankVote != RANKVOTE_NOVOTE)
			return;

		decl String:Name[32];
		GetClientName(param1, Name, sizeof(Name));

		StatsPrintToChatAll("L4DStats_RankVoteProgress", Name, votes, humans);
	}
}

CheckRankVotes(&Humans, &Votes, &YesVotes, &NoVotes, &WinningVoteCount)
{
	Humans = 0;
	Votes = 0;
	YesVotes = 0;
	NoVotes = 0;
	WinningVoteCount = 0;

	new i, team, maxplayers = MaxClients;

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			team = GetClientTeam(i);

			if (team == TEAM_SURVIVORS || team == TEAM_INFECTED)
			{
				Humans++;

				if (PlayerRankVote[i] != RANKVOTE_NOVOTE)
				{
					Votes++;

					if (PlayerRankVote[i] == RANKVOTE_YES)
						YesVotes++;
				}
			}
		}
	}

	// More than half of the players are needed to vot YES for rankvote pass
	WinningVoteCount = RoundToNearest(float(Humans) / 2) + 1 - (Humans % 2);
	NoVotes = Votes - YesVotes;
}

DisplayClearPanel(client, delay=30)
{
	if (!client)
		return;

	//if (ClearPlayerMenu != INVALID_HANDLE)
	//{
	//	CloseHandle(ClearPlayerMenu);
	//	ClearPlayerMenu = INVALID_HANDLE;
	//}

	new Handle:ClearPlayerMenu = CreateMenu(DisplayClearPanelHandler);
	new maxplayers = MaxClients;
	decl String:SteamID[MAX_LINE_WIDTH], String:Name[32];

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientBot(i) || !IsClientConnected(i) || !IsClientInGame(i))
			continue;

		if (!GetClientRankAuthString(i, SteamID, sizeof(SteamID)))
			continue;

		GetClientName(i, Name, sizeof(Name));
		AddMenuItem(ClearPlayerMenu, SteamID, Name);
	}

	StatsSetMenuTitle(ClearPlayerMenu, client, "L4DStats_ClearPlayerStatsTitle");
	DisplayMenu(ClearPlayerMenu, client, delay);
}

// Handler for RANKADMIN panel.
public DisplayClearPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (menu == INVALID_HANDLE)
		return;

	if (action == MenuAction_End)
		CloseHandle(menu);

	if (action != MenuAction_Select || param1 <= 0 || IsClientBot(param1))
		return;

	decl String:SteamID[MAX_LINE_WIDTH], String:Name[32];
	new style;
	new bool:found = GetMenuItem(menu, param2, SteamID, sizeof(SteamID), style, Name, sizeof(Name));

	if (!found || Stats_IsInvalidRankAuthString(SteamID))
		return;

	new client = Stats_FindHumanClientBySteamID(SteamID);

	if (DoFastQuery(param1, "DELETE FROM %splayers WHERE steamid = '%s'", DbPrefix, SteamID))
	{
		DoFastQuery(param1, "DELETE FROM %stimedmaps WHERE steamid = '%s'", DbPrefix, SteamID);
		DoFastQuery(param1, "DELETE FROM `%stimedmap_runs` WHERE steamid = '%s'", DbPrefix, SteamID);

		if (client)
		{
			ClientPoints[client] = 0;
			ClientRank[client] = 0;
			ClientScoreReady[client] = true;
			GetClientName(client, Name, sizeof(Name));
			StatsPrintToChatPreFormatted(client, "L4DStats_OwnStatsCleared");
		}

		if (!client || client != param1)
			StatsPrintToChat(param1, "L4DStats_PlayerStatsCleared", Name);
	}
	else
		StatsPrintToChatPreFormatted(param1, "L4DStats_PlayerStatsClearFailed");
}

// Handler for RANKABOUT panel.
public AboutPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 1)
			cmd_ShowRankMenu(param1, 0);
	}
}

// Handler for RANK SETTINGS panel.
public SettingsPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 1)
			cmd_ToggleClientRankMute(param1, 0);
		if (param2 == 2)
			cmd_ShowRankMenu(param1, 0);
	}
}

// Handler for TOP10 panel. param1 handle param2 client
public Top10PanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 0)
			param2 = 10;

		GetClientFromTop10(param1, param2 - 1);
	}
}

// Handler for quarterly TOP10 panel.
public QuarterTop10PanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 0)
			param2 = 10;

		GetClientFromQuarterTop10(param1, param2 - 1);
	}
}

// Handler for TOP10PPM panel.
public Top10PPMPanelHandler(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_Select)
	{
		if (param2 == 0)
			param2 = 10;

		GetClientFromTop10PPM(param1, param2 - 1);
	}
}
