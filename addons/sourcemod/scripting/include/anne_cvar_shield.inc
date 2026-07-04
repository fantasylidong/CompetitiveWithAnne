#if defined _anne_cvar_shield_included
 #endinput
#endif
#define _anne_cvar_shield_included

/**
 * Authorize a protected Anne CVar target before another plugin writes it.
 *
 * @param cvarName Protected CVar name, such as "l4d_infected_limit".
 * @param value    New target value.
 * @return         True when the CVar is protected and the target was accepted.
 */
native bool AnneCvarShield_AuthorizeTarget(const char[] cvarName, int value);

public SharedPlugin __pl_anne_cvar_shield =
{
    name = "anne_cvar_shield",
    file = "optional/AnneHappy/anne_cvar_shield.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_anne_cvar_shield_SetNTVOptional()
{
    MarkNativeAsOptional("AnneCvarShield_AuthorizeTarget");
}
#endif
