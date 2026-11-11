#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks> //#include <l4d2d_timers>

#define GAMEDATA "l4d2_si_ability"

#define MAX_ENTS 2048
#define MAX_PUDDLES 32

#define TICK_TIME 0.200072
#define TEAM_SURVIVOR 2

#define DMG_TYPE_SPIT (DMG_RADIATION|DMG_ENERGYBEAM)

ConVar
	g_hCvarDamagePerTick,
	g_hCvarAlternateDamagePerTwoTicks,
	g_hCvarMaxTicks,
	g_hCvarGodframeTicks;

int
	g_iPuddleSlot[MAX_ENTS] = {-1, ...},
	g_iPuddleEntity[MAX_PUDDLES] = {-1, ...},
	g_iPuddleTicks[MAX_PUDDLES][MAXPLAYERS + 1],
	g_iActiveTimerOffset,
	g_iMaxTicks,
	g_iGodframeTicks;

bool
	g_bPuddleAltTick[MAX_PUDDLES][MAXPLAYERS + 1],
	g_bLateLoad;

float
	g_fDamagePerTick,
	g_fAlternatePerTick;

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int iErrMax)
{
	g_bLateLoad = bLate;
	
	return APLRes_Success;
}

public Plugin myinfo =
{
	name = "L4D2 Uniform Spit",
	author = "Visor, Sir, A1m`",
	description = "Make the spit deal a set amount of DPS under all circumstances",
	version = "1.5.1",
	url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
};

public void OnPluginStart()
{
	InitGameData();

	g_hCvarDamagePerTick = CreateConVar("l4d2_spit_dmg", "-1.0", "Damage per tick the spit inflicts. -1 to skip damage adjustments");
	g_hCvarAlternateDamagePerTwoTicks = CreateConVar("l4d2_spit_alternate_dmg", "-1.0", "Damage per alternate tick. -1 to disable");
	g_hCvarMaxTicks = CreateConVar("l4d2_spit_max_ticks", "28", "Maximum number of acid damage ticks");
	g_hCvarGodframeTicks = CreateConVar("l4d2_spit_godframe_ticks", "4", "Number of initial godframed acid ticks");
	
	g_hCvarDamagePerTick.AddChangeHook(CvarsChanged);
	g_hCvarAlternateDamagePerTwoTicks.AddChangeHook(CvarsChanged);
	g_hCvarMaxTicks.AddChangeHook(CvarsChanged);
	g_hCvarGodframeTicks.AddChangeHook(CvarsChanged);
	
	ResetAllPuddles();

	HookEvent("round_start", Event_RoundReset, EventHookMode_PostNoCopy);
	//HookEvent("round_end", Event_RoundReset, EventHookMode_PostNoCopy);

	if (g_bLateLoad) {
		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)) {
				OnClientPutInServer(i);
			}
		}

		int entity = -1;
		while ((entity = FindEntityByClassname(entity, "insect_swarm")) != -1) {
			AllocPuddleSlot(entity);
		}
	}
}

void InitGameData()
{
	Handle hGamedata = LoadGameConfigFile(GAMEDATA);

	if (!hGamedata) {
		SetFailState("Gamedata '%s.txt' missing or corrupt.", GAMEDATA);
	}
	
	g_iActiveTimerOffset = GameConfGetOffset(hGamedata, "CInferno->m_activeTimer");
	if (g_iActiveTimerOffset == -1) {
		SetFailState("Failed to get offset 'CInferno->m_activeTimer'.");
	}
	
	delete hGamedata;
}

void CvarsChanged(ConVar hConVar, const char[] sOldValue, const char[] sNewValue)
{
	CvarsToType();
}

public void OnConfigsExecuted()
{
	CvarsToType();
}

void CvarsToType()
{
	g_fDamagePerTick = g_hCvarDamagePerTick.FloatValue;
	g_fAlternatePerTick = g_hCvarAlternateDamagePerTwoTicks.FloatValue;
	g_iMaxTicks = g_hCvarMaxTicks.IntValue;
	g_iGodframeTicks = g_hCvarGodframeTicks.IntValue;
}

void ResetAllPuddles()
{
	for (int i = 0; i < MAX_ENTS; i++) {
		g_iPuddleSlot[i] = -1;
	}
	for (int s = 0; s < MAX_PUDDLES; s++) {
		g_iPuddleEntity[s] = -1;
		for (int c = 0; c <= MAXPLAYERS; c++) {
			g_iPuddleTicks[s][c] = 0;
			g_bPuddleAltTick[s][c] = false;
		}
	}
}

int AllocPuddleSlot(int iEntity)
{
	if (iEntity <= MaxClients || iEntity >= MAX_ENTS) {
		return -1;
	}

	int existing = g_iPuddleSlot[iEntity];
	if (existing != -1) {
		for (int c = 0; c <= MAXPLAYERS; c++) {
			g_iPuddleTicks[existing][c] = 0;
			g_bPuddleAltTick[existing][c] = false;
		}
		return existing;
	}

	for (int s = 0; s < MAX_PUDDLES; s++) {
		if (g_iPuddleEntity[s] == -1) {
			g_iPuddleEntity[s] = iEntity;
			g_iPuddleSlot[iEntity] = s;
			for (int c = 0; c <= MAXPLAYERS; c++) {
				g_iPuddleTicks[s][c] = 0;
				g_bPuddleAltTick[s][c] = false;
			}
			return s;
		}
	}

	return -1;
}

void FreePuddleSlot(int iEntity)
{
	if (iEntity <= MaxClients || iEntity >= MAX_ENTS) {
		return;
	}

	int s = g_iPuddleSlot[iEntity];
	if (s != -1) {
		g_iPuddleSlot[iEntity] = -1;
		g_iPuddleEntity[s] = -1;
	}
}

void Event_RoundReset(Event hEvent, const char[] sEventName, bool bDontBroadcast)
{
	ResetAllPuddles();
}

public void OnMapEnd()
{
	ResetAllPuddles();
}

public void OnClientPutInServer(int iClient)
{
	SDKHook(iClient, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnClientDisconnect(int iClient)
{
	SDKUnhook(iClient, SDKHook_OnTakeDamage, Hook_OnTakeDamage);
}

public void OnEntityCreated(int iEntity, const char[] sClassName)
{
	if (sClassName[0] != 'i') {
		return;
	}

	if (strcmp(sClassName, "insect_swarm") == 0) {
		AllocPuddleSlot(iEntity);
	}
}

public void OnEntityDestroyed(int iEntity)
{
	FreePuddleSlot(iEntity);
}

/*
 * signed int CInsectSwarm::GetDamageType()
 * {
 *   return 263168; //DMG_RADIATION|DMG_ENERGYBEAM
 * }
*/
Action Hook_OnTakeDamage(int iVictim, int &iAttacker, int &iInflictor, float &fDamage, int &fDamageType)
{
	if (!(fDamageType & DMG_TYPE_SPIT)) { //for performance
		return Plugin_Continue;
	}

	if (iInflictor <= MaxClients || iInflictor >= MAX_ENTS || !IsSurvivor(iVictim)) {
		return Plugin_Continue;
	}

	int iSlot = g_iPuddleSlot[iInflictor];
	if (iSlot == -1) {
		if (!IsValidEdict(iInflictor)) {
			return Plugin_Continue;
		}
		char sClassName[32];
		GetEdictClassname(iInflictor, sClassName, sizeof(sClassName));
		if (strcmp(sClassName, "insect_swarm") != 0) {
			return Plugin_Continue;
		}
		iSlot = AllocPuddleSlot(iInflictor);
		if (iSlot == -1) {
			return Plugin_Continue;
		}
	}

	int iTicks = ++g_iPuddleTicks[iSlot][iVictim];

	// Check to see if it's a godframed tick
	if (iTicks < g_iGodframeTicks && GetPuddleLifetime(iInflictor) >= g_iGodframeTicks * TICK_TIME) {
		iTicks = g_iGodframeTicks + 1;
		g_iPuddleTicks[iSlot][iVictim] = iTicks;
	}

	// Let's see what do we have here
	if (g_fDamagePerTick > -1.0) {
		if (g_fAlternatePerTick > -1.0 && g_bPuddleAltTick[iSlot][iVictim]) {
			g_bPuddleAltTick[iSlot][iVictim] = false;
			fDamage = g_fAlternatePerTick;
		} else {
			fDamage = g_fDamagePerTick;
			g_bPuddleAltTick[iSlot][iVictim] = true;
		}
	}

	if (g_iGodframeTicks >= iTicks || iTicks > g_iMaxTicks) {
		fDamage = 0.0;
	}

	if (iTicks > g_iMaxTicks) {
		RemoveEntity(iInflictor);
	}

	return Plugin_Changed;
}

float GetPuddleLifetime(int iPuddle)
{
	return ITimer_GetElapsedTime(view_as<IntervalTimer>(GetEntityAddress(iPuddle) + view_as<Address>(g_iActiveTimerOffset)));
}

bool IsSurvivor(int iClient)
{
	return (iClient > 0
		&& iClient <= MaxClients
		&& IsClientInGame(iClient)
		&& GetClientTeam(iClient) == TEAM_SURVIVOR);
}

