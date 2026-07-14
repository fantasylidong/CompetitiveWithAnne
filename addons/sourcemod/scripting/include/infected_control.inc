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
 * @remarks True only for spawn-locked, spawn-allowed, and alive traitor clients.
 *
 * @param client Client index.
 * @return true when join/team-management plugins should not force this player away.
 */
native bool InfectedControl_IsTraitorClient(int client);

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
}
#endif
