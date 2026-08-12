#if defined _anne_ai_path_snapshot_included
    #endinput
#endif
#define _anne_ai_path_snapshot_included

#define AI_PATH_SNAPSHOT_STALE_TIME 0.35
#define AI_PATH_SNAPSHOT_TRACE_BUDGET 6
#define AI_PATH_SNAPSHOT_MAX_JUMP_HEIGHT 56.0
#define AI_PATH_SNAPSHOT_CENTER_HEIGHT 36.0

enum struct AIPathSnapshotSegment
{
    Address navArea;
    int traverseType;
    float goal[3];
    int segmentType;
    float pathForward[3];
    float length;
    float distanceFromStart;

    void Reset()
    {
        this.navArea = Address_Null;
        this.traverseType = 0;
        this.goal = NULL_VECTOR;
        this.segmentType = view_as<int>(AnneNextBotPathSegment_OnGround);
        this.pathForward = NULL_VECTOR;
        this.length = 0.0;
        this.distanceFromStart = 0.0;
    }
}

int g_AIPathSnapshotTraceTick = -1;
int g_AIPathSnapshotTraceUsed;

bool AIPathSnapshot_Setup()
{
    return LibraryExists(ANNE_NEXTBOT_LIBRARY) && AnneNextBot_IsActive() &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSnapshotInfo") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSegment") == FeatureStatus_Available;
}

bool AIPathSnapshot_GetInfo(int client, int &count, int &currentIndex, bool &complete, float &age)
{
    count = 0;
    currentIndex = -1;
    complete = false;
    age = -1.0;
    return AnneNextBot_GetPathSnapshotInfo(client, count, currentIndex, complete, age);
}

bool AIPathSnapshot_ReadSegment(int client, int index, AIPathSnapshotSegment segment)
{
    segment.Reset();
    return AnneNextBot_GetPathSegment(
        client,
        index,
        segment.navArea,
        segment.traverseType,
        segment.goal,
        segment.segmentType,
        segment.pathForward,
        segment.length,
        segment.distanceFromStart
    );
}

bool AIPathSnapshot_IsReady(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsFakeClient(client) ||
        !IsPlayerAlive(client) || GetClientTeam(client) != 3)
        return false;

    int count, currentIndex;
    bool complete;
    float age;
    return AIPathSnapshot_GetInfo(client, count, currentIndex, complete, age) &&
        count > 0 && currentIndex >= 0 && currentIndex < count && age >= 0.0 && age <= AI_PATH_SNAPSHOT_STALE_TIME;
}

int AIPathSnapshot_ClampEnd(int count, int currentIndex, int requested)
{
    int end = count;
    if (requested > 0 && currentIndex + requested < end)
        end = currentIndex + requested;
    return end;
}

bool AIPathSnapshot_HasSpecialMoveAhead(int client, int maxDepth)
{
    int count, currentIndex;
    bool complete;
    float age;
    if (!AIPathSnapshot_GetInfo(client, count, currentIndex, complete, age) ||
        currentIndex < 0 || age < 0.0 || age > AI_PATH_SNAPSHOT_STALE_TIME)
        return false;

    int end = AIPathSnapshot_ClampEnd(count, currentIndex, maxDepth);
    AIPathSnapshotSegment segment;
    for (int i = currentIndex; i < end; i++)
    {
        if (!AIPathSnapshot_ReadSegment(client, i, segment) ||
            segment.segmentType != view_as<int>(AnneNextBotPathSegment_OnGround))
            return true;
    }
    return false;
}

float AIPathSnapshot_Distance2D(const float first[3], const float second[3])
{
    float x = first[0] - second[0];
    float y = first[1] - second[1];
    return SquareRoot(x * x + y * y);
}

void AIPathSnapshot_RefreshTraceBudget()
{
    int tick = GetGameTickCount();
    if (tick != g_AIPathSnapshotTraceTick)
    {
        g_AIPathSnapshotTraceTick = tick;
        g_AIPathSnapshotTraceUsed = 0;
    }
}

bool AIPathSnapshot_TraceFilter(int entity, int contentsMask, any client)
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
    return true;
}

bool AIPathSnapshot_TraceClear(int client, const float start[3], const float rawGoal[3])
{
    AIPathSnapshot_RefreshTraceBudget();
    if (g_AIPathSnapshotTraceUsed >= AI_PATH_SNAPSHOT_TRACE_BUDGET)
        return false;

    g_AIPathSnapshotTraceUsed++;
    float end[3];
    end = rawGoal;
    end[2] += AI_PATH_SNAPSHOT_CENTER_HEIGHT;
    Handle trace = TR_TraceHullFilterEx(
        start,
        end,
        {-16.0, -16.0, -16.0},
        {16.0, 16.0, 16.0},
        MASK_PLAYERSOLID,
        AIPathSnapshot_TraceFilter,
        client
    );
    bool clear = !TR_DidHit(trace);
    delete trace;
    return clear;
}

int AIPathSnapshot_FindForwardStart(int client, const float position[3], int currentIndex, int end)
{
    int index = currentIndex;
    float position2D[3];
    position2D = position;
    position2D[2] = 0.0;

    AIPathSnapshotSegment current, next;
    while (index + 1 < end)
    {
        if (!AIPathSnapshot_ReadSegment(client, index, current) ||
            !AIPathSnapshot_ReadSegment(client, index + 1, next))
            break;

        float currentGoal[3], nextGoal[3], pathVector[3], toClient[3];
        currentGoal = current.goal;
        nextGoal = next.goal;
        currentGoal[2] = 0.0;
        nextGoal[2] = 0.0;
        MakeVectorFromPoints(currentGoal, nextGoal, pathVector);
        MakeVectorFromPoints(currentGoal, position2D, toClient);
        float lengthSquared = GetVectorDotProduct(pathVector, pathVector);
        if (lengthSquared <= 0.01 || GetVectorDotProduct(pathVector, toClient) / lengthSquared >= 0.5)
        {
            index++;
            continue;
        }
        break;
    }
    return index;
}

bool AIPathSnapshot_GetLookAheadGoal(int client, float maxDistance, float lateralOffset, float goal[3], int maxDepth)
{
    if (maxDistance <= 0.0)
        return false;

    int count, currentIndex;
    bool complete;
    float age;
    if (!AIPathSnapshot_GetInfo(client, count, currentIndex, complete, age) ||
        currentIndex < 0 || age < 0.0 || age > AI_PATH_SNAPSHOT_STALE_TIME)
        return false;

    int end = AIPathSnapshot_ClampEnd(count, currentIndex, maxDepth);
    float position[3];
    GetClientAbsOrigin(client, position);
    int startIndex = AIPathSnapshot_FindForwardStart(client, position, currentIndex, end);

    AIPathSnapshotSegment segment;
    if (!AIPathSnapshot_ReadSegment(client, startIndex, segment) ||
        segment.segmentType != view_as<int>(AnneNextBotPathSegment_OnGround))
        return false;

    int candidates[16];
    int candidateCount;
    for (int i = startIndex; i < end && candidateCount < sizeof(candidates); i++)
    {
        if (!AIPathSnapshot_ReadSegment(client, i, segment) ||
            segment.segmentType != view_as<int>(AnneNextBotPathSegment_OnGround) ||
            segment.goal[2] - position[2] > AI_PATH_SNAPSHOT_MAX_JUMP_HEIGHT)
            break;

        float distance = AIPathSnapshot_Distance2D(position, segment.goal);
        if (distance > maxDistance && candidateCount > 0)
            break;
        candidates[candidateCount++] = i;
        if (distance >= maxDistance)
            break;
    }
    if (candidateCount < 1)
        return false;

    float start[3];
    start = position;
    start[2] += AI_PATH_SNAPSHOT_CENTER_HEIGHT;
    int selected = -1;
    for (int i = candidateCount - 1; i >= 0; i--)
    {
        if (!AIPathSnapshot_ReadSegment(client, candidates[i], segment))
            continue;
        if (AIPathSnapshot_TraceClear(client, start, segment.goal))
        {
            selected = candidates[i];
            break;
        }
    }
    if (selected < 0 || !AIPathSnapshot_ReadSegment(client, selected, segment))
        return false;

    goal = segment.goal;
    if (FloatAbs(lateralOffset) <= 0.01)
        return true;

    float direction[3];
    direction = segment.pathForward;
    direction[2] = 0.0;
    if (GetVectorLength(direction) < 0.01 && selected > currentIndex)
    {
        AIPathSnapshotSegment previous;
        if (AIPathSnapshot_ReadSegment(client, selected - 1, previous))
            MakeVectorFromPoints(previous.goal, goal, direction);
    }
    direction[2] = 0.0;
    if (NormalizeVector(direction, direction) <= 0.0)
        return true;

    float offsetGoal[3];
    offsetGoal = goal;
    offsetGoal[0] += -direction[1] * lateralOffset;
    offsetGoal[1] += direction[0] * lateralOffset;
    if (AIPathSnapshot_TraceClear(client, start, offsetGoal))
        goal = offsetGoal;
    return true;
}

float AIPathSnapshot_GetSuggestedLateralOffset(int client, float maxOffset)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || maxOffset <= 0.0)
        return 0.0;

    int lane = (GetClientUserId(client) * 31 + GetEntProp(client, Prop_Send, "m_zombieClass") * 17) & 3;
    switch (lane)
    {
        case 0: return -maxOffset;
        case 1: return -maxOffset * 0.4;
        case 2: return maxOffset * 0.4;
    }
    return maxOffset;
}
