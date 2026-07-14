#if defined _state_charging_included_
    #endinput
#endif
#define _state_charging_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../setup.inc"
#include "../stocks.inc"
#include "./state.inc"

#define STATE_CHARGING_NAME                     "STATE_CHARGING"
#define PREDICT_MAX_LATERAL_OFFSET              45.0    // 冲锋位置横向预测最大值
#define PREDICT_MAX_TIME                        0.5     // charger 冲锋时预测目标位置的最大预测时间
#define CHARGE_DIST_TOLERANCE                   10.0    // 开始冲锋距离容差, 500 速度冲锋目标无法躲避距离大概是 36 左右, 有点小, 导致 charger 一直连跳无法冲锋, 增加一点容差

#define CHARGE_COMMIT_MIN_DIST                   36.0   // 按照 500 速度冲锋时, 允许冲锋的最小距离
#define CHARGE_COMMIT_MAX_DIST                   95.0   // 按照 500 速度冲锋时, 允许冲锋的最大距离
#define CHARGE_HIT_WIDTH                         16.0   // 冲锋命中宽度, 目标左右水平移动不超过这个范围可以被冲锋命中
#define CHARGE_SIDE_SPEED_MIN                    80.0   // 生还者横向移动速度假设的最小值 (由于计算 commitDist 时需要使用横向速度做除法, 防止除零异常, 设置一个最小值)
#define CHARGE_SPEED_EFFECTIVE_FACTOR            0.75   // 计算有效冲锋速度的因子 effective charge speed = max charge speed * factor
#define CHARGE_DIR_EPSILON                       50.0   // XY 距离小于该值时认为水平冲锋方向退化
#define CHARGE_COMMIT_GRACE_DIST                 10.0   // 最后一跳后落在 (commit range + 这个值) 的范围内时, 允许冲锋, 避免因为落在 commit range 外一点然后下一帧直接退回 Approach
#define CHARGE_FINAL_HOP_GRACE_TIME              0.50   // 最后一跳预计落地时间后的额外等待时间, 然后再判断 dist > commit range
#define CHARGING_LOST_SIGHT_GRACE                3.0    // 连续丢失目标视野超过该时间才退出 Charging

enum struct ChargeMotion {
    float m_flDist;                     // Charger 到目标的水平距离
    float m_vecForward[3];              // Charger -> target 的方向向量
    float m_vecSide[3];                 // 根据 vecForward 计算的水平侧向向量, 用于计算目标横向移动向量
    float m_vecTargetVel2D[3];          // 目标的水平速度, z 轴分量清零
    float m_flTargetSpeed;              // 目标水平速度大小
    float m_flForwardSpeed;             // 目标速度在冲锋方向上的投影分量, >0 表示目标正在远离 Charger, <0 表示正在靠近 Charger
    float m_flSideSpeed;                // 目标速度在横向方向上的投影分量, 有符号, 表示左右
    float m_flAbsSideSpeed;             // 横向速度绝对值, 只关心目标横向位移大小
    float m_flEffectiveChargeSpeed;     // 有效冲锋速度
    float m_flClosingSpeed;             // Charger 与目标沿冲锋方向的相对接近速度
    float m_flTimeToImpact;             // 按当前距离和接近速度估计的命中时间

    void init() {
        this.m_flDist = 0.0;
        ZeroVector(this.m_vecForward);
        ZeroVector(this.m_vecSide);
        ZeroVector(this.m_vecTargetVel2D);
        this.m_flTargetSpeed = 0.0;
        this.m_flForwardSpeed = 0.0;
        this.m_flSideSpeed = 0.0;
        this.m_flAbsSideSpeed = 0.0;
        this.m_flEffectiveChargeSpeed = 0.0;
        this.m_flClosingSpeed = 0.0;
        this.m_flTimeToImpact = 0.0;
    }
}

// =========================================================================
// State Charging 冲锋状态, Charger 以 500 速度冲锋目标无法躲避的距离大概在 36.0 左右
// 但是连跳到这个距离之内再冲撞是十分困难的, 大多时候都是在空中达到这个距离, 由于目标
// 持续的移动, Charger 落地时可能已经大于这个距离, 因此无法 100% 冲锋命中, 建议安装 air_ability patch
// 注册状态函数
// =========================================================================
stock void RegisterState_Charging() {
    ChargerState stateCharging;
    strcopy(stateCharging.name, sizeof(stateCharging.name), "State_Charging");
    stateCharging.OnEnter = StateCharging_OnEnter;
    stateCharging.OnUpdate = StateCharging_OnUpdate;
    stateCharging.OnExit = StateCharging_OnExit;
    g_ChargerStates.PushArray(stateCharging);
}

// ============================================================
// OnEnter 函数
// ============================================================
stock void StateCharging_OnEnter(int client) {
    g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    stateLog.debugAll("\n========== Charger (%N) State Charging On Enter ===========", client);
    // 确保每次进入冲锋决策逻辑时, 都有机会执行一次最后的连跳
    g_AiChargers[client].m_bBhopBeforeCharge = false;
    g_AiChargers[client].m_flFinalBhopStartTime = 0.0;
}

// ============================================================
// OnUpdate 函数
// ============================================================
stock Action StateCharging_OnUpdate(int client, int& buttons, float vel[3], float ang[3]) {
    if (!isAiCharger(client))
        return Plugin_Continue;
    
    static int target, betterTarget;
    target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
    betterTarget = GetClientOfUserId(g_AiChargers[client].m_iBetterTarget);
    // 检查更好的目标是否有效
    target = (IsValidSurvivor(betterTarget) && IsPlayerAlive(betterTarget)) ? betterTarget : target;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
        stateLog.debugAll("(%s) Charger (%N)'s target %d is invalid, transition to APPROACH STATE", STATE_CHARGING_NAME, client, target);
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    // 获取当前速度
    static float vVel[3], speed;
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVel);
    speed = getVectorLength2D(vVel);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
    // 是否在地上
    static bool isOnGround;
    isOnGround = IsClientOnGround(client);
    // 计算 charger 当前到目标的距离
    static float pos[3], eyePos[3], targetPos[3], targetEyePos[3], dist;
    L4D_GetEntityWorldSpaceCenter(client, pos);
    L4D_GetEntityWorldSpaceCenter(target, targetPos);
    GetClientEyePosition(client, eyePos);
    GetClientEyePosition(target, targetEyePos);
    dist = getVectorDistance2D(pos, targetPos);
    // 是否可视目标
    static bool visible;
    visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, TEAM_SURVIVOR, 0, targetEyePos);
    if (visible) {
        g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    }
    static bool recentlyVisible;
    recentlyVisible = visible || GetGameTime() - g_AiChargers[client].m_flLastVisibleTime < CHARGING_LOST_SIGHT_GRACE;
    // 目标威胁类型
    static TargetThreatType threatType;
    threatType = getTargetThreatType(client, target);
    // 是否正在冲锋
    static bool isCharging, isPinning;
    isCharging = isChargerCharging(client);
    isPinning = (IsValidSurvivor(L4D2_GetQueuedPummelVictim(client)) || IsValidSurvivor(L4D_GetVictimCharger(client)) || IsValidSurvivor(L4D_GetVictimCarry(client)));

    // ============================================================
    // 冲锋中或者正在控人, 不处理后续逻辑
    // ============================================================
    if (isCharging || isPinning)
        return Plugin_Continue;

    /*
    * Charging 空中阶段只负责空中速度修正, 不做状态退出和真正冲锋
    * 有些情况下 Charger 飞到目标背后会导致 visible=false, 但二者之间其实没有障碍
    * 如果此时先执行 shouldExitChargingState(), Charger 会过早切回 Approach
    * 然后重新走 Path/Direct 连跳, 可能朝错误的 goal 加速
    */
    if (!isOnGround) {
        /*
        * 是否允许进行空中速度方向修正
        * 有时候 Charger 飞到目标背后会导致 visible=false, 但二者之间其实没有障碍, 因此 visible 不是硬条件
        * 只要冲锋路径没有被阻挡就可以进行速度方向修正
        */
        static bool canPreserveAirLine;
        canPreserveAirLine = (
            visible ||
            !isChargePathBlocked(client, target)
        );

        if (canPreserveAirLine &&
            preserveAirChargeLine(client, target, true)
        ) {
            return Plugin_Changed;
        }

        return Plugin_Continue;
    }

    // ============================================================
    // 检查是否需要切换到其他状态
    // ============================================================
    if (shouldExitChargingState(client, target, dist, visible, threatType)) {
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    // 处理冲锋结束或控人结束时的能力未就绪的情况, 切换到其他状态
    if (!isChargeAbilityReady(client)) {
        handleAbilityNotReady(client, target, dist, threatType);
        return Plugin_Continue;
    }

    // ============================================================
    // 能力准备就绪, 发起冲锋
    // ============================================================

    // 获取目标当前速度
    static float chargeSpeed, targetAbsVel[3];
    chargeSpeed = !cvChargeSpeed ? DEFAULT_CHARGE_SPEED : cvChargeSpeed.FloatValue;
    GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetAbsVel);

    /*
    * 计算 Charging 状态下真正允许冲锋的距离阈值
    * 如果阈值无法计算返回 false, 推迟冲锋, 暂时不切回 Approach 状态, 避免状态抖动
    */
    static float commitDist;
    if (!getChargeCommitDist(pos, targetPos, targetAbsVel, chargeSpeed, commitDist)) {
        stateLog.debugAll("Charger (%N) failed to calculate reliable charge commit distance for target (%N), wait in CHARGING STATE", client, target);
        buttons &= ~IN_ATTACK;
        buttons &= ~IN_ATTACK2;
        setChargerAbilityCooldown(client, 1.0);
        return Plugin_Continue;
    }

    /*
    * 最后一跳已经发出后, 不要因为和 commit range 只差几个单位距离的预测误差立刻退回 Approach, 放弃这次冲锋
    * 这段逻辑只处理最后一跳后的短暂待决窗口:
    * 1. 已经接近 commit range, 直接冲锋
    * 2. 仍在最后一跳预计落地窗口内, 继续保持 Charging, 等待下一帧/落地后的距离更新
    * 3. 超过窗口仍然没有进入 commit range, 才退回 Approach 重新接近
    */
    static bool forceChargeNow;
    forceChargeNow = false;

    if (g_AiChargers[client].m_bBhopBeforeCharge) {
        static float now, finalHopWaitTime;
        now = GetGameTime();
        finalHopWaitTime = getJumpAirTime() + CHARGE_FINAL_HOP_GRACE_TIME;

        if (dist <= commitDist + CHARGE_COMMIT_GRACE_DIST) {
            // 最后一跳已经落在 commitDist + grace range 之内了, 可以直接冲锋
            g_AiChargers[client].m_bBhopBeforeCharge = false;
            g_AiChargers[client].m_flFinalBhopStartTime = 0.0;
            forceChargeNow = true;
        } else if (now - g_AiChargers[client].m_flFinalBhopStartTime <= finalHopWaitTime) {
            /*
            * 最后一跳刚发出的下一帧, 还没到落地结算查看 dist > commit dist 的时候, 应该继续保持 Charging 状态, 等待落地后查看是否进入 commit range
            * 在空中时禁止打拳和冲锋
            */
            buttons &= ~IN_ATTACK;
            buttons &= ~IN_ATTACK2;

            stateLog.debugAll("Charger (%N) waiting final bhop commit window, dist %.2f, commitDist %.2f, grace %.2f",
                client, dist, commitDist, CHARGE_COMMIT_GRACE_DIST);

            return Plugin_Changed;
        } else {
            // 最后一跳的 grace time 窗口已经结束, 但是仍然没有进入 (commit range + grace range), 说明最后一跳真的失败, 只能返回 Approach 重新接近目标
            stateLog.debugAll("Charger (%N) final bhop commit window expired, dist %.2f > commitDist %.2f, transition to APPROACH STATE",
                client, dist, commitDist
            );

            g_AiChargers[client].m_bBhopBeforeCharge = false;
            g_AiChargers[client].m_flFinalBhopStartTime = 0.0;
            g_AiChargers[client].m_iBetterTarget = 0;
            g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
            return Plugin_Continue;
        }
    }

    /*
    * 如果 Charger 已经进入 commit range, 那么可以直接冲锋 (dist < commit range + grace range) 时 forceChargeNow 为 true
    * 未进入 commit range 时, 只有当最后一跳可以进入 commit range 时才执行最后一跳
    * 如果最后一跳都无法进入 commit range, 说明当前不适合冲锋, 退回 Approach 重新接近目标
    */
    if (!forceChargeNow && dist > commitDist) {
        static Action finalBhopRes;
        // performFinalBhopBeforeCharge 成功返回 Plugin_Changed 然后立即结束这一帧的处理, 失败返回 Plugin_Continue
        finalBhopRes = performFinalBhopBeforeCharge(client, pos, targetPos, targetAbsVel, dist, commitDist, speed, recentlyVisible, buttons);
        if (finalBhopRes != Plugin_Continue)
            return finalBhopRes;

        stateLog.debugAll("Charger (%N) cannot enter charge commit range in one final bhop, dist %.2f > commitDist %.2f, transition to APPROACH STATE",
            client, dist, commitDist);
        
        g_AiChargers[client].m_iBetterTarget = 0;
        g_AiChargers[client].m_bBhopBeforeCharge = false;
        g_AiChargers[client].m_flFinalBhopStartTime = 0.0;
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    if (!isCharging && !isPinning) {
        static float aimPos[3];
        if (!calculateChargeAimPosition(pos, targetPos, targetAbsVel, chargeSpeed, aimPos))
            aimPos = targetPos;

        // 设置视角方向
        static float dir[3];
        MakeVectorFromPoints(pos, aimPos, dir);
        dir[2] = 0.0;

        // 设置立即冲锋
        setChargerAbilityCooldown(client, -1.0);
        GetVectorAngles(dir, dir);
        TeleportEntity(client, NULL_VECTOR, dir, NULL_VECTOR);

        // 发起冲锋
        buttons |= IN_ATTACK2;
        buttons |= IN_ATTACK;

        stateLog.debugAll("Charger (%N) initiated charge towards target (%N), dist %.2f, commitDist %.2f", client, target, dist, commitDist);

        return Plugin_Changed;
    }
    return Plugin_Continue;
}

bool shouldExitChargingState(int client, int target, float dist, bool visible, TargetThreatType threatType) {
    if (!isAiCharger(client) || !IsValidSurvivor(target) || !IsPlayerAlive(target))
        return true;
    if (IsClientIncapped(target) || IsClientHanging(target))
        return true;

    /*
    * Hunter 和其他 Charger 已经占有不可抢占的控制权, 此时不能抢夺目标
    * isSurvivorPinned 不包含 Smoker/Jockey, 所以这两种控制仍允许 Charger 抢夺
    */
    if (isSurvivorPinned(target)) {
        stateLog.debugAll("Charger (%N), target (%N) is controlled by Hunter/Charger, transition to APPROACH STATE", client, target);
        return true;
    }

    static float pos[3], targetPos[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);

    // 冲锋路径上面存在障碍物和高度差过大的 Gap 属于独立的硬退出理由, 不受距离、视野或最后一跳宽限窗口影响
    if (isChargePathBlocked(client, target)) {
        stateLog.debugAll("Charger (%N), charge path to target (%N) is blocked, transition to APPROACH STATE", client, target);
        return true;
    }

    /*
    * 沿实际地面逐段采样。连续上坡/下坡即使累计高度差超过 JUMP_HEIGHT 也不会退出
    * 只有相邻地面不连续、两个采样点之间高度差大于 JUMP_HEIGHT 说明存在 Gap 才退出
    */
    if (hasPotentialGap2(client, pos, targetPos, JUMP_HEIGHT)) {
        stateLog.debugAll("Charger (%N), route to target (%N) has a gap, transition to APPROACH STATE", client, target);
        return true;
    }

    /*
    * 最后一跳待决期间只忽略软退出条件, 上面的目标状态、阻挡和 Gap 仍然立即生效
    */
    static bool finalHopPending;
    finalHopPending = (
        g_AiChargers[client].m_bBhopBeforeCharge &&
        g_AiChargers[client].m_flFinalBhopStartTime > 0.0 &&
        GetGameTime() - g_AiChargers[client].m_flFinalBhopStartTime <= getJumpAirTime() + CHARGE_FINAL_HOP_GRACE_TIME
    );

    if (finalHopPending)
        return false;

    static float minDist;
    minDist = g_cvBhopMinDist.FloatValue + STATE_TOLERANCE_DIST;

    // 连续丢失目标视野超过宽限期才转换为 APPROACH STATE
    if (!visible && GetGameTime() - g_AiChargers[client].m_flLastVisibleTime >= CHARGING_LOST_SIGHT_GRACE) {
        stateLog.debugAll("Charger (%N) lost sight of target (%N) for %.1f seconds, transition to APPROACH STATE", client, target, CHARGING_LOST_SIGHT_GRACE);
        return true;
    }
    // 目标非手持近战, 且到目标距离大于 g_cvBhopMinDist.FloatValue + 容差距离, 转换为 APPROACH STATE
    if (
        threatType != Threat_Melee &&
        dist > minDist
    ) {
        stateLog.debugAll("Charger (%N), target (%N), distance %.2f > min dist %.2f, transition to APPROACH STATE", client, target, dist, minDist);
        return true;
    }
    // 目标手持近战, 且到目标距离大于 meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue, 转换为 APPROACH STATE
    static float meleeRange;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    minDist = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue + STATE_TOLERANCE_DIST;
    if (
        threatType == Threat_Melee &&
        dist > minDist
    ) {
        stateLog.debugAll("Charger (%N), target (%N) holding melee, dist %.2f > baitZoneMax %.2f, transition to APPROACH STATE", client, target, dist, minDist);
        return true;
    }
    return false;
}

/**
* 处理冲锋后能力未就绪时的状态转换
* @param client 客户端索引
* @param target 目标索引
* @param dist 到目标距离
* @param threatType 目标威胁类型
* @return void
**/
void handleAbilityNotReady(int client, int target, float dist, TargetThreatType threatType) {
    static float meleeRange, baitZoneMax;
    meleeRange = !cvMeleeRange ? DEFAULT_MELEE_RANGE : cvMeleeRange.FloatValue;
    baitZoneMax = meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue;

    if (threatType == Threat_Melee) {
        if (dist <= baitZoneMax) {
            stateLog.debugAll("Charger (%N) ability not ready, melee threat (%N), dist %.2f < baitZoneMax %.2f, transition to BAIT STATE", client, target, dist, baitZoneMax);
            g_ChargerStateContext[client].transitionTo(CH_STATE_BAIT);
        } else if (dist > baitZoneMax + STATE_TOLERANCE_DIST) {
            stateLog.debugAll("Charger (%N) ability not ready, melee threat (%N), dist %.2f > baitZoneMax + tolerance, transition to APPROACH STATE", client, target, dist);
            g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        }
    } else {
        if (dist <= g_cvBhopMinDist.FloatValue) {
            stateLog.debugAll("Charger (%N) ability not ready, non melee threat (%N), dist %.2f < bhopMinDist, transition to BAIT STATE", client, target, dist);
            g_ChargerStateContext[client].transitionTo(CH_STATE_BAIT);
        } else if (dist > g_cvBhopMinDist.FloatValue + STATE_TOLERANCE_DIST) {
            stateLog.debugAll("Charger (%N) ability not ready, non melee threat (%N), dist %.2f > bhopMinDist + tolerance, transition to APPROACH STATE", client, target, dist);
            g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        }
    }
}

/**
* 构造目标运动学模型
* @param pos Charger 位置
* @param targetPos 目标位置
* @param targetVel 目标速度
* @param chargeSpeed 冲锋速度
* @param motion 返回的冲锋运动学模型
* @return 运动学模型构建成功返回 true
    1. 当前 Charger 和 target 距离过近, 小于 CHARGE_DIR_EPSILON, 表示冲锋方向退化, 直接判断高度差满足允许冲锋
    2. 目标水平速度已经超过了当前最大冲锋速度, 并且目标正在横向移动或者逃逸, 说明这次冲锋大概率无法命中, 返回 false, 模型构建失败
    3. Charger 冲锋时接近目标的相对速度太小, 小于 120.0, 大概率无法命中, 返回 false, 模型构建失败
* @error 
**/
stock bool buildChargeMotion(const float pos[3], const float targetPos[3], const float targetVel[3], float chargeSpeed, ChargeMotion motion) {
    motion.init();

    /*
    * 计算 Charger -> target 冲锋的水平方向
    * 如果方向向量长度小于 CHARGE_DIR_EPSILON, 不代表不能冲锋, 而是代表 Charger 和 target 过于近了, 说明 forward 方向退化
    * 但是如果满足高度差范围的话, 还是能够直接冲锋的
    */
    MakeVectorFromPoints(pos, targetPos, motion.m_vecForward);
    motion.m_vecForward[2] = 0.0;

    motion.m_flDist = NormalizeVector(motion.m_vecForward, motion.m_vecForward);
    if (motion.m_flDist <= CHARGE_DIR_EPSILON)
        return false;

    // 计算沿着冲锋方向的侧向方向向量
    GetVectorCrossProduct(motion.m_vecForward, {0.0, 0.0, 1.0}, motion.m_vecSide);
    NormalizeVector(motion.m_vecSide, motion.m_vecSide);

    // 提取目标的水平速度
    motion.m_vecTargetVel2D[0] = targetVel[0];
    motion.m_vecTargetVel2D[1] = targetVel[1];
    motion.m_vecTargetVel2D[2] = 0.0;

    motion.m_flTargetSpeed = getVectorLength2D(motion.m_vecTargetVel2D);

    // 目标水平速度已经超过当前最大冲锋速度时, 认为这次冲锋大概率无法命中, 不允许冲锋
    if (motion.m_flTargetSpeed > chargeSpeed)
        return false;

    /*
    * 分解目标当前速度
    * m_flForwardSpeed 表示目标沿着冲锋方向的速度分量, >0 说明目标远离 Charger, <0 说明目标靠近 Charger
    * m_flSideSpeed 表示目标沿着冲锋方向的侧向速度分量, >0 说明目标向右移动, <0 说明目标向左移动
    * m_flAbsSideSpeed 表示目标横向速度绝对值大小, 用于 getCommitDist, 因为 getCommitDist 只需要计算目标多久能够离开命中宽度
    */
    motion.m_flForwardSpeed = GetVectorDotProduct(motion.m_vecTargetVel2D, motion.m_vecForward);
    motion.m_flSideSpeed = GetVectorDotProduct(motion.m_vecTargetVel2D, motion.m_vecSide);
    motion.m_flAbsSideSpeed = FloatAbs(motion.m_flSideSpeed);

    /*
    * 计算有效冲锋速度和接近速度
    * 考虑到 Charger 冲锋的启动时间, 不是直接从 runTopSpeed 直接到 max charge speed 的, 但是不知道启动时间是多少
    * 因此保守估计 max charge speed, 宁愿慢一些, 也不要过早冲锋
    */
    motion.m_flEffectiveChargeSpeed = chargeSpeed * CHARGE_SPEED_EFFECTIVE_FACTOR;
    motion.m_flClosingSpeed = motion.m_flEffectiveChargeSpeed - motion.m_flForwardSpeed;

    if (motion.m_flClosingSpeed < 120.0)
        return false;

    // 估计冲锋命中时间
    motion.m_flTimeToImpact = motion.m_flDist / motion.m_flClosingSpeed;
    return true;
}

/**
* 动态计算 Charger 冲锋目标无法躲避冲锋的距离, 尤其是考虑了目标横向位移, 如果目标横向位移大, 那么允许冲锋距离 commit dist 就要小一点, 否则可以大一点
* @param pos Charger 位置
* @param targetPos 目标位置
* @param targetVel 目标速度
* @param chargeSpeed 冲锋速度
* @param commitDist 返回冲锋允许的最小距离
* @return bool, 返回 true 表示最小冲锋允许距离预测成功
* @error 
**/
stock bool getChargeCommitDist(const float pos[3], const float targetPos[3], const float targetVel[3], float chargeSpeed, float& commitDist) {
    commitDist = CHARGE_COMMIT_MIN_DIST;

    static ChargeMotion motion;
    if (!buildChargeMotion(pos, targetPos, targetVel, chargeSpeed, motion)) {
        /*
        * XY 基本重合时方向退化, 但高度可达就可以用最小 charge commit 距离来进行冲锋, 只要 charger 到达最小 charge commit 距离, 那么允许冲锋
        * 如果不是方向退化, buildChargeMotion 失败代表目标速度或接近速度不可靠, 不允许冲锋, 维持 Charging 状态等待一个合适的冲锋时机
        */
        if (motion.m_flDist <= CHARGE_DIR_EPSILON)
            return isChargeHeightReachable(pos, targetPos);

        return false;
    }

    static float sideSpeed;
    sideSpeed = motion.m_flAbsSideSpeed;

    /*
    * 即使目标当前纯直线后退, 也给横向逃逸一个最小估计值
    * 这是为了防止 commitDist 被除法放大到过远, 让 Charger 太早冲锋
    */
    if (sideSpeed < CHARGE_SIDE_SPEED_MIN)
        sideSpeed = CHARGE_SIDE_SPEED_MIN;

    /*
    * timeToHit = dist / closingSpeed
    * sideEscape = sideSpeed * timeToHit
    * 命中条件: sideEscape <= hitWidth
    * 推导: sideSpeed * (dist / closingSpeed) <= hitWidth
    * 所以: dist <= (hitWidth * closingSpeed) / sideSpeed
    */
    commitDist = (CHARGE_HIT_WIDTH * motion.m_flClosingSpeed) / sideSpeed;
    commitDist += CHARGE_DIST_TOLERANCE;

    if (commitDist < CHARGE_COMMIT_MIN_DIST) {
        commitDist = CHARGE_COMMIT_MIN_DIST;
    } else if (commitDist > CHARGE_COMMIT_MAX_DIST) {
        commitDist = CHARGE_COMMIT_MAX_DIST;
    }

    return true;
}

/**
* 计算 Charger 冲锋前瞄准的位置, 通过 build charge motion 中分解的目标速度, 预测目标在 timeToImpact 时间后的位置
* @param pos Charger 位置
* @param targetPos 目标位置
* @param targetVel 目标速度
* @param chargeSpeed 冲锋速度
* @param aimPos 瞄准位置
* @return bool, 返回 true 表示位置预测成功
* @error 
**/
stock bool calculateChargeAimPosition(const float pos[3], const float targetPos[3], const float targetVel[3], float chargeSpeed, float aimPos[3]) {
    // 运动学模型构建失败, 不进行冲锋位置预测
    static ChargeMotion motion;
    if (!buildChargeMotion(pos, targetPos, targetVel, chargeSpeed, motion))
        return false;

    // 如果冲锋时间太长, 那么就限制到最大预测 PREDICT_MAX_TIME
    static float predictTime;
    predictTime = motion.m_flTimeToImpact;
    if (predictTime > PREDICT_MAX_TIME)
        predictTime = PREDICT_MAX_TIME;

    static float offsetFwd, offsetSide;
    offsetFwd = motion.m_flForwardSpeed * predictTime;
    offsetSide = motion.m_flSideSpeed * predictTime;

    // 限制侧向偏移, 侧向偏移太多会导致 Charger 撞空
    if (offsetSide > PREDICT_MAX_LATERAL_OFFSET) {
        offsetSide = PREDICT_MAX_LATERAL_OFFSET;
    } else if (offsetSide < -PREDICT_MAX_LATERAL_OFFSET) {
        offsetSide = -PREDICT_MAX_LATERAL_OFFSET;
    }

    aimPos[0] = targetPos[0] + (motion.m_vecForward[0] * offsetFwd) + (motion.m_vecSide[0] * offsetSide);
    aimPos[1] = targetPos[1] + (motion.m_vecForward[1] * offsetFwd) + (motion.m_vecSide[1] * offsetSide);
    aimPos[2] = targetPos[2];

    return true;
}

stock Action performFinalBhopBeforeCharge(int client, const float pos[3], const float targetPos[3], const float targetVel[3],
    float dist, float commitDist, float speed, bool visible, int& buttons
) {
    if (!visible || !allowToBhop(client))
        return Plugin_Continue;

    // 距离已经到 commit dist 之内了, 直接冲锋
    if (dist <= commitDist)
        return Plugin_Continue;

    static float airTime;
    airTime = getJumpAirTime();
    if (airTime <= 0.0)
        return Plugin_Continue;

    static float targetVel2D[3];
    targetVel2D = targetVel;
    targetVel2D[2] = 0.0;
    
    static float predictPos[3];
    predictPos[0] = targetPos[0] + (targetVel2D[0] * airTime);
    predictPos[1] = targetPos[1] + (targetVel2D[1] * airTime);
    predictPos[2] = targetPos[2];

    static float dir[3], predictDist;
    MakeVectorFromPoints(pos, predictPos, dir);
    dir[2] = 0.0;

    predictDist = NormalizeVector(dir, dir);
    if (predictDist <= commitDist) {
        return Plugin_Continue;
    }

    static float desiredRemainDist;
    desiredRemainDist = commitDist * 0.60;

    // Charger 实际需要从当前位置一次连跳到 commitDist * 0.60 的距离
    static float travelDist;
    travelDist = predictDist - desiredRemainDist;

    if (travelDist <= 0.0)
        return Plugin_Continue;

    static float requiredSpeed;
    requiredSpeed = travelDist / airTime;
    if (requiredSpeed <= 0.0)
        return Plugin_Continue;

    // 计算最后一跳的连跳速度, 最小不能小于 runTopSpeed, 最大不能大于 g_cvBhopMaxSpeed.FloatValue
    static float baseSpeed, maxHopSpeed;
    baseSpeed = SDKCall(g_hSdkGetRunTopSpeed, client);
    maxHopSpeed = speed;

    if (maxHopSpeed < baseSpeed)
        maxHopSpeed = baseSpeed;

    maxHopSpeed += g_cvBhopImpulse.FloatValue;

    if (maxHopSpeed > g_cvBhopMaxSpeed.FloatValue)
        maxHopSpeed = g_cvBhopMaxSpeed.FloatValue;

    if (requiredSpeed > maxHopSpeed)
        return Plugin_Continue;

    // 缩放最后一跳的速度向量
    ScaleVector(dir, requiredSpeed);

    static float landPos[3];
    landPos[0] = pos[0] + (dir[0] * airTime);
    landPos[1] = pos[1] + (dir[1] * airTime);
    landPos[2] = pos[2];

    if (hasPotentialGap2(client, pos, landPos, JUMP_HEIGHT))
        return Plugin_Continue;

    if (!nextTickPosCheck(client, dir, visible))
        return Plugin_Continue;

    // 如果最后一跳的落点安全, 执行连跳
    buttons |= IN_DUCK;
    buttons |= IN_JUMP;

    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, dir);
    g_AiChargers[client].m_bBhopBeforeCharge = true;
    g_AiChargers[client].m_flFinalBhopStartTime = GetGameTime();
    g_AiChargers[client].m_flLastHopSpeed = getVectorLength2D(dir);

    stateLog.debugAll(
        "Charger (%N) performed final bunnyhop before charge, dist %.2f, commitDist %.2f, requiredSpeed %.2f, maxHopSpeed %.2f",
        client,
        dist,
        commitDist,
        getVectorLength2D(dir),
        maxHopSpeed
    );

    return Plugin_Changed;
}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateCharging_OnExit(int client) {
    stateLog.debugAll("\n========== Charger (%N) State Charging On Exit ===========", client);
    // 再次重置人为冲锋延迟标记
    g_AiChargers[client].m_bChargeDelayed = false;
    g_AiChargers[client].m_bBhopBeforeCharge = false;
    g_AiChargers[client].m_flFinalBhopStartTime = 0.0;
    g_AiChargers[client].m_iBetterTarget = 0;
}
