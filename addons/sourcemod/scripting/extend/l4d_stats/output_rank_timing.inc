#if defined _l4d_stats_output_rank_timing_included
	#endinput
#endif
#define _l4d_stats_output_rank_timing_included

// 聊天输出、地图计时、队伍洗牌辅助、MOTD 和 Anne 模式辅助。

// Print a chat message to a specific team instead of all players

public StatsPrintToChatTeam(Team, const String:Message[], any:...)
{
	new AnnounceToTeam = GetConVarInt(cvar_AnnounceToTeam);
	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		new ClientTeam = GetClientTeam(i);
		if (Team > 0 && AnnounceToTeam && ClientTeam != Team && (ClientTeam != TEAM_SPECTATORS || AnnounceToTeam != 2))
			continue;

		new String:FormattedMessage[MAX_MESSAGE_WIDTH];
		SetGlobalTransTarget(i);
		VFormat(FormattedMessage, sizeof(FormattedMessage), "%t", 2);
		StatsPrintToChatRaw(i, FormattedMessage);
	}
}

// Debugging...
/*
public PrintToConsoleAll(const String:Message[], any:...)
{
	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	VFormat(FormattedMessage, sizeof(FormattedMessage), Message, 2);

	PrintToConsole(0, FormattedMessage);

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			PrintToConsole(i, FormattedMessage);
}*/

// Disable map timings when opposing team has human players. The time is too much depending on opposing team that is is comparable.

MapTimingEnabled()
{
	return MapTimingBlocked || MapRecords_GetPolicy() != MAP_RECORD_POLICY_OFF;
}

MapTimingRuns_RecordParticipant(const String:RunID[], const String:MapName[], GamemodeID, const String:ClientID[], Float:TotalTime, PlayerCounter, GameDifficulty, const String:Mutation[], Mode)
{
	decl String:query[2048];
	Format(query, sizeof(query),
		"INSERT IGNORE INTO `%stimedmap_runs` "
		... "(`run_id`,`map`,`gamemode`,`difficulty`,`steamid`,`time`,`players`,`mutation`,`mode`,`sinum`,`sitime`,`usebuy`,`auto`,`anneversion`,`created`,`modified`) "
		... "VALUES ('%s','%s',%i,%i,'%s',%f,%i,'%s',%i,%i,%i,%i,%i,'%s',NOW(),NOW())",
		DbPrefix, RunID, MapName, GamemodeID, GameDifficulty, ClientID, TotalTime, PlayerCounter, Mutation, Mode,
		GetAnneInfectedNumber(), GetAnneSISpawnTime(), g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), IsAutoSpawnTime(), GetAnneVersion());
	SendSQLUpdate(query);
}

public StartMapTiming()
{
	if (!MapTimingEnabled() || MapTimingStartTime != 0.0 || StatsDisabled())
	{
		return;
	}

	MapTimingStartTime = GetEngineTime();
	g_bMapTimingGlobalBroadcastSent = false;
	g_bMapTimingNoFastestPromptSent = false;

	new ClientTeam, maxplayers = MaxClients;
	decl String:ClientID[MAX_LINE_WIDTH];

	ClearTrie(MapTimingSurvivors);
	ClearTrie(MapTimingInfected);

	new bool:SoundsEnabled = EnableSounds_Maptime_Start && GetConVarBool(cvar_SoundsEnabled);

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));
				SetTrieValue(MapTimingSurvivors, ClientID, 1, true);

				if (SoundsEnabled)
					EmitSoundToClient(i, StatsSound_MapTime_Start);
			}
			else if (ClientTeam == TEAM_INFECTED)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));
				SetTrieValue(MapTimingInfected, ClientID, 1, true);
			}
		}
	}
}

GetCurrentDifficulty()
{
	decl String:Difficulty[MAX_LINE_WIDTH];
	GetConVarString(cvar_Difficulty, Difficulty, sizeof(Difficulty));

	if (StrEqual(Difficulty, "normal", false)) return 1;
	else if (StrEqual(Difficulty, "hard", false)) return 2;
	else if (StrEqual(Difficulty, "impossible", false)) return 3;
	else return 0;
}

GetMapTimingDifficulty()
{
	if (AnneMultiPlayerMode() || IsAnneShotgunMode())
	{
		ConVar enabled = FindConVar("ah_ai_dynamic_enable");
		ConVar currentLevel = FindConVar("ah_ai_dynamic_current_level");
		if (currentLevel != null && (enabled == null || enabled.BoolValue))
		{
			new level = currentLevel.IntValue;
			if (level >= 1 && level <= 6)
				return level;
		}

		ConVar fixedLevel = FindConVar("ah_ai_dynamic_fixed_level");
		if (fixedLevel != null && (enabled == null || enabled.BoolValue))
		{
			new level = fixedLevel.IntValue;
			if (level >= 1 && level <= 6)
				return level;
		}
	}

	return GetCurrentDifficulty();
}

GetMapTimingMode()
{
	if (IsWitchParty())
		return 2;
	else if (IsAllCharger())
		return 3;
	else if (IsAlone())
		return 4;
	else if (Is1vht())
		return 5;
	else if (IsAnneShotgunMode())
		return 7;
	else if (IsAnne() == 2)
		return 6;
	else if (IsAnne() == 1)
		return 1;

	return 0;
}

bool:IsAnneTimingBroadcastMode(Mode)
{
	return Mode == 1 || Mode == 6 || Mode == 7;
}

GetMapTimingModePhrase(Mode, String:Phrase[], MaxLength)
{
	switch (Mode)
	{
		case 6:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordModeHardcore");
		case 7:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordModeShotgun");
		default:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordModeNormal");
	}
}

GetMapTimingDifficultyPhrase(Difficulty, String:Phrase[], MaxLength)
{
	switch (Difficulty)
	{
		case 1:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyEasy");
		case 2:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyNormal");
		case 3:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyHard");
		case 4:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyExpert");
		case 5:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyExtreme");
		case 6:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyNeri");
		default:
			strcopy(Phrase, MaxLength, "L4DStats_MapRecordDifficultyUnknown");
	}
}

BuildMapTimingRunPlayerNames(String:Names[], MaxLength)
{
	Names[0] = '\0';

	new shown = 0;
	new total = 0;
	new enabled;
	decl String:ClientID[MAX_LINE_WIDTH], String:ClientName[MAX_NAME_LENGTH], String:Buffer[MAX_MESSAGE_WIDTH];

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i) || GetClientTeam(i) != TEAM_SURVIVORS)
			continue;

		GetClientRankAuthString(i, ClientID, sizeof(ClientID));
		if (!GetTrieValue(MapTimingSurvivors, ClientID, enabled) || !enabled)
			continue;

		total++;
		if (shown >= 3)
			continue;

		GetClientName(i, ClientName, sizeof(ClientName));
		if (Names[0] == '\0')
		{
			if (strlen(ClientName) < MaxLength)
			{
				strcopy(Names, MaxLength, ClientName);
				shown++;
			}
		}
		else
		{
			Format(Buffer, sizeof(Buffer), "%s, %s", Names, ClientName);
			if (strlen(Buffer) < MaxLength)
			{
				strcopy(Names, MaxLength, Buffer);
				shown++;
			}
		}
	}

	if (total > shown)
	{
		if (Names[0] != '\0')
		{
			Format(Buffer, sizeof(Buffer), "%s ... (%d)", Names, total);
			if (strlen(Buffer) < MaxLength)
				strcopy(Names, MaxLength, Buffer);
			else
				Format(Names, MaxLength, "Team (%d)", total);
		}
		else
			Format(Names, MaxLength, "Team (%d)", total);
	}
	else if (Names[0] == '\0')
	{
		strcopy(Names, MaxLength, "Team");
	}
}

public bool StopMapTiming()
{
	return StopMapTimingWithOptions(true, true);
}

bool StopMapTimingWithOptions(bool:WriteLegacy, bool:Completed)
{
	if (!MapTimingEnabled() || MapTimingStartTime <= 0.0 || StatsDisabled())
	{
		return false;
	}
	new bool:HistoryOnly = MapRecords_GetPolicy() == MAP_RECORD_POLICY_HISTORY && !WriteLegacy;
	if(!HistoryOnly && g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID))
	{
		if (GetConVarInt(cvar_AnnounceMode))
		{
			StatsPrintToChatAll("L4DStats_MapTimeInvalidSettings");
		}
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}
	if(!HistoryOnly && !IsNormalMode() && !IsThisRoundValid())
	{
		if (GetConVarInt(cvar_AnnounceMode))
		{
			StatsPrintToChatAll("L4DStats_MapTimeInvalidBunnyHop");
		}
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}
	int mode = GetMapTimingMode();
	ConVar multiplayer = FindConVar("l4d_multislots_survivors_manager_enable");
	if(!HistoryOnly && mode > 0 && (multiplayer == null || multiplayer.IntValue == 1 || GetConVarInt(cvar_SurvivorLimit) > 4))
	{
		StatsPrintToChatAll("L4DStats_MapTimeInvalidMultiplayerMode");
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
		return false;
	}

	new Float:TotalTime = GetEngineTime() - MapTimingStartTime;
	if(!HistoryOnly && TotalTime < 30.0)
	{
		StatsPrintToChatAll("L4DStats_MapTimeTooShortNoReward");
		return false;
	}

	MapTimingStartTime = -1.0;
	MapTimingBlocked = true;

	new Handle:dp = INVALID_HANDLE;
	new ClientTeam, enabled, maxplayers = MaxClients;
	decl String:ClientID[MAX_LINE_WIDTH], String:MapName[MAX_LINE_WIDTH], String:query[4096];

	GetCurrentMap(MapName, sizeof(MapName));

	new i, PlayerCounter = 0, SurvivorCounter = 0, InfectedCounter = 0;

	// 结算时以实际过关队伍为准，补登记中途加入/重连后加入的真人幸存者。
	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == TEAM_SURVIVORS)
		{
			GetClientRankAuthString(i, ClientID, sizeof(ClientID));
			if (!GetTrieValue(MapTimingSurvivors, ClientID, enabled))
			{
				SetTrieValue(MapTimingSurvivors, ClientID, 1, true);
			}
		}
		else if (HistoryOnly && IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == TEAM_INFECTED)
		{
			GetClientRankAuthString(i, ClientID, sizeof(ClientID));
			if (!GetTrieValue(MapTimingInfected, ClientID, enabled))
				SetTrieValue(MapTimingInfected, ClientID, 1, true);
		}
	}

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);
			GetClientRankAuthString(i, ClientID, sizeof(ClientID));

				if (ClientTeam == TEAM_SURVIVORS && GetTrieValue(MapTimingSurvivors, ClientID, enabled))
				{
					if (enabled)
					{
						PlayerCounter++;
						SurvivorCounter++;
					}
				}
				else if (ClientTeam == TEAM_INFECTED)
				{
					if (GetTrieValue(MapTimingInfected, ClientID, enabled))
					{
						if (enabled)
						{
							InfectedCounter++;
							if (MapRecords_GetPolicy() == MAP_RECORD_POLICY_HISTORY)
								PlayerCounter++;
						}
					}
			}
		}
	}

	// Game ended because all of the infected team left the server... don't record the time!
	//if (InfectedCounter <= 0)
		//return;

	new GameDifficulty = GetMapTimingDifficulty();
	new StatsGamemodeID = Stats_GetCurrentStatsGamemodeID();
	if(mode > 0)
	{
		PlayerCounter = GetConVarInt(cvar_SurvivorLimit);
		SurvivorCounter = PlayerCounter;
	}

	decl String:RunID[64];
	Format(RunID, sizeof(RunID), "%i_%i_%i", GetTime(), RoundToFloor(TotalTime * 1000.0), GetRandomInt(1000, 9999));

	decl String:RunPlayers[MAP_RECORD_PLAYER_NAMES_MAX];
	BuildMapTimingRunPlayerNames(RunPlayers, sizeof(RunPlayers));
	MapRecords_RecordRun(RunID, MapName, CurrentGamemodeID, TotalTime, SurvivorCounter, InfectedCounter, GameDifficulty, mode, Completed);
	if (mode > 0)
		GetThisModeBestTime(g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY), RunID);

	if (!WriteLegacy || MapRecords_GetPolicy() != MAP_RECORD_POLICY_LEADERBOARD)
	{
		ClearTrie(MapTimingSurvivors);
		ClearTrie(MapTimingInfected);
		return true;
	}

	MaybeAnnounceAnneNoBuyFastest(MapName, TotalTime, PlayerCounter, GameDifficulty, mode, RunPlayers, RunID);

	new SICount = GetAnneInfectedNumber();
	new SISpawnTime = GetAnneSISpawnTime();
	new UseBuy = g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY);
	new Auto = IsAutoSpawnTime();
	decl String:AnneVersion[64];
	strcopy(AnneVersion, sizeof(AnneVersion), GetAnneVersion());

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ClientTeam = GetClientTeam(i);

			if (ClientTeam == TEAM_SURVIVORS)
			{
				GetClientRankAuthString(i, ClientID, sizeof(ClientID));

				if (GetTrieValue(MapTimingSurvivors, ClientID, enabled))
				{
					if (enabled)
						{
							MapTimingRuns_RecordParticipant(RunID, MapName, StatsGamemodeID, ClientID, TotalTime, PlayerCounter, GameDifficulty, CurrentMutation, mode);

							new bool:UsingV2 = MapRecords_BuildBestTimeQuery(query, sizeof(query), MapName, GameDifficulty, PlayerCounter, ClientID, RunID);
							if (!UsingV2)
							{
								if(mode > 0)
								{
									Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i AND players = %i ORDER BY time %s LIMIT 1", DbPrefix, MapName, StatsGamemodeID, GameDifficulty, CurrentMutation, ClientID, SICount, SISpawnTime, AnneVersion, mode, UseBuy, Auto, PlayerCounter, CurrentGamemodeID == GAMEMODE_SURVIVAL ? "DESC" : "ASC");
								}
								else
								{
									Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND mode = %i AND players = %i ORDER BY time %s LIMIT 1", DbPrefix, MapName, StatsGamemodeID, GameDifficulty, CurrentMutation, ClientID, mode, PlayerCounter, CurrentGamemodeID == GAMEMODE_SURVIVAL ? "DESC" : "ASC");
								}
							}

							dp = CreateDataPack();
							WritePackString(dp, MapName);
							WritePackCell(dp, StatsGamemodeID);
							WritePackString(dp, ClientID);
							WritePackFloat(dp, TotalTime);
							WritePackCell(dp, i);
							WritePackCell(dp, PlayerCounter);
							WritePackCell(dp, GameDifficulty);
							WritePackString(dp, CurrentMutation);
							WritePackCell(dp, mode);
							WritePackCell(dp, SICount);
							WritePackCell(dp, SISpawnTime);
							WritePackString(dp, AnneVersion);
							WritePackCell(dp, UseBuy);
							WritePackCell(dp, Auto);
							WritePackCell(dp, UsingV2 ? 1 : 0);
						SQL_TQuery(db, UpdateMapTimingStat, query, dp);
					}
				}
 			}
		}
	}

	ClearTrie(MapTimingSurvivors);
	return true;
}

GetThisModeBestTime(int UseBuy=0, const String:ExcludeRunID[]="")
{

	decl String:MapName[MAX_LINE_WIDTH], String:query[4096];

	GetCurrentMap(MapName, sizeof(MapName));

	new GameDifficulty = GetMapTimingDifficulty();
	new StatsGamemodeID = Stats_GetCurrentStatsGamemodeID();
	int mode = GetMapTimingMode();
	if (mode <= 0)
		mode = 1;
	if (!MapRecords_BuildBestTimeQuery(query, sizeof(query), MapName, GameDifficulty, GetConVarInt(cvar_SurvivorLimit), "", ExcludeRunID))
	{
		Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i AND players = %i ORDER BY time %s LIMIT 1",
			DbPrefix, MapName, StatsGamemodeID, GameDifficulty, CurrentMutation, GetAnneInfectedNumber(), GetAnneSISpawnTime(),
			GetAnneVersion(), mode, UseBuy, IsAutoSpawnTime(), GetConVarInt(cvar_SurvivorLimit), CurrentGamemodeID == GAMEMODE_SURVIVAL ? "DESC" : "ASC");
	}
	LogMessage("GetFastTimequery: %s", query);
	SQL_TQuery(db, GetFastTime, query);
}

MaybeAnnounceAnneNoBuyFastest(const String:MapName[], Float:TotalTime, PlayerCounter, GameDifficulty, Mode, const String:RunPlayers[], const String:RunID[])
{
	if (g_bMapTimingGlobalBroadcastSent || db == INVALID_HANDLE)
		return;

	new SISpawnTime = GetAnneSISpawnTime();
	if (!IsAnneTimingBroadcastMode(Mode) || (SISpawnTime != 0 && SISpawnTime != 16))
		return;

	if (g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY))
		return;

	new StatsGamemodeID = Stats_GetCurrentStatsGamemodeID();
	decl String:query[4096];
	if (!MapRecords_BuildBestTimeQuery(query, sizeof(query), MapName, GameDifficulty, PlayerCounter, "", RunID))
	{
		Format(query, sizeof(query), "SELECT time FROM %stimedmaps WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = 0 AND auto = %i AND players = %i ORDER BY time ASC LIMIT 1",
			DbPrefix, MapName, StatsGamemodeID, GameDifficulty, CurrentMutation, GetAnneInfectedNumber(), SISpawnTime, GetAnneVersion(), Mode, IsAutoSpawnTime(), PlayerCounter);
	}

	new Handle:dp = CreateDataPack();
	WritePackString(dp, MapName);
	WritePackFloat(dp, TotalTime);
	WritePackCell(dp, GameDifficulty);
	WritePackCell(dp, GetAnneInfectedNumber());
	WritePackCell(dp, SISpawnTime);
	WritePackCell(dp, Mode);
	WritePackString(dp, RunPlayers);
	WritePackString(dp, GetAnneVersion());

	SQL_TQuery(db, SQL_OnCheckAnneNoBuyFastest, query, dp);
}

public SQL_OnCheckAnneNoBuyFastest(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	ResetPack(dp);
	decl String:MapName[MAX_LINE_WIDTH], String:AnneVersion[64], String:RunPlayers[MAX_MESSAGE_WIDTH];
	new Float:TotalTime, GameDifficulty, InfectedNumber, SISpawnTime, Mode;
	ReadPackString(dp, MapName, sizeof(MapName));
	TotalTime = ReadPackFloat(dp);
	GameDifficulty = ReadPackCell(dp);
	InfectedNumber = ReadPackCell(dp);
	SISpawnTime = ReadPackCell(dp);
	Mode = ReadPackCell(dp);
	ReadPackString(dp, RunPlayers, sizeof(RunPlayers));
	ReadPackString(dp, AnneVersion, sizeof(AnneVersion));
	CloseHandle(dp);

	if (hndl == INVALID_HANDLE)
	{
		LogError("[l4d_stats] Anne fastest broadcast query failed: %s", error);
		return;
	}

	new bool:IsFastest = false;
	new Float:OldTime = -1.0;
	if (SQL_GetRowCount(hndl) > 0)
	{
		SQL_FetchRow(hndl);
		OldTime = SQL_FetchFloat(hndl, 0);
		IsFastest = TotalTime < OldTime;
	}
	else
	{
		IsFastest = true;
	}

	if (!IsFastest || g_bMapTimingGlobalBroadcastSent)
		return;

	g_bMapTimingGlobalBroadcastSent = true;

	decl String:TimeLabel[32];
	SetMapRecordTimeLabel(TotalTime, TimeLabel, sizeof(TimeLabel));

	if (GetFeatureStatus(FeatureType_Native, "GlobalChat_BroadcastMapRecord") == FeatureStatus_Available &&
			GlobalChat_BroadcastMapRecord(MapName, RunPlayers, Mode, InfectedNumber, SISpawnTime, GameDifficulty, TimeLabel))
		return;

	BroadcastMapRecordLocally(MapName, RunPlayers, Mode, InfectedNumber, SISpawnTime, GameDifficulty, TimeLabel);
}

BroadcastMapRecordLocally(const String:MapName[], const String:RunPlayers[], Mode, InfectedNumber, SISpawnTime, GameDifficulty, const String:TimeLabel[])
{
	decl String:ModePhrase[64], String:DifficultyPhrase[64];
	GetMapTimingModePhrase(Mode, ModePhrase, sizeof(ModePhrase));
	GetMapTimingDifficultyPhrase(GameDifficulty, DifficultyPhrase, sizeof(DifficultyPhrase));

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		decl String:ModeLabel[64], String:DifficultyLabel[64], String:Summary[256], String:Details[256];
		Format(ModeLabel, sizeof(ModeLabel), "%T", ModePhrase, i);
		Format(DifficultyLabel, sizeof(DifficultyLabel), "%T", DifficultyPhrase, i);
		Format(Summary, sizeof(Summary), "%T", "L4DStats_MapRecordSummary", i, TimeLabel, ModeLabel, MapName);
		Format(Details, sizeof(Details), "%T", "L4DStats_MapRecordDetails", i, RunPlayers, InfectedNumber, SISpawnTime, DifficultyLabel);

		StatsPrintToChatRaw(i, Summary);
		StatsPrintToChatRaw(i, Details);
	}
}

public GetFastTime(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("[l4d_stats] fastest map record query failed: %s", error);
		return;
	}

	new Mode = GetConVarInt(cvar_AnnounceMode);
	if (SQL_GetRowCount(hndl) > 0)
	{
		SQL_FetchRow(hndl);
		FastestTime = SQL_FetchFloat(hndl, 0);
		if (Mode)
		{
			new bool:UsedBuy = g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY);
			for (new i = 1; i <= MaxClients; i++)
			{
				if (!Stats_IsValidHumanClient(i))
					continue;

				decl String:TimeLabel[32];
				SetTimeLabel(FastestTime, TimeLabel, sizeof(TimeLabel), i);
				StatsPrintToChat(i, UsedBuy ? "L4DStats_FastestTimeWithBuy" : "L4DStats_FastestTimeWithoutBuy", TimeLabel);
			}
		}
	}
		else{
			if (Mode && !g_bMapTimingNoFastestPromptSent)
			{
				g_bMapTimingNoFastestPromptSent = true;
				StatsPrintToChatAll("L4DStats_NoFastestTimeYet");
			}
		}
}


public UpdateMapTimingStat(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	ResetPack(dp);

	decl String:MapName[MAX_LINE_WIDTH], String:ClientID[MAX_LINE_WIDTH], String:TimeLabel[32], String:Mutation[MAX_LINE_WIDTH], String:AnneVersion[64];
	new GamemodeID, Float:TotalTime, Float:OldTime, Client, PlayerCounter, GameDifficulty;
	ReadPackString(dp, MapName, sizeof(MapName));
	GamemodeID = ReadPackCell(dp);
	ReadPackString(dp, ClientID, sizeof(ClientID));
	TotalTime = ReadPackFloat(dp);
	Client = ReadPackCell(dp);
	PlayerCounter = ReadPackCell(dp);
	GameDifficulty = ReadPackCell(dp);
	ReadPackString(dp, Mutation, sizeof(Mutation));
	new mode = ReadPackCell(dp);
	new SICount = ReadPackCell(dp);
	new SISpawnTime = ReadPackCell(dp);
	ReadPackString(dp, AnneVersion, sizeof(AnneVersion));
	new UseBuy = ReadPackCell(dp);
	new Auto = ReadPackCell(dp);
	new bool:UsingV2 = ReadPackCell(dp) != 0;

	CloseHandle(dp);

	// Return if client is not a human player
	if (IsClientBot(Client) || !IsClientInGame(Client))
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);
	new bool:HasOldTime = false;
	new bool:Improved = false;
	if (hndl == INVALID_HANDLE)
	{
		LogError("[l4d_stats] %s map record comparison failed: %s", UsingV2 ? "v2" : "legacy", error);
	}
	else if (SQL_GetRowCount(hndl) > 0)
	{
		SQL_FetchRow(hndl);
		OldTime = SQL_FetchFloat(hndl, 0);
		HasOldTime = true;
		Improved = GamemodeID == GAMEMODE_SURVIVAL ? TotalTime > OldTime : TotalTime < OldTime;
	}
	else
	{
		Improved = true;
	}

	if (HasOldTime)
	{
		if(TotalTime < 30.0)
		{
			StatsPrintToChat(Client, "L4DStats_MapTimeTooShortNotRecorded");
			return;
		}

		if (!Improved)
		{
			if (Mode)
			{
					SetTimeLabel(OldTime, TimeLabel, sizeof(TimeLabel), Client);
				if(mode > 0)
				{
					StatsPrintToChat(Client, "L4DStats_MapRecordNotImprovedAnne", AnneVersion, TimeLabel);
				}
				else
				{
					StatsPrintToChat(Client, "L4DStats_MapRecordNotImproved", TimeLabel);
				}
			}
		}
		else
		{
			if (Mode)
			{
					SetTimeLabel(TotalTime, TimeLabel, sizeof(TimeLabel), Client);
					StatsPrintToChat(Client, FastestTime < TotalTime ? "L4DStats_MapRecordImprovedCurrent" : "L4DStats_MapRecordImprovedPlayer", AnneVersion, TimeLabel);

			}
			
			if (EnableSounds_Maptime_Improve && GetConVarBool(cvar_SoundsEnabled))
				EmitSoundToClient(Client, StatsSound_MapTime_Improve);
		}
	}
	else
	{
		if (Mode)
		{
				SetTimeLabel(TotalTime, TimeLabel, sizeof(TimeLabel), Client);
			StatsPrintToChat(Client, "L4DStats_MapCompletionTime", TimeLabel);
		}

	}

	FastestTime = -1.0;
	MapTiming_UpdateLegacyRecord(MapName, GamemodeID, ClientID, TotalTime, PlayerCounter, GameDifficulty, Mutation, mode, SICount, SISpawnTime, AnneVersion, UseBuy, Auto, Improved);
}

MapTiming_UpdateLegacyRecord(const String:MapName[], GamemodeID, const String:ClientID[], Float:TotalTime, PlayerCounter, GameDifficulty, const String:Mutation[], mode, SICount, SISpawnTime, const String:AnneVersion[], UseBuy, Auto, bool:Improved)
{
	decl String:EscMap[512], String:EscClientID[128], String:EscMutation[128], String:EscVersion[128];
	SQL_EscapeString(db, MapName, EscMap, sizeof(EscMap));
	SQL_EscapeString(db, ClientID, EscClientID, sizeof(EscClientID));
	SQL_EscapeString(db, Mutation, EscMutation, sizeof(EscMutation));
	SQL_EscapeString(db, AnneVersion, EscVersion, sizeof(EscVersion));

	decl String:SetValues[128], String:query[2048], String:insertQuery[2048];
	if (Improved)
		Format(SetValues, sizeof(SetValues), "plays = plays + 1, time = %f, players = %i, modified = NOW()", TotalTime, PlayerCounter);
	else
		strcopy(SetValues, sizeof(SetValues), "plays = plays + 1, modified = NOW()");

	if (mode > 0)
	{
		Format(query, sizeof(query),
			"UPDATE `%stimedmaps` SET %s WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND sinum = %i AND sitime = %i AND anneversion = '%s' AND mode = %i AND usebuy = %i AND auto = %i AND players = %i",
			DbPrefix, SetValues, EscMap, GamemodeID, GameDifficulty, EscMutation, EscClientID, SICount, SISpawnTime, EscVersion, mode, UseBuy, Auto, PlayerCounter);
		Format(insertQuery, sizeof(insertQuery),
			"INSERT IGNORE INTO `%stimedmaps` (map, gamemode, difficulty, mutation, steamid, plays, time, players, sinum, sitime, anneversion, mode, usebuy, auto, modified, created) VALUES ('%s', %i, %i, '%s', '%s', 1, %f, %i, %i, %i, '%s', %i, %i, %i, NOW(), NOW())",
			DbPrefix, EscMap, GamemodeID, GameDifficulty, EscMutation, EscClientID, TotalTime, PlayerCounter, SICount, SISpawnTime, EscVersion, mode, UseBuy, Auto);
	}
	else
	{
		Format(query, sizeof(query),
			"UPDATE `%stimedmaps` SET %s WHERE map = '%s' AND gamemode = %i AND difficulty = %i AND mutation = '%s' AND steamid = '%s' AND mode = %i AND players = %i",
			DbPrefix, SetValues, EscMap, GamemodeID, GameDifficulty, EscMutation, EscClientID, mode, PlayerCounter);
		Format(insertQuery, sizeof(insertQuery),
			"INSERT IGNORE INTO `%stimedmaps` (map, gamemode, difficulty, mutation, steamid, plays, time, players, mode, modified, created) VALUES ('%s', %i, %i, '%s', '%s', 1, %f, %i, %i, NOW(), NOW())",
			DbPrefix, EscMap, GamemodeID, GameDifficulty, EscMutation, EscClientID, TotalTime, PlayerCounter, mode);
	}

	new Handle:writePack = CreateDataPack();
	WritePackString(writePack, insertQuery);
	SQL_TQuery(db, SQL_OnLegacyMapTimingUpdated, query, writePack);
}

public SQL_OnLegacyMapTimingUpdated(Handle:owner, Handle:hndl, const String:error[], any:dp)
{
	ResetPack(dp);
	decl String:insertQuery[2048];
	ReadPackString(dp, insertQuery, sizeof(insertQuery));
	CloseHandle(dp);

	if (hndl == INVALID_HANDLE)
	{
		LogError("[l4d_stats] legacy timedmaps update failed: %s", error);
		return;
	}
	if (SQL_GetAffectedRows(hndl) == 0)
		SendSQLUpdate(insertQuery);
}

public SetTimeLabel(Float:TheSeconds, String:TimeLabel[], maxsize, Client)
{
	new FlooredSeconds = RoundToFloor(TheSeconds);
	new FlooredSecondsMod = FlooredSeconds % 60;
	new Float:Seconds = TheSeconds - float(FlooredSeconds) + float(FlooredSecondsMod);
	new Minutes = (TheSeconds < 60.0 ? 0 : RoundToNearest(float(FlooredSeconds - FlooredSecondsMod) / 60));
	new MinutesMod = Minutes % 60;
	new Hours = (Minutes < 60 ? 0 : RoundToNearest(float(Minutes - MinutesMod) / 60));
	Minutes = MinutesMod;

	if (Hours > 0)
		StatsFormatPhrase(Client, TimeLabel, maxsize, "L4DStats_TimeHoursMinutesSeconds", Hours, Minutes, Seconds);
	else if (Minutes > 0)
		StatsFormatPhrase(Client, TimeLabel, maxsize, "L4DStats_TimeMinutesSeconds", Minutes, Seconds);
	else
		StatsFormatPhrase(Client, TimeLabel, maxsize, "L4DStats_TimeSeconds", Seconds);
}

SetMapRecordTimeLabel(Float:TheSeconds, String:TimeLabel[], maxsize)
{
	new TotalTenths = RoundToNearest(TheSeconds * 10.0);
	new TotalSeconds = TotalTenths / 10;
	new Tenths = TotalTenths % 10;
	new Minutes = TotalSeconds / 60;
	new Seconds = TotalSeconds % 60;
	new Hours = Minutes / 60;
	Minutes %= 60;

	if (Hours > 0)
		Format(TimeLabel, maxsize, "%i:%02i:%02i.%i", Hours, Minutes, Seconds, Tenths);
	else
		Format(TimeLabel, maxsize, "%02i:%02i.%i", Minutes, Seconds, Tenths);
}

public DisplayRankVote(client)
{
	DisplayYesNoPanel(client, RANKVOTE_QUESTION, RankVotePanelHandler, RoundToNearest(GetConVarFloat(cvar_RankVoteTime)));
}

// Initialize RANKVOTE
public InitializeRankVote(client)
{
	if (StatsDisabled())
	{
		if (client == 0)
		{
				StatsPrintToConsolePhrase(0, "L4DStats_RankVotePluginDisabledConsole");
		}
		else
		{
			StatsPrintToChatPreFormatted2(client, true, "L4DStats_RankVotePluginDisabledChat");
		}

		return;
	}

	// No TEAM gamemodes are allowed
	if (!IsTeamGamemode())
	{
		if (client == 0)
		{
				StatsPrintToConsolePhrase(0, "L4DStats_RankVoteGamemodeDisabledConsole");
		}
		else
		{
			if (EngineVersion1 == Engine_Left4Dead)
			{
				StatsPrintToChatPreFormatted2(client, true, "L4DStats_RankVoteVersusOnly");
			}
			else
			{
				StatsPrintToChatPreFormatted2(client, true, "L4DStats_RankVoteCompetitiveModes");
			}
		}

		return;
	}

	if (RankVoteTimer != INVALID_HANDLE)
	{
		if (client > 0)
		{
			DisplayRankVote(client);
		}
		else
		{
				StatsPrintToConsolePhrase(client, "L4DStats_RankVoteAlreadyStartedConsole");
		}

		return;
	}

	new bool:IsAdmin = (client > 0 ? ((GetUserFlagBits(client) & ADMFLAG_GENERIC) == ADMFLAG_GENERIC) : true);

	new team;
	decl String:ClientID[MAX_LINE_WIDTH];

	if (!IsAdmin && client > 0 && GetTrieValue(PlayerRankVoteTrie, ClientID, team))
	{
		StatsPrintToChatPreFormatted2(client, true, "L4DStats_RankVoteOncePerMap");
		return;
	}

	if (!IsAdmin && client > 0)
	{
		GetClientRankAuthString(client, ClientID, sizeof(ClientID));
		SetTrieValue(PlayerRankVoteTrie, ClientID, 1, true);
	}

	RankVoteTimer = CreateTimer(GetConVarFloat(cvar_RankVoteTime), timer_RankVote);

	new i;

	for (i = 0; i <= MAXPLAYERS; i++)
	{
		PlayerRankVote[i] = RANKVOTE_NOVOTE;
	}

	new maxplayers = MaxClients;

	for (i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			team = GetClientTeam(i);

			if (team == TEAM_SURVIVORS || team == TEAM_INFECTED)
			{
				DisplayRankVote(i);
			}
		}
	}

	if (client > 0)
	{
		decl String:UserName[MAX_LINE_WIDTH];
		GetClientName(client, UserName, sizeof(UserName));

		StatsPrintToChatAll2(true, "L4DStats_RankVoteInitiated", UserName);
	}
	else
	{
		StatsPrintToChatAllPreFormatted2(true, "L4DStats_RankVoteInitiatedConsole");
	}
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock bool:ChangeRankPlayerTeam(client, team)
{
	if(GetClientTeam(client) == team) return true;

	if(team != TEAM_SURVIVORS)
	{
		//we can always swap to infected or spectator, it has no actual limit
		ChangeClientTeam(client, team);
		return true;
	}

	if(GetRankTeamHumanCount(team) == GetRankTeamMaxHumans(team))
		return false;

	new bot;
	//for survivors its more tricky
	for (bot = 1; bot < MaxClients + 1 && (!IsClientConnected(bot) || !IsFakeClient(bot) || (GetClientTeam(bot) != TEAM_SURVIVORS)); bot++) {}

	if (bot == MaxClients + 1)
	{
		new String:command[] = "sb_add";
		new flags = GetCommandFlags(command);
		SetCommandFlags(command, flags & ~FCVAR_CHEAT);

		ServerCommand("sb_add");

		SetCommandFlags(command, flags);

		return false;
	}

	//have to do this to give control of a survivor bot
	SDKCall(L4DStatsSHS, bot, client);
	SDKCall(L4DStatsTOB, client, true);

	return true;
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock bool:IsRankClientInGameHuman(client)
{
	if (client > 0) return IsClientInGame(client) && !IsFakeClient(client);
	else return false;
}

/*
	From plugin:
		name = "L4D2 Score/Team Manager",
		author = "Downtown1 & AtomicStryker",
		description = "Manage teams and scores in L4D2",
		version = 1.1.2,
		url = "http://forums.alliedmods.net/showthread.php?p=1029519"
*/

stock GetRankTeamHumanCount(team)
{
	new humans = 0;
	
	for(new i = 1; i < MaxClients + 1; i++)
	{
		if(IsRankClientInGameHuman(i) && GetClientTeam(i) == team)
		{
			humans++;
		}
	}
	
	return humans;
}

stock GetRankTeamMaxHumans(team)
{
	switch (team)
	{
		case TEAM_SURVIVORS:
			return GetConVarInt(cvar_SurvivorLimit);
		case TEAM_INFECTED:
			return GetConVarInt(cvar_InfectedLimit);
		case TEAM_SPECTATORS:
			return MaxClients;
	}
	
	return -1;
}

stock bool:Stats_IsInvalidRankAuthString(const String:auth[])
{
	return auth[0] == '\0' || StrEqual(auth, "STEAM_ID_STOP_IGNORING_RETVALS", false);
}

bool:GetClientRankAuthString(client, String:auth[], maxlength)
{
	if (maxlength > 0)
		auth[0] = '\0';

	if (client <= 0 || client > MaxClients || !IsClientConnected(client))
		return false;

	if (GetConVarInt(cvar_Lan))
	{
		if (!GetClientAuthId(client, AuthId_Engine, auth, maxlength))
			return false;

		if (!StrEqual(auth, "BOT", false))
		{
			if (!GetClientIP(client, auth, maxlength))
				return false;
		}
	}
	else
	{
		if (!GetClientAuthId(client, AuthId_Engine, auth, maxlength))
			return false;

		if (StrEqual(auth, "STEAM_ID_LAN", false))
		{
			if (!GetClientIP(client, auth, maxlength))
				return false;
		}
	}

	return !Stats_IsInvalidRankAuthString(auth);
}

public StatsPrintToChatAll(const String:Message[], any:...)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		new String:FormattedMessage[MAX_MESSAGE_WIDTH];
		SetGlobalTransTarget(i);
		VFormat(FormattedMessage, sizeof(FormattedMessage), "%t", 1);
		StatsPrintToChatRaw(i, FormattedMessage);
	}
}

public StatsPrintToChatAll2(bool:Forced, const String:Message[], any:...)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		new String:FormattedMessage[MAX_MESSAGE_WIDTH];
		SetGlobalTransTarget(i);
		VFormat(FormattedMessage, sizeof(FormattedMessage), "%t", 2);
		StatsPrintToChatRaw2(i, Forced, FormattedMessage);
	}
}

public StatsPrintToChatAllPreFormatted(const String:Message[])
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		StatsPrintToChatPreFormatted(i, Message);
	}
}

public StatsPrintToChatAllPreFormatted2(bool:Forced, const String:Message[])
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
			continue;

		StatsPrintToChatPreFormatted2(i, Forced, Message);
	}
}

public StatsPrintToChat(Client, const String:Message[], any:...)
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (ClientRankMute[Client])
	{
		return;
	}

	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(FormattedMessage, sizeof(FormattedMessage), "%t", 2);

	StatsPrintToChatRaw(Client, FormattedMessage);
}

public StatsPrintToChat2(Client, bool:Forced, const String:Message[], any:...)
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (!Forced && ClientRankMute[Client])
	{
		return;
	}

	new String:FormattedMessage[MAX_MESSAGE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(FormattedMessage, sizeof(FormattedMessage), "%t", 3);

	StatsPrintToChatRaw2(Client, Forced, FormattedMessage);
}

public StatsPrintToChatPreFormatted(Client, const String:Message[])
{
	StatsPrintToChatPreFormatted2(Client, false, Message);
}

public StatsPrintToChatPreFormatted2(Client, bool:Forced, const String:Message[])
{
	// CHECK IF CLIENT HAS MUTED THE PLUGIN
	if (!Forced && ClientRankMute[Client])
	{
		return;
	}

	decl String:FormattedMessage[MAX_MESSAGE_WIDTH];
	Format(FormattedMessage, sizeof(FormattedMessage), "%T", Message, Client);
	StatsPrintToChatRaw2(Client, Forced, FormattedMessage);
}

public StatsPrintToChatRaw(Client, const String:Message[])
{
	StatsPrintToChatRaw2(Client, false, Message);
}

public StatsPrintToChatRaw2(Client, bool:Forced, const String:Message[])
{
	if (!Forced && ClientRankMute[Client])
		return;

	CPrintToChat(Client, "%T", "L4DStats_RankMessage", Client, Message);
}

stock StatsFormatPhrase(Client, String:Buffer[], MaxLength, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	SetGlobalTransTarget(Client);
	VFormat(Buffer, MaxLength, "%t", 4);
}

stock StatsPrintToConsolePhrase(Client, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	decl String:Message[1024];
	SetGlobalTransTarget(Client > 0 ? Client : LANG_SERVER);
	VFormat(Message, sizeof(Message), "%t", 2);
	PrintToConsole(Client, "[RANK] %s", Message);
}

stock StatsSetMenuTitle(Handle:MenuHandle, Client, const String:Phrase[])
{
	decl String:Text[MAX_LINE_WIDTH];
	StatsFormatPhrase(Client, Text, sizeof(Text), Phrase);
	SetMenuTitle(MenuHandle, Text);
}

stock StatsAddMenuItem(Handle:MenuHandle, const String:Info[], Client, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	decl String:Text[MAX_LINE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(Text, sizeof(Text), "%t", 4);
	AddMenuItem(MenuHandle, Info, Text);
}

stock StatsSetPanelTitle(Handle:PanelHandle, Client, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	decl String:Text[MAX_LINE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(Text, sizeof(Text), "%t", 3);
	SetPanelTitle(PanelHandle, Text);
}

stock StatsDrawPanelText(Handle:PanelHandle, Client, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	decl String:Text[MAX_LINE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(Text, sizeof(Text), "%t", 3);
	DrawPanelText(PanelHandle, Text);
}

stock StatsDrawPanelItem(Handle:PanelHandle, Client, const String:Phrase[], any:...)
{
	#pragma unused Phrase
	decl String:Text[MAX_LINE_WIDTH];
	SetGlobalTransTarget(Client);
	VFormat(Text, sizeof(Text), "%t", 3);
	DrawPanelItem(PanelHandle, Text);
}

stock StatsGetClientTeam(client)
{
	if (client <= 0 || !IsClientConnected(client))
	{
		return TEAM_UNDEFINED;
	}

	if (IsFakeClient(client) || IsClientInGame(client))
	{
		return GetClientTeam(client);
	}

	return TEAM_UNDEFINED;
}

bool:UpdateServerSettings(Client, const String:Key[], const String:Value[])
{
	new Handle:statement = INVALID_HANDLE;
	decl String:error[1024], String:query[2048];

	// Add a row if it does not previously exist
	if (!DoFastQuery(Client, "INSERT IGNORE INTO %sserver_settings SET sname = '%s', svalue = ''", DbPrefix, Key))
	{
		StatsPrintToConsolePhrase(Client, "L4DStats_MotdCreateFailed");
		return false;
	}

	Format(query, sizeof(query), "UPDATE %sserver_settings SET svalue = ? WHERE sname = '%s'", DbPrefix, Key);

	statement = SQL_PrepareQuery(db, query, error, sizeof(error));

	if (statement == INVALID_HANDLE)
	{
		StatsPrintToConsolePhrase(Client, "L4DStats_MotdPrepareFailed");
		return false;
	}

	new bool:retval = true;
	SQL_BindParamString(statement, 0, Value, false);

	if (!SQL_Execute(statement))
	{
		if (SQL_GetError(db, error, sizeof(error)))
		{
			StatsPrintToConsolePhrase(Client, "L4DStats_MotdUpdateError", error);
			LogError("MOTD update failed! (Error = \"%s\")", error);
		}
		else
		{
			StatsPrintToConsolePhrase(Client, "L4DStats_MotdUpdateFailed");
			LogError("MOTD update failed!");
		}
		
		retval = false;
	}
	else
	{
		StatsPrintToConsolePhrase(Client, "L4DStats_MotdUpdateSuccess");

		if (StrEqual(Key, "motdmessage", false))
		{
			strcopy(MessageOfTheDay, sizeof(MessageOfTheDay), Value);
			ShowMOTDAll();
		}
	}

	CloseHandle(statement);
	
	return retval;
}

ShowMOTDAll()
{
	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			ShowMOTD(i);
		}
	}
}

ShowMOTD(client, bool:forced=false)
{
	if (!forced && !GetConVarBool(cvar_AnnounceMotd))
	{
		return;
	}

	StatsPrintToChat2(client, forced, "L4DStats_MotdMessage", MessageOfTheDay);
}

AnnouncePlayerConnect(client)
{
	if (!GetConVarBool(cvar_AnnouncePlayerJoined))
	{
		return;
	}

	DoShowPlayerJoined(client);
}

ReadDb()
{
	ReadDbMotd();
}

ReadDbMotd()
{
	if (db == INVALID_HANDLE)
		return;

	decl String:query[512];
	Format(query, sizeof(query), "SELECT svalue FROM %sserver_settings WHERE sname = 'motdmessage' LIMIT 1", DbPrefix);
	SQL_TQuery(db, ReadDbMotdCallback, query);
}

public ReadDbMotdCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("ReadDbMotdCallback Query failed: %s", error);
		return;
	}

	if (SQL_FetchRow(hndl))
	{
		SQL_FetchString(hndl, 0, MessageOfTheDay, sizeof(MessageOfTheDay));
	}
}

stock bool IsGaoJiRenJiEnabled()
{
	ConVar gjrj = FindConVar("sb_fix_enabled");
	if(gjrj == null)
	{
		return false;
	}
	else if(gjrj.BoolValue)
	{
		return true;
	}
	return false;
}

stock bool IsNormalMode()
{
	ConVar cvar = FindConVar("l4d_infected_limit");
	if(cvar == null) return true;
	return false;
}

stock int IsAutoSpawnTime()
{
	ConVar cvar = FindConVar("inf_EnableAutoSpawnTime");
	if(cvar == null) return false;
	return cvar.IntValue;
}

stock bool IsThisRoundValid()
{
	ConVar tank_bhop = FindConVar("ai_Tank_Bhop");
	if(tank_bhop == null)
		return true;
	if(AnneMultiPlayerMode())
	{
		return tank_bhop.BoolValue;
	}
	return true;
}

stock bool CheckIsOfficalMap(){
	char mapname[256];
	GetCurrentMap(mapname,sizeof(mapname));
	if(( (mapname[0]=='c') && (mapname[2]=='m') &&(mapname[4]=='_'))||((mapname[0]=='c')&&(mapname[3]=='m')&&(mapname[5]=='_')))
		return true;
	return false;
}
