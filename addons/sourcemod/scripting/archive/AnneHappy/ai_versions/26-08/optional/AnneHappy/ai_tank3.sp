#pragma semicolon 1
#pragma newdecls required

// =========================================================================
// Ai-Tank 3
// 2.0 重写：
//   1. 移动决策以 NextBot 路径快照为准。梯子/高攀爬/深下落/跳跃间隙之前收住连跳，即将上梯时压回跑速；
//      只有“看得见、同一高度、路径本身就朝着目标”时才朝目标直追，高台上的人不再把 Tank 拽离上梯路线。
//   2. 撤离投石用的 BOT_CMD_MOVE 一定会 RESET（超时/停滞/上梯/计划结束），不再留下原地罚站的 Tank。
//   3. 接管 l4d_target_override 之后的最终选靶：沿用其过滤口径，按寻路距离排序，加换目标粘滞，爬梯期间冻结换靶。
//   4. 反头顶卡在路径能经梯子走到目标时放宽判定，梯子口排队/对准不再被当成恶意卡位。
// =========================================================================

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

#include "../../include/treeutil.inc"

#include "../../include/logger2.inc"

#include "../../include/anne_nextbot.inc"

#include "ai_path_movement.inc"
#undef REQUIRE_PLUGIN
#include <si_target_limit>
#define REQUIRE_PLUGIN
// 判定 AI Tank / 可见性等公共方法

#include "../../archive/AnneHappy/stocks.sp"

#include "ai_tank3/setup.inc"

#include "ai_tank3/path.inc"

#include "ai_tank3/target.inc"

#include "ai_tank3/command.inc"

#include "ai_tank3/overhead.inc"

#include "ai_tank3/movement.inc"

#include "ai_tank3/combat.inc"

public Plugin myinfo =
{
    name        = "Ai-Tank 3",
    author      = "夜羽真白, AnneHappy",
    description = "Ai Tank 增强 3.0 版本（路径感知连跳、梯子让行、寻路距离选目标、反头顶卡、骑头反制、投石瞄准等）",
    version     = "2.3.3",
    url         = "https://steamcommunity.com/id/saku_ra/"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, errMax, "本插件仅支持 Left 4 Dead 2");
        return APLRes_SilentFailure;
    }

    MarkNativeAsOptional("L4D_NavArea_GetLadder");
    MarkNativeAsOptional("AnneNextBot_IsActive");
    MarkNativeAsOptional("AnneNextBot_SetPathConsumer");
    MarkNativeAsOptional("AnneNextBot_GetPathSnapshotInfo");
    MarkNativeAsOptional("AnneNextBot_GetPathSegment");
    return APLRes_Success;
}

public void OnPluginStart()
{
    

    // 连跳
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    

    // 空速矫正
    
    
    

    // 投石 / 挥拳
    
    
    
    
    
    
    
    

    // 目标选择
    
    
    

    // 反头顶卡 / 骑头 / 强制投石
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    
    

    // 梯子
    
    
    
    

    // 日志
    
    char cvName[64];
    strcopy(cvName, sizeof(cvName), "ai_tank3");
    Format(cvName, sizeof(cvName), "%s_log_level", cvName);
    
    log = new Logger(PLUGIN_PREFIX, (32));

    HookEvent("round_start", Event_RoundReset, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundReset, EventHookMode_PostNoCopy);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_hurt", Event_PlayerHurt);

    g_hLadderNavList = new ArrayList();
    for (int client = 0; client <= MaxClients; client++)
        State_ResetClient(client, 0);
}

public void OnAllPluginsLoaded()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(path))
        SetFailState("Missing required gamedata file: %s", path);

    GameData gameData = new GameData(GAMEDATA);
    if (gameData == null)
        SetFailState("Failed to load %s gamedata.", GAMEDATA);

    // CTankClaw::SweepFist(start, end)
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(gameData, SDKConf_Signature, "CTankClaw::SweepFist");
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkTankClawSweepFist = EndPrepSDKCall();
    delete gameData;
    if (g_hSdkTankClawSweepFist == null)
        SetFailState("Failed to find signature for CTankClaw::SweepFist.");

    Path_EnableConsumer();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, ANNE_NEXTBOT_LIBRARY))
        Path_EnableConsumer();
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, ANNE_NEXTBOT_LIBRARY))
        g_bPathConsumerEnabled = false;
}

public void OnMapStart()
{
    // left4dhooks 换图时会移除全部动画钩子
    for (int client = 0; client <= MaxClients; client++)
    {
        g_bAnimHooked[client] = false;
        State_ResetClient(client, 0);
    }
    Path_EnableConsumer();
}

public void OnConfigsExecuted()
{
    if (g_cvTankSwingRange == null)
    {
        g_cvTankSwingRange = FindConVar("tank_swing_range");
        if (g_cvTankSwingRange != null)
            g_cvTankSwingRange.AddChangeHook(ConVarChanged_SwingRange);
    }
    g_fTankSwingRange = g_cvTankSwingRange == null ? DEFAULT_SWING_RANGE : g_cvTankSwingRange.FloatValue;
}

void ConVarChanged_SwingRange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_fTankSwingRange = convar.FloatValue;
}

public void OnPluginEnd()
{
    // 卸载时不能把正在执行撤离 MOVE 的 Tank 留在原地
    bool canCommand = GetFeatureStatus(FeatureType_Native, "L4D2_CommandABot") == FeatureStatus_Available;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_Tank[client].moveActive && canCommand && IsClientInGame(client) && IsFakeClient(client) && IsPlayerAlive(client))
            L4D2_CommandABot(client, 0, BOT_CMD_RESET);
        g_Tank[client].moveActive = false;
        Anim_RemoveHook(client);
    }

    Path_DisableConsumer();
    delete g_hLadderNavList;
    delete log;
}

public void OnClientDisconnect(int client)
{
    Anim_RemoveHook(client);
    State_ResetClient(client, 0);
}

void Event_RoundReset(Event event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
        State_ResetClient(client, 0);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int userId = event.GetInt("userid");
    int client = GetClientOfUserId(userId);
    if (client <= 0 || g_Tank[client].userId != userId)
        return;

    Anim_RemoveHook(client);
    State_ResetClient(client, 0);
}

// =========================================================================
// 主循环
// =========================================================================
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
    if (!true)
    {
        // 运行中关掉插件时，别把正在撤离的 Tank 留在 MOVE 命令里
        if (g_Tank[client].moveActive && isAiTank(client))
            Command_Reset(client, "plugin disabled");
        return Plugin_Continue;
    }
    if (!isAiTank(client))
        return Plugin_Continue;

    State_EnsureOwner(client);
    Anim_EnsureHook(client);

    // 只有最终返回 Plugin_Changed 时按键/视角修改才会生效，各子逻辑的结果必须聚合后返回
    Action result = Plugin_Continue;
    float now = GetEngineTime();
    float pos[3];
    GetClientAbsOrigin(client, pos);

    MoveType moveType = GetEntityMoveType(client);
    bool onLadder = moveType == MOVETYPE_LADDER;
    bool onGround = IsClientOnGround(client);
    // 地面/梯子登记必须每帧、在任何提前返回之前完成，否则停顿后的第一跳会白拿一份加速度
    if (onLadder || onGround)
        AIPathMovement_NotifyGrounded(client, onLadder);

    int target = Target_GetCurrent(client);
    float targetPos[3];
    if (target > 0)
        GetClientAbsOrigin(target, targetPos);
    Path_Update(client, pos, target, targetPos);
    if (true)
        Target_RefreshTravel(client, pos);

    bool ladderZone = onLadder || Movement_IsLadderZone(client, pos);
    if (ladderZone || moveType != MOVETYPE_WALK)
        Target_FreezeVictim(client, now);

    Command_Watchdog(client, pos, onLadder, now);

    if (onLadder)
    {
        if (true && Movement_LockLadderLook(client, pos, angles))
            result = Plugin_Changed;
        Movement_Reset(client);
        HeadBlock_Reset(client);
        return result;
    }

    // 攀爬/翻越等由引擎驱动位移的状态不改速度也不按键
    if (moveType != MOVETYPE_WALK)
    {
        Movement_Reset(client);
        return result;
    }

    int rider = Riding_FindRider(client);
    if (rider > 0)
    {
        if (Riding_Update(client, rider, buttons, now) == Plugin_Changed)
            result = Plugin_Changed;
    }
    else
    {
        Riding_Clear(client);
    }

    bool holdMovement;
    if (RockPlan_Update(client, buttons, pos, onGround, ladderZone, holdMovement, now) == Plugin_Changed)
        result = Plugin_Changed;

    // 投石目标可能与追人目标不同；普通投石即使没有追人目标也要检查起手机会。
    if (Combat_LimitThrowDistance(client, buttons))
        result = Plugin_Changed;

    if (rider > 0 || holdMovement || target <= 0)
    {
        Movement_Reset(client);
        return result;
    }

    if (HeadBlock_Update(client, target, pos, targetPos, now))
    {
        HeadBlock_OnFlagged(client, target, now);
        Movement_Reset(client);
        return result;
    }

    float dist = GetVectorDistance(pos, targetPos);

    if (ladderZone)
    {
        if (onGround || AIPathMovement_IsPathHopActive(client))
            Movement_BleedSpeed(client);
        Movement_Reset(client);
        return result;
    }

    Combat_PunchLockVision(client, pos, targetPos);

    bool visible = Target_IsVisible(client, target, targetPos);
    if (Movement_Bhop(client, buttons, pos, target, targetPos, dist, visible) == Plugin_Changed)
        result = Plugin_Changed;
    return result;
}

