#if defined _infected_control_included
 #endinput
#endif
#define _infected_control_included

/**
 * @brief Get infected_control next SI spawn time
 * @remarks you must send alive smoker client index.
 *
 * @return next si spawn time
 */
native float GetNextSpawnTime();

/**
 * @brief Returns whether a client must remain on infected for traitor mode.
 * @remarks False while traitor mode is disabled. Otherwise true for an armed Tank registrant and for spawn-locked, spawn-allowed, or alive traitor clients.
 *
 * @param client Client index.
 * @return true when join/team-management plugins should not force this player away.
 */
native bool InfectedControl_IsTraitorClient(int client);

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
	MarkNativeAsOptional("InfectedControl_IsTraitorClient");
	MarkNativeAsOptional("InfectedControl_HandleTraitorTankOffer");
}
#endif
