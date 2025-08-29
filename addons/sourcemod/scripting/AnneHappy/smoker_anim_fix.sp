#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <sdktools>

// ====================================================================================================
// >> DEFINES & PLUGIN INFO
// ====================================================================================================

#define GAMEDATA "l4d2_smoker_anim"

public Plugin myinfo = 
{
    name = "Smoker Animation Fix",
    author = "HoongDou",
    description = "Fixes AI Smoker tongue animation to match human players",
    version = "1.1",
    url = "https://github.com/HoongDou/L4D2-HoongDou-Project"
};

// ====================================================================================================
// >> Globals
// ====================================================================================================

// Handles
Handle hConf = null;       // Gamedata配置文件的句柄。
Handle sdkDoAnim = null;   // DoAnimationEvent SDKCall的句柄。
Handle hSequenceSet = null; // SelectWeightedSequence Detour的句柄。

//ConVars
ConVar g_cvEnabled; // 用于开关插件功能的控制台变量。

// State Tracking
// 追踪一个 Smoker 当前是否处于舌头攻击状态。
static bool g_bTongueAttacking[MAXPLAYERS + 1] = {false, ...};

// ====================================================================================================
// >> SIGNATURES
// ====================================================================================================

// SelectWeightedSequence
#define NAME_SelectWeightedSequence "CTerrorPlayer::SelectWeightedSequence"
#define SIG_SelectWeightedSequence_LINUX "@_ZN13CTerrorPlayer22SelectWeightedSequenceE8Activity"
#define SIG_SelectWeightedSequence_WINDOWS "\\x55\\x8B\\x2A\\x56\\x57\\x8B\\x2A\\x2A\\x8B\\x2A\\x81\\x2A\\x2A\\x2A\\x2A\\x2A\\x75\\x2A"

// DoAnimationEvent
#define NAME_DoAnimationEvent "CTerrorPlayer::DoAnimationEvent"
#define SIG_DoAnimationEvent_LINUX "@_ZN13CTerrorPlayer16DoAnimationEventE17PlayerAnimEvent_ti"
#define SIG_DoAnimationEvent_WINDOWS "\\x55\\x8B\\x2A\\x56\\x8B\\x2A\\x2A\\x57\\x8B\\x2A\\x83\\x2A\\x2A\\x74\\x2A\\x8B\\x2A\\x2A\\x2A\\x2A\\x2A\\x8B\\x2A"

// ====================================================================================================
// >> PLUGIN CORE
// ====================================================================================================

/**
 * @brief 当插件首次加载时调用，用于初始化所有内容。
 */
public void OnPluginStart()
{
    // Hook游戏事件以追踪 Smoker 的行为。
    HookEvent("ability_use", Event_AbilityUse);
    HookEvent("tongue_grab", Event_TongueGrab);
    HookEvent("tongue_release", Event_TongueRelease);
    
    // 创建控制台变量,是否启用该插件。
    g_cvEnabled = CreateConVar("smoker_anim_fix_enabled", "1", "Enable smoker animation fix", FCVAR_NONE, true, 0.0, true, 1.0);
    
    // 加载Gamedata，准备SDKCalls，并设置DHooks。
    GetGamedata();
    PrepSDKCall();
    LoadOffset();
    
    AutoExecConfig(true, "l4d2_smoker_anim_fix");
}

/**
 * @brief 当插件即将卸载时调用，用于清理 Hooks。
 */
public void OnPluginEnd()
{
    if (hSequenceSet != null)
    {
        DHookDisableDetour(hSequenceSet, false, OnSequenceSet_Pre);
        DHookDisableDetour(hSequenceSet, true, OnSequenceSet_Post);
    }
}

// ====================================================================================================
// >> EVENT HANDLERS
// ====================================================================================================

/**
 * @brief 当玩家使用技能时调用。用它来检测 Smoker 攻击的开始。
 *
 * @param event             Handle of the event.
 * @param name              Name of the event.
 * @param dontBroadcast     Whether the event is broadcast to clients.
 * @return                  Always continues to the next plugin.
 */
public Action Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnabled))
        return Plugin_Continue;
    
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (!IsValidClient(client) || !IsPlayerAlive(client))
        return Plugin_Continue;
    
    if (!IsFakeClient(client) || GetClientTeam(client) != 3)
        return Plugin_Continue;
    
    char ability[64];
    event.GetString("ability", ability, sizeof(ability));
    int context = event.GetInt("context");
    
    if (StrEqual(ability, "ability_tongue") && context == 1) // context 1 = ability start
    {
        char classname[64];
        GetClientModel(client, classname, sizeof(classname));
        if (StrContains(classname, "smoker", false) != -1 || GetEntProp(client, Prop_Send, "m_zombieClass") == 1)
        {
            g_bTongueAttacking[client] = true;
            
            // 强制游戏播放舌头攻击的动画事件。
            if (sdkDoAnim != null)
            {
                SDKCall(sdkDoAnim, client, 4, 1); // 4 = PLAYERANIMEVENT_ATTACK_PRIMARY
            }
            
            // 设置一个安全计时器，以防tongue_release事件未触发时重置标志。
            CreateTimer(2.0, Timer_ResetTongueFlag, client);
        }
    }
    
    return Plugin_Continue;
}

/**
 * @brief 当 Smoker 的舌头成功抓住生还者时(choke)调用。
 */
public Action Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnabled))
        return Plugin_Continue;
    
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (client > 0 && IsClientInGame(client) && IsFakeClient(client))
    {
        g_bTongueAttacking[client] = true;
    }
    
    return Plugin_Continue;
}

/**
 * @brief 当Smoker的舌头被释放或切断时调用。
 */
public Action Event_TongueRelease(Event event, const char[] name, bool dontBroadcast)
{
    if (!GetConVarBool(g_cvEnabled))
        return Plugin_Continue;
    
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (client > 0 && IsClientInGame(client))
    {
        g_bTongueAttacking[client] = false;
    }
    
    return Plugin_Continue;
}

// ====================================================================================================
// >> TIMERS
// ====================================================================================================

/**
 * @brief 一个用于重置客户端舌头攻击标志的计时器。
 *
 * @param timer             Handle of the timer.
 * @param client            The client index.
 * @return                  Stops the timer from repeating.
 */
public Action Timer_ResetTongueFlag(Handle timer, int client)
{
    if (IsValidClient(client))
    {
        g_bTongueAttacking[client] = false;
    }
    return Plugin_Stop;
}

// ====================================================================================================
// >> DHOOK CALLBACKS
// ====================================================================================================

/**
 * @brief Pre-hook for CTerrorPlayer::SelectWeightedSequence. 不做任何事，但DHooks要求必须有。
 */
public MRESReturn OnSequenceSet_Pre(int client, Handle hReturn, Handle hParams)
{
    return MRES_Ignored;
}

/**
 * @brief Post-hook for CTerrorPlayer::SelectWeightedSequence. 核心逻辑实现。
 *
 * @description If an AI Smoker is in the tongue attacking state, this function intercepts the
 *              animation chosen by the game and replaces it with the correct tongue attack sequence.
 *
 * @param client            The entity index (this pointer).
 * @param hReturn           Handle to the function's return value.
 * @param hParams           Handle to the function's parameters.
 * @return                  MRES_Override to change the sequence, or MRES_Ignored to do nothing.
 */
public MRESReturn OnSequenceSet_Post(int client, Handle hReturn, Handle hParams)
{
    if (!GetConVarBool(g_cvEnabled))
        return MRES_Ignored;
    
    if (!IsValidClient(client) || !IsPlayerAlive(client))
        return MRES_Ignored;
    
    if (!IsFakeClient(client) || GetClientTeam(client) != 3)
        return MRES_Ignored;
    
    if (GetEntProp(client, Prop_Send, "m_zombieClass") != 1)
        return MRES_Ignored;
    
    int sequence = DHookGetReturn(hReturn);
    
    // 如果Smoker应该处于攻击状态，则强制使用正确的动画序列。
    if (g_bTongueAttacking[client])
    {
        int tongueSequence = GetAnimation(client, "ACT_TERROR_SMOKER_SENDING_OUT_TONGUE");
        if (tongueSequence > -1 && sequence != tongueSequence)
        {
            DHookSetReturn(hReturn, tongueSequence);
            return MRES_Override;
        }
    }
    
    return MRES_Ignored;
}

// ====================================================================================================
// >> HELPER FUNCTIONS
// ====================================================================================================

/**
 * @brief 通过活动名称字符串获取动画序列的数字ID。
 *
 * @description This works by creating a temporary prop, setting its model to the target entity's
 *              model, using the "SetAnimation" input, and then reading the resulting sequence ID.
 *
 * @param entity            The entity whose model should be used.
 * @param sequence          The animation activity name (e.g., "ACT_IDLE").
 * @return                  The sequence ID, or -1 on failure.
 */
int GetAnimation(int entity, const char[] sequence)
{
    if (!IsValidEntity(entity))
        return -1;
    
    char model[PLATFORM_MAX_PATH];
    GetEntPropString(entity, Prop_Data, "m_ModelName", model, sizeof(model));
    
    int tempEnt = CreateEntityByName("prop_dynamic");
    if (!IsValidEntity(tempEnt))
        return -1;
    
    SetEntityModel(tempEnt, model);
    
    SetVariantString(sequence);
    AcceptEntityInput(tempEnt, "SetAnimation");
    int result = GetEntProp(tempEnt, Prop_Send, "m_nSequence");
    
    RemoveEntity(tempEnt);
    return result;
}

/**
 * @brief A 快速检查客户端索引是否有效且在游戏中。
 *
 * @param client            The client index to check.
 * @return                  True if valid, false otherwise.
 */
bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

// ====================================================================================================
// >> SETUP & INITIALIZATION
// ====================================================================================================

/**
 * @brief 为 CTerrorPlayer::DoAnimationEvent 准备 SDKCall。
 */
void PrepSDKCall()
{
    if (hConf == null)
        SetFailState("Error: Gamedata not loaded!");
    
    StartPrepSDKCall(SDKCall_Player);
    if (!PrepSDKCall_SetFromConf(hConf, SDKConf_Signature, NAME_DoAnimationEvent))
        SetFailState("Can't find %s signature in gamedata", NAME_DoAnimationEvent);
    
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // PlayerAnimEvent_t
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); // int
    sdkDoAnim = EndPrepSDKCall();
    
    if (sdkDoAnim == null)
        SetFailState("Can't initialize %s SDKCall", NAME_DoAnimationEvent);
}

/**
 * @brief 为 CTerrorPlayer::SelectWeightedSequence 创建并启用 DHooks detour。
 */
void LoadOffset()
{
    if (hConf == null)
        SetFailState("Error: Gamedata not found");
    
    hSequenceSet = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Int, ThisPointer_CBaseEntity);
    DHookSetFromConf(hSequenceSet, hConf, SDKConf_Signature, NAME_SelectWeightedSequence);
    DHookAddParam(hSequenceSet, HookParamType_Int); // Activity
    DHookEnableDetour(hSequenceSet, false, OnSequenceSet_Pre);
    DHookEnableDetour(hSequenceSet, true, OnSequenceSet_Post);
}

/**
 * @brief 加载gamedata文件。如果文件不存在，它会自动生成一个。
 */
void GetGamedata()
{
    char filePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filePath, sizeof(filePath), "gamedata/%s.txt", GAMEDATA);
    
    if (FileExists(filePath))
    {
        hConf = LoadGameConfigFile(GAMEDATA);
    }
    else
    {
        PrintToServer("[SM] %s gamedata file not found. Generating...", "Smoker Animation Fix");
        
        Handle fileHandle = OpenFile(filePath, "a+");
        if (fileHandle == null)
            SetFailState("[SM] Couldn't generate gamedata file!");
        
        WriteFileLine(fileHandle, "\"Games\"");
        WriteFileLine(fileHandle, "{");
        WriteFileLine(fileHandle, "    \"left4dead2\"");
        WriteFileLine(fileHandle, "    {");
        WriteFileLine(fileHandle, "        \"Signatures\"");
        WriteFileLine(fileHandle, "        {");
        WriteFileLine(fileHandle, "            \"%s\"", NAME_SelectWeightedSequence);
        WriteFileLine(fileHandle, "            {");
        WriteFileLine(fileHandle, "                \"library\"    \"server\"");
        WriteFileLine(fileHandle, "                \"linux\"      \"%s\"", SIG_SelectWeightedSequence_LINUX);
        WriteFileLine(fileHandle, "                \"windows\"    \"%s\"", SIG_SelectWeightedSequence_WINDOWS);
        WriteFileLine(fileHandle, "                \"mac\"        \"%s\"", SIG_SelectWeightedSequence_LINUX);
        WriteFileLine(fileHandle, "            }");
        WriteFileLine(fileHandle, "            \"%s\"", NAME_DoAnimationEvent);
        WriteFileLine(fileHandle, "            {");
        WriteFileLine(fileHandle, "                \"library\"    \"server\"");
        WriteFileLine(fileHandle, "                \"linux\"      \"%s\"", SIG_DoAnimationEvent_LINUX);
        WriteFileLine(fileHandle, "                \"windows\"    \"%s\"", SIG_DoAnimationEvent_WINDOWS);
        WriteFileLine(fileHandle, "                \"mac\"        \"%s\"", SIG_DoAnimationEvent_LINUX);
        WriteFileLine(fileHandle, "            }");
        WriteFileLine(fileHandle, "        }");
        WriteFileLine(fileHandle, "    }");
        WriteFileLine(fileHandle, "}");
        
        CloseHandle(fileHandle);
        hConf = LoadGameConfigFile(GAMEDATA);
        
        if (hConf == null)
            SetFailState("[SM] Failed to load auto-generated gamedata file!");
        
        PrintToServer("[SM] %s successfully generated gamedata file!", "Smoker Animation Fix");
    }
}
