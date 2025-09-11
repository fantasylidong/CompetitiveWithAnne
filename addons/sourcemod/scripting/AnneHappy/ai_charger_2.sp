#pragma semicolon 1
#pragma newdecls required

// ===== Headers =====
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <treeutil>

// ===== Defines =====
#define CVAR_FLAG FCVAR_NOTIFY
#define NAV_MESH_HEIGHT 20.0
#define FALL_DETECT_HEIGHT 120.0

// NOTE: 保留原作者/链接信息
public Plugin myinfo =
{
    name        = "Ai Charger 增强 2.0 版本 (fixed)",
    author      = "夜羽真白, fixes by ChatGPT for morzlee",
    description = "Ai Charger 2.0 with bugfixes & behavior tweaks",
    version     = "2.0.0.1 / 2025-09-10",
    url         = "https://steamcommunity.com/id/saku_ra/"
}

// ===== ConVars =====
ConVar g_hAllowBhop;
ConVar g_hBhopSpeed;                 // 注意：保持原键名拼写 ai_ChagrerBhopSpeed 兼容旧配置
ConVar g_hChargeDist;
ConVar g_hExtraTargetDist;
ConVar g_hAimOffset;
ConVar g_hChargerTarget;
ConVar g_hAllowMeleeAvoid;
ConVar g_hChargerMeleeDamage;
ConVar g_hChargeInterval;            // z_charge_interval

// ===== State =====
float charge_interval[MAXPLAYERS + 1] = {0.0};
bool  can_attack_pinned[MAXPLAYERS + 1] = {false};
bool  is_charging[MAXPLAYERS + 1] = {false};
int   survivor_num = 0;
int   ranged_client[MAXPLAYERS + 1][MAXPLAYERS + 1];
int   ranged_index[MAXPLAYERS + 1] = {0};

// extra target search window
float min_dist = 0.0;
float max_dist = 350.0;

// ===== Forward Decls =====
void   getOtherRangedTarget();
void   CalculateVel(const float self_pos[3], const float target_pos[3], float force, float out[3]);
bool   TR_EntityFilter(int entity, int mask, any data);
void   CopyVector(const float src[3], float dest[3]);
bool   WillChargePathClear(int client, const float dirAngles[3], float ahead);
bool   IsMeleeClass(const char[] cls);

// ===== Plugin Start =====
public void OnPluginStart()
{
    g_hAllowBhop         = CreateConVar("ai_ChargerBhop", "1", "是否开启 Charger 连跳", CVAR_FLAG, true, 0.0, true, 1.0);
    // 注意：保持键名 ai_ChagrerBhopSpeed 以兼容旧服配置（原拼写有误）
    g_hBhopSpeed         = CreateConVar("ai_ChagrerBhopSpeed", "90.0", "Charger 连跳速度/推进力度", CVAR_FLAG, true, 0.0);
    g_hChargeDist        = CreateConVar("ai_ChargerChargeDistance", "260.0", "Charger 只能在与目标小于这一距离时冲锋", CVAR_FLAG, true, 0.0);
    g_hExtraTargetDist   = CreateConVar("ai_ChargerExtraTargetDistance", "0,420", "Charger 会在这一范围内寻找其他有效的目标/背身冲锋窗口（逗号分隔，无空格）", CVAR_FLAG);
    g_hAimOffset         = CreateConVar("ai_ChargerAimOffset", "30.0", "目标的瞄准水平与 Charger 处在这一范围内，视为“看着你”", CVAR_FLAG, true, 0.0);
    g_hAllowMeleeAvoid   = CreateConVar("ai_ChargerMeleeAvoid", "1", "是否开启 Charger 近战回避", CVAR_FLAG, true, 0.0, true, 1.0);
    g_hChargerMeleeDamage= CreateConVar("ai_ChargerMeleeDamage", "351", "Charger 血量小于这个值，将不会直接冲锋拿着近战的生还者", CVAR_FLAG, true, 0.0);
    g_hChargerTarget     = CreateConVar("ai_ChargerTarget", "3", "Charger目标选择：1=自然，2=最近，3=撞人多处", CVAR_FLAG, true, 1.0, true, 3.0);
    g_hChargeInterval    = FindConVar("z_charge_interval");

    g_hExtraTargetDist.AddChangeHook(extraTargetDistChangeHandler);

    HookEvent("player_spawn", evt_PlayerSpawn);

    getOtherRangedTarget();
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        charge_interval[i] = 0.0;
        is_charging[i] = false;
        can_attack_pinned[i] = false;
        ranged_index[i] = 0;
    }
}

public void OnClientDisconnect(int client)
{
    charge_interval[client] = 0.0;
    is_charging[client] = false;
    can_attack_pinned[client] = false;
    ranged_index[client] = 0;
}

void extraTargetDistChangeHandler(ConVar convar, const char[] oldValue, const char[] newValue)
{
    getOtherRangedTarget();
}

// ===== Events =====
public void evt_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsCharger(client))
    {
        // 初始设置为：刚好结束一次冲锋 → 可以立刻挥拳
        charge_interval[client] = 0.0 - g_hChargeInterval.FloatValue;
        is_charging[client] = false;
    }
}

// ===== Core Control =====
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    if (!IsCharger(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    bool has_sight = view_as<bool>(GetEntProp(client, Prop_Send, "m_hasVisibleThreats"));
    int  target = GetClientAimTarget(client, true);
    int  flags  = GetEntityFlags(client);
    int  ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");

    float self_pos[3];
    float target_pos[3];
    float vec_speed[3];
    float cur_speed;

    GetClientAbsOrigin(client, self_pos);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vec_speed);
    cur_speed = SquareRoot(Pow(vec_speed[0], 2.0) + Pow(vec_speed[1], 2.0));

    survivor_num = GetSurvivorCount(true, false);

    // 监控 charging state 变化 → 记录结束时间戳
    if (IsValidEntity(ability) && !is_charging[client] && GetEntProp(ability, Prop_Send, "m_isCharging") == 1)
    {
        is_charging[client] = true;
    }
    else if (IsValidEntity(ability) && is_charging[client] && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
    {
        charge_interval[client] = GetGameTime();
        is_charging[client] = false;
    }

    // 冲锋时静止玩家输入速度
    if (buttons & IN_ATTACK)
    {
        vel[0] = vel[1] = vel[2] = 0.0;
    }

    // 主逻辑：根据“是否看你(背身)”与距离，决定冲/拳
    if (IsValidSurvivor(target))
    {
        GetClientAbsOrigin(target, target_pos);
        float dist = GetVectorDistance(self_pos, target_pos);
        bool target_watching = Is_Target_Watching_Attacker(client, target, g_hAimOffset.IntValue);
        bool inChargeCD = IsInChargeDuration(client);
        bool onGround = (flags & FL_ONGROUND) != 0;
        bool abilityCharging = (IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") == 1);

        // 先处理“可见且距离在主阈值周边”的场景
        if (has_sight && !abilityCharging)
        {
            // 背身分支：
            if (!target_watching && !IsClientIncapped(target) && !IsClientPinned(target))
            {
                // 背身 && 距离在 (ChargeDist, ExtraMax] && 在 [ExtraMin, ExtraMax] 窗口 → 试图冲锋（先检查是否会被挡）
                if (!inChargeCD && onGround && dist > g_hChargeDist.FloatValue && dist >= min_dist && dist <= max_dist)
                {
                    float chargeAngles[3];
                    float dir[3];
                    MakeVectorFromPoints(self_pos, target_pos, dir);
                    GetVectorAngles(dir, chargeAngles);

                    if (WillChargePathClear(client, chargeAngles, 120.0))
                    {
                        SetCharge(client);
                        buttons |= IN_ATTACK;   // 交由能力决定是冲锋
                        return Plugin_Changed;
                    }
                    else
                    {
                        // 路径被挡 → 挥拳更稳
                        BlockCharge(client);
                        buttons |= IN_ATTACK;   // 挥拳
                        return Plugin_Changed;
                    }
                }
                // 背身 && 距离 <= ChargeDist → 挥拳（近距离冲锋易贴脸卡）
                else if (dist <= g_hChargeDist.FloatValue)
                {
                    BlockCharge(client);
                    buttons |= IN_ATTACK;
                    return Plugin_Changed;
                }
            }
            else if (target_watching && !IsClientIncapped(target) && !IsClientPinned(target))
            {
                // 正面看你：若目标不是近战，尝试冲锋（带路径检查）
                if (!Client_MeleeCheck(target) && !inChargeCD && onGround)
                {
                    float chargeAngles2[3];
                    float dir2[3];
                    MakeVectorFromPoints(self_pos, target_pos, dir2);
                    GetVectorAngles(dir2, chargeAngles2);

                    if (WillChargePathClear(client, chargeAngles2, 120.0))
                    {
                        SetCharge(client);
                        buttons |= IN_ATTACK;
                        return Plugin_Changed;
                    }
                    else
                    {
                        BlockCharge(client);
                        buttons |= IN_ATTACK; // 路不通 → 挥拳
                        return Plugin_Changed;
                    }
                }
                // 正面且对方拿近战：交给 OnChooseVictim 去转移目标或近战回避；此处只防冲
                else if (Client_MeleeCheck(target))
                {
                    BlockCharge(client);
                }
            }

            // 目标倒地/起身：不冲 → 挥拳
            if (Is_InGetUp_Or_Incapped(target))
            {
                BlockCharge(client);
                buttons |= IN_ATTACK;
                return Plugin_Changed;
            }
        }

        // 距离过大或其他情况：阻止冲锋，允许普通攻击（追击/压制）
        if (!inChargeCD && !abilityCharging)
        {
            BlockCharge(client);
            // buttons |= IN_ATTACK; // 这里不强制攻击，交由 AI 自然移动
        }
    }

    // ====== BHop 逻辑 ======
    int bhopMinDist = can_attack_pinned[client] ? 0 : g_hChargeDist.IntValue;
    float closestDist = GetClosestSurvivorDistance(client);

    if (has_sight && g_hAllowBhop.BoolValue
        && closestDist > float(bhopMinDist)
        && closestDist < 2000.0
        && cur_speed > 175.0
        && IsValidSurvivor(GetClientAimTarget(client, true)))
    {
        if ((flags & FL_ONGROUND) != 0)
        {
            int tgt = GetClientAimTarget(client, true);
            float vel_buffer[3];
            if (IsValidSurvivor(tgt))
            {
                float tgtpos[3];
                GetClientAbsOrigin(tgt, tgtpos);
                CalculateVel(self_pos, tgtpos, g_hBhopSpeed.FloatValue, vel_buffer);
                buttons |= IN_JUMP;
                buttons |= IN_DUCK;
                if (Do_Bhop(client, buttons, vel_buffer))
                    return Plugin_Changed;
            }
        }
    }

    // 梯子上禁用连跳
    if (GetEntityMoveType(client) == MOVETYPE_LADDER)
    {
        buttons &= ~IN_JUMP;
        buttons &= ~IN_DUCK;
    }

    return Plugin_Continue;
}

// ===== Victim Selection =====
public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
    int new_target = 0;
    if (IsCharger(specialInfected))
    {
        float self_pos[3];
        float target_pos[3];
        GetClientEyePosition(specialInfected, self_pos);
        FindRangedClients(specialInfected, min_dist, max_dist);

        if (IsValidSurvivor(curTarget) && IsPlayerAlive(curTarget))
        {
            GetClientEyePosition(curTarget, target_pos);

            // 1) 范围内若有人被控，且自身血量>阈值，先去挥拳解场
            for (int i = 0; i < ranged_index[specialInfected]; i++)
            {
                int s = ranged_client[specialInfected][i];
                if (GetClientHealth(specialInfected) > g_hChargerMeleeDamage.IntValue && !IsInChargeDuration(specialInfected))
                {
                    if (GetEntPropEnt(s, Prop_Send, "m_pounceAttacker") > 0 ||
                        GetEntPropEnt(s, Prop_Send, "m_tongueOwner") > 0   ||
                        GetEntPropEnt(s, Prop_Send, "m_jockeyAttacker") > 0)
                    {
                        can_attack_pinned[specialInfected] = true;
                        curTarget = s;
                        BlockCharge(specialInfected); // 修正：阻止的是牛，不是目标
                        return Plugin_Changed;
                    }
                }
            }
            can_attack_pinned[specialInfected] = false;

            // 2) 近战回避：目标拿近战 & 距离>=冲锋阈 & 我血量≥阈 → 尝试切换
            if (!IsClientIncapped(curTarget) && !IsClientPinned(curTarget))
            {
                if (g_hAllowMeleeAvoid.BoolValue && Client_MeleeCheck(curTarget)
                    && GetVectorDistance(self_pos, target_pos) >= g_hChargeDist.FloatValue
                    && GetClientHealth(specialInfected) >= g_hChargerMeleeDamage.IntValue)
                {
                    int melee_num = 0;
                    Get_MeleeNum(melee_num, new_target);
                    if (Client_MeleeCheck(curTarget) && melee_num < survivor_num && IsValidSurvivor(new_target) && Player_IsVisible_To(specialInfected, new_target))
                    {
                        curTarget = new_target;
                        return Plugin_Changed;
                    }
                }
                // 不满足回避条件 → 防冲，改为近战压制
                else if (g_hAllowMeleeAvoid.BoolValue && Client_MeleeCheck(curTarget) && !IsInChargeDuration(specialInfected)
                    && (GetVectorDistance(self_pos, target_pos) < g_hChargeDist.FloatValue || GetClientHealth(specialInfected) < g_hChargerMeleeDamage.IntValue))
                {
                    BlockCharge(specialInfected);
                }

                // 3) 目标选择策略
                switch (g_hChargerTarget.IntValue)
                {
                    case 2:
                    {
                        new_target = GetClosetMobileSurvivor(specialInfected); // 保留原函数名
                        if (IsValidSurvivor(new_target))
                        {
                            curTarget = new_target;
                            return Plugin_Changed;
                        }
                    }
                    case 3:
                    {
                        new_target = GetCrowdPlace(survivor_num);
                        if (IsValidSurvivor(new_target))
                        {
                            curTarget = new_target;
                            return Plugin_Changed;
                        }
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
                return Plugin_Changed;
            }
        }
    }

    if (!can_attack_pinned[specialInfected] && IsCharger(specialInfected) && IsValidSurvivor(curTarget) && (IsClientIncapped(curTarget) || IsClientPinned(curTarget)))
    {
        int new_target2 = GetClosetMobileSurvivor(specialInfected);
        if (IsValidSurvivor(new_target2))
        {
            curTarget = new_target2;
            return Plugin_Changed;
        }
    }

    return Plugin_Continue;
}

// ===== Helpers =====
void Get_MeleeNum(int &melee_num, int &new_target)
{
    int active_weapon = -1;
    char weapon_name[48];
    melee_num = 0;
    new_target = -1;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientConnected(client) && IsClientInGame(client) && GetClientTeam(client) == view_as<int>(TEAM_SURVIVOR)
            && IsPlayerAlive(client) && !IsClientIncapped(client) && !IsClientPinned(client))
        {
            active_weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
            if (IsValidEntity(active_weapon) && IsValidEdict(active_weapon))
            {
                GetEdictClassname(active_weapon, weapon_name, sizeof(weapon_name));
                if (IsMeleeClass(weapon_name))
                {
                    melee_num += 1;
                }
                else
                {
                    new_target = client; // 记录一个非近战目标
                }
            }
        }
    }
}

public bool IsMeleeClass(const char[] cls)
{
    if (strcmp(cls, "weapon_chainsaw") == 0)
        return true;
    return (strncmp(cls, "weapon_melee", 12, false) == 0);
}

bool Client_MeleeCheck(int client)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client) || IsClientIncapped(client) || IsClientPinned(client))
        return false;

    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(wep) || !IsValidEdict(wep))
        return false;

    char cls[48];
    GetEdictClassname(wep, cls, sizeof(cls));
    return IsMeleeClass(cls);
}

int GetCrowdPlace(int num_survivors)
{
    if (num_survivors <= 0)
        return -1;

    int index = 0, iTarget = 0;
    int[] iSurvivors = new int[num_survivors];
    float fDistance[MAXPLAYERS + 1];
    for (int i = 0; i <= MAXPLAYERS; i++) fDistance[i] = -1.0;

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
            float fClientPos[3];
            GetClientAbsOrigin(client, fClientPos);
            for (int i = 0; i < num_survivors; i++)
            {
                float fPos[3];
                GetClientAbsOrigin(iSurvivors[i], fPos);
                fDistance[client] += GetVectorDistance(fClientPos, fPos, true);
            }
        }
    }

    for (int i = 0; i < num_survivors; i++)
    {
        if (fDistance[iSurvivors[iTarget]] > fDistance[iSurvivors[i]] && fDistance[iSurvivors[i]] != -1.0)
            iTarget = i;
    }

    return iSurvivors[iTarget];
}

// 是否 AI 牛
bool IsCharger(int client)
{
    return view_as<bool>(GetInfectedClass(client) == view_as<int>(ZC_CHARGER) && IsFakeClient(client));
}

// 判断目标是否处于正在起身或正在倒地状态
bool Is_InGetUp_Or_Incapped(int client)
{
    int character_index = IdentifySurvivor(client);
    if (character_index == view_as<int>(SC_INVALID))
        return false;

    int sequence = GetEntProp(client, Prop_Send, "m_nSequence");
    if (sequence == GetUpAnimations[character_index][ID_HUNTER] ||
        sequence == GetUpAnimations[character_index][ID_CHARGER] ||
        sequence == GetUpAnimations[character_index][ID_CHARGER_WALL] ||
        sequence == GetUpAnimations[character_index][ID_CHARGER_GROUND])
        return true;

    if (sequence == IncappAnimations[character_index][ID_SINGLE_PISTOL] ||
        sequence == IncappAnimations[character_index][ID_DUAL_PISTOLS])
        return true;

    return false;
}

// 阻止牛冲锋（推迟能力时间戳）
void BlockCharge(int client)
{
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", GetGameTime() + g_hChargeInterval.FloatValue);
}

// 让牛冲锋（提前能力时间戳）
void SetCharge(int client)
{
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging") != 1)
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", GetGameTime() - 0.5);
}

// 是否在冲锋间隔
bool IsInChargeDuration(int client)
{
    return view_as<bool>((GetGameTime() - (g_hChargeInterval.FloatValue + charge_interval[client])) < 0.0);
}

// 查找范围内可视的有效玩家
int FindRangedClients(int client, float min_range, float max_range)
{
    int index = 0;
    float self_eye_pos[3];
    GetClientEyePosition(client, self_eye_pos);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == view_as<int>(TEAM_SURVIVOR) && IsPlayerAlive(i) && !IsClientIncapped(i))
        {
            float target_eye_pos[3];
            GetClientEyePosition(i, target_eye_pos);
            float dist = GetVectorDistance(self_eye_pos, target_eye_pos);
            if (dist >= min_range && dist <= max_range)
            {
                Handle hTrace = TR_TraceRayFilterEx(self_eye_pos, target_eye_pos, MASK_VISIBLE, RayType_EndPoint, TR_EntityFilter, client);
                bool ok = (!TR_DidHit(hTrace) || TR_GetEntityIndex(hTrace) == i);
                delete hTrace;
                if (ok)
                    ranged_client[client][index++] = i;
            }
        }
    }
    ranged_index[client] = index;
    return index;
}

// 牛连跳
bool Do_Bhop(int client, int &buttons, float vec[3])
{
    if (buttons & (IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT))
    {
        if (ClientPush(client, vec))
            return true;
    }
    return false;
}

bool ClientPush(int client, float vec[3])
{
    float curvel[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", curvel);
    AddVectors(curvel, vec, curvel);
    if (Dont_HitWall_Or_Fall(client, curvel))
    {
        if (GetVectorLength(curvel) <= 250.0)
        {
            NormalizeVector(curvel, curvel);
            ScaleVector(curvel, 251.0);
        }
        TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, curvel);
        return true;
    }
    return false;
}

// 计算自→目标的单位向量 * force
public void CalculateVel(const float self_pos[3], const float target_pos[3], float force, float out[3])
{
    float dir[3];
    SubtractVectors(target_pos, self_pos, dir);
    NormalizeVector(dir, dir);
    ScaleVector(dir, force);
    out[0] = dir[0]; out[1] = dir[1]; out[2] = dir[2];
}

// 冲锋路径快速可行性检查：以当前包围盒沿着角度前探 ahead
public bool WillChargePathClear(int client, const float dirAngles[3], float ahead)
{
    float mins[3], maxs[3];
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);

    float start[3];
    GetClientAbsOrigin(client, start);
    start[2] += NAV_MESH_HEIGHT; // 与地面留出高度

    float fwd[3];
    GetAngleVectors(dirAngles, fwd, NULL_VECTOR, NULL_VECTOR);
    float end[3];
    end[0] = start[0] + fwd[0] * ahead;
    end[1] = start[1] + fwd[1] * ahead;
    end[2] = start[2];

    Handle hTrace = TR_TraceHullFilterEx(start, end, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilter);
    bool blocked = TR_DidHit(hTrace);
    delete hTrace;

    return !blocked;
}

// 检测下一帧位置是否撞墙/掉落/受伤
bool Dont_HitWall_Or_Fall(int client, float vel[3])
{
    bool hullrayhit = false;
    int down_hullray_hitent = -1;
    char down_hullray_hitent_classname[16];

    float selfpos[3], resultpos[3], mins[3], maxs[3], hullray_endpos[3];
    float down_hullray_startpos[3], down_hullray_endpos[3], down_hullray_hitpos[3];

    GetClientAbsOrigin(client, selfpos);
    AddVectors(selfpos, vel, resultpos);
    GetClientMins(client, mins);
    GetClientMaxs(client, maxs);

    float start[3]; CopyVector(selfpos, start); start[2] += NAV_MESH_HEIGHT;
    float end[3];   CopyVector(resultpos, end); end[2] += NAV_MESH_HEIGHT;

    Handle hTrace = TR_TraceHullFilterEx(start, end, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilter);
    if (TR_DidHit(hTrace))
    {
        hullrayhit = true;
        TR_GetEndPosition(hullray_endpos, hTrace);
        if (GetVectorDistance(start, hullray_endpos) <= NAV_MESH_HEIGHT)
        {
            delete hTrace;
            return false;
        }
    }
    delete hTrace;

    // 向下投射，避免大跌落/触发伤害
    if (!hullrayhit)
    {
        CopyVector(resultpos, down_hullray_startpos);
    }
    CopyVector(down_hullray_startpos, down_hullray_endpos);
    down_hullray_endpos[2] -= 100000.0;

    Handle hDownTrace = TR_TraceHullFilterEx(down_hullray_startpos, down_hullray_endpos, mins, maxs, MASK_NPCSOLID_BRUSHONLY, TR_EntityFilter);
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

// Trace filter：忽略玩家/常见实体
public bool TR_EntityFilter(int entity, int mask, any data)
{
    if (entity <= MaxClients)
        return false;

    char classname[32];
    if (IsValidEntity(entity) && IsValidEdict(entity))
    {
        GetEdictClassname(entity, classname, sizeof(classname));
        if (strcmp(classname, "infected") == 0 || strcmp(classname, "witch") == 0 || strcmp(classname, "prop_physics") == 0 || strcmp(classname, "tank_rock") == 0)
            return false;
    }
    return true;
}

// 目标是否“看着你”（水平夹角 ≤ offset）
bool Is_Target_Watching_Attacker(int client, int target, int offset)
{
    if (IsValidInfected(client) && IsValidSurvivor(target) && IsPlayerAlive(client) && IsPlayerAlive(target)
        && !IsClientIncapped(target) && !IsClientPinned(target) && !Is_InGetUp_Or_Incapped(target))
    {
        int aim_offset = RoundToNearest(Get_Player_Aim_Offset(target, client));
        return (aim_offset <= offset);
    }
    return false;
}

float Get_Player_Aim_Offset(int client, int target)
{
    if (IsValidClient(client) && IsValidClient(target) && IsPlayerAlive(client) && IsPlayerAlive(target))
    {
        float self_pos[3], target_pos[3], aim_vector[3], dir_vector[3];
        float result_angle = 0.0;
        GetClientEyeAngles(client, aim_vector);
        aim_vector[0] = 0.0; // Pitch 忽略
        aim_vector[2] = 0.0; // Roll 忽略
        GetAngleVectors(aim_vector, aim_vector, NULL_VECTOR, NULL_VECTOR);
        NormalizeVector(aim_vector, aim_vector);
        GetClientAbsOrigin(target, target_pos);
        GetClientAbsOrigin(client, self_pos);
        self_pos[2] = 0.0; target_pos[2] = 0.0;
        MakeVectorFromPoints(self_pos, target_pos, dir_vector);
        NormalizeVector(dir_vector, dir_vector);
        result_angle = RadToDeg(ArcCosine(GetVectorDotProduct(aim_vector, dir_vector)));
        return result_angle;
    }
    return -1.0;
}

public void getOtherRangedTarget()
{
    static char cvar_dist[32];
    static char parts[2][16];
    g_hExtraTargetDist.GetString(cvar_dist, sizeof(cvar_dist));
    if (!IsNullString(cvar_dist) && ExplodeString(cvar_dist, ",", parts, sizeof(parts), sizeof(parts[])) == 2)
    {
        min_dist = StringToFloat(parts[0]);
        max_dist = StringToFloat(parts[1]);
        if (max_dist < min_dist) { float t = min_dist; min_dist = max_dist; max_dist = t; }
    }
    else
    {
        min_dist = 0.0;
        max_dist = 350.0;
    }
}

// ===== Utility =====
public void CopyVector(const float src[3], float dest[3])
{
    dest[0] = src[0]; dest[1] = src[1]; dest[2] = src[2];
}

float GetClosestSurvivorDistance(int client)
{
    float selfpos[3];
    GetClientAbsOrigin(client, selfpos);
    float best = 999999.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
        {
            float pos[3];
            GetClientAbsOrigin(i, pos);
            float d = GetVectorDistance(selfpos, pos);
            if (d < best) best = d;
        }
    }
    return best;
}
