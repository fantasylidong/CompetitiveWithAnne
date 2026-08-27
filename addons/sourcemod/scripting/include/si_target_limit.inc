/** Double-include prevention */
#if defined _SI_Target_limit_included_
  #endinput
#endif
#define _SI_Target_limit_included_
 
/**
 * Adds two numbers together.
 *
 * @param client    An Player Index.
 * @return        return how many SI pick the player as target.
 */
native int GetClientTargetNum(int client);

/**
 * Adds two numbers together.
 *
 * @param client    An Player Index.
 * @return        return true the player is already target by limit number, otherwise false.
 */
native int IsClientReachLimit(int client);

/**
 * Current configured SI target capacity for this survivor.
 * @param client    A player index.
 */
native int GetClientTargetLimit(int client);

public SharedPlugin __pl_SI_Target_limit =
{
	name = "SI_Target_limit",
	file = "SI_Target_limit.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_SI_Target_limit_SetNTVOptional()
{
	MarkNativeAsOptional("GetClientTargetNum");
	MarkNativeAsOptional("IsClientReachLimit");
	MarkNativeAsOptional("GetClientTargetLimit");
}
#endif
