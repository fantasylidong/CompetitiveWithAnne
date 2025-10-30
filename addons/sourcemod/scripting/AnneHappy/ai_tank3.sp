#pragma semicolon 1
#pragma newdecls required

// ===== 头文件 =====
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>
#include <treeutil>
#include <logger2>
// 你自己的公共方法、工具函数（判定AI Tank / 可见性 / 贴图等）都在这里
#include "./stocks.sp"

// ===== 常量 / 宏 =====
#define CVAR_FLAGS                 FCVAR_NOTIFY
#define PLUGIN_PREFIX              "Ai-Tank3"
#define GAMEDATA                   "l4d2_ai_tank3"

#define DEFAULT_THROW_FORCE        800.0
#define DEFAULT_SV_GRAVITY         800.0
#define DEFAULT_SWING_RANGE        56.0

#define ROCK_FL_GRAVITY            0.4

#define PLAYER_HEIGHT              72.0
#define PLAYER_EYE_HEIGHT          62.0
#define PLAYER_CHEST               52.0
#define TANK_HEIGHT                84.0
#define JUMP_HEIGHT                56.0

#define THROW_UNDERHEAD_POS_Z      33.38  // 单手下挥出手高度
#define THROW_OVERSHOULDER_POS_Z   93.58  // 单手过肩出手高度
#define THROW_OVERHEAD_POS_Z       104.01 // 双手过头出手高度

#define JUMP_SPEED_Z               300.0  // 跳砖时给的Z轴速度

// ===== ConVar =====
ConVar g_cvPluginName, g_cvLogLevel;

ConVar
    g_cvEnable,
    g_cvTankBhop,
    g_cvBhopMinDist,
    g_cvBhopMaxDist,
    g_cvBhopMinSpeed,
    g_cvBhopMaxSpeed,
    g_cvBhopImpulse,
    g_cvBhopNoVision,
    g_cvThrowMinDist,
    g_cvThrowMaxDist,
    g_cvAirVecModifyDegree,
    g_cvAirVecModifyMaxDegree,
    g_cvAirVecModifyInterval,
    g_cvClimbAnimRate,       // 高翻越播放速率
    g_cvLowClimbAnimRate,    // 低翻越播放速率
    g_cvLadderClimbAnimRate, // NEW: 梯子攀爬播放速率（新增）
    g_cvRockTargetAdjust,
    g_cvBackFist,
    g_cvBackFistRange,
    g_cvBackFistAllowMaxSpd,
    g_cvPunchLockVision,
    g_cvJumpRock,
    g_cvBackFistWindow;

ConVar g_cvBhopNoVisionMaxAng;
ConVar cvTankSwingRange;

// ===== 运行时对象 =====
StringMap
    g_hThrowAnimMap,
    g_hClimbAnimMap,
    g_hLowClimbAnimMap;

Handle g_hSdkTankClawSweepFist;

bool  g_bLateLoad;
float g_fTankSwingRange;

// ===== 结构体 =====
enum struct AiTank
{
    int   target;               // 目标(userId)
    float lastAirVecModifyTime; // 上次空中速度修正时间
    float nextAttackTime;       // 下次挥拳时间
    bool  wasThrowing;          // 是否处于扔石头序列中
    float lastHopSpeed;         // 上次起跳时的速度（用于空中修正还原）
    float backFistExpire;       // 通背拳允许窗口到期时间（EngineTime <= 0 未开启）

    void initData()
    {
        this.target = -1;
        this.lastAirVecModifyTime = 0.0;
        this.nextAttackTime = 0.0;
        this.wasThrowing = false;
        this.lastHopSpeed = 0.0;
        this.backFistExpire = 0.0;
    }
}
AiTank g_AiTanks[MAXPLAYERS + 1];

Logger log;

// ===== Tank 动画类型（按逻辑分类）=====
enum TankSequenceType
{
    tankSequence_Throw,
    tankSequence_Climb
}

// ===== 插件信息 =====
public Plugin myinfo =
{
    name        = "Ai-Tank 3",
    author      = "夜羽真白",
    description = "Ai Tank 增强 3.0 版本（含攀爬/梯子分离加速、空速修正、跳砖、通背拳窗口等）",
    version     = "1.0.0.1",
    url         = "https://steamcommunity.com/id/saku_ra/"
};

// ===== 预加载 =====
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "本插件仅支持 Left 4 Dead 2");
        return APLRes_SilentFailure;
    }
    g_bLateLoad = late;
    return APLRes_Success;
}

// ===== 启动 =====
public void OnPluginStart()
{
    // 总开关
    g_cvEnable = CreateConVar("ai_tank3_enable", "1", "是否启用插件, 0=禁用, 1=启用", CVAR_FLAGS, true, 0.0, true, 1.0);

    // 连跳
    g_cvTankBhop   = CreateConVar("ai_tank_bhop", "1", "是否允许坦克连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopMinDist= CreateConVar("ai_Tank_StopDistance", "135", "停止连跳的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxDist= CreateConVar("ai_tank3_bhop_max_dist", "9999", "开始连跳的最大距离", CVAR_FLAGS, true, 0.0);
    g_cvBhopMinSpeed=CreateConVar("ai_tank3_bhop_min_speed", "200", "连跳的最小速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopMaxSpeed=CreateConVar("ai_tank3_bhop_max_speed", "1000", "连跳的最大速度", CVAR_FLAGS, true, 0.0);
    g_cvBhopImpulse =CreateConVar("ai_tank3_bhop_impulse", "60", "连跳的加速度（每次离地时追加）", CVAR_FLAGS, true, 0.0);
    g_cvBhopNoVision=CreateConVar("ai_tank3_bhop_no_vision", "1", "无视野是否允许连跳", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBhopNoVisionMaxAng = CreateConVar("_ai_tank3_bhop_nvis_maxang", "75.0", "无视野时速度向量与视角前向向量阈值（度）", CVAR_FLAGS, true, 0.0);

    // 空速矫正
    g_cvAirVecModifyDegree     = CreateConVar("ai_tank3_airvec_modify_degree", "45.0", "空速方向与目标方向角 >=此值 开始修正", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyMaxDegree  = CreateConVar("ai_tank3_airvec_modify_degree_max", "135.0", "角度 >此值 不再修正", CVAR_FLAGS, true, 0.0);
    g_cvAirVecModifyInterval   = CreateConVar("ai_tank3_airvec_modify_interval", "0.3", "空速方向修正最小间隔(秒)", CVAR_FLAGS, true, 0.1);

    // 投石/距离
    g_cvThrowMinDist = CreateConVar("ai_tank3_throw_min_dist", "0",   "允许扔石头的最小距离", CVAR_FLAGS, true, 0.0);
    g_cvThrowMaxDist = CreateConVar("ai_tank3_throw_max_dist", "800", "允许扔石头的最大距离", CVAR_FLAGS, true, 0.0);

    // 攀爬动画倍速（翻越）
    g_cvClimbAnimRate    = CreateConVar("ai_tank3_climb_anim_rate", "3.0", "Tank 高翻越动画播放倍速（1.0=原速）", CVAR_FLAGS, true, 0.0);
    g_cvLowClimbAnimRate = CreateConVar("ai_tank3_low_climb_anim_rate", "2.0", "Tank 低翻越动画播放倍速（1.0=原速）", CVAR_FLAGS, true, 0.0);

    // NEW: 梯子攀爬独立倍速
    g_cvLadderClimbAnimRate = CreateConVar("ai_tank3_ladder_climb_rate", "3.0", "Tank 梯子攀爬动画播放倍速（1.0=原速）", CVAR_FLAGS, true, 0.0);

    // 投石目标调整 / 通背拳 / 锁视角 / 跳砖
    g_cvRockTargetAdjust  = CreateConVar("ai_tank3_rock_target_adjust", "1", "扔石头时若原目标不可见，允许切换至最近可视目标", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFist          = CreateConVar("ai_tank3_back_fist", "1", "允许通背拳（可拍背后的人）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFistRange     = CreateConVar("ai_tank3_back_fist_range", "128.0", "通背拳距离（-1 使用 tank_swing_range）", CVAR_FLAGS, true, -1.0);
    g_cvBackFistAllowMaxSpd = CreateConVar("ai_tank3_back_fist_max_spd", "50.0", "通背拳允许的最大移动速度（超过禁用）", CVAR_FLAGS, true, -1.0);
    g_cvPunchLockVision   = CreateConVar("ai_tank3_punch_lock_vision", "1", "挥拳时视角锁定目标", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvJumpRock          = CreateConVar("ai_tank3_jump_rock", "1", "扔石头起手时允许“跳砖”", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_cvBackFistWindow    = CreateConVar("ai_tank3_back_fist_window", "3.0", "通背拳窗口（秒），Tank 爪击命中后开启/刷新", CVAR_FLAGS, true, 0.0);

    // 日志
    g_cvPluginName = CreateConVar("ai_tank3_plugin_name", "ai_tank3");
    char cvName[64];
    g_cvPluginName.GetString(cvName, sizeof(cvName));
    FormatEx(cvName, sizeof(cvName), "%s_log_level", cvName);
    g_cvLogLevel = CreateConVar(cvName, "32", "日志级别: 1=关,2=控制台,4=log,8=chat,16=srv,32=err", CVAR_FLAGS);

    // 事件
    HookEvent("round_start", evtRoundStart);
    HookEvent("round_end",   evtRoundEnd);
    HookEvent("player_hurt", evtPlayerHurt, EventHookMode_Post); // 命中刷新通背拳窗口

    // 日志对象
    log = new Logger(PLUGIN_PREFIX, g_cvLogLevel.IntValue);

    // 初始化动画活动映射
    initAnimMap();

    // 迟加载：给已在服玩家挂钩
    if (g_bLateLoad)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidClient(i)) continue;
            OnClientPutInServer(i);
        }
    }
}

// ===== 动态链接符 =====
public void OnAllPluginsLoaded()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(path))
        SetFailState("Missing required gamedata file: %s", path);

    Handle hGamedata = LoadGameConfigFile(GAMEDATA);
    if (!hGamedata)
        SetFailState("Failed to load %s gamedata.", GAMEDATA);

    // CTankClaw::SweepFist(start,end)
    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(hGamedata, SDKConf_Signature, "CTankClaw::SweepFist");
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hSdkTankClawSweepFist = EndPrepSDKCall();
    if (!g_hSdkTankClawSweepFist)
        SetFailState("Failed to find signature for CTankClaw::SweepFist.");
    delete hGamedata;
}

// ===== 读取/监听 CVar =====
public void OnConfigsExecuted()
{
    cvTankSwingRange  = FindConVar("tank_swing_range");
    g_fTankSwingRange = (!cvTankSwingRange) ? DEFAULT_SWING_RANGE : cvTankSwingRange.FloatValue;

    // FIX: 只有找到 cvar 才能挂 ChangeHook（原版写反了）
    if (cvTankSwingRange)
        cvTankSwingRange.AddChangeHook(changeHookTankSwingRange);
}

void changeHookTankSwingRange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_fTankSwingRange = convar.FloatValue;
    log.debugAll("tank_swing_range changed to %d", convar.IntValue);
}

// ===== 结束回收 =====
public void OnPluginEnd()
{
    delete log;
    delete g_hThrowAnimMap;
    delete g_hClimbAnimMap;
    delete g_hLowClimbAnimMap;
}

// ===== 事件 =====
void evtRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        g_AiTanks[i].backFistExpire = 0.0;
    }
}

void evtRoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        g_AiTanks[i].backFistExpire = 0.0;
    }
}

// ===== 动画活动映射 =====
stock void initAnimMap()
{
    if (!g_hThrowAnimMap)    g_hThrowAnimMap    = new StringMap();
    if (!g_hClimbAnimMap)    g_hClimbAnimMap    = new StringMap();
    if (!g_hLowClimbAnimMap) g_hLowClimbAnimMap = new StringMap();

    // 投石动画（活动名）
    g_hThrowAnimMap.SetValue("ACT_SIGNAL2", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL3", true);
    g_hThrowAnimMap.SetValue("ACT_SIGNAL_ADVANCE", true);

    // 高翻越（Valve 复用了一些 DIES* 活动名）
    g_hClimbAnimMap.SetValue("ACT_DIESIMPLE",  true);
    g_hClimbAnimMap.SetValue("ACT_DIEBACKWARD",true);
    g_hClimbAnimMap.SetValue("ACT_DIEFORWARD", true);
    g_hClimbAnimMap.SetValue("ACT_DIEVIOLENT", true);

    // 低翻越（复用 RANGE_ATTACK* 活动名）
    g_hLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK1",     true);
    g_hLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK2",     true);
    g_hLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK1_LOW", true);
    g_hLowClimbAnimMap.SetValue("ACT_RANGE_ATTACK2_LOW", true);
}

// ===== 玩家指令帧 =====
public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3])
{
    if (!g_cvEnable.BoolValue || !isAiTank(client))
        return Plugin_Continue;

    int target = GetClientOfUserId(g_AiTanks[client].target);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return Plugin_Continue;

    float pos[3], targetPos[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    float dist = GetVectorDistance(pos, targetPos);

    // 挥拳锁视角
    punchLockVision(client, target, pos, targetPos);

    // 限制投石距离
    checkEnableThrow(client, buttons, dist);

    // 连跳逻辑
    checkEnableBhop(client, target, buttons, pos, targetPos, dist);

    return Plugin_Continue;
}

// 确保目标缓存一致
public Action L4D2_OnChooseVictim(int client, int &curTarget)
{
    if (!isAiTank(client) || !IsValidSurvivor(curTarget))
        return Plugin_Continue;

    int cachedTarget = GetClientOfUserId(g_AiTanks[client].target);
    if (!IsValidClient(cachedTarget) || cachedTarget != curTarget)
        g_AiTanks[client].target = GetClientUserId(curTarget);

    return Plugin_Continue;
}

// ===== 通背拳（背后扫击） =====
stock bool IsBackFistAllowedNow(int tank)
{
    if (!g_cvBackFist.BoolValue)                return false;
    if (!isAiTank(tank))                        return false;
    if (!IsClientOnGround(tank))                return false;                    // 必须在地上
    if (GetEntityMoveType(tank) == MOVETYPE_LADDER) return false;               // 梯子上不允许
    float now = GetEngineTime();
    return (g_AiTanks[tank].backFistExpire > 0.0 && now <= g_AiTanks[tank].backFistExpire);
}

public void L4D_TankClaw_DoSwing_Post(int tank, int claw)
{
    if (!g_cvBackFist.BoolValue || !isAiTank(tank))
        return;

    // 速度过快不允许通背拳
    float vAbsVelVec[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    float speed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
    if (speed > g_cvBackFistAllowMaxSpd.FloatValue)
        return;

    if (!IsBackFistAllowedNow(tank))
        return;

    float pos[3], targetPos[3];
    float fistRange = (g_cvBackFistRange.IntValue >= 0) ? g_cvBackFistRange.FloatValue : g_fTankSwingRange;

    GetClientEyePosition(tank, pos);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientEyePosition(i, targetPos);
        if (GetVectorDistance(pos, targetPos) > fistRange)
            continue;
        if (!clientIsVisibleToClient(tank, i))
            continue;

        // 用 TankClaw 扫描碰撞
        SDKCall(g_hSdkTankClawSweepFist, claw, targetPos, targetPos);
    }
}

// 爪击命中 -> 刷新通背拳窗口
void evtPlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim   = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (!IsValidSurvivor(victim) || !IsValidClient(attacker) || !isAiTank(attacker))
        return;

    char wep[64];
    GetEventString(event, "weapon", wep, sizeof(wep));
    bool isClaw = StrEqual(wep, "tank_claw", false) || StrEqual(wep, "tank", false);
    if (!isClaw)
    {
        int claw = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon");
        if (claw > 0 && IsValidEdict(claw))
        {
            char cls[64];
            GetEntityClassname(claw, cls, sizeof(cls));
            if (StrEqual(cls, "weapon_tank_claw", false))
                isClaw = true;
        }
    }
    if (!isClaw) return;

    g_AiTanks[attacker].backFistExpire = GetEngineTime() + g_cvBackFistWindow.FloatValue;
}

// 挥拳锁视角
Action punchLockVision(int client, int target, const float pos[3], const float targetPos[3])
{
    if (!g_cvPunchLockVision.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
        return Plugin_Continue;

    int claw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!claw || !IsValidEdict(claw)) return Plugin_Continue;
    if (!HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack"))
        return Plugin_Continue;

    float nextAtk = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
    if (g_AiTanks[client].nextAttackTime < GetEngineTime() && nextAtk > GetGameTime())
    {
        float vLookAt[3], vDir[3];
        MakeVectorFromPoints(pos, targetPos, vLookAt);
        GetVectorAngles(vLookAt, vDir);
        TeleportEntity(client, NULL_VECTOR, vDir, NULL_VECTOR);
    }
    g_AiTanks[client].nextAttackTime = nextAtk;
    return Plugin_Continue;
}

// ===== 连跳 =====
Action checkEnableBhop(int client, int target, int& buttons, const float pos[3], const float targetPos[3], float dist)
{
    if (!g_cvTankBhop.BoolValue || !isAiTank(client) || !IsValidSurvivor(target))
        return Plugin_Continue;

    if (L4D_IsPlayerStaggering(client))
        return Plugin_Continue;

    // 梯子/水中不连跳
    if (GetEntityMoveType(client) == MOVETYPE_LADDER || GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
        return Plugin_Continue;

    float velVec[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    float vel = SquareRoot(Pow(velVec[0], 2.0) + Pow(velVec[1], 2.0));
    if (vel < g_cvBhopMinSpeed.FloatValue)
        return Plugin_Continue;

    if (dist < g_cvBhopMinDist.FloatValue || dist > g_cvBhopMaxDist.FloatValue)
        return Plugin_Continue;

    float vAbsVelVec[3], vTargetAbsVelVec[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

    // 是否可见
    float l_targetPos[3]; l_targetPos = targetPos;
    bool visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, 0, 0, l_targetPos);

    if (IsClientOnGround(client) && nextTickPosCheck(client, visible))
    {
        float vPredict[3], vDir[3], vFwd[3], vRight[3];

        if (!visible)
        {
            NormalizeVector(velVec, vFwd);
        }
        else
        {
            // 预测目标下一帧位置
            AddVectors(targetPos, vTargetAbsVelVec, vPredict);
            MakeVectorFromPoints(pos, vPredict, vDir);
            vDir[2] = 0.0;
            NormalizeVector(vDir, vDir);
            vFwd = vDir;
        }

        if (!g_cvBhopNoVision.BoolValue && !visible)
            return Plugin_Continue;

        buttons |= IN_DUCK;
        buttons |= IN_JUMP;

        bool fwdOnly  = ((buttons & IN_FORWARD) && !(buttons & IN_BACK));
        bool backOnly = ((buttons & IN_BACK) && !(buttons & IN_FORWARD));
        bool leftOnly = ((buttons & IN_LEFT) && !(buttons & IN_RIGHT));
        bool rightOnly= ((buttons & IN_RIGHT) && !(buttons & IN_LEFT));

        if (fwdOnly)
        {
            NormalizeVector(vFwd, vFwd);
            ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
            AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
        }
        else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0))
        {
            vFwd[0] = velVec[0]; vFwd[1] = velVec[1]; vFwd[2] = 0.0;
            NormalizeVector(vFwd, vFwd);
            ScaleVector(vFwd, g_cvBhopImpulse.FloatValue);
            AddVectors(vAbsVelVec, vFwd, vAbsVelVec);
        }
        else
        {
            float baseFwd[3];
            if (fwdOnly)
            {
                baseFwd[0] = vFwd[0]; baseFwd[1] = vFwd[1]; baseFwd[2] = 0.0;
            }
            else if (backOnly && (velVec[0] > 0.0 || velVec[1] > 0.0))
            {
                baseFwd[0] = velVec[0]; baseFwd[1] = velVec[1]; baseFwd[2] = 0.0;
            }
            else
            {
                baseFwd[0] = vDir[0]; baseFwd[1] = vDir[1]; baseFwd[2] = 0.0;
            }

            GetVectorCrossProduct({0.0, 0.0, 1.0}, baseFwd, vRight);
            NormalizeVector(vRight, vRight);
            if (rightOnly ^ leftOnly)
            {
                vRight[2] = 0.0;
                ScaleVector(vRight, g_cvBhopImpulse.FloatValue * (rightOnly ? 1.0 : -1.0));
                AddVectors(vAbsVelVec, vRight, vAbsVelVec);
            }
        }

        // 记录起跳水平速度（空中修正用）
        g_AiTanks[client].lastHopSpeed = SquareRoot(Pow(vAbsVelVec[0], 2.0) + Pow(vAbsVelVec[1], 2.0));
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
        return Plugin_Changed;
    }

    // 限速（空中）
    if (vel > g_cvBhopMaxSpeed.FloatValue)
    {
        NormalizeVector(velVec, velVec);
        ScaleVector(velVec, g_cvBhopMaxSpeed.FloatValue);
        SetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    }

    // 空中矫正：角度在 [min, max] 内
    float vAbsVelVecCpy[3]; vAbsVelVecCpy = vAbsVelVec;
    NormalizeVector(vAbsVelVec, vAbsVelVec);
    float vDir2[3];
    MakeVectorFromPoints(pos, targetPos, vDir2);
    NormalizeVector(vDir2, vDir2);
    vAbsVelVec[2] = 0.0; vDir2[2] = 0.0;

    float dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
    float dz = targetPos[2] - pos[2];
    float pitch = RadToDeg(ArcTangent(dz / dx));
    if (dz > (JUMP_HEIGHT + TANK_HEIGHT + g_fTankSwingRange) && pitch > 45.0)
        return Plugin_Continue;

    float angle = RadToDeg(ArcCosine(GetVectorDotProduct(vAbsVelVec, vDir2)));
    bool inAngleRange = (angle >= g_cvAirVecModifyDegree.FloatValue && angle <= g_cvAirVecModifyMaxDegree.FloatValue);
    bool notPressBack = !(buttons & IN_BACK);
    bool delayExpired = (GetEngineTime() - g_AiTanks[client].lastAirVecModifyTime) > g_cvAirVecModifyInterval.FloatValue;

    if (visible && inAngleRange && notPressBack && delayExpired)
    {
        NormalizeVector(vDir2, vDir2);
        if (vel < g_AiTanks[client].lastHopSpeed)
            vel = g_AiTanks[client].lastHopSpeed;
        ScaleVector(vDir2, vel);
        vDir2[2] = vAbsVelVecCpy[2];
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vDir2);
        g_AiTanks[client].lastAirVecModifyTime = GetEngineTime();
    }
    return Plugin_Changed;
}

// 预测下一帧位置是否会撞/坠落
stock bool nextTickPosCheck(int client, bool visible)
{
    if (!isAiTank(client)) return false;

    float vMins[3], vMaxs[3];
    GetClientMins(client, vMins);
    GetClientMaxs(client, vMaxs);

    float pos[3], endPos[3], velVec[3];
    GetClientAbsOrigin(client, pos);
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", velVec);
    float vel = GetVectorLength(velVec);
    NormalizeVector(velVec, velVec);

    ScaleVector(velVec, vel + FloatAbs(vMaxs[0] - vMins[0]) + 3.0);
    AddVectors(pos, velVec, endPos);
    pos[2]     += 10.0;
    endPos[2]  += 10.0;

    Handle hTrace = TR_TraceHullFilterEx(pos, endPos, {-36.0, -36.0, 10.0}, {36.0, 36.0, 72.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
    if (TR_DidHit(hTrace))
    {
        float hitNormal[3];
        TR_GetPlaneNormal(hTrace, hitNormal);
        NormalizeVector(hitNormal, hitNormal);
        NormalizeVector(velVec, velVec);
        if (RadToDeg(ArcCosine(GetVectorDotProduct(hitNormal, velVec))) > 165.0)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;

    if (!visible)
    {
        float eyeAng[3], dir[3];
        GetClientEyeAngles(client, eyeAng);
        GetAngleVectors(eyeAng, dir, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(dir, dir);
        NormalizeVector(velVec, velVec);
        dir[2] = velVec[2] = 0.0;
        float ang = RadToDeg(ArcCosine(GetVectorDotProduct(dir, velVec)));
        if (floatIsNan(ang) || ang > g_cvBhopNoVisionMaxAng.FloatValue)
            return false;
    }

    float downPos[3]; downPos = endPos; downPos[2] -= 99999.0;
    hTrace = TR_TraceHullFilterEx(endPos, downPos, {-16.0, -16.0, 0.0}, {16.0, 16.0, 0.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
    if (!TR_DidHit(hTrace))
    {
        delete hTrace;
        return false;
    }
    int hitEnt = TR_GetEntityIndex(hTrace);
    if (IsValidEntity(hitEnt))
    {
        char className[32];
        GetEntityClassname(hitEnt, className, sizeof(className));
        if (strcmp(className, "trigger_hurt", false) == 0)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;
    return true;
}

// ===== 玩家进服：启用动画钩子 & 梯子常驻维护 =====
public void OnClientPutInServer(int client)
{
    g_AiTanks[client].initData();

    // 后置动画钩子：识别投石/翻越等序列变化
    AnimHookEnable(client, INVALID_FUNCTION, tankAnimHookPostCb);

    // NEW: 梯子播放速率常驻维护（PostThinkPost 每帧极轻量）
    SDKHook(client, SDKHook_PostThinkPost, ladderRateModifyHookHandler);
}

// ===== 翻越播放速率维护（进入翻越时挂，退出解）=====
void climbRateModifyHookHandler(int client)
{
    if (!isAiTank(client))
        return;

    int animSeq = GetEntProp(client, Prop_Data, "m_nSequence");

    // 仍处于翻越：按“高/低翻越”倍速
    if (isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Climb)))
    {
        SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", getClimbPlaybackRate(animSeq));
        return;
    }

    // NEW: 若此刻处于“梯子”，交给梯子常驻维护，不复位
    if (GetEntityMoveType(client) == MOVETYPE_LADDER)
    {
        return;
    }

    // 其它状态：复位并解绑本钩子
    SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", 1.0);
    SDKUnhook(client, SDKHook_PostThinkPost, climbRateModifyHookHandler);
}

// ===== NEW: 梯子播放速率常驻维护（互不干扰翻越）=====
void ladderRateModifyHookHandler(int client)
{
    if (!isAiTank(client))
        return;

    // 在梯子上：持续“喂”播放速率为 ai_tank3_ladder_climb_rate
    if (GetEntityMoveType(client) == MOVETYPE_LADDER)
    {
        float want = g_cvLadderClimbAnimRate.FloatValue;
        float cur  = GetEntPropFloat(client, Prop_Send, "m_flPlaybackRate");
        if (cur != want)
            SetEntPropFloat(client, Prop_Send, "m_flPlaybackRate", want);
        return;
    }
    // 非梯子：不做事（翻越的速度由 climbRateModifyHookHandler 处理）
}

// ===== 动画后置钩子：识别投石/攀爬序列并触发相应逻辑 =====
Action tankAnimHookPostCb(int tank, int &sequence)
{
    if (!isAiTank(tank))
    {
        AnimHookDisable(tank, tankAnimHookPostCb);
        return Plugin_Continue;
    }

    // 投石：跳砖 + 定时刷新 throwing 标志
    if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        if (g_cvJumpRock.BoolValue && !g_AiTanks[tank].wasThrowing)
        {
            makeTankJumpRock(tank);
            g_AiTanks[tank].wasThrowing = true;
            CreateTimer(0.5, timerResetThrowingFlagHandler, GetClientUserId(tank), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        }
    }
    // 翻越：开启 PostThinkPost（仅在倍速变化时绑定，离开翻越自动解绑）
    else if (isMatchedSequence(sequence, view_as<TankSequenceType>(tankSequence_Climb)))
    {
        float targetRate = getClimbPlaybackRate(sequence);
        if (GetEntPropFloat(tank, Prop_Send, "m_flPlaybackRate") != targetRate)
            SDKHook(tank, SDKHook_PostThinkPost, climbRateModifyHookHandler);
    }
    return Plugin_Continue;
}

// 判断序列是否匹配“投石/翻越”两类
bool isMatchedSequence(int sequence, TankSequenceType seqType)
{
    if (sequence < 0) return false;

    char seqName[64];
    if (!AnimGetActivity(sequence, seqName, sizeof(seqName)))
        return false;

    switch (seqType)
    {
        case view_as<TankSequenceType>(tankSequence_Throw):
            return g_hThrowAnimMap.ContainsKey(seqName);
        case view_as<TankSequenceType>(tankSequence_Climb):
            return g_hClimbAnimMap.ContainsKey(seqName);
    }
    return false;
}

// 是否属于“低矮翻越”
bool isLowClimbSequence(int sequence)
{
    if (sequence < 0 || !g_hLowClimbAnimMap) return false;

    char seqName[64];
    if (!AnimGetActivity(sequence, seqName, sizeof(seqName)))
        return false;

    return g_hLowClimbAnimMap.ContainsKey(seqName);
}

// 根据序列选择翻越倍速：低矮用 low，其他用高翻越
float getClimbPlaybackRate(int sequence)
{
    if (isLowClimbSequence(sequence))
        return g_cvLowClimbAnimRate.FloatValue;
    return g_cvClimbAnimRate.FloatValue;
}

// ===== 投石：跳砖、距离限制、出手角度 =====
void makeTankJumpRock(int tank)
{
    if (!isAiTank(tank)) return;

    float vAbsVelVec[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", vAbsVelVec);
    vAbsVelVec[2] += JUMP_SPEED_Z;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, vAbsVelVec);
}

Action timerResetThrowingFlagHandler(Handle timer, int userId)
{
    int tank = GetClientOfUserId(userId);
    if (!isAiTank(tank))
        return Plugin_Stop;

    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    if (!isMatchedSequence(animSeq, view_as<TankSequenceType>(tankSequence_Throw)))
    {
        g_AiTanks[tank].wasThrowing = false;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

Action checkEnableThrow(int client, int& buttons, float dist)
{
    if (!isAiTank(client)) return Plugin_Continue;

    if (dist < g_cvThrowMinDist.FloatValue || dist > g_cvThrowMaxDist.FloatValue)
        buttons &= ~IN_ATTACK2;

    return Plugin_Changed;
}

public Action L4D_TankRock_OnRelease(int tank, int rock, float vecPos[3], float vecAng[3], float vecVel[3], float vecRot[3])
{
    if (!isAiTank(tank)) return Plugin_Continue;
    if (!HasEntProp(rock, Prop_Data, "m_flGravity")) return Plugin_Continue;

    static ConVar cv_ThrowForce, cv_Gravity;
    if (!cv_ThrowForce) cv_ThrowForce = FindConVar("z_tank_throw_force");
    if (!cv_Gravity)    cv_Gravity    = FindConVar("sv_gravity");

    float throwSpeed = (!cv_ThrowForce) ? DEFAULT_THROW_FORCE : cv_ThrowForce.FloatValue;
    float svGravity  = (!cv_Gravity)    ? DEFAULT_SV_GRAVITY  : cv_Gravity.FloatValue;

    int target = GetClientOfUserId(g_AiTanks[tank].target);
    if (!IsValidSurvivor(target)) return Plugin_Continue;

    int newRockTarget = -1;
    if (g_cvRockTargetAdjust.BoolValue)
    {
        static ArrayList targets;
        if (!targets) targets = new ArrayList(2);

        float pos[3], tpos[3];
        GetClientEyePosition(tank, pos);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (tank == i || !IsValidSurvivor(i) || !IsPlayerAlive(i) || IsClientIncapped(i) || isPinnedByHunterOrCharger(i))
                continue;
            if (!clientIsVisibleToClient(tank, i))
                continue;
            GetClientEyePosition(i, tpos);
            targets.Set(targets.Push(GetVectorDistance(pos, tpos)), i, 1);
        }
        if (targets.Length > 0)
        {
            SortADTArray(targets, Sort_Ascending, Sort_Float);
            newRockTarget = targets.Get(0, 1);
        }
        delete targets;
    }

    int aimTarget = IsValidSurvivor(newRockTarget) ? newRockTarget : target;

    // 计算上抬角
    float rockGravityScale = GetEntPropFloat(rock, Prop_Data, "m_flGravity");
    float pitch = calculateThrowAngle(tank, aimTarget, throwSpeed, svGravity * rockGravityScale);
    if (pitch > 90.0 || pitch < -90.0)
        return Plugin_Continue;

    // 预测偏航
    float pos0[3], tpos0[3], pred[3], vTargetAbsVelVec[3], aimAng[3];
    GetClientAbsOrigin(tank, pos0);
    GetClientAbsOrigin(aimTarget, tpos0);
    GetEntPropVector(aimTarget, Prop_Data, "m_vecAbsVelocity", vTargetAbsVelVec);

    float dx = SquareRoot(Pow(vecPos[0] - tpos0[0], 2.0) + Pow(vecPos[1] - tpos0[1], 2.0));
    float vx = throwSpeed * Cosine(DegToRad(pitch));
    float t  = dx / vx;

    pred[0] = tpos0[0] + vTargetAbsVelVec[0] * t;
    pred[1] = tpos0[1] + vTargetAbsVelVec[1] * t;
    pred[2] = tpos0[2] + vTargetAbsVelVec[2] * t;

    float yawCenter = ArcTangent2(pred[1] - pos0[1], pred[0] - pos0[0]);
    float yawThrow  = ArcTangent2(pred[1] - vecPos[1], pred[0] - vecPos[0]);
    yawThrow        = RadToDeg(yawThrow - yawCenter);

    MakeVectorFromPoints(pos0, pred, aimAng);
    GetVectorAngles(aimAng, aimAng);
    aimAng[0] = -pitch;
    aimAng[1] += yawThrow;
    if (aimAng[1] > 180.0)  aimAng[1] -= 360.0;
    if (aimAng[1] < -180.0) aimAng[1] += 360.0;
    aimAng[2] = 0.0;

    GetAngleVectors(aimAng, aimAng, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(aimAng, aimAng);
    ScaleVector(aimAng, throwSpeed);
    vecVel = aimAng;

    return Plugin_Changed;
}

// 计算投石出手角度
float calculateThrowAngle(int tank, int target, float vSpeed = 800.0, float g = 320.0)
{
    if (!isAiTank(tank) || !IsValidSurvivor(target))
        return -9999.0;

    float pos[3], tpos[3];
    GetClientAbsOrigin(tank, pos);

    int animSeq = GetEntProp(tank, Prop_Data, "m_nSequence");
    switch (animSeq)
    {
        case L4D2_ACT_SIGNAL3: { pos[2] += THROW_UNDERHEAD_POS_Z; }
        case L4D2_ACT_SIGNAL2: { pos[2] += THROW_OVERSHOULDER_POS_Z; }
        case L4D2_ACT_SIGNAL_ADVANCE: { pos[2] += THROW_OVERHEAD_POS_Z; }
    }

    GetClientAbsOrigin(target, tpos);
    tpos[2] += PLAYER_CHEST;

    float dx = SquareRoot(Pow(tpos[0] - pos[0], 2.0) + Pow(tpos[1] - pos[1], 2.0));
    float dz = tpos[2] - pos[2];

    float v2 = Pow(vSpeed, 2.0);
    float v4 = Pow(vSpeed, 4.0);
    float delta = v4 - g * (g * dx * dx + 2.0 * dz * v2);
    if (delta < 0.0)
    {
        log.debugAll("%N rock unreachable: dist=%.2f dh=%.2f v=%.2f g=%.2f", tank, dx, dz, vSpeed, g);
        return -9999.0;
    }

    float tanTheta = (v2 - SquareRoot(delta)) / (g * dx); // 取低抛解
    return RadToDeg(ArcTangent(tanTheta));
}
