#if defined _infected_control_traitor_quota_bridge_included
    #endinput
#endif
#define _infected_control_traitor_quota_bridge_included

bool Traitor_IsAdminClient(int client)
{
    return IsValidClient(client)
        && CheckCommandAccess(client, "infected_control_traitor_admin", ADMFLAG_GENERIC);
}

bool TraitorQuota_IsProviderAvailable()
{
    return GetFeatureStatus(FeatureType_Native, "AnneTraitorQuota_CanUse") == FeatureStatus_Available;
}

// 无 provider 即无数据库模式：跳过持久化限制，不阻断内鬼与刷特主流程。
void TraitorQuota_InvalidateClientCache(int client)
{
    if (TraitorQuota_IsProviderAvailable())
        AnneTraitorQuota_InvalidateClient(client);
}

bool TraitorQuota_CanUse(int client, int cost = 1)
{
    if (!TraitorQuota_IsProviderAvailable())
        return true;

    return AnneTraitorQuota_CanUse(client, cost);
}

bool TraitorQuota_Consume(int client, int cost = 1)
{
    if (!TraitorQuota_IsProviderAvailable())
        return true;

    return AnneTraitorQuota_Consume(client, cost);
}

bool TraitorQuota_Refund(int client, int cost = 1)
{
    if (!TraitorQuota_IsProviderAvailable())
        return true;

    return AnneTraitorQuota_Refund(client, cost);
}

bool TraitorQuota_CanUseTank(int client)
{
    if (!TraitorQuota_IsProviderAvailable())
        return true;

    return AnneTraitorQuota_CanUseTank(client);
}

bool TraitorQuota_BlockTank(int client, int seconds)
{
    if (!TraitorQuota_IsProviderAvailable())
        return false;

    return AnneTraitorQuota_BlockTank(client, seconds);
}
