#if defined _infected_control_included
 #endinput
#endif
#define _infected_control_included

/**
 * @brief Returns the legacy estimate for the next SI wave.
 * @remarks During the kill phase this is an upper-bound estimate. During an
 *          Anti-Bait hold it returns 0. New UI consumers should use
 *          InfectedControl_GetWaveStatus instead.
 *
 * @return Estimated seconds remaining, or -1 when unavailable.
 */
native float GetNextSpawnTime();

enum InfectedControlWavePhase
{
	InfectedControlWavePhase_Inactive = 0,
	InfectedControlWavePhase_Kill,
	InfectedControlWavePhase_Countdown,
	InfectedControlWavePhase_AntiBaitHold
};

/**
 * @brief Returns the current infected wave phase.
 * @remarks Kill remaining is the maximum time left in the kill phase, not the
 *          next-wave ETA. Countdown remaining is the independent base respawn
 *          countdown. Inactive and AntiBaitHold have no finite deadline and
 *          write -1.0.
 *
 * @param remaining Remaining seconds for the returned phase.
 * @return Current public wave phase.
 */
native InfectedControlWavePhase InfectedControl_GetWaveStatus(float &remaining);

/**
 * @brief Copies the current special-infected spawn queue.
 * @remarks Class ids match L4D2 zombie classes (1 smoker .. 6 charger).
 *          The list is the remaining AI spawn order for the current/next wave.
 *
 * @param classes Output array of zombie class ids.
 * @param maxlen  Maximum number of classes to copy.
 * @return Number of classes written.
 */
native int InfectedControl_GetSpawnQueue(int[] classes, int maxlen);

/**
 * @brief Returns whether a client must remain on infected for traitor mode.
 * @remarks False while traitor mode is disabled. Otherwise true for an armed Tank registrant and for spawn-locked, spawn-allowed, or alive traitor clients.
 *
 * @param client Client index.
 * @return true when join/team-management plugins should not force this player away.
 */
native bool InfectedControl_IsTraitorClient(int client);

/**
 * @brief Returns whether a client has a traitor registration.
 * @remarks False while traitor mode is disabled. Waiting and armed clients are included.
 *
 * @param client Client index.
 * @return true when the player is registered for traitor mode.
 */
native bool InfectedControl_IsTraitorRegistered(int client);

/**
 * @brief Returns whether infected_control currently enables traitor mode.
 *
 * @return true when traitor mode is enabled by the active plugin instance.
 */
native bool InfectedControl_IsTraitorModeEnabled();

/**
 * @brief Returns whether an armed traitor Tank is waiting for a natural AI Tank.
 *
 * @return true when automatic Tank lotteries should leave the spawned Tank as AI for traitor takeover.
 */
native bool InfectedControl_HasPendingTraitorTank();

enum InfectedControlTankOfferResult
{
	InfectedControlTankOffer_NotTraitor = 0,
	InfectedControlTankOffer_KeepCurrentControl,
	InfectedControlTankOffer_GrantSecondControl,
	InfectedControlTankOffer_ReleaseToAI
};

/**
 * @brief Resolves a Tank offer for an active traitor Tank.
 * @remarks Tank Control should block the engine offer for KeepCurrentControl and
 *          GrantSecondControl, and continue normally for ReleaseToAI.
 *
 * @param client Active Tank client index.
 * @return How the Tank offer should be handled.
 */
native InfectedControlTankOfferResult InfectedControl_HandleTraitorTankOffer(int client);

/**
 * @brief When a RushMan be detected
 * @remarks you must send alive Player client index.
 * @para DetectRushMan the rush man client index
 * 
 */
forward void OnDetectRushman(int DetectRushMan);

public SharedPlugin __pl_infected_control = 
{
	name = "infected_control",
	file = "infected_control.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_infected_control_SetNTVOptional()
{
	MarkNativeAsOptional("GetNextSpawnTime");
	MarkNativeAsOptional("InfectedControl_GetWaveStatus");
	MarkNativeAsOptional("InfectedControl_GetSpawnQueue");
	MarkNativeAsOptional("InfectedControl_IsTraitorClient");
	MarkNativeAsOptional("InfectedControl_IsTraitorRegistered");
	MarkNativeAsOptional("InfectedControl_IsTraitorModeEnabled");
	MarkNativeAsOptional("InfectedControl_HasPendingTraitorTank");
	MarkNativeAsOptional("InfectedControl_HandleTraitorTankOffer");
}
#endif
