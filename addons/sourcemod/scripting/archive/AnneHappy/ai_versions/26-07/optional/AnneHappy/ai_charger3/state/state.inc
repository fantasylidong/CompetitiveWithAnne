#if defined _state_included_
    #endinput
#endif
#define _state_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../../../../include/logger2.inc"

#define STATE_LOG_PREFIX "AI-ChargerState"

Logger
    stateLog;



// =========================================================================
// State 状态模块初始化
// =========================================================================
stock void State_OnModuleStart() {
    
    stateLog = new Logger(STATE_LOG_PREFIX, (1));
    registerStates();
}

stock void State_OnModuleEnd() {
    delete stateLog;
}

#include "state_approach.inc"

#include "state_bait.inc"

#include "state_locked.inc"

#include "state_charging.inc"

// =========================================================================
// 按 enum 顺序注册状态到 g_ChargerStates 中
// =========================================================================
stock void registerStates() {
    // 注册 Approach State
    RegisterState_Approach();
    // 注册 Bait_State
    RegisterState_Bait();
    // 注册 Locked_State
    RegisterState_Locked();
    // 注册 Charging_State
    RegisterState_Charging();
}

