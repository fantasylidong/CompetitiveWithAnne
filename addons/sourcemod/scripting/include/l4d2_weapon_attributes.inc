#if defined _l4d2_weapon_attributes_included
	#endinput
#endif
#define _l4d2_weapon_attributes_included

public SharedPlugin __pl_l4d2_weapon_attributes =
{
	name = "l4d2_weapon_attributes",
	file = "optional/l4d2_weapon_attributes.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_l4d2_weapon_attributes_SetNTVOptional()
{
	MarkNativeAsOptional("L4D2WA_GetWeaponTankDamageMult");
	MarkNativeAsOptional("L4D2WA_GetWeaponReloadDurationMult");
}
#endif

/**
 * Returns the tankdamagemult configured for a weapon (1.0 when not overridden).
 */
native float L4D2WA_GetWeaponTankDamageMult(const char[] weaponName);

/**
 * Returns the reloaddurationmult configured for a shotgun (1.0 when not overridden).
 */
native float L4D2WA_GetWeaponReloadDurationMult(const char[] weaponName);
