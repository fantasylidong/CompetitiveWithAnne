#if defined _l4d_stats_players_included
	#endinput
#endif
#define _l4d_stats_players_included

stock bool:Stats_IsValidClient(client)
{
	if (client <= 0 || client > MaxClients)
		return false;

	if (!IsClientConnected(client) || !IsClientInGame(client))
		return false;

	return true;
}

stock bool:Stats_ResolveQueryUserId(any:userid, &client)
{
	client = GetClientOfUserId(userid);
	return Stats_IsValidClient(client);
}

stock bool:Stats_ResolveHumanQueryUserId(any:userid, &client)
{
	client = GetClientOfUserId(userid);
	return Stats_IsValidHumanClient(client);
}

stock bool:Stats_ResolveHumanQueryAuth(any:userid, const String:SteamID[], &client)
{
	if (!Stats_ResolveHumanQueryUserId(userid, client))
		return false;

	if (Stats_IsInvalidRankAuthString(SteamID))
		return false;

	decl String:CurrentID[MAX_LINE_WIDTH];
	if (!GetClientRankAuthString(client, CurrentID, sizeof(CurrentID)))
		return false;

	return StrEqual(CurrentID, SteamID);
}

stock Handle:Stats_CreateClientIdentityPack(client, const String:SteamID[])
{
	new Handle:dp = CreateDataPack();
	WritePackCell(dp, GetClientUserId(client));
	WritePackString(dp, SteamID);
	return dp;
}

stock Stats_CloseQueryData(any:dp)
{
	if (dp != INVALID_HANDLE)
		CloseHandle(dp);
}

stock bool:Stats_ResolvePackedQueryClient(any:dp, &client)
{
	if (dp == INVALID_HANDLE)
		return false;

	ResetPack(dp);
	new userid = ReadPackCell(dp);
	if (!Stats_ResolveHumanQueryUserId(userid, client))
	{
		CloseHandle(dp);
		return false;
	}

	return true;
}

stock bool:Stats_BeginPackedClientQuery(any:dp, &client, Handle:hndl, const String:error[], const String:context[])
{
	if (hndl == INVALID_HANDLE)
	{
		Stats_CloseQueryData(dp);
		LogError("%s Query failed: %s", context, error);
		return false;
	}

	return Stats_ResolvePackedQueryClient(dp, client);
}

stock Stats_ClientFromEntityOrUserId(value)
{
	if (Stats_IsValidClient(value))
		return value;

	return GetClientOfUserId(value);
}

stock bool:Stats_IsRpgRoundValid()
{
	return !g_brpgAvailable || L4D_RPG_GetGlobalValue(INDEX_VALID);
}

// 统一的人类玩家校验入口。
// 旧代码里同类判断分散在事件中，新模块尽量先复用这里，减少以后扩展奖励时漏判 bot/未进服玩家。
stock bool:Stats_IsValidHumanClient(client)
{
	if (!Stats_IsValidClient(client))
		return false;

	if (IsClientBot(client))
		return false;

	return true;
}

stock Stats_FindHumanClientBySteamID(const String:SteamID[])
{
	if (Stats_IsInvalidRankAuthString(SteamID))
		return 0;

	decl String:CurrentID[MAX_LINE_WIDTH];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!Stats_IsValidHumanClient(i))
			continue;

		if (!GetClientRankAuthString(i, CurrentID, sizeof(CurrentID)))
			continue;

		if (StrEqual(CurrentID, SteamID))
			return i;
	}

	return 0;
}

stock Stats_CancelDatabaseClearConfirm()
{
	ClearDatabaseCaller = -1;

	if (ClearDatabaseTimer != INVALID_HANDLE)
	{
		CloseHandle(ClearDatabaseTimer);
		ClearDatabaseTimer = INVALID_HANDLE;
	}
}

// 有效且正在幸存者队伍的人类玩家。
stock bool:Stats_IsSurvivorHuman(client)
{
	return Stats_IsValidHumanClient(client) && GetClientTeam(client) == TEAM_SURVIVORS;
}

// 有效且正在感染者队伍的人类玩家。
stock bool:Stats_IsInfectedHuman(client)
{
	return Stats_IsValidHumanClient(client) && GetClientTeam(client) == TEAM_INFECTED;
}

// 正在参与本局的人类玩家；旁观者不计入计分人数门槛。
stock bool:Stats_IsPlayingHuman(client)
{
	if (!Stats_IsValidHumanClient(client))
		return false;

	new team = GetClientTeam(client);
	return team == TEAM_SURVIVORS || team == TEAM_INFECTED;
}

stock Stats_CountPlayingHumans()
{
	new humans = 0;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (Stats_IsPlayingHuman(i))
			humans++;
	}

	return humans;
}

stock bool:Stats_HasPlaytimeStarted()
{
	if (CurrentGamemodeID == GAMEMODE_SURVIVAL)
		return SurvivalStarted;

	if (CurrentGamemodeID == GAMEMODE_SCAVENGE)
		return g_bStatsPlaytimeStarted;

	return g_bStatsPlaytimeStarted || L4D_HasAnySurvivorLeftSafeArea();
}

stock bool:Stats_ShouldCountClientPlaytime(Client)
{
	if (!Stats_HasPlaytimeStarted() || !Stats_IsValidHumanClient(Client))
		return false;

	new team = GetClientTeam(Client);
	return team == TEAM_SURVIVORS || team == TEAM_INFECTED;
}

stock Stats_ClearRoundParticipant(client)
{
	if (client <= 0 || client > MaxClients)
		return;

	ClientEnabled[client] = false;
	ClientEnabledAuth[client][0] = '\0';
}

stock bool:Stats_MarkRoundParticipant(client)
{
	if (!Stats_IsSurvivorHuman(client))
		return false;

	decl String:ClientID[MAX_LINE_WIDTH];
	if (!GetClientRankAuthString(client, ClientID, sizeof(ClientID)))
		return false;

	ClientEnabled[client] = true;
	strcopy(ClientEnabledAuth[client], sizeof(ClientEnabledAuth[]), ClientID);
	return true;
}

stock bool:Stats_IsRoundParticipant(client)
{
	if (!ClientEnabled[client] || !Stats_IsValidHumanClient(client))
		return false;

	decl String:ClientID[MAX_LINE_WIDTH];
	if (!GetClientRankAuthString(client, ClientID, sizeof(ClientID)))
		return false;

	return StrEqual(ClientEnabledAuth[client], ClientID);
}
