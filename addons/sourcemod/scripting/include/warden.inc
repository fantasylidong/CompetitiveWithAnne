#if defined _warden_included
	#endinput
#endif
#define _warden_included

public SharedPlugin __pl_warden =
{
	name = "warden",
	file = "warden.smx",

	#if defined REQUIRE_PLUGIN
	required = 1,
	#else
	required = 0,
	#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_warden_SetNTVOptional()
{
	MarkNativeAsOptional("warden_iswarden");
}
#endif

native bool warden_iswarden(int client);
