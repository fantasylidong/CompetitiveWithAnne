#pragma semicolon 1
#pragma newdecls required

/**
 * Ai Charger 增强 2.0（合并修复版 - “永不站桩”）
 * -------------------------------------------------
 * 行为流程（每帧 RunCmd 决策）：
 *  0) 运行时跟踪
 *     - is_charging[]       ：从 m_isCharging 读出（1=冲锋中），用于捕捉开始/结束
 *     - charge_interval[]   ：记录“冲锋结束时刻” + 0.2s（避免恢复帧误差）
 *     - g_BlockUntil[]      ：最近一次调用 BlockCharge() 设置的“禁止冲锋直到何时”的节流时戳
 *
 *  1) 状态同步
 *     - 发现 m_isCharging 由 0→1：标记 is_charging=true
 *     - 发现 m_isCharging 由 1→0：将 charge_interval = GetGameTime() + 0.2
 *
 *  2) 距离内（closet_survivor_distance < ai_ChargerChargeDistance）且可见（m_hasVisibleThreats）：
 *     A. 目标“没看我”（角度偏差 > ai_ChargerAimOffset）且我血量 ≥ ai_ChargerMeleeDamage：
 *        - 轻节流 BlockCharge（仅一次），随后 TryRetargetAndAdvance()：
 *            * 若新目标满足“能冲”→立刻冲；否则→前压靠近（原生导航接管）
 *     B. 目标“看我”且没近战、非起身/倒地、我能冲且脚踩地：直接冲（仅 IN_ATTACK）
 *     C. 目标起身/倒地：TryRetargetAndAdvance（前压或换人冲）
 *     D. 目标被控：我血量足→BlockCharge + TryRetargetAndAdvance；否则→TryRetargetAndAdvance（不 BlockCharge）
 *
 *  3) 距离外：TryRetargetAndAdvance（不 BlockCharge）
 *
 *  4) 连跳（Bhop）：条件满足时轻推加速，避免长期与原生 AI 争夺移动控制
 *
 *  5) 梯子：禁止 IN_JUMP/IN_DUCK
 *
 *  6) 永不站桩关键：
 *     - 所有“没有合适冲锋对象”的路径都走 TryRetargetAndAdvance（能冲就冲，否则前压推进）
 *     - BlockCharge 做了节流，避免“每帧往后推冷却，永远冲不到”
 */

// ======================= Debug 开关 =======================
// 将 DEBUG 设为 1 可打开调试日志
#define DEBUG 0

stock void DBG(const char[] fmt, any ...)
{
    #if DEBUG
        static char msg[256];
        VFormat(msg, sizeof(msg), fmt, 2);
        PrintToServer("[AiChargerDBG] %s", msg);
    #endif
}
// ========================================================

// 头文件
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil>

// 原作者常量
#define CVAR_FLAG           FCVAR_NOTIFY
#define NAV_MESH_HEIGHT     20.0
#define FALL_DETECT_HEIGHT  120.0

// 保底枚举（你的头文件里若已定义，这里不会生效）
#if !defined TEAM_SURVIVOR
    #define TEAM_SURVIVOR 2
#endif
#if !defined ZC_CHARGER
    #define ZC_CHARGER 6
#endif
#if !defined SC_INVALID
    #define SC_INVALID (-1)
#endif

public Plugin myinfo = 
{
    name        = "Ai Charger 增强 2.0 版本（合并修复）",
    author      = "夜羽真白 / 修订: ChatGPT for morzlee",
    description = "Ai Charger 2.0 - 永不站桩、换人推进、轻节流冷却、防冲突输入",
    version     = "2.0.0.1 / 2025-09-08",
    url         = "https://steamcommunity.com/id/saku_ra/"
}

// ---------------- ConVars ----------------
ConVar g_hAllowBhop, g_hBhopSpeed, g_hChargeDist, g_hExtraTargetDist, g_hAimOffset, g_hChargerTarget, g_hAllowMeleeAvoid, g_hChargerMeleeDamage, g_hChargeInterval;

// ---------------- 运行时状态 ----------------
float charge_interval[MAXPLAYERS + 1] = {0.0};   // 记录“冲锋结束+0.2s”的时戳
float g_BlockUntil[MAXPLAYERS + 1]    = {0.0};   // BlockCharge 节流控制（防“每帧后推”）

float min_dist = 100.0;  // “额外目标范围”CVar 解析失败的兜底
float max_dist = 600.0;

bool is_charging[MAXPLAYERS + 1]       = {false};
bool can_attack_pinned[MAXPLAYERS + 1] = {false};

int survivor_num = 0;
int ranged_client[MAXPLAYERS + 1][MAXPLAYERS + 1];
int ranged_index[MAXPLAYERS + 1] = {0};
/*
// ---------------- 前置声明 ----------------
void extraTargetDistChangeHandler(ConVar convar, const char[] oldValue, const char[] newValue);
void getOtherRangedTarget();
int  FindRangedClients(int client, float min_range, float max_range);
void BlockCharge(int client);
void SetCharge(int client);
bool TR_EntityFilterEx(int entity, int mask, any data);
bool TR_RayFilter(int entity, int mask, any data);
bool TryRetargetAndAdvance(int client, int ability, int &buttons);
void CalcVel(const float self_pos[3], const float target_pos[3], float force, float out[3]);
*/
// ---------------- PluginStart ----------------
public void OnPluginStart()
{
    // CreateConVars（保持原注释/拼写）
    g_hAllowBhop          = CreateConVar("ai_ChargerBhop", "1", "是否开启 Charger 连跳", CVAR_FLAG, true, 0.0, true, 1.0);
    g_hBhopSpeed          = CreateConVar("ai_ChagrerBhopSpeed", "90.0", "Charger 连跳速度", CVAR_FLAG, true, 0.0);
    g_hChargeDist         = CreateConVar("ai_ChargerChargeDistance", "250.0", "Charger 只能在与目标小于这一距离时冲锋", CVAR_FLAG, true, 0.0);
    g_hExtraTargetDist    = CreateConVar("ai_ChargerExtraTargetDistance", "250,600", "Charger 会在这一范围内寻找其他有效的目标（中间用逗号隔开，不要有空格）", CVAR_FLAG);
    g_hAimOffset          = CreateConVar("ai_ChargerAimOffset", "15.0", "目标的瞄准水平与 Charger 处在这一范围内，Charger 不会冲锋", CVAR_FLAG, true, 0.0);
    g_hAllowMeleeAvoid    = CreateConVar("ai_ChargerMeleeAvoid", "1", "是否开启 Charger 近战回避", CVAR_FLAG, true, 0.0, true, 1.0);
    g_hChargerMeleeDamage = CreateConVar("ai_ChargerMeleeDamage", "350", "Charger 血量小于这个值，将不会直接冲锋拿着近战的生还者", CVAR_FLAG, true, 0.0);
    // 修：上限允许 3（原代码误写为 2，导致 case 3 永远进不去）
    g_hChargerTarget      = CreateConVar("ai_ChargerTarget", "3", "Charger目标选择：1=自然目标选择，2=优先取最近目标，3=优先撞人多处", CVAR_FLAG, true, 1.0, true, 3.0);

    g_hChargeInterval     = FindConVar("z_charge_interval");

    g_hExtraTargetDist.AddChangeHook(extraTargetDistChangeHandler);

    HookEvent("player_spawn", evt_PlayerSpawn);

    getOtherRangedTarget();
}

// CVar 变更：解析“额外目标范围”
void extraTargetDistChangeHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
    getOtherRangedTarget();
}

// 事件：牛生成时初始化状态
public void evt_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsCharger(client))
    {
        charge_interval[client] = 0.0 - g_hChargeInterval.FloatValue;
        g_BlockUntil[client] = 0.0;
        is_charging[client] = false;
        can_attack_pinned[client] = false;
        DBG("Spawn: chg %d charge_interval=%.2f", client, charge_interval[client]);
    }
}

// ---------------- 主循环：RunCmd 决策 ----------------
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (IsCharger(client) && IsPlayerAlive(client))
    {
        if (GetEntPropEnt(client, Prop_Send, "m_pummelVictim") > 0 || GetEntPropEnt(client, Prop_Send, "m_carryVictim") > 0)
            return Plugin_Continue;

        if (L4D_IsPlayerStaggering(client))
            return Plugin_Continue;

        bool has_sight = view_as<bool>(GetEntProp(client, Prop_Send, "m_hasVisibleThreats"));
        int target = GetClientAimTarget(client, true);
        int closet_survivor_distance = GetClosetSurvivorDistance(client);
        int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");

        float self_pos[3] = {0.0}, target_pos[3] = {0.0}, vec_speed[3] = {0.0}, vel_buffer[3] = {0.0};
        GetClientAbsOrigin(client, self_pos);
        GetEntPropVector(client, Prop_Data, "m_vecVelocity", vec_speed);
        float cur_speed = SquareRoot(Pow(vec_speed[0], 2.0) + Pow(vec_speed[1], 2.0));

        survivor_num = GetSurvivorCount(true, false);

        // --- 冲锋状态机同步（开始/结束） ---
        if (IsValidEntity(ability) && !is_charging[client] && GetEntProp(ability, Prop_Send, "m_isCharging") == 1)
        {
            is_charging[client] = true;
            DBG("StartCharge chg=%d", client);
        }
        else if (IsValidEntity(ability) && is_charging[client] && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
        {
            charge_interval[client] = GetGameTime() + 0.2; // 微延后
            is_charging[client] = false;
            DBG("EndCharge chg=%d charge_interval=%.2f", client, charge_interval[client]);
        }

        // 冲锋帧：清零三方向速度（保留原行为）
        if (buttons & IN_ATTACK)
            vel[0] = vel[1] = vel[2] = 0.0;

        // ====== 主决策 ======
        if (closet_survivor_distance < g_hChargeDist.IntValue)
        {
            if (has_sight && IsValidSurvivor(target) && !IsClientIncapped(target) && !IsClientPinned(target) && !IsInChargeDuration(client))
            {
                // A. 目标没看我 + 我血量足：轻节流 Block + 强制换人推进
                if (GetClientHealth(client) >= g_hChargerMeleeDamage.IntValue
                    && !Is_Target_Watching_Attacker(client, target, g_hAimOffset.IntValue))
                {
                    BlockCharge(client);
                    if (TryRetargetAndAdvance(client, ability, buttons))
                        return Plugin_Changed;
                }
                // B. 目标看我、可冲锋：直接冲
                else if (Is_Target_Watching_Attacker(client, target, g_hAimOffset.IntValue)
                         && !Client_MeleeCheck(target)
                         && !Is_InGetUp_Or_Incapped(target)
                         && GetEntProp(ability, Prop_Send, "m_isCharging") != 1
                         && IsGrounded(client))
                {
                    SetCharge(client);
                    buttons |= IN_ATTACK; // 仅冲锋
                    DBG("DirectCharge target=%d chg=%d", target, client);
                    return Plugin_Changed;
                }
                // C. 目标起身/倒地：推进（不 Block）
                else if (Is_InGetUp_Or_Incapped(target))
                {
                    if (TryRetargetAndAdvance(client, ability, buttons))
                        return Plugin_Changed;
                }
            }
            // 目标被控：血量足则 Block+推进，否则直接推进（不 Block）
            else if (has_sight && IsValidSurvivor(target) && IsClientPinned(target) && !IsInChargeDuration(client))
            {
                if (GetClientHealth(client) > g_hChargerMeleeDamage.IntValue)
                {
                    BlockCharge(client);
                    if (TryRetargetAndAdvance(client, ability, buttons))
                        return Plugin_Changed;
                }
                else
                {
                    if (TryRetargetAndAdvance(client, ability, buttons))
                        return Plugin_Changed;
                }
            }
        }
        else
        {
            // 距离外：不 Block，推进
            if (!IsInChargeDuration(client) && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
            {
                if (TryRetargetAndAdvance(client, ability, buttons))
                    return Plugin_Changed;
            }
        }

        // ====== 连跳（轻推） ======
        int bhopMinDist = can_attack_pinned[client] ? 60 : g_hChargeDist.IntValue;

        if (has_sight
            && g_hAllowBhop.BoolValue
            && float(closet_survivor_distance) > float(bhopMinDist)
            && float(closet_survivor_distance) < 10000.0
            && cur_speed > 175.0
            && IsValidSurvivor(target))
        {
            if (IsGrounded(client))
            {
                GetClientAbsOrigin(target, target_pos);
                CalcVel(self_pos, target_pos, g_hBhopSpeed.FloatValue, vel_buffer);

                buttons |= IN_JUMP;
                buttons |= IN_DUCK;

                if (Do_Bhop(client, buttons, vel_buffer))
                {
                    DBG("Bhop chg=%d", client);
                    return Plugin_Changed;
                }
            }
        }

        // 梯子：禁止连跳
        if (GetEntityMoveType(client) == MOVETYPE_LADDER)
        {
            buttons &= ~IN_JUMP;
            buttons &= ~IN_DUCK;
        }
    }
    return Plugin_Continue;
}

// ---------------- 目标选择（L4D2 Forward） ----------------
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
    int new_target = 0;
    if (IsCharger(specialInfected))
    {
        if (GetEntPropEnt(specialInfected, Prop_Send, "m_pummelVictim") > 0 || GetEntPropEnt(specialInfected, Prop_Send, "m_carryVictim") > 0)
            return Plugin_Continue;

        float self_pos[3] = {0.0}, target_pos[3] = {0.0};
        GetClientEyePosition(specialInfected, self_pos);

        // 刷新范围内可视目标池
        FindRangedClients(specialInfected, min_dist, max_dist);

        if (IsValidSurvivor(curTarget) && IsPlayerAlive(curTarget))
        {
            GetClientEyePosition(curTarget, target_pos);

            // 范围内有人被控且血量足 → 先去被控附近压迫（Block 一次）
            for (int i = 0; i < ranged_index[specialInfected]; i++)
            {
                if (GetClientHealth(specialInfected) > g_hChargerMeleeDamage.IntValue
                    && !IsInChargeDuration(specialInfected)
                    && (GetEntPropEnt(ranged_client[specialInfected][i], Prop_Send, "m_pounceAttacker") > 0
                        || GetEntPropEnt(ranged_client[specialInfected][i], Prop_Send, "m_tongueOwner") > 0
                        || GetEntPropEnt(ranged_client[specialInfected][i], Prop_Send, "m_jockeyAttacker") > 0))
                {
                    can_attack_pinned[specialInfected] = true;
                    curTarget = ranged_client[specialInfected][i];
                    BlockCharge(specialInfected);
                    DBG("ChooseVictim: attack pinned -> near %d", curTarget);
                    return Plugin_Changed;
                }
                can_attack_pinned[specialInfected] = false;
            }

            if (!IsClientIncapped(curTarget) && !IsClientPinned(curTarget))
            {
                // 近战回避：若当前目标近战，且距离≥冲锋距离、且血量足 → 切到非近战且可视的目标
                if (g_hAllowMeleeAvoid.BoolValue
                    && Client_MeleeCheck(curTarget)
                    && GetVectorDistance(self_pos, target_pos) >= g_hChargeDist.FloatValue
                    && GetClientHealth(specialInfected) >= g_hChargerMeleeDamage.IntValue)
                {
                    int melee_num = 0;
                    Get_MeleeNum(melee_num, new_target);
                    if (Client_MeleeCheck(curTarget) && melee_num < survivor_num && IsValidSurvivor(new_target) && Player_IsVisible_To(specialInfected, new_target))
                    {
                        curTarget = new_target;
                        DBG("ChooseVictim: melee avoid -> switch to %d", curTarget);
                        return Plugin_Changed;
                    }
                }
                // 不满足回避距离/血量，但目标近战：Block 一次（以靠近为主）
                else if (g_hAllowMeleeAvoid.BoolValue && Client_MeleeCheck(curTarget)
                         && !IsInChargeDuration(specialInfected)
                         && (GetVectorDistance(self_pos, target_pos) < g_hChargeDist.FloatValue || GetClientHealth(specialInfected) >= g_hChargerMeleeDamage.IntValue))
                {
                    BlockCharge(specialInfected);
                    DBG("ChooseVictim: melee avoid -> block charge");
                }

                // —— 目标选择策略（用 if/else，避免 break 语境错误） —— //
                int mode = g_hChargerTarget.IntValue;
                if (mode == 2)
                {
                    new_target = GetClosetMobileSurvivor(specialInfected);
                    if (IsValidSurvivor(new_target))
                    {
                        curTarget = new_target;
                        DBG("ChooseVictim: nearest -> %d", curTarget);
                        return Plugin_Changed;
                    }
                }
                else if (mode == 3)
                {
                    new_target = GetCrowdPlace(survivor_num);
                    if (IsValidSurvivor(new_target))
                    {
                        curTarget = new_target;
                        DBG("ChooseVictim: crowd -> %d", curTarget);
                        return Plugin_Changed;
                    }
                }
            }
        }
        else if (!IsValidSurvivor(curTarget))
        {
            new_target = GetClosetMobileSurvivor(specialInfected);
            if (IsValidSurvivor(new_target))
            {
                curTarget = new_target;
                DBG("ChooseVictim: fallback nearest -> %d", curTarget);
                return Plugin_Changed;
            }
        }
    }

    // 避免把“已倒地/被控的人”作为当前目标
    if (!can_attack_pinned[specialInfected] && IsCharger(specialInfected) && IsValidSurvivor(curTarget) && (IsClientIncapped(curTarget) || IsClientPinned(curTarget)))
    {
        int nt = GetClosetMobileSurvivor(specialInfected);
        if (IsValidSurvivor(nt))
        {
            curTarget = nt;
            DBG("ChooseVictim: avoid incapped/pinned -> %d", curTarget);
            return Plugin_Changed;
        }
    }
    return Plugin_Continue;
}

// ---------------- 工具函数：强制换目标 + 推进（核心：永不站桩） ----------------
bool TryRetargetAndAdvance(int client, int ability, int &buttons)
{
    FindRangedClients(client, min_dist, max_dist);

    int cand = -1;

    // 1) 优先“看我”的可动目标
    for (int i = 0; i < ranged_index[client]; i++)
    {
        int s = ranged_client[client][i];
        if (!IsClientPinned(s) && !Is_InGetUp_Or_Incapped(s) && Is_Target_Watching_Attacker(client, s, g_hAimOffset.IntValue))
        { cand = s; break; }
    }

    // 2) 否则最近的可动目标
    if (cand == -1)
    {
        float best = 1.0e9;
        float self[3]; GetClientAbsOrigin(client, self);
        for (int i = 0; i < ranged_index[client]; i++)
        {
            int s = ranged_client[client][i];
            if (!IsClientPinned(s) && !Is_InGetUp_Or_Incapped(s))
            {
                float pos[3]; GetClientAbsOrigin(s, pos);
                float d = GetVectorDistance(self, pos);
                if (d < best) { best = d; cand = s; }
            }
        }
    }

    // 3) 再退回“最近可动生还者”或“人多处”
    if (cand == -1) cand = GetClosetMobileSurvivor(client);
    if (!IsValidSurvivor(cand)) cand = GetCrowdPlace(survivor_num);
    if (!IsValidSurvivor(cand)) return false;

    // 4) 立刻面向该目标
    float self_pos[3], tgt_pos[3], ang[3];
    GetClientAbsOrigin(client, self_pos);
    GetClientAbsOrigin(cand,  tgt_pos);
    MakeVectorFromPoints(self_pos, tgt_pos, tgt_pos);
    GetVectorAngles(tgt_pos, ang);
    TeleportEntity(client, NULL_VECTOR, ang, NULL_VECTOR);

    // 5) 满足“能冲” → 立刻冲；否则 → 前压（不 Block）
    bool canChargeNow = (IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
                     && !IsInChargeDuration(client)
                     && IsGrounded(client)
                     && Is_Target_Watching_Attacker(client, cand, g_hAimOffset.IntValue)
                     && !Client_MeleeCheck(cand)
                     && !Is_InGetUp_Or_Incapped(cand);

    if (canChargeNow)
    {
        SetCharge(client);
        buttons &= ~IN_ATTACK2;
        buttons |= IN_ATTACK;
        DBG("Retarget->Charge chg=%d target=%d", client, cand);
    }
    else
    {
        buttons &= ~IN_ATTACK;
        buttons &= ~IN_ATTACK2;
        buttons |= IN_FORWARD; // 交给原生导航推进
        DBG("Retarget->Advance chg=%d target=%d", client, cand);
    }
    return true;
}

// ---------------- 近战数量统计 & 近战识别 ----------------
void Get_MeleeNum(int &melee_num, int &new_target)
{
    int active_weapon = -1;
    char weapon_name[48] = {'\0'};
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(client) && !IsClientIncapped(client) && !IsClientPinned(client))
        {
            active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
            if (IsValidEntity(active_weapon) && IsValidEdict(active_weapon))
            {
                GetEdictClassname(active_weapon, weapon_name, sizeof(weapon_name));
                if (StrContains(weapon_name, "melee", false) != -1 || StrEqual(weapon_name, "weapon_chainsaw"))
                    melee_num += 1;
                else
                    new_target = client;
            }
        }
    }
}

bool Client_MeleeCheck(int client)
{
    int active_weapon = -1;
    char weapon_name[48] = {'\0'};
    if (IsValidSurvivor(client) && IsPlayerAlive(client) && !IsClientIncapped(client) && !IsClientPinned(client))
    {
        active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
        if (IsValidEntity(active_weapon) && IsValidEdict(active_weapon))
        {
            GetEdictClassname(active_weapon, weapon_name, sizeof(weapon_name));
            if (StrContains(weapon_name, "melee", false) != -1 || StrEqual(weapon_name, "weapon_chainsaw"))
                return true;
        }
    }
    return false;
}

// ---------------- 人群中心（原作者引用方法） ----------------
// From：http://github.com/PaimonQwQ/L4D2-Plugins/smartspitter.sp
int GetCrowdPlace(int num_survivors)
{
    if (num_survivors > 0)
    {
        int index = 0, iTarget = 0;
        int[] iSurvivors = new int[MAXPLAYERS + 1];
        float fDistance[MAXPLAYERS + 1] = {-1.0};

        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsValidClient(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR))
                iSurvivors[index++] = client;
        }

        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsValidClient(client) && IsPlayerAlive(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR))
            {
                fDistance[client] = 0.0;
                float fClientPos[3] = {0.0};
                GetClientAbsOrigin(client, fClientPos);
                for (int i = 0; i < num_survivors; i++)
                {
                    float fPos[3] = {0.0};
                    GetClientAbsOrigin(iSurvivors[i], fPos);
                    fDistance[client] += GetVectorDistance(fClientPos, fPos, true);
                }
            }
        }

        for (int i = 0; i < num_survivors; i++)
        {
            if (fDistance[iSurvivors[iTarget]] > fDistance[iSurvivors[i]])
            {
                if (fDistance[iSurvivors[i]] != -1.0)
                    iTarget = i;
            }
        }
        return iSurvivors[iTarget];
    }
    return -1;
}

// ---------------- 判断/工具（保留原语义） ----------------
bool IsCharger(int client)
{
    return view_as<bool>(GetInfectedClass(client) == view_as<int>(ZC_CHARGER) && IsFakeClient(client));
}

// 起身/倒地识别（依赖 treeutil/left4dhooks 的动画表）
bool Is_InGetUp_Or_Incapped(int client)
{
    int character_index = IdentifySurvivor(client);
    if (character_index != view_as<int>(SC_INVALID))
    {
        int sequence = GetEntProp(client, Prop_Send, "m_nSequence");
        if (sequence == GetUpAnimations[character_index][ID_HUNTER] || sequence == GetUpAnimations[character_index][ID_CHARGER] || sequence == GetUpAnimations[character_index][ID_CHARGER_WALL] || sequence == GetUpAnimations[character_index][ID_CHARGER_GROUND])
            return true;
        else if (sequence == IncappAnimations[character_index][ID_SINGLE_PISTOL] || sequence == IncappAnimations[character_index][ID_DUAL_PISTOLS])
            return true;
        return false;
    }
    return false;
}

// 阻止牛冲锋（带节流，避免“每帧把 m_timestamp 往后推”）
void BlockCharge(int client)
{
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (!IsValidEntity(ability) || GetEntProp(ability, Prop_Send, "m_isCharging") == 1)
        return;

    float until = GetGameTime() + g_hChargeInterval.FloatValue;
    if (g_BlockUntil[client] + 0.01 < until)
    {
        g_BlockUntil[client] = until;
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", until);
        DBG("BlockCharge chg=%d until=%.2f", client, until);
    }
}

// 让牛冲锋（立即把时间戳拉回“可用”）
void SetCharge(int client)
{
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
    {
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", GetGameTime() - 0.5);
        DBG("SetCharge chg=%d", client);
    }
}

// 是否在冲锋间隔（基于“冲锋结束+0.2s”的记录）
bool IsInChargeDuration(int client)
{
    return view_as<bool>((GetGameTime() - (g_hChargeInterval.FloatValue + charge_interval[client])) < 0.0);
}

// 在 min..max 范围内、且可视的有效生还者集合（写入 ranged_client / ranged_index）
int FindRangedClients(int client, float min_range, float max_range)
{
    int index = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(i) && !IsClientIncapped(i))
        {
            float self_eye_pos[3] = {0.0}, target_eye_pos[3] = {0.0};
            GetClientEyePosition(client, self_eye_pos);
            GetClientEyePosition(i, target_eye_pos);
            float dist = GetVectorDistance(self_eye_pos, target_eye_pos);
            if (dist >= min_range && dist <= max_range)
            {
                Handle hTrace = TR_TraceRayFilterEx(self_eye_pos, target_eye_pos, MASK_VISIBLE, RayType_EndPoint, TR_RayFilter, client);
                if (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i)
                {
                    ranged_client[client][index] = i;
                    index += 1;
                }
                delete hTrace;
            }
        }
    }
    ranged_index[client] = index;
    return index;
}

// 轻量连跳：仅在有移动输入且速度低时注入
bool Do_Bhop(int client, int &buttons, float vec[3])
{
    if (buttons & IN_FORWARD || buttons & IN_BACK || buttons & IN_MOVELEFT || buttons & IN_MOVERIGHT)
    {
        float curvel[3] = {0.0};
        GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", curvel);
        if (GetVectorLength(curvel) <= 250.0)
        {
            AddVectors(curvel, vec, curvel);
            NormalizeVector(curvel, curvel);
            ScaleVector(curvel, 251.0);
            TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, curvel);
            return true;
        }
    }
    return false;
}

// 计算面向 target 的水平速度向量（输出到 out）
void CalcVel(const float self_pos[3], const float target_pos[3], float force, float out[3])
{
    out[0] = target_pos[0] - self_pos[0];
    out[1] = target_pos[1] - self_pos[1];
    out[2] = 0.0;
    NormalizeVector(out, out);
    ScaleVector(out, force);
}

// 碰撞/掉落检测（原逻辑保留，签名统一）
stock bool Dont_HitWall_Or_Fall(int client, float vel[3])
{
    bool  hullrayhit = false;
    int   down_hullray_hitent = -1;
    char  down_hullray_hitent_classname[16] = {'\0'};
    float selfpos[3] = {0.0}, resultpos[3] = {0.0}, mins[3] = {0.0}, maxs[3] = {0.0}, hullray_endpos[3] = {0.0}, down_hullray_startpos[3] = {0.0}, down_hullray_endpos[3] = {0.0}, down_hullray_hitpos[3] = {0.0};

    GetClientAbsOrigin(client, selfpos);
    AddVectors(selfpos, vel, resultpos);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);
    selfpos[2]  += NAV_MESH_HEIGHT;
    resultpos[2]+= NAV_MESH_HEIGHT;

    Handle hTrace = TR_TraceHullFilterEx(selfpos, resultpos, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilterEx, client);
    if (TR_DidHit(hTrace))
    {
        hullrayhit = true;
        TR_GetEndPosition(hullray_endpos, hTrace);
        if (GetVectorDistance(selfpos, hullray_endpos) <= NAV_MESH_HEIGHT)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;

    resultpos[2] -= NAV_MESH_HEIGHT;

    if (!hullrayhit)
    {
        down_hullray_startpos[0] = resultpos[0];
        down_hullray_startpos[1] = resultpos[1];
        down_hullray_startpos[2] = resultpos[2];
    }

    down_hullray_endpos[0] = down_hullray_startpos[0];
    down_hullray_endpos[1] = down_hullray_startpos[1];
    down_hullray_endpos[2] = down_hullray_startpos[2] - 100000.0;

    Handle hDownTrace = TR_TraceHullFilterEx(down_hullray_startpos, down_hullray_endpos, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilterEx, client);
    if (TR_DidHit(hDownTrace))
    {
        TR_GetEndPosition(down_hullray_hitpos, hDownTrace);
        if (FloatAbs(down_hullray_startpos[2] - down_hullray_hitpos[2]) > FALL_DETECT_HEIGHT)
        {
            delete hDownTrace;
            return false;
        }
        down_hullray_hitent = TR_GetEntityIndex(hDownTrace);
        GetEdictClassname(down_hullray_hitent, down_hullray_hitent_classname, sizeof(down_hullray_hitent_classname));
        if (strcmp(down_hullray_hitent_classname, "trigger_hurt") == 0)
        {
            delete hDownTrace;
            return false;
        }
        delete hDownTrace;
        return true;
    }
    delete hDownTrace;
    return false;
}

// Trace 过滤器（统一签名）
public bool TR_EntityFilterEx(int entity, int mask, any data)
{
    if (entity <= MaxClients)
        return false;

    char classname[32] = {'\0'};
    GetEdictClassname(entity, classname, sizeof(classname));
    if (strcmp(classname, "infected") == 0 || strcmp(classname, "witch") == 0 || strcmp(classname, "prop_physics") == 0 || strcmp(classname, "tank_rock") == 0)
        return false;

    return true;
}



// “是否目标在看我”（水平面角度偏差 <= offset）
bool Is_Target_Watching_Attacker(int client, int target, int offset)
{
    if (IsValidInfected(client) && IsValidSurvivor(target) && IsPlayerAlive(client) && IsPlayerAlive(target) && !IsClientIncapped(target) && !IsClientPinned(target) && !Is_InGetUp_Or_Incapped(target))
    {
        int aim_offset = RoundToNearest(Get_Player_Aim_Offset(target, client));
        return (aim_offset <= offset);
    }
    return false;
}

// 计算“目标视线”与“指向 Charger 的方向向量”的水平夹角
float Get_Player_Aim_Offset(int client, int target)
{
    if (IsValidClient(client) && IsValidClient(target) && IsPlayerAlive(client) && IsPlayerAlive(target))
    {
        float self_pos[3] = {0.0}, target_pos[3] = {0.0}, aim_vector[3] = {0.0}, dir_vector[3] = {0.0};
        float result_angle = 0.0;

        GetClientEyeAngles(client, aim_vector);
        aim_vector[0] = 0.0;
        aim_vector[2] = 0.0;
        GetAngleVectors(aim_vector, aim_vector, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(aim_vector, aim_vector);

        GetClientAbsOrigin(target, target_pos);
        GetClientAbsOrigin(client, self_pos);
        self_pos[2] = target_pos[2] = 0.0;

        MakeVectorFromPoints(self_pos, target_pos, dir_vector);
        NormalizeVector(dir_vector, dir_vector);

        result_angle = RadToDeg(ArcCosine(GetVectorDotProduct(aim_vector, dir_vector)));
        return result_angle;
    }
    return -1.0;
}

// 解析“额外目标范围”CVar，失败时使用兜底
void getOtherRangedTarget()
{
    static char cvar_dist[32], result_dist[2][16];
    g_hExtraTargetDist.GetString(cvar_dist, sizeof(cvar_dist));
    if (!IsNullString(cvar_dist) && ExplodeString(cvar_dist, ",", result_dist, 2, sizeof(result_dist[])) == 2)
    {
        min_dist = StringToFloat(result_dist[0]);
        max_dist = StringToFloat(result_dist[1]);
    }
    else
    {
        min_dist = 100.0;
        max_dist = 600.0;
    }
    DBG("ExtraTargetDist parsed: min=%.1f max=%.1f", min_dist, max_dist);
}
