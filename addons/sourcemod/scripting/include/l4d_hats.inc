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
	MarkNativeAsOptional("Hats_GetClientPrefs");
	MarkNativeAsOptional("Hats_SetClientPrefs");
	MarkNativeAsOptional("Hats_AreClientPrefsReady");
}
#endif

/**
 * Stable bitmask for the four hat visibility preferences.
 * Defaults: wear on, first-person off, third-person on, show others on.
 */
#define HATS_PREF_ENABLED      (1 << 0)
#define HATS_PREF_VIEW_FIRST   (1 << 1)
#define HATS_PREF_VIEW_THIRD   (1 << 2)
#define HATS_PREF_SHOW_OTHERS  (1 << 3)
#define HATS_PREF_DEFAULT      (HATS_PREF_ENABLED | HATS_PREF_VIEW_THIRD | HATS_PREF_SHOW_OTHERS)

/**
 * Called when a player selects or removes a hat.
 *
 * @param client	Client index.
 * @param index		0-based hat index from data/l4d_hats.cfg, or -1 when the hat is removed.
 * @noreturn
 */
forward void L4D_OnHatLoadSave(int client, int index);

/**
 * Called when a player (or admin targeting them) changes hat preferences.
 * Not fired for Hats_SetClientPrefs restores.
 *
 * @param client	Client index.
 * @param flags		HATS_PREF_* bitmask after the change.
 * @noreturn
 */
forward void L4D_OnHatPrefsChanged(int client, int flags);

/**
 * Called after clientprefs has loaded, or after a pre-cache player change has
 * been mirrored into clientprefs. MySQL NULL migration must wait for this.
 *
 * @param client	Client index.
 * @param flags		HATS_PREF_* bitmask after cookie resolution.
 * @noreturn
 */
forward void L4D_OnHatPrefsReady(int client, int flags);

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

/**
 * Get the four hat preferences as a HATS_PREF_* bitmask.
 *
 * @param client	Client index.
 * @return			Bitmask. Invalid clients return 0.
 */
native int Hats_GetClientPrefs(int client);

/**
 * Apply hat preferences without notifying L4D_OnHatPrefsChanged.
 * Syncs clientprefs cookies. Restores must use this instead of player commands
 * so RPG/MySQL load cannot form a write loop.
 *
 * @param client	Client index.
 * @param flags		HATS_PREF_* bitmask.
 * @return			True on success, false if the client is invalid.
 */
native bool Hats_SetClientPrefs(int client, int flags);

/**
 * Report whether the client's cookie-backed preferences are ready.
 *
 * @param client	Client index.
 * @return			True after clientprefs has been resolved for this connection.
 */
native bool Hats_AreClientPrefsReady(int client);
