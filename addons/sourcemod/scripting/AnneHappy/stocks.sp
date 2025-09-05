#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <treeutil>

stock bool isAiTank(int client) {
    return IsValidInfected(client) && GetInfectedClass(client) == ZC_TANK && IsFakeClient(client)
            && IsPlayerAlive(client) && !IsClientIncapped(client) && !IsInGhostState(client);
}

/**
* 获取当前被控的生还者数量
* @param void
* @return int
**/
stock int getPinnedSurvivorCount() {
    static int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i) || IsClientIncapped(i) || IsClientHanging(i))
            continue;
        if (!IsClientPinned(i))
            continue;
        count += 1;
    }
    return count;
}

/**
* 检查客户端是否正在被 Hunter 或者 Charger 控制
* @param client 客户端索引
* @return bool 是否被控制
**/
stock bool isPinnedByHunterOrCharger(int client) {
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
        return false;
    
    static int infected;
    infected = GetEntPropEnt(client, Prop_Send, "m_pounceAttacker");
    if (IsValidInfected(infected))
        return true;
    infected = GetEntPropEnt(client, Prop_Send, "m_carryAttacker");
    if (IsValidInfected(infected))
        return true;
    infected = GetEntPropEnt(client, Prop_Send, "m_pummelAttacker");
    if (IsValidInfected(infected))
        return true;
    return false;
}

/**
* 生还者是否处于胆汁状态
* @param client 客户端索引
* @return bool
**/
stock bool isClientBiled(int client) {
    if (!IsValidClient(client))
        return false;
    
    static int glowColor;
    glowColor = GetEntProp(client, Prop_Send, "m_glowColorOverride");
    if (glowColor == -4713783)
        return true;
    
    static float bileTime;
    bileTime = GetEntPropFloat(client, Prop_Send, "m_vomitFadeStart");
    if (bileTime != 0.0 && bileTime + FindConVar("z_vomit_fade_duration").FloatValue > GetGameTime())
        return true;
    return false;
}

stock bool clientPush(int client, float fwdAng[3], float scale) {
    if (!isAiTank(client))
        return false;

    static float velVec[3];
    GetEntPropVector(client, Prop_Send, "m_vecAbsVelocity", velVec);

    NormalizeVector(fwdAng, fwdAng);
    ScaleVector(fwdAng, scale);
    AddVectors(velVec, fwdAng, velVec);
    TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, velVec);
    return true;
}

/**
* 返回客户端是否看到生还者
* @param client 客户端索引
* @return bool
**/
stock bool hasSightOfSurvivor(int client) {
    return view_as<bool>(HasEntProp(client, Prop_Send, "m_hasVisibleThreats"));
}

/**
* 获取距离某个客户端最近的生还者
* @param client 客户端索引
* @param exluceIncap 是否排除倒地的生还者
* @error 无法找到有效的生还者时返回 -1
* @return int 目标客户端索引
**/
stock int getClosestSurvivor(int client, bool excludeIncap = false) {
    static ArrayList targets;
    targets = new ArrayList(2);

    static float pos[3], targetPos[3];
    GetClientAbsOrigin(client, pos);
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;
        if (excludeIncap && IsClientIncapped(i))
            continue;
        
        GetClientAbsOrigin(i, targetPos)
        targets.Set(targets.Push(GetVectorDistance(targetPos, pos)), i, 1);
    }

    SortADTArray(targets, Sort_Ascending, Sort_Float);
    if (targets.Length < 1) {
        delete targets;
        return -1;
    }
    static int target;
    target = targets.Get(0, 1);
    delete targets;
    return target;
}

stock bool clientIsVisibleToClient(int client, int target) {
    if (!isAiTank(client))
        return false;
    if (!IsValidClient(target) || !IsPlayerAlive(target))
        return false;
    
    static float pos[3], targetPos[3];
    GetClientEyePosition(client, pos);
    GetClientEyePosition(target, targetPos);
    static Handle hTrace;
    static bool visible;
    hTrace = TR_TraceRayFilterEx(pos, targetPos, MASK_SHOT, RayType_EndPoint, _CIsVisible2C_traceRayFilter, client);
    visible = !TR_DidHit(hTrace);
    delete hTrace;
    return visible;
}

stock bool _CIsVisible2C_traceRayFilter(int entity, int contentsMask, any data) {
    // 忽略自身与无效实体
    if (entity == data || !IsValidEntity(entity))
        return false;
    // 忽略客户端
    if (entity > 0 && entity <= MaxClients)
        return false;

    static char className[64];
    GetEntityClassname(entity, className, sizeof(className));
    if (StrContains(className, "trigger_", false) >= 0)
        return false;
    if (strcmp(className, "func_illusionary", false) == 0)
        return false;
    // 忽略玻璃
    static int solidType, effects;
    solidType = GetEntProp(entity, Prop_Data, "m_nSolidType");
    if (strcmp(className, "func_breakable", false) == 0 && solidType == 1)
        return false;
    // 忽略阻挡玩家或特感的空气墙
    if (strcmp(className, "func_playerclip", false) == 0 ||
        strcmp(className, "player_infected_clip", false) == 0 ||
        strcmp(className, "func_playerinfected_clip", false) == 0)
        return false;
    // 忽略效果包含 EF_NODRAW 的实体
    effects = GetEntProp(entity, Prop_Send, "m_fEffects");
    if (effects & 32)
        return false;

    return true;
}

stock bool _TraceWallFilter(int entity, int contentsMask, any data) {
    if (!IsValidEntity(entity))
        return false;

    if (entity != data) {
        static char className[3];
        GetEntityClassname(entity, className, sizeof(className));
        if (strcmp(className, "infected", false) == 0 || strcmp(className, "player", false) == 0)
            return false;
        return true;
    }

    return false;
}

stock bool floatIsNan(float val) {
    return (view_as<int>(val) & 0x7FFFFFFF) > 0x7F800000;
}