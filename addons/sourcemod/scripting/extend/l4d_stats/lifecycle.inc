#if defined _l4d_stats_lifecycle_included
	#endinput
#endif
#define _l4d_stats_lifecycle_included

// 地图、玩家连接/断开和 ConVar 变化生命周期。

// Reset all boolean variables when a map changes.

public OnMapStart()
{
	if (MapChangingForConnectAnnounce)
	{
		CreateTimer(CONNECT_ANNOUNCE_MAPCHANGE_GRACE, Timer_ResetConnectAnnounceMapChange, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	GetConVarString(cvar_Gamemode, CurrentGamemode, sizeof(CurrentGamemode));
	CurrentGamemodeID = GetCurrentGamemodeID();
	SetCurrentGamemodeName();
	QuarterRank_EnsureCurrentQuarter();
	ResetVars();
}

// Init player on connect, and update total rank and client rank.

public OnClientPostAdminCheck(client)
{
	Stats_ClearRoundParticipant(client);

	if (db == INVALID_HANDLE)
	{
		return;
	}

	InitializeClientInf(client);
	PostAdminCheckRetryCounter[client] = 0;

	if (IsClientBot(client))
	{
		return;
	}

	CreateTimer(1.0, ClientPostAdminCheck, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:ClientPostAdminCheck(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client <= 0 || IsClientBot(client))
		return;

	if (!IsClientInGame(client))
	{
		if (PostAdminCheckRetryCounter[client]++ < 10)
		{
			CreateTimer(3.0, ClientPostAdminCheck, userid, TIMER_FLAG_NO_MAPCHANGE);
		}

		return;
	}

	StartRankChangeCheck(client);

	decl String:SteamID[MAX_LINE_WIDTH];
	GetClientRankAuthString(client, SteamID, sizeof(SteamID));

	QueryClientNewPlayerBonusData(client, SteamID);
	CheckPlayerDB(client);
	QuarterRank_QueryClient(client);

	TimerPoints[client] = 0;
	TimerKills[client] = 0;
	TimerHeadshots[client] = 0;

	new bool:AlreadyAnnounced = false;
	if (ConnectAnnounceTrie != INVALID_HANDLE)
	{
		GetTrieValue(ConnectAnnounceTrie, SteamID, AlreadyAnnounced);
	}

	if (!AlreadyAnnounced)
	{
		if (ConnectAnnounceTrie != INVALID_HANDLE)
		{
			SetTrieValue(ConnectAnnounceTrie, SteamID, true);
		}

		CreateTimer(10.0, RankConnect, userid, TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(15.0, AnnounceConnect, userid, TIMER_FLAG_NO_MAPCHANGE);

		AnnouncePlayerConnect(client);
	}

	ConnectAnnouncePendingDisconnect[client][0] = '\0';
}

public Action:Timer_ResetConnectAnnounceMapChange(Handle:timer)
{
	MapChangingForConnectAnnounce = false;

	if (ConnectAnnounceTrie != INVALID_HANDLE)
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (ConnectAnnouncePendingDisconnect[i][0] == '\0')
			{
				continue;
			}

			if (!IsClientConnected(i))
			{
				RemoveFromTrie(ConnectAnnounceTrie, ConnectAnnouncePendingDisconnect[i]);
			}

			ConnectAnnouncePendingDisconnect[i][0] = '\0';
		}
	}

	return Plugin_Stop;
}

public OnPluginEnd()
{
	if (db == INVALID_HANDLE)
	{
		ScoreLog_FlushNow();
		return;
	}

	new maxplayers = MaxClients;

	for (new i = 1; i <= maxplayers; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
		{
			switch (GetClientTeam(i))
			{
				case TEAM_SURVIVORS:
					InterstitialPlayerUpdate(i);
				case TEAM_INFECTED:
					DoInfectedFinalChecks(i);
			}
		}
	}

	ScoreLog_FlushNow();

	CloseHandle(db);
	db = INVALID_HANDLE;

	CommandsRegistered = false;

	//if (ClearPlayerMenu != INVALID_HANDLE)
	//{
	//	CloseHandle(ClearPlayerMenu);
	//	ClearPlayerMenu = INVALID_HANDLE;
	//}
	delete MapTimingSurvivors;
	delete MapTimingInfected;
	delete FriendlyFireDamageTrie;
	delete ConnectAnnounceTrie;
}

// Show rank on connect.

public Action:RankConnect(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client <= 0 || IsClientBot(client))
		return;

	if (GetConVarBool(cvar_RankOnJoin) && !InvalidGameMode())
	{
		cmd_ShowRank(client, 0);
	}
}

// Announce on player connect!

public Action:AnnounceConnect(Handle:timer, any:userid)
{
	if (!GetConVarBool(cvar_AnnounceMode))
	{
		return;
	}

	new client = GetClientOfUserId(userid);
	if (client <= 0 || IsClientBot(client))
		return;

	if (!IsClientConnected(client) || !IsClientInGame(client))
	{
		if (AnnounceCounter[client] > 10)
		{
			AnnounceCounter[client] = 0;
		}
		else
		{
			AnnounceCounter[client]++;
			CreateTimer(5.0, AnnounceConnect, userid, TIMER_FLAG_NO_MAPCHANGE);
		}

		return;
	}

	AnnounceCounter[client]++;
	Call_StartForward(AnnounceGameTime);//转发触发
	Call_PushCell(client);//按顺序将参数push进forward传参列表里
	Call_Finish();//转发结束

	ShowMOTD(client);
	StatsPrintToChat2(client, true, "L4DStats_RankMenuHint");
}

// Update the player's interstitial stats, since they may have
// gotten points between the last update and when they disconnect.

stock Stats_ClearClientSlotCaches(client)
{
	if (client <= 0 || client > MaxClients)
		return;

	TimerPoints[client] = 0;
	TimerKills[client] = 0;
	TimerHeadshots[client] = 0;

	ClientRank[client] = 0;
	ClientNextRank[client] = 0;
	ClientPoints[client] = 0;
	ClientScoreReady[client] = false;
	ClientPlayTime[client] = 0;
	ClientGameModeRank[client] = 0;
	ClientRankMute[client] = false;
	CurrentPoints[client] = 0;
	ClientMapTime[client] = 0.0;
	MapTimingMenuInfo[client][0] = '\0';
	AnnounceCounter[client] = 0;
	PostAdminCheckRetryCounter[client] = 0;
	RankChangeLastRank[client] = 0;
	RankChangeFirstCheck[client] = true;
	QuarterRankChangeLastRank[client] = 0;
	QuarterRankChangeFirstCheck[client] = true;
	ClientQuarterPoints[client] = 0;
	ClientQuarterPlayTime[client] = 0;
	ClientQuarterRank[client] = 0;

	new i;
	for (i = 0; i < GAMEMODES; i++)
		ClientGameModePoints[client][i] = 0;

	BoomerHitCounter[client] = 0;
	BoomerVomitUpdated[client] = false;
	InfectedDamageCounter[client] = 0;
	SmokerDamageCounter[client] = 0;
	SpitterDamageCounter[client] = 0;
	JockeyDamageCounter[client] = 0;
	ChargerDamageCounter[client] = 0;
	ChargerImpactCounter[client] = 0;
	TankPointsCounter[client] = 0;
	TankDamageCounter[client] = 0;
	TankDamageTotalCounter[client] = 0;
	TankSurvivorKillCounter[client] = 0;
	ClientInfectedType[client] = 0;
	MeleeKillCounter[client] = 0;
	ProtectedFriendlyCounter[client] = 0;
	SupportMedicineAwardCount[client] = 0;
	SupportMedkitAwardCount[client] = 0;
	SupportReviveAwardCount[client] = 0;
	SupportDefibAwardCount[client] = 0;

	if (TimerRankChangeCheck[client] != INVALID_HANDLE)
	{
		CloseHandle(TimerRankChangeCheck[client]);
		TimerRankChangeCheck[client] = INVALID_HANDLE;
	}

	if (MeleeKillTimer[client] != INVALID_HANDLE)
	{
		CloseHandle(MeleeKillTimer[client]);
		MeleeKillTimer[client] = INVALID_HANDLE;
	}

	if (TimerBoomerPerfectCheck[client] != INVALID_HANDLE)
	{
		CloseHandle(TimerBoomerPerfectCheck[client]);
		TimerBoomerPerfectCheck[client] = INVALID_HANDLE;
	}

	if (TimerInfectedDamageCheck[client] != INVALID_HANDLE)
	{
		CloseHandle(TimerInfectedDamageCheck[client]);
		TimerInfectedDamageCheck[client] = INVALID_HANDLE;
	}

	if (ChargerImpactCounterTimer[client] != INVALID_HANDLE)
	{
		CloseHandle(ChargerImpactCounterTimer[client]);
		ChargerImpactCounterTimer[client] = INVALID_HANDLE;
	}

	if (TimerProtectedFriendly[client] != INVALID_HANDLE)
	{
		CloseHandle(TimerProtectedFriendly[client]);
		TimerProtectedFriendly[client] = INVALID_HANDLE;
	}

	for (i = 0; i <= MaxClients; i++)
	{
		FriendlyFireCooldown[client][i] = false;
		FriendlyFireCooldown[i][client] = false;
		// 友伤延迟结算定时器仍按发起时 SteamID 写库，断线后不能 CloseHandle，否则会让惩罚丢失。
		FriendlyFireTimer[client][i] = INVALID_HANDLE;
		FriendlyFireTimer[i][client] = INVALID_HANDLE;
	}
}

public OnClientDisconnect(client)
{
	new bool:IsBot = IsClientBot(client);

	Stats_ClearRoundParticipant(client);
	InitializeClientInf(client);
	NewPlayerBonus_ResetClientData(client);

	if (TimerRankChangeCheck[client] != INVALID_HANDLE)
		CloseHandle(TimerRankChangeCheck[client]);

	TimerRankChangeCheck[client] = INVALID_HANDLE;

	if (ClearDatabaseCaller > 0 && ClearDatabaseCaller == GetClientUserId(client))
		Stats_CancelDatabaseClearConfirm();

	if (!IsBot)
	{
		decl String:ClientID[MAX_LINE_WIDTH];
		GetClientRankAuthString(client, ClientID, sizeof(ClientID));
		if (!MapChangingForConnectAnnounce && ConnectAnnounceTrie != INVALID_HANDLE)
		{
			RemoveFromTrie(ConnectAnnounceTrie, ClientID);
		}
		else if (MapChangingForConnectAnnounce)
		{
			strcopy(ConnectAnnouncePendingDisconnect[client], sizeof(ConnectAnnouncePendingDisconnect[]), ClientID);
		}

		if (MapTimingStartTime >= 0.0)
		{
			RemoveFromTrie(MapTimingSurvivors, ClientID);
			RemoveFromTrie(MapTimingInfected, ClientID);
		}

		if (IsClientInGame(client))
		{
			switch (GetClientTeam(client))
			{
				case TEAM_SURVIVORS:
					InterstitialPlayerUpdate(client);
				case TEAM_INFECTED:
					DoInfectedFinalChecks(client);
			}
		}
	}

	new bool:HumansRemain = false;
	if (!IsBot)
	{
		new maxplayers = MaxClients;
		for (new i = 1; i <= maxplayers; i++)
		{
			if (i != client && IsClientConnected(i) && IsClientInGame(i) && !IsClientBot(i))
			{
				HumansRemain = true;
				break;
			}
		}
	}

	Stats_ClearClientSlotCaches(client);

	if (IsBot || HumansRemain)
		return;

	// If we get this far, ALL HUMAN PLAYERS LEFT THE SERVER
	CampaignOver = true;
}

public action_LanChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (GetConVarInt(cvar_Lan))
		LogMessage("ATTENTION! %s in LAN environment is based on IP address rather than Steam ID. The statistics are not reliable when they are base on IP!", PLUGIN_NAME);
}

// Update the Database prefix when the Cvar is changed.

public action_DbPrefixChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_DbPrefix)
	{
		if (!StrEqual(DbPrefix, newValue))
		{
			ScoreLog_FlushNow();
			strcopy(DbPrefix, sizeof(DbPrefix), newValue);
		}
	}
}

// Update the Update Timer when the Cvar is changed.

public action_TimerChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_UpdateRate)
	{
		CloseHandle(UpdateTimer);

		new NewTime = StringToInt(newValue);
		UpdateTimer = CreateTimer(float(NewTime), timer_ShowTimerScore, INVALID_HANDLE, TIMER_REPEAT);
	}
}

// Update the CurrentGamemode when the Cvar is changed.

public action_DifficultyChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_Difficulty)
	{
		MapTimingStartTime = -1.0;
		MapTimingBlocked = true;
	}
}

// Update the CurrentGamemode when the Cvar is changed.

public action_GamemodeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (convar == cvar_Gamemode)
	{
		GetConVarString(cvar_Gamemode, CurrentGamemode, sizeof(CurrentGamemode));
		CurrentGamemodeID = GetCurrentGamemodeID();
		SetCurrentGamemodeName();
	}
}
