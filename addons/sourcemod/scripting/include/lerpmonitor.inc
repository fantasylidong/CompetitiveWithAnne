#if defined __lerpmonitor_included
	#endinput
#endif
#define __lerpmonitor_included

/**
 * @brief				Get the player's most recently queried lerp time.
 * @param client		Client index.
 *
 * @return				Last queried lerp, or the engine value before the first query completes.
 * @error				If the client is not connected or the index is invalid.
**/
native float LM_GetLerpTime(int client);

/**
 * @brief				Get the player's most recently queried lerp time.
 * @param client		Client index.
 *
 * @return				Current lerp time.
 * @error				Invalid client index, or client not connected.
**/
native float LM_GetCurrentLerpTime(int client);

/**
 * @brief				Get the player's lerp time stored in the array.
 * @param client		Client index.
 *
 * @return				Return -1.0 if the lerp time has not been saved, otherwise the stored lerp time.
 * @error				Invalid client index, or client not connected.
**/
native float LM_GetStoredLerpTime(int client);

public SharedPlugin __lerpmonitor =
{
	name = "LerpMonitor++",
	file = "lerpmonitor.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_lerpmonitor_SetNTVOptional()
{
	MarkNativeAsOptional("LM_GetLerpTime");
	MarkNativeAsOptional("LM_GetCurrentLerpTime");
	MarkNativeAsOptional("LM_GetStoredLerpTime");
}
#endif
