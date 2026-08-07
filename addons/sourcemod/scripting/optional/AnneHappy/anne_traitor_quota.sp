#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>
#include <dbi>

#define CVAR_FLAG FCVAR_NOTIFY
#define DEFAULT_TRAITOR_QUOTA_DB_CONFIG "l4dstats"

enum struct TraitorQuotaConfig
{
    ConVar TraitorDailyQuota;
    ConVar TraitorPublicDailyQuota;
    ConVar TraitorQuotaDb;
    ConVar TraitorQuotaTable;
    int iTraitorDailyQuota;
    int iTraitorPublicDailyQuota;

    void Create()
    {
        this.TraitorDailyQuota = CreateConVar(
            "inf_traitor_daily_quota", "100",
            "Base daily traitor quota for admins; each full year remaining before sb_admins.expires adds 50.",
            CVAR_FLAG, true, 0.0, true, 10000.0);
        this.TraitorPublicDailyQuota = CreateConVar(
            "inf_traitor_public_daily_quota", "20",
            "Daily traitor quota available to eligible non-admin players.",
            CVAR_FLAG, true, 0.0, true, 10000.0);
        this.TraitorQuotaDb = CreateConVar(
            "inf_traitor_quota_db", DEFAULT_TRAITOR_QUOTA_DB_CONFIG,
            "MySQL databases.cfg section for shared traitor daily quota storage; defaults to the l4d_stats database.",
            CVAR_FLAG);
        this.TraitorQuotaTable = CreateConVar(
            "inf_traitor_quota_table", "infected_control_traitor_quota",
            "SQL table name for traitor daily quota storage.",
            CVAR_FLAG);

        this.TraitorDailyQuota.AddChangeHook(AnneTraitorQuota_OnConfigChanged);
        this.TraitorPublicDailyQuota.AddChangeHook(AnneTraitorQuota_OnConfigChanged);
        this.TraitorQuotaDb.AddChangeHook(AnneTraitorQuota_OnConfigChanged);
        this.TraitorQuotaTable.AddChangeHook(AnneTraitorQuota_OnConfigChanged);
        this.Refresh();
    }

    void Refresh()
    {
        this.iTraitorDailyQuota = this.TraitorDailyQuota.IntValue;
        if (this.iTraitorDailyQuota < 0) this.iTraitorDailyQuota = 0;
        if (this.iTraitorDailyQuota > 10000) this.iTraitorDailyQuota = 10000;

        this.iTraitorPublicDailyQuota = this.TraitorPublicDailyQuota.IntValue;
        if (this.iTraitorPublicDailyQuota < 0) this.iTraitorPublicDailyQuota = 0;
        if (this.iTraitorPublicDailyQuota > 10000) this.iTraitorPublicDailyQuota = 10000;
    }
}

TraitorQuotaConfig gCV;

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client);
}

#include "anne_traitor_quota/storage.inc"

public Plugin myinfo =
{
    name = "Anne Traitor Quota",
    author = "AnneHappy",
    description = "Optional MySQL-backed daily quota and Tank block provider for infected_control traitor mode",
    version = "1.0.0",
    url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int errMax)
{
    RegPluginLibrary("anne_traitor_quota");
    CreateNative("AnneTraitorQuota_CanUse", Native_AnneTraitorQuotaCanUse);
    CreateNative("AnneTraitorQuota_Consume", Native_AnneTraitorQuotaConsume);
    CreateNative("AnneTraitorQuota_Refund", Native_AnneTraitorQuotaRefund);
    CreateNative("AnneTraitorQuota_CanUseTank", Native_AnneTraitorQuotaCanUseTank);
    CreateNative("AnneTraitorQuota_BlockTank", Native_AnneTraitorQuotaBlockTank);
    CreateNative("AnneTraitorQuota_InvalidateClient", Native_AnneTraitorQuotaInvalidateClient);
    return APLRes_Success;
}

public void OnPluginStart()
{
    LoadTranslations("infected_control.phrases");
    gCV.Create();
    TraitorQuota_Init();
}

public void OnPluginEnd()
{
    TraitorQuota_Close();
}

public void OnClientDisconnect(int client)
{
    TraitorQuota_InvalidateClientCache(client);
}

public void OnClientPutInServer(int client)
{
    TraitorQuota_InvalidateClientCache(client);
}

public void AnneTraitorQuota_OnConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    gCV.Refresh();
    if (convar == gCV.TraitorQuotaDb || convar == gCV.TraitorQuotaTable)
    {
        TraitorQuota_Close();
        TraitorQuota_Init();
    }
    else
    {
        TraitorQuota_InvalidateAdminQuotaCache();
    }
}

public any Native_AnneTraitorQuotaCanUse(Handle plugin, int numParams)
{
    return TraitorQuota_CanUse(GetNativeCell(1), GetNativeCell(2));
}

public any Native_AnneTraitorQuotaConsume(Handle plugin, int numParams)
{
    return TraitorQuota_Consume(GetNativeCell(1), GetNativeCell(2));
}

public any Native_AnneTraitorQuotaRefund(Handle plugin, int numParams)
{
    return TraitorQuota_Refund(GetNativeCell(1), GetNativeCell(2));
}

public any Native_AnneTraitorQuotaCanUseTank(Handle plugin, int numParams)
{
    return TraitorQuota_CanUseTank(GetNativeCell(1));
}

public any Native_AnneTraitorQuotaBlockTank(Handle plugin, int numParams)
{
    return TraitorQuota_BlockTank(GetNativeCell(1), GetNativeCell(2));
}

public any Native_AnneTraitorQuotaInvalidateClient(Handle plugin, int numParams)
{
    TraitorQuota_InvalidateClientCache(GetNativeCell(1));
    return 0;
}
