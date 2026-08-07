#if defined _l4d_stats_score_included
	#endinput
#endif
#define _l4d_stats_score_included

stock bool:Stats_IsAnneStatsMode()
{
	decl String:plugin_name[MAX_LINE_WIDTH];
	if (cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}

	if (cvar_mode == null)
		return false;

	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	return StrContains(plugin_name, "AnneHappy", false) != -1
		|| StrContains(plugin_name, "WitchParty", false) != -1
		|| StrContains(plugin_name, "AllCharger", false) != -1
		|| StrContains(plugin_name, "Alone", false) != -1
		|| StrContains(plugin_name, "1vHunters", false) != -1;
}

// Anne 系可以运行在 versus 底座上，但积分和记录仍归入战役桶。
stock Stats_GetCurrentStatsGamemodeID()
{
	if (Stats_IsAnneStatsMode() &&
			(CurrentGamemodeID == GAMEMODE_VERSUS || CurrentGamemodeID == GAMEMODE_REALISMVERSUS))
	{
		return GAMEMODE_COOP;
	}

	return CurrentGamemodeID;
}

stock Stats_GetPointsColumnForModeAndTeam(Mode, ClientTeam, String:UpdatePoints[], MaxLength)
{
	switch (Mode)
	{
		case GAMEMODE_VERSUS:
		{
			if (ClientTeam == TEAM_INFECTED)
				Format(UpdatePoints, MaxLength, "points_infected");
			else
				Format(UpdatePoints, MaxLength, "points_survivors");
		}
		case GAMEMODE_REALISM:
		{
			Format(UpdatePoints, MaxLength, "points_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(UpdatePoints, MaxLength, "points_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			if (ClientTeam == TEAM_INFECTED)
				Format(UpdatePoints, MaxLength, "points_scavenge_infected");
			else
				Format(UpdatePoints, MaxLength, "points_scavenge_survivors");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			if (ClientTeam == TEAM_INFECTED)
				Format(UpdatePoints, MaxLength, "points_realism_infected");
			else
				Format(UpdatePoints, MaxLength, "points_realism_survivors");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(UpdatePoints, MaxLength, "points_mutations");
		}
		default:
		{
			Format(UpdatePoints, MaxLength, "points");
		}
	}
}

// 根据当前统计模式和玩家队伍选择 players 表里的积分列。
// 新增奖励时优先走这个函数，避免每个事件都复制一份 switch。
stock Stats_GetPointsColumnForTeam(ClientTeam, String:UpdatePoints[], MaxLength)
{
	Stats_GetPointsColumnForModeAndTeam(Stats_GetCurrentStatsGamemodeID(), ClientTeam, UpdatePoints, MaxLength);
}

stock Stats_GetMapPointsFieldForTeam(ClientTeam, String:Field[], MaxLength)
{
	new Mode = Stats_GetCurrentStatsGamemodeID();
	if (ClientTeam == TEAM_INFECTED &&
			(Mode == GAMEMODE_VERSUS || Mode == GAMEMODE_SCAVENGE || Mode == GAMEMODE_REALISMVERSUS))
	{
		Format(Field, MaxLength, "points_infected");
		return;
	}

	Format(Field, MaxLength, "points");
}

stock Stats_GetPlaytimeColumnForMode(Mode, String:Playtime[], MaxLength)
{
	switch (Mode)
	{
		case GAMEMODE_VERSUS:
		{
			Format(Playtime, MaxLength, "playtime_versus");
		}
		case GAMEMODE_REALISM:
		{
			Format(Playtime, MaxLength, "playtime_realism");
		}
		case GAMEMODE_SURVIVAL:
		{
			Format(Playtime, MaxLength, "playtime_survival");
		}
		case GAMEMODE_SCAVENGE:
		{
			Format(Playtime, MaxLength, "playtime_scavenge");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			Format(Playtime, MaxLength, "playtime_realismversus");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			Format(Playtime, MaxLength, "playtime_mutations");
		}
		default:
		{
			Format(Playtime, MaxLength, "playtime");
		}
	}
}

stock Stats_ResolveScoreTeam(Client, ScoreTeam)
{
	if (ScoreTeam == TEAM_SURVIVORS || ScoreTeam == TEAM_INFECTED)
		return ScoreTeam;

	return GetClientTeam(Client);
}

// 唯一的 players 积分 SQL 写入点。ExtraSet 只追加同一行的计数器更新。
stock bool:Stats_WriteScoreIdentity(const String:SteamID[], Score, const String:ExtraSet[], ScoreTeam)
{
	if (db == INVALID_HANDLE || StatsDisabled() || Stats_IsInvalidRankAuthString(SteamID))
		return false;

	if (Score == 0 && ExtraSet[0] == '\0')
		return false;

	if (ScoreTeam != TEAM_SURVIVORS && ScoreTeam != TEAM_INFECTED)
		return false;

	decl String:EscSteamID[MAX_LINE_WIDTH * 2 + 1];
	SQL_EscapeString(db, SteamID, EscSteamID, sizeof(EscSteamID));

	decl String:UpdatePoints[32];
	Stats_GetPointsColumnForTeam(ScoreTeam, UpdatePoints, sizeof(UpdatePoints));

	decl String:query[1024];
	Format(query, sizeof(query), "UPDATE %splayers SET %s = %s + %i%s WHERE steamid = '%s'", DbPrefix, UpdatePoints, UpdatePoints, Score, ExtraSet, EscSteamID);
	SendSQLUpdate(query);
	return true;
}

stock bool:Stats_WriteClientScore(Client, Score, const String:ExtraSet[], ScoreTeam)
{
	if (!Stats_IsValidHumanClient(Client))
		return false;

	decl String:ClientID[MAX_LINE_WIDTH];
	if (!GetClientRankAuthString(Client, ClientID, sizeof(ClientID)))
		return false;

	return Stats_WriteScoreIdentity(ClientID, Score, ExtraSet, Stats_ResolveScoreTeam(Client, ScoreTeam));
}

// 同一积分变动在一个入口内同步总表、地图缓存、流水、季度榜和模式榜。
stock bool:Stats_ApplyClientScore(Client, Score, const String:Reason[], const String:Formula[], const String:ExtraSet[] = "", bool:UpdateMapPoints = true, ScoreTeam = 0)
{
	if (!Stats_WriteClientScore(Client, Score, ExtraSet, ScoreTeam))
		return false;

	if (UpdateMapPoints && Score > 0)
		UpdateMapStat("points", Score);

	if (Score != 0)
		AddScore(Client, Score, Reason, Formula, Stats_ResolveScoreTeam(Client, ScoreTeam));

	return true;
}

// 延迟结算时玩家可能已经离线；使用事件发生时保存的身份同步所有持久化账本。
stock bool:Stats_ApplyStoredClientScore(const String:SteamID[], const String:PlayerName[], Score, ScoreAfter, const String:Reason[], const String:Formula[], const String:ExtraSet[], ScoreTeam)
{
	if (!Stats_WriteScoreIdentity(SteamID, Score, ExtraSet, ScoreTeam))
		return false;

	if (Score != 0)
	{
		ScoreLog_RecordStored(SteamID, PlayerName, Score, ScoreAfter, Reason, Formula, ScoreTeam);
		QuarterRank_RecordScoreSteamID(SteamID, Score, ScoreTeam);
		ModeStats_RecordScoreSteamID(SteamID, Score);
	}

	return true;
}

// 感染者击杀需要在同一入口额外同步季度和模式击杀计数。
stock bool:Stats_ApplyInfectedKillScore(Client, Score, const String:InfectedType[], Kills, Headshots, const String:Reason[], const String:Formula[], const String:ExtraSet[] = "", bool:UpdateMapPoints = true, ScoreTeam = 0)
{
	if (!Stats_WriteClientScore(Client, Score, ExtraSet, ScoreTeam))
		return false;

	if (UpdateMapPoints && Score > 0)
		UpdateMapStat("points", Score);

	if (Score != 0 || Kills > 0)
		AddInfectedKillScore(Client, Score, InfectedType, Kills, Headshots, Reason, Formula, Stats_ResolveScoreTeam(Client, ScoreTeam));

	return true;
}

// 兼容现有 native/奖励调用；所有调用方都必须提供 Reason 和 Formula。
stock bool:Stats_AwardClientScore(Client, Score, const String:Reason[], const String:Formula[], const String:ExtraSet[] = "", bool:UpdateMapPoints = true)
{
	return Stats_ApplyClientScore(Client, Score, Reason, Formula, ExtraSet, UpdateMapPoints);
}
