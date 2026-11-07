#pragma semicolon 1
#pragma newdecls required

// Run only in an isolated server. Reuse the actual production restoration.
#define myinfo Production_Info
#define OnPluginStart Production_OnPluginStart
#include "../../optional/l4d2_melee_spawn_control.sp"
#undef myinfo
#undef OnPluginStart

Handle g_hTestGetMissionInfo;

public Plugin myinfo = {
    name = "Anne mission lifetime regression", author = "Anne", version = "1.0"
};

public void OnPluginStart()
{
    Production_OnPluginStart();
    GameData gd = new GameData(GAMEDATA);
    StartPrepSDKCall(SDKCall_GameRules);
    PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CTerrorGameRules::GetMissionInfo");
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hTestGetMissionInfo = EndPrepSDKCall();
    delete gd;
    if (g_hTestGetMissionInfo == null) SetFailState("GetMissionInfo test SDKCall failed");
    RegServerCmd("sm_melee_lifetime_test", Command_Test);
}

Action Command_Test(int args)
{
    #pragma unused args
    Address mission = SDKCall(g_hTestGetMissionInfo);
    if (mission == Address_Null) ThrowError("No current mission");

    char name[PLATFORM_MAX_PATH], original[MELEE_LIST_LENGTH], actual[MELEE_LIST_LENGTH];
    SDKCall(g_hSDKKvGetName, mission, name, sizeof(name));
    SDKCall(g_hSDKKvGetString, mission, original, sizeof(original), "meleeweapons", "");
    if (original[0] == '\0') ThrowError("Test requires a mission with an existing melee list");

    strcopy(g_sMissionName, sizeof(g_sMissionName), name);
    strcopy(g_sMissionMelee, sizeof(g_sMissionMelee), original);
    strcopy(g_sAppliedMelee, sizeof(g_sAppliedMelee), "knife");
    SDKCall(g_hSDKKvSetString, mission, "meleeweapons", "knife");
    RestoreMissionInfo();
    SDKCall(g_hSDKKvGetString, mission, actual, sizeof(actual), "meleeweapons", "");
    if (strcmp(actual, original) != 0) ThrowError("Live registry restoration failed for %s", name);
    RestoreMissionInfo(); // Repeated map-end/unload cleanup must be harmless.
    PrintToServer("[MeleeLifetimeTest] PASS live restore and repeated cleanup mission=%s", name);

    strcopy(g_sMissionName, sizeof(g_sMissionName), name);
    SDKCall(g_hSDKKvSetString, mission, "meleeweapons", "knife");
    ServerCommand("mission_reload");
    ServerExecute();
    // The old mission pointer is invalid now. Only production code resolves the new root.
    RestoreMissionInfo();
    mission = SDKCall(g_hTestGetMissionInfo);
    if (mission == Address_Null) ThrowError("No mission after mission_reload");
    SDKCall(g_hSDKKvGetString, mission, actual, sizeof(actual), "meleeweapons", "");
    if (strcmp(actual, original) != 0) ThrowError("Reloaded registry restoration failed for %s", name);
    PrintToServer("[MeleeLifetimeTest] PASS mission_reload and fresh registry restore mission=%s", name);

    strcopy(g_sMissionName, sizeof(g_sMissionName), "_anne_removed_lifetime_test_");
    RestoreMissionInfo();
    Address missions = SDKCall(g_hSDKGetAllMissions, g_pMatchExtL4D);
    SDKCall(g_hSDKKvGetString, missions, actual, sizeof(actual),
        "_anne_removed_lifetime_test_/meleeweapons", "missing");
    if (strcmp(actual, "missing") != 0) ThrowError("Cleanup recreated a removed mission");
    PrintToServer("[MeleeLifetimeTest] PASS missing mission ignored");
    return Plugin_Handled;
}
