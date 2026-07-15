#if defined _global_chat_included_
 #endinput
#endif
#define _global_chat_included_

public SharedPlugin __pl_global_chat =
{
	name = "global_chat",
	file = "global_chat.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_global_chat_SetNTVOptional()
{
	MarkNativeAsOptional("GlobalChat_Broadcast");
	MarkNativeAsOptional("GlobalChat_BroadcastMapRecord");
}
#endif

/**
 * Broadcast a server-side announcement through global_chat.
 *
 * @param message		Message text, color codes allowed.
 * @return				true if queued to the global chat database.
 */
native bool GlobalChat_Broadcast(const char[] message);

/**
 * Broadcast a localized map-record announcement through global_chat.
 *
 * @param mapName            Map name.
 * @param runPlayers        Compact player-name list.
 * @param mode              Anne timing mode identifier.
 * @param infectedNumber    Special Infected count.
 * @param siSpawnTime       Special Infected spawn interval in seconds.
 * @param difficulty        Difficulty identifier.
 * @param timeLabel         Formatted completion time.
 * @return                  true if queued to the global chat database.
 */
native bool GlobalChat_BroadcastMapRecord(const char[] mapName, const char[] runPlayers, int mode, int infectedNumber, int siSpawnTime, int difficulty, const char[] timeLabel);
