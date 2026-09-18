#if defined _ai_tank3_path_included
    #endinput
#endif
#define _ai_tank3_path_included

// =========================================================================
// 路径快照
// 移动决策先看 NextBot 自己打算怎么走：前面有没有梯子、攀爬、下落、跳跃间隙，路径终点能不能走到目标。
// 快照不可用时才退回“附近有没有梯子实体”的物理检测。
// =========================================================================

bool Path_IsExtensionReady()
{
    return LibraryExists(ANNE_NEXTBOT_LIBRARY) &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_IsActive") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_SetPathConsumer") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSnapshotInfo") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSegment") == FeatureStatus_Available &&
        AnneNextBot_IsActive();
}

void Path_EnableConsumer()
{
    if (g_bPathConsumerEnabled)
        return;

    g_bPathConsumerEnabled = Path_IsExtensionReady() && AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Tank, true);
    if (!g_bPathConsumerEnabled && log != null)
        log.error("anne_nextbot path snapshots unavailable: path bhop disabled, ladder checks fall back to entities");
}

void Path_DisableConsumer()
{
    if (g_bPathConsumerEnabled && Path_IsExtensionReady())
        AnneNextBot_SetPathConsumer(AnneNextBotPathConsumer_Tank, false);
    g_bPathConsumerEnabled = false;
}

bool Path_ReadSegment(int client, int index, float goal[3], int &segmentType, Address &navArea)
{
    int traverseType;
    float pathForward[3], length, distanceFromStart;
    return AnneNextBot_GetPathSegment(client, index, navArea, traverseType, goal, segmentType, pathForward, length, distanceFromStart);
}

void Path_MarkBlockHop(int client, float dist)
{
    if (g_TankPath[client].blockHopDist < 0.0 || dist < g_TankPath[client].blockHopDist)
        g_TankPath[client].blockHopDist = dist;
}

// 每 tick 最多算一次，结果缓存在 g_TankPath[client]
void Path_Update(int client, const float pos[3], int target, const float targetPos[3])
{
    int tick = GetGameTickCount();
    if (g_TankPath[client].tick == tick)
        return;

    g_TankPath[client].Reset();
    g_TankPath[client].tick = tick;
    g_TankPath[client].time = GetGameTime();
    if (!g_bPathConsumerEnabled)
        return;

    int count, currentIndex;
    bool complete;
    float age;
    if (!AnneNextBot_GetPathSnapshotInfo(client, count, currentIndex, complete, age))
        return;
    if (count < 1 || currentIndex < 0 || currentIndex >= count || age < 0.0 || age > PATH_STALE_TIME)
        return;

    g_TankPath[client].fresh = true;
    g_TankPath[client].count = count;
    g_TankPath[client].currentIndex = currentIndex;
    g_TankPath[client].complete = complete;

    int end = currentIndex + PATH_SCAN_MAX_SEGMENTS;
    if (end > count)
        end = count;

    float previousGoal[3], goal[3];
    previousGoal = pos;
    float reachDist = 0.0;
    int segmentType;
    Address navArea;
    for (int index = currentIndex; index < end; index++)
    {
        if (!Path_ReadSegment(client, index, goal, segmentType, navArea))
            break;

        // 段类型描述的是“怎么从上一个目标点走到这一段的目标点”：
        // 梯子段的目标点就是上/下梯入口；攀爬、下落、跳跃间隙从上一个目标点开始
        float startDist = reachDist;
        reachDist += AIPathMovement_GetDistance2D(previousGoal, goal);
        float rise = goal[2] - previousGoal[2];

        AnneNextBotPathSegmentType type = view_as<AnneNextBotPathSegmentType>(segmentType);
        switch (type)
        {
            case AnneNextBotPathSegment_LadderUp, AnneNextBotPathSegment_LadderDown:
            {
                if (g_TankPath[client].ladderDist < 0.0)
                    g_TankPath[client].ladderDist = reachDist;
                Path_MarkBlockHop(client, reachDist);
                if (type == AnneNextBotPathSegment_LadderUp)
                    g_TankPath[client].routeUp = true;
            }
            case AnneNextBotPathSegment_ClimbUp:
            {
                g_TankPath[client].routeUp = true;
                if (rise > JUMP_HEIGHT)
                    Path_MarkBlockHop(client, startDist);
            }
            case AnneNextBotPathSegment_DropDown:
            {
                if (-rise > JUMP_HEIGHT && g_TankPath[client].dropDist < 0.0)
                {
                    g_TankPath[client].dropDist = startDist;
                    g_TankPath[client].dropLandingZ = goal[2];
                }
                // 普通落差不再预先限速；是否能跳下交给完整飞行路线和落点检查。
                if (-rise > TANK_HOP_MAX_DROP)
                    Path_MarkBlockHop(client, startDist);
            }
            case AnneNextBotPathSegment_JumpGap:
            {
                Path_MarkBlockHop(client, startDist);
            }
        }
        previousGoal = goal;
    }

    if (target > 0)
        g_TankPath[client].reachesTarget = Path_ComputeReachesTarget(client, pos, target, targetPos, count, complete);
}

bool Path_ComputeReachesTarget(int client, const float pos[3], int target, const float targetPos[3], int count, bool complete)
{
    // 快照被截断时看不到终点，按走得到处理，不因此关闭直追
    if (!complete)
        return true;

    float lastGoal[3];
    int segmentType;
    Address lastArea;
    if (!Path_ReadSegment(client, count - 1, lastGoal, segmentType, lastArea))
        return true;

    Address targetArea = view_as<Address>(L4D_GetLastKnownArea(target));
    if (targetArea != Address_Null && lastArea == targetArea)
        return true;

    float allowed = AIPathMovement_GetDistance2D(pos, targetPos) * PATH_REACH_TARGET_RATIO;
    if (allowed < PATH_REACH_TARGET_MIN_2D)
        allowed = PATH_REACH_TARGET_MIN_2D;
    return AIPathMovement_GetDistance2D(lastGoal, targetPos) <= allowed &&
        FloatAbs(lastGoal[2] - targetPos[2]) <= PATH_REACH_TARGET_Z;
}

bool Path_AcquireTraceBudget(int client)
{
    int tick = GetGameTickCount();
    if (tick != g_iPathTraceTick[client])
    {
        g_iPathTraceTick[client] = tick;
        g_iPathTraceUsed[client] = 0;
    }
    if (g_iPathTraceUsed[client] >= PATH_LOOKAHEAD_TRACE_BUDGET)
        return false;
    g_iPathTraceUsed[client]++;
    return true;
}

// 深下落候选仅供地面起跳验证使用；空中前瞻仍保持原来的小落差限制。
bool Path_GetLookAhead(int client, const float pos[3], float maxDist, int maxDepth, float out[3], bool allowDrop = false)
{
    if (!g_TankPath[client].fresh)
        return false;

    if (maxDepth < 1)
        maxDepth = 1;
    int end = g_TankPath[client].currentIndex + maxDepth * 2 + 1;
    if (end > g_TankPath[client].count)
        end = g_TankPath[client].count;

    // 已经走过当前段一半以上时从下一段开始，避免把身后的点当成前瞻点
    int start = g_TankPath[client].currentIndex;
    float currentGoal[3], nextGoal[3];
    int segmentType;
    Address navArea;
    if (!Path_ReadSegment(client, start, currentGoal, segmentType, navArea))
        return false;
    for (int depth = 0; depth < maxDepth && start + 1 < end; depth++)
    {
        if (!Path_ReadSegment(client, start + 1, nextGoal, segmentType, navArea))
            break;

        float segmentX = nextGoal[0] - currentGoal[0];
        float segmentY = nextGoal[1] - currentGoal[1];
        float lengthSquared = segmentX * segmentX + segmentY * segmentY;
        if (lengthSquared > 0.01 &&
            (segmentX * (pos[0] - currentGoal[0]) + segmentY * (pos[1] - currentGoal[1])) / lengthSquared < 0.5)
            break;
        start++;
        currentGoal = nextGoal;
    }

    int candidates[PATH_LOOKAHEAD_MAX_CANDIDATES];
    int candidateCount;
    float previousGoal[3], goal[3];
    previousGoal = pos;
    for (int index = start; index < end && candidateCount < PATH_LOOKAHEAD_MAX_CANDIDATES; index++)
    {
        if (!Path_ReadSegment(client, index, goal, segmentType, navArea))
            break;

        AnneNextBotPathSegmentType type = view_as<AnneNextBotPathSegmentType>(segmentType);
        float rise = goal[2] - previousGoal[2];
        bool hopable = type == AnneNextBotPathSegment_OnGround ||
            ((type == AnneNextBotPathSegment_DropDown || type == AnneNextBotPathSegment_ClimbUp) && FloatAbs(rise) <= JUMP_HEIGHT) ||
            (allowDrop && type == AnneNextBotPathSegment_DropDown && rise < 0.0 && -rise <= TANK_HOP_MAX_DROP);
        if (!hopable || goal[2] - pos[2] > JUMP_HEIGHT || (allowDrop && pos[2] - goal[2] > TANK_HOP_MAX_DROP))
            break;

        float dist = AIPathMovement_GetDistance2D(pos, goal);
        if (dist > maxDist && candidateCount > 0)
            break;
        candidates[candidateCount++] = index;
        previousGoal = goal;
        if (dist >= maxDist)
            break;
    }

    float traceStart[3];
    traceStart = pos;
    traceStart[2] += HULL_CENTER_HEIGHT;
    // 先检查近处，遇到遮挡或预算耗尽时仍保留已确认可达的点，避免远处弯道吃光预算。
    bool found;
    for (int i = 0; i < candidateCount; i++)
    {
        if (!Path_ReadSegment(client, candidates[i], goal, segmentType, navArea))
            continue;
        if (AIPathMovement_GetDistance2D(pos, goal) < PATH_LOOKAHEAD_MIN_GOAL_DIST)
            continue;
        if (!Path_AcquireTraceBudget(client))
            break;

        float traceEnd[3];
        traceEnd = goal;
        traceEnd[2] += HULL_CENTER_HEIGHT;
        // 直接斜着 trace 到低处会穿过脚下的平台。这里只确认水平出口，
        // 真正的下落抛物线和落地支撑由 Movement_IsDropHopSafe 完整验证。
        if (allowDrop && pos[2] - goal[2] > JUMP_HEIGHT)
            traceEnd[2] = traceStart[2];
        Handle trace = TR_TraceHullFilterEx(traceStart, traceEnd, {-16.0, -16.0, -16.0}, {16.0, 16.0, 16.0}, MASK_PLAYERSOLID, AIPathMovement_TraceFilter, client);
        bool blocked = TR_DidHit(trace);
        delete trace;
        if (blocked)
            break;
        out = goal;
        found = true;
    }
    return found;
}

// =========================================================================
// 梯子实体
// 路径快照不可用时的兜底检测，以及锁视角时确认 Tank 贴着的是哪一架梯子。
// 距离按到梯子包围盒而不是包围盒中心算：长梯子的中心在半空，两架梯子背靠背时中心距离也分不清。
// =========================================================================

float Ladder_AxisGap(float value, float minValue, float maxValue)
{
    if (value < minValue)
        return minValue - value;
    if (value > maxValue)
        return value - maxValue;
    return 0.0;
}

bool Ladder_DistanceToBox(int entity, const float pos[3], float &dist2D, float &zGap)
{
    if (!IsValidEntity(entity) || !HasEntProp(entity, Prop_Send, "m_vecMins"))
        return false;

    float origin[3], mins[3], maxs[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    GetEntPropVector(entity, Prop_Send, "m_vecMins", mins);
    GetEntPropVector(entity, Prop_Send, "m_vecMaxs", maxs);

    float dx = Ladder_AxisGap(pos[0], origin[0] + mins[0], origin[0] + maxs[0]);
    float dy = Ladder_AxisGap(pos[1], origin[1] + mins[1], origin[1] + maxs[1]);
    dist2D = SquareRoot(dx * dx + dy * dy);
    zGap = Ladder_AxisGap(pos[2], origin[2] + mins[2], origin[2] + maxs[2]);
    return true;
}

// 返回水平方向离 pos 最近、且高度对得上的梯子，找不到返回 -1
int Ladder_FindNear(const float pos[3], float radius, float zTolerance)
{
    if (radius <= 0.0)
        return -1;

    int best = -1;
    float bestDist = radius;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "func_simpleladder")) != -1)
    {
        float dist, zGap;
        if (!Ladder_DistanceToBox(entity, pos, dist, zGap) || zGap > zTolerance || dist > bestDist)
            continue;
        best = entity;
        bestDist = dist;
    }
    return best;
}

bool Ladder_NavAreaHasLadder(const float pos[3])
{
    if (GetFeatureStatus(FeatureType_Native, "L4D_NavArea_GetLadder") != FeatureStatus_Available)
        return false;

    Address area = view_as<Address>(L4D_GetNearestNavArea(pos, LADDER_NAV_SEARCH_DIST, false, false, false, TEAM_INFECTED));
    if (area == Address_Null)
        return false;

    if (g_hLadderNavList == null)
        g_hLadderNavList = new ArrayList();
    g_hLadderNavList.Clear();
    return L4D_NavArea_GetLadder(area, g_hLadderNavList) > 0;
}

bool Ladder_IsNearPhysical(int client, const float pos[3])
{
    float now = GetEngineTime();
    float cacheTime = g_cvLadderNearbyCacheTime.FloatValue;
    if (cacheTime <= 0.0)
        cacheTime = LADDER_CACHE_DEFAULT;
    if (now - g_Tank[client].ladderCheckTime < cacheTime)
        return g_Tank[client].ladderNear;

    g_Tank[client].ladderCheckTime = now;
    g_Tank[client].ladderNear = Ladder_FindNear(pos, g_cvLadderNearbyRadius.FloatValue, LADDER_Z_TOLERANCE) > 0 ||
        Ladder_NavAreaHasLadder(pos);
    return g_Tank[client].ladderNear;
}
