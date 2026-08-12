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

enum struct AIPathMovementState
{
    bool active;
    float goal[3];
    float hopSpeed;
    float lastCorrectionTime;

    void Reset()
    {
        this.active = false;
        this.goal = NULL_VECTOR;
        this.hopSpeed = 0.0;
        this.lastCorrectionTime = 0.0;
    }
}

AIPathMovementState g_AIPathMovementState[MAXPLAYERS + 1];
ConVar g_AIPathMovementGravityCvar;

stock void AIPathMovement_Reset(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AIPathMovementState[client].Reset();
}

stock void AIPathMovement_BeginPathHop(int client, const float goal[3], float hopSpeed)
{
    if (client < 1 || client > MaxClients)
        return;

    g_AIPathMovementState[client].active = true;
    g_AIPathMovementState[client].goal = goal;
    g_AIPathMovementState[client].hopSpeed = hopSpeed;
    g_AIPathMovementState[client].lastCorrectionTime = GetEngineTime();
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

    if (!visible && noVisionMaxAngle > 0.0)
    {
        float eyeAngles[3], eyeDirection[3];
        GetClientEyeAngles(client, eyeAngles);
        GetAngleVectors(eyeAngles, eyeDirection, NULL_VECTOR, NULL_VECTOR);
        if (AIPathMovement_VectorAngle(eyeDirection, velocity, true) > noVisionMaxAngle)
            return false;
    }

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
