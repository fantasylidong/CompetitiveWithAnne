#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>
#include <l4d2lib>
#include <sdktools>
#include <colors>

#define Z_TANK 8
#define TEAM_INFECTED 3

#define ZOMBIEMANAGER_GAMEDATA "l4d2_zombiemanager"
#define LEFT4FRAMEWORK_GAMEDATA "left4dhooks.l4d2"

#define HORDE_MIN_SIZE_AUDIAL_FEEDBACK 120
#define MAX_CHECKPOINTS 4
#define FINITE_EVENT_ACTIVITY_HOLD 12.0

#define HORDE_SOUND "/npc/mega_mob/mega_mob_incoming.wav"

ConVar
	hCvarNoEventHordeDuringTanks,
	hCvarHordeCheckpointAnnounce;

Address
	pZombieManager = Address_Null;

int
	commonLimit,
	commonTank,
	commonTotal,
	lastCheckpoint,
	deferredMobCount,
	m_nPendingMobCount;

bool
	announcedInChat,
	announcedEventEnd,
	finiteEventActive,
	deferredMobSavedForTank,
	checkpointAnnounced[MAX_CHECKPOINTS];

float
	finiteEventActiveUntil,
	finiteEventPauseStartedAt;

Handle g_hFiniteEventStateChangedForward = INVALID_HANDLE;

public Plugin myinfo = 
{
	name = "L4D2 Horde Equaliser",
	author = "Visor (original idea by Sir), A1m`",
	description = "Make certain event hordes finite",
	version = "3.0.10",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int errMax)
{
	RegPluginLibrary("l4d2_horde_equaliser");
	CreateNative("L4D2HordeEqualiser_IsFiniteEventActive", Native_IsFiniteEventActive);
	CreateNative("L4D2HordeEqualiser_GetFiniteEventLimit", Native_GetFiniteEventLimit);
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslation("l4d2_horde_equaliser.phrases");
	InitGameData();
	g_hFiniteEventStateChangedForward = CreateGlobalForward(
		"L4D2HordeEqualiser_OnFiniteEventStateChanged",
		ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	RefreshMapSettings();
	
	hCvarNoEventHordeDuringTanks = CreateConVar("l4d2_heq_no_tank_horde", "0", "Put infinite hordes on a 'hold up' during Tank fights");
	hCvarHordeCheckpointAnnounce = CreateConVar("l4d2_heq_checkpoint_sound", "1", "Play the incoming mob sound at checkpoints (each 1/4 of total commons killed off) to simulate L4D1 behaviour");

	HookEvent("round_start", RoundStartEvent, EventHookMode_PostNoCopy);
	HookEvent("round_end", RoundEndEvent, EventHookMode_PostNoCopy);
	HookEvent("tank_spawn", TankSpawn, EventHookMode_PostNoCopy);
	HookEvent("player_death", TankDeath);
}

void InitGameData()
{
	Handle hDamedata = LoadGameConfigFile(LEFT4FRAMEWORK_GAMEDATA);
	if (!hDamedata) {
		SetFailState("%s gamedata missing or corrupt", LEFT4FRAMEWORK_GAMEDATA);
	}

	pZombieManager = GameConfGetAddress(hDamedata, "ZombieManager");
	if (!pZombieManager) {
		SetFailState("Couldn't find the 'ZombieManager' address");
	}
	
	delete hDamedata;

	Handle hDamedata2 = LoadGameConfigFile(ZOMBIEMANAGER_GAMEDATA);
	if (!hDamedata2) {
		SetFailState("%s gamedata missing or corrupt", ZOMBIEMANAGER_GAMEDATA);
	}
	
	m_nPendingMobCount = GameConfGetOffset(hDamedata2, "ZombieManager->m_nPendingMobCount");
	if (m_nPendingMobCount == -1) {
		SetFailState("Failed to get offset 'ZombieManager->m_nPendingMobCount'.");
	}

	delete hDamedata2;
}

public void OnMapStart()
{
	finiteEventActive = false;
	finiteEventActiveUntil = 0.0;
	finiteEventPauseStartedAt = 0.0;
	RefreshMapSettings();

	PrecacheSound(HORDE_SOUND);
}

void RefreshMapSettings()
{
	commonLimit = L4D2_GetMapValueInt("horde_limit", -1);
	commonTank = L4D2_GetMapValueInt("horde_tank", -1);
	finiteEventActive = false;
	finiteEventActiveUntil = 0.0;
	if (commonLimit > 0 && IsInfiniteHordeActive()) {
		finiteEventActive = true;
		finiteEventActiveUntil = GetFiniteEventTime() + FINITE_EVENT_ACTIVITY_HOLD;
	}
	PublishFiniteEventState();
}

void RoundStartEvent(Event hEvent, const char[] name, bool dontBroadcast)
{
	commonTotal = 0;
	lastCheckpoint = 0;
	deferredMobCount = 0;
	deferredMobSavedForTank = false;
	announcedInChat = false;
	announcedEventEnd = false;
	finiteEventPauseStartedAt = 0.0;
	for (int i = 0; i < MAX_CHECKPOINTS; i++) {
		checkpointAnnounced[i] = false;
	}
	SetFiniteEventActive(false, true);
}

void RoundEndEvent(Event hEvent, const char[] name, bool dontBroadcast)
{
	SetFiniteEventActive(false);
	finiteEventPauseStartedAt = 0.0;
	deferredMobCount = 0;
	deferredMobSavedForTank = false;
}

public void OnMapEnd()
{
	SetFiniteEventActive(false);
	finiteEventPauseStartedAt = 0.0;
	deferredMobCount = 0;
	deferredMobSavedForTank = false;
}

public void OnPluginEnd()
{
	SetFiniteEventActive(false);
}

public any Native_IsFiniteEventActive(Handle plugin, int numParams)
{
	return finiteEventActive;
}

public any Native_GetFiniteEventLimit(Handle plugin, int numParams)
{
	return commonLimit;
}

void PublishFiniteEventState()
{
	if (g_hFiniteEventStateChangedForward == INVALID_HANDLE) {
		return;
	}

	Call_StartForward(g_hFiniteEventStateChangedForward);
	Call_PushCell(finiteEventActive);
	Call_PushCell(commonLimit);
	Call_PushCell(commonTotal);
	Call_Finish();
}

void SetFiniteEventActive(bool active, bool forceNotify = false)
{
	if (finiteEventActive == active && !forceNotify) {
		return;
	}

	finiteEventActive = active;
	if (!active) {
		finiteEventActiveUntil = 0.0;
	}
	PublishFiniteEventState();
}

void TouchFiniteEventActivity()
{
	finiteEventActiveUntil = GetFiniteEventTime() + FINITE_EVENT_ACTIVITY_HOLD;
	SetFiniteEventActive(true);
}

float GetFiniteEventTime()
{
	return (finiteEventPauseStartedAt > 0.0) ? finiteEventPauseStartedAt : GetGameTime();
}

public void OnPause()
{
	if (finiteEventPauseStartedAt <= 0.0) {
		finiteEventPauseStartedAt = GetGameTime();
	}
}

public void OnUnpause()
{
	if (finiteEventPauseStartedAt <= 0.0) {
		return;
	}

	float pausedFor = GetGameTime() - finiteEventPauseStartedAt;
	if (pausedFor > 0.0 && finiteEventActiveUntil > 0.0) {
		finiteEventActiveUntil += pausedFor;
	}
	finiteEventPauseStartedAt = 0.0;
}

public void OnGameFrame()
{
	if (finiteEventPauseStartedAt > 0.0) {
		return;
	}

	if (deferredMobSavedForTank) {
		if (IsTankUp()) {
			if (finiteEventActive) {
				finiteEventActiveUntil = GetGameTime() + FINITE_EVENT_ACTIVITY_HOLD;
			}
			return;
		}
		RestoreDeferredMobCount();
	}

	if (!finiteEventActive || finiteEventActiveUntil <= 0.0
		|| GetFiniteEventTime() < finiteEventActiveUntil) {
		return;
	}

	SetFiniteEventActive(false);
}

void TankDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && IsInfected(client) && IsTank(client)) {
		CreateTimer(0.1, Timer_CheckTank);
	}
}

void TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
	bool infiniteHordeActive = IsInfiniteHordeActive();
	if (commonLimit > 0 && infiniteHordeActive) {
		TouchFiniteEventActivity();
	}

	if ((hCvarNoEventHordeDuringTanks.BoolValue || commonTank > 0) && infiniteHordeActive) {
		DeferMobCount(0);
		SetPendingMobCount(0);
	}
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && IsInfected(client) && IsTank(client) && IsFakeClient(client)) {
		CreateTimer(0.1, Timer_CheckTank);
	}
}

Action Timer_CheckTank(Handle timer)
{
	if (!IsTankUp()) {
		RestoreDeferredMobCount();
	}

	return Plugin_Stop;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	// TO-DO: Find a value that tells wanderers from active event commons?
	if (strcmp(classname, "infected") == 0 && IsInfiniteHordeActive()) {
		// Don't count in boomer hordes, alarm cars and wanderers during a Tank fight
		if (hCvarNoEventHordeDuringTanks.BoolValue && IsTankUp()) {
			return;
		}

		if (commonLimit > 0) {
			TouchFiniteEventActivity();
		}

		// Our job here is done
		if (commonTotal >= commonLimit) {
			if (!announcedEventEnd){
				CPrintToChatAll("%t %t", "Tag", "NoCommonRemaining");
				announcedEventEnd = true;
			}
			return;
		}

		commonTotal++;
		if (hCvarHordeCheckpointAnnounce.BoolValue &&
			(commonTotal >= ((lastCheckpoint + 1) * RoundFloat(float(commonLimit / MAX_CHECKPOINTS))))
		) {
			if (commonLimit >= HORDE_MIN_SIZE_AUDIAL_FEEDBACK) {
				EmitSoundToAll(HORDE_SOUND);
			}
			
			int remaining = commonLimit - commonTotal;
			if (remaining != 0) {
				CPrintToChatAll("%t %t", "Tag", "CommonRemaining", remaining);
			}
			
			checkpointAnnounced[lastCheckpoint] = true;
			lastCheckpoint++;
		}
	}
}

public Action L4D_OnSpawnMob(int &amount)
{
	/////////////////////////////////////
	// - Called on Event Hordes.
	// - Called on Panic Event Hordes.
	// - Called on Natural Hordes.
	// - Called on Onslaught (Mini-finale or finale Scripts)

	// - Not Called on Boomer Hordes.
	// - Not Called on z_spawn mob.
	////////////////////////////////////
	
	bool bInfiniteHordeActive = IsInfiniteHordeActive();
	bool bHoldingForTank = ((hCvarNoEventHordeDuringTanks.BoolValue || commonTank > 0) && IsTankUp() && bInfiniteHordeActive);
	bool bFiniteEventActive = (bInfiniteHordeActive && commonLimit > 0);

	if (bFiniteEventActive) {
		TouchFiniteEventActivity();
	}

	// "Pause" the infinite horde during the Tank fight
	if (bHoldingForTank){
		DeferMobCount(amount);
		SetPendingMobCount(0);
		amount = 0;
		return Plugin_Handled;
	}

	if (bInfiniteHordeActive) {
		RestoreDeferredMobCount();
	}

	// Excluded map -- don't block any infinite hordes on this one
	if (commonLimit < 0) {
		return Plugin_Continue;
	}

	// If it's a "finite" infinite horde...
	if (bInfiniteHordeActive) {
		if (!announcedInChat) {
			CPrintToChatAll("%t %t", "Tag", "FiniteEventStarted", commonLimit);
			announcedInChat = true;
		}
		
		// ...and it's overlimit...
		if (commonTotal >= commonLimit) {
			SetPendingMobCount(0);
			amount = 0;
			return Plugin_Handled;
		}
		// commonTotal += amount;
	}
	
	// ...or not.
	return Plugin_Continue;
}

void DeferMobCount(int amount)
{
	if (deferredMobSavedForTank) {
		return;
	}

	int pending = GetPendingMobCount();
	int amountToDefer = (pending > 0) ? pending : amount;
	if (amountToDefer <= 0) {
		return;
	}

	if (commonLimit >= 0) {
		int remaining = commonLimit - commonTotal - deferredMobCount;
		if (remaining <= 0) {
			return;
		}

		if (amountToDefer > remaining) {
			amountToDefer = remaining;
		}
	}

	deferredMobCount += amountToDefer;
	deferredMobSavedForTank = true;
}

void RestoreDeferredMobCount()
{
	if (deferredMobCount <= 0) {
		deferredMobSavedForTank = false;
		return;
	}

	if (commonLimit >= 0) {
		int remaining = commonLimit - commonTotal;
		if (remaining <= 0) {
			deferredMobCount = 0;
			deferredMobSavedForTank = false;
			return;
		}

		if (deferredMobCount > remaining) {
			deferredMobCount = remaining;
		}
	}

	SetPendingMobCount(GetPendingMobCount() + deferredMobCount);
	deferredMobCount = 0;
	deferredMobSavedForTank = false;
}

bool IsInfiniteHordeActive()
{
	int countdown = GetHordeCountdown();
	return (/*GetPendingMobCount() > 0 &&*/ countdown > -1 && countdown <= 10);
}

int GetPendingMobCount()
{
	return LoadFromAddress(pZombieManager + view_as<Address>(m_nPendingMobCount), NumberType_Int32);
}

void SetPendingMobCount(int count)
{
	StoreToAddress(pZombieManager + view_as<Address>(m_nPendingMobCount), count, NumberType_Int32);
}

int GetHordeCountdown()
{
	return (CTimer_HasStarted(L4D2Direct_GetMobSpawnTimer())) ? RoundFloat(CTimer_GetRemainingTime(L4D2Direct_GetMobSpawnTimer())) : -1;
}

bool IsTankUp()
{
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED) {
			if (GetEntProp(i, Prop_Send, "m_zombieClass") == Z_TANK && IsPlayerAlive(i)) {
				return true;
			}
		}
	}

	return false;
}

bool IsInfected(int client)
{
	return (IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED);
}

bool IsTank(int client)
{
	return (GetEntProp(client, Prop_Send, "m_zombieClass") == Z_TANK);
}

/**
 * Check if the translation file exists
 *
 * @param translation	Translation name.
 * @noreturn
 */
stock void LoadTranslation(const char[] translation)
{
	char
		sPath[PLATFORM_MAX_PATH],
		sName[64];

	Format(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}
