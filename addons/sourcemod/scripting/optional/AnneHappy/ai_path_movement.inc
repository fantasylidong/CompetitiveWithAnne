#if defined _anne_ai_path_movement_included
    #endinput
#endif
#define _anne_ai_path_movement_included

#define AI_PATH_MOVEMENT_AIR_STEP_INTERVAL 0.05
#define AI_PATH_MOVEMENT_MAX_TURN_DEG 89.0
#define AI_PATH_MOVEMENT_MIN_TURN_DEG 1.0
#define AI_PATH_MOVEMENT_GROUND_SAMPLE_STEP 50.0
#define AI_PATH_MOVEMENT_MAX_LOCAL_STEP_UP 56.0
#define AI_PATH_MOVEMENT_GROUND_TRACE_MARGIN 10.0
#define AI_PATH_MOVEMENT_MIN_GROUND_NORMAL_Z 0.20
#define AI_PATH_MOVEMENT_ROUTE_FAIL_RETRY 0.1
#define AI_PATH_MOVEMENT_MIN_HOP_AIR_TIME 0.1
#define AI_PATH_MOVEMENT_LANDING_IMPULSE_WINDOW 0.15

enum struct AIPathMovementState
{
    bool active;
    float goal[3];
    float hopSpeed;
    float maxSpeed;
    float lastCorrectionTime;

    void Reset()
    {
        this.active = false;
        this.goal = NULL_VECTOR;
        this.hopSpeed = 0.0;
        this.maxSpeed = 0.0;
        this.lastCorrectionTime = 0.0;
    }
}

AIPathMovementState g_AIPathMovementState[MAXPLAYERS + 1];
float g_AIPathMovementRouteFailTime[MAXPLAYERS + 1];
float g_AIPathMovementLastGroundTime[MAXPLAYERS + 1];
float g_AIPathMovementLandingTime[MAXPLAYERS + 1];
ConVar g_AIPathMovementGravityCvar;

/**
* 连跳加速节奏。
* 从地面直接起跳的第一跳只改方向不加速，加速度只在“落地后紧接着再起跳”的那一跳追加，
* 否则第一跳会在离地瞬间凭空多出一整份加速度，看起来像空中突然加速。
*
* 落地 = 离开地面至少 AI_PATH_MOVEMENT_MIN_HOP_AIR_TIME 后重新踩地，不区分是插件起跳、
* 引擎跳跃还是沿路径走下落差；高处坠落同样算落地，落地那一跳照常追加加速度，滞空不设上限。
* 起跳被引擎拒绝时下一帧仍在地面、中间没有离地，不算落地，原地反复起跳不会每帧领加速度。
* 梯子按地面处理，爬完梯子之后的第一跳不加速。
*
* 用法：每帧在地面或梯子上时尽早调用 AIPathMovement_NotifyGrounded；
* 每次起跳（Teleport 出起跳速度）后调用 AIPathMovement_MarkHopStart 消费掉本次落地授权
* （AIPathMovement_BeginPathHop 内已自动调用）；
* 起跳前用 AIPathMovement_GetHopImpulse 决定本跳能追加多少加速度。
* 这组状态独立于 AIPathMovement_Reset，地面每帧 Reset 空中修正状态不会打断连跳链。
*/
stock void AIPathMovement_ResetHopChain(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AIPathMovementLastGroundTime[client] = 0.0;
    g_AIPathMovementLandingTime[client] = 0.0;
}

stock void AIPathMovement_MarkHopStart(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    // 起跳后落地授权立即作废，同一次落地不会被连续两帧的起跳重复使用
    g_AIPathMovementLandingTime[client] = 0.0;
}

stock void AIPathMovement_NotifyGrounded(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    float now = GetGameTime();
    float lastGround = g_AIPathMovementLastGroundTime[client];
    g_AIPathMovementLastGroundTime[client] = now;

    // 首次登记 / 换图后 GameTime 回卷
    if (lastGround <= 0.0 || lastGround > now)
        return;

    // 上一帧也在地面（含引擎拒跳后仍站在原地）不算落地
    if (now - lastGround < AI_PATH_MOVEMENT_MIN_HOP_AIR_TIME)
        return;

    g_AIPathMovementLandingTime[client] = now;
}

stock bool AIPathMovement_IsLandingHop(int client)
{
    if (client < 1 || client > MaxClients)
        return false;

    float landing = g_AIPathMovementLandingTime[client];
    if (landing <= 0.0)
        return false;

    float now = GetGameTime();
    if (landing > now)
    {
        g_AIPathMovementLandingTime[client] = 0.0;
        return false;
    }
    return now - landing <= AI_PATH_MOVEMENT_LANDING_IMPULSE_WINDOW;
}

/**
* 本次起跳可追加的加速度：落地后紧接着的起跳返回完整 impulse，从地面直接起跳返回 0。
*/
stock float AIPathMovement_GetHopImpulse(int client, float impulse)
{
    if (impulse <= 0.0)
        return 0.0;
    return AIPathMovement_IsLandingHop(client) ? impulse : 0.0;
}

/**
* 起跳路线安全检查的失败节流。
* 地形导致的检查失败（撞墙/断层/落点危险）在极短时间内不会自行消失，
* 每帧重试只会重复烧掉相同的 hull/ray trace。失败后在冷却时间内跳过重试，
* 即可把受阻状态下的射线开销压到 1/N，而重试延迟最多 AI_PATH_MOVEMENT_ROUTE_FAIL_RETRY 秒。
*/
stock void AIPathMovement_MarkRouteCheckFailure(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AIPathMovementRouteFailTime[client] = GetGameTime();
}

stock bool AIPathMovement_IsRouteCheckThrottled(int client, float cooldown = AI_PATH_MOVEMENT_ROUTE_FAIL_RETRY)
{
    if (client < 1 || client > MaxClients)
        return false;

    float now = GetGameTime();
    float failTime = g_AIPathMovementRouteFailTime[client];
    // 换图后 GameTime 回卷，旧时间戳会比当前时间大，直接清掉避免长时间误节流
    if (failTime > now)
    {
        g_AIPathMovementRouteFailTime[client] = 0.0;
        return false;
    }
    return now - failTime < cooldown;
}

stock void AIPathMovement_Reset(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AIPathMovementState[client].Reset();
}

/**
* 记录一次连跳的空中保速状态。
* maxSpeed > 0 时作为本次滞空期间的水平速度硬上限：
* 起跳速度尖峰（叠加式推速、外部冲量）不会被空中修正长期保持，防止“飞天大跳”。
* 同时消费掉本次落地加速授权。
*/
stock void AIPathMovement_BeginPathHop(int client, const float goal[3], float hopSpeed, float maxSpeed = 0.0)
{
    if (client < 1 || client > MaxClients)
        return;

    if (maxSpeed > 0.0 && hopSpeed > maxSpeed)
        hopSpeed = maxSpeed;

    g_AIPathMovementState[client].active = true;
    g_AIPathMovementState[client].goal = goal;
    g_AIPathMovementState[client].hopSpeed = hopSpeed;
    g_AIPathMovementState[client].maxSpeed = maxSpeed;
    g_AIPathMovementState[client].lastCorrectionTime = GetEngineTime();
    AIPathMovement_MarkHopStart(client);
}

stock void AIPathMovement_UpdateGoal(int client, const float goal[3])
{
    if (client < 1 || client > MaxClients || !g_AIPathMovementState[client].active)
        return;

    g_AIPathMovementState[client].goal = goal;
}

stock bool AIPathMovement_IsPathHopActive(int client)
{
    return client >= 1 && client <= MaxClients && g_AIPathMovementState[client].active;
}

stock float AIPathMovement_GetHorizontalSpeed(const float velocity[3])
{
    return SquareRoot(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
}

/**
* 只压水平分量的限速，保留 Z 速度（跳跃/重力交给引擎）。
* maxSpeed <= 0 表示不限速。
*/
stock void AIPathMovement_ClampHorizontalSpeed(float velocity[3], float maxSpeed)
{
    if (maxSpeed <= 0.0)
        return;

    float speed = AIPathMovement_GetHorizontalSpeed(velocity);
    if (speed <= maxSpeed)
        return;

    float scale = maxSpeed / speed;
    velocity[0] *= scale;
    velocity[1] *= scale;
}

/**
* 只保留水平分量并归一化。水平分量为零时（目标正上/正下方、视角俯仰 ±90）
* 归一化会除零，Valve 的 VectorNormalize 退化成 (0,0,1)，等于把特感直接推上天。
* 这种情况输出零向量并返回 false，由调用方跳过本次推力。
*/
stock bool AIPathMovement_NormalizeHorizontal(float velocity[3])
{
    velocity[2] = 0.0;
    if (AIPathMovement_GetHorizontalSpeed(velocity) <= 0.0)
    {
        velocity[0] = 0.0;
        velocity[1] = 0.0;
        return false;
    }

    NormalizeVector(velocity, velocity);
    velocity[2] = 0.0;
    return true;
}

stock float AIPathMovement_GetDistance2D(const float first[3], const float second[3])
{
    float dx = first[0] - second[0];
    float dy = first[1] - second[1];
    return SquareRoot(dx * dx + dy * dy);
}

stock float AIPathMovement_GetJumpAirTime(float jumpHeight = 56.0)
{
    if (g_AIPathMovementGravityCvar == null)
        g_AIPathMovementGravityCvar = FindConVar("sv_gravity");
    float gravity = g_AIPathMovementGravityCvar == null ? 800.0 : g_AIPathMovementGravityCvar.FloatValue;
    if (gravity <= 0.0)
        gravity = 800.0;
    if (jumpHeight <= 0.0)
        jumpHeight = 56.0;

    return SquareRoot((2.0 * jumpHeight) / gravity) * 2.0;
}

stock float AIPathMovement_VectorAngle(const float first[3], const float second[3], bool ignoreZ = true)
{
    float firstCopy[3], secondCopy[3];
    firstCopy = first;
    secondCopy = second;
    if (ignoreZ)
    {
        firstCopy[2] = 0.0;
        secondCopy[2] = 0.0;
    }

    if (NormalizeVector(firstCopy, firstCopy) <= 0.0 || NormalizeVector(secondCopy, secondCopy) <= 0.0)
        return 0.0;

    float dot = GetVectorDotProduct(firstCopy, secondCopy);
    if (dot > 1.0)
        dot = 1.0;
    else if (dot < -1.0)
        dot = -1.0;
    return RadToDeg(ArcCosine(dot));
}

stock bool AIPathMovement_TraceFilter(int entity, int contentsMask, any client)
{
    if (entity == 0)
        return true;
    if (entity == client || (entity >= 1 && entity <= MaxClients) || !IsValidEntity(entity))
        return false;

    char className[64];
    GetEntityClassname(entity, className, sizeof(className));
    if (strcmp(className, "infected", false) == 0 || strcmp(className, "witch", false) == 0 ||
        StrContains(className, "trigger_", false) == 0 || strcmp(className, "func_illusionary", false) == 0 ||
        strcmp(className, "func_playerclip", false) == 0 || strcmp(className, "player_infected_clip", false) == 0 ||
        strcmp(className, "func_playerinfected_clip", false) == 0)
        return false;

    if (strcmp(className, "func_breakable", false) == 0 && HasEntProp(entity, Prop_Data, "m_nSolidType") &&
        GetEntProp(entity, Prop_Data, "m_nSolidType") == 1)
        return false;
    if (HasEntProp(entity, Prop_Send, "m_fEffects") && (GetEntProp(entity, Prop_Send, "m_fEffects") & 32))
        return false;
    return true;
}

stock bool AIPathMovement_TryFindGround(
    int client,
    const float samplePosition[3],
    float referenceGroundZ,
    bool hasPreviousGround,
    float maxLocalDrop,
    float &groundZ
)
{
    float traceStart[3], traceEnd[3];
    traceStart[0] = traceEnd[0] = samplePosition[0];
    traceStart[1] = traceEnd[1] = samplePosition[1];
    traceStart[2] = referenceGroundZ + (hasPreviousGround
        ? AI_PATH_MOVEMENT_MAX_LOCAL_STEP_UP + AI_PATH_MOVEMENT_GROUND_TRACE_MARGIN
        : AI_PATH_MOVEMENT_GROUND_TRACE_MARGIN);
    traceEnd[2] = referenceGroundZ - maxLocalDrop;

    Handle trace = TR_TraceRayFilterEx(
        traceStart,
        traceEnd,
        MASK_PLAYERSOLID,
        RayType_EndPoint,
        AIPathMovement_TraceFilter,
        client
    );
    if (!TR_DidHit(trace) || TR_StartSolid(trace))
    {
        delete trace;
        return false;
    }

    float groundPosition[3], groundNormal[3];
    TR_GetEndPosition(groundPosition, trace);
    TR_GetPlaneNormal(trace, groundNormal);
    delete trace;
    if (groundNormal[2] < AI_PATH_MOVEMENT_MIN_GROUND_NORMAL_Z)
        return false;

    groundZ = groundPosition[2];
    return true;
}

stock bool AIPathMovement_HasPotentialGap(int client, const float start[3], const float end[3], float maxLocalDrop)
{
    if (maxLocalDrop <= 0.0)
        return true;

    float routeDirection[3];
    MakeVectorFromPoints(start, end, routeDirection);
    routeDirection[2] = 0.0;
    float routeDistance = NormalizeVector(routeDirection, routeDirection);
    if (routeDistance <= 0.0)
        return false;

    int sampleCount = RoundToCeil(routeDistance / AI_PATH_MOVEMENT_GROUND_SAMPLE_STEP);
    if (sampleCount < 1)
        sampleCount = 1;

    float previousGroundZ = start[2];
    bool hasPreviousGround = false;
    for (int sampleIndex = 0; sampleIndex <= sampleCount; sampleIndex++)
    {
        float fraction = float(sampleIndex) / float(sampleCount);
        float samplePosition[3];
        samplePosition[0] = start[0] + routeDirection[0] * routeDistance * fraction;
        samplePosition[1] = start[1] + routeDirection[1] * routeDistance * fraction;
        samplePosition[2] = start[2];

        float referenceGroundZ = hasPreviousGround ? previousGroundZ : start[2];
        float currentGroundZ;
        if (!AIPathMovement_TryFindGround(
            client,
            samplePosition,
            referenceGroundZ,
            hasPreviousGround,
            maxLocalDrop,
            currentGroundZ
        ))
            return true;

        if (hasPreviousGround)
        {
            float deltaZ = currentGroundZ - previousGroundZ;
            if (deltaZ > AI_PATH_MOVEMENT_MAX_LOCAL_STEP_UP + 1.0 || deltaZ < -maxLocalDrop - 1.0)
                return true;
        }

        previousGroundZ = currentGroundZ;
        hasPreviousGround = true;
    }
    return false;
}

stock bool AIPathMovement_IsJumpRouteSafe(
    int client,
    const float velocity[3],
    float airTime,
    float maxLocalDrop,
    bool visible,
    float noVisionMaxAngle
)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
        return false;
    if (airTime <= 0.0)
        airTime = AIPathMovement_GetJumpAirTime(maxLocalDrop);

    // 无视野角度拒绝不需要任何 trace，放在最前面可让被拒绝的尝试零射线开销
    if (!visible && noVisionMaxAngle > 0.0)
    {
        float eyeAngles[3], eyeDirection[3];
        GetClientEyeAngles(client, eyeAngles);
        GetAngleVectors(eyeAngles, eyeDirection, NULL_VECTOR, NULL_VECTOR);
        if (AIPathMovement_VectorAngle(eyeDirection, velocity, true) > noVisionMaxAngle)
            return false;
    }

    float start[3], routeEnd[3];
    GetClientAbsOrigin(client, start);
    routeEnd = start;
    routeEnd[0] += velocity[0] * airTime;
    routeEnd[1] += velocity[1] * airTime;

    float centerStart[3], centerEnd[3];
    centerStart = start;
    centerStart[2] += 36.0;
    centerEnd = routeEnd;
    centerEnd[2] += 36.0;
    Handle trace = TR_TraceHullFilterEx(
        centerStart,
        centerEnd,
        {-16.0, -16.0, -16.0},
        {16.0, 16.0, 16.0},
        MASK_PLAYERSOLID,
        AIPathMovement_TraceFilter,
        client
    );
    bool blocked = TR_StartSolid(trace);
    if (!blocked && TR_DidHit(trace))
    {
        float hitNormal[3], direction[3];
        TR_GetPlaneNormal(trace, hitNormal);
        direction = velocity;
        direction[2] = 0.0;
        NormalizeVector(hitNormal, hitNormal);
        NormalizeVector(direction, direction);
        blocked = AIPathMovement_VectorAngle(hitNormal, direction, true) > 165.0;
    }
    delete trace;
    if (blocked)
        return false;

    return !AIPathMovement_HasPotentialGap(client, start, routeEnd, maxLocalDrop);
}

stock bool AIPathMovement_PrepareAirCorrection(int client, float baseLerp, float responseTime, float &smoothLerp, float &now)
{
    now = GetEngineTime();
    if (client < 1 || client > MaxClients || !g_AIPathMovementState[client].active)
        return false;
    if (now - g_AIPathMovementState[client].lastCorrectionTime < AI_PATH_MOVEMENT_AIR_STEP_INTERVAL)
        return false;
    if (baseLerp <= 0.0)
        return false;
    if (baseLerp > 1.0)
        baseLerp = 1.0;
    if (responseTime < AI_PATH_MOVEMENT_AIR_STEP_INTERVAL)
        responseTime = AI_PATH_MOVEMENT_AIR_STEP_INTERVAL;

    float stepRatio = AI_PATH_MOVEMENT_AIR_STEP_INTERVAL / responseTime;
    smoothLerp = 1.0 - Pow(1.0 - baseLerp, stepRatio);
    return smoothLerp > 0.0;
}

stock void AIPathMovement_BuildAirCorrectionVelocity(
    const float currentVelocity[3],
    const float desiredDirection[3],
    float lerp,
    float finalSpeed,
    float speedLossFactor,
    float outputVelocity[3]
)
{
    float currentDirection[3], desired[3];
    currentDirection = currentVelocity;
    desired = desiredDirection;
    currentDirection[2] = 0.0;
    desired[2] = 0.0;
    NormalizeVector(currentDirection, currentDirection);
    NormalizeVector(desired, desired);

    if (lerp < 0.0)
        lerp = 0.0;
    else if (lerp > 1.0)
        lerp = 1.0;

    outputVelocity[0] = currentDirection[0] + (desired[0] - currentDirection[0]) * lerp;
    outputVelocity[1] = currentDirection[1] + (desired[1] - currentDirection[1]) * lerp;
    outputVelocity[2] = 0.0;
    NormalizeVector(outputVelocity, outputVelocity);

    float actualTurnAngle = AIPathMovement_VectorAngle(currentDirection, outputVelocity, true);
    float speedLoss = speedLossFactor * (actualTurnAngle / 90.0);
    if (speedLoss < 0.0)
        speedLoss = 0.0;
    else if (speedLoss > 0.5)
        speedLoss = 0.5;
    finalSpeed *= 1.0 - speedLoss;

    ScaleVector(outputVelocity, finalSpeed);
    outputVelocity[2] = currentVelocity[2];
}

stock bool AIPathMovement_ComputeAirCorrectionToward(
    int client,
    const float currentVelocity[3],
    const float desiredDirection[3],
    float goalDistance,
    float goalTolerance,
    float minTurnDegree,
    float maxTurnDegree,
    float baseLerp,
    float responseTime,
    float speedLossFactor,
    float outputVelocity[3]
)
{
    if (!AIPathMovement_IsPathHopActive(client) || goalDistance <= goalTolerance)
        return false;

    if (minTurnDegree < AI_PATH_MOVEMENT_MIN_TURN_DEG)
        minTurnDegree = AI_PATH_MOVEMENT_MIN_TURN_DEG;
    if (maxTurnDegree > AI_PATH_MOVEMENT_MAX_TURN_DEG)
        maxTurnDegree = AI_PATH_MOVEMENT_MAX_TURN_DEG;

    float turnAngle = AIPathMovement_VectorAngle(currentVelocity, desiredDirection, true);
    if (turnAngle < minTurnDegree || turnAngle > maxTurnDegree)
        return false;

    float smoothLerp, now;
    if (!AIPathMovement_PrepareAirCorrection(client, baseLerp, responseTime, smoothLerp, now))
        return false;

    float speed = AIPathMovement_GetHorizontalSpeed(currentVelocity);
    if (speed < g_AIPathMovementState[client].hopSpeed)
        speed = g_AIPathMovementState[client].hopSpeed;
    // 空中修正只维持不超过上限的速度，被外力推出的尖峰速度不再被保持
    float maxSpeed = g_AIPathMovementState[client].maxSpeed;
    if (maxSpeed > 0.0 && speed > maxSpeed)
        speed = maxSpeed;
    AIPathMovement_BuildAirCorrectionVelocity(
        currentVelocity,
        desiredDirection,
        smoothLerp,
        speed,
        speedLossFactor,
        outputVelocity
    );
    g_AIPathMovementState[client].lastCorrectionTime = now;
    return true;
}

stock bool AIPathMovement_ComputePathAirCorrection(
    int client,
    const float currentVelocity[3],
    float goalTolerance,
    float minTurnDegree,
    float maxTurnDegree,
    float baseLerp,
    float responseTime,
    float speedLossFactor,
    float outputVelocity[3]
)
{
    if (!AIPathMovement_IsPathHopActive(client))
        return false;

    float position[3], direction[3];
    GetClientAbsOrigin(client, position);
    MakeVectorFromPoints(position, g_AIPathMovementState[client].goal, direction);
    direction[2] = 0.0;
    float goalDistance = AIPathMovement_GetDistance2D(position, g_AIPathMovementState[client].goal);
    return AIPathMovement_ComputeAirCorrectionToward(
        client,
        currentVelocity,
        direction,
        goalDistance,
        goalTolerance,
        minTurnDegree,
        maxTurnDegree,
        baseLerp,
        responseTime,
        speedLossFactor,
        outputVelocity
    );
}

stock bool AIPathMovement_AlignFacing(const float movement[3], float angles[3])
{
    float direction[3];
    direction = movement;
    direction[2] = 0.0;
    if (NormalizeVector(direction, direction) <= 0.0)
        return false;

    GetVectorAngles(direction, angles);
    angles[0] = 0.0;
    angles[2] = 0.0;
    return true;
}
