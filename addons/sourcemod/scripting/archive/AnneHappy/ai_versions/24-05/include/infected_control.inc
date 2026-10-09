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
}
#endif
