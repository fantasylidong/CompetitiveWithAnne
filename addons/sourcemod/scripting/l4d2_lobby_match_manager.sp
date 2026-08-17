/*
## 关于动态大厅
大厅的部分信息是保存在客户端，最先进入服务器的玩家是大厅厅长(CSysSessionHost)，其他玩家加入服务器会和大厅厅长通信，判断是否能进入服务器(CSysSessionHost::Process_RequestJoinData)
大厅厅长那边的数据如何更新和继承尚不清楚，这些都发生在客户端运行的 matchmaking.so 中，服务端无法干涉。
在客户端启动项参数加上-debug -dev，客户端控制台输入 mm_debugprint 命令会看到更多信息
*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <sourcescramble>			// https://github.com/nosoop/SMExt-SourceScramble
#include <l4d2_source_keyvalues>	// https://github.com/fdxx/l4d2_source_keyvalues
#include <l4d2_lobby_match_manager_policy>

#define VERSION "0.14"

#define RMFLAG_NO_MODE_CHANGE			1
#define RMFLAG_NO_DIFFICULTY_CHANGE		2
#define RMFLAG_FORCE_ACCESS_PUBLIC		4	// private, friends -> public
#define RMFLAG_FORCE_OFFICIAL_MAP		8	// unofficial map -> official map

#define MAX_COOKIE_LENGTH	20

enum LobbyState
{
	LobbyState_IdleUnreserved,
	LobbyState_MatchmakingReserved,
	LobbyState_ActiveDirect,
	LobbyState_Released
};

ConVar
	mp_gamemode,
	z_difficulty,
	sv_allow_lobby_connect_only,
	sv_hosting_lobby,
	sv_reservation_timeout,
	g_cvUnreserveType,
	g_cvReserveModifyFlags;

char
	g_sGameMode[64],
	g_sDifficulty[64];

MemoryPatch
	g_mBlockReserve;

int
	g_iUnreserveType,
	g_iReserveModifyFlags;

bool
	g_bDependenciesReady,
	g_bLobbyReservationObserved,
	g_bHumanClient[MAXPLAYERS + 1];

LobbyState
	g_eLobbyState = LobbyState_IdleUnreserved;

Address
	g_pMatchExtL4D,
	g_pReservationCookie;

Handle
	g_hSDKUpdateGameType,
	g_hSDKGetGameModeInfo,
	g_hSDKGetMapInfo;

DynamicDetour
	g_hApplyGameSettingsDetour,
	g_hReplyReservationRequestDetour;

public Plugin myinfo = 
{
	name = "L4D2 Lobby match manager",
	author = "fdxx",
	version = VERSION,
	url = "https://github.com/fdxx/l4d2_plugins"
};

public void OnPluginStart()
{
	Init();

	mp_gamemode = FindConVar("mp_gamemode");
	z_difficulty = FindConVar("z_difficulty");
	sv_allow_lobby_connect_only = FindConVar("sv_allow_lobby_connect_only");
	sv_hosting_lobby = FindConVar("sv_hosting_lobby");
	sv_reservation_timeout = FindConVar("sv_reservation_timeout");

	CreateConVar("l4d2_lobby_match_manager_version", VERSION, "version", FCVAR_NONE | FCVAR_DONTRECORD);
	g_cvUnreserveType =			CreateConVar("l4d2_lmm_unreserve_type",				"0",	"Direct joins never create reservations. 0=Keep pre-existing reservation, 1=Anne mode: keep pre-existing reservation until the third player joins, 2=Unreserve when lobby full, 3=Clear stale reservation while empty.");
	g_cvReserveModifyFlags =	CreateConVar("l4d2_lmm_reservation_modify_flags",	"7",	"Modify the lobby settings applied by the client to the server.\nSee RMFLAG_* (need cvar l4d2_lmm_unreserve_type != 1).");
	
	mp_gamemode.AddChangeHook(OnConVarChanged);
	z_difficulty.AddChangeHook(OnConVarChanged);
	g_cvUnreserveType.AddChangeHook(OnConVarChanged);
	g_cvReserveModifyFlags.AddChangeHook(OnConVarChanged);

	RegAdminCmd("sm_lobby_status", Cmd_Status, ADMFLAG_ROOT);
	RegAdminCmd("sm_lobby_set", Cmd_Set, ADMFLAG_ROOT);
	RegServerCmd("sm_lobby_unreserve", Cmd_Unreserve, "Remove the lobby reservation so more players can join.");
}

public void OnAllPluginsLoaded()
{
	// Nested shared-plugin dependencies are not fully native-bound during OnPluginStart.
	g_bDependenciesReady = true;
	RefreshCachedConVars();
	RebuildLobbyStateFromEngine("plugins_loaded");
	EvaluateLobbyReleasePolicy();
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_bDependenciesReady)
		return;

	RefreshCachedConVars();
	ReconcileLobbyState("cvar_changed");
	EvaluateLobbyReleasePolicy();
}

void RefreshCachedConVars()
{
	mp_gamemode.GetString(g_sGameMode, sizeof(g_sGameMode));
	z_difficulty.GetString(g_sDifficulty, sizeof(g_sDifficulty));
	g_iUnreserveType = g_cvUnreserveType.IntValue;
	g_iReserveModifyFlags = g_cvReserveModifyFlags.IntValue;
}

public void OnConfigsExecuted()
{
	sv_reservation_timeout.IntValue = 30;
	RefreshCachedConVars();
	ReconcileLobbyState("configs_executed");
	EvaluateLobbyReleasePolicy();
}

public void OnMapStart()
{
	RequestFrame(Frame_ReconcileLobbyState);
}

void Frame_ReconcileLobbyState(any data)
{
	if (!g_bDependenciesReady)
		return;

	ReconcileLobbyState("map_start");
	EvaluateLobbyReleasePolicy();
}

public void OnPluginEnd()
{
	if (g_hApplyGameSettingsDetour != null)
		g_hApplyGameSettingsDetour.Disable(Hook_Pre, OnApplyGameSettingsPre);
	if (g_hReplyReservationRequestDetour != null)
		g_hReplyReservationRequestDetour.Disable(Hook_Post, OnReplyReservationRequestPost);

	g_mBlockReserve.Disable();
}

MRESReturn OnApplyGameSettingsPre(Address pThis, DHookParam hParams)
{
	if (!g_bDependenciesReady || hParams.IsNull(1))
		return MRES_Ignored;

	char sBuffer[256];
	SourceKeyValues kv = view_as<SourceKeyValues>(hParams.GetAddress(1));

	kv.GetName(sBuffer, sizeof(sBuffer));
	if (strcmp(sBuffer, "left4dead2", false)) // Exclude ExecGameTypeCfg
		return MRES_Ignored;

	g_bLobbyReservationObserved = true;

	if (g_iUnreserveType == UNRESERVE_ANNE)
	{
		RefreshReserveBlockPatch();
		return MRES_Ignored;
	}

	if (!g_iReserveModifyFlags)
		return MRES_Ignored;

	if (g_iReserveModifyFlags & RMFLAG_NO_MODE_CHANGE)
		kv.SetString("Game/mode", g_sGameMode);

	if (g_iReserveModifyFlags & RMFLAG_NO_DIFFICULTY_CHANGE)
		kv.SetString("Game/difficulty", g_sDifficulty);

	if (g_iReserveModifyFlags & RMFLAG_FORCE_ACCESS_PUBLIC)
		kv.SetString("System/access", "public");

	if (g_iReserveModifyFlags & RMFLAG_FORCE_OFFICIAL_MAP)
	{
		if (IsNeedForceOfficialMap(kv))
		{
			kv.SetString("Game/campaign", "L4D2C2");
			kv.SetInt("Game/chapter", 1);
		}
	}

	return MRES_Ignored;
}

MRESReturn OnReplyReservationRequestPost(Address pThis, DHookParam hParams)
{
	if (!g_bDependenciesReady)
		return MRES_Ignored;

	if (!HasReservationCookie())
		return MRES_Ignored;

	if (g_eLobbyState == LobbyState_IdleUnreserved && GetPlayerCount() == 0)
	{
		TransitionLobbyState(LobbyState_MatchmakingReserved, "reservation_accepted");
	}
	else if (g_eLobbyState == LobbyState_MatchmakingReserved)
	{
		ApplyLobbyState();
	}
	else if (g_eLobbyState == LobbyState_ActiveDirect || g_eLobbyState == LobbyState_Released)
	{
		ApplyLobbyState();
	}

	return MRES_Ignored;
}

bool IsNeedForceOfficialMap(SourceKeyValues kvSettings)
{
	char sApplyCampaign[256], sApplyMap[256], sCurMap[256];
	kvSettings.GetString("Game/campaign", sApplyCampaign, sizeof(sApplyCampaign));

	// Allow changes to official maps.
	if (!strncmp(sApplyCampaign, "L4D2C", 5, false))
		return false;

	SourceKeyValues kvMapInfo = SDKCall(g_hSDKGetMapInfo, g_pMatchExtL4D, kvSettings, 0);
	if (!kvMapInfo)
		return false;

	kvMapInfo.GetString("Map", sApplyMap, sizeof(sApplyMap));
	GetCurrentMap(sCurMap, sizeof(sCurMap));

	// if the client changed the map.
	return strcmp(sApplyMap, sCurMap) != 0;
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	if (!g_bDependenciesReady)
		return true;

	if (IsFakeClient(client))
		return true;

	g_bHumanClient[client] = true;

	if (g_eLobbyState == LobbyState_IdleUnreserved && HasReservationCookie())
		TransitionLobbyState(LobbyState_MatchmakingReserved, "reservation_before_connect");
	else
		ReconcileLobbyState("client_connect");

	if (g_eLobbyState == LobbyState_IdleUnreserved)
	{
		TransitionLobbyState(LobbyState_ActiveDirect, "direct_connect");
		CreateTimer(5.0, Timer_ReconcilePendingDirectConnect, _, TIMER_FLAG_NO_MAPCHANGE);
	}

	return true;
}

public void OnClientPutInServer(int client)
{
	if (!g_bDependenciesReady)
		return;

	if (IsFakeClient(client))
		return;

	g_bHumanClient[client] = true;
	ReconcileLobbyState("client_put_in_server");

	if (g_eLobbyState == LobbyState_IdleUnreserved)
		TransitionLobbyState(LobbyState_ActiveDirect, "direct_put_in_server");
	else if (g_eLobbyState == LobbyState_ActiveDirect || g_eLobbyState == LobbyState_Released)
		ApplyLobbyState();

	if (g_eLobbyState == LobbyState_MatchmakingReserved)
		CreateTimer(1.0, Timer_EvaluateLobbyRelease, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
	if (!IsFakeClient(client))
		g_bHumanClient[client] = true;
}

public void OnClientDisconnect_Post(int client)
{
	bool wasHuman = g_bHumanClient[client];
	g_bHumanClient[client] = false;

	if (!g_bDependenciesReady || !wasHuman || GetPlayerCount() > 0)
		return;

	if (g_eLobbyState == LobbyState_MatchmakingReserved && HasReservationCookie() && g_iUnreserveType != UNRESERVE_DEFAULT_EMPTY)
	{
		ApplyLobbyState();
		CreateTimer(float(sv_reservation_timeout.IntValue + 1), Timer_ReconcileEmptyReservation, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else
	{
		TransitionLobbyState(LobbyState_IdleUnreserved, "server_empty");
	}
}

Action Timer_ReconcilePendingDirectConnect(Handle timer)
{
	if (g_eLobbyState == LobbyState_ActiveDirect && GetPlayerCount() == 0)
		TransitionLobbyState(LobbyState_IdleUnreserved, "direct_connect_abandoned");
	return Plugin_Stop;
}

Action Timer_ReconcileEmptyReservation(Handle timer)
{
	if (GetPlayerCount() == 0 && g_eLobbyState == LobbyState_MatchmakingReserved && !HasReservationCookie())
		TransitionLobbyState(LobbyState_IdleUnreserved, "reservation_timeout");
	return Plugin_Stop;
}

Action Timer_EvaluateLobbyRelease(Handle timer)
{
	EvaluateLobbyReleasePolicy();
	return Plugin_Stop;
}

void EvaluateLobbyReleasePolicy()
{
	ReconcileLobbyState("release_policy");

	if (g_eLobbyState != LobbyState_MatchmakingReserved)
		return;

	int playerCount = GetPlayerCount();
	if (LobbyPolicy_ShouldClearOnJoin(g_iUnreserveType, playerCount, GetMaxLobbySlots(g_sGameMode), false))
	{
		TransitionLobbyState(LobbyState_Released, "join_release_policy");
		return;
	}

	if (LobbyPolicy_ShouldClearDefaultReservation(g_iUnreserveType, playerCount, false, g_bLobbyReservationObserved))
		TransitionLobbyState(LobbyState_IdleUnreserved, "default_empty_policy");
}

void RebuildLobbyStateFromEngine(const char[] reason)
{
	if (HasReservationCookie())
	{
		TransitionLobbyState(LobbyState_MatchmakingReserved, reason);
	}
	else if (GetPlayerCount() > 0)
	{
		TransitionLobbyState(LobbyState_ActiveDirect, reason);
	}
	else
	{
		TransitionLobbyState(LobbyState_IdleUnreserved, reason);
	}
}

void ReconcileLobbyState(const char[] reason)
{
	int playerCount = GetPlayerCount();
	bool hasReservation = HasReservationCookie();

	switch (g_eLobbyState)
	{
		case LobbyState_IdleUnreserved:
		{
			if (hasReservation && playerCount == 0)
				TransitionLobbyState(LobbyState_MatchmakingReserved, reason);
			else if (playerCount > 0)
				TransitionLobbyState(LobbyState_ActiveDirect, reason);
			else
				ApplyLobbyState();
		}
		case LobbyState_MatchmakingReserved:
		{
			if (!hasReservation)
				TransitionLobbyState(playerCount > 0 ? LobbyState_ActiveDirect : LobbyState_IdleUnreserved, reason);
			else
				ApplyLobbyState();
		}
		case LobbyState_ActiveDirect, LobbyState_Released:
		{
			if (playerCount == 0)
				TransitionLobbyState(LobbyState_IdleUnreserved, reason);
			else
				ApplyLobbyState();
		}
	}
}

void TransitionLobbyState(LobbyState nextState, const char[] reason)
{
	LobbyState previousState = g_eLobbyState;
	g_eLobbyState = nextState;

	if (previousState != nextState)
	{
		char previousName[32], nextName[32];
		GetLobbyStateName(previousState, previousName, sizeof(previousName));
		GetLobbyStateName(nextState, nextName, sizeof(nextName));
		LogMessage("[LMM] state %s -> %s, reason=%s, players=%d, cookie=%d", previousName, nextName, reason, GetPlayerCount(), HasReservationCookie());
	}

	ApplyLobbyState();
}

void ApplyLobbyState()
{
	if (g_eLobbyState == LobbyState_MatchmakingReserved)
	{
		if (HasReservationCookie())
		{
			sv_hosting_lobby.BoolValue = true;
			g_bLobbyReservationObserved = true;
			SDKCall(g_hSDKUpdateGameType);
		}
	}
	else
	{
		sv_allow_lobby_connect_only.BoolValue = false;
		SetReservationCookie(false);
	}

	RefreshReserveBlockPatch();
}

void RefreshReserveBlockPatch()
{
	g_mBlockReserve.Disable();

	if (g_eLobbyState != LobbyState_ActiveDirect && g_eLobbyState != LobbyState_Released)
		return;

	if (!g_mBlockReserve.Enable())
		SetFailState("Failed to enable patch.");
}

void GetLobbyStateName(LobbyState state, char[] buffer, int maxlen)
{
	switch (state)
	{
		case LobbyState_IdleUnreserved:
			strcopy(buffer, maxlen, "IdleUnreserved");
		case LobbyState_MatchmakingReserved:
			strcopy(buffer, maxlen, "MatchmakingReserved");
		case LobbyState_ActiveDirect:
			strcopy(buffer, maxlen, "ActiveDirect");
		case LobbyState_Released:
			strcopy(buffer, maxlen, "Released");
	}
}

Action Cmd_Status(int client, int args)
{
	int iCookie[2];
	char sCookie[MAX_COOKIE_LENGTH], stateName[32];

	GetReservationCookie(iCookie);
	GetLobbyStateName(g_eLobbyState, stateName, sizeof(stateName));
	if (iCookie[1])
		FormatEx(sCookie, sizeof(sCookie), "%x%08x", iCookie[1], iCookie[0]);
	else 
		FormatEx(sCookie, sizeof(sCookie), "%x", iCookie[0]);

	ReplyToCommand(client, "state = %s, unreserveType = %i, players = %i, maxLobbySlots = %i, reservationObserved = %i, sv_hosting_lobby = %i, sv_allow_lobby_connect_only = %i, cookie = %s", stateName, g_iUnreserveType, GetPlayerCount(), GetMaxLobbySlots(g_sGameMode), g_bLobbyReservationObserved, sv_hosting_lobby.IntValue, sv_allow_lobby_connect_only.IntValue, sCookie);
	return Plugin_Handled;
}

Action Cmd_Unreserve(int args)
{
	if (!g_bDependenciesReady)
		return Plugin_Handled;

	TransitionLobbyState(GetPlayerCount() > 0 ? LobbyState_Released : LobbyState_IdleUnreserved, "admin_unreserve");
	return Plugin_Handled;
}

Action Cmd_Set(int client, int args)
{
	if (args != 4)
	{
		ReplyToCommand(client, "sm_lobby_set sCookie bAllowLobbyConnectOnly bHostingLobby bUpdateGameType");
		return Plugin_Handled;
	}

	int iCookie[2];
	char sCookie[MAX_COOKIE_LENGTH];

	GetCmdArg(1, sCookie, sizeof(sCookie));
	StringToInt64(sCookie, iCookie, 16);
	StoreToAddress(g_pReservationCookie, iCookie[0], NumberType_Int32);
	StoreToAddress(g_pReservationCookie + view_as<Address>(4), iCookie[1], NumberType_Int32);

	sv_allow_lobby_connect_only.BoolValue = GetCmdArgInt(2) > 0;
	sv_hosting_lobby.BoolValue = GetCmdArgInt(3) > 0;
	
	if (GetCmdArgInt(4) > 0)
		SDKCall(g_hSDKUpdateGameType);

	if (HasReservationCookie())
		TransitionLobbyState(LobbyState_MatchmakingReserved, "admin_set");
	else
		TransitionLobbyState(GetPlayerCount() > 0 ? LobbyState_Released : LobbyState_IdleUnreserved, "admin_set");

	Cmd_Status(client, 0);
	return Plugin_Handled;
}

int GetPlayerCount(int exclude = 0)
{
	int iPlayers;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i != exclude && IsClientConnected(i) && !IsFakeClient(i))
			iPlayers++;
	}
	return iPlayers;
}

int GetMaxLobbySlots(const char[] mode)
{
	SourceKeyValues kv = SDKCall(g_hSDKGetGameModeInfo, g_pMatchExtL4D, mode);
	if (kv)
		return kv.GetInt("maxplayers", 4);
	return 4;
}

void GetReservationCookie(int cookie[2])
{
	cookie[0] = LoadFromAddress(g_pReservationCookie, NumberType_Int32);
	cookie[1] = LoadFromAddress(g_pReservationCookie + view_as<Address>(4), NumberType_Int32);
}

bool HasReservationCookie()
{
	int cookie[2];
	GetReservationCookie(cookie);
	return cookie[0] != 0 || cookie[1] != 0;
}

void SetReservationCookie(bool reservation, const int cookie[2]={0, 0})
{
	StoreToAddress(g_pReservationCookie, cookie[0], NumberType_Int32);
	StoreToAddress(g_pReservationCookie + view_as<Address>(4), cookie[1], NumberType_Int32);
	sv_hosting_lobby.BoolValue = reservation;
	g_bLobbyReservationObserved = reservation;
	SDKCall(g_hSDKUpdateGameType);
}

void Init()
{
	char sBuffer[128];

	strcopy(sBuffer, sizeof(sBuffer), "l4d2_lobby_match_manager");
	GameData hGameData = new GameData(sBuffer);
	if (hGameData == null)
		SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CServerGameDLL::ApplyGameSettings");
	g_hApplyGameSettingsDetour = DynamicDetour.FromConf(hGameData, sBuffer);
	if (g_hApplyGameSettingsDetour == null)
		SetFailState("Failed to create DynamicDetour: %s", sBuffer);
	if (!g_hApplyGameSettingsDetour.Enable(Hook_Pre, OnApplyGameSettingsPre))
		SetFailState("Failed to detour pre: %s", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CBaseServer::ReplyReservationRequest");
	g_hReplyReservationRequestDetour = DynamicDetour.FromConf(hGameData, sBuffer);
	if (g_hReplyReservationRequestDetour == null)
		SetFailState("Failed to create DynamicDetour: %s", sBuffer);
	if (!g_hReplyReservationRequestDetour.Enable(Hook_Post, OnReplyReservationRequestPost))
		SetFailState("Failed to detour post: %s", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CBaseServer::ReplyReservationRequest");
	g_mBlockReserve = MemoryPatch.CreateFromConf(hGameData, sBuffer);
	if (!g_mBlockReserve.Validate())
		SetFailState("Failed to verify patch: %s", sBuffer);
	
	strcopy(sBuffer, sizeof(sBuffer), "g_pMatchExtL4D");
	g_pMatchExtL4D = hGameData.GetAddress(sBuffer);
	if (g_pMatchExtL4D == Address_Null)
		SetFailState("Failed to get address: %s", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CBaseServer::m_nReservationCookie");
	g_pReservationCookie = hGameData.GetAddress(sBuffer);
	if (g_pReservationCookie == Address_Null)
		SetFailState("Failed to get address: %s", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CBaseServer::UpdateGameType");
	StartPrepSDKCall(SDKCall_Server);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, sBuffer);
	g_hSDKUpdateGameType = EndPrepSDKCall();
	if (g_hSDKUpdateGameType == null)
		SetFailState("Failed to create SDKCall: %s", sBuffer);

	strcopy(sBuffer, sizeof(sBuffer), "CMatchExtL4D::GetGameModeInfo");
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, sBuffer);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKGetGameModeInfo = EndPrepSDKCall();
	if (g_hSDKGetGameModeInfo == null)
		SetFailState("Failed to create SDKCall: %s", sBuffer);

	// KeyValues * CMatchExtL4D::GetMapInfo( KeyValues *pSettings, KeyValues **ppMissionInfo )
	strcopy(sBuffer, sizeof(sBuffer), "CMatchExtL4D::GetMapInfo");
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, sBuffer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	g_hSDKGetMapInfo = EndPrepSDKCall();
	if (g_hSDKGetMapInfo == null)
		SetFailState("Failed to create SDKCall: %s", sBuffer);

		

	delete hGameData;
}
