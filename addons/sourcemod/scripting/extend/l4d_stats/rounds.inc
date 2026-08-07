#if defined _l4d_stats_rounds_included
	#endinput
#endif
#define _l4d_stats_rounds_included

// 游戏模式标签、回合开始/结束和清道夫回合入口。

public SetCurrentGamemodeName()
{
	switch (Stats_GetCurrentStatsGamemodeID())
	{
		case GAMEMODE_COOP:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeCoop");
		}
		case GAMEMODE_VERSUS:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeVersus");
		}
		case GAMEMODE_REALISM:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeRealism");
		}
		case GAMEMODE_SURVIVAL:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeSurvival");
		}
		case GAMEMODE_SCAVENGE:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeScavenge");
		}
		case GAMEMODE_REALISMVERSUS:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeRealismVersus");
		}
		case GAMEMODE_OTHERMUTATIONS:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeMutations");
		}
		default:
		{
			strcopy(CurrentGamemodeLabel, sizeof(CurrentGamemodeLabel), "L4DStats_GamemodeUnknown");
		}
	}

	if (CurrentGamemodeID == GAMEMODE_OTHERMUTATIONS)
	{
		GetConVarString(cvar_Gamemode, CurrentMutation, sizeof(CurrentMutation));
	}
	else
	{
		CurrentMutation[0] = 0;
	}
}

public Action Event_RoundEnd(Handle:event, String:event_name[], bool:dontBroadcast)
{
	// Competitive modes keep round history in map_runs but do not enter cooperative fastest-time tables.
	if (MapRecords_GetPolicy() == MAP_RECORD_POLICY_HISTORY && MapTimingStartTime > 0.0)
		StopMapTimingWithOptions(false, true);

	if(!g_broundend && (AnneMultiPlayerMode() || SinglePlayerMode())){
		g_broundend = true;
	}else{
		return Plugin_Handled;
	}
	if(!L4D_HasAnySurvivorLeftSafeArea())
		return Plugin_Continue;
	if(!Isstart)
		return Plugin_Continue;
	UpdateMapStat("restarts", 1);
	int Score=200;
	if (!GetConVarBool(cvar_EnableNegativeScore))
		return Plugin_Continue;
	if (AnneMultiPlayerMode() || (FindConVar("survivor_limit").IntValue > 2)){
		Score = 200;
	}
	else{
		Score = 0;
	}
	
	if(IsAnne() == 2)
	{
		Score = RoundToFloor(view_as<float>(Score) * 0.4);
	}

	if(IsFunGame())
	{
		//娱乐模式团灭不掉分
		return Plugin_Continue;
	}
	
		for(int i = 1; i <= MaxClients; i++){
			if(IsClientConnected(i) && IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS || Stats_IsRoundParticipant(i)) && !IsFakeClient(i) && Score > 0){
				StatsPrintToChat(i, "L4DStats_AllPlayersLostRoundPenalty", Score);
				Stats_ApplyClientScore(i, Score * (-1), "round_end_penalty", "base=anne_round_end,negative_score", "", false, TEAM_SURVIVORS);
			}
		}
	Isstart=false;	
	return Plugin_Continue;
}

// Scavenge round start event (occurs when door opens or players leave the start area)

public Action:event_ScavengeRoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	event_RoundStart(event, name, dontBroadcast);

	g_bStatsPlaytimeStarted = true;
	StartMapTiming();
}

// Called after the connection to the database is established

public Action:event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	ResetVars();
	CheckCurrentMapDB();
	MapTimingStartTime = 0.0;
	MapTimingBlocked = false;
	g_bMapTimingNoFastestPromptSent = false;
	g_bStatsPlaytimeStarted = false;
	g_broundend = false;
	NewPlayerBonus_ResetRound();
	ResetRankChangeCheck();
}
