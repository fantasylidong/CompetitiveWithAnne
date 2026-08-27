#if defined _l4d_stats_timers_included
	#endinput
#endif
#define _l4d_stats_timers_included

// 状态结束、友伤统计和周期更新定时器。

// End blinded state.

public Action:timer_EndBoomerBlinded(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	PlayerBlinded[data][0] = 0;
	PlayerBlinded[data][1] = 0;
}

// End blinded state.

public Action:timer_EndSmokerParalyzed(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	PlayerParalyzed[data][0] = 0;
	PlayerParalyzed[data][1] = 0;
}

// End lunging state.

public Action:timer_EndHunterLunged(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	PlayerLunged[data][0] = 0;
	PlayerLunged[data][1] = 0;
}

// End plummel state.

public Action:timer_EndChargerPlummel(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	ChargerPlummelVictim[PlayerPlummeled[data][1]] = 0;
	PlayerPlummeled[data][0] = 0;
	PlayerPlummeled[data][1] = 0;
}

// End charge impact counter state.

public Action:timer_EndCharge(Handle:timer, any:userid)
{
	new data;
	if (!Stats_ResolveHumanQueryUserId(userid, data))
		return;

	ChargerImpactCounterTimer[data] = INVALID_HANDLE;
	new Counter = ChargerImpactCounter[data];
	ChargerImpactCounter[data] = 0;

	new Score = 0;
	new String:ExtraSet[256] = "";

	if (Counter >= GetConVarInt(cvar_ChargerRamHits))
	{
		Score = ModifyScoreDifficultyFloat(GetConVarInt(cvar_ChargerRamSuccess), 0.9, 0.8, TEAM_INFECTED);

		Format(ExtraSet, sizeof(ExtraSet), ", award_scatteringram = award_scatteringram + 1");

		if (EnableSounds_Charger_Ram && GetConVarBool(cvar_SoundsEnabled))
			EmitSoundToAll(SOUND_CHARGER_RAM);
	}
	//UPDATE players SET points_infected = points_infected + 40, award_scatteringram = acharger_impacts = charger_impacts + 4 WHERE steamid = 'STEAM_1:1:12345678'

	Format(ExtraSet[strlen(ExtraSet)], sizeof(ExtraSet) - strlen(ExtraSet), ", charger_impacts = charger_impacts + %i", Counter);
	Stats_ApplyClientScore(data, Score, "charger_scattering_ram", "base=l4d_stats_chargerramsuccess,difficulty,impact_count", ExtraSet, false, TEAM_INFECTED);

	if (Score > 0)
	{
		decl String:MapPoints[32];
		Stats_GetMapPointsFieldForTeam(TEAM_INFECTED, MapPoints, sizeof(MapPoints));
		UpdateMapStat(MapPoints, Score);
	}

	if (Counter > 0)
		UpdateMapStat("charger_impacts", Counter);

	new Mode = 0;
	if (Score > 0)
		Mode = GetConVarInt(cvar_AnnounceMode);

	if ((Mode == 1 || Mode == 2) && IsClientConnected(data) && IsClientInGame(data))
		StatsPrintToChat(data, "L4DStats_ChargerMultiHitSelf", Counter, Score);
	else if (Mode == 3)
	{
		decl String:AttackerName[MAX_LINE_WIDTH];
		GetClientName(data, AttackerName, sizeof(AttackerName));
		StatsPrintToChatAll("L4DStats_ChargerMultiHitAll", AttackerName, Counter, Score);
	}
}

// End carried state.

public Action:timer_EndChargerCarry(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	ChargerCarryVictim[PlayerCarried[data][1]] = 0;
	PlayerCarried[data][0] = 0;
	PlayerCarried[data][1] = 0;
}

// End jockey ride state.

public Action:timer_EndJockeyRide(Handle:timer, any:userid)
{
	new data = GetClientOfUserId(userid);
	if (data <= 0)
		return;

	JockeyVictim[PlayerCarried[data][1]] = 0;
	PlayerJockied[data][0] = 0;
	PlayerJockied[data][1] = 0;
}

// End friendly fire damage counter.

public Action:timer_FriendlyFireDamageEnd(Handle:timer, any:dp)
{
	ResetPack(dp);

	new HumanDamage = ReadPackCell(dp);
	new BotDamage = ReadPackCell(dp);
	new AttackerUserId = ReadPackCell(dp);
	new Attacker = GetClientOfUserId(AttackerUserId);

	decl String:AttackerID[MAX_LINE_WIDTH];
	ReadPackString(dp, AttackerID, sizeof(AttackerID));
	decl String:AttackerName[MAX_LINE_WIDTH];
	ReadPackString(dp, AttackerName, sizeof(AttackerName));
	new ScoreBefore = ReadPackCell(dp);

	new bool:CurrentAttackerMatches = false;
	decl String:CurrentAttackerID[MAX_LINE_WIDTH];
	if (Stats_IsValidHumanClient(Attacker) && GetClientRankAuthString(Attacker, CurrentAttackerID, sizeof(CurrentAttackerID)) && StrEqual(CurrentAttackerID, AttackerID))
	{
		CurrentAttackerMatches = true;
		FriendlyFireTimer[Attacker][0] = INVALID_HANDLE;
	}

	// The damage is read and turned into lost points...
	ResetPack(dp);
	WritePackCell(dp, 0); // Human damage
	WritePackCell(dp, 0); // Bot damage

	if (HumanDamage <= 0 && BotDamage <= 0)
		return;

	new Score = 0;
		
	if (GetConVarBool(cvar_EnableNegativeScore))
	{
		if (HumanDamage > 0)
			Score += ModifyScoreDifficultyNR(RoundToNearest(GetConVarFloat(cvar_FriendlyFireMultiplier) * HumanDamage), 2, 4, TEAM_SURVIVORS);

		if (BotDamage > 0)
		{
			new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

			if (BotScoreMultiplier > 0.0)
				Score += ModifyScoreDifficultyNR(RoundToNearest(GetConVarFloat(cvar_FriendlyFireMultiplier) * BotDamage), 2, 4, TEAM_SURVIVORS);
		}

		if (IsNormalMode())
		{
			Score = RoundToFloor(Score / 5.0);
		}

		if (CurrentAttackerMatches)
		{
			Stats_ApplyClientScore(Attacker, Score * (-1), "friendly_fire_damage_penalty", "base=damage*l4d_stats_ffire_multiplier,difficulty,negative_score", ", award_friendlyfire = award_friendlyfire + 1", false, TEAM_SURVIVORS);
			QuarterRank_RecordField(Attacker, "award_friendlyfire", 1);
		}
		else if (Stats_ApplyStoredClientScore(AttackerID, AttackerName, Score * (-1), ScoreBefore - Score, "friendly_fire_damage_penalty", "base=damage*l4d_stats_ffire_multiplier,difficulty,negative_score", ", award_friendlyfire = award_friendlyfire + 1", TEAM_SURVIVORS))
		{
			QuarterRank_RecordFieldSteamID(AttackerID, "award_friendlyfire", 1);
		}

		new Mode = 0;
		if (Score > 0)
			Mode = GetConVarInt(cvar_AnnounceMode);

		if ((Mode == 1 || Mode == 2) && CurrentAttackerMatches)
			StatsPrintToChat(Attacker, "L4DStats_FriendlyFirePenaltySelf", HumanDamage + BotDamage, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_FriendlyFirePenaltyAll", AttackerName, HumanDamage + BotDamage, Score);
	}
}

// End friendly fire cooldown.

public Action:timer_FriendlyFireCooldownEnd(Handle:timer, any:data)
{
	new attacker = GetClientOfUserId(FriendlyFirePrm[data][0]);
	if (attacker <= 0)
		return;

	new target = 0;
	if (FriendlyFirePrm[data][1])
	{
		target = GetClientOfUserId(FriendlyFirePrm[data][1]);
		if (target <= 0)
			return;
	}

	FriendlyFireCooldown[attacker][target] = false;
	FriendlyFireTimer[attacker][target] = INVALID_HANDLE;
}

// End friendly fire cooldown.

public Action:timer_MeleeKill(Handle:timer, any:userid)
{
	new data;
	if (!Stats_ResolveHumanQueryUserId(userid, data))
		return;

	MeleeKillTimer[data] = INVALID_HANDLE;
	new Counter = MeleeKillCounter[data];
	MeleeKillCounter[data] = 0;

	if (Counter <= 0 || IsClientBot(data) || !IsClientConnected(data) || !IsClientInGame(data) || GetClientTeam(data) != TEAM_SURVIVORS)
		return;

	decl String:query[512], String:clientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(data, clientID, sizeof(clientID));
	Format(query, sizeof(query), "UPDATE %splayers SET melee_kills = melee_kills + %i WHERE steamid = '%s'", DbPrefix, Counter, clientID);
	SendSQLUpdate(query);
	QuarterRank_RecordField(data, "melee_kills", Counter);
}

// Perform minutely updates of player database.
// Reports Disabled message if in Versus, Easy mode, not enough Human players, and if cheats are active.

public Action:timer_UpdatePlayers(Handle:timer, Handle:hndl)
{
	if (CheckHumans())
	{
		if (GetConVarBool(cvar_DisabledMessages))
		{
			StatsPrintToChatAllPreFormatted("L4DStats_RankDisabledNotEnoughPlayers");
		}

		return;
	}

	if (StatsDisabled())
		return;

	if (Stats_HasPlaytimeStarted())
		UpdateMapStat("playtime", 1);

	GetTop100PlayerScore();
	QuarterRank_QueryTop100Scores();

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			CheckPlayerDB(i);
	}
}

// Display rank change.

public Action:timer_ShowRankChange(Handle:timer, any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	DoShowRankChange(client);
}

public DoShowRankChange(Client)
{
	if (StatsDisabled())
		return;

	decl String:ClientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Client, ClientID, sizeof(ClientID));

	QueryClientPointsSteamID(Client, ClientID, GetClientPointsRankChange);

	if (QuarterRank_Enabled())
	{
		QuarterRank_QueryClientPointsSteamID(Client, ClientID, GetClientQuarterPointsRankChange);
	}
}

// Display player rank.

public Action:timer_ShowPlayerJoined(Handle:timer, any:userid)
{
	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	DoShowPlayerJoined(client);
}

public OnClientAuthorized(Client, const String:SteamID[]){
	if (!Client)
		return;

	NewPlayerBonus_ResetClientData(Client);

	if (StrEqual(SteamID, "BOT", false)) {
		return;
	}

	// 数据库连接和客户端入服状态在 PostAdminCheck 阶段统一确认后再查询。
}

stock QueryClientNewPlayerBonusData(Client, const String:SteamID[])
{
	if (db == INVALID_HANDLE || !Stats_IsValidHumanClient(Client))
		return;

	decl String:query[1024];
	Format(query, sizeof(query), "SELECT %s, %s FROM %splayers WHERE steamid = '%s'", DB_PLAYERS_TOTALPLAYTIME, DB_PLAYERS_TOTALPOINTS, DbPrefix, SteamID);
	SQL_TQuery(db, GetBasicInf, query, GetClientUserId(Client));
}
// Send the RANK panel to the client's display.
public GetBasicInf(Handle:owner, Handle:hndl, const String:error[], any:userid)
{
	if (hndl == INVALID_HANDLE)
	{
		LogError("GetBasicInf Query failed: %s", error);
		return;
	}

	new client;
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return;

	if (SQL_FetchRow(hndl))
	{
		ClientPlayTime[client] = SQL_FetchInt(hndl, 0);
		ClientPoints[client] = SQL_FetchInt(hndl, 1);
	}
	else
	{
		// 查询成功且没有记录，才确认这是分数和时长均为 0 的新玩家。
		ClientPlayTime[client] = 0;
		ClientPoints[client] = 0;
	}

	g_bNewPlayerBonusClientDataReady[client] = true;
	ClientScoreReady[client] = true;
	Call_StartForward(SuccessGetPlayerTime);//转发触发
	Call_PushCell(client);//按顺序将参数push进forward传参列表里
	Call_Finish();//转发结束

	if (g_bStatsPlaytimeStarted || Isstart || SurvivalStarted)
		NewPlayerBonus_AnnounceRoundStart();
}
public DoShowPlayerJoined(client)
{
	if (StatsDisabled())
	{
		return;
	}

	decl String:clientId[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, clientId, sizeof(clientId));

	QueryClientStatsSteamID(client, clientId, CM_PLAYERJOINED);
}

// Display common Infected scores to each player.

public Action:timer_ShowTimerScore(Handle:timer, Handle:hndl)
{
	if (StatsDisabled())
		return;

	new Mode = GetConVarInt(cvar_AnnounceMode);
	decl String:Name[MAX_LINE_WIDTH];

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			// if (CurrentPoints[i] > GetConVarInt(cvar_MaxPoints))
			//     continue;

			TimerPoints[i] = GetMedkitPointReductionScore(TimerPoints[i]);
			TimerPoints[i] = NewPlayerBonus_ApplyScoreMultiplier(i, TimerPoints[i]);

			if (TimerPoints[i] > 0 && TimerKills[i] > 0)
			{
				if (Mode == 1 || Mode == 2)
				{
					StatsPrintToChat(i, "L4DStats_CommonKillsRewardSelf", TimerKills[i], TimerPoints[i]);
				}
				else if (Mode == 3)
				{
					GetClientName(i, Name, sizeof(Name));
					StatsPrintToChatAll("L4DStats_CommonKillsRewardAll", Name, TimerKills[i], TimerPoints[i]);
				}
			}

			InterstitialPlayerUpdateEx(i, false);
		}

		TimerPoints[i] = 0;
		TimerKills[i] = 0;
		TimerHeadshots[i] = 0;
	}

}

// Update a player's stats, used for interstitial updating.

public InterstitialPlayerUpdate(client)
{
	InterstitialPlayerUpdateEx(client, true);
}

InterstitialPlayerUpdateEx(client, bool:ApplyNewPlayerMultiplier)
{
	new AwardPoints = TimerPoints[client];
	if (ApplyNewPlayerMultiplier)
		AwardPoints = NewPlayerBonus_ApplyScoreMultiplier(client, AwardPoints);

	decl String:ExtraSet[256];
	Format(ExtraSet, sizeof(ExtraSet), ", kills = kills + %i, kill_infected = kill_infected + %i, headshots = headshots + %i", TimerKills[client], TimerKills[client], TimerHeadshots[client]);
	Stats_ApplyInfectedKillScore(client, AwardPoints, "infected", TimerKills[client], TimerHeadshots[client], "common_infected_timer", "timer_points=sum_common_infected_kills,difficulty,newbie_multiplier", ExtraSet, false);

	UpdateMapStat("kills", TimerKills[client]);
	UpdateMapStat("points", AwardPoints);

}
