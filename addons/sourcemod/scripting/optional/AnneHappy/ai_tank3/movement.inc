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

// 1.x 的叠加式推速：按前进键时沿给定方向追加，按后退键时沿当前速度方向追加，其余情况只起跳不加速
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

    // 前方有梯子入口/高攀爬/深下落/跳跃间隙：这一跳只能落在它前面，按剩余距离压低起跳速度，连跑速都够不上就不跳
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
    bool hasLook = pathFresh && Path_GetLookAhead(tank, pos, horizon, g_cvPathLookAheadMaxDepth.IntValue, lookGoal);

    // 直追只在“看得见、同一高度、路径本身就朝着目标”时用；目标站在高台/梯子顶上时，
    // 朝目标加速只会把 Tank 拽到平台下的墙根，偏离去梯子的路线
    bool direct = visible && FloatAbs(targetPos[2] - pos[2]) <= JUMP_HEIGHT;
    if (direct && pathFresh)
    {
        if (!g_TankPath[tank].reachesTarget)
        {
            direct = false;
        }
        else if (hasLook)
        {
            float toTarget[3], toLook[3];
            MakeVectorFromPoints(pos, targetPos, toTarget);
            MakeVectorFromPoints(pos, lookGoal, toLook);
            direct = AIPathMovement_VectorAngle(toLook, toTarget, true) <= g_cvDirectChaseMaxAngle.FloatValue;
        }
    }

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
    if (!AIPathMovement_IsJumpRouteSafe(tank, hopVelocity, airTime, JUMP_HEIGHT, visible, g_cvBhopNoVisionMaxAng.FloatValue))
    {
        AIPathMovement_MarkRouteCheckFailure(tank);
        return Plugin_Continue;
    }

    buttons |= IN_DUCK | IN_JUMP;
    g_Tank[tank].hopMode = mode;
    AIPathMovement_BeginPathHop(tank, hopGoal, AIPathMovement_GetHorizontalSpeed(hopVelocity), maxSpeed);
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, hopVelocity);
    return Plugin_Changed;
}

Action Movement_AirControl(int tank, int &buttons, const float pos[3], const float velocity[3], float speed, const float targetPos[3], float dist, bool visible)
{
    // 只修正插件自己起的跳；NextBot 的跳跃、下落、被打飞都不碰
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

    float output[3];
    switch (g_Tank[tank].hopMode)
    {
        case TankHop_Path:
        {
            if (AIPathMovement_ComputePathAirCorrection(tank, corrected, PATH_GOAL_TOLERANCE_DIST,
                g_cvAirVecModifyDegree.FloatValue, g_cvAirVecModifyMaxDegree.FloatValue, 0.3,
                g_cvAirVecModifyInterval.FloatValue, 0.12, output))
            {
                corrected = output;
                changed = true;
            }
        }
        case TankHop_Target:
        {
            float dz = targetPos[2] - pos[2];
            float dx = AIPathMovement_GetDistance2D(pos, targetPos);
            float pitch = dx > 0.0 ? RadToDeg(ArcTangent(dz / dx)) : 90.0;
            bool steep = dz > JUMP_HEIGHT + TANK_HEIGHT + g_fTankSwingRange && pitch > 45.0;
            if (visible && !(buttons & IN_BACK) && !steep)
            {
                float toTarget[3];
                MakeVectorFromPoints(pos, targetPos, toTarget);
                toTarget[2] = 0.0;
                if (AIPathMovement_ComputeAirCorrectionToward(tank, corrected, toTarget, dist, PATH_GOAL_TOLERANCE_DIST,
                    g_cvAirVecModifyDegree.FloatValue, g_cvAirVecModifyMaxDegree.FloatValue, 0.3,
                    g_cvAirVecModifyInterval.FloatValue, 0.12, output))
                {
                    corrected = output;
                    changed = true;
                }
            }
        }
    }

    if (!changed)
        return Plugin_Continue;
    TeleportEntity(tank, NULL_VECTOR, NULL_VECTOR, corrected);
    return Plugin_Changed;
}
