#if defined _state_bait_included_
    #endinput
#endif
#define _state_bait_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../setup.inc"
#include "../stocks.inc"
#include "./state.inc"

#define STATE_BAIT_NAME         "STATE_BAIT"
#define TARGET_PURSUIT_FACTOR   1.2       // 面对手持近战目标 Charger 后跳时, 此时目标若朝着 Charger 移动, Charger 后跳速度的加速倍数
#define TARGET_RETREAT_FACTOR   0.5       // 面对手持近战目标 Charger 后跳时, 此时目标若远离 Charger 移动, Charger 后跳速度的减速倍数
#define MELEE_PRESS_MIN_SPEED   50.0      // 目标朝 Charger 移动速度超过该值时, 视为主动进入近战危险区
#define MELEE_EMERGENCY_BUFFER  20.0      // 目标距离 Charger 小于 (meleeRange + 这个值) 时, 视为非常危险, 无论目标速度如何都尝试后跳
#define BAIT_LOST_SIGHT_GRACE   3.0       // 连续丢失目标视野超过该时间才退出 Bait

// =========================================================================
// State Bait 接近目标时的博弈状态 (dist < g_cvBhopMinDist.FloatValue 时进入 BAIT_STATE)
// 注册状态函数
// =========================================================================
stock void RegisterState_Bait() {
    ChargerState stateBait;
    strcopy(stateBait.name, sizeof(stateBait.name), "State_Bait");
    stateBait.OnEnter = StateBait_OnEnter;
    stateBait.OnUpdate = StateBait_OnUpdate;
    stateBait.OnExit = StateBait_OnExit;
    g_ChargerStates.PushArray(stateBait);
}

// ============================================================
// OnEnter 函数
// ============================================================
stock void StateBait_OnEnter(int client) {
    g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    stateLog.debugAll("\n========== Charger (%N) State Bait On Enter ===========", client);
}

// ============================================================
// OnUpdate 函数
// ============================================================
stock Action StateBait_OnUpdate(int client, int& buttons, float vel[3], float ang[3]) {
    if (!isAiCharger(client))
        return Plugin_Continue;
    if (IsPinningSurvivor(client))
        return Plugin_Continue;
    
    static int target;
    target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
        stateLog.debugAll("(%s) Charger (%N)'s target %d is invalid, transition to APPROACH STATE", STATE_BAIT_NAME, client, target);
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

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
    // 目标是否正在看着 charger
    // 除了目标之外还有多少生还者正在看着 charger
    static bool isWatching, isOnGround;
    static int watchers;
    isOnGround = IsClientOnGround(client);
    isWatching = isTargetWatchingCharger(client, target, g_cvTargetWatchMaxDeg.FloatValue);
    watchers = isAnySurvivorWatchingCharger(client, target, g_cvTargetWatchMaxDeg.FloatValue);
    // 目标威胁类型
    static TargetThreatType threatType;
    threatType = getTargetThreatType(client, target);

    // 只在 Charger 落地后检查高度, 避免后跳在空中时因高度差而错误的退出 Bait 状态
    if (isOnGround && !isChargeHeightReachable(pos, targetPos)) {
        stateLog.debugAll("Charger (%N) bait target (%N) height diff %.2f > %.2f, transition to APPROACH STATE",
            client, target,FloatAbs(pos[2] - targetPos[2]), CHARGE_Z_THRESHOLD);
        
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    /*
    * Bait 可能在 Charger 仍处于上一次 Approach 连跳的空中阶段时触发 (在空中距离目标小于 BaitRange 进入 Bait 状态)
    * 之前的 Bait State 并没有修正空中速度, 如果此时不持续修正空中速度, Charger 会沿着旧的 Path/Strafe 速度从目标侧面飞走
    * 导致后续 Bait -> Locked -> Charging 时 Charger 已经飞出去很远, 需要从 Charging -> Approach 继续接近目标, 错过一次冲锋
    */
    static bool airLineCorrected;
    airLineCorrected = false;

    /*
    * 目标的威胁类型不是近战, 且 Charger 从 Approach 状态转为 Bait 状态但是最后一跳还没结束还在空中时
    * 进行空中速度修正, 避免 Charger 飞过目标
    */
    if (threatType != Threat_Melee && !isOnGround && visible) {
        airLineCorrected = preserveAirChargeLine(client, target, visible, buttons, ang);
    }

    // ============================================================
    // 进入博弈状态, 说明距离正常威胁目标距离小于 g_cvBhopMinDist.FloatValue
    // 距离手持近战目标距离小于 melee_range + g_cvMeleeBaitZoneMaxRange.FloatValue
    // 这时候先阻止冲锋, 并尝试右键挥拳, 若后续满足冲锋条件, 转换到冲锋状态
    // ============================================================
    if (isOnGround)
        buttons |= IN_ATTACK2;
    else
        buttons &= ~(IN_ATTACK | IN_ATTACK2);
    setChargerAbilityCooldown(client, 1.0);

    // ============================================================
    // 优先行动检查, 检测是否有更好的可以直接冲锋的目标, 如果有, 直接转换为冲锋状态
    // 这避免了如果在与手持近战的目标博弈时, 另一个生还者在 charger 身后疯狂输出的行为
    // 若 charger 身后突然出现另一个生还者, 且 charger 此时距离到他更近且他无法躲避冲锋, 直接向他冲锋, 否则, 继续朝着原目标冲锋
    // ============================================================
    if (isOnGround) {
        static int betterTarget;
        betterTarget = getChargeUnavoidableTarget(client, target, pos, dist, g_cvBhopMinDist.FloatValue);
        if (IsValidSurvivor(betterTarget) && IsPlayerAlive(betterTarget) &&
            isChargeAbilityReady(client) &&
            isChargeTargetHeightReachable(client, betterTarget) &&
            !isChargePathBlocked(client, betterTarget)
        ) {
            stateLog.debugAll("Charger (%N) find a better charge target %N, transition to LOCKED STATE", client, betterTarget);
            g_AiChargers[client].m_iBetterTarget = GetClientUserId(betterTarget);
            g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
            return Plugin_Changed;
        }
    }

    // ============================================================
    // 检查是否需要退出博弈状态, 转移到接近状态
    // 1. 不可见目标时, 转换为接近状态
    // 2. 目标非手持近战, 且到目标距离大于 bhopMinDist + 容差距离, 转换为接近状态
    // 3. 目标手持近战, 且到目标距离大于 meleeRange + baitZoneMax, 出了博弈区, 转换为接近状态
    // ============================================================
    if (shouldExitBaitState(client, target, dist, visible, threatType)) {
        /*
        * Bait 状态下空中速度修正成功, 但是已经达到了退出 Bait 状态的条件, 是否直接退出 Bait 转给 Approach 状态空中修正?
        * 理论上不应该, 这里返回 Plugin_Changed 的语义是当前 Charger 在 Bait 状态的空中, 然后已经对空中速度进行修正
        * Charger 在空中的时候先让其继续修正, 暂时不要在同一帧之内切换状态, 否则在 Bait 中做了速度修正, 然后又退出 Bait, 速度修正就被打断
        * 所以等到 Charger 落地, 再切换到 Approach 状态
        */
        if (airLineCorrected) {
            return Plugin_Changed;
        }

        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    // ============================================================
    // 如果当前目标已经被其他强控特感控制, hunter, charger
    // 中止转换到 CHARGING STATE, 停留在 BAIT 状态, 持续对目标挥拳
    // ============================================================
    if (isSurvivorPinned(target)) {
        // stateLog.debugAll("Charger (%N)'s target (%N) is pinned! Suspending charge, melee to it", client, target);
        return Plugin_Continue;
    }

    // ============================================================
    // 根据威胁类型分别处理
    // ============================================================
    static Action resAction;
    if (threatType == Threat_Melee) {
        // handleMeleeThreat 的返回值为 Plugin_Changed 表示执行了后跳动作, 需要结束这一帧
        resAction = handleMeleeThreat(client, target, dist, visible, isWatching, watchers, buttons, ang);
        if (resAction != Plugin_Continue)
            return resAction;
        /*
        * 如果 handleMeleeThreat 中不能冲锋, 也不允许向后跳, 或向后跳失败了, 且 Charger 在地上
        * 那么如果目标正在看着 Charger, Charger 进入 baitZoneMin 那么 Charger 后退, 出了 baitZoneMax 朝着目标前进进行近战博弈
        * 若向后移动方向不安全, 且技能就绪, 那么直接冲锋
        */
        static Action distanceControlResult;
        distanceControlResult = maintainMeleeBaitDistance(client, target, dist, visible, vel, buttons, ang);
        if (distanceControlResult != Plugin_Continue)
            return distanceControlResult;
    } else if (threatType == Threat_Shotgun) {
        resAction = handleShotgunThreat(client, target, dist, visible);
    } else {
        resAction = handleNonMeleeThreat(client, target, dist, visible);
    }

    if (resAction != Plugin_Continue)
        return resAction;

    return airLineCorrected ? Plugin_Changed : Plugin_Continue;
}

/**
* 当 Charger 距离目标距离小于 baitZoneMin 时, 若目标看着 Charger 那么 Charger 后退, 如果距离目标距离大于 baitZoneMax 那么前进继续接近目标
* 后跳时保留远离目标的水平动量, 只在空中存在异常指向目标的速度 (如 Approach 最后一跳进入 BaitZone, 那么急停, 清除输入和当前速度)
* @param client Charger 客户端索引
* @param target 目标客户端索引
* @param dist 到目标的距离
* @param visible 是否可见目标
* @param cmdVel 当前速度
* @param buttons 输入按键状态
* @return Action
* @error 
**/

#define BAIT_RETREAT_NONE       0
#define BAIT_RETREAT_BACK       1
#define BAIT_RETREAT_FORWARD    -1

Action maintainMeleeBaitDistance(int client, int target, float dist, bool visible, float cmdVel[3], int& buttons, float ang[3]) {
    static float pos[3], targetPos[3], currentVel[3], awayDir[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", currentVel);

    // awayDir = target -> Charger
    MakeVectorFromPoints(targetPos, pos, awayDir);
    awayDir[2] = 0.0;

    if (NormalizeVector(awayDir, awayDir) <= 0.0)
        return Plugin_Continue;

    // currentAwaySpeed > 0 表示 Charger 正沿 target -> Charger 方向远离目标。
    static float currentAwaySpeed;
    currentAwaySpeed = GetVectorDotProduct(currentVel, awayDir);

    // 后跳起飞后保留远离目标的动量, 不再被下一帧的距离控制清零
    if (!IsClientOnGround(client)) {
        // 空中只保留朝速度方向的前进姿态，不重复发送跳跃和蹲伏。
        setForwardBhopInput(buttons, false);
        cmdVel[0] = 0.0;
        cmdVel[1] = 0.0;

        // 如果 BhopType 是 BhopType_BaitRetreat, 且当前的 Charger 后跳速度分量有效, 那么说明在空中的这次连跳确实由后跳发起, 保持后跳
        if (g_AiChargers[client].m_BhopType == BhopType_BaitRetreat && currentAwaySpeed > 1.0) {
            alignChargerFacingWithMovement(client, currentVel, ang);
            return Plugin_Changed;
        }

        // 否则说明当前的速度不是由 BhopType_BaitRetreat 发起的, 可能是 Approach 的最后一跳在空中进入 BaitZone, 此时要急停, 清除输入和速度
        currentVel[0] = 0.0;
        currentVel[1] = 0.0;
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, currentVel);
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_flLastHopSpeed = 0.0;
        return Plugin_Changed;
    }

    if (g_AiChargers[client].m_BhopType == BhopType_BaitRetreat) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_flLastHopSpeed = 0.0;
    }

    // 只有目标正在看着 Charger 时才进行距离博弈, 否则目标不看着 Charger, 安全, 不需要进行近战博弈操作
    if (!isTargetWatchingCharger(client, target))
        return Plugin_Continue;

    static float meleeRange, baitZoneMin, baitZoneMax;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    baitZoneMin = meleeRange + g_cvMeleeBaitZoneMinRange.FloatValue;
    baitZoneMax = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue;

    static int moveSign;
    moveSign = BAIT_RETREAT_NONE;

    if (dist < baitZoneMin) {
        // 距离过近, 沿 awayDir 后退
        moveSign = BAIT_RETREAT_BACK;
    } else if (dist > baitZoneMax) {
        // 距离过远, 朝目标前进
        moveSign = BAIT_RETREAT_FORWARD;
    }

    if (moveSign == 0) {
        buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
        cmdVel[0] = 0.0;
        cmdVel[1] = 0.0;
        currentVel[0] = 0.0;
        currentVel[1] = 0.0;
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, currentVel);
        return Plugin_Changed;
    }

    static float baseSpeed, moveSpeed;
    baseSpeed = SDKCall(g_hSdkGetRunTopSpeed, client);
    moveSpeed = baseSpeed;

    static float desiredVel[3];
    desiredVel[0] = awayDir[0] * moveSpeed * float(moveSign);
    desiredVel[1] = awayDir[1] * moveSpeed * float(moveSign);
    desiredVel[2] = 0.0;

    if (!nextTickPosCheck(client, desiredVel, visible)) {
        // 无论前进还是后退, 方向不安全都不接管移动
        // handleMeleeThreat 已在这个函数之前执行, 此时保留其朝着目标右键打拳或者冲锋决策及原生 PathFollower 输入
        return Plugin_Continue;
    }

    buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
    cmdVel[0] = 0.0;
    cmdVel[1] = 0.0;
    desiredVel[2] = currentVel[2];
    alignChargerFacingWithMovement(client, desiredVel, ang);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, desiredVel);

    g_AiChargers[client].m_BhopType = BhopType_None;
    g_AiChargers[client].m_flLastHopSpeed = 0.0;
    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
    g_AiChargers[client].m_AirStrafe.init();
    return Plugin_Changed;
}

/**
* 是否应该退出博弈状态, 转换为 APPROACH State
* @param client 客户端索引
* @param target 目标索引
* @param dist 距离
* @param visible 是否可见
* @param threatType 目标威胁类型
* @return bool
**/
bool shouldExitBaitState(int client, int target, float dist, bool visible, TargetThreatType threatType) {
    if (!isAiCharger(client) || !IsValidSurvivor(target) || !IsPlayerAlive(target))
        return true;

    // 向后跳在空中时, 禁止因视野或距离变化中途退出 Bait
    if (!IsClientOnGround(client) &&
        g_AiChargers[client].m_BhopType == BhopType_BaitRetreat
    ) {
        return false;
    }

    static float minDist;
    minDist = g_cvBhopMinDist.FloatValue + STATE_TOLERANCE_DIST;
    
    // 连续失去目标视野超过宽限期才转换为 APPROACH STATE
    if (!visible &&
        GetGameTime() - g_AiChargers[client].m_flLastVisibleTime >= BAIT_LOST_SIGHT_GRACE
    ) {
        stateLog.debugAll("Charger (%N) lost the sight of target (%N) for %.2f seconds, transition to APPROACH STATE",
            client, target, BAIT_LOST_SIGHT_GRACE);
        return true;
    }
    // 目标非手持近战, 且到目标距离大于 g_cvBhopMinDist.FloatValue + 容差距离, 转换为 APPROACH STATE
    if (threatType != Threat_Melee && dist > minDist) {
        stateLog.debugAll("Charger (%N), target (%N), distance %.2f > min dist %.2f, transition to APPROACH STATE", client, target, dist, minDist);
        return true;
    }
    // 目标手持近战, 且到目标距离大于 meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue, 转换为 APPROACH STATE
    static float meleeRange;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    minDist = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue + STATE_TOLERANCE_DIST;
    if (threatType == Threat_Melee && dist > minDist) {
        stateLog.debugAll("Charger (%N), target (%N) holding melee, dist %.2f > baitZoneMax %.2f, transition to APPROACH STATE", client, target, dist, minDist);
        return true;
    }
    return false;
}

/**
* Charger 面对手持近战目标时的处理逻辑
* 1. 若目标没有看着 Charger, 且没有其他人看着 Charger, 处在博弈区内, 概率冲锋
* 2. 目标处于易受攻击状态, 直接冲锋
* 3. 目标不处于易受攻击状态, Charger 血量大于近战斩杀线时, 概率冲锋
* @param client 客户端索引
* @param target 目标索引
* @param dist 距离
* @param visible 是否可见目标
* @param isWatching 目标是否正在看着 Charger
* @param watchers 正在看着 Charger 的人数
* @return void
**/
Action handleMeleeThreat(int client, int target, float dist, bool visible, bool isWatching, int watchers, int& buttons, float ang[3]) {
    static int health;
    health = GetEntProp(client, Prop_Data, "m_iHealth");

    static float meleeRange, baitZoneMin, baitZoneMax;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    baitZoneMin = meleeRange + g_cvMeleeBaitZoneMinRange.FloatValue;
    baitZoneMax = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue;

    // 如果已经出了博弈区, 允许原生移动继续朝着目标接近
    if (dist > baitZoneMax)
        return Plugin_Continue;

    // 冲锋的收益高于后跳, 如果满足冲锋条件, 那么优先冲锋
    if (IsClientOnGround(client) &&
        shouldChargeInMeleeBait(client, target, health, visible, isWatching, watchers) &&
        isChargeAbilityReady(client)
    ) {
        stateLog.debugAll("Charger (%N) melee bait: charging holding melee target (%N), dist %.2f, transition to LOCKED STATE", client, target, dist);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
        return Plugin_Changed;
    }

    /*
    * 如果不满足冲锋条件, 那么目标接近时尝试后跳
    * 1. 目标主动进入 baitZoneMin 时, 且在 target -> Charger 方向的速度分量大于 MELEE_PRESS_MIN_SPEED 时, 表示目标正在主动接近 Charger, 应该后跳
    * 2. 目标距离 Charger 小于 (meleeRange + MELEE_EMERGENCY_BUFFER) 时, 情况紧急, 应该后跳, 否则会被砍
    */
    static float chargerPos[3], targetPos[3], targetVel[3], targetToCharger[3];
    GetClientAbsOrigin(client, chargerPos);
    GetClientAbsOrigin(target, targetPos);
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetVel);

    MakeVectorFromPoints(targetPos, chargerPos, targetToCharger);
    targetToCharger[2] = 0.0;
    NormalizeVector(targetToCharger, targetToCharger);
    targetVel[2] = 0.0;

    // 计算目标速度和 Charger -> target 方向的分量, 如果 targetApproachSpeed > 0 表示目标正在朝着 Charger 主动接近, 此时应该向后跳
    static float targetApproachSpeed;
    targetApproachSpeed = GetVectorDotProduct(targetVel, targetToCharger);

    /*
    * targetPressing: 目标主动进入 baitZoneMin 时, 且速度分量大于 MELEE_PRESS_MIN_SPEED 时, 应该后跳
    * emergencyClose: 目标距离 Charger 小于 (meleeRange + MELEE_EMERGENCY_BUFFER) 时, 情况紧急, 应该后跳, 否则会被砍
    */
    static bool targetPressing, emergencyClose;
    targetPressing = dist <= baitZoneMin && targetApproachSpeed >= MELEE_PRESS_MIN_SPEED;
    emergencyClose = dist <= meleeRange + MELEE_EMERGENCY_BUFFER;

    // 无法冲锋时, 目标主动进入 baitZoneMin 或已经过近才尝试后跳
    if (targetPressing || emergencyClose) {
        static Action backhopResult;
        backhopResult = performBackwardBhop(client, target, visible, buttons, ang);
        if (backhopResult != Plugin_Continue)
            return backhopResult;
    }

    return Plugin_Continue;
}

/**
* Charger 在面对手持近战的目标时, 且距离处于博弈区内 (baitZoneMin, baitZoneMax], 判断是否冲锋
* @param client 客户端索引
* @param target 目标索引
* @param dist 距离
* @param health Charger 生命值
* @param isWatching 目标是否正在看着 Charger
* @param watchers 正在看着 Charger 的人数
* @return bool
**/
bool shouldChargeInMeleeBait(int client, int target, int health, bool visible, bool isWatching, int watchers) {
    // 能力未就绪, 不允许冲锋
    if (!isChargeAbilityReady(client))
        return false;
    // 0. 无目标视野, 不允许冲锋
    if (!visible)
        return false;
    // 1. 目标手持近战, 但是没有看着自己, 且没有其他生还者看着自己, 概率冲锋
    if (!isWatching && watchers <= 0 && isChargerProbCharge(client))
        return true;
    // 2. 目标手持近战, 且处于易受攻击状态, 直接冲锋
    if (isTargetVulnerable(client, target))
        return true;
    // 3. 目标手持近战, 且不处于易受攻击状态, Charger 血量大于近战斩杀线时, 概率冲锋
    static int meleeDamageCharger;
    meleeDamageCharger = getLegacyMeleeDamage();
    if (health > meleeDamageCharger && isChargerProbCharge(client))
        return true;
    return false;
}

/**
* Charger 在面对手持近战目标时, 执行向后连跳操作
* @param client 客户端索引
* @param target 目标索引
* @param dist 距离
* @param visible 是否可见目标
* @return Action
**/
Action performBackwardBhop(int client, int target, bool visible, int& buttons, float ang[3]) {
    if (!IsClientOnGround(client) || !allowToBhop(client))
        return Plugin_Continue;

    /*
    * 使用目标到 Charger 的方向, 确保后跳严格远离目标, 不受当前 Charger 视角影响, 之前是使用 Charger 视角方向, 不够健壮
    */
    static float pos[3], targetPos[3], vBack[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    MakeVectorFromPoints(targetPos, pos, vBack);
    vBack[2] = 0.0;

    if (NormalizeVector(vBack, vBack) <= 0.0)
        return Plugin_Continue;

    // 获取 runTopSpeed 作为基础速度
    static float baseSpeed;
    baseSpeed = SDKCall(g_hSdkGetRunTopSpeed, client);

    // 计算目标速度在 charger 后退方向上的投影, dot > 0 表示目标在追 charger, dot < 0 表示目标远离 charger
    static float targetAbsVel[3], approachSpeed;
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetAbsVel);
    targetAbsVel[2] = 0.0;
    approachSpeed = GetVectorDotProduct(targetAbsVel, vBack);
    
    // 计算 charger 需要的后退速度
    static float backSpeed;
    // backSpeed = baseSpeed + g_cvBhopImpulse.FloatValue;
    backSpeed = baseSpeed;
    if (approachSpeed > 0.0) {
        backSpeed += approachSpeed * TARGET_PURSUIT_FACTOR;
    } else {
        // approachSpeed < 0, 目标远离 charger, 在 backSpeed 速度上叠加目标速度 (approachSpeed 是负数, 因此是减速), 减少距离
        // 控制减速大小, 0.5 表示在 backSpeed 基础上减速目标速度的 50%
        backSpeed += approachSpeed * TARGET_RETREAT_FACTOR;
    }

    // 限制最小后跳速度为 RunToSpeed, 最大后跳速度不超过设置的连跳速度上限
    if (backSpeed < baseSpeed) {
        backSpeed = baseSpeed;
    }
    if (backSpeed > g_cvBhopMaxSpeed.FloatValue) {
        backSpeed = g_cvBhopMaxSpeed.FloatValue;
    }

    // 应用缩放
    ScaleVector(vBack, backSpeed);

    // 连跳后退的落点不安全的时候, 则转为冲锋状态
    if (!nextTickPosCheck(client, vBack, visible)) {
        if (!isChargePathBlocked(client, target) && isChargeAbilityReady(client)) {
            stateLog.debugAll("Charger (%N) bait to holding melee target (%N), backward jump unsafe, transition to LOCKED STATE", client, target);
            g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
            return Plugin_Changed;
        }

        return Plugin_Continue;
    }

    stateLog.debugAll("Charger (%N) bait to holding melee target (%N), performing backward bunnyhop, speed %.2f", client, target, backSpeed);
    g_AiChargers[client].m_BhopType = BhopType_BaitRetreat;
    g_AiChargers[client].m_flLastHopSpeed = backSpeed;
    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
    g_AiChargers[client].m_AirStrafe.init();
    setForwardBhopInput(buttons, true);
    buttons &= ~(IN_ATTACK | IN_ATTACK2);
    alignChargerFacingWithMovement(client, vBack, ang);
    TeleportEntity(client, NULL_VECTOR, ang, vBack);
    g_AiChargers[client].m_flLastAirVecModifyTime = GetEngineTime();
    return Plugin_Changed;
}

/**
* Charger 面对手持霰弹枪的目标的处理逻辑
* 1. 若目标手持霰弹枪, Charger 到目标距离小于 bhopMinDist, 直接冲锋
* @param client 玩家索引
* @param target 目标索引
* @param dist 距离
* @param visible 是否可见目标
* @return Action
**/
Action handleShotgunThreat(int client, int target, float dist, bool visible) {
    // 能力未就绪, 不允许冲锋
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;
    // 无目标视野, 或者距离大于 bhopMinDist, 不允许冲锋
    if (!visible || dist > g_cvBhopMinDist.FloatValue)
        return Plugin_Continue;
    // 能力未就绪, 不允许冲锋
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;

    stateLog.debugAll("Charger (%N) handling shotgun threat, charging to target (%N), transition to LOCKED STATE", client, target);
    g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
    return Plugin_Continue;
}

/**
* Charger 面对手持非近战, 非霰弹枪的目标的处理逻辑
* 1. 目标没有看着 Charger, 且没有其他人看着 Charger, 继续接近挥拳, 同时概率冲锋
* 2. 目标处于易受攻击状态, 直接冲锋
* 3. 无论目标有没有看着 Charger, 若血量大于近战斩杀线, 概率冲锋, 小于则直接冲锋
* @param client 客户端索引
* @param target 目标索引
* @param dist 距离
* @param health Charger 生命值
* @param visible 是否可见目标
* @param meleeDamage Charger 近战斩杀线
* @param watchers 正在看着 Charger 的人数
* @return Action
**/
Action handleNonMeleeThreat(int client, int target, float dist, bool visible) {
    // 能力未准备就绪, 不允许冲锋
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;
    // 无目标视野, 或距离大于最小连跳允许距离, 不允许冲锋
    if (!visible || dist > g_cvBhopMinDist.FloatValue)
        return Plugin_Continue;
    // 能力未就绪, 不允许冲锋
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;

    // 如果目标处于易受攻击状态, 直接冲锋
    if (isTargetVulnerable(client, target)) {
        stateLog.debugAll("Charger (%N) handling non-melee threat: target (%N) vulnerable, charging", client, target);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
        return Plugin_Continue;
    }
    // 血量条件
    static int health, meleeDamageCharger;
    health = GetEntProp(client, Prop_Data, "m_iHealth");
    meleeDamageCharger = getLegacyMeleeDamage();
    if (health > meleeDamageCharger && isChargerProbCharge(client)) {
        stateLog.debugAll("Charger (%N) handling non-melee: health %d > melee damage charger %d, probabilistic charge to (%N)", client, health, meleeDamageCharger, target);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
    } else if (health <= meleeDamageCharger) {
        stateLog.debugAll("Charger (%N) handling non-melee: health %d <= melee damage charger %d, instant charge to (%N)", client, health, meleeDamageCharger, target);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
    }
    return Plugin_Continue;
}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateBait_OnExit(int client) {
    stateLog.debugAll("\n========== Charger (%N) State Bait On Exit ===========", client);
    if (g_AiChargers[client].m_BhopType == BhopType_BaitRetreat) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_flLastHopSpeed = 0.0;
    }
}
