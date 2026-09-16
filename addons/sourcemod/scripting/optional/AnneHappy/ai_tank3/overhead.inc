#if defined _ai_tank3_overhead_included
    #endinput
#endif
#define _ai_tank3_overhead_included

// =========================================================================
// 骑头：生还者站在 Tank 头上，或站在嵌进 Tank 模型上方的平台上
// =========================================================================

void Riding_Clear(int tank)
{
    g_Tank[tank].ridingUser = 0;
    g_Tank[tank].ridingStart = 0.0;
}

bool Riding_OverlapAABB2D(int first, int second, float slack)
{
    float firstPos[3], secondPos[3], firstMins[3], firstMaxs[3], secondMins[3], secondMaxs[3];
    GetClientAbsOrigin(first, firstPos);
    GetClientAbsOrigin(second, secondPos);
    GetClientMins(first, firstMins);
    GetClientMaxs(first, firstMaxs);
    GetClientMins(second, secondMins);
    GetClientMaxs(second, secondMaxs);

    return firstPos[0] + firstMins[0] - slack <= secondPos[0] + secondMaxs[0] &&
        firstPos[0] + firstMaxs[0] + slack >= secondPos[0] + secondMins[0] &&
        firstPos[1] + firstMins[1] - slack <= secondPos[1] + secondMaxs[1] &&
        firstPos[1] + firstMaxs[1] + slack >= secondPos[1] + secondMins[1];
}

bool Riding_Detect(int tank, int survivor)
{
    int ground = GetEntPropEnt(survivor, Prop_Send, "m_hGroundEntity");
    if (ground < 0 && !(GetEntityFlags(survivor) & FL_ONGROUND))
        return false;

    float tankPos[3], survivorPos[3];
    GetClientAbsOrigin(tank, tankPos);
    GetClientAbsOrigin(survivor, survivorPos);
    float vertical = survivorPos[2] - tankPos[2];
    if (vertical < g_cvHeadBlockRideVerticalMin.FloatValue || vertical > g_cvHeadBlockRideVerticalMax.FloatValue)
        return false;
    if (AIPathMovement_GetDistance2D(tankPos, survivorPos) > g_cvHeadBlockRideHorizontal.FloatValue)
        return false;

    // 直接站在 Tank 上时相信引擎的接地实体；站在箱子/平台上时看水平碰撞投影是否重叠
    if (ground == tank)
        return true;
    return Riding_OverlapAABB2D(tank, survivor, RIDE_AABB_SLACK);
}

bool Riding_IsRiding(int tank, int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue || !g_cvHeadBlockRideEnable.BoolValue)
        return false;
    if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || IsClientIncapped(survivor) || IsClientHanging(survivor))
        return false;

    float now = GetEngineTime();
    int userId = GetClientUserId(survivor);
    if (g_Tank[tank].rideCheckUser[survivor] == userId && now - g_Tank[tank].rideCheckTime[survivor] < RIDE_CHECK_CACHE)
        return g_Tank[tank].rideCheckResult[survivor];

    bool riding = Riding_Detect(tank, survivor);
    g_Tank[tank].rideCheckUser[survivor] = userId;
    g_Tank[tank].rideCheckTime[survivor] = now;
    g_Tank[tank].rideCheckResult[survivor] = riding;
    return riding;
}

int Riding_FindRider(int tank)
{
    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);

    int nearest = -1;
    float nearestDist = 0.0;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!Riding_IsRiding(tank, survivor))
            continue;

        float survivorPos[3];
        GetClientAbsOrigin(survivor, survivorPos);
        float dist = GetVectorDistance(tankPos, survivorPos);
        if (nearest == -1 || dist < nearestDist)
        {
            nearest = survivor;
            nearestDist = dist;
        }
    }
    return nearest;
}

bool Riding_CanPunch(int tank, int rider)
{
    float tankEye[3], riderChest[3];
    GetClientEyePosition(tank, tankEye);
    GetClientAbsOrigin(rider, riderChest);
    riderChest[2] += PLAYER_CHEST;

    float swingRange = g_fTankSwingRange > 0.0 ? g_fTankSwingRange : DEFAULT_SWING_RANGE;
    if (GetVectorDistance(tankEye, riderChest) > swingRange + RIDE_AABB_SLACK)
        return false;
    return clientIsVisibleToClient(tank, rider);
}

Action Riding_Update(int tank, int rider, int &buttons, float now)
{
    HeadBlock_Reset(tank);
    if (g_Tank[tank].throwing)
        return Plugin_Continue;

    int oldButtons = buttons;
    buttons &= ~(IN_ATTACK | IN_ATTACK2);

    int riderUser = GetClientUserId(rider);
    if (Riding_CanPunch(tank, rider))
    {
        g_Tank[tank].ridingUser = riderUser;
        g_Tank[tank].ridingStart = now;
        if (g_Tank[tank].rockReason == TankRock_Riding && g_Tank[tank].rockUser == riderUser)
            RockPlan_End(tank, "rider punchable");
        if (Combat_IsClawReady(tank))
            buttons |= IN_ATTACK;
    }
    else
    {
        // 平台或地形挡住拳路时才开始计时，超时后原地投石
        if (g_Tank[tank].ridingUser != riderUser)
        {
            g_Tank[tank].ridingUser = riderUser;
            g_Tank[tank].ridingStart = now;
        }
        float rockTime = g_cvHeadBlockRideRockTime.FloatValue;
        if (rockTime > 0.0 && now - g_Tank[tank].ridingStart >= rockTime)
            RockPlan_Start(tank, TankRock_Riding, rider, now);
    }
    return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
}

// =========================================================================
// 高台停滞：目标在头顶够不着的位置，Tank 在下面原地打转
// =========================================================================

void HeadBlock_Reset(int tank)
{
    g_Tank[tank].headBlockUser = 0;
    g_Tank[tank].headBlockStart = 0.0;
}

bool HeadBlock_Update(int tank, int target, const float tankPos[3], const float targetPos[3], float now)
{
    if (!g_cvHeadBlockEnable.BoolValue || IsClientIncapped(target) || IsClientHanging(target) ||
        Target_IsIgnored(tank, target) || Riding_IsRiding(tank, target))
    {
        HeadBlock_Reset(tank);
        return false;
    }

    if (targetPos[2] - tankPos[2] < g_cvHeadBlockVertical.FloatValue ||
        AIPathMovement_GetDistance2D(tankPos, targetPos) > g_cvHeadBlockHorizontal.FloatValue)
    {
        HeadBlock_Reset(tank);
        return false;
    }

    int userId = GetClientUserId(target);
    if (g_Tank[tank].headBlockUser != userId || g_Tank[tank].headBlockStart <= 0.0)
    {
        g_Tank[tank].headBlockUser = userId;
        g_Tank[tank].headBlockStart = now;
        g_Tank[tank].headBlockOrigin = tankPos;
        return false;
    }

    if (GetVectorDistance(tankPos, g_Tank[tank].headBlockOrigin) >= HEAD_BLOCK_PROGRESS_DIST)
    {
        g_Tank[tank].headBlockStart = now;
        g_Tank[tank].headBlockOrigin = tankPos;
        return false;
    }

    // 路径能经梯子/攀爬走到目标时这是正常的上楼路线，只有长时间原地不动才算卡住
    float threshold = g_cvHeadBlockTime.FloatValue;
    if (g_TankPath[tank].fresh && g_TankPath[tank].routeUp && g_TankPath[tank].reachesTarget)
        threshold *= HEAD_BLOCK_ROUTE_UP_MULT;
    if (now - g_Tank[tank].headBlockStart < threshold)
        return false;

    HeadBlock_Reset(tank);
    return true;
}

void HeadBlock_OnFlagged(int tank, int blocked, float now)
{
    Target_Ignore(tank, blocked, now + g_cvHeadBlockIgnoreTime.FloatValue);
    g_Tank[tank].victimSince = 0.0;
    g_Tank[tank].victimFreezeUntil = 0.0;

    if (Target_HasAlternative(tank, blocked))
    {
        if (g_Tank[tank].rockReason == TankRock_HeadBlock)
            RockPlan_End(tank, "switching victim", true);
        if (log != null)
            log.debugAll("%N ignores overhead %N, switching victim", tank, blocked);
        return;
    }

    RockPlan_Start(tank, TankRock_HeadBlock, blocked, now);
    if (log != null)
        log.debugAll("%N ignores overhead %N, no alternative victim, planning rock", tank, blocked);
}

// =========================================================================
// 强制投石计划
// =========================================================================

void RockPlan_Start(int tank, TankRockReason reason, int survivor, float now)
{
    if (!g_cvHeadBlockEnable.BoolValue || !IsValidSurvivor(survivor) || !IsPlayerAlive(survivor))
        return;

    int userId = GetClientUserId(survivor);
    if (g_Tank[tank].rockReason == reason && g_Tank[tank].rockUser == userId && g_Tank[tank].rockUntil > now)
        return;
    if (g_Tank[tank].rockReason != TankRock_None)
        RockPlan_End(tank, "replaced", true);

    g_Tank[tank].rockReason = reason;
    g_Tank[tank].rockUser = userId;
    g_Tank[tank].rockUntil = now + g_cvHeadBlockForceRockTime.FloatValue;
    g_Tank[tank].retreatAttempts = 0;
    g_Tank[tank].retreatLastIssue = 0.0;
    if (log != null)
        log.debugAll("%N rock plan %d at %N", tank, view_as<int>(reason), survivor);
}

// 只清状态不发命令，动画钩子等回调里用；残留的 MOVE 由看门狗下一帧 RESET
void RockPlan_Clear(int tank, bool keepAim)
{
    g_Tank[tank].rockReason = TankRock_None;
    g_Tank[tank].rockUser = 0;
    g_Tank[tank].rockUntil = 0.0;
    g_Tank[tank].retreatAttempts = 0;
    g_Tank[tank].retreatLastIssue = 0.0;
    if (!keepAim)
    {
        g_Tank[tank].rockAimUser = 0;
        g_Tank[tank].rockPendingUntil = 0.0;
    }
}

void RockPlan_End(int tank, const char[] reason, bool keepAim = false)
{
    RockPlan_Clear(tank, keepAim);
    Command_Reset(tank, reason);
}

void RockPlan_PressThrow(int tank, int &buttons, int target, float now)
{
    buttons |= IN_ATTACK2;
    g_Tank[tank].rockAimUser = GetClientUserId(target);
    g_Tank[tank].rockPendingUntil = now + ROCK_PENDING_HOLD_TIME;
}

bool RockPlan_CanSee(int tank, int target)
{
    if (clientIsVisibleToClient(tank, target))
        return true;

    float eye[3];
    GetClientEyePosition(target, eye);
    return L4D2_IsVisibleToPlayer(tank, TEAM_INFECTED, 0, 0, eye);
}

void RockPlan_TryThrow(int tank, int &buttons, int target, const float tankPos[3], const float targetPos[3], float now)
{
    float throwMax = g_cvThrowMaxDist.FloatValue;
    if (throwMax > 0.0 && GetVectorDistance(tankPos, targetPos) > throwMax)
        return;
    if (RockPlan_CanSee(tank, target))
        RockPlan_PressThrow(tank, buttons, target, now);
}

bool RockPlan_FindRetreatGoal(int tank, const float tankPos[3], const float targetPos[3], float horizontal, float needDistance, float goal[3])
{
    float awayX = tankPos[0] - targetPos[0];
    float awayY = tankPos[1] - targetPos[1];
    if (awayX * awayX + awayY * awayY < 1.0)
    {
        float angles[3], forwardVec[3];
        GetClientEyeAngles(tank, angles);
        angles[0] = 0.0;
        angles[2] = 0.0;
        GetAngleVectors(angles, forwardVec, NULL_VECTOR, NULL_VECTOR);
        awayX = -forwardVec[0];
        awayY = -forwardVec[1];
    }

    Address tankArea = view_as<Address>(L4D_GetLastKnownArea(tank));
    if (tankArea == Address_Null)
        return false;

    float baseYaw = RadToDeg(ArcTangent2(awayY, awayX));
    float retreatDistance = needDistance - horizontal + FORCE_ROCK_RETREAT_MARGIN;
    for (int i = 0; i < sizeof(g_fRetreatYawOffsets); i++)
    {
        float yaw = DegToRad(baseYaw + g_fRetreatYawOffsets[i]);
        float candidate[3];
        candidate[0] = tankPos[0] + Cosine(yaw) * retreatDistance;
        candidate[1] = tankPos[1] + Sine(yaw) * retreatDistance;
        candidate[2] = tankPos[2];

        Address area = view_as<Address>(L4D_GetNearestNavArea(candidate, RETREAT_NAV_SEARCH_DIST, false, false, true, TEAM_INFECTED));
        if (area == Address_Null)
            continue;

        float center[3];
        L4D_GetNavAreaCenter(area, center);
        if (FloatAbs(center[2] - tankPos[2]) > RETREAT_MAX_Z_DIFF)
            continue;
        if (AIPathMovement_GetDistance2D(center, targetPos) < horizontal + FORCE_ROCK_MIN_HORIZONTAL)
            continue;
        if (Ladder_FindNear(center, RETREAT_LADDER_CLEARANCE, LADDER_Z_TOLERANCE) > 0)
            continue;

        // 有长度上限的可达性检查：绕一大圈才到的点不要，走不到的点也不会让寻路翻遍整张 nav
        float maxTravel = AIPathMovement_GetDistance2D(tankPos, center) * RETREAT_TRAVEL_RATIO + 100.0;
        if (!L4D2_NavAreaBuildPath(tankArea, area, maxTravel, TEAM_INFECTED, false))
            continue;

        goal = center;
        return true;
    }
    return false;
}

Action RockPlan_Update(int tank, int &buttons, const float tankPos[3], bool onGround, bool ladderZone, bool &holdMovement, float now)
{
    holdMovement = false;
    if (g_Tank[tank].rockReason == TankRock_None)
        return Plugin_Continue;
    if (!g_cvHeadBlockEnable.BoolValue)
    {
        RockPlan_End(tank, "disabled");
        return Plugin_Continue;
    }
    if (g_Tank[tank].throwing)
        return Plugin_Continue;
    if (g_Tank[tank].rockUntil <= now)
    {
        RockPlan_End(tank, "expired");
        return Plugin_Continue;
    }

    int target = GetClientOfUserId(g_Tank[tank].rockUser);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
    {
        RockPlan_End(tank, "target gone");
        return Plugin_Continue;
    }

    float targetPos[3];
    GetClientAbsOrigin(target, targetPos);
    float horizontal = AIPathMovement_GetDistance2D(tankPos, targetPos);
    float vertical = FloatAbs(targetPos[2] - tankPos[2]);
    float releaseHoriz = g_cvHeadBlockForceRockReleaseHoriz.FloatValue;
    float releaseVert = g_cvHeadBlockForceRockReleaseVert.FloatValue;
    if ((releaseHoriz > 0.0 && horizontal > releaseHoriz) || (releaseVert > 0.0 && vertical > releaseVert))
    {
        RockPlan_End(tank, "target left");
        return Plugin_Continue;
    }

    int oldButtons = buttons;
    if (g_Tank[tank].rockReason == TankRock_Riding)
    {
        if (!Riding_IsRiding(tank, target))
        {
            RockPlan_End(tank, "rider left");
            return Plugin_Continue;
        }
        RockPlan_PressThrow(tank, buttons, target, now);
        return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
    }

    float needDistance = g_cvHeadBlockForceRockRange.FloatValue;
    if (needDistance < FORCE_ROCK_MIN_HORIZONTAL)
        needDistance = FORCE_ROCK_MIN_HORIZONTAL;

    if (horizontal >= needDistance)
    {
        Command_Reset(tank, "retreat distance reached");
        RockPlan_TryThrow(tank, buttons, target, tankPos, targetPos, now);
        return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
    }

    if (g_Tank[tank].moveActive)
    {
        if (!ladderZone)
        {
            buttons &= ~(IN_ATTACK | IN_ATTACK2);
            holdMovement = true;
            return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
        }
        Command_Reset(tank, "retreat entered ladder zone");
    }

    // 梯子口/空中不撤：MOVE 会把 Tank 从上梯路线上拽走
    if (onGround && !ladderZone && g_Tank[tank].retreatAttempts < RETREAT_MAX_ATTEMPTS &&
        now - g_Tank[tank].retreatLastIssue >= RETREAT_RETRY_INTERVAL)
    {
        g_Tank[tank].retreatLastIssue = now;
        float goal[3];
        if (RockPlan_FindRetreatGoal(tank, tankPos, targetPos, horizontal, needDistance, goal))
        {
            g_Tank[tank].retreatAttempts++;
            Command_IssueMove(tank, goal);
            buttons &= ~(IN_ATTACK | IN_ATTACK2);
            holdMovement = true;
            return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
        }
        // 找不到撤离点就别每秒再找一遍
        g_Tank[tank].retreatAttempts = RETREAT_MAX_ATTEMPTS;
    }

    // 撤不开时水平距离够就原地投
    if (horizontal >= FORCE_ROCK_MIN_HORIZONTAL)
        RockPlan_TryThrow(tank, buttons, target, tankPos, targetPos, now);
    return buttons != oldButtons ? Plugin_Changed : Plugin_Continue;
}
