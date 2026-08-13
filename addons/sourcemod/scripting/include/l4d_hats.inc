#if defined  _l4d_hats_included_
 #endinput
#endif
#define _l4d_hats_included_

public SharedPlugin __pl_l4d_hats =
{
	name = "l4d_hats",
	file = "l4d_hats.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d_hats_SetNTVOptional()
{
	MarkNativeAsOptional("Hats_SetClientHat");
	MarkNativeAsOptional("Hats_GetClientHat");
}
#endif

/**
 * Called when a player selects or removes a hat.
 *
 * @param client	Client index.
 * @param index		0-based hat index from data/l4d_hats.cfg, or -1 when the hat is removed.
 * @noreturn
 */
forward void L4D_OnHatLoadSave(int client, int index);

/**
 * Set or remove a client's hat without notifying L4D_OnHatLoadSave.
 * Use this to restore a previously saved hat.
 *
 * @param client	Client index.
 * @param index		0-based hat index, or -1 to remove the hat.
 * @return			True on success, false if the client/index is invalid or the hat could not be created.
 */
native bool Hats_SetClientHat(int client, int index);

/**
 * Get the client's current hat type.
 *
 * @param client	Client index.
 * @return			0-based hat index, or -1 if the client has no hat.
 */
native int Hats_GetClientHat(int client);
