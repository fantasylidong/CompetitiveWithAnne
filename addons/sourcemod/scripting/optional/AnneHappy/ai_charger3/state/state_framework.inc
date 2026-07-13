#if defined _state_framework_included_
    #endinput
#endif
#define _state_framework_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#include "../setup.inc"
#include "../stocks.inc"
#include "./state.inc"

// =========================================================================
// State [此状态的说明]
// 注册状态函数
// =========================================================================
stock void RegisterState_Framework() {
    
}

// ============================================================
// OnEnter 函数
// ============================================================
stock void StateFramework_OnEnter(int client) {
    stateLog.debugAll("\n========== State Framework On Enter ===========");
}

// ============================================================
// OnUpdate 函数
// ============================================================
stock Action StateFramework_OnUpdate(int client, int& buttons, float vel[3], float ang[3]) {

}

// ============================================================
// OnExit 函数
// ============================================================
stock void StateFramework_OnExit(int client) {
    stateLog.debugAll("\n========== State Framework On Exit ===========");
}