#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// Run on a fresh isolated map with l4d2_door_lock enabled and no human exit.
// Observe the production door-lock command; it must run after both safe-area hooks.
Handle g_hOnFirstSurvivorLeftSafeArea;
bool g_bTesting, g_bInsideSafeAreaCall;
int g_iPreCalls, g_iPostCalls, g_iWarpCalls, g_iBotSerial;

public Plugin myinfo = {
    name = "Anne door-lock deferred bot return regression", author = "Anne", version = "1.1"
};

public void OnPluginStart()
{
    GameData gd = new GameData("left4dhooks.l4d2");
    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CDirector::OnFirstSurvivorLeftSafeArea");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    g_hOnFirstSurvivorLeftSafeArea = EndPrepSDKCall();
    delete gd;
    if (g_hOnFirstSurvivorLeftSafeArea == null) SetFailState("Safe-area test SDKCall failed");
    RegServerCmd("sm_safearea_lifetime_test", Command_Test);
    AddCommandListener(ObserveWarp, "warp_to_start_area");
}

Action Command_Test(int args)
{
    #pragma unused args
    ServerCommand("sm_l4dd_reload");
    ServerExecute();
    if (g_bTesting) ThrowError("Regression already running");
    int client = CreateFakeClient("LifetimeRegressionBot");
    if (client == 0) ThrowError("Could not create regression bot");
    ChangeClientTeam(client, 2);
    L4D_RespawnPlayer(client);
    g_iBotSerial = GetClientSerial(client);
    g_iPreCalls = g_iPostCalls = g_iWarpCalls = 0;
    g_bTesting = g_bInsideSafeAreaCall = true;
    SDKCall(g_hOnFirstSurvivorLeftSafeArea, L4D_GetPointer(POINTER_DIRECTOR), client);
    g_bInsideSafeAreaCall = false;
    if (g_iPreCalls != 1 || g_iPostCalls != 1 || g_iWarpCalls != 0) {
        ThrowError("Safe-area hook mismatch pre=%d post=%d warp=%d",
            g_iPreCalls, g_iPostCalls, g_iWarpCalls);
    }
    CreateTimer(0.2, Timer_Finish, _, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Handled;
}

Action ObserveWarp(int client, const char[] command, int argc)
{
    if (!g_bTesting || client == 0 || GetClientSerial(client) != g_iBotSerial) return Plugin_Continue;
    if (g_bInsideSafeAreaCall) ThrowError("Bot warp ran inside the safe-area call");
    g_iWarpCalls++;
    return Plugin_Continue;
}

Action Timer_Finish(Handle timer)
{
    g_bTesting = false;
    int client = GetClientFromSerial(g_iBotSerial);
    if (client != 0) KickClientEx(client, "Lifetime regression completed");
    if (g_iWarpCalls < 1) ThrowError("No deferred bot warp; use a fresh map with door-lock enabled");
    PrintToServer("[SafeAreaLifetimeTest] PASS pre=%d post=%d deferred_warp=%d",
        g_iPreCalls, g_iPostCalls, g_iWarpCalls);
    return Plugin_Handled;
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
    if (!g_bTesting || GetClientSerial(client) != g_iBotSerial) return Plugin_Continue;
    g_iPreCalls++;
    return Plugin_Handled;
}

public void L4D_OnFirstSurvivorLeftSafeArea_PostHandled(int client)
{
    if (!g_bTesting || GetClientSerial(client) != g_iBotSerial) return;
    if (!IsClientInGame(client)) ThrowError("Forward received a removed player");
    g_iPostCalls++;
}
