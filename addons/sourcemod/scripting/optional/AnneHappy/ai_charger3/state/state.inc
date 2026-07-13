#if defined _state_included_
    #endinput
#endif
#define _state_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <logger2>

#define STATE_LOG_PREFIX "AI-ChargerState"

Logger
    stateLog;

ConVar
    g_cvStateLogLevel;

// =========================================================================
// State 状态模块初始化
// =========================================================================
stock void State_OnModuleStart(ConVar& cvPluginName) {
    if (!cvPluginName) {
        g_cvStateLogLevel = CreateConVar("_ai_charger3_state_log_level", "38", "状态模块的日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 数字相加", CVAR_FLAGS);
    } else {
        char cvName[64], stateLogCvName[64];
        cvPluginName.GetString(cvName, sizeof(cvName));
        FormatEx(stateLogCvName, sizeof(stateLogCvName), "_%s_state_log_level", cvName);
        g_cvStateLogLevel = CreateConVar(stateLogCvName, "38", "状态模块的日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 33=所有输出", CVAR_FLAGS);
    }

    stateLog = new Logger(STATE_LOG_PREFIX, g_cvStateLogLevel.IntValue);

    // 注册状态
    registerStates();
}

stock void State_OnModuleEnd() {
    delete stateLog;
}

#include "./state_approach.inc"
#include "./state_bait.inc"
#include "./state_locked.inc"
#include "./state_charging.inc"

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