#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.1.4"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_SMOKER 1
#define ZC_BOOMER 2
#define ZC_HUNTER 3
#define ZC_SPITTER 4
#define ZC_JOCKEY 5
#define ZC_CHARGER 6
#define ZC_TANK 8

#define NORMAL_SPEED 1.0
#define SPEED_EPSILON 0.01
#define CHECK_INTERVAL 0.1
#define SIGHT_CHECK_INTERVAL 0.05
#define MAX_SIGHT_SCANS_PER_TICK 2

ConVar g_cvEnabled;
ConVar g_cvSpeedMultiplier;
ConVar g_cvDetectionMethod;
ConVar g_cvCooldownTime;
ConVar g_cvDebugMode;

// Compatibility cvars from l4d2_si_ladder_booster.sp.
ConVar g_cvAiLadderBoost;
ConVar g_cvLegacyBoostMultiplier;
ConVar g_cvTankLadderBoost;
ConVar g_cvClimbAnimBoost;
ConVar g_cvSiClimbAnimRate;
ConVar g_cvTankClimbAnimRate;
ConVar g_cvTankLowClimbAnimRate;
ConVar g_cvTankLadderAnimRate;
ConVar g_cvClampExitSpeed;

bool g_bIsOnLadder[MAXPLAYERS + 1] = {false, ...};
bool g_bSpeedBoosted[MAXPLAYERS + 1] = {false, ...};
bool g_bWasOnLadder[MAXPLAYERS + 1] = {false, ...};
bool g_bClimbAnimBoosted[MAXPLAYERS + 1] = {false, ...};
bool g_bAnimHooked[MAXPLAYERS + 1] = {false, ...};
bool g_bLadderThinkHooked[MAXPLAYERS + 1] = {false, ...};
bool g_bLadderThinkRefreshPending[MAXPLAYERS + 1] = {false, ...};
bool g_bAiInfectedTracked[MAXPLAYERS + 1] = {false, ...};
bool g_bTrackedAiTank[MAXPLAYERS + 1] = {false, ...};
bool g_bCachedSightBoostAllowed[MAXPLAYERS + 1] = {false, ...};
bool g_bRoundActive;
float g_fOriginalSpeed[MAXPLAYERS + 1] = {0.0, ...};
float g_fActiveMultiplier[MAXPLAYERS + 1] = {0.0, ...};
float g_fCooldownEndTime[MAXPLAYERS + 1] = {0.0, ...};
float g_fNextSightCheckTime[MAXPLAYERS + 1] = {0.0, ...};
int g_iAiInfectedClients[MAXPLAYERS + 1];
int g_iAiInfectedCount;
int g_iSightBudgetTick = -1;
int g_iSightScansThisTick;

Handle g_hCheckTimer = null;
StringMap g_hTankClimbAnimMap;
StringMap g_hTankLowClimbAnimMap;

enum ClimbSequenceType
{
    ClimbSequence_High,
    ClimbSequence_Low
}

public Plugin myinfo =
{
    name = "[L4D2] Infected Ladder Speed Boost",
    author = "YourName, AiMee, AnneHappy",
    description = "AI infected ladder booster with visibility-gated boost and climb animation controls",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    LoadTranslations("l4d2_ai_ladder_boost.phrases");

    g_cvEnabled = CreateConVar("l4d2_ladder_boost_enabled", "1", "启用未被生还者看见时的AI特感爬梯加速 (0=禁用, 1=启用)", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvSpeedMultiplier = CreateConVar("l4d2_ladder_boost_multiplier", "10.0", "未被看见时的爬梯速度倍数", FCVAR_NONE, true, 1.0, true, 20.0);
    g_cvDetectionMethod = CreateConVar("l4d2_ladder_boost_detection", "0", "检测方法 (0=威胁感知+射线, 1=传统FOV+射线)", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvCooldownTime = CreateConVar("l4d2_ladder_boost_cooldown", "3.0", "被看见后禁用未视野加速的冷却时间(秒)", FCVAR_NONE, true, 1.0, true, 10.0);
    CreateConVar("l4d2_ladder_boost_use_sdkhook", "1", "兼容旧配置：已停用，AI特感固定使用Timer检测", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvDebugMode = CreateConVar("l4d2_ladder_boost_debug", "0", "调试模式 (0=关闭, 1=基本调试, 2=详细调试)", FCVAR_NONE, true, 0.0, true, 2.0);

    g_cvAiLadderBoost = CreateConVar("l4d2_ai_ladder_boost", "1", "兼容旧l4d2_si_ladder_booster：AI特感在梯子上固定加速", FCVAR_SPONLY, true, 0.0, true, 1.0);
    CreateConVar("l4d2_pz_ladder_boost", "0", "兼容旧l4d2_si_ladder_booster：已停用，真人特感不会获得加速", FCVAR_SPONLY, true, 0.0, true, 1.0);
    g_cvLegacyBoostMultiplier = CreateConVar("l4d2_boost_multiplier", "3.2", "兼容旧l4d2_si_ladder_booster：固定爬梯加速倍数", FCVAR_SPONLY, true, 1.0, true, 10.0);
    g_cvTankLadderBoost = CreateConVar("l4d2_ladder_boost_tank", "1", "是否允许该通用插件加速Tank爬梯", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvClimbAnimBoost = CreateConVar("l4d2_climb_anim_boost", "1", "是否由该插件处理AI Tank翻越/爬小障碍动画加速", FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvSiClimbAnimRate = CreateConVar("l4d2_si_climb_anim_rate", "3.2", "兼容旧配置：普通AI特感仅进行梯子移动加速，不再修改翻越动画速度", FCVAR_NONE, true, 0.0);
    g_cvTankClimbAnimRate = CreateConVar("l4d2_tank_climb_anim_rate", "3.5", "Tank 高翻越动画播放倍速（1.0=原速）", FCVAR_NONE, true, 0.0);
    g_cvTankLowClimbAnimRate = CreateConVar("l4d2_tank_low_climb_anim_rate", "2.5", "Tank 低翻越动画播放倍速（1.0=原速）", FCVAR_NONE, true, 0.0);
    g_cvTankLadderAnimRate = CreateConVar("l4d2_tank_ladder_anim_rate", "1.0", "Tank 梯子动画播放倍速；真实爬梯速度由 m_flLaggedMovementValue 控制", FCVAR_NONE, true, 0.0);
    g_cvClampExitSpeed = CreateConVar("l4d2_ladder_boost_clamp_exit_speed", "1", "特感离开梯子时将水平速度限制到当前走路速度，防止10倍速度带出", FCVAR_NONE, true, 0.0, true, 1.0);

    AutoExecConfig(true, "l4d2_infected_ladder_speed");

    InitClimbAnimMaps();

    RegAdminCmd("sm_ladder_debug", Command_LadderDebug, ADMFLAG_GENERIC, "显示插件调试信息");
    RegAdminCmd("sm_ladder_status", Command_LadderStatus, ADMFLAG_GENERIC, "显示所有玩家状态");

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("player_disconnect", Event_PlayerDisconnect);
    HookEvent("player_team", Event_PlayerTeam);
    HookEvent("player_bot_replace", Event_PlayerBotReplace);
    HookEvent("bot_player_replace", Event_PlayerBotReplace);

    HookBoostCvars();
    g_bRoundActive = IsGameRoundActive();
    RebuildAiInfectedCache();
    RefreshRuntimeHooks();
}

void HookBoostCvars()
{
    g_cvEnabled.AddChangeHook(OnConVarChanged);
    g_cvSpeedMultiplier.AddChangeHook(OnConVarChanged);
    g_cvDetectionMethod.AddChangeHook(OnConVarChanged);
    g_cvCooldownTime.AddChangeHook(OnConVarChanged);
    g_cvAiLadderBoost.AddChangeHook(OnConVarChanged);
    g_cvLegacyBoostMultiplier.AddChangeHook(OnConVarChanged);
    g_cvTankLadderBoost.AddChangeHook(OnConVarChanged);
    g_cvClimbAnimBoost.AddChangeHook(OnConVarChanged);
    g_cvSiClimbAnimRate.AddChangeHook(OnConVarChanged);
    g_cvTankClimbAnimRate.AddChangeHook(OnConVarChanged);
    g_cvTankLowClimbAnimRate.AddChangeHook(OnConVarChanged);
    g_cvTankLadderAnimRate.AddChangeHook(OnConVarChanged);
    g_cvClampExitSpeed.AddChangeHook(OnConVarChanged);
}

public void OnPluginEnd()
{
    StopCheckTimer();

    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bSpeedBoosted[i])
        {
            RestorePlayerSpeed(i);
        }
        RestorePlaybackRate(i);
        RemoveLadderThinkHook(i);
        RemoveAnimationHook(i);
    }

    delete g_hTankClimbAnimMap;
    delete g_hTankLowClimbAnimMap;
}

public void OnMapStart()
{
    RebuildAiInfectedCache();
    RefreshRuntimeHooks();
}

public void OnMapEnd()
{
    g_bRoundActive = false;
    StopCheckTimer();

    for (int i = 1; i <= MaxClients; i++)
    {
        g_bAnimHooked[i] = false;
        g_bLadderThinkHooked[i] = false;
        g_bLadderThinkRefreshPending[i] = false;
        g_bClimbAnimBoosted[i] = false;
        g_bAiInfectedTracked[i] = false;
        g_bTrackedAiTank[i] = false;
    }
    g_iAiInfectedCount = 0;
}

public void OnClientPostAdminCheck(int client)
{
    RefreshAiInfectedCache(client);
    RefreshClientAnimationHook(client);
    RefreshClientLadderThinkHook(client);
}

public void OnClientDisconnect(int client)
{
    UntrackAiInfected(client);
    RemoveLadderThinkHook(client);
    RemoveAnimationHook(client);
    ResetClientData(client);
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RefreshRuntimeHooks();

    for (int i = 0; i < g_iAiInfectedCount; i++)
    {
        int client = g_iAiInfectedClients[i];
        InvalidateSightCache(client);
        CheckAndUpdatePlayerSpeed(client);
    }
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = true;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bSpeedBoosted[i])
        {
            RestorePlayerSpeed(i);
        }
        RestorePlaybackRate(i);

        ResetClientData(i);
    }

    RebuildAiInfectedCache();
    RefreshRuntimeHooks();
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundActive = false;
    StopCheckTimer();

    for (int i = 0; i < g_iAiInfectedCount; i++)
    {
        int client = g_iAiInfectedClients[i];
        if (g_bSpeedBoosted[client])
        {
            RestorePlayerSpeed(client);
        }
        g_bIsOnLadder[client] = false;
        g_bWasOnLadder[client] = false;
        InvalidateSightCache(client);
        RefreshClientLadderThinkHook(client);
    }
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsValidClient(client))
    {
        return;
    }

    if (g_bSpeedBoosted[client])
    {
        RestorePlayerSpeed(client);
    }
    if (g_bWasOnLadder[client] && IsValidClient(client))
    {
        ClampClientExitVelocity(client);
    }
    RestorePlaybackRate(client);

    ResetClientData(client);

    RefreshAiInfectedCache(client);
    RefreshClientAnimationHook(client);
    RefreshClientLadderThinkHook(client);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0)
    {
        return;
    }

    if (g_bSpeedBoosted[client])
    {
        RestorePlayerSpeed(client);
    }
    RestorePlaybackRate(client);
    UntrackAiInfected(client);
    RemoveLadderThinkHook(client);
    RemoveAnimationHook(client);

    ResetClientData(client);
}

void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0)
    {
        UntrackAiInfected(client);
        RemoveLadderThinkHook(client);
        RemoveAnimationHook(client);
        ResetClientData(client);
    }
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    RequestFrame(Frame_RefreshClientState, event.GetInt("userid"));
}

public Action L4D_OnFirstSurvivorLeftSafeArea(int client)
{
    if (!g_bRoundActive)
    {
        g_bRoundActive = true;
        RebuildAiInfectedCache();
        RefreshRuntimeHooks();
    }
    return Plugin_Continue;
}

void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
    int playerUserId = event.GetInt("player");
    int botUserId = event.GetInt("bot");
    if (playerUserId > 0)
    {
        RequestFrame(Frame_RefreshClientState, playerUserId);
    }
    if (botUserId > 0)
    {
        RequestFrame(Frame_RefreshClientState, botUserId);
    }
}

void Frame_RefreshClientState(any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0)
    {
        return;
    }

    RefreshAiInfectedCache(client);
    RefreshClientAnimationHook(client);
    RefreshClientLadderThinkHook(client);
}

void RebuildAiInfectedCache()
{
    g_iAiInfectedCount = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        g_bAiInfectedTracked[client] = false;
        g_bTrackedAiTank[client] = false;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsAiInfected(client))
        {
            TrackAiInfected(client);
        }
    }
}

void RefreshAiInfectedCache(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (IsAiInfected(client))
    {
        g_bTrackedAiTank[client] = GetZombieClass(client) == ZC_TANK;
        TrackAiInfected(client);
        return;
    }

    if (g_bSpeedBoosted[client])
    {
        RestorePlayerSpeed(client);
    }
    if (g_bWasOnLadder[client] && IsValidClient(client))
    {
        ClampClientExitVelocity(client);
    }
    g_bIsOnLadder[client] = false;
    g_bWasOnLadder[client] = false;
    InvalidateSightCache(client);
    UntrackAiInfected(client);
    RefreshClientLadderThinkHook(client);
}

void TrackAiInfected(int client)
{
    if (client < 1 || client > MaxClients || g_bAiInfectedTracked[client])
    {
        return;
    }

    g_bAiInfectedTracked[client] = true;
    g_bTrackedAiTank[client] = GetZombieClass(client) == ZC_TANK;
    g_iAiInfectedClients[g_iAiInfectedCount++] = client;

    if (g_iAiInfectedCount == 1 && ShouldRunBoostChecks())
    {
        StartCheckTimer();
    }
}

void UntrackAiInfected(int client)
{
    if (client < 1 || client > MaxClients || !g_bAiInfectedTracked[client])
    {
        return;
    }

    g_bAiInfectedTracked[client] = false;
    g_bTrackedAiTank[client] = false;
    for (int i = 0; i < g_iAiInfectedCount; i++)
    {
        if (g_iAiInfectedClients[i] != client)
        {
            continue;
        }

        g_iAiInfectedCount--;
        g_iAiInfectedClients[i] = g_iAiInfectedClients[g_iAiInfectedCount];
        g_iAiInfectedClients[g_iAiInfectedCount] = 0;
        return;
    }
}

void RefreshRuntimeHooks()
{
    bool shouldRun = ShouldRunBoostChecks() && g_iAiInfectedCount > 0;
    if (shouldRun)
    {
        StartCheckTimer();
    }
    else
    {
        StopCheckTimer();
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        RefreshClientAnimationHook(i);
        RefreshClientLadderThinkHook(i);
    }
}

bool ShouldRunBoostChecks()
{
    return g_bRoundActive && (g_cvEnabled.BoolValue || g_cvAiLadderBoost.BoolValue || g_cvTankLadderBoost.BoolValue);
}

bool IsGameRoundActive()
{
    return GameRules_GetPropFloat("m_flRoundStartTime") > 0.0
        && GameRules_GetPropFloat("m_flRoundEndTime") == 0.0;
}

void StartCheckTimer()
{
    if (!ShouldRunBoostChecks() || g_iAiInfectedCount < 1 || g_hCheckTimer != null)
    {
        return;
    }

    g_hCheckTimer = CreateTimer(CHECK_INTERVAL, Timer_CheckPlayers, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void StopCheckTimer()
{
    Handle timer = g_hCheckTimer;
    g_hCheckTimer = null;

    // TIMER_FLAG_NO_MAPCHANGE timers may already have been closed by SourceMod
    // before OnMapEnd/OnPluginEnd reaches this plugin.
    if (timer == null || !IsValidHandle(timer))
    {
        return;
    }

    KillTimer(timer);
}

void SetupAnimationHook(int client)
{
    if (!ShouldHookTankAnimation(client) || g_bAnimHooked[client])
    {
        return;
    }

    AnimHookEnable(client, INVALID_FUNCTION, Hook_AnimationPost);
    g_bAnimHooked[client] = true;
}

void RefreshClientAnimationHook(int client)
{
    if (ShouldHookTankAnimation(client))
    {
        SetupAnimationHook(client);
    }
    else
    {
        RestorePlaybackRate(client);
        RemoveAnimationHook(client);
    }
}

bool ShouldHookTankAnimation(int client)
{
    return g_cvClimbAnimBoost.BoolValue && IsAiInfected(client) && IsTank(client);
}

bool IsTankAnimationHookActive(int client)
{
    return client > 0 && client <= MaxClients && g_bAnimHooked[client] && g_cvClimbAnimBoost.BoolValue;
}

void RemoveAnimationHook(int client)
{
    if (client < 1 || client > MaxClients || !g_bAnimHooked[client])
    {
        return;
    }

    if (!IsValidClient(client))
    {
        g_bAnimHooked[client] = false;
        return;
    }

    AnimHookDisable(client, INVALID_FUNCTION, Hook_AnimationPost);
    g_bAnimHooked[client] = false;
}

bool ShouldHookPersistentTankThink(int client)
{
    return ShouldRunBoostChecks()
        && IsAiInfected(client)
        && IsTank(client)
        && (g_cvTankLadderBoost.BoolValue || g_cvClimbAnimBoost.BoolValue);
}

bool ShouldHookActiveSiLadderThink(int client)
{
    return ShouldRunBoostChecks()
        && g_bAiInfectedTracked[client]
        && !g_bTrackedAiTank[client]
        && (g_bWasOnLadder[client] || g_bSpeedBoosted[client]);
}

void RefreshClientLadderThinkHook(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    if (ShouldHookPersistentTankThink(client) || ShouldHookActiveSiLadderThink(client))
    {
        if (!g_bLadderThinkHooked[client])
        {
            SDKHook(client, SDKHook_PostThinkPost, Hook_ClimbAnimThink);
            g_bLadderThinkHooked[client] = true;
        }
        return;
    }

    RemoveLadderThinkHook(client);
}

void RemoveLadderThinkHook(int client)
{
    if (client < 1 || client > MaxClients || !g_bLadderThinkHooked[client])
    {
        return;
    }

    if (IsValidClient(client))
    {
        SDKUnhook(client, SDKHook_PostThinkPost, Hook_ClimbAnimThink);
    }
    g_bLadderThinkHooked[client] = false;
}

void QueueLadderThinkRefresh(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    bool shouldHook = ShouldHookPersistentTankThink(client) || ShouldHookActiveSiLadderThink(client);
    if (shouldHook == g_bLadderThinkHooked[client] || g_bLadderThinkRefreshPending[client])
    {
        return;
    }

    g_bLadderThinkRefreshPending[client] = true;
    RequestFrame(Frame_RefreshLadderThinkHook, GetClientUserId(client));
}

void Frame_RefreshLadderThinkHook(any userId)
{
    int client = GetClientOfUserId(userId);
    if (client <= 0)
    {
        return;
    }

    g_bLadderThinkRefreshPending[client] = false;
    RefreshClientLadderThinkHook(client);
}

Action Hook_AnimationPost(int client, int &sequence)
{
    if (!IsTankAnimationHookActive(client))
    {
        return Plugin_Continue;
    }

    float rate = GetClimbPlaybackRate(client, sequence);
    if (rate <= NORMAL_SPEED + SPEED_EPSILON)
    {
        return Plugin_Continue;
    }

    SetClientPlaybackRate(client, rate);
    g_bClimbAnimBoosted[client] = true;
    return Plugin_Continue;
}

public void Hook_ClimbAnimThink(int client)
{
    if (!g_bLadderThinkHooked[client])
    {
        return;
    }

    CheckAndUpdatePlayerSpeed(client);

    if (!IsTankAnimationHookActive(client))
    {
        RestorePlaybackRate(client);
        return;
    }

    if (IsPlayerOnLadder(client))
    {
        float ladderRate = g_cvTankLadderAnimRate.FloatValue;
        if (ladderRate > NORMAL_SPEED + SPEED_EPSILON)
        {
            SetClientPlaybackRate(client, ladderRate);
            g_bClimbAnimBoosted[client] = true;
            return;
        }
    }

    int sequence = GetEntProp(client, Prop_Data, "m_nSequence");
    float rate = GetClimbPlaybackRate(client, sequence);
    if (rate > NORMAL_SPEED + SPEED_EPSILON)
    {
        SetClientPlaybackRate(client, rate);
        g_bClimbAnimBoosted[client] = true;
        return;
    }

    RestorePlaybackRate(client);
}

public Action Timer_CheckPlayers(Handle timer)
{
    if (g_hCheckTimer != timer)
    {
        return Plugin_Stop;
    }

    if (!ShouldRunBoostChecks())
    {
        g_hCheckTimer = null;
        return Plugin_Stop;
    }

    if (g_iAiInfectedCount < 1)
    {
        g_hCheckTimer = null;
        return Plugin_Stop;
    }

    for (int i = 0; i < g_iAiInfectedCount;)
    {
        int client = g_iAiInfectedClients[i];
        if (!IsAiInfected(client))
        {
            RefreshAiInfectedCache(client);
            continue;
        }

        if (!g_bSpeedBoosted[client] && !g_bWasOnLadder[client] && IsClassAllowedForBoost(client))
        {
            UpdateAiInfectedLadderSpeed(client, IsPlayerOnLadder(client));
        }
        i++;
    }

    return Plugin_Continue;
}

void CheckAndUpdatePlayerSpeed(int client)
{
    if (!g_bRoundActive || !IsAiInfected(client))
    {
        if (g_bWasOnLadder[client] && IsValidClient(client))
        {
            ClampClientExitVelocity(client);
        }
        if (g_bSpeedBoosted[client])
        {
            RestorePlayerSpeed(client);
        }
        g_bIsOnLadder[client] = false;
        g_bWasOnLadder[client] = false;
        InvalidateSightCache(client);
        QueueLadderThinkRefresh(client);
        return;
    }

    bool isOnLadder = IsPlayerOnLadder(client);
    UpdateAiInfectedLadderSpeed(client, isOnLadder);
}

void UpdateAiInfectedLadderSpeed(int client, bool isOnLadder)
{
    g_bIsOnLadder[client] = isOnLadder;

    if (!isOnLadder)
    {
        if (g_bWasOnLadder[client])
        {
            ClampClientExitVelocity(client);
        }
        if (g_bSpeedBoosted[client])
        {
            RestorePlayerSpeed(client);
        }
        g_bWasOnLadder[client] = false;
        InvalidateSightCache(client);
        QueueLadderThinkRefresh(client);
        return;
    }

    if (!IsClassAllowedForBoost(client))
    {
        if (g_bSpeedBoosted[client])
        {
            RestorePlayerSpeed(client);
        }
        QueueLadderThinkRefresh(client);
        return;
    }

    float multiplier = GetDesiredBoostMultiplier(client);
    if (multiplier <= NORMAL_SPEED + SPEED_EPSILON)
    {
        if (g_bSpeedBoosted[client])
        {
            RestorePlayerSpeed(client);
        }
        QueueLadderThinkRefresh(client);
        return;
    }

    g_bWasOnLadder[client] = true;
    ApplyPlayerSpeed(client, multiplier);
    QueueLadderThinkRefresh(client);
}

float GetDesiredBoostMultiplier(int client)
{
    float multiplier = NORMAL_SPEED;
    bool tank = g_bTrackedAiTank[client];

    if (tank && g_cvTankLadderBoost.BoolValue)
    {
        multiplier = MaxFloat(multiplier, g_cvLegacyBoostMultiplier.FloatValue);
    }

    if (!tank && g_cvAiLadderBoost.BoolValue)
    {
        multiplier = MaxFloat(multiplier, g_cvLegacyBoostMultiplier.FloatValue);
    }

    if (!tank && g_cvEnabled.BoolValue && IsSightBoostAllowed(client))
    {
        multiplier = MaxFloat(multiplier, g_cvSpeedMultiplier.FloatValue);
    }

    return multiplier;
}

bool IsSightBoostAllowed(int client)
{
    float currentTime = GetGameTime();
    if (currentTime < g_fCooldownEndTime[client])
    {
        g_bCachedSightBoostAllowed[client] = false;
        if (g_cvDebugMode.IntValue >= 1)
        {
            char name[64];
            GetClientName(client, name, sizeof(name));
            PrintToServer("[LadderBoost] %s sight boost cooldown %.1fs", name, g_fCooldownEndTime[client] - currentTime);
        }
        return false;
    }

    if (currentTime < g_fNextSightCheckTime[client])
    {
        return g_bCachedSightBoostAllowed[client];
    }

    if (!AcquireSightScanBudget())
    {
        g_bCachedSightBoostAllowed[client] = false;
        g_fNextSightCheckTime[client] = currentTime + GetTickInterval();
        return false;
    }

    bool visible = IsInfectedVisibleToSurvivors(client);
    g_fNextSightCheckTime[client] = currentTime + SIGHT_CHECK_INTERVAL;
    g_bCachedSightBoostAllowed[client] = !visible;

    if (g_cvDebugMode.IntValue >= 1)
    {
        char name[64];
        GetClientName(client, name, sizeof(name));
        PrintToServer("[LadderBoost] %s visible=%s boosted=%s",
            name, visible ? "yes" : "no", g_bSpeedBoosted[client] ? "yes" : "no");
    }

    if (visible)
    {
        g_fCooldownEndTime[client] = currentTime + g_cvCooldownTime.FloatValue;
        return false;
    }

    return true;
}

bool AcquireSightScanBudget()
{
    int currentTick = GetGameTickCount();
    if (currentTick != g_iSightBudgetTick)
    {
        g_iSightBudgetTick = currentTick;
        g_iSightScansThisTick = 0;
    }

    if (g_iSightScansThisTick >= MAX_SIGHT_SCANS_PER_TICK)
    {
        return false;
    }

    g_iSightScansThisTick++;
    return true;
}

void InvalidateSightCache(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_bCachedSightBoostAllowed[client] = false;
    g_fNextSightCheckTime[client] = 0.0;
}

void ApplyPlayerSpeed(int client, float multiplier)
{
    if (!g_bSpeedBoosted[client])
    {
        g_fOriginalSpeed[client] = GetClientSpeed(client);
        if (g_fOriginalSpeed[client] <= 0.0)
        {
            g_fOriginalSpeed[client] = NORMAL_SPEED;
        }
        g_bSpeedBoosted[client] = true;
    }

    float desiredSpeed = multiplier;
    float currentSpeed = GetClientSpeed(client);
    if (FloatAbs(currentSpeed - desiredSpeed) > SPEED_EPSILON)
    {
        SetClientSpeed(client, desiredSpeed);
    }

    if (FloatAbs(g_fActiveMultiplier[client] - multiplier) > SPEED_EPSILON && g_cvDebugMode.IntValue >= 1)
    {
        char name[64];
        GetClientName(client, name, sizeof(name));
        PrintToServer("[LadderBoost] %s ladder speed %.1fx", name, multiplier);
        PrintToChatAll("%t", "L4D2AILadderBoost_LadderAccelerationGetLadderAcceleration", name);
    }

    g_fActiveMultiplier[client] = multiplier;
}

void RestorePlayerSpeed(int client, bool clampVelocity = false)
{
    if (!IsValidClient(client) || !g_bSpeedBoosted[client])
    {
        return;
    }

    if (clampVelocity)
    {
        ClampClientExitVelocity(client);
    }

    float restoreSpeed = (g_fOriginalSpeed[client] > 0.0) ? g_fOriginalSpeed[client] : NORMAL_SPEED;
    SetClientSpeed(client, restoreSpeed);

    if (g_cvDebugMode.IntValue >= 1)
    {
        char name[64];
        GetClientName(client, name, sizeof(name));
        PrintToServer("[LadderBoost] %s restore ladder speed", name);
        PrintToChatAll("%t", "L4D2AILadderBoost_LadderAccelerationRestoreOriginalSpeed", name);
    }

    g_bSpeedBoosted[client] = false;
    g_fOriginalSpeed[client] = 0.0;
    g_fActiveMultiplier[client] = 0.0;
}

void ResetClientData(int client)
{
    if (client < 1 || client > MaxClients)
    {
        return;
    }

    g_bIsOnLadder[client] = false;
    g_bSpeedBoosted[client] = false;
    g_bWasOnLadder[client] = false;
    g_bClimbAnimBoosted[client] = false;
    g_bLadderThinkRefreshPending[client] = false;
    g_fOriginalSpeed[client] = 0.0;
    g_fActiveMultiplier[client] = 0.0;
    g_fCooldownEndTime[client] = 0.0;
    InvalidateSightCache(client);
}

void InitClimbAnimMaps()
{
    if (!g_hTankClimbAnimMap)
    {
        g_hTankClimbAnimMap = new StringMap();
    }
    if (!g_hTankLowClimbAnimMap)
    {
        g_hTankLowClimbAnimMap = new StringMap();
    }

    g_hTankClimbAnimMap.SetValue("ACT_DIESIMPLE", true);
    g_hTankClimbAnimMap.SetValue("ACT_DIEBACKWARD", true);
    g_hTankClimbAnimMap.SetValue("ACT_DIEFORWARD", true);
    g_hTankClimbAnimMap.SetValue("ACT_DIEVIOLENT", true);

    g_hTankLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK1", true);
    g_hTankLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK2", true);
    g_hTankLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK1_LOW", true);
    g_hTankLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK2_LOW", true);
}

float GetClimbPlaybackRate(int client, int sequence)
{
    if (!IsTankAnimationHookActive(client))
    {
        return NORMAL_SPEED;
    }

    ClimbSequenceType type;
    if (!GetTankClimbSequenceType(sequence, type))
    {
        return NORMAL_SPEED;
    }

    return type == ClimbSequence_Low ? g_cvTankLowClimbAnimRate.FloatValue : g_cvTankClimbAnimRate.FloatValue;
}

bool GetTankClimbSequenceType(int sequence, ClimbSequenceType &type)
{
    if (sequence < 0)
    {
        return false;
    }

    char seqName[64];
    if (!AnimGetActivity(sequence, seqName, sizeof(seqName)))
    {
        return false;
    }

    if (g_hTankLowClimbAnimMap && g_hTankLowClimbAnimMap.ContainsKey(seqName))
    {
        type = ClimbSequence_Low;
        return true;
    }

    if (g_hTankClimbAnimMap && g_hTankClimbAnimMap.ContainsKey(seqName))
    {
        type = ClimbSequence_High;
        return true;
    }

    return false;
}

void RestorePlaybackRate(int client)
{
    if (client < 1 || client > MaxClients || !g_bClimbAnimBoosted[client])
    {
        return;
    }

    if (IsValidClient(client))
    {
        SetClientPlaybackRate(client, NORMAL_SPEED);
    }

    g_bClimbAnimBoosted[client] = false;
}

void SetClientPlaybackRate(int client, float value)
{
    if (!IsValidClient(client))
    {
        return;
    }

    float current = GetEntPropFloat(client, Prop_Send, "m_flPlaybackRate");
    if (FloatAbs(current - value) > SPEED_EPSILON)
    {
        SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", value);
    }
}

void ClampClientExitVelocity(int client)
{
    if (!g_cvClampExitSpeed.BoolValue || !IsValidClient(client))
    {
        return;
    }

    float maxSpeed = GetClientWalkSpeed(client);
    if (maxSpeed <= 0.0)
    {
        return;
    }

    float velocity[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", velocity);
    float horizontal = SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
    if (horizontal <= maxSpeed || horizontal <= 0.0)
    {
        return;
    }

    float scale = maxSpeed / horizontal;
    velocity[0] *= scale;
    velocity[1] *= scale;
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velocity);
}

float GetClientWalkSpeed(int client)
{
    if (HasEntProp(client, Prop_Send, "m_flMaxspeed"))
    {
        float speed = GetEntPropFloat(client, Prop_Send, "m_flMaxspeed");
        if (speed > 0.0)
        {
            return speed;
        }
    }

    switch (GetZombieClass(client))
    {
        case ZC_SMOKER: return 210.0;
        case ZC_BOOMER: return 175.0;
        case ZC_HUNTER: return 300.0;
        case ZC_SPITTER: return 210.0;
        case ZC_JOCKEY: return 250.0;
        case ZC_CHARGER: return 250.0;
        case ZC_TANK: return 210.0;
    }

    return 250.0;
}

bool IsClassAllowedForBoost(int client)
{
    if (g_bTrackedAiTank[client])
    {
        return g_cvTankLadderBoost.BoolValue;
    }

    return g_cvAiLadderBoost.BoolValue || g_cvEnabled.BoolValue;
}

bool IsValidInfected(int client)
{
    return IsValidClient(client) && GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client);
}

bool IsAiInfected(int client)
{
    return IsValidInfected(client) && IsFakeClient(client);
}

bool IsValidClient(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsClientInKickQueue(client);
}

bool IsPlayerOnLadder(int client)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsValidEntity(client))
    {
        return false;
    }

    if (!HasEntProp(client, Prop_Data, "m_MoveType"))
    {
        if (g_cvDebugMode.IntValue >= 2)
        {
            LogMessage("[LadderBoost] client %d missing m_MoveType", client);
        }
        return false;
    }

    return GetEntityMoveType(client) == MOVETYPE_LADDER;
}

bool IsTank(int client)
{
    if (!IsValidInfected(client))
    {
        return false;
    }

    return GetZombieClass(client) == ZC_TANK;
}

int GetZombieClass(int client)
{
    if (!IsValidClient(client) || !HasEntProp(client, Prop_Send, "m_zombieClass"))
    {
        return 0;
    }

    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

void SetClientSpeed(int client, float value)
{
    SetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue", value);
}

float GetClientSpeed(int client)
{
    return GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
}

float MaxFloat(float a, float b)
{
    return (a > b) ? a : b;
}

bool IsInfectedVisibleToSurvivors(int infected)
{
    if (g_cvDetectionMethod.IntValue == 0)
    {
        return UseNewRaycastDetection(infected);
    }

    return UseTraditionalDetection(infected);
}

bool UseNewRaycastDetection(int infected)
{
    if (!IsAiInfected(infected))
    {
        return false;
    }

    float infectedPos[3];
    GetClientEyePosition(infected, infectedPos);

    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidClient(survivor) || GetClientTeam(survivor) != TEAM_SURVIVOR || !IsPlayerAlive(survivor))
        {
            continue;
        }

        bool hasThreats = false;
        if (HasEntProp(survivor, Prop_Send, "m_hasVisibleThreats"))
        {
            hasThreats = GetEntProp(survivor, Prop_Send, "m_hasVisibleThreats") > 0;
        }

        if (!hasThreats)
        {
            continue;
        }

        float survivorPos[3];
        GetClientEyePosition(survivor, survivorPos);
        if (GetVectorDistance(survivorPos, infectedPos) > 1500.0)
        {
            continue;
        }

        if (!IsInSurvivorFOV(survivor, infected, infectedPos, survivorPos))
        {
            continue;
        }

        Handle trace = TR_TraceRayFilterEx(survivorPos, infectedPos, MASK_VISIBLE, RayType_EndPoint, TraceFilter_IgnorePlayers);
        bool visible = !TR_DidHit(trace);
        CloseHandle(trace);

        if (visible)
        {
            return true;
        }
    }

    return false;
}

bool UseTraditionalDetection(int infected)
{
    if (!IsAiInfected(infected))
    {
        return false;
    }

    float infectedPos[3];
    GetClientEyePosition(infected, infectedPos);

    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidClient(survivor) || GetClientTeam(survivor) != TEAM_SURVIVOR || !IsPlayerAlive(survivor))
        {
            continue;
        }

        float survivorPos[3];
        GetClientEyePosition(survivor, survivorPos);
        if (GetVectorDistance(infectedPos, survivorPos) > 1500.0)
        {
            continue;
        }

        if (!IsInSurvivorFOV(survivor, infected, infectedPos, survivorPos))
        {
            continue;
        }

        Handle trace = TR_TraceRayFilterEx(survivorPos, infectedPos, MASK_VISIBLE, RayType_EndPoint, TraceFilter_IgnorePlayers);
        bool visible = !TR_DidHit(trace);
        CloseHandle(trace);

        if (visible)
        {
            return true;
        }
    }

    return false;
}

bool IsInSurvivorFOV(int survivor, int infected, const float infectedPos[3], const float survivorPos[3])
{
    if (!IsValidClient(survivor) || !IsValidClient(infected))
    {
        return false;
    }

    float survivorAngles[3];
    GetClientEyeAngles(survivor, survivorAngles);

    float toInfected[3];
    SubtractVectors(infectedPos, survivorPos, toInfected);
    NormalizeVector(toInfected, toInfected);

    float survivorForward[3];
    GetAngleVectors(survivorAngles, survivorForward, NULL_VECTOR, NULL_VECTOR);

    float dot = GetVectorDotProduct(survivorForward, toInfected);
    return dot > 0.707;
}

public bool TraceFilter_IgnorePlayers(int entity, int contentsMask, any data)
{
    return entity > MaxClients;
}

public Action Command_LadderDebug(int client, int args)
{
    PrintToConsole(client, "=== Ladder Boost Debug ===");
    PrintToConsole(client, "Sight boost: %s", g_cvEnabled.BoolValue ? "on" : "off");
    PrintToConsole(client, "Sight multiplier: %.1fx", g_cvSpeedMultiplier.FloatValue);
    PrintToConsole(client, "Legacy AI boost: %s", g_cvAiLadderBoost.BoolValue ? "on" : "off");
    PrintToConsole(client, "Legacy PZ boost: ignored (AI only)");
    PrintToConsole(client, "Legacy multiplier: %.1fx", g_cvLegacyBoostMultiplier.FloatValue);
    PrintToConsole(client, "Tank boost: %s", g_cvTankLadderBoost.BoolValue ? "on" : "off");
    PrintToConsole(client, "Detection: %s", g_cvDetectionMethod.IntValue == 0 ? "threat+ray" : "fov+ray");
    PrintToConsole(client, "Cooldown: %.1fs", g_cvCooldownTime.FloatValue);
    PrintToConsole(client, "Realtime speed hook: ignored (AI uses timer)");
    PrintToConsole(client, "Debug mode: %d", g_cvDebugMode.IntValue);

    float currentTime = GetGameTime();
    PrintToConsole(client, "\n=== Player State ===");

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || !IsPlayerAlive(i))
        {
            continue;
        }

        char name[64];
        GetClientName(i, name, sizeof(name));

        if (GetClientTeam(i) == TEAM_INFECTED)
        {
            bool hasThreats = false;
            if (HasEntProp(i, Prop_Send, "m_hasVisibleThreats"))
            {
                hasThreats = GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0;
            }

            float cooldownRemaining = g_fCooldownEndTime[i] - currentTime;
            if (cooldownRemaining < 0.0)
            {
                cooldownRemaining = 0.0;
            }

            PrintToConsole(client, "SI %s%s: ladder=%s, boosted=%s, speed=%.2f, mult=%.1f, threats=%s, cooldown=%.1fs%s",
                name,
                IsFakeClient(i) ? "[AI]" : "[PZ]",
                g_bIsOnLadder[i] ? "yes" : "no",
                g_bSpeedBoosted[i] ? "yes" : "no",
                GetClientSpeed(i),
                g_fActiveMultiplier[i],
                hasThreats ? "yes" : "no",
                cooldownRemaining,
                IsTank(i) ? ", tank" : "");
        }
        else if (GetClientTeam(i) == TEAM_SURVIVOR)
        {
            bool hasThreats = false;
            if (HasEntProp(i, Prop_Send, "m_hasVisibleThreats"))
            {
                hasThreats = GetEntProp(i, Prop_Send, "m_hasVisibleThreats") > 0;
            }

            PrintToConsole(client, "Survivor %s: threats=%s", name, hasThreats ? "yes" : "no");
        }
    }

    return Plugin_Handled;
}

public Action Command_LadderStatus(int client, int args)
{
    ReplyToCommand(client, "[梯子加速] 当前有 %d 个特感获得了爬梯加速", CountBoostedPlayers());

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsAiInfected(i) || !g_bSpeedBoosted[i])
        {
            continue;
        }

        char name[64];
        GetClientName(i, name, sizeof(name));
        ReplyToCommand(client, "  - %s (%.1fx速度)", name, g_fActiveMultiplier[i]);
    }

    int coolingDownCount = 0;
    float currentTime = GetGameTime();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsAiInfected(i) && currentTime < g_fCooldownEndTime[i])
        {
            coolingDownCount++;
        }
    }

    if (coolingDownCount > 0)
    {
        ReplyToCommand(client, "[梯子加速] 有 %d 个特感在冷却期", coolingDownCount);
    }

    return Plugin_Handled;
}

int CountBoostedPlayers()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bSpeedBoosted[i])
        {
            count++;
        }
    }

    return count;
}
