#if defined _ai_tank3_movement_included
    #endinput
#endif
#define _ai_tank3_movement_included

// =========================================================================
// 移动：连跳、空中修正、梯子让行
// =========================================================================

void Movement_Reset(int tank)
{
    g_Tank[tank].hopMode = TankHop_None;
    g_Tank[tank].nextAirThink = 0.0;
    g_Tank[tank].hopStrafeYaw = 0.0;
    AIPathMovement_Reset(tank);
}

float Movement_GetRunSpeed(int tank)
{
    float speed = GetEntPropFloat(tank, Prop_Send, "m_flMaxspeed");
    return speed > 0.0 ? speed : DEFAULT_TANK_RUN_SPEED;
}

// 梯子窗口：有路径快照时只看“路径上马上要爬的梯子”，从不相干的梯子旁边经过照常连跳；
// 快照不可用时退回按梯子实体 / nav 梯子连接判断
bool Movement_IsLadderZone(int tank, const float pos[3])
{
    if (!g_cvLadderNearbyDisable.BoolValue)
        return false;
    if (g_TankPath[tank].fresh)
        return g_TankPath[tank].ladderDist >= 0.0 && g_TankPath[tank].ladderDist <= g_cvLadderNearbyRadius.FloatValue;
    return Ladder_IsNearPhysical(tank, pos);
}

// 连跳速度冲进梯子口会越过上梯点或撞墙弹开，NextBot 的上梯对准要反复重来
void Movement_BleedSpeed(int tank)
{
    float velocity[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", velocity);
    float runSpeed = Movement_GetRunSpeed(tank);
    float speed = AIPathMovement_GetHorizontalSpeed(velocity);
    if (speed <= runSpeed * LADDER_SPEED_BLEED_RATIO)
        return;

    float scale = runSpeed / speed;
    velocity[0] *= scale;
    velocity[1] *= scale;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, velocity);
}

// 在梯子上把俯仰拉平、朝向对准梯面，减轻原版“爬梯时抬头看人然后掉下来”的循环
bool Movement_LockLadderLook(int tank, const float pos[3], float angles[3])
{
    float center[3];
    center = pos;
    center[2] += HULL_CENTER_HEIGHT;
    int ladder = Ladder_FindNear(center, LADDER_LOOK_MARGIN, LADDER_LOOK_Z_TOLERANCE);
    if (ladder <= 0 || !HasEntProp(ladder, Prop_Send, "m_climbableNormal"))
        return false;

    float normal[3];
    GetEntPropVector(ladder, Prop_Send, "m_climbableNormal", normal);
    if (GetVectorLength(normal) <= 0.01)
        return false;

    float desiredYaw = RadToDeg(ArcTangent2(-normal[1], -normal[0]));
    float yawDelta = angles[1] - desiredYaw;
    while (yawDelta > 180.0)
        yawDelta -= 360.0;
    while (yawDelta < -180.0)
        yawDelta += 360.0;
    if (FloatAbs(angles[0]) < LADDER_LOOK_ALIGN_DEG && FloatAbs(yawDelta) < LADDER_LOOK_ALIGN_DEG)
        return false;

    angles[0] = 0.0;
    angles[1] = desiredYaw;
    angles[2] = 0.0;
    TeleportEntity(tank, NULL_VECTOR, angles, NULL_VECTOR);
    return true;
}

// 1.x 的叠加式推速：前/后优先，没有独占前后键时继承原生左右按键的侧向推力。
void Movement_AddLegacyImpulse(int buttons, const float velocity[3], const float direction[3], float impulse, float output[3])
{
    output[0] = velocity[0];
    output[1] = velocity[1];
    output[2] = velocity[2];

    bool forwardOnly = (buttons & IN_FORWARD) && !(buttons & IN_BACK);
    bool backOnly = (buttons & IN_BACK) && !(buttons & IN_FORWARD);
    if (forwardOnly)
    {
        output[0] += direction[0] * impulse;
        output[1] += direction[1] * impulse;
    }
    else if (backOnly)
    {
        float along[3];
        along = velocity;
        if (AIPathMovement_NormalizeHorizontal(along))
        {
            output[0] += along[0] * impulse;
            output[1] += along[1] * impulse;
        }
    }
    else
    {
        bool leftOnly = (buttons & IN_MOVELEFT) && !(buttons & IN_MOVERIGHT);
        bool rightOnly = (buttons & IN_MOVERIGHT) && !(buttons & IN_MOVELEFT);
        if (leftOnly || rightOnly)
        {
            float side = rightOnly ? 1.0 : -1.0;
            // Source 的右向量在 yaw=0 时指向 -Y。
            output[0] += direction[1] * impulse * side;
            output[1] -= direction[0] * impulse * side;
        }
    }
}

bool Movement_CanDirectChase(int tank, const float pos[3], const float targetPos[3], bool visible, bool hasLook, const float lookGoal[3])
{
    if (!visible || FloatAbs(targetPos[2] - pos[2]) > JUMP_HEIGHT)
        return false;
    if (!g_TankPath[tank].fresh)
        return true;
    if (!g_TankPath[tank].reachesTarget || !hasLook)
        return false;

    float toTarget[3], toLook[3];
    MakeVectorFromPoints(pos, targetPos, toTarget);
    MakeVectorFromPoints(pos, lookGoal, toLook);
    return AIPathMovement_VectorAngle(toLook, toTarget, true) <= g_cvDirectChaseMaxAngle.FloatValue;
}

void Movement_RotateHorizontal(const float input[3], float yaw, float output[3])
{
    float radians = DegToRad(yaw);
    float cosine = Cosine(radians), sine = Sine(radians);
    output[0] = input[0] * cosine - input[1] * sine;
    output[1] = input[0] * sine + input[1] * cosine;
    output[2] = input[2];
}

bool Movement_CanStrafe(int tank, float targetDist, float reach)
{
    return g_cvBhopStrafeAngle.FloatValue > 0.0 && targetDist > g_cvBhopStrafeMinDist.FloatValue &&
        g_TankPath[tank].fresh && (g_TankPath[tank].blockHopDist < 0.0 ||
        g_TankPath[tank].blockHopDist > reach + LADDER_HOP_MARGIN) &&
        (g_TankPath[tank].dropDist < 0.0 || g_TankPath[tank].dropDist > reach + LADDER_HOP_MARGIN);
}

Action Movement_Bhop(int tank, int &buttons, const float pos[3], int target, const float targetPos[3], float dist, bool visible)
{
    if (!g_cvTankBhop.BoolValue || L4D_IsPlayerStaggering(tank) || GetEntProp(tank, Prop_Data, "m_nWaterLevel") > 1)
    {
        Movement_Reset(tank);
        return Plugin_Continue;
    }

    bool onGround = IsClientOnGround(tank);
    float velocity[3];
    GetEntPropVector(tank, Prop_Data, "m_vecAbsVelocity", velocity);
    float speed = AIPathMovement_GetHorizontalSpeed(velocity);
    if (speed < g_cvBhopMinSpeed.FloatValue || dist < g_cvBhopMinDist.FloatValue || dist > g_cvBhopMaxDist.FloatValue)
    {
        if (onGround)
            Movement_Reset(tank);
        return Plugin_Continue;
    }

    if (onGround)
        return Movement_GroundHop(tank, buttons, pos, velocity, speed, target, targetPos, visible);
    return Movement_AirControl(tank, buttons, pos, velocity, speed, targetPos, dist, visible);
}

Action Movement_GroundHop(int tank, int &buttons, const float pos[3], const float velocity[3], float speed, int target, const float targetPos[3], bool visible)
{
    // 落地先结束上一跳的空中修正：这一帧不起跳时，NextBot 自己的跳跃/下落不会再被插件拽
    Movement_Reset(tank);

    if (!visible && !g_cvBhopNoVision.BoolValue)
        return Plugin_Continue;
    // 上次起跳安全检查因地形失败且仍在冷却期内时跳过，避免受阻时每帧重复整套 trace
    if (AIPathMovement_IsRouteCheckThrottled(tank))
        return Plugin_Continue;

    float airTime = AIPathMovement_GetJumpAirTime(JUMP_HEIGHT);
    float maxSpeed = g_cvBhopMaxSpeed.FloatValue;
    bool pathFresh = g_TankPath[tank].fresh;

    // 梯子入口/高攀爬/过深下落/跳跃间隙仍需让行；普通下落验证真实落点后保速续跳。
    if (pathFresh && g_TankPath[tank].blockHopDist >= 0.0)
    {
        float allowedReach = g_TankPath[tank].blockHopDist - LADDER_HOP_MARGIN;
        if (allowedReach < Movement_GetRunSpeed(tank) * airTime)
            return Plugin_Continue;
        float reachSpeed = allowedReach / airTime;
        if (maxSpeed <= 0.0 || reachSpeed < maxSpeed)
            maxSpeed = reachSpeed;
    }

    float horizon = speed * airTime;
    if (horizon < PATH_LOOKAHEAD_MIN_DIST)
        horizon = PATH_LOOKAHEAD_MIN_DIST;
    float lookGoal[3];
    bool hasLook = pathFresh && Path_GetLookAhead(tank, pos, horizon, g_cvPathLookAheadMaxDepth.IntValue, lookGoal, true);

    // 直追只在“看得见、同一高度、路径本身就朝着目标”时用；目标站在高台/梯子顶上时，
    // 朝目标加速只会把 Tank 拽到平台下的墙根，偏离去梯子的路线
    bool direct = Movement_CanDirectChase(tank, pos, targetPos, visible, hasLook, lookGoal);

    float hopImpulse = AIPathMovement_GetHopImpulse(tank, g_cvBhopImpulse.FloatValue, g_cvBhopFirstHopRatio.FloatValue);
    float hopVelocity[3], hopGoal[3], direction[3];
    TankHopMode mode;
    if (direct)
    {
        // 预测目标 1 秒后的位置
        float targetVelocity[3], predicted[3];
        GetEntPropVector(target, Prop_Data, "m_vecAbsVelocity", targetVelocity);
        predicted[0] = targetPos[0] + targetVelocity[0];
        predicted[1] = targetPos[1] + targetVelocity[1];
        predicted[2] = pos[2];
        MakeVectorFromPoints(pos, predicted, direction);
        if (!AIPathMovement_NormalizeHorizontal(direction))
            return Plugin_Continue;
        Movement_AddLegacyImpulse(buttons, velocity, direction, hopImpulse, hopVelocity);
        hopGoal = targetPos;
        mode = TankHop_Target;
    }
    else if (hasLook)
    {
        MakeVectorFromPoints(pos, lookGoal, direction);
        if (!AIPathMovement_NormalizeHorizontal(direction))
            return Plugin_Continue;
        hopVelocity[0] = direction[0] * (speed + hopImpulse);
        hopVelocity[1] = direction[1] * (speed + hopImpulse);
        hopVelocity[2] = velocity[2];
        hopGoal = lookGoal;
        mode = TankHop_Path;
    }
    else if (!visible && !pathFresh)
    {
        direction = velocity;
        if (!AIPathMovement_NormalizeHorizontal(direction))
            return Plugin_Continue;
        Movement_AddLegacyImpulse(buttons, velocity, direction, hopImpulse, hopVelocity);
        hopGoal[0] = pos[0] + direction[0] * horizon;
        hopGoal[1] = pos[1] + direction[1] * horizon;
        hopGoal[2] = pos[2];
        mode = TankHop_Velocity;
    }
    else
    {
        // 有路径但找不到能直飞的前瞻点，或看得见目标却不该直追：交给 NextBot 原生移动
        return Plugin_Continue;
    }

    // 起跳帧同样受最大连跳速度约束
    AIPathMovement_ClampHorizontalSpeed(hopVelocity, maxSpeed);
    bool routeSafe;
    float strafeYaw;
    int strafeSide;
    if (direct && !(buttons & IN_BACK) && Movement_CanStrafe(tank, GetVectorDistance(pos, targetPos),
        AIPathMovement_GetHorizontalSpeed(hopVelocity) * airTime))
    {
        strafeSide = g_Tank[tank].lastStrafeSide;
        if (strafeSide == 0)
            strafeSide = GetRandomInt(0, 1) == 0 ? -1 : 1;
        else if (AIPathMovement_IsLandingHop(tank))
            strafeSide = -strafeSide;
        strafeYaw = g_cvBhopStrafeAngle.FloatValue * float(strafeSide);
        float lateral[3];
        Movement_RotateHorizontal(direction, strafeYaw, lateral);
        ScaleVector(lateral, AIPathMovement_GetHorizontalSpeed(hopVelocity));
        lateral[2] = hopVelocity[2];
        // 不在起跳时突然掉头；侧跳受阻则继续尝试原来的直跳。
        routeSafe = AIPathMovement_VectorAngle(velocity, lateral, true) <= g_cvDirectChaseMaxAngle.FloatValue &&
            Movement_IsTurnRouteSafe(tank, pos, pos, lateral, airTime, true);
        if (routeSafe)
            hopVelocity = lateral;
        else
            strafeYaw = 0.0;
    }
    if (!routeSafe && !AIPathMovement_IsJumpRouteSafe(tank, hopVelocity, airTime, JUMP_HEIGHT, visible, g_cvBhopNoVisionMaxAng.FloatValue))
    {
        if (!hasLook || !Movement_IsDropHopSafe(tank, pos, hopVelocity, visible))
        {
            AIPathMovement_MarkRouteCheckFailure(tank);
            return Plugin_Continue;
        }
        // 已验证完整下落轨迹，保持这次前冲方向，不在越过边沿后改向未知落点。
        mode = TankHop_Velocity;
    }

    buttons |= IN_DUCK | IN_JUMP;
    g_Tank[tank].hopMode = mode;
    g_Tank[tank].hopStrafeYaw = strafeYaw;
    if (strafeYaw != 0.0)
        g_Tank[tank].lastStrafeSide = strafeSide;
    AIPathMovement_BeginPathHop(tank, hopGoal, AIPathMovement_GetHorizontalSpeed(hopVelocity), maxSpeed);
    g_Tank[tank].nextAirThink = GetEngineTime() + TANK_AIR_THINK_INTERVAL;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, hopVelocity);
    return Plugin_Changed;
}

// 从当前高度/竖直速度估算剩余滞空时间，不拿完整一跳去检查空中转向。
float Movement_RemainingAirTime(float height, float verticalSpeed, float fullAirTime)
{
    float gravity = 8.0 * JUMP_HEIGHT / (fullAirTime * fullAirTime);
    if (height < 0.0)
        height = 0.0;
    float remaining = (verticalSpeed + SquareRoot(verticalSpeed * verticalSpeed + 2.0 * gravity * height)) / gravity;
    if (remaining < TANK_AIR_THINK_INTERVAL)
        remaining = TANK_AIR_THINK_INTERVAL;
    if (remaining > fullAirTime)
        remaining = fullAirTime;
    return remaining;
}

bool Movement_IsTurnRouteSafe(int tank, const float pos[3], const float ground[3], const float velocity[3], float remaining, bool launching = false, float maxDrop = JUMP_HEIGHT)
{
    float reach = AIPathMovement_GetHorizontalSpeed(velocity) * remaining;
    if (g_TankPath[tank].fresh && g_TankPath[tank].blockHopDist >= 0.0 &&
        reach + LADDER_HOP_MARGIN > g_TankPath[tank].blockHopDist)
        return false;

    float end[3];
    end = ground;
    end[0] += velocity[0] * remaining;
    end[1] += velocity[1] * remaining;
    float fullAirTime = AIPathMovement_GetJumpAirTime(JUMP_HEIGHT);
    float gravity = 8.0 * JUMP_HEIGHT / (fullAirTime * fullAirTime);
    float verticalSpeed = launching ? gravity * fullAirTime * 0.5 : velocity[2];
    float mins[3], maxs[3], traceStart[3], traceEnd[3];
    GetEntPropVector(tank, Prop_Send, "m_vecMins", mins);
    GetEntPropVector(tank, Prop_Send, "m_vecMaxs", maxs);
    int steps = RoundToCeil(remaining / TANK_AIR_TRACE_STEP);
    if (steps < 1)
        steps = 1;
    float stepTime = remaining / float(steps);
    // 抛物线在每段弦线上方；抬高 hull 顶部覆盖曲率余量，避免漏掉低顶棚/悬挑物。
    maxs[2] += gravity * stepTime * stepTime / 8.0;
    traceStart = pos;
    traceStart[2] += 1.0; // 留 1 单位接地余量，避免将预期的落地接触误判为障碍。
    for (int step = 1; step <= steps; step++)
    {
        float time = stepTime * float(step);
        traceEnd[0] = pos[0] + velocity[0] * time;
        traceEnd[1] = pos[1] + velocity[1] * time;
        traceEnd[2] = pos[2] + verticalSpeed * time - 0.5 * gravity * time * time + 1.0;
        Handle trace = TR_TraceHullFilterEx(traceStart, traceEnd, mins, maxs,
            MASK_PLAYERSOLID, AIPathMovement_TraceFilter, tank);
        bool blocked = TR_StartSolid(trace) || TR_DidHit(trace);
        delete trace;
        if (blocked)
            return false;
        traceStart = traceEnd;
    }
    // 断层检测以脚下地面为参考，不能把当前离地高度当成地面。
    return !AIPathMovement_HasPotentialGap(tank, ground, end, maxDrop);
}

// 只放开 NextBot 路径明确安排的普通下落。深落差腾空更久，必须按下方
// 地面重算实际落点；只增大平地一跳的 gap 容差会漏掉远处的墙和第二道悬崖。
bool Movement_IsDropHopSafe(int tank, const float pos[3], const float velocity[3], bool visible)
{
    if (!g_TankPath[tank].fresh || g_TankPath[tank].dropDist < 0.0)
        return false;

    float drop = pos[2] - g_TankPath[tank].dropLandingZ;
    if (drop <= JUMP_HEIGHT || drop > TANK_HOP_MAX_DROP)
        return false;

    float fullAirTime = AIPathMovement_GetJumpAirTime(JUMP_HEIGHT);
    float gravity = 8.0 * JUMP_HEIGHT / (fullAirTime * fullAirTime);
    float riseSpeed = gravity * fullAirTime * 0.5;
    float airTime, groundZ, end[3];
    bool converged;
    for (int attempt = 0; attempt < 3; attempt++)
    {
        airTime = (riseSpeed + SquareRoot(riseSpeed * riseSpeed + 2.0 * gravity * drop)) / gravity;
        if (AIPathMovement_GetHorizontalSpeed(velocity) * airTime <= g_TankPath[tank].dropDist)
            return false;
        end = pos;
        end[0] += velocity[0] * airTime;
        end[1] += velocity[1] * airTime;
        if (!AIPathMovement_TryFindGround(tank, end, pos[2], false, TANK_HOP_MAX_DROP, groundZ) ||
            FloatAbs(groundZ - g_TankPath[tank].dropLandingZ) > JUMP_HEIGHT)
            return false;
        float actualDrop = pos[2] - groundZ;
        if (actualDrop <= JUMP_HEIGHT || actualDrop > TANK_HOP_MAX_DROP)
            return false;
        if (FloatAbs(actualDrop - drop) < 0.5)
        {
            converged = true;
            break;
        }
        drop = actualDrop;
    }
    if (!converged)
        return false;

    // 落点四角也必须有地面，不能让中心射线恰好命中狭小凸起。
    float mins[3], maxs[3], sample[3], supportZ;
    GetEntPropVector(tank, Prop_Send, "m_vecMins", mins);
    GetEntPropVector(tank, Prop_Send, "m_vecMaxs", maxs);
    for (int corner = 0; corner < 4; corner++)
    {
        sample = end;
        sample[0] += (corner & 1) ? maxs[0] : mins[0];
        sample[1] += (corner & 2) ? maxs[1] : mins[1];
        if (!AIPathMovement_TryFindGround(tank, sample, groundZ, true, JUMP_HEIGHT, supportZ) ||
            FloatAbs(supportZ - groundZ) > AI_PATH_MOVEMENT_MAX_LOCAL_STEP_UP)
            return false;
    }
    return AIPathMovement_IsJumpRouteSafe(tank, velocity, airTime, TANK_HOP_MAX_DROP, visible, g_cvBhopNoVisionMaxAng.FloatValue) &&
        Movement_IsTurnRouteSafe(tank, pos, pos, velocity, airTime, true, TANK_HOP_MAX_DROP);
}

bool Movement_TrySafeAirCorrection(int tank, const float pos[3], const float ground[3], const float velocity[3],
    const float direction[3], float goalDist, float minAngle, float remaining, float output[3])
{
    float previousTime = g_AIPathMovementState[tank].lastCorrectionTime;
    if (!AIPathMovement_ComputeAirCorrectionToward(tank, velocity, direction, goalDist, PATH_GOAL_TOLERANCE_DIST,
        minAngle, g_cvAirVecModifyMaxDegree.FloatValue, 0.3, g_cvAirVecModifyInterval.FloatValue, 0.12, output))
        return false;
    if (Movement_IsTurnRouteSafe(tank, pos, ground, output, remaining))
        return true;
    // 被安全检查拒绝的候选没有真正转向，不占用修正时间；侧向失败后本帧还可尝试正常方向。
    g_AIPathMovementState[tank].lastCorrectionTime = previousTime;
    return false;
}

bool Movement_UpdateAirDirection(int tank, int buttons, const float pos[3], const float velocity[3],
    const float targetPos[3], float dist, bool visible, float output[3])
{
    float ground[3], groundZ;
    if (!AIPathMovement_TryFindGround(tank, pos, pos[2], false, TANK_AIR_GROUND_SEARCH, groundZ))
        return false;
    ground = pos;
    ground[2] = groundZ;
    float fullAirTime = AIPathMovement_GetJumpAirTime(JUMP_HEIGHT);
    float remaining = Movement_RemainingAirTime(pos[2] - groundZ, velocity[2], fullAirTime);
    float horizon = AIPathMovement_GetHorizontalSpeed(velocity) * remaining;
    if (horizon < PATH_LOOKAHEAD_MIN_DIST)
        horizon = PATH_LOOKAHEAD_MIN_DIST;

    float lookGoal[3], goal[3];
    bool hasLook = g_TankPath[tank].fresh &&
        Path_GetLookAhead(tank, pos, horizon, g_cvPathLookAheadMaxDepth.IntValue, lookGoal);
    // 用脚下地面的高度判定同层，避免正常起跳到顶点时误判为追高台。
    bool direct = g_Tank[tank].hopMode == TankHop_Target && !(buttons & IN_BACK) &&
        Movement_CanDirectChase(tank, ground, targetPos, visible, hasLook, lookGoal);
    float minAngle;
    if (direct)
    {
        goal = targetPos;
        minAngle = g_cvAirVecModifyDegree.FloatValue;
    }
    else if (hasLook)
    {
        goal = lookGoal;
        minAngle = AI_PATH_MOVEMENT_MIN_TURN_DEG;
        g_Tank[tank].hopStrafeYaw = 0.0;
    }
    else
    {
        // 快照过期/没有可达点时保持惯性，不再拽向已飞过的旧点。
        return false;
    }

    AIPathMovement_UpdateGoal(tank, goal);
    float direction[3];
    MakeVectorFromPoints(pos, goal, direction);
    direction[2] = 0.0;
    float goalDist = AIPathMovement_GetDistance2D(pos, goal);
    if (direct && g_Tank[tank].hopStrafeYaw != 0.0 && Movement_CanStrafe(tank, dist, horizon))
    {
        float lateral[3];
        Movement_RotateHorizontal(direction, g_Tank[tank].hopStrafeYaw, lateral);
        // 已沿本跳侧向方向飞行时无需修正，也不能因此误判侧向受阻。
        if (AIPathMovement_VectorAngle(velocity, lateral, true) < minAngle)
            return false;
        if (Movement_TrySafeAirCorrection(tank, pos, ground, velocity, lateral, goalDist, minAngle, remaining, output))
            return true;
        g_Tank[tank].hopStrafeYaw = 0.0;
    }
    else
    {
        g_Tank[tank].hopStrafeYaw = 0.0;
    }
    return Movement_TrySafeAirCorrection(tank, pos, ground, velocity, direction, goalDist, minAngle, remaining, output);
}

Action Movement_AirControl(int tank, int &buttons, const float pos[3], const float velocity[3], float speed, const float targetPos[3], float dist, bool visible)
{
    // 只修正插件自己起的跳；NextBot 的跳跃、下落、被打飞都不碰。
    if (!AIPathMovement_IsPathHopActive(tank))
        return Plugin_Continue;

    float corrected[3];
    corrected = velocity;
    bool changed = false;
    float maxSpeed = g_cvBhopMaxSpeed.FloatValue;
    if (maxSpeed > 0.0 && speed > maxSpeed)
    {
        AIPathMovement_ClampHorizontalSpeed(corrected, maxSpeed);
        changed = true;
    }

    float now = GetEngineTime();
    if (now >= g_Tank[tank].nextAirThink && g_Tank[tank].hopMode != TankHop_Velocity)
    {
        g_Tank[tank].nextAirThink = now + TANK_AIR_THINK_INTERVAL;
        float output[3];
        if (Movement_UpdateAirDirection(tank, buttons, pos, corrected, targetPos, dist, visible, output))
        {
            corrected = output;
            changed = true;
        }
    }
    if (!changed)
        return Plugin_Continue;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, corrected);
    return Plugin_Changed;
}
