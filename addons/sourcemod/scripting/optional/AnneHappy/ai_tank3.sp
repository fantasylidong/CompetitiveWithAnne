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
#include <treeutil>
#include <logger2>
#include <anne_nextbot>
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
    version     = "2.2.0",
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
    g_cvEnable = CreateConVar("ai_tank3_enable", "1", "是否启用插件, 0=禁用, 1=启用", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 连跳
    g_cvTankBhop = CreateConVar("ai_tank_bhop", "1", "是否允许坦克连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopMinDist = CreateConVar("ai_Tank_StopDistance", "135", "停止连跳的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxDist = CreateConVar("ai_tank3_bhop_max_dist", "9999", "开始连跳的最大距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMinSpeed = CreateConVar("ai_tank3_bhop_min_speed", "200", "连跳的最小速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxSpeed = CreateConVar("ai_tank3_bhop_max_speed", "1000", "连跳的最大速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopImpulse = CreateConVar("ai_tank3_bhop_impulse", "60", "连跳的加速度（落地后紧接着再起跳时追加，从跑动直接起跳的第一跳按 ai_tank3_bhop_first_hop_ratio 折算）", CVAR_FLAGS, true, 0.0);
    g_cvBhopFirstHopRatio = CreateConVar("ai_tank3_bhop_first_hop_ratio", "1.0", "从跑动直接起跳的第一跳可拿到的加速度比例，0.0=不加速只改方向，1.0=与落地跳相同（旧行为）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopNoVision = CreateConVar("ai_tank3_bhop_no_vision", "1", "无视野是否允许连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopNoVisionMaxAng = CreateConVar("_ai_tank3_bhop_nvis_maxang", "75.0", "无视野时速度向量与视角前向向量阈值（度）", CVAR_FLAGS, true, 0.0);
    g_cvPathLookAheadMaxDepth = CreateConVar("ai_tank3_path_lookahead_maxdepth", "10", "沿路径连跳时向前搜索 PathSegment 的最大深度", CVAR_FLAGS, true, 1.0);
    g_cvDirectChaseMaxAngle = CreateConVar("_ai_tank3_direct_chase_max_angle", "45.0", "有视野时，路径前瞻方向与目标方向的夹角不超过该值才朝目标预测点直追，否则沿路径连跳（度）", CVAR_FLAGS, true, 0.0, true, 180.0);
    g_cvBhopStrafeAngle = CreateConVar("ai_tank3_bhop_strafe_angle", "15.0", "远距离安全直追时逐跳左右交替的偏角，0=关闭（度）", CVAR_FLAGS, true, 0.0, true, 35.0);
    g_cvBhopStrafeMinDist = CreateConVar("ai_tank3_bhop_strafe_min_dist", "600.0", "距离目标超过该值才主动左右连跳", CVAR_FLAGS, true, 0.0);

    // 空速矫正
    g_cvAirVecModifyDegree = CreateConVar("ai_tank3_airvec_modify_degree", "45.0", "追人时空速方向与目标方向角 >=此值 开始修正；路径跟随固定从1度开始", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyMaxDegree = CreateConVar("ai_tank3_airvec_modify_degree_max", "135.0", "角度 >此值 不再修正，实际最大89度", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyInterval = CreateConVar("ai_tank3_airvec_modify_interval", "0.3", "空中转向平滑响应时间(秒)，每0.05秒检查一次", CVAR_FLAGS, true, 0.1);

    // 投石 / 挥拳
    g_cvThrowMinDist = CreateConVar("ai_tank3_throw_min_dist", "0", "允许扔石头的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvThrowMaxDist = CreateConVar("ai_tank3_throw_max_dist", "800", "允许扔石头的最大距离", CVAR_FLAGS, true, 0.0);
    g_cvRockTargetAdjust = CreateConVar("ai_tank3_rock_target_adjust", "1", "出手时改为瞄准最近的可视生还者（强制投石计划指定的目标除外）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvJumpRock = CreateConVar("ai_tank3_jump_rock", "1", "扔石头起手时允许“跳砖”", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFist = CreateConVar("ai_tank3_back_fist", "1", "允许通背拳（可拍背后的人）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFistRange = CreateConVar("ai_tank3_back_fist_range", "128.0", "通背拳距离（-1 使用 tank_swing_range）", CVAR_FLAGS, true, -1.0);
    g_cvBackFistAllowMaxSpd = CreateConVar("ai_tank3_back_fist_max_spd", "50.0", "通背拳允许的最大移动速度（超过禁用）", CVAR_FLAGS, true, -1.0);
    g_cvBackFistWindow = CreateConVar("ai_tank3_back_fist_window", "3.0", "通背拳窗口（秒），Tank 爪击命中后开启/刷新", CVAR_FLAGS, true, 0.0);
    g_cvPunchLockVision = CreateConVar("ai_tank3_punch_lock_vision", "1", "挥拳时视角锁定目标", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 目标选择
    g_cvTargetSelect = CreateConVar("ai_tank3_target_select", "1", "Tank 选目标, 0=排序交给 l4d_target_override/原生（只换掉反头顶卡屏蔽的人）, 1=沿用 target_override 的过滤口径, 但按寻路距离排序并带换目标粘滞", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvTargetSwitchRatio = CreateConVar("ai_tank3_target_switch_ratio", "0.85", "同一层换目标时，新目标得分须不超过当前目标的这个比例（且差值不小于 ai_tank3_target_switch_gain）", CVAR_FLAGS, true, 0.1, true, 1.0);
    g_cvTargetSwitchGain = CreateConVar("ai_tank3_target_switch_gain", "75", "同一层换目标时，新目标得分至少要比当前目标低这么多（按寻路距离，单位）；应大于估距精度 64，否则估距误差会自己触发换目标", CVAR_FLAGS, true, 0.0);
    g_cvTargetCommitTime = CreateConVar("ai_tank3_target_commit_time", "1.0", "两次主动换目标之间的最短间隔（秒），当前目标失效或出现明显更好打的目标时不受限制", CVAR_FLAGS, true, 0.0);
    g_cvTargetDecisiveRatio = CreateConVar("ai_tank3_target_decisive_ratio", "0.5", "新目标得分不超过当前目标的这个比例时视为明显更好打，不等换目标间隔，0=关闭", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 反头顶卡 / 骑头 / 强制投石
    g_cvHeadBlockEnable = CreateConVar("ai_tank3_head_block_enable", "1", "是否启用 Tank 反头顶卡逻辑", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvHeadBlockTime = CreateConVar("ai_tank3_head_block_time", "2.0", "Tank 位于目标脚下的持续时间阈值（秒），路径能经梯子/攀爬走到目标时按 3 倍计算", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockVertical = CreateConVar("ai_tank3_head_block_vertical", "80.0", "触发头顶卡判定需要的垂直距离（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockHorizontal = CreateConVar("ai_tank3_head_block_horizontal", "65.0", "触发头顶卡判定的水平距离上限（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockIgnoreTime = CreateConVar("ai_tank3_head_block_ignore_time", "10.0", "判定恶意卡位后屏蔽该生还者的时间（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockTime = CreateConVar("ai_tank3_head_block_force_rock_time", "20.0", "强制投石尝试的最长时间（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockRange = CreateConVar("ai_tank3_head_block_force_rock_range", "250.0", "强制投石前 Tank 需要与目标拉开的最小水平距离（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseHoriz = CreateConVar("ai_tank3_head_block_force_rock_release_h", "400", "强制投石期间目标离开多远（水平距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockForceRockReleaseVert = CreateConVar("ai_tank3_head_block_force_rock_release_v", "250", "强制投石期间目标离开多远（垂直距离，单位）将立即清除强制状态（<=0 不检测）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideEnable = CreateConVar("ai_tank3_head_block_ride_enable", "1", "是否把 Tank 正上方的生还者按骑头处理（能命中则上挥，否则原地投石）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvHeadBlockRideHorizontal = CreateConVar("ai_tank3_head_block_ride_horizontal", "40.0", "骑头判定的水平距离上限（单位）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideVerticalMin = CreateConVar("ai_tank3_head_block_ride_vertical_min", "40.0", "骑头判定的最小垂直差（单位，脚站在 Tank 上时可被 GroundEntity 短路）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideVerticalMax = CreateConVar("ai_tank3_head_block_ride_vertical_max", "100.0", "骑头判定的最大垂直差（单位，超过视为高台而非骑头）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockRideRockTime = CreateConVar("ai_tank3_head_block_ride_rock_time", "3.0", "拳打不到的骑头目标持续多久后开始原地投石（秒）", CVAR_FLAGS, true, 0.0);
    g_cvHeadBlockUpSwing = CreateConVar("ai_tank3_head_block_up_swing", "1", "挥拳时对骑头生还者额外向上 SweepFist", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvRetreatTimeout = CreateConVar("ai_tank3_retreat_timeout", "3.0", "反头顶卡撤离投石时单次 MOVE 命令的最长持续时间（秒），到时必定 RESET", CVAR_FLAGS, true, 0.5);

    // 梯子
    g_cvLadderLookLock = CreateConVar("ai_tank3_ladder_look_lock", "1", "Tank 在梯子上时把视角锁到梯子朝向，避免抬头看人掉梯", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvLadderNearbyDisable = CreateConVar("ai_tank3_ladder_nearby_disable", "1", "Tank 即将爬梯时暂停连跳和挥拳锁视角，并把速度压回跑速", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvLadderNearbyRadius = CreateConVar("ai_tank3_ladder_nearby_radius", "180.0", "沿路径距离梯子入口多近算即将爬梯（路径快照不可用时按到梯子包围盒的水平距离）", CVAR_FLAGS, true, 0.0);
    g_cvLadderNearbyCacheTime = CreateConVar("ai_tank3_ladder_nearby_cache", "0.20", "路径快照不可用时，梯子实体检测的缓存时间（秒）", CVAR_FLAGS, true, 0.0);

    // 日志
    g_cvPluginName = CreateConVar("ai_tank3_plugin_name", "ai_tank3");
    char cvName[64];
    g_cvPluginName.GetString(cvName, sizeof(cvName));
    Format(cvName, sizeof(cvName), "%s_log_level", cvName);
    g_cvLogLevel = CreateConVar(cvName, "32", "日志级别: 1=关,2=控制台,4=log,8=chat,16=srv,32=err", CVAR_FLAGS);
    log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);

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
    if (!g_cvEnable.BoolValue)
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
    if (g_cvTargetSelect.BoolValue)
        Target_RefreshTravel(client, pos);

    bool ladderZone = onLadder || Movement_IsLadderZone(client, pos);
    if (ladderZone || moveType != MOVETYPE_WALK)
        Target_FreezeVictim(client, now);

    Command_Watchdog(client, pos, onLadder, now);

    if (onLadder)
    {
        if (g_cvLadderLookLock.BoolValue && Movement_LockLadderLook(client, pos, angles))
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
    if (Combat_LimitThrowDistance(client, buttons, dist))
        result = Plugin_Changed;

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
