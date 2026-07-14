#if defined _state_approach_included_
    #endinput
#endif
#define _state_approach_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../setup.inc"
#include "../stocks.inc"
#include "./state.inc"

#define STATE_APPROACH_NAME             "STATE_APPROACH"
#define PATH_LOOKAHEAD_MIN_DIST         150.0           // 在地面时连跳前瞻目标点的最小距离
#define GOAL_POS_TOLERANCE_DIST         25.0            // Charger 与目标 Goal Pos 距离小于这个值时, 放弃速度修正

#define DIRECT_BHOP_TOLERANCE_BUFFER    150.0           // 朝着目标方向直线连跳状态切换到 Path 连跳的缓冲距离

#define GOAL_REACHED_DIST               100.0            // Charger 位置距离当前 GoalPos 位置在这个范围之内, 认为到达 GoalPos
#define PATH_REPATH_COOLDOWN            0.75             // Repath 之前的冷却时间
#define PATH_REPATH_DELAY               1.0              // 没有 Path, 尝试 Repath 到直接切成直线连跳的延迟时间
#define AIR_CORRECTION_STEP_INTERVAL    0.05             // 用短步长平滑空中转向，避免离散硬拐
#define AIR_CORRECTION_MIN_TARGET_DEG   1.0              // 小于该角度不写回速度，避免无效 Teleport 引起抖动
#define AIR_CORRECTION_MAX_TURN_DEG     89.0             // 空中不允许把速度修正到当前运动方向后方

// =========================================================================
// State Approach 接近目标状态 (连跳等)
// 注册状态函数
// =========================================================================
stock void RegisterState_Approach() {
    ChargerState stateApproach;
    strcopy(stateApproach.name, sizeof(stateApproach.name), "State_Approach");
    stateApproach.OnEnter = StateApproach_OnEnter;
    stateApproach.OnUpdate = StateApproach_OnUpdate;
    stateApproach.OnExit = StateApproach_OnExit;
    g_ChargerStates.PushArray(stateApproach);
}

// ============================================================
// OnEnter 函数
// ============================================================
stock void StateApproach_OnEnter(int client) {
	g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    stateLog.debugAll("\n========== Charger (%N) State Approach On Enter ===========", client);
}

// ============================================================
// OnUpdate 函数
// ============================================================
stock Action StateApproach_OnUpdate(int client, int& buttons, float vel[3], float ang[3]) {
    if (!isAiCharger(client) || IsPinningSurvivor(client))
        return Plugin_Continue;

    // ============================================================
    // 数据收集 (Data Collection)
    // ============================================================
    static int target;
    target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
        stateLog.debugAll("(%s) Charger (%N)'s target %d is invalid", STATE_APPROACH_NAME, client, target);
        return Plugin_Continue;
    }
    
    // 计算 charger 当前速度
    static float vVel[3], speed;
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVel);
    speed = getVectorLength2D(vVel);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
    // 计算 charger 当前到目标的距离
    static float pos[3], targetPos[3], targetEyePos[3], dist;
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    GetClientEyePosition(target, targetEyePos);
    dist = getVectorDistance2D(pos, targetPos);
    // 是否可视目标
    static bool visible;
    visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, TEAM_SURVIVOR, 0, targetEyePos);
    if (visible) {
        g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    }
    // 是否在地上
    static bool isOnGround;
    isOnGround = IsClientOnGround(client);
    // 高度差过大时不进入 Bait/Locked, 避免不可冲锋目标导致状态抖动
    static bool chargeHeightReachable;
    chargeHeightReachable = isChargeHeightReachable(pos, targetPos);

    // ============================================================
    // 状态决策 (State Decision)
    // ============================================================

    // 1. 优先行动检查, 检测是否有更好的可以直接冲锋的目标, 如果有, 直接转换为冲锋状态
    if (isOnGround) {
        static int betterTarget;
        betterTarget = getChargeUnavoidableTarget(client, target, pos, dist, g_cvBhopMinDist.FloatValue);
        if (IsValidSurvivor(betterTarget) && IsPlayerAlive(betterTarget) &&
            isChargeAbilityReady(client) &&
            isChargeTargetHeightReachable(client, betterTarget) &&
            !isChargePathBlocked(client, betterTarget)
        ) {
            stateLog.debugAll("Charger (%N) find a better charge target %N, transition to LOCKED STATE", client, betterTarget);
            // 设置新目标, 转换为冲锋状态
            g_AiChargers[client].m_iBetterTarget = GetClientUserId(betterTarget);
            g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
            return Plugin_Changed;
        }
    }
    // 2. 面对近战威胁的博弈 (切换到 BAIT 博弈逻辑)
    // 若 charger 目标手持近战武器, 设置一个博弈区为 melee_range + g_cvMeleeBaitZoneMaxRange.FloatValue
    // charger 在空中进入该区域时, 急停, 进入博弈状态, 若在地上, 直接进入博弈状态, 避免 g_cvBhopMinDist.FloatValue 设置的太小, 连跳到目标脸上被砍
    static TargetThreatType threatType;
    threatType = getTargetThreatType(client, target);
    if (threatType == Threat_Melee) {
        static float meleeRange, baitZoneMax;
        meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
        baitZoneMax = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue;

        if (visible && chargeHeightReachable && dist <= baitZoneMax) {
            // 增加 airBreak 标记, 如果是空中急停, 修正了速度之后返回 Plugin_Changed 让速度修改返回 OnPlyaerRunCmd
            static bool airBreaked;
            airBreaked = false;

            if (!isOnGround && !g_AiChargers[client].m_bHasAirBreaked) {
                // 如果 charger 此时在空中, 将水平方向上的速度设置为 0, 仅保留垂直方向的速度
                vVel[0] = vVel[1] = 0.0;
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vVel);
                g_AiChargers[client].m_bHasAirBreaked = true;
                airBreaked = true;
            }
            // 转换为博弈状态
            stateLog.debugAll("Charger (%N) melee threat (%N) dist %.2f < %.2f, transition to BAIT", client, target, dist, baitZoneMax);
            g_ChargerStateContext[client].transitionTo(CH_STATE_BAIT);
            return airBreaked ? Plugin_Changed : Plugin_Continue;
        }
    }
    // 3. 常规距离达标后的博弈 or 准备冲锋 (转换到 BAIT 博弈逻辑)
    if (visible && chargeHeightReachable && dist <= g_cvBhopMinDist.FloatValue) {
        /**
         * charger 面对持枪生还者, 连跳到 g_cvBhopMinDist.FloatValue 时空中急停
         * 急停可能会出现的问题: charger 下落时间内, 目标又跑出去一段路, 此时 charger 冲锋无法准确命中目标
         * if (!isOnGround && !g_AiChargers[client].m_bHasAirBreaked) {
                // 如果 charger 此时在空中, 将水平方向上的速度设置为 0, 仅保留垂直方向的速度
                vVel[0] = vVel[1] = 0.0;
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vVel);
                g_AiChargers[client].m_bHasAirBreaked = true;
            }
         */
        // 到目标距离小于允许连跳的最小距离, 转换为博弈状态
        stateLog.debugAll("Charger (%N) to target (%N) dist %.2f <= %.2f, transition to BAIT", client, target, dist, g_cvBhopMinDist.FloatValue);
        g_ChargerStateContext[client].transitionTo(CH_STATE_BAIT);
        return Plugin_Continue;
    }

    // ============================================================
    // 动作干预 (Default Actions)
    // ============================================================

    // 移除原生攻击键, 特别是 IN_ATTACK2, 避免多个 Charger 生成在远处互相打拳
    buttons &= ~IN_ATTACK;
    buttons &= ~IN_ATTACK2;
    setChargerAbilityCooldown(client, 1.0);

    // ============================================================
    // 连跳行为 (Bhop Execution)
    // ============================================================
    static Action bhopRes;
    bhopRes = checkShouldBhop(client, buttons, ang, target, vVel, speed, dist, visible, pos, targetPos);
    if (bhopRes != Plugin_Continue)
        return bhopRes;

    return Plugin_Continue;
}

stock Action checkShouldBhop(
    int client, int& buttons, float ang[3], int target, float vVel[3], float speed,
    float dist, bool visible, float pos[3], float targetPos[3]
) {
    if (!isAiCharger(client))
        return Plugin_Continue;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return Plugin_Continue;
    if (!allowToBhop(client))
        return Plugin_Continue;

    // 是否在地上
    static bool isOnGround;
    isOnGround = IsClientOnGround(client);
    if (isOnGround) {
        g_AiChargers[client].m_bHasAirBreaked = false;
    }

    // 连跳距离限制
    if (dist > g_cvBhopMaxDist.FloatValue)
        return Plugin_Continue;

    // 连跳空速限制
    if (speed < g_cvBhopMinSpeed.FloatValue)
        return Plugin_Continue;

    if (isOnGround)
        return executeGroundBhop(client, target, dist, speed, visible, pos, targetPos, vVel, buttons, ang);
    else
        return executeAirCorrection(client, dist, speed, visible, pos, targetPos, vVel, buttons, ang);
}

/**
* 检查当前 Charger 的 Path 是否通向目标, 也就是目标所在的 NavArea 是否在 Charger 的 Path 上
* @param client 客户端索引
* @param targetNavArea 目标所在的 NavArea
* @param hasSpecialMove 如果目标所在的 NavArea 在 Charger 的 Path 上, 从 Charger 当前的 PathSegment 到目标所在的 PathSegment 是否存在 SetmentType != ON_GROUND 的 Segment
* @return bool 目标是否在 Charger 当前 Path 上
* @error 
**/
stock bool isRemainingPathSupportsTarget(int client, Address targetNavArea, bool& hasSpecialMove) {
    if (!isAiCharger(client))
        return false;
    if (!targetNavArea)
        return false;
    
    hasSpecialMove = false;

    static Address pPathFollower;
    pPathFollower = g_AiChargers[client].m_pPathFollower;

    static Address pCurrentSeg, pLastSegment;
    pCurrentSeg = g_AiChargers[client].m_PathSegment.m_pPathSegment;
    pLastSegment = g_AiChargers[client].m_LastPathSegment.m_pPathSegment;

    if (!pPathFollower || !pCurrentSeg || !pLastSegment)
        return false;
    
    static bool scannedAny;
    scannedAny = false;

    static PathSegment curSeg, lastScannedSeg;
    while (pCurrentSeg != Address_Null) {
        constructPathSegment(pCurrentSeg, curSeg);

        lastScannedSeg = curSeg;
        scannedAny = true;

        // 查看当前遍历的 PathSegment 的 SegmentType 查看是否需要特殊移动
        if (curSeg.m_SegmentType != SegType_OnGround)
            hasSpecialMove = true;

        // 如果当前 Path 的某一个 Segment 对应的 NavArea 等于目标所在的 NavArea, 则返回 true
        if (curSeg.m_pNavArea == targetNavArea)
            return true;
        
        if (pCurrentSeg == pLastSegment)
            break;

        pCurrentSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pPathFollower, pCurrentSeg));

        if (!pCurrentSeg)
            break;
    }

    if (!scannedAny || !lastScannedSeg.m_pNavArea)
        return false;
    
    // 目标移动到 Path 终点相邻的 NavArea 也视为当前 Path 可以通向目标
    return (
        L4D_NavArea_IsConnected(lastScannedSeg.m_pNavArea, targetNavArea, NAV_ALL) ||
        L4D_NavArea_IsConnected(targetNavArea, lastScannedSeg.m_pNavArea, NAV_ALL)
    );
}

/**
* 检查 Charger 是否已经到达了当前 Path 最后一个节点的 GoalPos, 判断当前 Charger 位置是否已经接近 GoalPos 或者已经越过了 GoalPos
* @param pos 当前 Charger 坐标
* @param vel 当前 Charger 速度向量
* @param goalPos 需要检测的 GoalPos 坐标
* @return bool 如果靠近或者越过, 返回 true
* @error 
**/
stock bool isFinalGoalReached(const float pos[3], const float vel[3], const float goalPos[3]) {
    // Charger 已经足够接近 GoalPos, 直接认为已到达
    static float dist2D;
    dist2D = getVectorDistance2D(pos, goalPos);
    if (dist2D <= GOAL_REACHED_DIST) {
        return true;
    }

    /*
    * 判断 GoalPos 是否已经落在 Charger 水平移动方向的后方
    * toGoal 表示当前 Charger 到 GoalPos 的方向向量
    * moveDir 表示 Charger 水平方向的速度向量
    */
    static float toGoal[3], moveDir[3];
    MakeVectorFromPoints(pos, goalPos, toGoal);
    toGoal[2] = 0.0;

    moveDir = vel;
    moveDir[2] = 0.0;

    // 如果 Charger 当前位置到 GoalPos 的水平距离几乎为 0, 那么认为已经到达
    if (NormalizeVector(toGoal, toGoal) <= 0.0)
        return true;
    
    // 如果 Charger 当前没有水平速度, 那么直接返回 false
    if (NormalizeVector(moveDir, moveDir) <= 0.0)
        return false;

    /*
    * 如果 GoalPos 处在移动方向背后, 认为是已经到达终点
    * dot < -0.20 表示 ArcCosine(Dot(·)), 约为 101.5 度, 也就是说 GoalPos 已经明显处于当前速度方向的后方, 而不是刚好 dot = 0.0 表示侧方 90 度位置
    */
    return GetVectorDotProduct(moveDir, toGoal) < -0.20;
}

stock void buildDirectBhopVelocity(const float pos[3], const float targetPos[3], float speed, float outputVelVec[3]) {
    MakeVectorFromPoints(pos, targetPos, outputVelVec);
    outputVelVec[2] = 0.0;

    if (NormalizeVector(outputVelVec, outputVelVec) <= 0.0) {
        ZeroVector(outputVelVec);
        return;
    }

    ScaleVector(outputVelVec, speed + g_cvBhopImpulse.FloatValue);

    limitGroundBhopVel(outputVelVec);
}

/**
* 检查朝着目标方向直线连跳是否安全
* @param client 客户端索引
* @param pos 当前 Charger 位置
* @param targetPos 目标位置
* @param velVec 当前 Charger 速度向量
* @return bool, 如果安全, 返回 true
* @error 
**/
stock bool isDirectBhopSafe(int client, const float pos[3], const float targetPos[3], const float velVec[3]) {
    // 获取 ILocomotion 指针用于 HasPotentialGap 的检查
    /* static Address pLocomotion;
    pLocomotion = clientGetLocomotionInterface(client);
    if (!pLocomotion)
        return false; */
    
    // 计算当前位置到目标点的水平 2D 方向
    static float vDir[3];
    MakeVectorFromPoints(pos, targetPos, vDir);
    vDir[2] = 0.0;

    static float targetDist2D;
    targetDist2D = NormalizeVector(vDir, vDir);
    if (targetDist2D <= 0.0) {
        return false;
    }

    /*
    * 预测 Charger 在一次空中连跳可能飞出的水平距离, 如果当前速度很快 Charger 可能不会停在 targetPos 而是继续向前飞, 飞到目标后面之类的
    * 因此实际落点要使用 routeEnd 也就是根据算出来的水平距离的落点而不是 targetPos
    */
    static float curSpeed2D, predictedAirDist;
    curSpeed2D = getVectorLength2D(velVec);
    predictedAirDist = curSpeed2D * getJumpAirTime();

    // 先把 routeCheckDist 设置成为 targetDist, 在判断和实际飞行距离的关系, 取较大值
    static float routeCheckDist;
    routeCheckDist = targetDist2D;
    if (predictedAirDist > targetDist2D) {
        routeCheckDist = predictedAirDist;
    }
    
    /*
    * 构造本次直线连跳可能到达的终点坐标 routeEnd
    * z 高度沿着 pos -> targetPos 的高度斜率外推, 如果 routeCheckDist > targetDist2D, 表示 Charger 会飞过头, 因此 routeEnd 的 z 高度也同样按照斜率外推
    */
    static float heightDelta, heightSlopePerUnit;
    heightDelta = targetPos[2] - pos[2];
    heightSlopePerUnit = heightDelta / targetDist2D;

    static float routeEnd[3];
    routeEnd[0] = pos[0] + vDir[0] * routeCheckDist;
    routeEnd[1] = pos[1] + vDir[1] * routeCheckDist;
    routeEnd[2] = pos[2] + (heightSlopePerUnit * routeCheckDist);
    
    // 原生 hasPotentialGap 检查 Charger 位置到目标位置的路线是否存在 Gap, 但不作为最终判断条件, 因为最终判断条件是需要 Charger 位置到 routeEnd 位置的判断
    /* static bool hasGap;
    hasGap = hasPotentialGap(pLocomotion, pos, targetPos);
    stateLog.debugAll("[IsDirectBhopSafe]: hasPotentialGap: %b, routeDist: %.2f", hasGap, routeDist); */

    // 检查整段实际路线, 包括速度太快可能跳到目标后方
    if (hasPotentialGap2(client, pos, routeEnd, JUMP_HEIGHT)) {
        return false;
    }
    
    // 检查到目标的方向是否被障碍物阻挡, 如果有阻挡继续沿着 Path 连跳
    static float traceStart[3], traceEnd[3];
    L4D_GetEntityWorldSpaceCenter(client, traceStart);

    traceEnd = routeEnd;
    traceEnd[2] += PLAYER_HEIGHT * 0.5;

    static Handle hTrace;
    hTrace = TR_TraceHullFilterEx(traceStart, traceEnd, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);

    static bool routeBlocked;
    routeBlocked = TR_DidHit(hTrace);
    delete hTrace;

    if (routeBlocked)
        return false;

    return true;
}

stock void clearPathWait(int client) {
    g_AiChargers[client].m_flPathWaitStart = -1.0;
}

stock void enterPathWait(int client, bool invalidateOldPath) {
    static float now;
    now = GetGameTime();

    // 进入 Repath 等待期, 等待 Repath, 此时让引擎接管 Charger 动作, 清空连跳相关变量
    if (g_AiChargers[client].m_flPathWaitStart < 0.0)
        g_AiChargers[client].m_flPathWaitStart = now;

    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
    g_AiChargers[client].m_BhopType = BhopType_None;
    g_AiChargers[client].m_AirStrafe.init();

    if (!invalidateOldPath)
        return;

    // 等待一个冷却时间, 然后 Invalidate Path, 让引擎重新计算新的 Path
    if (now - g_AiChargers[client].m_flLastPathInvalidateTime < PATH_REPATH_COOLDOWN)
        return;

    // 如果需要销毁旧的 Path, 那么就销毁, 然后等待 Repath
    SDKCall(g_hSdkPathInvalidate, g_AiChargers[client].m_pPathFollower);
    g_AiChargers[client].m_flLastPathInvalidateTime = now;

    g_AiChargers[client].m_PathSegment.init();
    g_AiChargers[client].m_NextPathSegment.init();
    g_AiChargers[client].m_LastPathSegment.init();
}

stock void setupGroundAirStrafe(int client, float targetDist, float airCorrDist) {
    /*
    * 在 Charger 起跳前配置下一次空中侧向连跳参数
    * airCorrDist 表示 Charger 到空中速度修正目标点的距离, 这个目标点在不侧向连跳的时候是目标位置, 沿着 Path 侧向连跳时是 PathLookAheadGoal
    */
    static AirStrafe airStrafe;
    airStrafe = g_AiChargers[client].m_AirStrafe;

    // 每次 GroundSetup 都先重置本次 Strafe 状态, 如果后续条件不满足, 本次空中不会执行侧向偏移
    airStrafe.m_flStrafeStartDist = airCorrDist;
    airStrafe.m_flStrafeAmp = 0.0;
    airStrafe.m_StrafeType = StrafeType_None;

    /*
    * 启用侧向连跳条件如下
    * 1. g_cvBhopStrafeMinDeg 开启, 开启侧向偏移功能
    * 2. targetDist 足够远, 大于 g_cvBhopStrafeMinDist.FloatValue
    * 3. airCorrDist 足够远, 大于 GOAL_POS_TOLERANCE_DIST, 然后再根据距离决定做一次侧向还是两次侧向偏移
    */
    static bool strafeEnable;
    strafeEnable = (
        g_cvBhopStrafeMinDeg.FloatValue > 0.0 &&
        targetDist > g_cvBhopStrafeMinDist.FloatValue &&
        airCorrDist > GOAL_POS_TOLERANCE_DIST
    );

    if (!strafeEnable) {
        g_AiChargers[client].m_AirStrafe = airStrafe;
        return;
    }

    /*
    * 每次真正启用侧向连跳时, 方向和上一次相反
    * 如果之前没有进行过侧向连跳的话, 那么随机选择一个左右方向
    */
    if (airStrafe.m_StrafeDir == StrafeDir_None) {
        airStrafe.m_StrafeDir = (GetRandomFloatInRange(0.0, 1.0) > 0.5) ? StrafeDir_Left : StrafeDir_Right;
    } else if (airStrafe.m_StrafeDir == StrafeDir_Left) {
        airStrafe.m_StrafeDir = StrafeDir_Right;
    } else {
        airStrafe.m_StrafeDir = StrafeDir_Left;
    }

    /*
    * targetDist 已经通过 g_cvBhopStrafeMinDist.FloatValue
    * 当 airCorrDist 足够大时执行两次偏移, 当 airCorrDist 大于 g_cvBhopStrafeOnceDist 时执行一次偏移, 否则不执行偏移
    */
    if (airCorrDist >= g_cvBhopStrafeTwiceDist.FloatValue) {
        airStrafe.m_StrafeType = StrafeType_Twice;
    } else if (airCorrDist >= g_cvBhopStrafeOnceDist.FloatValue) {
        airStrafe.m_StrafeType = StrafeType_Once;
    } else {
        airStrafe.m_StrafeType = StrafeType_None;
    }

    /*
    * tan(angle)
    * 使用一个角度, 根据 forward 速度向量算出需要偏移的方向向量, 然后 desired = forward + (right * amp)
    * amp = tan(theta) 可以让 desired 最终向量相对于 forward 前向向量偏转 theta 度
    */
    airStrafe.m_flStrafeAmp = Tangent(DegToRad(GetRandomFloatInRange(g_cvBhopStrafeMinDeg.FloatValue, g_cvBhopStrafeMaxDeg.FloatValue)));

    g_AiChargers[client].m_AirStrafe = airStrafe;
}

stock void limitGroundBhopVel(float vel[3]) {
    static float horizontalSpeed;
    horizontalSpeed = getVectorLength2D(vel);

    if (horizontalSpeed <= 0.0 || horizontalSpeed <= g_cvBhopMaxSpeed.FloatValue)
        return;
    
    ScaleVector(vel, (g_cvBhopMaxSpeed.FloatValue / horizontalSpeed));
}

stock Action performPathGroundBhop(int client, float targetDist, const float pos[3], const float targetPos[3], float speed, bool visible, int& buttons, float ang[3]) {
    #pragma unused targetPos

    static float lookAheadPos[3];
    static float maxEstimateDist;
    maxEstimateDist = speed * getJumpAirTime();

    // 最小向前检查距离不能小于 PATH_LOOKAHEAD_MIN_DIST
    if (maxEstimateDist < PATH_LOOKAHEAD_MIN_DIST) {
        maxEstimateDist = PATH_LOOKAHEAD_MIN_DIST;
    }

    if (!getLookAheadGoalPos(client, pos, maxEstimateDist, lookAheadPos, g_cvPathLookAheadMaxDepth.IntValue)) {
        /*
        * 找不到可用的 LookAhead Goal Pos 不代表 Path 无效, 也不能因此切换到 Direct 连跳模式
        */
        ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_AirStrafe.m_StrafeType = StrafeType_None;
        
        return Plugin_Continue;
    }

    static float vFwd[3];

    // Debug print, if current PathSegment is not the last, print charger pos and look ahead goal pos, color: cyan
    /* DrawBeamPoint(lookAheadPos, NULL_VECTOR, {0, 255, 255, 255}, 0.1); */
    MakeVectorFromPoints(pos, lookAheadPos, vFwd);
    vFwd[2] = 0.0;

    if (NormalizeVector(vFwd, vFwd) <= 0.0) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        return Plugin_Continue;
    }

    ScaleVector(vFwd, speed + g_cvBhopImpulse.FloatValue);

    // 连跳前限制速度, 使检查距离与最终实际速度一致
    limitGroundBhopVel(vFwd);

    if (!nextTickPosCheck(client, vFwd, visible)) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_AirStrafe.m_StrafeType = StrafeType_None;
        return Plugin_Continue;
    }

    static float airCorrDist;
    airCorrDist = getVectorDistance2D(pos, lookAheadPos);

    // 只有确定本次能够起跳后, 才写入空中状态
    g_AiChargers[client].m_BhopType = BhopType_Path;
    g_AiChargers[client].m_vecAirCorrGoal = lookAheadPos;

    setupGroundAirStrafe(client, targetDist, airCorrDist);

    setForwardBhopInput(buttons, true);
    alignChargerFacingWithMovement(client, vFwd, ang);
    TeleportEntity(client, NULL_VECTOR, ang, vFwd);

    // 保存起跳速度, 防止空中速度衰减
    g_AiChargers[client].m_flLastHopSpeed = getVectorLength2D(vFwd);
    g_AiChargers[client].m_flLastAirVecModifyTime = GetEngineTime();

    stateLog.debugAll("Charger(%N) Path Ground Bhop, speed: %.2f, target dist: %.2f, air correction dist: %.2f, strafe type: %d",
        client, g_AiChargers[client].m_flLastHopSpeed, targetDist, airCorrDist, g_AiChargers[client].m_AirStrafe.m_StrafeType);

    return Plugin_Changed;
}

stock Action performDirectGrounBhop(int client, float targetDist, const float pos[3], const float targetPos[3], float speed, bool visible, int& buttons, float ang[3]) {
    static float vFwd[3];
    buildDirectBhopVelocity(pos, targetPos, speed, vFwd);

    vFwd[2] = 0.0;

    if (getVectorLength2D(vFwd) <= 0.0) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        return Plugin_Continue;
    }

    if (!isDirectBhopSafe(client, pos, targetPos, vFwd)) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_AirStrafe.m_StrafeType = StrafeType_None;
        return Plugin_Continue;
    }

    if (!nextTickPosCheck(client, vFwd, visible)) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_AirStrafe.m_StrafeType = StrafeType_None;
        return Plugin_Continue;
    }

    static float airCorrDist;
    airCorrDist = getVectorLength2D(vFwd) * getJumpAirTime();

    g_AiChargers[client].m_BhopType = BhopType_Normal;

    // Direct 连跳使用目标位置作为空中修正方向, 不需要写入 Path AirCorrGoal
    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);

    setupGroundAirStrafe(client, targetDist, airCorrDist);

    setForwardBhopInput(buttons, true);
    alignChargerFacingWithMovement(client, vFwd, ang);
    TeleportEntity(client, NULL_VECTOR, ang, vFwd);

    g_AiChargers[client].m_flLastHopSpeed = getVectorLength2D(vFwd);
    g_AiChargers[client].m_flLastAirVecModifyTime = GetEngineTime();

    stateLog.debugAll("Charger(%N) Direct Ground Bhop, speed: %.2f, target dist: %.2f, air correction dist: %.2f, strafe type: %d",
        client, g_AiChargers[client].m_flLastHopSpeed, targetDist, airCorrDist, g_AiChargers[client].m_AirStrafe.m_StrafeType);

    return Plugin_Changed;
}

/**
* 处理地面连跳逻辑
* @param client 客户端索引
* @param target 目标索引
* @param dist 与目标距离
* @param speed 当前速度
* @param visible 是否有视野
* @param nextSeg 下一个 PathSegment
* @param pos 当前位置
* @param targetPos 目标位置
* @param vVel 当前速度
* @return Action
**/
stock Action executeGroundBhop(
    int client, int target, float dist, float speed, bool visible,
    const float pos[3], const float targetPos[3], const float vVel[3], int& buttons, float ang[3]
) {
    // 如果无视野, 且不允许连跳, 返回
    if (!visible && !g_cvBhopNoVision.BoolValue)
        return Plugin_Continue;

    /*
        使用 Next PathSegment 的 Goal Pos 作为连跳加速度与空中速度方向修正的方向
        因为在一块 Nav 之内, Current PathSegment 的 Goal Pos 可能会根据当前 bot 位置被多次改变, 没有激活 PathSegment 之前, Goal Pos (不变)
        进入当前 PathSegment 并激活当前 PathSegment 后, 会根据当前 bot 位置改变 Goal Pos, Goal Pos 频繁被改变则会影响空中速度方向修正
    */
    /*
    * 沿着 Path 的连跳还需要注意当前 Path 是否断档, 比如 c4m2 楼梯, Charger 的一条 Path 可能最后一个节点在楼梯口
    * 此时直接判断 currentSegment == lastSegment 认为已经没有后续 Path, 让 Charger 沿着目标方向 (在楼的另一侧) 连跳会导致 Charger 摔下楼梯, 因此需要更加严格的判断
    * 如果还可以 Repath, 不要着急切换到朝着目标方向直线连跳
    * 
    * currentSeg != lastSeg 表示当前 Path 还有后续节点, 可以继续走
    * currentSeg == lastSeg 表示正在前往最后一个 Segment 的 GoalPos, Path 仍然有效
    * lastGoalReached 表示当前 Path 已经走完
    */
    static bool hasPath, atLastSegment, lastGoalReached;

    /*
    * currentSeg == lastSeg && !targetOnPath 可以解释为当前 Path 断裂, 等待 Repath
    * currentSeg == null && !targetOnPath 解释为目标不在有效 Nav 上, 直接朝着目标方向加速
    */
    static PathSegment currentSeg, lastSeg;
    currentSeg = g_AiChargers[client].m_PathSegment;
    lastSeg = g_AiChargers[client].m_LastPathSegment;

    // 当前 PathSegment 和当前 Path 最后一个 Segment 均有效, 则为路径有效
    hasPath = g_AiChargers[client].m_pPathFollower && (currentSeg.m_pPathSegment && lastSeg.m_pPathSegment);
    // 是否到达当前 Path 的最后一个 Segment
    atLastSegment = hasPath && (currentSeg.m_pPathSegment == lastSeg.m_pPathSegment);
    // 是否已经走完最后一个 PathSegment
    lastGoalReached = (atLastSegment && isFinalGoalReached(pos, vVel, currentSeg.m_vecGoalPos));

    /*
    * targetOnPath 判断目标是否在 Charger 当前 Path 上, 如果目标不在 Charger 当前 Path 上, 且 Charger 当前 Path 无效, 允许朝着目标方向连跳加速,
    * 平地正常 Path, 目标位于 Charger 当前 Path 上, 如果是 c4m2 楼梯口 Path 断裂, 那么 targetOnPath == false
    * hasSpecialMove 表示当前 Path 到目标是否中间存在 SegmentType != OnGround 的 Segment
    */
    static bool hasSpecialMove, targetOnPath;
    hasSpecialMove = false;
    targetOnPath = false;

    static Address targetNavArea;
    targetNavArea = L4D_GetLastKnownArea(target);
    if (!targetNavArea) {
        static float targetPos_cpy[3];
        targetPos_cpy = targetPos;
        targetPos_cpy[2] += 20.0;
        targetNavArea = L4D_GetNearestNavArea(targetPos_cpy, _, false, true, true, TEAM_SURVIVOR);
    }
    if (!targetNavArea) {
        stateLog.error("[ExecuteGroundBhop]: Client %N is on invalid NavArea!", client);
        targetOnPath = false;
    }
    if (hasPath && targetNavArea) {
        targetOnPath = isRemainingPathSupportsTarget(client, targetNavArea, hasSpecialMove);
    }

    stateLog.debugAll("[ExecuteGroundBhop]: Client: %d, dist: %.2f, speed: %.2f, visible: %d, hasPath: %d, atLastSegment: %d, lastGoalReached: %d, targetOnPath: %d",
        client, dist, speed, visible, hasPath, atLastSegment, lastGoalReached, targetOnPath);


    /*
    * 直接连跳模式加入退出缓冲距离, 避免在 direct bhop 距离阈值附近来回切换模式
    */
    static float directBhopDist;
    directBhopDist = g_cvDirectBhopDist.FloatValue;
    if (g_AiChargers[client].m_BhopType == BhopType_Normal) {
        directBhopDist += DIRECT_BHOP_TOLERANCE_BUFFER;
    }

    /*
    * Direct 距离阈值只用于限制有 Path 时的模式切换
    * 当前完全没有 Path 时, 允许直接尝试朝目标方向连跳, 再交给 performDirectGrounBhop 做安全检查
    */
    static bool withinDirectDistance;
    withinDirectDistance = (
        !hasPath ||
        dist <= directBhopDist
    );

    /*
    * 进行朝着目标方向直线连跳的基础判断
    * 1. pathProvenDirect: 目标仍然处于剩余 Path 上, 且中间没有特殊移动, 说明 Path 证明可以直接朝着目标方向连跳
    * 2. closeStalePath: 目标已经不在当前 Path 上, 通常是由于目标移动, 然后旧的 Path 已经过期
    *   此时允许尝试直线连跳, 但是需要通过 performDirectGrounBhop 内部的 isDirectBhopSafe 和 nextTickPosCheck
    */

    static bool pathProvenDirect;
    pathProvenDirect = (
        hasPath &&
        targetOnPath &&
        !hasSpecialMove
    );

    static bool closeStalePath;
    closeStalePath = (
        hasPath &&
        !targetOnPath &&
        withinDirectDistance &&
        visible
    );

    static bool canTryDirectBhop;
    canTryDirectBhop = (
        visible &&
        withinDirectDistance && (
            pathProvenDirect ||
            closeStalePath
        )
    );

    static Action directBhopRes;

    /*
    * 正常平地, 可以直接使用到目标的直线方向连跳, Path 有效且仍然通向目标, 地形检查通过, 直接转为直线连跳
    */
    if (canTryDirectBhop) {
        g_AiChargers[client].m_BhopType = BhopType_DirectCandidate;

        directBhopRes = performDirectGrounBhop(client, dist, pos, targetPos, speed, visible, buttons, ang);

        // 正常连跳, return Plugin_Changed
        if (directBhopRes != Plugin_Continue) {
            clearPathWait(client);
            return directBhopRes;
        }

        /*
        * 如果 performDirectGrounBhop 拒绝执行连跳, 那么返回 Plugin_Continue
        * 这通常说明近距离目标不在旧的 Path 上, 已经产生了移动, 而且直线连跳不安全, 这通常是楼梯口, 断层等需要绕路的场景
        * 不要继续沿着旧的 Path 连跳前进, 而是将当前旧的 Path Invalidate, 交给给引擎决定, 重新计算新的 Path
        */
        if (closeStalePath) {
            enterPathWait(client, true);
            return Plugin_Continue;
        }
    }

    /*
    * 当前 Path 仍有未完成部分, 即使距离已经进入直线连跳阈值, 只要直线连跳不安全, 那么就继续沿着 Path
    */
    if (hasPath && !lastGoalReached) {
        clearPathWait(client);

        return performPathGroundBhop(client, dist, pos, targetPos, speed, visible, buttons, ang);
    }

    /*
    * 到达 Path 终点, 但它没有安全连接到目标, 返回原生控制, 等待 ChargerAttack::Update 计算新的 Path
    */
    if (hasPath && lastGoalReached) {
        enterPathWait(client, true);

        // canEnterDirectBhop 返回 false 说明直线连跳不安全, 然后当前 Path 已经走完, 返回原生控制, 等待 Repath
        return Plugin_Continue;
    }

    // 当前完全没有 Path, 可能是目标站在了无效的 NavArea 上, 直接尝试直线连跳
    static bool canTryNoPathDirectBhop;
    canTryNoPathDirectBhop = (
        visible &&
        withinDirectDistance
    );

    stateLog.debugAll("[ExecuteGroundBhop]: Client: %N, visible: %d, withinDirectDist: %d, directDist: %.2f, canTryNoPathDirectBhop: %d",
        client, visible, withinDirectDistance, directBhopDist, canTryNoPathDirectBhop);

    if (canTryNoPathDirectBhop) {
        directBhopRes = performDirectGrounBhop(client, dist, pos, targetPos, speed, visible, buttons, ang);

        if (directBhopRes != Plugin_Continue) {
            clearPathWait(client);

            return directBhopRes;
        }
    }

    return Plugin_Continue;
}

stock bool buildStrafedDesiredVector(int client, const float baseDir[3], float curDist, float outDesired[3]) {
    outDesired = baseDir;
    outDesired[2] = 0.0;

    if (NormalizeVector(outDesired, outDesired) <= 0.0)
        return false;

    static StrafeType strafeType;
    strafeType = g_AiChargers[client].m_AirStrafe.m_StrafeType;

    if (strafeType == StrafeType_None || g_cvBhopStrafeMinDeg.FloatValue <= 0.0 || curDist <= GOAL_POS_TOLERANCE_DIST) {
        return false;
    }

    static float startDist;
    startDist = g_AiChargers[client].m_AirStrafe.m_flStrafeStartDist;

    if (startDist <= 10.0)
        return false;

    static float progress;
    progress = curDist / startDist;

    if (progress > 1.0)
        progress = 1.0;
    else if (progress < 0.0)
        progress = 0.0;

    // 获取当前侧向连跳的方向
    static StrafeDir strafeDir;
    strafeDir = g_AiChargers[client].m_AirStrafe.m_StrafeDir;

    // 获取之前起跳时设置的振幅
    static float amp;
    amp = g_AiChargers[client].m_AirStrafe.m_flStrafeAmp;

    if (amp <= 0.0 || strafeDir == StrafeDir_None)
        return false;

    // 从离地时的 0 偏移开始，避免第一帧突然横向硬拐。
    static float M, phase;
    M = 0.0;
    phase = 1.0 - progress;

    if (strafeType == StrafeType_Once) {
        // 一次侧移：离地和落地时均回到路径方向，中段达到最大偏移。
        M = Sine(phase * PI) * float(view_as<int>(strafeDir)) * amp;
    } else if (strafeType == StrafeType_Twice) {
        // 两次侧移：平滑经过左右两侧，起点和终点都没有方向突变。
        M = Sine(phase * PI * 2.0) * float(view_as<int>(strafeDir)) * amp;
    }

    // 计算与 vDir 方向正交的方向向量
    static float vRight[3];
    GetVectorCrossProduct(outDesired, {0.0, 0.0, 1.0}, vRight);
    
    if (NormalizeVector(vRight, vRight) <= 0.0)
        return false;

    // 算出包含了偏移曲线在内的最终方向
    outDesired[0] += vRight[0] * M;
    outDesired[1] += vRight[1] * M;
    outDesired[2] = 0.0;
    NormalizeVector(outDesired, outDesired);

    // 可视化黄色 desired 位置曲线, 绿色 vRight 方向向量曲线, 橙色 air correction goal 坐标点
    /* static float vPos[3];
    vPos = pos;
    ShowDir(COLOR_GREEN, vPos, vRight, 5.0, 50.0);
    ShowDir(COLOR_YELLOW, vPos, vDesired, 5.0, 50.0);
    DrawBeamPoint(g_AiChargers[client].m_vecAirCorrGoal, NULL_VECTOR, {251, 164, 20, 255}, 10.0); */

    return true;
}

stock bool prepareSmoothAirCorrection(int client, float baseLerp, float& now, float& smoothLerp) {
    now = GetEngineTime();

    if (g_AiChargers[client].m_flLastAirVecModifyTime <= 0.0) {
        g_AiChargers[client].m_flLastAirVecModifyTime = now;
        return false;
    }

    if (now - g_AiChargers[client].m_flLastAirVecModifyTime < AIR_CORRECTION_STEP_INTERVAL)
        return false;

    if (baseLerp <= 0.0)
        return false;
    if (baseLerp > 1.0)
        baseLerp = 1.0;

    static float responseTime, stepRatio;
    responseTime = g_cvAirVecModifyInterval.FloatValue;
    if (responseTime < AIR_CORRECTION_STEP_INTERVAL)
        responseTime = AIR_CORRECTION_STEP_INTERVAL;

    stepRatio = AIR_CORRECTION_STEP_INTERVAL / responseTime;
    smoothLerp = 1.0 - Pow(1.0 - baseLerp, stepRatio);
    return smoothLerp > 0.0;
}

/**
* 处理空中速度方向修正逻辑
* @param client 客户端索引
* @param dist 到目标距离
* @param speed 当前速度
* @param visible 是否有目标视野
* @param nextSeg 下一个 PathSegment
* @param pos 当前位置
* @param target 目标位置
* @param vVel 当前速度向量
* @return Action
**/
stock Action executeAirCorrection(
    int client, float dist, float speed, bool visible,
    const float pos[3], const float targetPos[3], const float vVel[3], int& buttons, float ang[3]
) {

    static float vFwd[3], vDir[3], dot, d2Goal;

    if (g_AiChargers[client].m_BhopType != BhopType_Path &&
        g_AiChargers[client].m_BhopType != BhopType_Normal
    ) {
        return Plugin_Continue;
    }

    // 空中只保留朝实际运动方向的前进姿态，避免重复跳/蹲造成动画抽搐。
    setForwardBhopInput(buttons, false);
    alignChargerFacingWithMovement(client, vVel, ang);

    static float now, smoothLerp;
    static bool correctionReady;
    correctionReady = prepareSmoothAirCorrection(client, g_cvAirVecModifyLerp.FloatValue, now, smoothLerp);

    // ============================================================
    // 1. 当前连跳模式为基于 PATH 的连跳, 进行基于 PATH 的空中速度方向修正
    // ============================================================
    if (g_AiChargers[client].m_BhopType == BhopType_Path) {

        // 保持离地时选定的路径目标，空中不再追随不断变化的 PathSegment。
        // 获取 Charger 当前的连跳前前向寻找的目标点
        static float curGoal[3];
        curGoal = g_AiChargers[client].m_vecAirCorrGoal;
        
        /*
            将 IsNullVector 改用 IsZeroVector, 因为 NULL_VECTOR 仅仅是一个标志, 将参数传递给 C++ 引擎时表示这个参数是 null (比如 SdkCall 调用函数, 参数是 Vector &pos 这样的, 如果不想传递, 可以传递 NULL_VECTOR), 并不代表在插件编写自己定义的 float[3] 类型的变量无效
            e.g., float v[3]; v = NULL_VECTOR; IsNullVector(v) 返回 false, 将 v 的三个分量全部置为 0, 再次判断, 也是返回 false, 因此无法使用 IsNullVector 判断插件中的一个向量是否为无效
        */
        if (IsZeroVector(curGoal)) {
            return Plugin_Changed;
        }

        // 一次起跳只使用离地时选定的路径目标；空中反复换节点会造成左右抽搐。
        MakeVectorFromPoints(pos, curGoal, vDir);
        dot = calcVectorAngle(vVel, vDir, true);

        // 路径目标已经在身后时保持当前惯性，等落地后再选择下一段路径。
        if (dot >= AIR_CORRECTION_MAX_TURN_DEG)
            return Plugin_Changed;

        // 获取离地时路径目标的剩余水平距离。
        d2Goal = getVectorDistance2D(pos, g_AiChargers[client].m_vecAirCorrGoal);

        // ============================================================
        // 处理主动侧向连跳
        // ============================================================
        static float vDesired[3];
        vDesired = vDir;

        static bool isStrafing;
        isStrafing = buildStrafedDesiredVector(client, vDir, d2Goal, vDesired);

        static float desiredAngle;
        desiredAngle = calcVectorAngle(vVel, vDesired, true);

        // ============================================================
        // 正常连跳, 判断是否需要空中速度修正
        // ============================================================
        static bool shouldCorrect;
        shouldCorrect = false;
        
        static float airCorrLerp;
        airCorrLerp = smoothLerp;
        static float maxTurnAngle;
        maxTurnAngle = g_cvAirVecModifyMaxDegree.FloatValue;
        if (maxTurnAngle > AIR_CORRECTION_MAX_TURN_DEG)
            maxTurnAngle = AIR_CORRECTION_MAX_TURN_DEG;

        if (isStrafing &&
            desiredAngle >= AIR_CORRECTION_MIN_TARGET_DEG &&
            desiredAngle <= maxTurnAngle &&
            d2Goal > GOAL_POS_TOLERANCE_DIST
        ) {
            shouldCorrect = true;
        } else {
            if (
                dot >= g_cvAirVecModifyMinDegree.FloatValue &&
                dot <= maxTurnAngle &&
                d2Goal > GOAL_POS_TOLERANCE_DIST
            ) {
                shouldCorrect = true;
            }
        }

        if (shouldCorrect && correctionReady) {
            buildAirCorrectionVelocity2D(vVel, vDesired, airCorrLerp, speed, vFwd);

            alignChargerFacingWithMovement(client, vFwd, ang);
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vFwd);

            // 记录空中速度方向修正时间
            g_AiChargers[client].m_flLastAirVecModifyTime = now;
            return Plugin_Changed;
        }

        // Path 跳不能继续落入朝生还者修正的分支。
        return Plugin_Changed;
    }

    // ============================================================
    // 寻路结束, 或路径无效, 进行选择性空中速度方向修正
    // ============================================================

    // 防止目标在上方频繁触发速度修正
    static float dx, dz, pitch;
    dx = SquareRoot(Pow(targetPos[0] - pos[0], 2.0) + Pow(targetPos[1] - pos[1], 2.0));
    dz = targetPos[2] - pos[2];
    pitch = RadToDeg(ArcTangent2(dz, dx));
    if (pitch > 45.0)
        return Plugin_Changed;

    // 计算当前方向与到目标方向的夹角
    MakeVectorFromPoints(pos, targetPos, vDir);
    dot = calcVectorAngle(vVel, vDir, true);

    static float vDirectDesired[3];
    vDirectDesired = vDir;

    static bool isDirectStrafing;
    isDirectStrafing = buildStrafedDesiredVector(client, vDir, dist, vDirectDesired);

    static float directDesiredAngle;
    directDesiredAngle = calcVectorAngle(vVel, vDirectDesired, true);

    static bool inAngleRange;

    static float directMaxTurnAngle;
    directMaxTurnAngle = g_cvAirVecModifyMaxDegree.FloatValue;
    if (directMaxTurnAngle > AIR_CORRECTION_MAX_TURN_DEG)
        directMaxTurnAngle = AIR_CORRECTION_MAX_TURN_DEG;

    inAngleRange = (dot >= g_cvAirVecModifyMinDegree.FloatValue && dot <= directMaxTurnAngle);

    if (visible &&
        correctionReady &&
        directDesiredAngle <= directMaxTurnAngle &&
        (
            (isDirectStrafing && directDesiredAngle >= AIR_CORRECTION_MIN_TARGET_DEG) ||
            (
                inAngleRange &&
                dist <= g_cvDirectBhopDist.FloatValue
            )
        )
    ) {
        stateLog.debugAll("Charger: %N triggered air speed modify, current vector angle: %.2f", client, dot);

        static float directAirCorrLerp;
        directAirCorrLerp = smoothLerp;
        
        buildAirCorrectionVelocity2D(vVel, vDirectDesired, directAirCorrLerp, speed, vFwd);

        vFwd[2] = vVel[2];
        alignChargerFacingWithMovement(client, vFwd, ang);
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, vFwd);
        // 记录空中速度方向修正时间
        g_AiChargers[client].m_flLastAirVecModifyTime = now;
    }
    return Plugin_Changed;
}

stock void buildAirCorrectionVelocity2D(const float curVel[3], const float desiredVec[3], float lerp, float finalSpeed, float outVel[3]) {
    static float curDir[3], desireDir[3];
    curDir = curVel;
    curDir[2] = 0.0;

    desireDir = desiredVec;
    desireDir[2] = 0.0;

    NormalizeVector(curDir, curDir);
    NormalizeVector(desireDir, desireDir);

    if (lerp < 0.0) {
        lerp = 0.0;
    } else if (lerp > 1.0) {
        lerp = 1.0;
    }

    outVel[0] = curDir[0] + (desireDir[0] - curDir[0]) * lerp;
    outVel[1] = curDir[1] + (desireDir[1] - curDir[1]) * lerp;
    outVel[2] = 0.0;
    NormalizeVector(outVel, outVel);

    // 只按这一小步真正转过的角度损失动量，轻微修正几乎不受影响。
    static float actualTurnAngle, speedLoss;
    actualTurnAngle = calcVectorAngle(curDir, outVel, true);
    speedLoss = g_cvAirTurnSpeedLoss.FloatValue * (actualTurnAngle / 90.0);
    if (speedLoss < 0.0)
        speedLoss = 0.0;
    else if (speedLoss > 0.5)
        speedLoss = 0.5;

    finalSpeed *= 1.0 - speedLoss;
    ScaleVector(outVel, finalSpeed);
    
    outVel[2] = curVel[2];
}

/**
* 2026-01-13
* Charger 在连跳接近目标的时候, 如果落地, 可以检测周围是否有距离原目标更近的目标, 如果有, 且新目标无法在 Charger 朝他冲锋的时间内躲开冲锋, 直接更换目标冲锋,
* 这样可以一定程度上减少原目标距离 Charger 较远时, 一味地追击原目标而在追击过程中被其他生还者打掉很多血量, 条件:
* 1. 新目标是有效生还者, 且没有倒地挂边和被 hunter 控制 (其他特感 smoker, jockey 等控制可以抢控)
* 2. 新目标必须可视, 而且距离新目标的距离比原目标更近
* @param client 客户端索引
* @param curTarDist 当前目标距离
* @param unavoidableDist 新目标在冲锋路径上无法躲避冲锋的距离
* @return int 如果找到了更好的新目标, 返回新目标的客户端索引, 若没有, 返回 -1
**/
stock int getChargeUnavoidableTarget(int client, int curTarget, float pos[3], float curTarDist, float unavoidableDist = 150.0) {
    if (!isAiCharger(client))
        return -1;
    if (!IsValidSurvivor(curTarget) || !IsPlayerAlive(curTarget))
        return -1;

    // 获取冲锋时的冲锋速度
    static float chargeSpeed;
    chargeSpeed = !cvChargeSpeed ? DEFAULT_CHARGE_SPEED : cvChargeSpeed.FloatValue;

    // 遍历所有生还者, 寻找更近的目标
    static float dist, targetPos[3], targetEyePos[3];
    for (int i = 1; i <= MaxClients; i++) {
        if (i == client || i == curTarget || !IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;
        if (IsClientIncapped(i) || IsClientHanging(i))
            continue;
        // 跳过被 hunter 控制的生还者, 无法抢控
        if (isSurvivorPinned(i))
            continue;

        GetClientAbsOrigin(i, targetPos);
        GetClientEyePosition(i, targetEyePos);
        // 高度差过大的目标不作为直接冲锋目标
        if (!isChargeHeightReachable(pos, targetPos))
            continue;

        // 跳过不可直视的玩家
        if (!L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, TEAM_SURVIVOR, 0, targetEyePos))
            continue;
        
        dist = getVectorDistance2D(pos, targetPos);
        // 跳过距离比当前目标还远的玩家
        if (dist > unavoidableDist || dist > curTarDist)
            continue;
        
        // 计算冲锋无法躲避的条件
        static float timeToImpact;
        static float vTarVelVec[3], predictDist;
        timeToImpact = dist / chargeSpeed;
        GetEntPropVector(i, Prop_Data, "m_vecVelocity", vTarVelVec);
        vTarVelVec[2] = 0.0;
        // 计算玩家在 charger 冲锋到此处的时间后的位置 (线性计算)
        ScaleVector(vTarVelVec, timeToImpact);
        predictDist = GetVectorLength(vTarVelVec);

        // 获取冲锋方向 (直接使用自身位置到当前玩家位置的方向向量作为冲锋方向)
        static float chargeDir[3];
        MakeVectorFromPoints(pos, targetPos, chargeDir);
        NormalizeVector(chargeDir, chargeDir);

        // 计算玩家速度在冲锋方向上的投影长度
        // prj = |A| * cosθ, |A| * cosθ = dot(A,B) / |B|, B 已经归一化, 因此 |A| * cosθ = dot(A,B)
        static float dot;
        dot = GetVectorDotProduct(vTarVelVec, chargeDir);
        // 根据勾股定理计算垂直于冲锋方向上的躲避距离
        static float effDodgeDistSqr, effDodgeDist;
        effDodgeDistSqr = Pow(predictDist, 2.0) - Pow(dot, 2.0);
        if (effDodgeDistSqr < 0.0) {
            effDodgeDistSqr = 0.0;
        }
        effDodgeDist = SquareRoot(effDodgeDistSqr);
        if (effDodgeDist < unavoidableDist) {
            stateLog.debugAll("Charger (%N) find a unavoidable target (%N), distance: %.2f", client, i, dist);
            return i;
        }
    }
    return -1;
}

#define AIR_CHARGE_LINE_MIN_PREDICT_TIME    0.05
#define AIR_CHARGE_LINE_MAX_PREDICT_TIME    0.25

/**
* 进入 Bait, Lock, Charge 阶段时, 当 Charger 在空中时, 将其水平速度方向修正到可见目标的预测位置
* @param client 客户端索引
* @param target 目标客户端索引
* @param visible 是否可见目标
* @return bool, 修改速度方向成功返回 true
* @error 
**/
stock bool preserveAirChargeLine(int client, int target, bool visible, int& buttons, float ang[3]) {
    if (!isAiCharger(client)) {
        return false;
    }
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
        return false;
    }
    if (!visible) {
        return false;
    }
    // 仅做空中速度修正, Charger 在地面时不进行速度修正
    if (IsClientOnGround(client)) {
        return false;
    }
    if (isChargerCharging(client) || IsPinningSurvivor(client)) {
        return false;
    }

    static float pos[3], targetPos[3], curVel[3], targetVel[3];
    L4D_GetEntityWorldSpaceCenter(client, pos);
    L4D_GetEntityWorldSpaceCenter(target, targetPos);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", curVel);
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetVel);

    setForwardBhopInput(buttons, false);
    buttons &= ~(IN_ATTACK | IN_ATTACK2);
    alignChargerFacingWithMovement(client, curVel, ang);

    static float now, smoothLerp;
    if (!prepareSmoothAirCorrection(client, g_cvAirVecModifyLerp.FloatValue, now, smoothLerp))
        return true;

    /*
    * 检查目标对 Charger 的几何关系, 目标过近或者过高, 或 Charger 明显在目标上方太多时, 不做空中速度方向修正
    */
    static float dx, dz, pitch;
    dx = getVectorDistance2D(pos, targetPos);
    if (dx <= 1.0) {
        return true;
    }

    dz = targetPos[2] - pos[2];
    pitch = RadToDeg(ArcTangent2(dz, dx));
    if (pitch > 45.0) {
        return true;
    }

    if (pos[2] - targetPos[2] > getChargeHeightLimit()) {
        return true;
    }

    static float curSpeed, finalSpeed;
    curSpeed = getVectorLength2D(curVel);
    if (curSpeed <= 1.0) {
        return true;
    }

    // 空中修正只改变方向，不补回起跳速度，也不额外增加速度。
    finalSpeed = curSpeed;
    // 最大速度不能超过设置的连跳速度上限
    if (finalSpeed > g_cvBhopMaxSpeed.FloatValue) {
        finalSpeed = g_cvBhopMaxSpeed.FloatValue;
    }

    static float predictTime;
    predictTime = dx / finalSpeed;
    if (predictTime < AIR_CHARGE_LINE_MIN_PREDICT_TIME) {
        predictTime = AIR_CHARGE_LINE_MIN_PREDICT_TIME;
    } else if (predictTime > AIR_CHARGE_LINE_MAX_PREDICT_TIME) {
        predictTime = AIR_CHARGE_LINE_MAX_PREDICT_TIME;
    }

    static float predictPos[3];
    predictPos[0] = targetPos[0] + (targetVel[0] * predictTime);
    predictPos[1] = targetPos[1] + (targetVel[1] * predictTime);
    predictPos[2] = targetPos[2];

    static float desiredDir[3], outVel[3];
    MakeVectorFromPoints(pos, predictPos, desiredDir);
    desiredDir[2] = 0.0;

    if (NormalizeVector(desiredDir, desiredDir) <= 0.0) {
        return true;
    }

    static float turnAngle;
    turnAngle = calcVectorAngle(curVel, desiredDir, true);
    static float maxTurnAngle;
    maxTurnAngle = g_cvAirVecModifyMaxDegree.FloatValue;
    if (maxTurnAngle > AIR_CORRECTION_MAX_TURN_DEG)
        maxTurnAngle = AIR_CORRECTION_MAX_TURN_DEG;
    if (turnAngle > maxTurnAngle) {
        return true;
    }
    if (turnAngle < AIR_CORRECTION_MIN_TARGET_DEG) {
        return true;
    }

    buildAirCorrectionVelocity2D(curVel, desiredDir, smoothLerp, finalSpeed, outVel);
    outVel[2] = curVel[2];

    alignChargerFacingWithMovement(client, outVel, ang);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, outVel);

    /*
    * 当前已经改为朝着目标预测位置修正, 所以不再使用 PahtLookAhead GoalPos
    * 空中速度修正应该稳定朝着目标预测位置靠近, 不应该继续 Strafe
    */
    g_AiChargers[client].m_BhopType = BhopType_Normal;
    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
    g_AiChargers[client].m_AirStrafe.m_StrafeType = StrafeType_None;
    g_AiChargers[client].m_flLastHopSpeed = getVectorLength2D(outVel);
    g_AiChargers[client].m_flLastAirVecModifyTime = now;

    return true;
}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateApproach_OnExit(int client) {
    stateLog.debugAll("\n========== Charger (%N) State Approach On Exit ===========", client);
    // 重置空中急停标记
    g_AiChargers[client].m_bHasAirBreaked = false;
}
