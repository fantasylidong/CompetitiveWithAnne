#if defined _stocks_included_
    #endinput
#endif
#define _stocks_included_

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <treeutil>
#include <logger2>

#include "./setup.inc"

#define STOCK_LOG_PREFIX "AI-ChargerStock"

Logger
    stockLog;

ConVar
    g_cvStockLogLevel;

stock void Stock_OnModuleStart(ConVar& cvPluginName) {
    if (!cvPluginName) {
        g_cvStockLogLevel = CreateConVar("_ai_charger3_stock_log_level", "1", "工具模块的日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 数字相加", CVAR_FLAGS);
    } else {
        char cvName[64], stockLogCvName[64];
        cvPluginName.GetString(cvName, sizeof(cvName));
        FormatEx(stockLogCvName, sizeof(stockLogCvName), "_%s_stock_log_level", cvName);
        g_cvStockLogLevel = CreateConVar(stockLogCvName, "1", "工具模块的日志记录级别, 1=关闭, 2=控制台输出, 4=log文件输出, 8=聊天框输出, 16=服务器控制台输出, 32=error文件输出, 数字相加", CVAR_FLAGS);
    }

    stockLog = new Logger(STOCK_LOG_PREFIX, g_cvStockLogLevel.IntValue);
}

stock void Stock_OnModuleEnd() {
    delete stockLog;
}

stock bool isAiCharger(int client) {
    return IsValidInfected(client) && GetInfectedClass(client) == ZC_CHARGER &&
            IsFakeClient(client) && IsPlayerAlive(client) && !IsInGhostState(client);
}

stock bool alignChargerFacingWithMovement(int client, const float movement[3], float commandAngles[3]) {
    if (!isAiCharger(client))
        return false;

    static float direction[3];
    direction = movement;
    direction[2] = 0.0;
    if (NormalizeVector(direction, direction) <= 0.0)
        return false;

    GetVectorAngles(direction, commandAngles);
    commandAngles[0] = 0.0;
    commandAngles[2] = 0.0;
    return true;
}

stock void setForwardBhopInput(int& buttons, bool startJump) {
    buttons &= ~(IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_LEFT | IN_RIGHT | IN_JUMP | IN_DUCK);
    buttons |= IN_FORWARD;

    if (startJump)
        buttons |= IN_JUMP | IN_DUCK;
}

stock bool allowToBhop(int client) {
    if (!isAiCharger(client))
        return false;
    
    // 处于 APPROACH STATE 且不允许接近状态时连跳或处于 CHARGING STATE 时不允许冲锋前连跳
    if (
        (g_ChargerStateContext[client].currentStateId == CH_STATE_APPROACH && !g_cvBhop.BoolValue) ||
        (g_ChargerStateContext[client].currentStateId == CH_STATE_CHARGING && !g_cvBhopBeforeCharge.BoolValue)
    ) {
        return false;
    }

    if (L4D_IsPlayerStaggering(client))
        return false;
    
    if (GetEntityMoveType(client) == MOVETYPE_LADDER || GetEntProp(client, Prop_Data, "m_nWaterLevel") > 1)
        return false;
    
    // 当前需要上下梯子或者爬上障碍物, 不允许连跳
    static PathSegment curSeg;
    curSeg = g_AiChargers[client].m_PathSegment;
    if (
        curSeg.m_pPathSegment && curSeg.m_SegmentType == SegType_ClimbUp ||
        curSeg.m_pPathSegment && curSeg.m_SegmentType == SegType_LadderUp ||
        curSeg.m_pPathSegment && curSeg.m_SegmentType == SegType_LadderDown
    ) {
        return false;
    }

    return true;
}

stock bool isNearLadder(int client, const float checkDist) {
    static int entity;
    entity = -1;
    static float pos[3], origin[3], mins[3], maxs[3], nearest[3];
    L4D_GetEntityWorldSpaceCenter(client, pos);
    while ((entity = FindEntityByClassname(entity, "func_simpleladder")) != -1) {
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
        GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);

        AddVectors(origin, mins, mins);
        AddVectors(origin, maxs, maxs);

        nearest[0] = (pos[0] < mins[0]) ? mins[0] : ((pos[0] > maxs[0]) ? maxs[0] : pos[0]);
        nearest[1] = (pos[1] < mins[1]) ? mins[1] : ((pos[1] > maxs[1]) ? maxs[1] : pos[1]);
        nearest[2] = (pos[2] < mins[2]) ? mins[2] : ((pos[2] > maxs[2]) ? maxs[2] : pos[2]);

        if (GetVectorDistance(pos, nearest) <= checkDist) {
            return true;
        }
    }
    return false;
}

stock int getChargeAbilityEnt(int client) {
    if (!isAiCharger(client))
        return -1;

    static int ability;
    static char clsName[32];
    ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (!IsValidEdict(ability))
        return -1;
    GetEntityClassname(ability, clsName, sizeof(clsName));
    if (strcmp(clsName, "ability_charge", false) != 0)
        return -1;

    return ability;
}

stock bool isChargerCharging(int client) {
    if (!isAiCharger(client))
        return false;
    
    static int ability;
    ability = getChargeAbilityEnt(client);
    if (!IsValidEdict(ability))
        return false;
    
    return view_as<bool>(GetEntProp(ability, Prop_Send, "m_isCharging"));
}

/**
* 检查 Charger 冲撞能力是否就绪
* @param client 客户端索引
* @return bool, true 就绪, false 未就绪
**/
stock bool isChargeAbilityReady(int client) {
    if (!isAiCharger(client))
        return false;

    static int ability;
    ability = getChargeAbilityEnt(client);
    if (!IsValidEdict(ability))
        return false;
    
    static float timestamp;
    timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
    // ============================================================
    // 1. 如果技能就绪时刻大于当前时刻, 且是人为延时, 则说明技能其实可以准备就绪, 允许冲锋
    // 2. 如果技能就绪时刻小于当前时刻, 允许冲锋
    // ============================================================
    if (timestamp > GetGameTime() && g_AiChargers[client].m_bChargeDelayed)
        return true;
    if (timestamp <= GetGameTime())
        return true;
    
    return false;
}

/**
* 检查目标是否处在 Charger 可以冲锋的高度范围内
* @param pos Charger 位置
* @param targetPos 目标位置
* @param threshold 最大允许高度差
* @return bool, true 表示高度可冲锋, false 表示高度差过大
**/
stock float getChargeHeightLimit(float threshold = -1.0) {
	if (threshold > 0.0)
		return threshold;
	if (g_cvLegacyChargeHeightDiff != null && g_cvLegacyChargeHeightDiff.FloatValue > 0.0)
		return g_cvLegacyChargeHeightDiff.FloatValue;
	return CHARGE_Z_THRESHOLD;
}

stock bool isChargeHeightReachable(const float pos[3], const float targetPos[3], float threshold = -1.0) {
	return FloatAbs(pos[2] - targetPos[2]) <= getChargeHeightLimit(threshold);
}

/**
* 检查目标实体是否处在 Charger 可以冲锋的高度范围内
* @param client Charger 客户端索引
* @param target 目标客户端索引
* @param threshold 最大允许高度差
* @return bool, true 表示高度可冲锋, false 表示高度差过大
**/
stock bool isChargeTargetHeightReachable(int client, int target, float threshold = -1.0) {
    if (!isAiCharger(client))
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;

    static float pos[3], targetPos[3];
    GetClientAbsOrigin(client, pos);
    GetClientAbsOrigin(target, targetPos);

    return isChargeHeightReachable(pos, targetPos, threshold);
}

/**
* 设置 Charger 冲锋技能的冷却时间
* @param client 客户端索引
* @param duration 冷却剩余时间 (0.0 = 立刻就绪, 0.5 = 锁定)
* @return void
**/
stock void setChargerAbilityCooldown(int client, float duration) {
    if (!isAiCharger(client))
        return;
    
    static int ability;
    ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (!IsValidEntity(ability))
        return;
    
    static char clsName[32];
    GetEntityClassname(ability, clsName, sizeof(clsName));
    if (strcmp(clsName, "ability_charge", false) != 0)
        return;
    
    // =========================================================================
    // 检查能力冷却时间, 若能力就绪时间大于当前时间, 且无论 duration > 0.0 还是小于 0.0
    // 则说明还在冷却, 不处理, 避免能力还没就绪就直接设置为 GetGameTime() ± 0.1 导致能力立即就绪
    // =========================================================================
    static float timestamp, gameTime;
    timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
    gameTime = GetGameTime();
    if (duration > 0.0) {
        // 如果当前已经处在自然冷却时间, 且 timestamp 远大于 gametime + duration, 返回
        if (timestamp > gameTime + duration && !g_AiChargers[client].m_bChargeDelayed)
            return;
        // 可以进行人为延迟, 进行标记
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", gameTime + duration);
        g_AiChargers[client].m_bChargeDelayed = true;
    } else {
        // 如果是自然冷却, 不能重置
        if (timestamp > gameTime && !g_AiChargers[client].m_bChargeDelayed)
            return;
        // 只有是人为延迟的，或者已经就绪的，才允许重置, 并重置标记
        SetEntPropFloat(ability, Prop_Send, "m_timestamp", gameTime + duration);
        g_AiChargers[client].m_bChargeDelayed = false;
    }
}

/**
* 检查 Charger 冲锋路径 start 和 end 坐标中会不会被实体阻挡
* @param client 客户端索引
* @param start 起点坐标 (使用 GetWorldSpaceCenter 获得)
* @param end 终点坐标
* @return bool, false 表示无障碍, true 存在障碍
**/
stock bool isChargePathBlocked(int client, int target) {
    if (!isAiCharger(client))
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;

    static float start[3], end[3];
    L4D_GetEntityWorldSpaceCenter(client, start);
    L4D_GetEntityWorldSpaceCenter(target, end);
    return SDKCall(g_hSdkIsChargeBlocked, client, start, end);
}

/**
* 检查 charger 当前目标是否处在易受攻击状态
* @param client 客户端索引
* @param target 目标索引
* @return bool, true 表示易受攻击, false 表示非易受攻击
**/
stock bool isTargetVulnerable(int client, int target) {
    if (!isAiCharger(client))
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;
    
    static int weapon;
    weapon = GetEntPropEnt(target, Prop_Send, "m_hActiveWeapon");
    // 没有武器, 可以直接冲撞
    if (!IsValidEntity(weapon)) {
        stockLog.debugAll("Charger (%N)'s target (%N) has no weaopn, can charge", client, target);
        return true;
    }

    static char weaponName[32];
    GetEntityClassname(weapon, weaponName, sizeof(weaponName));

    // 正在换弹中, 可以直接冲撞
    if (HasEntProp(weapon, Prop_Send, "m_bInReload") &&
        view_as<bool>(GetEntProp(weapon, Prop_Send, "m_bInReload"))) {
        stockLog.debugAll("Charger (%N)'s target (%N) is reloading, weapon %s, can charge", client, target, weaponName);
        return true;
    }

    // 正在攻击间隔中, 可以直接冲撞
    static float nextPrimaryAttack;
    nextPrimaryAttack = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
    if (nextPrimaryAttack > GetGameTime() + 0.5) {
        stockLog.debugAll("Charger (%N)'s target (%N) is in primary attack cooldown, weapon %s, can charge", client, target, weaponName);
        return true;
    }

    // 正在推的间隔中, 可以直接冲撞
    static float nextShoveTime;
    nextShoveTime = GetEntPropFloat(target, Prop_Send, "m_flNextShoveTime");
    if (nextShoveTime > GetGameTime() + 0.5) {
        stockLog.debugAll("Charger (%N)'s target (%N) is in shove cooldown, can charge", client, target);
        return true;
    }

    // 如果除了目标以外, 有另外的生还者正在看着 charger, 可以直接冲撞
    if (isAnySurvivorWatchingCharger(client, target) >= 1) {
        stockLog.debugAll("Charger (%N)'s target (%N) is being watched by another survivor, can charge", client, target);
        return true;
    }
    
    // 如果目标手持近战武器, 且 charger 生命值高于近战斩杀线, 可以直接冲撞
    if (L4D2_GetMeleeWeaponIndex(weaponName) > -1) {
        static int health;
        static int meleeDamageCharger;
        health = GetEntProp(client, Prop_Data, "m_iHealth");
		meleeDamageCharger = getLegacyMeleeDamage();
        if (health > meleeDamageCharger) {
            stockLog.debugAll("Charger (%N)'s target (%N) is holding melee weapon %s, charger health %d is greater than melee damage charger %.2f, can charge",
                client, target, weaponName, health, meleeDamageCharger);
            return true;
        }
    }

    // 如果当前 charger 的博弈时间超过了最大允许的博弈时间, 直接冲撞
    if (g_ChargerStateContext[client].getStateDuration() > g_cvBaitMaxDuration.FloatValue) {
        stockLog.debugAll("Charger (%N)'s bait time is up, can charge to its target (%N)", client, target);
        return true;
    }

    // 进阶检查, 检查朝着目标方向冲撞位置后若干距离是否有墙体或向下是否有足够高差或必杀
    static float eyeAng[3];
	GetClientEyeAngles(target, eyeAng);
    if (isDirectionBlockedOrFall(target, eyeAng, TARGET_VULNERABLE_ADV_CHECK_DIST)) {
        stockLog.debugAll("Ahead charger (%N)'s target (%N)'s direction %.2f distance, will hit wall or fall down, can charge",
            client, target, TARGET_VULNERABLE_ADV_CHECK_DIST);
        return true;
    }

    return false;
}

/**
* 检查 charger 当前目标 ang 方向 checkDist 距离内是否有障碍物
* @param target 目标索引
* @param ang 检测方向
* @param checkDist 检测距离
* @return book, true 存在障碍, false 无障碍
**/
stock bool isDirectionBlockedOrFall(int target, float ang[3], float checkDist) {
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;
    
    static float targetPos[3], eyePos[3], dir[3];
    GetClientAbsOrigin(target, targetPos);
    GetClientEyePosition(target, eyePos);
    // 计算方向向量
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
    dir[2] = 0.0;
    NormalizeVector(dir, dir);
    // 计算终点
    ScaleVector(dir, checkDist);
    AddVectors(eyePos, dir, dir);

    static Handle hTrace;
    static bool blocked;
    hTrace = TR_TraceHullFilterEx(eyePos, dir, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, _TraceWallFilter, target);
    blocked = TR_DidHit(hTrace);
    delete hTrace;
    if (blocked)
        return true;

    // 如果没有障碍物阻挡, 那么向下检测是否有很高的高差或者可以直接摔死
    static float vDown[3];
    vDown = dir;
    vDown[2] -= 9999.0;
    hTrace = TR_TraceRayFilterEx(dir, vDown, MASK_PLAYERSOLID, RayType_EndPoint, _TraceWallFilter, target);
    blocked = TR_DidHit(hTrace);
    if (!blocked) {
        // 如果连向下的射线都没有阻挡, 直接允许冲锋
        delete hTrace;
        return true;
    }
    static int hitEnt;
    static float endPos[3];
    hitEnt = TR_GetEntityIndex(hTrace);
    TR_GetEndPosition(endPos, hTrace);
    delete hTrace;

    // 检查落点高度, 若距离目标当前位置高差大于阈值, 则允许冲锋
    if (targetPos[2] - endPos[2] > DROP_DOWN_THRESHOLD)
        return true;
    // 检查落点是否有危险
    static char clsName[64];
    if (IsValidEntity(hitEnt)) {
        GetEntityClassname(hitEnt, clsName, sizeof(clsName));
        if (strcmp(clsName, "trigger_hurt", false) == 0)
            return true;
    }

    return false;
}

stock int getLegacyMeleeDamage() {
	if (g_cvLegacyMeleeDamage != null)
		return g_cvLegacyMeleeDamage.IntValue;
	if (cvMeleeDamageCharger != null)
		return cvMeleeDamageCharger.IntValue;
	return DEFAULT_MELEE_DMG_CHARGER;
}

/**
* 计算 charger 是否允许概率冲锋
* @param client 客户端索引
* @return bool, true 允许概率冲锋, false 不允许
**/
stock bool isChargerProbCharge(int client) {
    if (!isAiCharger(client))
        return false;

    // 没到检测时间
    if (GetGameTime() - g_AiChargers[client].m_flLastProbChargeChkTime <= g_cvProbChargeChkDur.FloatValue)
        return false;

    // 重新计算此次冲锋概率
    g_AiChargers[client].m_flLastProbChargeChkTime = GetGameTime();
    // 计算概率
    static float chargeProb;
    chargeProb = GetRandomFloatInRange(0.0, 1.0);
    if (chargeProb <= g_cvProbChargeProb.FloatValue)
        return true;
    
    return false;
}

/**
* 计算在平地上正常跳跃的滞空时间, Client 起跳高度为 56.0
* @param 
* @return float
**/
stock float getJumpAirTime() {
    static float gravity;
    gravity = !cvGravity ? DEFAULT_GRAVITY : cvGravity.FloatValue;
    return SquareRoot(112 / gravity) * 2.0;
}

/**
* 下一帧连跳落点位置检测
* @param client 客户端索引
* @param visible 是否有目标的视野
* @return bool, true 表示下一帧位置没有威胁, 允许连跳, false 反之
**/
stock bool nextTickPosCheck(int client, float vFwd[3], bool visible) {
	if (!isAiCharger(client))
		return false;

	static float vMins[3], vMaxs[3];
	GetClientMins(client, vMins);
	GetClientMaxs(client, vMaxs);

	static float pos[3], endPos[3], velVec[3], vel;
	L4D_GetEntityWorldSpaceCenter(client, pos);
    velVec = vFwd;
    // 根据跳跃滞空时间对 velVec 进行缩放
    ScaleVector(velVec, getJumpAirTime());

	vel = GetVectorLength(velVec);
	NormalizeVector(velVec, velVec);
	// 为下一帧检测的位置留出一些余量 (bbox 宽度 + 3), endPos 为下一帧位置
	ScaleVector(velVec, vel + FloatAbs(vMaxs[0] - vMins[0]) + 3.0);
	AddVectors(pos, velVec, endPos);

    // For debug print next tick position
    /* ShowPos(COLOR_GREEN, pos, endPos); */

	// 射线检测
	static Handle hTrace;
	hTrace = TR_TraceHullFilterEx(pos, endPos, {-36.0, -36.0, 10.0}, {36.0, 36.0, 72.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
	if (TR_DidHit(hTrace)) {
		// 防止下次连跳速度方向撞墙 (速度方向与墙的法向量垂直为 180 度)
		static float rayEndPos[3], hitNormal[3];
		TR_GetEndPosition(rayEndPos, hTrace);
		TR_GetPlaneNormal(hTrace, hitNormal);
		NormalizeVector(hitNormal, hitNormal);
		NormalizeVector(velVec, velVec);
		if (RadToDeg(ArcCosine(GetVectorDotProduct(hitNormal, velVec))) > 165.0) {
			delete hTrace;
			return false;
		}
	}

	if (!visible) {
		// 无视野情况, 计算视角与速度向量夹角, 若太大则禁止连跳
		static float eyeAng[3], dir[3], dot, angle;
		GetClientEyeAngles(client, eyeAng);
		GetAngleVectors(eyeAng, dir, NULL_VECTOR, NULL_VECTOR);
		NormalizeVector(dir, dir);
		NormalizeVector(velVec, velVec);
		dir[2] = velVec[2] = 0.0;

        dot = GetVectorDotProduct(dir, velVec);
        if (dot > 1.0) dot = 1.0;
        else if (dot < -1.0) dot = -1.0;
		angle = RadToDeg(ArcCosine(dot));

		if (angle > g_cvBhopNoVisionMaxAng.FloatValue) {
			delete hTrace;
			return false;
		}
	}

	delete hTrace;
	// 检测下一帧向下的位置是否会死亡
	static float downPos[3], landPos[3];
	downPos = endPos;
	downPos[2] -= 99999.0;
	hTrace = TR_TraceHullFilterEx(endPos, downPos, {-16.0, -16.0, 0.0}, {16.0, 16.0, 0.0}, MASK_PLAYERSOLID, _TraceWallFilter, client);
	// 太高了, 返回 false
	if (!TR_DidHit(hTrace)) {
		delete hTrace;
		return false;
	}

    // 获取实际落地点
    TR_GetEndPosition(landPos, hTrace);

	static int hitEnt;
	hitEnt = TR_GetEntityIndex(hTrace);
	if (IsValidEntity(hitEnt)) {
		static char className[32];
		GetEntityClassname(hitEnt, className, sizeof(className));
		if (strcmp(className, "trigger_hurt", false) == 0) {
			delete hTrace;
			return false;
		}
	}
	delete hTrace;
	return true;
}

stock float navAreaGetCenterZ(Address navArea) {
    if (navArea == Address_Null)
        return 0.0;
    
    static float center[3];
    L4D_GetNavAreaCenter(navArea, center);
    return center[2];
}

stock bool _TraceWallFilter(int entity, int contentsMask, any data) {
    // worldspawn
    if (entity == 0)
        return true;
    // 忽略自身
    if (entity == data)
        return false;
    // 忽略所有玩家 (生还和特感)
    if (entity > 0 && entity <= MaxClients)
        return false;

    // 忽略普通感染者和 witch
    static char clsName[32];
    if (IsValidEntity(data)) {
        GetEntityClassname(entity, clsName, sizeof(clsName));
        if (strcmp(clsName, "infected", false) == 0 ||
            strcmp(clsName, "witch", false) == 0)
            return false;
    }

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

/**
* 获取 charger 目标的威胁类型
* @param client 客户端索引
* @param target 目标索引
* @return TargetThreatType, 威胁类型
**/
stock TargetThreatType getTargetThreatType(int client, int target) {
    if (!isAiCharger(client))
        return Threat_None;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return Threat_None;

    static int weapon;
    weapon = GetEntPropEnt(target, Prop_Send, "m_hActiveWeapon");
    if (!IsValidEntity(weapon))
        return Threat_None;
    
    char clsName[64];
    GetEntityClassname(weapon, clsName, sizeof(clsName));
    if (StrContains(clsName, "shotgun", false) >= 0)
        return Threat_Shotgun;
	else if (StrContains(clsName, "melee", false) >= 0 || StrContains(clsName, "chainsaw", false) >= 0)
	{
		if (g_cvLegacyMeleeAvoid != null && !g_cvLegacyMeleeAvoid.BoolValue)
			return Threat_Normal;
		return Threat_Melee;
	}
    
    return Threat_Normal;
}

stock float angleNormalize(float angle) {
    while (angle > 180.0) angle -= 360.0;
    while (angle < -180.0) angle += 360.0;
    return angle;
}

/**
* 判断目标是否正在看着 charger
* @param client 客户端索引
* @param target 目标索引
* @param fovDeg 视野角度 (默认 60 度, 即目标的视角方向与目标到 charger 的位置向量方向夹角小于 fovDeg 即为正在看着)
* @return bool
**/
stock bool isTargetWatchingCharger(int client, int target, float fovDeg = 60.0) {
    if (!isAiCharger(client))
        return false;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;
    
    static float eyePos[3], vDir[3];
    GetClientEyePosition(client, eyePos);
    
    static float targetEyePos[3], targetEyeAng[3], vFwd[3];
    GetClientEyePosition(target, targetEyePos);
    GetClientEyeAngles(target, targetEyeAng);
    GetAngleVectors(targetEyeAng, vFwd, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(vFwd, vFwd);
    
    MakeVectorFromPoints(targetEyePos, eyePos, vDir);
    NormalizeVector(vDir, vDir);

    float dot = GetVectorDotProduct(vFwd, vDir);
    if (dot > 1.0) dot = 1.0;
    else if (dot < -1.0) dot = -1.0;
    float deg = RadToDeg(ArcCosine(dot));
    
    if (deg > fovDeg)
        return false;

    /**
    // 检测是否能够直视 charger (没有被障碍物挡住)
    static Handle hTrace;
    static bool visible;
    hTrace = TR_TraceRayFilterEx(targetEyePos, eyePos, MASK_VISIBLE, RayType_EndPoint, _TraceRayFilterNoPlayer, target);
    visible = !TR_DidHit(hTrace);
    delete hTrace;
    return visible;
    **/

    return L4D2_IsVisibleToPlayer(client, TEAM_INFECTED, TEAM_SURVIVOR, 0, targetEyePos);
}

/**
* 检查当前有几个生还者正在看着 Charger
* @param client 客户端索引
* @param target Charger 的目标索引, 一般是把它排除的, 如果需要检查目标, target 传递 INVALID_CLIENT_INDEX 即可
* @param fovDeg 视野角度 (默认 60 度)
* @return int 正在看着 Charger 的生还者数量
**/
stock int isAnySurvivorWatchingCharger(int client, int target, float fovDeg = 60.0) {
    if (!isAiCharger(client))
        return 0;

    int count = 0;
    static float pos[3], targetPos[3], dist, weaponRange, rangeModifier;
    static int weapon;
    static char clsName[32];

    for (int i = 1; i <= MaxClients; i++) {
        if (i == client || i == target)
            continue;
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;
        if (IsClientIncapped(i) || IsClientHanging(i) || IsClientPinned(i))
            continue;
        if (!isTargetWatchingCharger(client, i, fovDeg))
            continue;
        // =========================================================================
        // 对不同的武器类型进行判断
        // 1. 如果生还者拿着近战武器但是距离 charger 的距离大于 melee_range + _ai_charger3_melee_bait_maxrange.FloatValue, 那么没有威胁
        // 2. 如果生还者拿着枪械, 如果距离大于射程范围, 没有威胁
        // =========================================================================
        GetClientAbsOrigin(client, pos);
        GetClientAbsOrigin(i, targetPos);
        pos[2] = targetPos[2] = 0.0;
        dist = GetVectorDistance(pos, targetPos);

        weapon = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
        if (!IsValidEntity(weapon))
            continue;
        GetEntityClassname(weapon, clsName, sizeof(clsName));
        // 近战武器的情况
        if (L4D2_GetMeleeWeaponIndex(clsName) > -1 || strcmp(clsName[7], "chainsaw", false) == 0) {
		float meleeRange = cvMeleeRange != null ? cvMeleeRange.FloatValue : DEFAULT_MELEE_RANGE;
		if (dist > meleeRange + g_cvMeleeBaitZoneMaxRange.FloatValue)
                continue;
        }
        // 非近战武器的情况
        weaponRange = L4D2_GetFloatWeaponAttribute(clsName, L4D2FWA_Range);
        rangeModifier = L4D2_GetFloatWeaponAttribute(clsName, L4D2FWA_RangeModifier);
        if (dist > (weaponRange * rangeModifier))
            continue;
        
        count += 1;
    }
    return count;
}

stock int getClosestSurvivorAndValid(int charger, int excludeTar = -1) {
	if (!isAiCharger(charger))
		return -1;
	
	static int target;
	static float pos[3], targetPos[3];
	static ArrayList targets;
	if (!targets)
		targets = new ArrayList(2);

	GetClientAbsOrigin(charger, pos);
	for (int i = 1; i <= MaxClients; i++) {
		if (i == charger || i == excludeTar)
			continue;
		if (!IsValidSurvivor(i) || !IsPlayerAlive(i) || IsClientPinned(i) || IsClientIncapped(i) || IsClientHanging(i))
			continue;

		GetClientAbsOrigin(i, targetPos);
		targets.Set(targets.Push(GetVectorDistance(pos, targetPos)), i, 1);
	}

	if (targets.Length < 1) {
		delete targets;
		return -1;
	}

	SortADTArray(targets, Sort_Ascending, Sort_Float);
	target = targets.Get(0, 1);
	delete targets;
	return target;
}

stock bool vectorsEqual(const float vec1[3], const float vec2[3]) {
    return (vec1[0] == vec2[0] &&
            vec1[1] == vec2[1] &&
            vec1[2] == vec2[2]);
}

stock float getVectorLength2D(const float vec[3]) {
    return SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
}

stock float getVectorDistance2D(const float vec1[3], const float vec2[3]) {
    return SquareRoot(Pow(vec1[0] - vec2[0], 2.0) + Pow(vec1[1] - vec2[1], 2.0));
}

stock bool isSurvivorPinned(int client) {
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
        return false;

    // 检查是否被 Hunter 扑倒
    if (GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0) return true;
    // 检查是否被其他 Charger 携带着冲锋
    if (GetEntPropEnt(client, Prop_Send, "m_carryAttacker") > 0) return true;
    // 检查是否被其他 Charger 按在地上捶打
    if (GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0) return true;

    return false;
}

/* struct Segment
{
    CNavArea *area;									// the area along the path
    NavTraverseType how;							// how to enter this area from the previous one
    Vector pos;										// our movement goal position at this point in the path
    const CNavLadder *ladder;						// if "how" refers to a ladder, this is it
    
    SegmentType type;								// how to traverse this segment of the path
    Vector forward;									// unit vector along segment
    float length;									// length of this segment
    float distanceFromStart;						// distance of this node from the start of the path
    float curvature;								// how much the path 'curves' at this point in the XY plane (0 = none, 1 = 180 degree doubleback)

    Vector m_portalCenter;							// position of center of 'portal' between previous area and this area
    float m_portalHalfWidth;						// half width of 'portal'
}; */
void constructPathSegment(Address pPathSegment, PathSegment segment) {
    if (!pPathSegment) {
        LogError("Stocks.sp::ConstructPathSegment: pPathSegment pointer is null");
        segment.init();
        return;
    }

    segment.m_pPathSegment = pPathSegment;

    static Address pArea;
	pArea = view_as<Address>(LoadFromAddress(pPathSegment, NumberType_Int32));
    segment.m_pNavArea = pArea;

    static int traverseType, segmentType;
	traverseType = view_as<int>(LoadFromAddress(pPathSegment + view_as<Address>(4), NumberType_Int32));
    segmentType = view_as<int>(LoadFromAddress(pPathSegment + view_as<Address>(24), NumberType_Int32));
    segment.m_iNavTraverseType = traverseType;
	segment.m_SegmentType = view_as<SegmentType>(segmentType);

    // 从 pPathSegment 结构体中获取 x, y, z 坐标
	// v99 = *(float *)(v37 + 8);
	// v38 = *(float *)(v37 + 12);
	// v39 = *(float *)(v37 + 16);
    static float x, y, z;
	x = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(8), NumberType_Int32));
	y = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(12), NumberType_Int32));
	z = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(16), NumberType_Int32));
	segment.m_vecGoalPos[0] = x;
    segment.m_vecGoalPos[1] = y;
    segment.m_vecGoalPos[2] = z;

    x = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(28), NumberType_Int32));
	y = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(32), NumberType_Int32));
	z = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(36), NumberType_Int32));
	segment.m_vecForward[0] = x;
    segment.m_vecForward[1] = y;
    segment.m_vecForward[2] = z;

    static float length, dist;
	length = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(40), NumberType_Int32));
	dist = view_as<float>(LoadFromAddress(pPathSegment + view_as<Address>(44), NumberType_Int32));
	segment.m_flLength = length;
    segment.m_flDistFromStart = dist;
}

stock bool getNextPathSegment(Address pPath, Address pCurSeg, PathSegment segemnt) {
    if (!pPath || !pCurSeg)
        return false;
    
    Address pNextSeg = view_as<Address>(SDKCall(g_hSdkPathNextSegment, pPath, pCurSeg));
    if (!pNextSeg)
        return false;
    constructPathSegment(pNextSeg, segemnt);
    return true;
}

stock int getLookAheadGoalPos(int client, const float pos[3], float maxDist, float outPos[3], int maxDepth = 10) {
	// A: iterSeg, B: nextSeg
    static PathSegment A, B;
    A = g_AiChargers[client].m_PathSegment;
    
    // 如果 current path segment 无效, 返回 false
    if (!A.m_pPathSegment) {
		return false;
	}

	static float vPos2D[3];
	vPos2D = pos;
	vPos2D[2] = 0.0;

	// ============================================================
	// 使用几何投影法, 找到真正的前向节点
	// ============================================================
	for (int i = 0; i < maxDepth; i++) {
		// 先尝试获取下一个节点, 如果没有下一个节点, 说明 iterSeg 为当前路径的终点, 跳出循环
		if (!getNextPathSegment(g_AiChargers[client].m_pPathFollower, A.m_pPathSegment, B)) {
			break;
		}

		// 获取 2D 节点坐标, 用于计算投影
		static float curGoal2D[3], nextGoal2D[3];
		curGoal2D = A.m_vecGoalPos;
		nextGoal2D = B.m_vecGoalPos;
		curGoal2D[2] = 0.0;
		nextGoal2D[2] = 0.0;

		// 获取 current goal pos 到 next goal pos 的向量 x
		// 获取 current goal pos 到 client pos 的向量 y
		static float vCur2Next[3], vCur2Client[3], lenSqrAB;
		MakeVectorFromPoints(curGoal2D, nextGoal2D, vCur2Next);
		MakeVectorFromPoints(curGoal2D, vPos2D, vCur2Client);
		lenSqrAB = GetVectorDotProduct(vCur2Next, vCur2Next);
		
		if (lenSqrAB <= 0.0) {
			A = B;
			continue;
		}

		// 计算 y 到 x 向量的投影
		static float proj;
		proj = GetVectorDotProduct(vCur2Next, vCur2Client) / lenSqrAB;

		// 如果 y 向量在 x 向量上的投影长过 x 向量, 说明当前 path segment 完全在 client 身后, 继续推进检测下一段 path segment
		if (proj >= 1.0) {
			A = B;
			continue;
		} else if (proj >= 0.5) {
			// 若 y 向量在 x 向量上的投影超过 x 向量长度一半, 说明 client 已经走了当前 path segment 的一半, 找一个以当前 client 速度一次可达的最远节点
			A = B;
			break;
		} else {
			// 若投影小于等于 0, 说明当前节点依旧是有效的起步点, 找一个以当前 client 速度一次可达的最远节点
			break;
		}
	}

	// ============================================================
	// 以上一步的起点为基础, 外推, 找一个以当前 client 速度一次
	// 可达且可见 (client pos 到目标节点中间没有障碍物遮挡, 不会阻止连跳) 的最远节点
	// ============================================================
	static float lastVisPos[3];
	lastVisPos = A.m_vecGoalPos;

	static float vStart[3];
	L4D_GetEntityWorldSpaceCenter(client, vStart);

	static int fwdCount;
	fwdCount = 0;

	for (int i = 0; i < maxDepth; i++) { 
		static float vGoal[3], vEnd[3];
		vGoal = A.m_vecGoalPos;

		vEnd = vGoal;
		vEnd[2] += 36.0;
		
		static Handle hTrace;
        static bool isHit;
		hTrace = TR_TraceHullFilterEx(vStart, vEnd, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, _TraceWallFilter);
        isHit = TR_DidHit(hTrace);
        delete hTrace;

        // 如果视线被墙挡住, 前面的路无法直接一次连跳过去, 跳出循环, 返回最远的可见节点
        if (isHit) {
            break;
        }

		// 该节点并没有被遮挡, 立即记录为最优节点, 增加检查节点数量
		lastVisPos = vGoal;
		fwdCount += 1;

		static float dist2CurGoal;
		dist2CurGoal = getVectorDistance2D(vStart, vGoal);
		// 到达以当前速度最远可达的距离, 这个节点以当前速度一次连跳不可达, 跳出循环
		if (dist2CurGoal >= maxDist) {
			break;
		}

        // 如果当前节点的高度大于 client pos + MaxJumpHeight, 说明一跳上不去, 跳出循环
        if (vGoal[2] - pos[2] > JUMP_HEIGHT) {
            break;
        }

		// 如果这个节点以当前速度可达, 继续遍历下一个节点
		// 如果下一个节点没有了, 说明当前节点就是路径的最后一个节点, 跳出循环
		if (!getNextPathSegment(g_AiChargers[client].m_pPathFollower, A.m_pPathSegment, A)) {
			break;
		}
	}

	// 如果前向检查节点没有任何一个以当前速度一次跳跃可达的节点, 说明 client 当前位置到下一个节点中间存在障碍物, 不允许连跳
	if (fwdCount < 1) {
		return false;
	}

	outPos = lastVisPos;
	return true;
}

/**
* 从 PathFollower 对象中读出 m_minLookAheadDistance 成员
* @param pPathFollower 指向 PathFollower 对象的指针
* @return float
**/
stock float getMinLookAheadDist(Address pPathFollower) {
    if (!pPathFollower)
        return -1.0;

    // *((float *)this + 4567) = a2;
    return view_as<float>(LoadFromAddress(pPathFollower + view_as<Address>(4 * 4567), NumberType_Int32));
}

/**
 * 计算客户端的剩余滞空时间
 * @param client  客户端索引
 * @param pos     客户端当前坐标
 * @param vVel    m_vecAbsVelocity
 * @return float
 */
stock float calcRemainingAirTime(const float pos[3], const float vVel[3]) {
    float vEnd[3];
    vEnd = pos;
    vEnd[2] -= 9999.0;

    Handle hTrace = TR_TraceRayFilterEx(pos, vEnd, MASK_PLAYERSOLID, RayType_Infinite, _TraceWallFilter);

    float H = JUMP_HEIGHT;
    if (TR_DidHit(hTrace)) {
        float vHitPos[3];
        TR_GetEndPosition(vHitPos, hTrace);
        H = pos[2] - vHitPos[2];
    }
    delete hTrace;

    /*
        如果射线没有打到任何东西, 说明下面是深渊, 使用什么 H 都无所谓了
    */
    if (H < 0.0) {
        H = 0.0;
    }

    float gravity = !cvGravity ? DEFAULT_GRAVITY : cvGravity.FloatValue;

    float root = (vVel[2] * vVel[2]) + (2.0 * gravity * H);
    if (root < 0.0) {
        root = 0.0;
    }

    // 计算落地时间, 设置最小值和最大值
    float t = (vVel[2] + SquareRoot(root)) / gravity;
    if (t < 0.1) {
        t = 0.1;
    }
    if (t > 3.0) {
        t = 3.0;
    }

    return t;
}

#define DIRECT_GROUND_SAMPLE_STEP   50.0    // hasPotentialGap2 函数的从 start 到 end 路线上的采样步长
#define DIRECT_MAX_LOCAL_STEP_UP    56.0    // 后续采样点以第一个采样点的地面高度向上或者向下 (STEP_UP + margin) 开始向下射线
#define DIRECT_GROUND_TRACE_MARGIN  10.0
#define DIRECT_MIN_GROUND_NORMAL_Z  0.20

stock bool hasPotentialGap2(int client, const float start[3], const float end[3], float maxLocalDrop) {
    if (maxLocalDrop <= 0.0)
        return true;
    
    // 从 start 到 end 只计算水平路线
    static float routeDir[3];
    MakeVectorFromPoints(start, end, routeDir);
    routeDir[2] = 0.0;

    // NormalizeVector 返回归一化之前的向量长度, 同时将 routeDir 转化为单位方向向量
    static float routeDist;
    routeDist = NormalizeVector(routeDir, routeDir);

    if (routeDist <= 0.0)
        return false;

    int sampleCount = RoundToCeil(routeDist / DIRECT_GROUND_SAMPLE_STEP);
    if (sampleCount < 1) {
        sampleCount = 1;
    }

    static float previousGroundZ;
    bool hasPreviousGround;

    previousGroundZ = start[2];
    hasPreviousGround = false;

    for (int sampleIndex = 0; sampleIndex <= sampleCount; sampleIndex++) {
        static float sampleFraction;
        sampleFraction = float(sampleIndex) / float(sampleCount);

        static float samplePos[3];
        samplePos[0] = start[0] + routeDir[0] * routeDist * sampleFraction;
        samplePos[1] = start[1] + routeDir[1] * routeDist * sampleFraction;
        samplePos[2] = start[2];

        /*
        * 第一个采样点以 start[2] 高度为基准, 后续采样点以上一个真实地面高度为基准
        * 这样可以允许长斜坡之间存在很大的累计高度差, 比如中间有个坑这种, 但不允许相邻采样点之间高度差断崖式下降或者上升
        */
        static float referenceGroundZ;
        referenceGroundZ = hasPreviousGround ? previousGroundZ : start[2];

        static float currentGroundZ;
        if (!tryFindGroundAtRouteSample(client, samplePos, referenceGroundZ, hasPreviousGround, maxLocalDrop, currentGroundZ)) {
            return true;
        }

        if (hasPreviousGround) {
            if (isLocalGroundHeightDiscontinuous(previousGroundZ, currentGroundZ, maxLocalDrop)) {
                return true;
            }
        }

        previousGroundZ = currentGroundZ;
        hasPreviousGround = true;
    }

    return false;
}

stock bool tryFindGroundAtRouteSample(int client, const float samplePos[3], float referenceGroundZ, bool hasPreviousGround, float maxLocalDrop, float& outGroundZ) {
    static float traceStart[3], traceEnd[3];

    traceStart[0] = samplePos[0];
    traceStart[1] = samplePos[1];

    traceEnd[0] = samplePos[0];
    traceEnd[1] = samplePos[1];

    /*
    * 第一个采样点, Charger 通常已经在地面上, 只需要从 start 上方向下寻找地面
    * 后续采样点, 允许当前地面比上一个地面高 DIRECT_MAX_LOCAL_STEP_UP, 如果上升超过这个范围, 要么 trace 失败, 要么后续的高度差检查会拒绝
    */
    if (hasPreviousGround) {
        traceStart[2] = referenceGroundZ + (DIRECT_MAX_LOCAL_STEP_UP + DIRECT_GROUND_TRACE_MARGIN);
    } else {
        traceStart[2] = referenceGroundZ + DIRECT_GROUND_TRACE_MARGIN;
    }

    /*
    * 最低只允许下降 max local drop, 如果这个范围内找不到地面, 认为存在 Gap 或者断崖
    */
    traceEnd[2] = referenceGroundZ - maxLocalDrop;

    static Handle hTrace;
    hTrace = TR_TraceRayFilterEx(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, _TraceWallFilter, client);

    if (!TR_DidHit(hTrace) || TR_StartSolid(hTrace)) {
        delete hTrace;
        return false;
    }

    static float groundPos[3], groundNormal[3];
    TR_GetEndPosition(groundPos, hTrace);
    TR_GetPlaneNormal(hTrace, groundNormal);

    delete hTrace;

    /*
    * GroundNormal 越接近于 1, 说明越接近水平地面, 如果 GroundNormal 接近于 0, 则说明地面倾斜严重, 无法站立
    */
    if (groundNormal[2] < DIRECT_MIN_GROUND_NORMAL_Z) {
        return false;
    }

    outGroundZ = groundPos[2];
    return true;
}

stock bool isLocalGroundHeightDiscontinuous(float previousGroundZ, float currentGroundZ, float maxLocalDrop) {
    static float deltaZ;
    deltaZ = currentGroundZ - previousGroundZ;

    if (deltaZ > DIRECT_MAX_LOCAL_STEP_UP + 1.0) {
        return true;
    }

    if (deltaZ < -maxLocalDrop - 1.0) {
        return true;
    }

    return false;
}

stock float calcVectorAngle(const float v1[3], const float v2[3], bool ignoreZ = true) {
    if ((v1[0] == 0.0 && v1[1] == 0.0 && v1[2] == 0.0) ||
        (v2[0] == 0.0 && v2[1] == 0.0 && v2[2] == 0.0))
        return 0.0;
    
    static float v1_cpy[3], v2_cpy[3];
    v1_cpy = v1;
    v2_cpy = v2;

    if (ignoreZ) {
        v1_cpy[2] = 0.0;
        v2_cpy[2] = 0.0;
    }

    NormalizeVector(v1_cpy, v1_cpy);
    NormalizeVector(v2_cpy, v2_cpy);
    static float dot;
    dot = GetVectorDotProduct(v1_cpy, v2_cpy);
    if (dot > 1.0) dot = 1.0;
    else if (dot < -1.0) dot = -1.0;
    return RadToDeg(ArcCosine(dot));
}

/**
* 从 Client Index 获取该 Bot 的 ILocomotion 指针
* @param client 客户端索引
* @return Address ILocomotion 指针地址, 无效返回 Address Null
**/
stock Address clientGetLocomotionInterface(int client) {
    if (!IsValidClient(client))
        return Address_Null;
    
    Address pEntity = GetEntityAddress(client);
    if (!pEntity)
        return Address_Null;
    
    Address pNextBot = view_as<Address>(SDKCall(g_hSdkMyNextBotPointer, pEntity));
    if (!pNextBot)
        return Address_Null;
    
    Address pLocomotion = view_as<Address>(SDKCall(g_hSdkGetLocomotionInterface, pNextBot));
    if (!pLocomotion)
        return Address_Null;
    
    return pLocomotion;
}

/**
* 检查 start 坐标和 end 坐标中间有没有纵向高差超过 MaxJumpHeight 的下坠, 有则返回 true, 无返回 false
* 底层采用从 start 到 end 进行步进然后向下作射线检测, 检测是否有超过 MaxJumpHeight 的高差
* @param start 起点坐标
* @param end 终点坐标
* @return bool
**/
stock bool hasPotentialGap(Address pLocomotion, const float start[3], const float end[3]) {
    if (!pLocomotion)
        return false;

    /*
        bool ILocomotion::HasPotentialGap( const Vector &from, const Vector &desiredTo, float *fraction ) const
        最后一个参数 fraction 表示射线检测的进度, 射线检测到 has gap, 这个 fraction 表示从 start 到高度差的距离占 start 到 end 的距离的百分比
    */
    float fraction = 0.0;

    return SDKCall(g_hSdkHasPotentialGap, pLocomotion, start, end, fraction);
}

/**
* 调试输出 PathSegment 结构体信息
* @param segment PathSegment 结构体
* @return void
**/
stock void debugPrintPathSegment(PathSegment segment) {
    PrintToConsoleAll("\n===== PathSegment Info =====");
    PrintToConsoleAll("\tthis pointer: 0x%X", segment.m_pPathSegment);
    PrintToConsoleAll("\tNavArea: 0x%X", segment.m_pNavArea);
    PrintToConsoleAll("\tNavTraverseType: %d", segment.m_iNavTraverseType);
    PrintToConsoleAll("\tSegmentType: %d", segment.m_SegmentType);
    PrintToConsoleAll("\tGoal Pos: (%f, %f, %f)", segment.m_vecGoalPos[0], segment.m_vecGoalPos[1], segment.m_vecGoalPos[2]);
    PrintToConsoleAll("\tForward: (%f, %f, %f)", segment.m_vecForward[0], segment.m_vecForward[1], segment.m_vecForward[2]);
    PrintToConsoleAll("\tLength: %f", segment.m_flLength);
    PrintToConsoleAll("\tDistFromStart: %f", segment.m_flDistFromStart);
    PrintToConsoleAll("\n");
}
