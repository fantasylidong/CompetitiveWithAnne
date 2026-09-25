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
#define MELEE_PRESS_MIN_SPEED   50.0      // 目标朝 Charger 移动速度超过该值时, 视为主动进入近战危险区
#define MELEE_EMERGENCY_BUFFER  20.0      // 目标距离 Charger 小于 (meleeRange + 这个值) 时, 视为非常危险, 无论目标速度如何都尝试后跳
#define BAIT_LOST_SIGHT_GRACE           3.0    // 连续丢失目标视野超过该时间才退出 Bait
#define BAIT_CLAW_HITS_BEFORE_CHARGE    2      // 持枪目标锤得到时, 先锤这么多次再冲锋
#define BAIT_CLAW_SWING_INTERVAL        0.85   // 单次爪击大约耗时, 用于判断能否连锤两下
#define BAIT_CLAW_GIVEUP_TIME           2.5    // 锤击尝试超时后改为冲锋, 避免被推打断后一直站着挥空

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
    resetBaitClawTracking(client);
    // 距离控制的方向锁是每次进入博弈重新开始的, 僵持计时则刻意不在这里重置
    resetBaitMoveControl(client);
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
        resetMeleeStalemate(client);
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
    visible = isSurvivorVisibleToCharger(client, target, targetEyePos);
    if (visible) {
        g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    }
    static bool isOnGround;
    isOnGround = IsClientOnGround(client);
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
    // 先阻止引擎自行冲锋; 持枪目标的锤/撞由后面的威胁处理决定, 不要默认按 IN_ATTACK2
    // ============================================================
    if (!isOnGround)
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
            resetMeleeStalemate(client);
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
        if (isOnGround) {
            // Charger 挥拳是 IN_ATTACK2, IN_ATTACK 是冲锋能力
            buttons |= IN_ATTACK2;
            buttons &= ~IN_ATTACK;
            return Plugin_Changed;
        }
        return Plugin_Continue;
    }

    // ============================================================
    // 根据威胁类型分别处理
    // ============================================================
    static Action resAction;
    if (threatType == Threat_Melee) {
        // 僵持计时跟着 "目标 + 连续近战博弈" 走, Bait <-> Approach 的来回抖动不会把它清零
        updateMeleeStalemate(client, target);

        // 只有近战博弈会使用 watcher 数据，避免枪械目标每 tick 扫描所有生还者。
        static bool isWatching;
        static int watchers;
        isWatching = isTargetWatchingCharger(client, target, g_cvTargetWatchMaxDeg.FloatValue);
        watchers = isAnySurvivorWatchingCharger(client, target, g_cvTargetWatchMaxDeg.FloatValue);

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
        resAction = handleNonMeleeThreat(client, target, dist, visible, buttons, ang);
    }

    if (resAction != Plugin_Continue)
        return resAction;

    return airLineCorrected ? Plugin_Changed : Plugin_Continue;
}

/**
* 当 Charger 距离目标距离小于 baitZoneMin 时, 若目标看着 Charger 那么 Charger 后退, 如果距离目标距离大于 baitZoneMax 那么前进继续接近目标
* 后跳时保留远离目标的水平动量; Approach 最后一跳带进博弈区时不急停, 这一跳按当前水平速度落地后再后跳
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

        // Approach 最后一跳带进博弈区: 玩家做不到空中把连跳速度瞬间清零, 保留水平动量让这一跳落地
        if (getVectorLength2D(currentVel) > 1.0)
            alignChargerFacingWithMovement(client, currentVel, ang);
        return Plugin_Changed;
    }

    if (g_AiChargers[client].m_BhopType == BhopType_BaitRetreat) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_flLastHopSpeed = 0.0;
        /*
        * 后跳刚落地, 锁一小段时间不允许距离控制立刻掉头前进
        * 否则 "后跳出去 -> 落地即前进 -> 又太近 -> 再后跳" 会在每一帧互相打架, 观感上就是原地抽搐
        */
        g_AiChargers[client].m_flBaitBackhopLockUntil = GetGameTime() + BAIT_BACKHOP_LOCK_TIME;
    }

    // 只有目标正在看着 Charger 时才进行距离博弈, 否则目标不看着 Charger, 安全, 不需要进行近战博弈操作
    if (!isTargetWatchingCharger(client, target)) {
        resetBaitMoveControl(client);
        return Plugin_Continue;
    }

    static float meleeRange, baitZoneMin, baitZoneMax, baitZoneMid;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    baitZoneMin = meleeRange + g_cvMeleeBaitZoneMinRange.FloatValue;
    baitZoneMax = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue;
    baitZoneMid = (baitZoneMin + baitZoneMax) * 0.5;

    static int moveSign;
    moveSign = updateBaitMoveSign(client, dist, baitZoneMin, baitZoneMax, baitZoneMid);

    static bool orbiting;
    orbiting = g_cvMeleeBaitOrbit != null && g_cvMeleeBaitOrbit.BoolValue;

    /*
    * 死区内且没开绕圈: 不再每帧把水平速度硬清零 (那是 "按一下马上停止" 的直接来源),
    * 改成逐帧衰减, 观感上是滑停而不是卡停
    */
    if (moveSign == BAIT_RETREAT_NONE && !orbiting) {
        buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
        cmdVel[0] = 0.0;
        cmdVel[1] = 0.0;
        currentVel[0] *= BAIT_MOVE_DEADZONE_DAMP;
        currentVel[1] *= BAIT_MOVE_DEADZONE_DAMP;
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, currentVel);
        return Plugin_Changed;
    }

    static float baseSpeed, radialSpeed, distError;
    baseSpeed = SDKCall(g_hSdkGetRunTopSpeed, client);

    /*
    * 比例速度: 以带中心为目标, 距离误差越小走得越慢, 误差达到 BAIT_MOVE_SPEED_RAMP 才用满速
    * 原来无论误差 1 单位还是 30 单位都是满速, 才会出现 "全速蹦一下 -> 立刻归零" 的抽搐
    */
    radialSpeed = 0.0;
    if (moveSign != BAIT_RETREAT_NONE) {
        distError = moveSign == BAIT_RETREAT_BACK ? (baitZoneMid - dist) : (dist - baitZoneMid);
        radialSpeed = baseSpeed * getBaitMoveSpeedRatio(distError);
    }

    static float desiredVel[3];
    buildBaitMoveVelocity(client, awayDir, moveSign, radialSpeed, baseSpeed, orbiting, desiredVel);

    if (!nextTickPosCheck(client, desiredVel, visible)) {
        // 绕圈方向被挡住时先换个方向再试一次, 换向本身有冷却, 不会贴着墙每帧左右横跳
        if (orbiting && flipBaitOrbitDir(client))
            buildBaitMoveVelocity(client, awayDir, moveSign, radialSpeed, baseSpeed, orbiting, desiredVel);

        if (!nextTickPosCheck(client, desiredVel, visible)) {
            resetBaitMoveControl(client);

            /*
            * 本来就是要站住的 (只是想顺便绕两步), 那就老老实实站住并衰减速度
            * 这里如果把控制权交回原生寻路, PathFollower 会直接把 Charger 往目标身上送, 然后触发紧急后跳, 反而更抖
            */
            if (moveSign == BAIT_RETREAT_NONE) {
                buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
                cmdVel[0] = 0.0;
                cmdVel[1] = 0.0;
                currentVel[0] *= BAIT_MOVE_DEADZONE_DAMP;
                currentVel[1] *= BAIT_MOVE_DEADZONE_DAMP;
                TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, currentVel);
                return Plugin_Changed;
            }

            // 确实需要移动但方向不安全, 不接管移动
            // handleMeleeThreat 已在这个函数之前执行, 此时保留其朝着目标右键打拳或者冲锋决策及原生 PathFollower 输入
            return Plugin_Continue;
        }
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
* 计算这一帧的距离控制方向, 带迟滞和最短驻留
* 迟滞: 一旦开始移动就一直走到博弈带中心才松手, 而不是刚进带边缘就撒手, 方向翻转需要跨越半个带宽
* 最短驻留: 同一方向至少维持 BAIT_MOVE_HOLD_TIME, 从根上堵死方向每帧翻转
* @param client Charger 客户端索引
* @param dist 到目标的距离
* @param zoneMin 博弈带内边界
* @param zoneMax 博弈带外边界
* @param zoneMid 博弈带中心
* @return int, BAIT_RETREAT_BACK / BAIT_RETREAT_FORWARD / BAIT_RETREAT_NONE
**/
int updateBaitMoveSign(int client, float dist, float zoneMin, float zoneMax, float zoneMid) {
    static float now;
    now = GetGameTime();

    static int sign;
    sign = g_AiChargers[client].m_iBaitMoveSign;

    if (sign != BAIT_RETREAT_NONE && now < g_AiChargers[client].m_flBaitMoveHoldUntil) {
        // 驻留期内保持方向不变
    } else if (sign == BAIT_RETREAT_BACK) {
        sign = dist >= zoneMid ? BAIT_RETREAT_NONE : BAIT_RETREAT_BACK;
    } else if (sign == BAIT_RETREAT_FORWARD) {
        sign = dist <= zoneMid ? BAIT_RETREAT_NONE : BAIT_RETREAT_FORWARD;
    } else if (dist < zoneMin) {
        sign = BAIT_RETREAT_BACK;
    } else if (dist > zoneMax) {
        sign = BAIT_RETREAT_FORWARD;
    } else {
        sign = BAIT_RETREAT_NONE;
    }

    // 后跳刚落地的锁定期内不允许掉头前进, 但仍然允许继续后退
    if (sign == BAIT_RETREAT_FORWARD && now < g_AiChargers[client].m_flBaitBackhopLockUntil)
        sign = BAIT_RETREAT_NONE;

    if (sign != g_AiChargers[client].m_iBaitMoveSign) {
        g_AiChargers[client].m_iBaitMoveSign = sign;
        g_AiChargers[client].m_flBaitMoveHoldUntil = sign != BAIT_RETREAT_NONE ? now + BAIT_MOVE_HOLD_TIME : 0.0;
    }

    return sign;
}

/**
* 距离误差到速度比例的映射, 结果限制在 [BAIT_MOVE_MIN_SPEED_RATIO, 1.0]
**/
float getBaitMoveSpeedRatio(float distError) {
    if (distError < 0.0)
        distError = 0.0;

    static float ratio;
    ratio = distError / BAIT_MOVE_SPEED_RAMP;
    if (ratio < BAIT_MOVE_MIN_SPEED_RATIO)
        ratio = BAIT_MOVE_MIN_SPEED_RATIO;
    if (ratio > 1.0)
        ratio = 1.0;

    return ratio;
}

/**
* 组合出这一帧的博弈移动速度 = 径向分量 (进/退) + 切向分量 (绕圈)
* 切向分量让 Charger 在保持半径的同时绕着目标转, 把 "原地抽搐" 变成 "绕着你转圈找机会"
**/
void buildBaitMoveVelocity(int client, const float awayDir[3], int moveSign, float radialSpeed, float baseSpeed, bool orbiting, float outVel[3]) {
    outVel[0] = awayDir[0] * radialSpeed * float(moveSign);
    outVel[1] = awayDir[1] * radialSpeed * float(moveSign);
    outVel[2] = 0.0;

    if (!orbiting)
        return;

    if (g_AiChargers[client].m_iBaitOrbitDir == 0)
        g_AiChargers[client].m_iBaitOrbitDir = GetRandomInt(0, 1) == 0 ? -1 : 1;

    // 切向 = awayDir 绕 Z 轴旋转 90 度
    static float orbitSpeed;
    orbitSpeed = baseSpeed * BAIT_ORBIT_SPEED_RATIO * float(g_AiChargers[client].m_iBaitOrbitDir);
    outVel[0] += -awayDir[1] * orbitSpeed;
    outVel[1] += awayDir[0] * orbitSpeed;
}

/**
* 翻转绕圈方向 (绕圈方向被墙挡住时调用), 带冷却避免贴着墙每帧左右横跳
* @return bool, 是否真的翻转了
**/
bool flipBaitOrbitDir(int client) {
    if (GetGameTime() < g_AiChargers[client].m_flBaitOrbitFlipTime)
        return false;

    g_AiChargers[client].m_iBaitOrbitDir = g_AiChargers[client].m_iBaitOrbitDir == 0
        ? (GetRandomInt(0, 1) == 0 ? -1 : 1)
        : -g_AiChargers[client].m_iBaitOrbitDir;
    g_AiChargers[client].m_flBaitOrbitFlipTime = GetGameTime() + BAIT_ORBIT_FLIP_INTERVAL;
    return true;
}

/**
* 清掉距离控制的方向锁 (退出博弈 / 目标不再看着 Charger / 接管失败时调用)
**/
void resetBaitMoveControl(int client) {
    g_AiChargers[client].m_iBaitMoveSign = BAIT_RETREAT_NONE;
    g_AiChargers[client].m_flBaitMoveHoldUntil = 0.0;
}

/**
* 紧急后跳的距离阈值
* 原来直接用 meleeRange + MELEE_EMERGENCY_BUFFER (70 + 20 = 90), 比 baitZoneMin (70 + 15 = 85) 还远,
* 于是 Charger 站在自己博弈带的内半边时永远处在 "紧急" 状态, 每帧都想后跳, 死区根本没机会生效
* 这里把紧急线压到博弈带内侧, 保证 [紧急线, baitZoneMin] 之间有一段真正可以站住的空间
**/
float getMeleeEmergencyDist(float meleeRange, float baitZoneMinRange) {
    static float buffer;
    buffer = baitZoneMinRange * 0.5;
    if (buffer > MELEE_EMERGENCY_BUFFER)
        buffer = MELEE_EMERGENCY_BUFFER;

    return meleeRange + buffer;
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
        resetMeleeStalemate(client);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
        return Plugin_Changed;
    }

    /*
    * 僵持升级
    * Charger 血量低于近战斩杀线时 shouldChargeInMeleeBait 的血量分支恒假, 只剩 "玩家扭头" 一条路,
    * 如果不给一个出口, 就会在博弈带里无限对峙下去. 这里按 诱骗 -> 强冲 -> 换目标 的阶梯逐级升级
    */
    if (IsClientOnGround(client) && isMeleeStalemateTimedOut(client)) {
        static Action escalation;
        escalation = escalateMeleeStalemate(client, target, dist, meleeRange, buttons, ang);
        if (escalation != Plugin_Continue)
            return escalation;
    }

    /*
    * 如果不满足冲锋条件, 那么目标接近时尝试后跳
    * 1. 目标主动进入 baitZoneMin 时, 且在 target -> Charger 方向的速度分量大于 MELEE_PRESS_MIN_SPEED 时, 表示目标正在主动接近 Charger, 应该后跳
    * 2. 目标距离 Charger 小于紧急线 (getMeleeEmergencyDist) 时, 情况紧急, 应该后跳, 否则会被砍
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
    * emergencyClose: 目标距离 Charger 小于紧急线时, 情况紧急, 应该后跳, 否则会被砍
    */
    static bool targetPressing, emergencyClose;
    targetPressing = dist <= baitZoneMin && targetApproachSpeed >= MELEE_PRESS_MIN_SPEED;
    emergencyClose = dist <= getMeleeEmergencyDist(meleeRange, g_cvMeleeBaitZoneMinRange.FloatValue);

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
    /*
    * 3. 目标刚挥空一刀, 抓后摇冲锋
    * isTargetVulnerable 对所有武器统一用 "下次攻击时间 > 现在 + 0.5" 判断攻击间隔,
    * 而近战武器整个挥击周期本身才 0.6 ~ 0.9 秒, 留给 Charger 的窗口只剩 0.1 ~ 0.3 秒, 每帧碰运气基本抓不到,
    * 这里对近战目标单独用一个更短的阈值, 让残血 Charger 也有一个凭本事进场的机会
    */
    if (isMeleeTargetInSwingRecovery(target))
        return true;
    // 4. 目标手持近战, 且不处于易受攻击状态, Charger 血量大于近战斩杀线时, 概率冲锋
    static int meleeDamageCharger;
    meleeDamageCharger = getLegacyMeleeDamage();
    if (health > meleeDamageCharger && isChargerProbCharge(client))
        return true;
    return false;
}

// =========================================================================
// 近战僵持追踪与升级
// =========================================================================

/**
* 刷新近战僵持计时
* 关键点: 计时器绑定在 "目标 + 连续近战博弈" 上, 而不是 Bait 状态上
* Bait 状态的 startTime 每次 transitionTo 都会重置, 而后跳一次就会飞出退出线走一轮 Bait -> Approach -> Bait,
* 原来挂在 getStateDuration 上的兜底强冲因此几乎永远等不到, 僵局才会无限持续
* 只要两次近战博弈的间隔小于 MELEE_STALEMATE_KEEP_GAP, 这里的计时就继续累加
* @param client Charger 客户端索引
* @param target 目标索引
* @return void
**/
void updateMeleeStalemate(int client, int target) {
    static float now;
    static int targetUserId;
    now = GetGameTime();
    targetUserId = GetClientUserId(target);

    if (g_AiChargers[client].m_iStalemateTarget != targetUserId ||
        g_AiChargers[client].m_flStalemateStart <= 0.0 ||
        now - g_AiChargers[client].m_flLastMeleeBaitTime > MELEE_STALEMATE_KEEP_GAP
    ) {
        g_AiChargers[client].m_iStalemateTarget = targetUserId;
        g_AiChargers[client].m_flStalemateStart = now;
        g_AiChargers[client].m_iStalemateFeints = 0;
        g_AiChargers[client].m_flStalemateFeintUntil = 0.0;
        g_AiChargers[client].m_flStalemateFeintCooldown = 0.0;
    }

    g_AiChargers[client].m_flLastMeleeBaitTime = now;
}

/**
* 近战僵持是否已经超过允许的最长博弈时间
**/
bool isMeleeStalemateTimedOut(int client) {
    if (g_AiChargers[client].m_flStalemateStart <= 0.0)
        return false;

    return GetGameTime() - g_AiChargers[client].m_flStalemateStart > g_cvBaitMaxDuration.FloatValue;
}

/**
* 清空僵持追踪 (冲锋成功 / 换目标 / 目标失效时调用)
**/
void resetMeleeStalemate(int client) {
    g_AiChargers[client].m_iStalemateTarget = -1;
    g_AiChargers[client].m_flStalemateStart = 0.0;
    g_AiChargers[client].m_flLastMeleeBaitTime = 0.0;
    g_AiChargers[client].m_iStalemateFeints = 0;
    g_AiChargers[client].m_flStalemateFeintUntil = 0.0;
    g_AiChargers[client].m_flStalemateFeintCooldown = 0.0;
}

/**
* 目标是否刚挥空近战, 处在后摇里
* 通用的 isTargetVulnerable 用的是 0.5 秒阈值, 对近战武器来说太长, 这里单独用 MELEE_SWING_WINDOW
**/
bool isMeleeTargetInSwingRecovery(int target) {
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;

    static int weapon;
    weapon = GetEntPropEnt(target, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(weapon) || !HasEntProp(weapon, Prop_Send, "m_flNextPrimaryAttack"))
        return false;

    return GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack") > GetGameTime() + MELEE_SWING_WINDOW;
}

/**
* 僵持升级阶梯
* 1. 诱骗: 主动往里顶一下逼目标出刀, 挥空的后摇由 shouldChargeInMeleeBait 抓, 顶到紧急线就交回常规逻辑后跳拉开
* 2. 强冲: 诱骗次数用完还是没机会, 直接撞. 撞倒一个人再被砍死是划算的, 站在原地抖不划算
* 3. 换目标: 只有连撞都撞不过去 (高度不可达 / 冲锋路径被挡) 才考虑改打别人, 默认关闭
* @param client Charger 客户端索引
* @param target 目标索引
* @param dist 到目标的距离
* @param meleeRange 目标近战武器的攻击距离
* @return Action
**/
Action escalateMeleeStalemate(int client, int target, float dist, float meleeRange, int& buttons, float ang[3]) {
    /*
    * 技能还在 CD 只是 "现在还撞不了", 不是 "撞不过去"
    * 这时候正确的做法就是保持距离等技能: 既不该往里顶去白挨一刀 (顶进去也没东西可打), 也不该因为 CD 就把人换了
    */
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;

    if (g_AiChargers[client].m_iStalemateFeints < MELEE_STALEMATE_FEINT_LIMIT) {
        static Action feintResult;
        feintResult = performMeleeFeint(client, target, dist, meleeRange, buttons, ang);
        if (feintResult != Plugin_Continue)
            return feintResult;
    }

    if (isChargeTargetHeightReachable(client, target) && !isChargePathBlocked(client, target)) {
        stateLog.debugAll("Charger (%N) melee stalemate with target (%N) timed out, forcing charge, dist %.2f", client, target, dist);
        resetMeleeStalemate(client);
        g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
        return Plugin_Changed;
    }

    // 技能就绪却依然撞不过去 (高度不可达 / 冲锋路径被挡), 这才是真的无解, 考虑改打别人
    if (g_cvMeleeBaitStalemateSwitch != null && g_cvMeleeBaitStalemateSwitch.BoolValue) {
        static int newTarget;
        newTarget = findMeleeStalemateSwitchTarget(client, target);
        if (IsValidSurvivor(newTarget) && IsPlayerAlive(newTarget)) {
            stateLog.debugAll("Charger (%N) cannot break melee stalemate with (%N), switching target to (%N)", client, target, newTarget);
            blacklistBaitTarget(client, target);
            requestChargerTargetSwitch(client, newTarget);
            resetMeleeStalemate(client);
            resetBaitMoveControl(client);
            g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
            return Plugin_Changed;
        }
    }

    return Plugin_Continue;
}

/**
* 一次诱骗: 沿直线往目标顶, 顶到紧急线就结束这一次, 交回常规逻辑让 emergencyClose 的后跳把 Charger 拉出来
* 这样 "进一步退一步" 变成有节奏、有目的的假动作, 目标被逼出刀挥空后 shouldChargeInMeleeBait 会立刻抓后摇冲锋
* @return Action
**/
Action performMeleeFeint(int client, int target, float dist, float meleeRange, int& buttons, float ang[3]) {
    static float now, feintDoneDist;
    now = GetGameTime();
    feintDoneDist = getMeleeEmergencyDist(meleeRange, g_cvMeleeBaitZoneMinRange.FloatValue);

    // 诱骗窗口进行中
    if (g_AiChargers[client].m_flStalemateFeintUntil > 0.0) {
        if (dist <= feintDoneDist || now >= g_AiChargers[client].m_flStalemateFeintUntil) {
            g_AiChargers[client].m_iStalemateFeints++;
            g_AiChargers[client].m_flStalemateFeintUntil = 0.0;
            g_AiChargers[client].m_flStalemateFeintCooldown = now + MELEE_FEINT_COOLDOWN;
            stateLog.debugAll("Charger (%N) melee feint %d/%d on target (%N) finished at dist %.2f",
                client, g_AiChargers[client].m_iStalemateFeints, MELEE_STALEMATE_FEINT_LIMIT, target, dist);
            return Plugin_Continue;
        }

        return pressTowardMeleeTarget(client, target, buttons, ang);
    }

    if (now < g_AiChargers[client].m_flStalemateFeintCooldown)
        return Plugin_Continue;
    // 已经比紧急线还近, 这一帧该做的是被拉开而不是往里顶
    if (dist <= feintDoneDist)
        return Plugin_Continue;
    if (L4D_IsPlayerStaggering(client))
        return Plugin_Continue;

    g_AiChargers[client].m_flStalemateFeintUntil = now + MELEE_FEINT_WINDOW;
    resetBaitMoveControl(client);
    stateLog.debugAll("Charger (%N) melee stalemate: starting feint toward target (%N), dist %.2f", client, target, dist);
    return pressTowardMeleeTarget(client, target, buttons, ang);
}

/**
* 沿直线朝目标顶进, 落点不安全时不接管移动
**/
Action pressTowardMeleeTarget(int client, int target, int& buttons, float ang[3]) {
    if (!IsClientOnGround(client))
        return Plugin_Continue;

    static float pos[3], targetPos[3], dir[3], desiredVel[3], currentVel[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    MakeVectorFromPoints(pos, targetPos, dir);
    dir[2] = 0.0;
    if (NormalizeVector(dir, dir) <= 0.0)
        return Plugin_Continue;

    static float speed;
    speed = SDKCall(g_hSdkGetRunTopSpeed, client);
    desiredVel[0] = dir[0] * speed;
    desiredVel[1] = dir[1] * speed;
    desiredVel[2] = 0.0;

    if (!nextTickPosCheck(client, desiredVel, true))
        return Plugin_Continue;

    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", currentVel);
    desiredVel[2] = currentVel[2];

    buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
    buttons &= ~(IN_ATTACK | IN_ATTACK2);
    alignChargerFacingWithMovement(client, desiredVel, ang);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, desiredVel);

    g_AiChargers[client].m_BhopType = BhopType_None;
    g_AiChargers[client].m_flLastHopSpeed = 0.0;
    return Plugin_Changed;
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
    static float pos[3], targetPos[3], vBack[3], currentVel[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", currentVel);
    MakeVectorFromPoints(targetPos, pos, vBack);
    vBack[2] = 0.0;

    if (NormalizeVector(vBack, vBack) <= 0.0)
        return Plugin_Continue;

    /*
    * 后跳跟 Path / Direct 连跳同一套速度: 已有的远离分量留下, 朝目标飞来的速度在转身时丢掉,
    * 再加落地加速度. 不再按生还者追速 × 1.2 凭空加到 400+, 普通玩家做不出那种后跳
    */
    static float baseSpeed, awaySpeed, backSpeed;
    baseSpeed = SDKCall(g_hSdkGetRunTopSpeed, client);
    awaySpeed = GetVectorDotProduct(currentVel, vBack);
    if (awaySpeed < 0.0)
        awaySpeed = 0.0;

    backSpeed = awaySpeed;
    if (backSpeed < baseSpeed)
        backSpeed = baseSpeed;
    // 后跳相对当前速度通常是大角度掉头, 按起跳改向折算后加速度会很少甚至为 0
    backSpeed += getChargerHopImpulse(client, vBack);

    ScaleVector(vBack, backSpeed);
    limitGroundBhopVel(vBack);
    backSpeed = getVectorLength2D(vBack);

    // 连跳后退的落点不安全的时候, 则转为冲锋状态
    if (!nextTickPosCheck(client, vBack, visible)) {
        if (!isChargePathBlocked(client, target) && isChargeAbilityReady(client)) {
            stateLog.debugAll("Charger (%N) bait to holding melee target (%N), backward jump unsafe, transition to LOCKED STATE", client, target);
            g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
            return Plugin_Changed;
        }

        return Plugin_Continue;
    }

    stateLog.debugAll("Charger (%N) bait to holding melee target (%N), performing backward bunnyhop, speed %.2f, hop turn %.1f, impulse scale %.2f",
        client, target, backSpeed, g_AiChargers[client].m_flLastHopTurn, g_AiChargers[client].m_flLastHopImpulseScale);
    g_AiChargers[client].m_BhopType = BhopType_BaitRetreat;
    g_AiChargers[client].m_flLastHopSpeed = backSpeed;
    ZeroVector(g_AiChargers[client].m_vecAirCorrGoal);
    g_AiChargers[client].m_AirStrafe.init();
    setForwardBhopInput(buttons, true);
    buttons &= ~(IN_ATTACK | IN_ATTACK2);
    alignChargerFacingWithMovement(client, vBack, ang);
    TeleportEntity(client, NULL_VECTOR, ang, vBack);
    AIPathMovement_MarkHopStart(client);
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
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;
    if (!visible || dist > g_cvBhopMinDist.FloatValue)
        return Plugin_Continue;

    stateLog.debugAll("Charger (%N) handling shotgun threat, charging to target (%N), transition to LOCKED STATE", client, target);
    g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
    return Plugin_Changed;
}

/**
* Charger 面对手持非近战、非霰弹枪的目标:
* 进入 bhopMinDist 后不再概率等待。
* 正面被盯着、残血、或目标出现换弹/推 CD 窗口时直接冲;
* 否则爪击距离内、且下一锤之内目标还跑不掉, 先锤两下再撞。
**/
Action handleNonMeleeThreat(int client, int target, float dist, bool visible, int& buttons, float ang[3]) {
    if (!isChargeAbilityReady(client))
        return Plugin_Continue;
    if (!visible || dist > g_cvBhopMinDist.FloatValue)
        return Plugin_Continue;

    if (g_AiChargers[client].m_iBaitClawSwings >= BAIT_CLAW_HITS_BEFORE_CHARGE)
        return beginNonMeleeCharge(client, target, dist, "claw combo finished");

    if (g_AiChargers[client].m_flBaitClawStart > 0.0 &&
        GetGameTime() - g_AiChargers[client].m_flBaitClawStart >= BAIT_CLAW_GIVEUP_TIME
    ) {
        return beginNonMeleeCharge(client, target, dist, "claw combo timed out");
    }

    static bool inClawRange, midCombo, onGround, staggering;
    inClawRange = isChargerClawInRange(client, target);
    midCombo = g_AiChargers[client].m_iBaitClawSwings > 0;
    onGround = IsClientOnGround(client);
    staggering = L4D_IsPlayerStaggering(client);

    // 已经挥出第一锤则打完组合, 不被注视/残血门槛打断
    if (onGround && !staggering && midCombo && inClawRange)
        return performBaitClaw(client, target, buttons, ang);

    if (!midCombo) {
        if (isTargetWatchingCharger(client, target, g_cvTargetWatchMaxDeg.FloatValue))
            return beginNonMeleeCharge(client, target, dist, "target watching");

        if (GetEntProp(client, Prop_Data, "m_iHealth") <= getLegacyMeleeDamage())
            return beginNonMeleeCharge(client, target, dist, "low health");

        if (hasNonMeleeChargeWindow(target))
            return beginNonMeleeCharge(client, target, dist, "target window");
    }

    if (onGround && !staggering && canLandTwoChargerClaws(client, target, dist, getChargerClawRange()))
        return performBaitClaw(client, target, buttons, ang);

    if (staggering)
        return Plugin_Continue;

    return beginNonMeleeCharge(client, target, dist, "non-melee guaranteed range");
}

bool hasNonMeleeChargeWindow(int target) {
    static int weapon;
    weapon = GetEntPropEnt(target, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(weapon))
        return true;

    if (HasEntProp(weapon, Prop_Send, "m_bInReload") &&
        view_as<bool>(GetEntProp(weapon, Prop_Send, "m_bInReload")))
        return true;

    static float now;
    now = GetGameTime();
    if (GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack") > now + 0.5)
        return true;
    if (GetEntPropFloat(target, Prop_Send, "m_flNextShoveTime") > now + 0.5)
        return true;

    return false;
}

void resetBaitClawTracking(int client) {
    g_AiChargers[client].m_iBaitClawSwings = 0;
    g_AiChargers[client].m_flBaitClawStart = 0.0;

    static int claw;
    claw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (claw > 0 && IsValidEdict(claw) && HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack")) {
        g_AiChargers[client].m_flLastClawNextAttack = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
        g_AiChargers[client].m_bBaitClawBaselineValid = true;
    } else {
        g_AiChargers[client].m_flLastClawNextAttack = 0.0;
        g_AiChargers[client].m_bBaitClawBaselineValid = false;
    }
}

bool canLandTwoChargerClaws(int client, int target, float dist, float clawRange) {
    if (!IsClientOnGround(client) || L4D_IsPlayerStaggering(client))
        return false;

    static float pos[3], targetPos[3], targetVel[3], awayDir[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    if (GetVectorDistance(pos, targetPos) > clawRange)
        return false;

    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetVel);
    targetVel[2] = 0.0;

    MakeVectorFromPoints(pos, targetPos, awayDir);
    awayDir[2] = 0.0;
    if (NormalizeVector(awayDir, awayDir) <= 0.0)
        return true;

    static float fleeSpeed, predictedDist, waitTime;
    fleeSpeed = GetVectorDotProduct(targetVel, awayDir);
    if (fleeSpeed < 0.0)
        fleeSpeed = 0.0;

    // 第一锤立刻出手, 只预测打完剩余锤所需时间
    waitTime = BAIT_CLAW_SWING_INTERVAL * float(BAIT_CLAW_HITS_BEFORE_CHARGE - 1);
    if (waitTime < 0.0)
        waitTime = 0.0;
    predictedDist = dist + fleeSpeed * waitTime;
    return predictedDist <= clawRange;
}

void noteBaitClawSwing(int client) {
    static int claw;
    claw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (claw <= 0 || !IsValidEdict(claw) || !HasEntProp(claw, Prop_Send, "m_flNextPrimaryAttack")) {
        g_AiChargers[client].m_bBaitClawBaselineValid = false;
        return;
    }

    static float nextAttack, last;
    nextAttack = GetEntPropFloat(claw, Prop_Send, "m_flNextPrimaryAttack");
    last = g_AiChargers[client].m_flLastClawNextAttack;
    if (g_AiChargers[client].m_bBaitClawBaselineValid && nextAttack > last + 0.05) {
        g_AiChargers[client].m_iBaitClawSwings++;
        stateLog.debugAll("Charger (%N) bait claw swing %d/%d",
            client, g_AiChargers[client].m_iBaitClawSwings, BAIT_CLAW_HITS_BEFORE_CHARGE);
    }
    g_AiChargers[client].m_flLastClawNextAttack = nextAttack;
    g_AiChargers[client].m_bBaitClawBaselineValid = true;
}

Action performBaitClaw(int client, int target, int& buttons, float ang[3]) {
    if (g_AiChargers[client].m_flBaitClawStart <= 0.0)
        g_AiChargers[client].m_flBaitClawStart = GetGameTime();

    static float pos[3], targetPos[3], dir[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);
    MakeVectorFromPoints(pos, targetPos, dir);
    dir[2] = 0.0;
    if (NormalizeVector(dir, dir) > 0.0) {
        GetVectorAngles(dir, ang);
        TeleportEntity(client, NULL_VECTOR, ang, NULL_VECTOR);
    }

    buttons |= IN_ATTACK2;
    buttons &= ~IN_ATTACK;
    setChargerAbilityCooldown(client, 1.0);
    noteBaitClawSwing(client);
    return Plugin_Changed;
}

Action beginNonMeleeCharge(int client, int target, float dist, const char[] reason) {
    stateLog.debugAll("Charger (%N) %s, charging (%N) dist %.2f, transition to LOCKED STATE",
        client, reason, target, dist);
    g_ChargerStateContext[client].transitionTo(CH_STATE_LOCKED);
    return Plugin_Changed;
}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateBait_OnExit(int client) {
    stateLog.debugAll("\n========== Charger (%N) State Bait On Exit ===========", client);
    resetBaitMoveControl(client);
    if (g_AiChargers[client].m_BhopType == BhopType_BaitRetreat) {
        g_AiChargers[client].m_BhopType = BhopType_None;
        g_AiChargers[client].m_flLastHopSpeed = 0.0;
    }
}
