#if defined _myjbwarden_included
	#endinput
#endif
#define _myjbwarden_included

public SharedPlugin __pl_myjbwarden =
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
public void __pl_myjbwarden_SetNTVOptional()
{
	MarkNativeAsOptional("warden_deputy_isdeputy");
}
#endif

native bool warden_deputy_isdeputy(int client);
