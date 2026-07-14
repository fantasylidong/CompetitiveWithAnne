#if defined _state_locked_included_
    #endinput
#endif
#define _state_locked_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../setup.inc"
#include "../stocks.inc"
#include "./state.inc"

#define STATE_LOCKED_NAME "STATE_LOCKED"

// =========================================================================
// State Locked 锁定目标状态
// 作为转移到 CHARGING 状态的过渡状态, 似乎并没有什么用, 因为 CHARGING 状态还需要预测目标位置并冲锋
// 注册状态函数
// =========================================================================
stock void RegisterState_Locked() {
    ChargerState stateLocked;
    strcopy(stateLocked.name, sizeof(stateLocked.name), "State_Locked");
    stateLocked.OnEnter = StateLocked_OnEnter;
    stateLocked.OnUpdate = StateLocked_OnUpdate;
    stateLocked.OnExit = StateLocked_OnExit;
    g_ChargerStates.PushArray(stateLocked);
}

// ============================================================
// OnEnter 函数
// ============================================================
stock void StateLocked_OnEnter(int client) {
    g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    stateLog.debugAll("\n========== State Locked On Enter ===========");
}

// ============================================================
// OnUpdate 函数
// ============================================================
stock Action StateLocked_OnUpdate(int client, int& buttons, float vel[3], float ang[3]) {
    if (!isAiCharger(client))
        return Plugin_Continue;
    
    static int target, betterTarget;
    target = GetClientOfUserId(g_AiChargers[client].m_iTarget);
    betterTarget = GetClientOfUserId(g_AiChargers[client].m_iBetterTarget);
    // 检查更好的目标是否有效
    target = (IsValidSurvivor(betterTarget) && IsPlayerAlive(betterTarget)) ? betterTarget : target;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)) {
        stateLog.error("(%s) Charger (%N)'s target %d is invalid", STATE_LOCKED_NAME, client, target);
        return Plugin_Continue;
    }

    /*
    * 如果目标高度差过大无法冲锋, 那么就不要切换到 Charging 状态了
    * 并且清除 better target, 避免下一帧还使用这个旧的 better target
    */
    if (!isChargeTargetHeightReachable(client, target)) {
        stateLog.debugAll("Charger (%N) locked target (%N) is outside charge height %.2f, transition to APPROACH STATE",
            client, target, CHARGE_Z_THRESHOLD);
        
        g_AiChargers[client].m_iBetterTarget = 0;
        g_ChargerStateContext[client].transitionTo(CH_STATE_APPROACH);
        return Plugin_Continue;
    }

    /*
    * Locked 是 Bait -> Charging 转换的一帧过渡状态
    * 如果 Charger 此时还在空中, 在切入 Charging 前补一次空中速度修正
    * 避免上一次 Approach/Bait 的空中速度把 Charger 从目标侧面继续甩出去
    */
    static float targetEyePos[3];
    GetClientEyePosition(target, targetEyePos);

    static bool visible;
    visible = L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, TEAM_SURVIVOR, 0, targetEyePos);
    if (visible) {
        g_AiChargers[client].m_flLastVisibleTime = GetGameTime();
    }
    preserveAirChargeLine(client, target, visible, buttons, ang);

    // 转换为冲锋状态
    stateLog.debugAll("Charger (%N) locked target (%N), is better target %d, transition to CHARGING STATE",
        client, target, (IsValidSurvivor(betterTarget) && IsPlayerAlive(betterTarget)));
    g_ChargerStateContext[client].transitionTo(CH_STATE_CHARGING);
    return Plugin_Changed;
}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateLocked_OnExit(int client) {
    stateLog.debugAll("\n========== State Locked On Exit ===========");
}
