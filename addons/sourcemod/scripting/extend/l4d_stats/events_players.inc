#if defined _l4d_stats_events_players_included
	#endinput
#endif
#define _l4d_stats_events_players_included

// 玩家个人行为事件：击杀、治疗、倒地、友伤和物品。

// Player Death event. Used for killing AI Infected. +2 on headshot, and global announcement.
// Team Kill code is in the awards section. Tank Kill code is in Tank section.

public Action:event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new bool:AttackerIsBot = GetEventBool(event, "attackerisbot");
	new bool:VictimIsBot = GetEventBool(event, "victimisbot");
	new VictimTeam = -1;

	// Self inflicted death does not count
	if (Attacker == Victim)
		return;

	if (!VictimIsBot)
		DoInfectedFinalChecks(Victim, ClientInfectedType[Victim]);

	if (Victim > 0)
		VictimTeam = GetClientTeam(Victim);

	if (Attacker == 0 || AttackerIsBot)
	{
		// Attacker is normal indected but the Victim was infected by blinding and/or paralysation.
		if (Attacker == 0
				&& VictimTeam == TEAM_SURVIVORS
				&& (PlayerBlinded[Victim][0] && PlayerBlinded[Victim][1]
					|| PlayerParalyzed[Victim][0] && PlayerParalyzed[Victim][1]
					|| PlayerLunged[Victim][0] && PlayerLunged[Victim][1]
					|| PlayerCarried[Victim][0] && PlayerCarried[Victim][1]
					|| PlayerPlummeled[Victim][0] && PlayerPlummeled[Victim][1]
					|| PlayerJockied[Victim][0] && PlayerJockied[Victim][1])
				&& IsGamemodeVersus())
			PlayerDeathExternal(Victim);

		if (CurrentGamemodeID == GAMEMODE_SURVIVAL && Victim > 0 && VictimTeam == TEAM_SURVIVORS)
			CheckSurvivorsAllDown();

		return;
	}

	new Mode = GetConVarInt(cvar_AnnounceMode);
	new AttackerTeam = GetClientTeam(Attacker);
	decl String:AttackerName[MAX_LINE_WIDTH];
	decl String:AttackerID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Attacker, AttackerID, sizeof(AttackerID));
	decl String:VictimName[MAX_LINE_WIDTH];
	new VictimInfType = -1;

	if (Victim > 0)
	{
		GetClientName(Victim, VictimName, sizeof(VictimName));

		if (VictimTeam == TEAM_INFECTED)
			VictimInfType = GetInfType(Victim);
	}
	else
	{
		GetEventString(event, "victimname", VictimName, sizeof(VictimName));

		if (StrEqual(VictimName, "hunter", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_HUNTER;
		}
		else if (StrEqual(VictimName, "smoker", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_SMOKER;
		}
		else if (StrEqual(VictimName, "boomer", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_BOOMER;
		}
		if (StrEqual(VictimName, "spitter", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_SPITTER_L4D2;
		}
		else if (StrEqual(VictimName, "jockey", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_JOCKEY_L4D2;
		}
		else if (StrEqual(VictimName, "charger", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_CHARGER_L4D2;
		}
		else if (StrEqual(VictimName, "tank", false))
		{
			VictimTeam = TEAM_INFECTED;
			VictimInfType = INF_ID_TANK_L4D2;
		}
		else
			return;
	}

	// The wearoff should now work properly! Don't initialize
	//if (Victim > 0 && (VictimInfType == INF_ID_HUNTER || VictimInfType == INF_ID_SMOKER))
	//	InitializeClientInf(Victim);

	if (VictimTeam == TEAM_SURVIVORS)
		CheckSurvivorsAllDown();

	// Team Kill: Attacker is a Survivor and Victim is Survivor
	if (AttackerTeam == TEAM_SURVIVORS && VictimTeam == TEAM_SURVIVORS && L4D_HasAnySurvivorLeftSafeArea())
	{
		new Score = 0;
		if (GetConVarBool(cvar_EnableNegativeScore))
		{
			if (!IsClientBot(Victim))
				Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_FKill), 2, 4, TEAM_SURVIVORS);
			else
			{
				new Float:BotScoreMultiplier = GetConVarFloat(cvar_BotScoreMultiplier);

				if (BotScoreMultiplier > 0.0)
					Score = RoundToNearest(ModifyScoreDifficultyNR(GetConVarInt(cvar_FKill), 2, 4, TEAM_SURVIVORS) * BotScoreMultiplier);
			}
		}
		else
			Mode = 0;

			if(IsNormalMode()){
				Score = RoundToFloor(Score / 5.0);
			}

			Stats_ApplyClientScore(Attacker, Score * (-1), "team_kill_penalty", "base=l4d_stats_fkill,difficulty,negative_score", ", award_teamkill = award_teamkill + 1", false, TEAM_SURVIVORS);
				QuarterRank_RecordField(Attacker, "award_teamkill", 1);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Attacker, "L4DStats_TeamKillPenaltySelf", VictimName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_TeamKillPenaltyAll", AttackerName, VictimName, Score);
	}

	// Attacker is a Survivor
	else if (AttackerTeam == TEAM_SURVIVORS && VictimTeam == TEAM_INFECTED)
	{
		int human = CheckSurvivorsHumans();
		if( human < 3 || IsWitchParty() || IsAllCharger() || (g_brpgAvailable && !L4D_RPG_GetGlobalValue(INDEX_VALID)))
			return;
		new Score = 0;
		decl String:InfectedType[8];

		if (VictimInfType == INF_ID_HUNTER)
		{
			Format(InfectedType, sizeof(InfectedType), "hunter");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Hunter), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_SMOKER)
		{
			Format(InfectedType, sizeof(InfectedType), "smoker");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Smoker), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_BOOMER)
		{
			Format(InfectedType, sizeof(InfectedType), "boomer");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Boomer), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_SPITTER_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "spitter");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Spitter), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_JOCKEY_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "jockey");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Jockey), 2, 3, TEAM_SURVIVORS);
		}
		else if (VictimInfType == INF_ID_CHARGER_L4D2)
		{
			Format(InfectedType, sizeof(InfectedType), "charger");
			Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Charger), 2, 3, TEAM_SURVIVORS);
		}
		else
			return;

			new bool:IsHeadshot = GetEventBool(event, "headshot");
			if (IsHeadshot)
			{
				Score = Score + 2;
			}

		Score = GetMedkitPointReductionScore(Score);

			if(IsFunGame())
			{
				Score = 0;
			}

			decl String:ExtraSet[256];
			Format(ExtraSet, sizeof(ExtraSet), ", kills = kills + 1, kill_%s = kill_%s + 1", InfectedType, InfectedType);
			if (IsHeadshot)
				StrCat(ExtraSet, sizeof(ExtraSet), ", headshots = headshots + 1");
			decl String:ScoreFormula[MAX_MESSAGE_WIDTH];
			Format(ScoreFormula, sizeof(ScoreFormula), "base=l4d_stats_%s,difficulty,headshot=%i,medkit_reduction", InfectedType, IsHeadshot ? 1 : 0);
			Stats_ApplyInfectedKillScore(Attacker, Score, InfectedType, 1, IsHeadshot ? 1 : 0, "special_infected_kill", ScoreFormula, ExtraSet, false, TEAM_SURVIVORS);

		if (Mode && Score > 0)
		{
			decl String:VictimLabel[MAX_LINE_WIDTH];
			if (IsHeadshot)
			{
				if (Mode > 1)
				{
					GetClientName(Attacker, AttackerName, sizeof(AttackerName));
					for (new i = 1; i <= MaxClients; i++)
					{
						if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
							continue;
						Stats_FormatKillVictimLabel(i, Victim, VictimInfType, VictimName, VictimLabel, sizeof(VictimLabel));
						StatsPrintToChat(i, "L4DStats_HeadshotSpecialKillAll", AttackerName, VictimLabel, Score);
					}
				}
				else
				{
					Stats_FormatKillVictimLabel(Attacker, Victim, VictimInfType, VictimName, VictimLabel, sizeof(VictimLabel));
					StatsPrintToChat(Attacker, "L4DStats_HeadshotSpecialKillSelf", VictimLabel, Score);
				}
			}
			else
			{
				if (Mode > 1)
				{
					GetClientName(Attacker, AttackerName, sizeof(AttackerName));
					for (new i = 1; i <= MaxClients; i++)
					{
						if (!IsClientConnected(i) || !IsClientInGame(i) || IsClientBot(i))
							continue;
						Stats_FormatKillVictimLabel(i, Victim, VictimInfType, VictimName, VictimLabel, sizeof(VictimLabel));
						StatsPrintToChat(i, "L4DStats_SpecialKillAll", AttackerName, VictimLabel, Score);
					}
				}
				else
				{
					Stats_FormatKillVictimLabel(Attacker, Victim, VictimInfType, VictimName, VictimLabel, sizeof(VictimLabel));
					StatsPrintToChat(Attacker, "L4DStats_SpecialKillSelf", VictimLabel, Score);
				}
			}
		}

		UpdateMapStat("kills", 1);
		UpdateMapStat("points", Score);
	}

	// Attacker is an Infected
	else if (AttackerTeam == TEAM_INFECTED && VictimTeam == TEAM_SURVIVORS)
		SurvivorDiedNamed(Attacker, Victim, VictimName, AttackerID, -1, Mode);

	if (VictimTeam == TEAM_SURVIVORS)
	{
		if (PanicEvent)
			PanicEventIncap = true;

		if (PlayerVomited)
			PlayerVomitedIncap = true;
	}
}

stock int IsAnne(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return 0;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AnneHappy", false) != -1)
	{
		if(StrContains(plugin_name, "HardCore", false) != -1)
			return 2;
		else
			return 1;
	}else
	{
		return 0;
	}
}

stock bool IsAnneShotgunMode(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AnneHappy", false) != -1 && StrContains(plugin_name, "Shotgun", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}


stock int IsFunGame(){
	//判断游戏是否是娱乐模式，alone 1vht删除特感分(返回1)，witchparty allcharger realismCoop RealismRealism versus 等其他模式不加分不减分，不记游戏时间，只做统计(返回2)
	if(IsAnne())
	{
		return 0;
	}
	if(IsAlone() || Is1vht())
	{
		return 1;
	}
	if(IsWitchParty() || IsAllCharger())
	{
		return 2;
	}
	return 3;
}

stock bool IsAllCharger(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AllCharger", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsMutationCoop()
{
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return 0;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AnneCoop", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsRealism()
{
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return 0;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "AnneRealism", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool Is1vht(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "1vHunters", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsWitchParty(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "WitchParty", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool IsAlone(){
	decl String:plugin_name[MAX_LINE_WIDTH];
	if(cvar_mode == null && FindConVar("l4d_ready_cfg_name"))
	{
		cvar_mode = FindConVar("l4d_ready_cfg_name");
	}
	if(cvar_mode == null) return false;
	GetConVarString(cvar_mode, plugin_name, sizeof(plugin_name));
	if(StrContains(plugin_name, "Alone", false) != -1)
	{
		return true;
	}else
	{
		return false;
	}
}

stock bool SinglePlayerMode(){
	if(Is1vht() || IsAlone()){
		return true;
	}
	return false;
}

stock bool AnneMultiPlayerMode(){
	if(IsAnne() || IsWitchParty() || IsAllCharger()){
		return true;
	}
	return false;
}

stock bool IsAboveFourPeople()
{
	ConVar survivorManager = FindConVar("l4d_multislots_survivors_manager_enable");
	if( survivorManager == null)
	{
		return false;
	}
	else
	{
		if(survivorManager.BoolValue)
		{
			return true;
		}else
		{
			return false;
		}
	}
}

stock int getSurvivorNum()
{
	int count = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2)
		{
			count ++;
		}
	}
	return count;
}


// Common Infected death code. +1 on headshot.

public Action:event_InfectedDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

	if (!Attacker || IsClientBot(Attacker) || GetClientTeam(Attacker) == TEAM_INFECTED)
		return;
	new Score =0;
	if (AnneMultiPlayerMode())
		Score = ModifyScoreDifficultyNR(2, 1, 1, TEAM_SURVIVORS);
	else if(IsNormalMode())
		Score = ModifyScoreDifficultyNR(2, 2, 3, TEAM_SURVIVORS);
	else {
		Score = ModifyScoreDifficultyNR(GetConVarInt(cvar_Infected), 2, 3, TEAM_SURVIVORS);
	}

	if (GetEventBool(event, "headshot"))
	{
		Score = Score + 1;
		TimerHeadshots[Attacker] = TimerHeadshots[Attacker] + 1;
	}

	TimerPoints[Attacker] = TimerPoints[Attacker] + Score;
	TimerKills[Attacker] = TimerKills[Attacker] + 1;

	// Melee?
	if (EngineVersion1 != Engine_Left4Dead)
	{
		new WeaponID = GetEventInt(event, "weapon_id");

		if (WeaponID == 19)
			IncrementMeleeKills(Attacker);
	}

	//decl String:AttackerName[MAX_LINE_WIDTH];
	//GetClientName(Attacker, AttackerName, sizeof(AttackerName));

	//LogMessage("[DEBUG] %s killed an infected (Weapon ID: %i)", AttackerName, WeaponID);
	//PrintToConsoleAll("[DEBUG] %s killed an infected (Weapon ID: %i)", AttackerName, WeaponID);
}

// Check player validity before calling this method!
IncrementMeleeKills(client)
{
	if (MeleeKillTimer[client] != INVALID_HANDLE)
		CloseHandle(MeleeKillTimer[client]);

	MeleeKillCounter[client]++;
	MeleeKillTimer[client] = CreateTimer(5.0, timer_MeleeKill, client);
}

// Tank death code. Points are given to all players.

public Action:event_TankKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
	{
		return;
	}

	if (TankCount >= 3)
	{
		return;
	}

	new BaseScore = ModifyScoreDifficulty(GetConVarInt(cvar_Tank), 2, 4, TEAM_SURVIVORS);
	new Mode = GetConVarInt(cvar_AnnounceMode);
	new Deaths = 0;
	new Players = 0;

	new maxplayers = MaxClients;
	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			Players++;

			if (!IsPlayerAlive(i))
			{
				Deaths++;
			}
		}
	}

	// This was proposed by AlliedModders users el_psycho and PatriotGames (Thanks!)
	new Score = (BaseScore * ((Players - Deaths) / Players)) / Players;

	// HardCore 奖励增加100%
	if(IsAnne() == 2)
	{
		Score *= 2;
	}
	

	if(IsFunGame())
	{
		Score = 0;
		//return Plugin_Continue;
	}

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i) && GetClientTeam(i) == TEAM_SURVIVORS)
		{
			Stats_ApplyClientScore(i, Score, "tank_kill", "base=l4d_stats_tank,difficulty,alive_players", ", award_tankkill = award_tankkill + 1", false, TEAM_SURVIVORS);
		}
	}

	if (Mode && Score > 0)
	{
		StatsPrintToChatTeam(TEAM_SURVIVORS, "L4DStats_TankKillWithDeaths", Deaths, Score);
	}

	UpdateMapStat("kills", 1);
	UpdateMapStat("points", Score);
	TankCount = TankCount + 1;
}

stock bool:Stats_IsTrackedWeaponEntity(entity)
{
	return entity > 0 && entity < sizeof(Pills);
}

stock bool:Stats_IsSupportItemClassName(const String:ClassName[])
{
	return StrContains(ClassName, "pain_pills", false) != -1 ||
		StrContains(ClassName, "adrenaline", false) != -1 ||
		StrContains(ClassName, "first_aid_kit", false) != -1;
}

stock Stats_GetSupportItemOwner(entity)
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_hOwnerEntity"))
		return -1;

	return GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
}

stock Stats_RecordWorldSupportItem(entity)
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !IsValidEntity(entity))
		return;

	decl String:ClassName[MAX_LINE_WIDTH];
	GetEntityClassname(entity, ClassName, sizeof(ClassName));
	if (!Stats_IsSupportItemClassName(ClassName))
		return;

	if (!Stats_IsValidClient(Stats_GetSupportItemOwner(entity)))
		SupportItemWorldSpawned[entity] = true;
}

stock Stats_RecordWorldSupportItems()
{
	new EntityLimit = GetMaxEntities();
	if (EntityLimit > sizeof(SupportItemWorldSpawned))
		EntityLimit = sizeof(SupportItemWorldSpawned);

	for (new entity = MaxClients + 1; entity < EntityLimit; entity++)
	{
		Stats_RecordWorldSupportItem(entity);
	}
}

public OnEntityCreated(entity, const String:ClassName[])
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !Stats_IsSupportItemClassName(ClassName))
		return;

	Pills[entity] = 0;
	Adrenaline[entity] = 0;
	PillsFirstHolder[entity] = 0;
	AdrenalineFirstHolder[entity] = 0;
	FirstAidFirstHolder[entity] = 0;
	SupportItemWorldSpawned[entity] = false;

	CreateTimer(0.1, timer_RecordWorldSupportItem, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:timer_RecordWorldSupportItem(Handle:timer, any:entityRef)
{
	new entity = EntRefToEntIndex(entityRef);
	if (entity == INVALID_ENT_REFERENCE)
		return Plugin_Stop;

	Stats_RecordWorldSupportItem(entity);
	return Plugin_Stop;
}

stock bool:Stats_IsSupportGiveBlocked(client)
{
	return Stats_IsValidClient(client) && GetEngineTime() <= SupportGiveCommandUntil[client];
}

stock bool:Stats_IsSupportStartGrantWindow()
{
	if (GetEngineTime() > SupportStartGrantUntil)
		return false;

	return !g_brpgAvailable || !L4D_RPG_GetGlobalValue(INDEX_USEBUY);
}

stock Stats_MarkHeldSupportItemsUnscoreable(client)
{
	if (!Stats_IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return;

	new entity = GetPlayerWeaponSlot(client, 3);
	if (Stats_IsTrackedWeaponEntity(entity) && IsValidEntity(entity))
		Stats_MarkUnscoreableSupportItem(FirstAidFirstHolder, entity);

	entity = GetPlayerWeaponSlot(client, 4);
	if (!Stats_IsTrackedWeaponEntity(entity) || !IsValidEntity(entity))
		return;

	decl String:ClassName[MAX_LINE_WIDTH];
	GetEntityClassname(entity, ClassName, sizeof(ClassName));
	if (StrContains(ClassName, "pain_pills", false) != -1)
		Stats_MarkUnscoreableSupportItem(PillsFirstHolder, entity);
	else if (StrContains(ClassName, "adrenaline", false) != -1)
		Stats_MarkUnscoreableSupportItem(AdrenalineFirstHolder, entity);
}

public Action:timer_MarkHeldSupportItemsUnscoreable(Handle:timer, any:userId)
{
	new client = GetClientOfUserId(userId);
	if (client > 0)
		Stats_MarkHeldSupportItemsUnscoreable(client);

	return Plugin_Stop;
}

public Action:Command_BlockSupportGiveSource(client, const String:command[], argc)
{
	if (!Stats_IsValidClient(client))
		return Plugin_Continue;

	decl String:Args[128];
	GetCmdArgString(Args, sizeof(Args));
	if (StrContains(Args, "pain_pills", false) == -1 &&
		StrContains(Args, "pills", false) == -1 &&
		StrContains(Args, "adrenaline", false) == -1 &&
		StrContains(Args, "first_aid", false) == -1 &&
		StrContains(Args, "firstaid", false) == -1)
		return Plugin_Continue;

	if (Stats_IsSupportStartGrantWindow())
		return Plugin_Continue;

	SupportGiveCommandUntil[client] = GetEngineTime() + 2.0;
	CreateTimer(0.1, timer_MarkHeldSupportItemsUnscoreable, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.5, timer_MarkHeldSupportItemsUnscoreable, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

stock Stats_RecordScoreableSupportHolder(firstHolder[], entity, client, bool:AllowStartGrant=false)
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !Stats_IsValidClient(client))
		return;

	if (firstHolder[entity] != 0)
		return;

	if (SupportItemWorldSpawned[entity] || (AllowStartGrant && !Stats_IsSupportGiveBlocked(client)))
		firstHolder[entity] = GetClientUserId(client);
	else if (Isstart || AllowStartGrant || Stats_IsSupportGiveBlocked(client))
		firstHolder[entity] = -1;
}

stock bool:Stats_ShouldMarkUnknownSupportPickupUnscoreable(client)
{
	if (!Stats_IsSupportGiveBlocked(client) && Stats_IsSupportStartGrantWindow())
		return false;

	return Isstart || Stats_IsSupportGiveBlocked(client);
}

stock bool:Stats_IsScoreableSupportPickup(entity)
{
	if (!Stats_IsTrackedWeaponEntity(entity))
		return false;

	return SupportItemWorldSpawned[entity];
}

stock Stats_HandleUnknownSupportPickup(firstHolder[], entity, client)
{
	if (Stats_ShouldMarkUnknownSupportPickupUnscoreable(client))
		Stats_MarkUnscoreableSupportItem(firstHolder, entity);
}

stock Stats_GetHeldSupportItemType(client)
{
	if (!Stats_IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return 0;

	new entity = GetPlayerWeaponSlot(client, 4);
	if (!Stats_IsTrackedWeaponEntity(entity) || !IsValidEntity(entity))
		return 0;

	decl String:ClassName[MAX_LINE_WIDTH];
	GetEntityClassname(entity, ClassName, sizeof(ClassName));
	if (StrContains(ClassName, "pain_pills", false) != -1)
		return 1;

	if (StrContains(ClassName, "adrenaline", false) != -1)
		return 2;

	return 0;
}

public Action:Command_ReloadSupportItem(client, const String:command[], argc)
{
	if (!Stats_IsSurvivorHuman(client))
		return Plugin_Continue;

	new ItemType = Stats_GetHeldSupportItemType(client);
	if (ItemType == 0)
		return Plugin_Continue;

	SupportReloadTime[client] = GetEngineTime();
	SupportReloadType[client] = ItemType;
	GetClientAbsOrigin(client, SupportReloadOrigin[client]);

	return Plugin_Continue;
}

stock Stats_RecordFirstHolder(firstHolder[], entity, client)
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !Stats_IsValidClient(client))
		return;

	if (firstHolder[entity] == 0)
		firstHolder[entity] = GetClientUserId(client);
}

stock Stats_MarkUnscoreableSupportItem(firstHolder[], entity)
{
	if (!Stats_IsTrackedWeaponEntity(entity))
		return;

	if (firstHolder[entity] == 0)
		firstHolder[entity] = -1;
}

stock bool:Stats_IsRecentReloadTransferPickup(client, ItemType)
{
	if (!Stats_IsSurvivorHuman(client) || ItemType == 0)
		return false;

	new Float:Now = GetEngineTime();
	decl Float:Origin[3];
	GetClientAbsOrigin(client, Origin);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (i == client || !Stats_IsSurvivorHuman(i))
			continue;

		if (SupportReloadType[i] != ItemType)
			continue;

		if (Now - SupportReloadTime[i] > 1.0)
			continue;

		if (GetVectorDistance(Origin, SupportReloadOrigin[i]) <= 250.0)
			return true;
	}

	return false;
}

stock bool:Stats_IsOriginalHolder(firstHolder[], entity, client)
{
	if (!Stats_IsTrackedWeaponEntity(entity) || !Stats_IsValidClient(client))
		return false;

	if (firstHolder[entity] == 0)
		return false;

	return firstHolder[entity] == GetClientUserId(client);
}

stock Stats_RecordHeldSupportItems(client, bool:AllowHeldAfterStart=false)
{
	if (!Stats_IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return;

	decl String:ClassName[MAX_LINE_WIDTH];
	new entity = GetPlayerWeaponSlot(client, 3);
	if (Stats_IsTrackedWeaponEntity(entity) && IsValidEntity(entity))
	{
		GetEntityClassname(entity, ClassName, sizeof(ClassName));
		if (StrContains(ClassName, "first_aid_kit", false) != -1)
			Stats_RecordScoreableSupportHolder(FirstAidFirstHolder, entity, client, AllowHeldAfterStart);
	}

	entity = GetPlayerWeaponSlot(client, 4);
	if (Stats_IsTrackedWeaponEntity(entity) && IsValidEntity(entity))
	{
		GetEntityClassname(entity, ClassName, sizeof(ClassName));
		if (StrContains(ClassName, "pain_pills", false) != -1)
			Stats_RecordScoreableSupportHolder(PillsFirstHolder, entity, client, AllowHeldAfterStart);
		else if (StrContains(ClassName, "adrenaline", false) != -1)
			Stats_RecordScoreableSupportHolder(AdrenalineFirstHolder, entity, client, AllowHeldAfterStart);
	}
}

stock Stats_RecordAllHeldSupportItems(bool:AllowHeldAfterStart=false)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		Stats_RecordHeldSupportItems(i, AllowHeldAfterStart);
	}
}

stock Stats_ScheduleStartGrantedSupportItemScans()
{
	CreateTimer(0.1, timer_RecordStartGrantedSupportItems, _, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(0.5, timer_RecordStartGrantedSupportItems, _, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(1.0, timer_RecordStartGrantedSupportItems, _, TIMER_FLAG_NO_MAPCHANGE);
}

stock Stats_OpenStartGrantedSupportItemWindow()
{
	new Float:Until = GetEngineTime() + 1.2;
	if (Until > SupportStartGrantUntil)
		SupportStartGrantUntil = Until;
}

stock Stats_RecordStartGrantedSupportItems()
{
	if (SupportStartGrantRecorded)
		return;

	SupportStartGrantRecorded = true;
	Stats_OpenStartGrantedSupportItemWindow();
	Stats_RecordAllHeldSupportItems(true);
	Stats_ScheduleStartGrantedSupportItemScans();
}

stock Stats_ScheduleInitialSupportItemScans(Float:Duration)
{
	new Float:Until = GetEngineTime() + Duration;
	if (Until > InitialSupportScanUntil)
		InitialSupportScanUntil = Until;

	CreateTimer(0.2, timer_RecordInitialSupportItems);
	CreateTimer(1.0, timer_RecordInitialSupportItems);
	CreateTimer(3.0, timer_RecordInitialSupportItems);
	CreateTimer(6.0, timer_RecordInitialSupportItems);
	CreateTimer(10.0, timer_RecordInitialSupportItems);
}

public Action:timer_RecordInitialSupportItems(Handle:timer)
{
	if (CampaignOver)
	{
		return Plugin_Stop;
	}

	if (Isstart && GetEngineTime() > InitialSupportScanUntil)
	{
		return Plugin_Stop;
	}

	Stats_RecordAllHeldSupportItems();
	return Plugin_Stop;
}

public Action:timer_RecordStartGrantedSupportItems(Handle:timer)
{
	if (CampaignOver)
		return Plugin_Stop;

	Stats_RecordAllHeldSupportItems(true);
	return Plugin_Stop;
}

public Action:event_ItemPickup(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	if (!Stats_IsValidClient(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return;

	decl String:ItemName[MAX_LINE_WIDTH];
	GetEventString(event, "item", ItemName, sizeof(ItemName));

	if (StrContains(ItemName, "pain_pills", false) != -1)
	{
		new entity = GetPlayerWeaponSlot(client, 4);
		if (Stats_IsRecentReloadTransferPickup(client, 1))
			Stats_MarkUnscoreableSupportItem(PillsFirstHolder, entity);
		else if (Stats_IsScoreableSupportPickup(entity))
			Stats_RecordScoreableSupportHolder(PillsFirstHolder, entity, client);
		else
			Stats_HandleUnknownSupportPickup(PillsFirstHolder, entity, client);
	}
	else if (StrContains(ItemName, "adrenaline", false) != -1)
	{
		new entity = GetPlayerWeaponSlot(client, 4);
		if (Stats_IsRecentReloadTransferPickup(client, 2))
			Stats_MarkUnscoreableSupportItem(AdrenalineFirstHolder, entity);
		else if (Stats_IsScoreableSupportPickup(entity))
			Stats_RecordScoreableSupportHolder(AdrenalineFirstHolder, entity, client);
		else
			Stats_HandleUnknownSupportPickup(AdrenalineFirstHolder, entity, client);
	}
	else if (StrContains(ItemName, "first_aid_kit", false) != -1)
	{
		new entity = GetPlayerWeaponSlot(client, 3);
		if (Stats_IsScoreableSupportPickup(entity))
			Stats_RecordScoreableSupportHolder(FirstAidFirstHolder, entity, client);
		else
			Stats_HandleUnknownSupportPickup(FirstAidFirstHolder, entity, client);
	}
}

public Action:event_HealBegin(Handle:event, const String:name[], bool:dontBroadcast)
{
	new Giver = GetClientOfUserId(GetEventInt(event, "userid"));

	if (!Stats_IsValidClient(Giver))
		return;

	new FirstAidID = GetPlayerWeaponSlot(Giver, 3);
	HealingFirstAid[Giver] = FirstAidID;
	Stats_RecordScoreableSupportHolder(FirstAidFirstHolder, FirstAidID, Giver);
}

#define SUPPORT_ROUND_AWARD_LIMIT 2

stock bool:Stats_HasSupportAwardRoundStarted()
{
	if (CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return SurvivalStarted;

	return Isstart || L4D_HasAnySurvivorLeftSafeArea();
}

stock bool:Stats_TryConsumeSupportRoundAward(Giver, Recipient, AwardCount[])
{
	if (!Stats_HasSupportAwardRoundStarted())
		return false;

	if (!Stats_IsSurvivorHuman(Giver) || !Stats_IsSurvivorHuman(Recipient))
		return false;

	if (!Stats_IsRpgRoundValid())
		return false;

	if (AwardCount[Giver] >= SUPPORT_ROUND_AWARD_LIMIT)
		return false;

	AwardCount[Giver]++;
	return true;
}

stock bool:Stats_TryConsumeMedicineGiveAward(Giver, Recipient)
{
	return Stats_TryConsumeSupportRoundAward(Giver, Recipient, SupportMedicineAwardCount);
}

// Adrenaline give code. Special note, Adrenalines can only be given once. (Even if it's initially given by a bot!)

GiveAdrenaline(Giver, Recipient, AdrenalineID = -1)
{
	// Stats enabled is checked by the caller

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	if (!Stats_IsValidClient(Giver) || !Stats_IsValidClient(Recipient))
		return;

	if (AdrenalineID < 0)
		AdrenalineID = GetPlayerWeaponSlot(Recipient, 4);

	if (AdrenalineID < 0 || Adrenaline[AdrenalineID] == 1)
		return;
	else
		Adrenaline[AdrenalineID] = 1;

	if (!Stats_TryConsumeMedicineGiveAward(Giver, Recipient))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Adrenaline), 2, 4, TEAM_SURVIVORS);
	if(IsFunGame())
	{
		Score = 0;
		//return Plugin_Continue;
	}
	Score = NewPlayerBonus_ApplyScoreMultiplier(Giver, Score);

	decl String:ScoreFormula[MAX_MESSAGE_WIDTH];
	Format(ScoreFormula, sizeof(ScoreFormula), "base=l4d_stats_adrenaline,difficulty,target=%s,newbie_multiplier", RecipientID);
	Stats_ApplyClientScore(Giver, Score, "give_adrenaline", ScoreFormula, ", award_adrenaline = award_adrenaline + 1", true, TEAM_SURVIVORS);
	QuarterRank_RecordField(Giver, "award_adrenaline", 1);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "L4DStats_AdrenalineGivenSelf", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_AdrenalineGivenAll", GiverName, RecipientName, Score);
	}
}

// Pill give event. (From give a weapon)

public Action:event_GivePills(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled())
		return;

	// If given weapon != 12 (Pain Pills) then return
	if (GetEventInt(event, "weapon") != 12)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !GetConVarBool(cvar_EnableSvMedicPoints))
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "userid"));
	new Giver = GetClientOfUserId(GetEventInt(event, "giver"));
	new PillsID = GetEventInt(event, "weaponentid");

	GivePills(Giver, Recipient, PillsID);
}

// Pill give code. Special note, Pills can only be given once. (Even if it's initially given by a bot!)

GivePills(Giver, Recipient, PillsID = -1)
{
	// Stats enabled is checked by the caller

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && !SurvivalStarted)
		return;

	if (!Stats_IsValidClient(Giver) || !Stats_IsValidClient(Recipient))
		return;

	if (PillsID < 0)
		PillsID = GetPlayerWeaponSlot(Recipient, 4);

	if (PillsID < 0 || Pills[PillsID] == 1)
		return;
	else
		Pills[PillsID] = 1;

	if (!Stats_TryConsumeMedicineGiveAward(Giver, Recipient))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Pills), 2, 4, TEAM_SURVIVORS);
	if(IsFunGame())
	{
		Score = 0;
		//return Plugin_Continue;
	}
	Score = NewPlayerBonus_ApplyScoreMultiplier(Giver, Score);

	decl String:ScoreFormula[MAX_MESSAGE_WIDTH];
	Format(ScoreFormula, sizeof(ScoreFormula), "base=l4d_stats_pills,difficulty,target=%s,newbie_multiplier", RecipientID);
	Stats_ApplyClientScore(Giver, Score, "give_pills", ScoreFormula, ", award_pills = award_pills + 1", true, TEAM_SURVIVORS);
	QuarterRank_RecordField(Giver, "award_pills", 1);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);

		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "L4DStats_PillsGivenSelf", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_PillsGivenAll", GiverName, RecipientName, Score);
	}
}

// Defibrillator used code.

public Action:event_DefibPlayer(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && (!SurvivalStarted || !GetConVarBool(cvar_EnableSvMedicPoints)))
		return;

	if (!Stats_IsRpgRoundValid())
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "subject"));
	new Giver = GetClientOfUserId(GetEventInt(event, "userid"));

	new bool:GiverIsBot = IsClientBot(Giver);
	new bool:RecipientIsBot = IsClientBot(Recipient);

	if (CurrentGamemodeID != GAMEMODE_SURVIVAL && (!GiverIsBot || (GiverIsBot && (GetConVarInt(cvar_MedkitBotMode) >= 2 || (!RecipientIsBot && GetConVarInt(cvar_MedkitBotMode) >= 1)))))
	{
		MedkitsUsedCounter++;
		AnnounceMedkitPenalty();
	}

	// How is this possible?
	if (Recipient == Giver)
		return;

	if (!Stats_TryConsumeSupportRoundAward(Giver, Recipient, SupportDefibAwardCount))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));

	new Score = ModifyScoreDifficulty(GetConVarInt(cvar_Defib), 2, 4, TEAM_SURVIVORS);
	if(IsFunGame())
	{
		Score = 0;
		//return Plugin_Continue;
	}
	Score = NewPlayerBonus_ApplyScoreMultiplier(Giver, Score);

	decl String:ScoreFormula[MAX_MESSAGE_WIDTH];
	Format(ScoreFormula, sizeof(ScoreFormula), "base=l4d_stats_defib,difficulty,target=%s,newbie_multiplier", RecipientID);
	Stats_ApplyClientScore(Giver, Score, "defib_teammate", ScoreFormula, ", award_defib = award_defib + 1", true, TEAM_SURVIVORS);
	QuarterRank_RecordField(Giver, "award_defib", 1);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);
		if (Mode == 1 || Mode == 2)
			StatsPrintToChat(Giver, "L4DStats_DefibReviveSelf", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_DefibReviveAll", GiverName, RecipientName, Score);
	}
}

// Medkit give code.

public Action:event_HealPlayer(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	if (CurrentGamemodeID == GAMEMODE_SURVIVAL && (!SurvivalStarted || !GetConVarBool(cvar_EnableSvMedicPoints)))
		return;

	if (!Stats_IsRpgRoundValid())
		return;

	new Recipient = GetClientOfUserId(GetEventInt(event, "subject"));
	new Giver = GetClientOfUserId(GetEventInt(event, "userid"));
	new Amount = GetEventInt(event, "health_restored");

	new bool:GiverIsBot = IsClientBot(Giver);
	new bool:RecipientIsBot = IsClientBot(Recipient);

	if (CurrentGamemodeID != GAMEMODE_SURVIVAL && (!GiverIsBot || (GiverIsBot && (GetConVarInt(cvar_MedkitBotMode) >= 2 || (!RecipientIsBot && GetConVarInt(cvar_MedkitBotMode) >= 1)))))
	{
		MedkitsUsedCounter++;
		AnnounceMedkitPenalty();
	}

	if (GiverIsBot)
		return;

	if (Recipient == Giver)
		return;

	HealingFirstAid[Giver] = 0;

	if (!Stats_TryConsumeSupportRoundAward(Giver, Recipient, SupportMedkitAwardCount))
		return;

	decl String:RecipientName[MAX_LINE_WIDTH];
	GetClientName(Recipient, RecipientName, sizeof(RecipientName));
	decl String:RecipientID[MAX_LINE_WIDTH];
	GetClientRankAuthString(Recipient, RecipientID, sizeof(RecipientID));

	decl String:GiverName[MAX_LINE_WIDTH];
	GetClientName(Giver, GiverName, sizeof(GiverName));

	new Score = (Amount + 1) / 2;
	if (GetConVarInt(cvar_MedkitMode))
		Score = ModifyScoreDifficulty(GetConVarInt(cvar_Medkit), 2, 4, TEAM_SURVIVORS);
	else
		Score = ModifyScoreDifficulty(Score, 2, 3, TEAM_SURVIVORS);

	if(IsFunGame())
	{
		Score = 0;
		//return Plugin_Continue;
	}
	Score = NewPlayerBonus_ApplyScoreMultiplier(Giver, Score);

	decl String:ScoreFormula[MAX_MESSAGE_WIDTH];
	Format(ScoreFormula, sizeof(ScoreFormula), "base=health_restored/2_or_l4d_stats_medkit,difficulty,target=%s,amount=%i,newbie_multiplier", RecipientID, Amount);
	Stats_ApplyClientScore(Giver, Score, "heal_teammate", ScoreFormula, ", award_medkit = award_medkit + 1", true, TEAM_SURVIVORS);
	QuarterRank_RecordField(Giver, "award_medkit", 1);

	if (Score > 0)
	{
		new Mode = GetConVarInt(cvar_AnnounceMode);
		if (Mode == 1 || Mode == 2) 
			StatsPrintToChat(Giver, "L4DStats_HealTeammateSelf", RecipientName, Score);
		else if (Mode == 3)
			StatsPrintToChatAll("L4DStats_HealTeammateAll", GiverName, RecipientName, Score);
	}
}

// Friendly fire code.

public Action:event_FriendlyFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (StatsDisabled() || CampaignOver)
		return;

	new Attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new Victim = GetClientOfUserId(GetEventInt(event, "victim"));

	if (!Attacker || !Victim)
		return;

//	if (IsClientBot(Victim))
//		return;

	new FFMode = GetConVarInt(cvar_FriendlyFireMode);

	if (FFMode == 1)
	{
		new CooldownMode = GetConVarInt(cvar_FriendlyFireCooldownMode);

		if (CooldownMode == 1 || CooldownMode == 2)
		{
			new Target = 0;

			// Player specific : CooldownMode = 1
			// General : CooldownMode = 2
			if (CooldownMode == 1)
				Target = Victim;

			if (FriendlyFireCooldown[Attacker][Target])
				return;

			FriendlyFireCooldown[Attacker][Target] = true;

			if (FriendlyFirePrmCounter >= MAXPLAYERS)
				FriendlyFirePrmCounter = 0;

			FriendlyFirePrm[FriendlyFirePrmCounter][0] = Attacker;
			FriendlyFirePrm[FriendlyFirePrmCounter][1] = Target;
			FriendlyFireTimer[Attacker][Target] = CreateTimer(GetConVarFloat(cvar_FriendlyFireCooldown), timer_FriendlyFireCooldownEnd, FriendlyFirePrmCounter++);
		}
	}
	else if (FFMode == 2)
	{
		// Friendly fire is calculated in player_hurt event (Damage based)
		return;
	}

	UpdateFriendlyFire(Attacker, Victim);
}
