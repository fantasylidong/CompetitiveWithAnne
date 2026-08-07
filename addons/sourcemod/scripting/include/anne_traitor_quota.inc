#if defined _anne_traitor_quota_included
    #endinput
#endif
#define _anne_traitor_quota_included

public SharedPlugin __pl_anne_traitor_quota =
{
    name = "anne_traitor_quota",
    file = "optional/AnneHappy/anne_traitor_quota.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_anne_traitor_quota_SetNTVOptional()
{
    MarkNativeAsOptional("AnneTraitorQuota_CanUse");
    MarkNativeAsOptional("AnneTraitorQuota_Consume");
    MarkNativeAsOptional("AnneTraitorQuota_Refund");
    MarkNativeAsOptional("AnneTraitorQuota_CanUseTank");
    MarkNativeAsOptional("AnneTraitorQuota_BlockTank");
    MarkNativeAsOptional("AnneTraitorQuota_InvalidateClient");
}
#endif

native bool AnneTraitorQuota_CanUse(int client, int cost = 1);
native bool AnneTraitorQuota_Consume(int client, int cost = 1);
native bool AnneTraitorQuota_Refund(int client, int cost = 1);
native bool AnneTraitorQuota_CanUseTank(int client);
native bool AnneTraitorQuota_BlockTank(int client, int seconds);
native void AnneTraitorQuota_InvalidateClient(int client);
