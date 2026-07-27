#if defined _l4d_stats_map_records_included
	#endinput
#endif
#define _l4d_stats_map_records_included

// Normalized map-run persistence shared by every server ruleset.

#define MAP_RECORD_POLICY_AUTO -1
#define MAP_RECORD_POLICY_OFF 0
#define MAP_RECORD_POLICY_HISTORY 1
#define MAP_RECORD_POLICY_LEADERBOARD 2

stock MapRecords_GetPolicy()
{
	new Policy = GetConVarInt(cvar_MapRecordPolicy);
	if (Policy >= MAP_RECORD_POLICY_OFF && Policy <= MAP_RECORD_POLICY_LEADERBOARD)
		return Policy;

	if (IsAnne() || IsAnneShotgunMode() || IsWitchParty() || IsAllCharger() || IsAlone() || Is1vht())
		return MAP_RECORD_POLICY_LEADERBOARD;

	new GamemodeID = CurrentGamemodeID;
	if (GamemodeID == GAMEMODE_VERSUS || GamemodeID == GAMEMODE_SCAVENGE || GamemodeID == GAMEMODE_REALISMVERSUS)
		return MAP_RECORD_POLICY_HISTORY;

	return MAP_RECORD_POLICY_LEADERBOARD;
}

stock MapRecords_GetRuleset(String:Ruleset[], MaxLength)
{
	GetConVarString(cvar_MapRecordRuleset, Ruleset, MaxLength);
	TrimString(Ruleset);
	if (Ruleset[0] != '\0')
		return;

	if (IsAnneShotgunMode())
		strcopy(Ruleset, MaxLength, "anne_shotgun");
	else if (IsAnne() == 2)
		strcopy(Ruleset, MaxLength, "anne_hardcore");
	else if (IsAnne() == 1)
		strcopy(Ruleset, MaxLength, "annehappy");
	else if (IsWitchParty())
		strcopy(Ruleset, MaxLength, "witchparty");
	else if (IsAllCharger())
		strcopy(Ruleset, MaxLength, "allcharger");
	else if (IsAlone())
		strcopy(Ruleset, MaxLength, "alone");
	else if (Is1vht())
		strcopy(Ruleset, MaxLength, "hunters");
	else
	{
		decl String:ReadyName[128];
		ReadyName[0] = '\0';
		if (cvar_mode != null)
			GetConVarString(cvar_mode, ReadyName, sizeof(ReadyName));
		MapRecords_NormalizeRuleset(ReadyName, Ruleset, MaxLength);
		if (Ruleset[0] == '\0' && CurrentGamemode[0] != '\0')
			Format(Ruleset, MaxLength, "default_%s", CurrentGamemode);
		if (Ruleset[0] == '\0')
			strcopy(Ruleset, MaxLength, "default_unknown");
	}
}

stock MapRecords_NormalizeRuleset(const String:ReadyName[], String:Ruleset[], MaxLength)
{
	Ruleset[0] = '\0';
	if (ReadyName[0] == '\0')
		return;

	decl String:Tokens[16][32], String:Base[128];
	Base[0] = '\0';
	new TokenCount = ExplodeString(ReadyName, " ", Tokens, sizeof(Tokens), sizeof(Tokens[]));
	for (new Token = 0; Token < TokenCount; Token++)
	{
		new First = Tokens[Token][0];
		new Second = Tokens[Token][1];
		new bool:StartsVersion = (First == 'v' || First == 'V') && Second >= '0' && Second <= '9';
		new bool:NumericVersion = First >= '0' && First <= '9' && StrContains(Tokens[Token], ".", false) != -1;
		if (StartsVersion || NumericVersion)
			break;

		if (Base[0] != '\0')
			StrCat(Base, sizeof(Base), "_");
		StrCat(Base, sizeof(Base), Tokens[Token]);
	}

	new Out = 0;
	new bool:LastSeparator = true;
	for (new Pos = 0; Base[Pos] != '\0' && Out < MaxLength - 1; Pos++)
	{
		new Character = Base[Pos];
		new bool:IsAlpha = (Character >= 'a' && Character <= 'z') || (Character >= 'A' && Character <= 'Z');
		new bool:IsNumber = Character >= '0' && Character <= '9';
		if (IsAlpha || IsNumber)
		{
			Ruleset[Out++] = CharToLower(Character);
			LastSeparator = false;
		}
		else if (!LastSeparator)
		{
			Ruleset[Out++] = '_';
			LastSeparator = true;
		}
	}

	if (Out > 0 && Ruleset[Out - 1] == '_')
		Out--;
	Ruleset[Out] = '\0';
}

stock MapRecords_GetRulesetVersion(String:Version[], MaxLength)
{
	GetConVarString(cvar_MapRecordRulesetVersion, Version, MaxLength);
	TrimString(Version);
	if (Version[0] != '\0')
		return;

	if (IsAnne() || IsAnneShotgunMode())
	{
		strcopy(Version, MaxLength, GetAnneVersion());
		return;
	}

	if (cvar_mode != null)
	{
		GetConVarString(cvar_mode, Version, MaxLength);
		TrimString(Version);
	}

	if (Version[0] == '\0')
		strcopy(Version, MaxLength, PLUGIN_VERSION);
}

stock MapRecords_GetTimingProfile(String:Profile[], MaxLength)
{
	GetConVarString(cvar_MapRecordTimingProfile, Profile, MaxLength);
	TrimString(Profile);
	if (Profile[0] != '\0')
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL)
		strcopy(Profile, MaxLength, "survival");
	else if (MapRecords_GetPolicy() == MAP_RECORD_POLICY_HISTORY)
		strcopy(Profile, MaxLength, "round_history");
	else
		strcopy(Profile, MaxLength, "completion");
}

stock MapRecords_GetDifficultyProfile(String:Profile[], MaxLength)
{
	GetConVarString(cvar_MapRecordDifficultyProfile, Profile, MaxLength);
	TrimString(Profile);
	if (Profile[0] != '\0')
		return;

	if (IsAnne() || IsAnneShotgunMode() || IsWitchParty() || IsAllCharger() || IsAlone() || Is1vht())
		strcopy(Profile, MaxLength, "anne_ai");
	else if (MapRecords_GetPolicy() == MAP_RECORD_POLICY_HISTORY)
		strcopy(Profile, MaxLength, "none");
	else
		strcopy(Profile, MaxLength, "game");
}

stock bool:MapRecords_CheckSchema()
{
	if (db == INVALID_HANDLE)
		return false;

	decl String:Query[512], String:Error[256], String:EscTable[128], String:Table[128];
	Format(Table, sizeof(Table), "%smap_runs", DbPrefix);
	SQL_EscapeString(db, Table, EscTable, sizeof(EscTable));
	Format(Query, sizeof(Query), "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '%s' LIMIT 1", EscTable);
	new Handle:Runs = SQL_Query(db, Query);
	if (Runs == INVALID_HANDLE)
	{
		SQL_GetError(db, Error, sizeof(Error));
		LogError("MapRecords schema check failed for map_runs: %s", Error);
		return false;
	}
	new bool:HasRuns = SQL_GetRowCount(Runs) > 0;
	CloseHandle(Runs);

	Format(Table, sizeof(Table), "%smap_run_players", DbPrefix);
	SQL_EscapeString(db, Table, EscTable, sizeof(EscTable));
	Format(Query, sizeof(Query), "SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '%s' LIMIT 1", EscTable);
	new Handle:Players = SQL_Query(db, Query);
	if (Players == INVALID_HANDLE)
	{
		SQL_GetError(db, Error, sizeof(Error));
		LogError("MapRecords schema check failed for map_run_players: %s", Error);
		return false;
	}
	new bool:HasPlayers = SQL_GetRowCount(Players) > 0;
	CloseHandle(Players);

	if (!HasRuns || !HasPlayers)
		LogError("Map record v2 tables are missing. Run the 20260726 map record migration; legacy timing remains available.");

	return HasRuns && HasPlayers;
}

stock MapRecords_RecordRun(const String:RunID[], const String:MapName[], GamemodeID, Float:TotalTime, SurvivorCount, InfectedCount, Difficulty, LegacyMode, bool:Completed)
{
	if (!g_bMapRecordsTablesReady || MapRecords_GetPolicy() == MAP_RECORD_POLICY_OFF)
		return;

	decl String:Ruleset[MAX_LINE_WIDTH], String:Version[MAX_LINE_WIDTH], String:TimingProfile[24], String:DifficultyProfile[16];
	decl String:Mutation[MAX_LINE_WIDTH], String:ServerName[128];
	MapRecords_GetRuleset(Ruleset, sizeof(Ruleset));
	MapRecords_GetRulesetVersion(Version, sizeof(Version));
	MapRecords_GetTimingProfile(TimingProfile, sizeof(TimingProfile));
	MapRecords_GetDifficultyProfile(DifficultyProfile, sizeof(DifficultyProfile));
	strcopy(Mutation, sizeof(Mutation), CurrentMutation);
	GetConVarString(cvar_Hostname, ServerName, sizeof(ServerName));

	decl String:EscRunID[128], String:EscMap[512], String:EscRuleset[128], String:EscVersion[128];
	decl String:EscTiming[64], String:EscDifficulty[64], String:EscMutation[128], String:EscServer[256];
	SQL_EscapeString(db, RunID, EscRunID, sizeof(EscRunID));
	SQL_EscapeString(db, MapName, EscMap, sizeof(EscMap));
	SQL_EscapeString(db, Ruleset, EscRuleset, sizeof(EscRuleset));
	SQL_EscapeString(db, Version, EscVersion, sizeof(EscVersion));
	SQL_EscapeString(db, TimingProfile, EscTiming, sizeof(EscTiming));
	SQL_EscapeString(db, DifficultyProfile, EscDifficulty, sizeof(EscDifficulty));
	SQL_EscapeString(db, Mutation, EscMutation, sizeof(EscMutation));
	SQL_EscapeString(db, ServerName, EscServer, sizeof(EscServer));

	new DurationMs = RoundToNearest(TotalTime * 1000.0);
	new UseBuy = g_brpgAvailable && L4D_RPG_GetGlobalValue(INDEX_USEBUY);
	decl String:Query[2048];
	Format(Query, sizeof(Query),
		"INSERT IGNORE INTO `%smap_runs` "
		... "(`run_id`,`map`,`gamemode`,`mutation`,`ruleset_key`,`ruleset_version`,`record_policy`,`timing_profile`,`difficulty_type`,`difficulty`,`duration_ms`,`survivor_count`,`infected_count`,`si_count`,`si_spawn_time`,`usebuy`,`auto`,`legacy_mode`,`completed`,`valid`,`server_name`,`source`,`created`,`modified`) "
		... "VALUES ('%s','%s',%i,'%s','%s','%s',%i,'%s','%s',%i,%i,%i,%i,%i,%i,%i,%i,%i,%i,1,'%s','native',NOW(),NOW())",
		DbPrefix, EscRunID, EscMap, GamemodeID, EscMutation, EscRuleset, EscVersion, MapRecords_GetPolicy(), EscTiming, EscDifficulty,
		Difficulty, DurationMs, SurvivorCount, InfectedCount, GetAnneInfectedNumber(), GetAnneSISpawnTime(), UseBuy, IsAutoSpawnTime(), LegacyMode, Completed ? 1 : 0, EscServer);
	SendSQLUpdate(Query);

	MapRecords_RecordParticipants(EscRunID, Completed);
}

stock MapRecords_RecordParticipants(const String:EscRunID[], bool:Completed)
{
	MapRecords_RecordParticipantTrie(MapTimingSurvivors, EscRunID, TEAM_SURVIVORS, Completed);
	MapRecords_RecordParticipantTrie(MapTimingInfected, EscRunID, TEAM_INFECTED, Completed);
}

stock MapRecords_RecordParticipantTrie(Handle:Participants, const String:EscRunID[], Team, bool:Completed)
{
	new Handle:Snapshot = CreateTrieSnapshot(Participants);
	if (Snapshot == INVALID_HANDLE)
		return;

	decl String:ClientID[MAX_LINE_WIDTH], String:EscClientID[128], String:Query[512];
	new Enabled;
	new Count = TrieSnapshotLength(Snapshot);
	for (new Index = 0; Index < Count; Index++)
	{
		GetTrieSnapshotKey(Snapshot, Index, ClientID, sizeof(ClientID));
		if (!GetTrieValue(Participants, ClientID, Enabled) || !Enabled)
			continue;

		SQL_EscapeString(db, ClientID, EscClientID, sizeof(EscClientID));
		Format(Query, sizeof(Query),
			"INSERT IGNORE INTO `%smap_run_players` (`run_id`,`steamid`,`team`,`completed`,`created`) VALUES ('%s','%s',%i,%i,NOW())",
			DbPrefix, EscRunID, EscClientID, Team, Completed ? 1 : 0);
		SendSQLUpdate(Query);
	}
	CloseHandle(Snapshot);
}
