#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <anne_spawn_accel>

native int NextBotCreatePlayerBotSurvivorBot(const char[] name = NULL_STRING);
native bool CTerrorPlayerRoundRespawn(int client);

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define TEST_SURVIVORS 4
#define MATRIX_GRAPH_RESULTS 512
#define MATRIX_MAX_PATH 3000.0
#define MATRIX_OBSERVER_MAX_PATH 6000.0
#define MATRIX_SPREAD_MIN 128.0
#define MATRIX_MEMBER_RADIUS_MAX 650.0
#define MATRIX_TEAM_SPREAD_MAX 800.0
#define MATRIX_SPREAD_PATH_MAX 1600.0
#define MATRIX_SPREAD_FLOW_TOLERANCE 6.0
#define MATRIX_SPREAD_PATH_CANDIDATES 24

#define TERROR_NAV_PLAYER_START   (1 << 7)
#define TERROR_NAV_CHECKPOINT     (1 << 11)
#define TERROR_NAV_RESCUE_VEHICLE (1 << 15)
#define TERROR_NAV_RESCUE_CLOSET  (1 << 16)

ArrayList g_NavAreas;
char g_CurrentMap[64];
bool g_HasTargetPosition[MAXPLAYERS + 1];
float g_TargetPosition[MAXPLAYERS + 1][3];
float g_TargetAngles[MAXPLAYERS + 1][3];
int g_TargetNavId[MAXPLAYERS + 1];
ArrayList g_RejectedTargetNavIds;
int g_RejectedPercent = -1;
bool g_HasPendingAnchor;
Address g_PendingSourceArea = Address_Null;
Address g_PendingActualArea = Address_Null;
float g_PendingAnchorPosition[3];
float g_InfectedBornAt[MAXPLAYERS + 1];
int g_InfectedBornClass[MAXPLAYERS + 1];
int g_SpawnVisibilityChecks;
int g_SpawnVisibilityViolations;
bool g_VisibilityChecked[MAXPLAYERS + 1];
bool g_ProbeRecorded[MAXPLAYERS + 1];
bool g_ProbePending[MAXPLAYERS + 1];
int g_ProbeSamples;
int g_ProbeClassCounts[7];
float g_FormationMinDistance;
float g_FormationMaxDistance;
bool g_FrameMeasureActive;
float g_FrameLastAt;
float g_FrameDeltaTotalMs;
float g_FrameDeltaMaxMs;
int g_FrameSamples;
int g_FrameOverTick;
int g_FrameOver2Tick;
int g_FrameOver4Tick;

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("AnneSpawn_IsActive");
    MarkNativeAsOptional("AnneSpawn_NavGraphPump");
    MarkNativeAsOptional("AnneSpawn_NavGraphStart");
    MarkNativeAsOptional("AnneSpawn_NavGraphPrepareRange");
    MarkNativeAsOptional("AnneSpawn_NavGraphCollectRange");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetPathDistance");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetAreaCount");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetEdgeCount");
    MarkNativeAsOptional("AnneSpawn_NavGraphGetDiagnostics");
    return APLRes_Success;
}

public Plugin myinfo =
{
    name = "Anne Nav Wave Matrix Probe",
    author = "AnneHappy",
    description = "Positions survivor bots at raw-flow checkpoints for spawn matrix tests",
    version = "1.3.0",
    url = "https://github.com/morzlee/CompetitiveWithAnne"
};

public void OnPluginStart()
{
    RegAdminCmd("sm_navmatrix_prepare", Command_Prepare, ADMFLAG_ROOT,
        "sm_navmatrix_prepare <raw-flow-percent>");
    RegAdminCmd("sm_navmatrix_clear", Command_Clear, ADMFLAG_ROOT,
        "Remove test special infected");
    RegAdminCmd("sm_navmatrix_status", Command_Status, ADMFLAG_ROOT,
        "Show test survivor and infected counts");
    RegAdminCmd("sm_navmatrix_activate", Command_Activate, ADMFLAG_ROOT,
        "Create survivor bots and initialize an empty-server test round");
    RegAdminCmd("sm_navmatrix_mark", Command_Mark, ADMFLAG_ROOT,
        "sm_navmatrix_mark <text>");
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
}

public void OnMapStart()
{
    GetCurrentMap(g_CurrentMap, sizeof(g_CurrentMap));
    for (int client = 1; client <= MaxClients; client++)
    {
        g_HasTargetPosition[client] = false;
        g_TargetNavId[client] = -1;
        g_InfectedBornAt[client] = 0.0;
        g_InfectedBornClass[client] = 0;
        g_VisibilityChecked[client] = false;
        g_ProbeRecorded[client] = false;
        g_ProbePending[client] = false;
    }
    delete g_NavAreas;
    g_NavAreas = null;
    delete g_RejectedTargetNavIds;
    g_RejectedTargetNavIds = new ArrayList();
    g_RejectedPercent = -1;
    g_HasPendingAnchor = false;
    g_PendingSourceArea = Address_Null;
    g_PendingActualArea = Address_Null;
    g_SpawnVisibilityChecks = 0;
    g_SpawnVisibilityViolations = 0;
    g_ProbeSamples = 0;
    for (int zombieClass = 0; zombieClass < sizeof(g_ProbeClassCounts); zombieClass++)
        g_ProbeClassCounts[zombieClass] = 0;
    g_FormationMinDistance = 0.0;
    g_FormationMaxDistance = 0.0;
    g_FrameMeasureActive = false;
    g_FrameLastAt = 0.0;
    g_FrameDeltaTotalMs = 0.0;
    g_FrameDeltaMaxMs = 0.0;
    g_FrameSamples = 0;
    g_FrameOverTick = 0;
    g_FrameOver2Tick = 0;
    g_FrameOver4Tick = 0;
}

static float MatrixNormalizeYaw(float yaw)
{
    while (yaw > 180.0)
        yaw -= 360.0;
    while (yaw <= -180.0)
        yaw += 360.0;
    return yaw;
}

void SynchronizeSurvivorPositions()
{
    float current[3];
    float currentAngles[3];
    float stopped[3];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_HasTargetPosition[client] || !IsClientInGame(client)
            || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
        {
            continue;
        }

        GetClientAbsOrigin(client, current);
        GetClientEyeAngles(client, currentAngles);
        if (GetVectorDistance(current, g_TargetPosition[client]) > 1.0
            || FloatAbs(MatrixNormalizeYaw(
                    currentAngles[1] - g_TargetAngles[client][1])) > 1.0)
        {
            TeleportEntity(client, g_TargetPosition[client],
                g_TargetAngles[client], stopped);
        }
    }
}

public void OnGameFrame()
{
    if (g_FrameMeasureActive)
    {
        float now = GetEngineTime();
        if (g_FrameLastAt > 0.0)
        {
            float deltaMs = (now - g_FrameLastAt) * 1000.0;
            g_FrameSamples++;
            g_FrameDeltaTotalMs += deltaMs;
            if (deltaMs > g_FrameDeltaMaxMs)
                g_FrameDeltaMaxMs = deltaMs;

            // 容忍少量计时量化误差，避免把正常 128 tick 误记成超预算。
            if (deltaMs > 7.8125 + 0.25) g_FrameOverTick++;
            if (deltaMs > 15.625 + 0.25) g_FrameOver2Tick++;
            if (deltaMs > 31.25 + 0.25) g_FrameOver4Tick++;
        }
        g_FrameLastAt = now;
    }
    SynchronizeSurvivorPositions();
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
    if (client <= 0 || client > MaxClients || !g_VisibilityChecked[client]
        || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED
        || !IsPlayerAlive(client))
    {
        return Plugin_Continue;
    }

    // 测试只固定已提交特感的主动行为；实体仍按正常物理落地并继续
    // 接受 trigger_hurt / 世界伤害，避免把出生后的 AI 游走算成刷点失败。
    int moveButtons = IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT
        | IN_JUMP | IN_SPEED | IN_ATTACK | IN_ATTACK2;
    buttons &= ~moveButtons;
    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    return Plugin_Changed;
}

public void OnClientDisconnect(int client)
{
    g_HasTargetPosition[client] = false;
    g_TargetNavId[client] = -1;
    g_InfectedBornAt[client] = 0.0;
    g_InfectedBornClass[client] = 0;
    g_VisibilityChecked[client] = false;
    g_ProbeRecorded[client] = false;
    g_ProbePending[client] = false;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != TEAM_INFECTED)
        return;

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass < 1 || zombieClass > 6)
        return;

    g_InfectedBornAt[client] = GetGameTime();
    g_InfectedBornClass[client] = zombieClass;
    g_VisibilityChecked[client] = false;
    g_ProbeRecorded[client] = false;
    g_ProbePending[client] = true;
    MatrixLog("InfectedSpawn userid=%d client=%d class=%d alive=%d ghost=%d",
        GetClientUserId(client), client, zombieClass,
        IsPlayerAlive(client) ? 1 : 0,
        GetEntProp(client, Prop_Send, "m_isGhost") != 0 ? 1 : 0);
    CreateTimer(0.30, Timer_RecordProbeSpawn, GetClientUserId(client),
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

bool FinalizeVisibilityCheck(int client)
{
    if (client <= 0 || !IsClientInGame(client)
        || GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client)
        || GetEntProp(client, Prop_Send, "m_isGhost") != 0
        || IsClientInKickQueue(client))
    {
        return false;
    }

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass < 1 || zombieClass > 6)
        return false;

    float origin[3];
    GetClientAbsOrigin(client, origin);
    int rayVisibleMask;
    int engineVisibleMask;
    int controlledSlot;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!g_HasTargetPosition[survivor] || !IsClientInGame(survivor)
            || GetClientTeam(survivor) != TEAM_SURVIVOR || !IsPlayerAlive(survivor))
        {
            continue;
        }

        float eyes[3];
        float head[3];
        float chest[3];
        GetClientEyePosition(survivor, eyes);
        head = origin;
        head[2] += 62.0;
        chest = origin;
        chest[2] += 32.0;
        Handle trace = TR_TraceRayFilterEx(
            eyes, head, MASK_VISIBLE & MASK_SHOT,
            RayType_EndPoint, MatrixTraceFilter);
        if (!TR_DidHit(trace) || TR_GetFraction(trace) >= 0.99)
            rayVisibleMask |= 1 << controlledSlot;
        delete trace;
        if (L4D2_IsVisibleToPlayer(
                survivor, TEAM_SURVIVOR, TEAM_INFECTED, 0, chest))
        {
            engineVisibleMask |= 1 << controlledSlot;
        }
        controlledSlot++;
    }
    g_SpawnVisibilityChecks++;
    g_VisibilityChecked[client] = true;
    if (rayVisibleMask != 0 || engineVisibleMask != 0)
        g_SpawnVisibilityViolations++;
    MatrixLog("SpawnVisibility userid=%d class=%d survivors=%d rayMask=%d engineMask=%d violation=%d pos=(%.1f %.1f %.1f)",
        GetClientUserId(client), zombieClass, controlledSlot,
        rayVisibleMask, engineVisibleMask,
        (rayVisibleMask != 0 || engineVisibleMask != 0) ? 1 : 0,
        origin[0], origin[1], origin[2]);
    return true;
}

public void InfectedControl_OnSpawnCommitted(int userid)
{
    FinalizeVisibilityCheck(GetClientOfUserId(userid));
}

public Action Timer_RecordProbeSpawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)
        || GetClientTeam(client) != TEAM_INFECTED || !IsFakeClient(client)
        || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_isGhost") != 0
        || IsClientInKickQueue(client))
    {
        return Plugin_Stop;
    }
    if (g_ProbeRecorded[client])
        return Plugin_Stop;

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass < 1 || zombieClass > 6)
        return Plugin_Stop;

    if (!g_VisibilityChecked[client] && !FinalizeVisibilityCheck(client))
        return Plugin_Stop;

    float origin[3];
    GetClientAbsOrigin(client, origin);
    float teamMin = 1.0e30;
    float teamMax;
    int survivorCount;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!g_HasTargetPosition[survivor] || !IsClientInGame(survivor)
            || GetClientTeam(survivor) != TEAM_SURVIVOR || !IsPlayerAlive(survivor))
        {
            continue;
        }
        float eyes[3];
        GetClientEyePosition(survivor, eyes);
        float distance = GetVectorDistance(origin, eyes);
        if (distance < teamMin) teamMin = distance;
        if (distance > teamMax) teamMax = distance;
        survivorCount++;
    }
    if (survivorCount <= 0)
        return Plugin_Stop;

    Address actualArea = L4D2Direct_GetTerrorNavArea(origin);
    if (actualArea == Address_Null)
        actualArea = L4D_GetNearestNavArea(
            origin, 120.0, false, false, false, TEAM_INFECTED);
    int actualNavId = actualArea != Address_Null
        ? L4D_GetNavAreaID(actualArea) : -1;
    float nearestNavDistance = 1.0e30;
    int nearestTargetClient;
    int nearestTargetNavId = -1;
    int reachableTargets;
    int unreachableTargets;
    int unavailableTargets;
    int pendingTargets;
    int configuredTargets;
    bool navPending;
    FeatureStatus distanceNativeStatus = GetFeatureStatus(
        FeatureType_Native, "AnneSpawn_NavGraphGetPathDistance");
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (g_HasTargetPosition[survivor] && g_TargetNavId[survivor] > 0)
            configuredTargets++;
    }
    if (actualNavId > 0 && distanceNativeStatus == FeatureStatus_Available)
    {
        for (int survivor = 1; survivor <= MaxClients; survivor++)
        {
            if (!g_HasTargetPosition[survivor] || g_TargetNavId[survivor] <= 0)
                continue;
            float navDistance;
            int result = AnneSpawn_NavGraphGetPathDistance(
                actualNavId, g_TargetNavId[survivor], MATRIX_OBSERVER_MAX_PATH,
                TEAM_INFECTED, false, navDistance);
            if (result == ANNE_SPAWN_NAV_DISTANCE_PENDING)
            {
                navPending = true;
                pendingTargets++;
                continue;
            }
            if (result == 0)
            {
                unreachableTargets++;
                continue;
            }
            if (result != 1)
            {
                unavailableTargets++;
                continue;
            }
            reachableTargets++;
            if (navDistance < nearestNavDistance)
            {
                nearestNavDistance = navDistance;
                nearestTargetClient = survivor;
                nearestTargetNavId = g_TargetNavId[survivor];
            }
        }
    }
    if (navPending && GetGameTime() - g_InfectedBornAt[client] < 3.0)
        return Plugin_Continue;

    if (nearestTargetNavId < 0)
        nearestNavDistance = -1.0;
    g_ProbeRecorded[client] = true;
    g_ProbePending[client] = false;
    g_ProbeSamples++;
    g_ProbeClassCounts[zombieClass]++;
    MatrixLog("ProbeSpawn seq=%d userid=%d client=%d class=%d survivors=%d configuredTargets=%d distanceNativeStatus=%d actualNav=%d targetNav=%d targetClient=%d reachableTargets=%d unreachableTargets=%d unavailableTargets=%d pendingTargets=%d teamMinDistance=%.1f teamMaxDistance=%.1f nearestNavDistance=%.1f pos=(%.1f %.1f %.1f)",
        g_ProbeSamples, userid, client, zombieClass, survivorCount,
        configuredTargets, view_as<int>(distanceNativeStatus), actualNavId,
        nearestTargetNavId, nearestTargetClient, reachableTargets,
        unreachableTargets, unavailableTargets, pendingTargets,
        teamMin, teamMax, nearestNavDistance,
        origin[0], origin[1], origin[2]);
    return Plugin_Stop;
}

public bool MatrixTraceFilter(int entity, int contentsMask)
{
    return entity > MaxClients && IsValidEntity(entity);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || client > MaxClients || g_InfectedBornClass[client] <= 0)
        return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int attackerTeam;
    if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker))
        attackerTeam = GetClientTeam(attacker);

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    float lifetime = GetGameTime() - g_InfectedBornAt[client];
    float lifetimeMs = (lifetime > 0.0 ? lifetime : 0.0) * 1000.0;
    MatrixLog("InfectedDeath userid=%d client=%d class=%d lifetimeMs=%.1f attacker=%d attackerTeam=%d weapon=%s type=%d",
        event.GetInt("userid"), client, g_InfectedBornClass[client], lifetimeMs,
        attacker, attackerTeam, weapon, event.GetInt("type"));
    g_InfectedBornAt[client] = 0.0;
    g_InfectedBornClass[client] = 0;
    g_VisibilityChecked[client] = false;
    g_ProbeRecorded[client] = false;
    g_ProbePending[client] = false;
}

public void OnPluginEnd()
{
    delete g_NavAreas;
    g_NavAreas = null;
    delete g_RejectedTargetNavIds;
    g_RejectedTargetNavIds = null;
}

void MatrixLog(const char[] format, any ...)
{
    char message[768];
    VFormat(message, sizeof(message), format, 2);
    PrintToServer("[NavMatrix] %s", message);
    LogToFile("addons/sourcemod/logs/infected_control_fdxxnav.txt",
        "[NavMatrix] %s", message);
}

bool EnsureNavAreas()
{
    if (g_NavAreas != null && g_NavAreas.Length > 0)
        return true;

    delete g_NavAreas;
    g_NavAreas = new ArrayList();
    L4D_GetAllNavAreas(g_NavAreas);
    return g_NavAreas.Length > 0;
}

bool IsUsableRouteArea(Address area, float maxFlow, float &flow)
{
    if (area == Address_Null)
        return false;

    int flags = L4D_GetNavArea_SpawnAttributes(area);
    int excluded = TERROR_NAV_PLAYER_START | TERROR_NAV_CHECKPOINT |
        TERROR_NAV_RESCUE_VEHICLE | TERROR_NAV_RESCUE_CLOSET;
    if ((flags & excluded) != 0)
        return false;

    int adjacent;
    for (int direction = 0; direction < 4; direction++)
        adjacent += L4D_NavArea_GetAdjacentCount(area, direction);
    if (adjacent <= 0)
        return false;

    flow = L4D2Direct_GetTerrorNavAreaFlow(area);
    return flow >= 0.0 && flow <= maxFlow;
}

Address FindRouteStartArea(float maxFlow)
{
    Address best = Address_Null;
    float bestFlow = maxFlow + 1.0;
    for (int i = 0; i < g_NavAreas.Length; i++)
    {
        Address area = g_NavAreas.Get(i);
        float flow;
        if (!IsUsableRouteArea(area, maxFlow, flow) || flow >= bestFlow)
            continue;
        best = area;
        bestFlow = flow;
    }
    return best;
}

bool HasGraphNatives()
{
    return LibraryExists(ANNE_SPAWN_ACCEL_LIBRARY)
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_IsActive") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphPump") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphPrepareRange") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphCollectRange") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphGetDiagnostics") == FeatureStatus_Available
        && AnneSpawn_IsActive();
}

bool EnsureObserverGraphStarted()
{
    if (!LibraryExists(ANNE_SPAWN_ACCEL_LIBRARY)
        || GetFeatureStatus(FeatureType_Native, "AnneSpawn_IsActive") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphStart") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphPump") != FeatureStatus_Available
        || !AnneSpawn_IsActive())
    {
        return false;
    }

    AnneSpawnNavGraphStatus status = AnneSpawn_NavGraphPump(false);
    if (status == AnneSpawnNavGraph_Ready
        || status == AnneSpawnNavGraph_Loading
        || status == AnneSpawnNavGraph_Building)
    {
        return true;
    }

    char mapName[64];
    char graphPath[PLATFORM_MAX_PATH];
    GetCurrentMap(mapName, sizeof(mapName));
    float maxFlowDistance = L4D2Direct_GetMapMaxFlowDistance();
    if (mapName[0] == '\0' || maxFlowDistance <= 0.0
        || BuildPath(Path_SM, graphPath, sizeof(graphPath),
            "data/anne_spawn_accel/navgraph/%s.anvg", mapName) <= 0)
    {
        return false;
    }
    return AnneSpawn_NavGraphStart(
        mapName, graphPath, maxFlowDistance, false);
}

bool GetLiveNavArea(int client, Address &area, float position[3])
{
    area = Address_Null;
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return false;

    GetClientAbsOrigin(client, position);
    area = L4D2Direct_GetTerrorNavArea(position);
    if (area == Address_Null)
        area = L4D_GetNearestNavArea(position, 120.0, false, false, false, TEAM_INFECTED);
    return area != Address_Null;
}

bool TryGetDirectedCoverage(Address area, bool &pending,
                            int &nearCount, int &longCount, int &broadCount)
{
    pending = false;
    nearCount = 0;
    longCount = 0;
    broadCount = 0;
    if (area == Address_Null || !HasGraphNatives())
        return false;

    AnneSpawnNavGraphStatus status = AnneSpawn_NavGraphPump(false);
    if (status != AnneSpawnNavGraph_Ready)
    {
        pending = true;
        return false;
    }

    char reason[384];
    int diagnostics = AnneSpawn_NavGraphGetDiagnostics(reason, sizeof(reason));
    if (diagnostics < 0 || (diagnostics & ANNE_SPAWN_NAV_DIAG_COMPLETE) == 0)
        return false;

    int navId = L4D_GetNavAreaID(area);
    AnneSpawn_NavGraphPrepareRange(navId, MATRIX_MAX_PATH, TEAM_INFECTED, false);

    int output[MATRIX_GRAPH_RESULTS];
    nearCount = AnneSpawn_NavGraphCollectRange(navId, 250.0, 700.0,
        output, sizeof(output));
    longCount = AnneSpawn_NavGraphCollectRange(navId, 500.0, 1200.0,
        output, sizeof(output));
    broadCount = AnneSpawn_NavGraphCollectRange(navId, 250.0, MATRIX_MAX_PATH,
        output, sizeof(output));
    if (nearCount < 0 || longCount < 0 || broadCount < 0)
    {
        pending = true;
        return false;
    }
    // 落点只验证存在 candidate -> target 的感染者有向入口。near/long 数量
    // 作为诊断记录；某个职业首层为空时应由生产逻辑逐层放宽，而不是让探针换进度。
    return broadCount > 0;
}

bool IsRejectedTargetNav(int navId)
{
    return g_RejectedTargetNavIds != null
        && g_RejectedTargetNavIds.FindValue(navId) >= 0;
}

Address FindFlowArea(float targetFlow, float maxFlow, Address routeStart)
{
    Address best = Address_Null;
    float bestScore = 1.0e30;
    for (int i = 0; i < g_NavAreas.Length; i++)
    {
        Address area = g_NavAreas.Get(i);
        float flow;
        if (!IsUsableRouteArea(area, maxFlow, flow))
            continue;
        int navId = L4D_GetNavAreaID(area);
        if (IsRejectedTargetNav(navId))
            continue;

        float score = FloatAbs(flow - targetFlow) * 16.0;
        if (score >= bestScore)
            continue;
        if (area != routeStart && !L4D2_NavAreaBuildPath(
            routeStart, area, maxFlow * 2.0, TEAM_SURVIVOR, true))
        {
            continue;
        }
        best = area;
        bestScore = score;
    }
    return best;
}

float DistanceToClosestSelected(const float position[3],
                                const float selectedPositions[TEST_SURVIVORS][3],
                                int selectedCount)
{
    float closest = 1.0e30;
    for (int i = 0; i < selectedCount; i++)
    {
        float distance = GetVectorDistance(position, selectedPositions[i]);
        if (distance < closest)
            closest = distance;
    }
    return closest;
}

bool SelectSpreadFormation(Address anchorArea, const float anchor[3],
                           float maxFlow,
                           Address selectedAreas[TEST_SURVIVORS],
                           float selectedPositions[TEST_SURVIVORS][3])
{
    selectedAreas[0] = anchorArea;
    selectedPositions[0] = anchor;
    int selectedCount = 1;
    int anchorId = L4D_GetNavAreaID(anchorArea);

    while (selectedCount < TEST_SURVIVORS)
    {
        Address bestArea = Address_Null;
        float bestPosition[3];
        Address pathCandidates[MATRIX_SPREAD_PATH_CANDIDATES];
        float pathPositions[MATRIX_SPREAD_PATH_CANDIDATES][3];
        float pathScores[MATRIX_SPREAD_PATH_CANDIDATES];
        int pathCandidateCount;
        for (int i = 0; i < g_NavAreas.Length; i++)
        {
            Address area = g_NavAreas.Get(i);
            float flow;
            if (!IsUsableRouteArea(area, maxFlow, flow))
                continue;

            int navId = L4D_GetNavAreaID(area);
            bool duplicate = false;
            for (int chosen = 0; chosen < selectedCount; chosen++)
            {
                if (navId == L4D_GetNavAreaID(selectedAreas[chosen]))
                    duplicate = true;
            }
            if (duplicate)
                continue;

            float flowDeltaPct = FloatAbs(
                L4D2Direct_GetTerrorNavAreaFlow(anchorArea) - flow) * 100.0 / maxFlow;
            if (flowDeltaPct > MATRIX_SPREAD_FLOW_TOLERANCE)
                continue;

            float center[3];
            L4D_GetNavAreaCenter(area, center);
            float anchorDistance = GetVectorDistance(anchor, center);
            if (anchorDistance < MATRIX_SPREAD_MIN
                || anchorDistance > MATRIX_MEMBER_RADIUS_MAX)
                continue;

            float separation = DistanceToClosestSelected(
                center, selectedPositions, selectedCount);
            if (separation < MATRIX_SPREAD_MIN)
                continue;
            bool tooSpread;
            for (int chosen = 0; chosen < selectedCount; chosen++)
            {
                if (GetVectorDistance(center, selectedPositions[chosen])
                    > MATRIX_TEAM_SPREAD_MAX)
                {
                    tooSpread = true;
                }
            }
            if (tooSpread)
                continue;

            int slot = pathCandidateCount;
            if (pathCandidateCount < MATRIX_SPREAD_PATH_CANDIDATES)
            {
                pathCandidateCount++;
            }
            else
            {
                slot = 0;
                for (int candidate = 1; candidate < pathCandidateCount; candidate++)
                {
                    if (pathScores[candidate] < pathScores[slot])
                        slot = candidate;
                }
                if (separation <= pathScores[slot])
                    continue;
            }
            pathCandidates[slot] = area;
            pathPositions[slot] = center;
            pathScores[slot] = separation;
        }

        // BuildPath is synchronous and can be expensive on large Nav meshes.
        // Cheap-sort first, then validate only the strongest bounded candidates.
        for (int tested = 0; tested < pathCandidateCount; tested++)
        {
            int slot = -1;
            for (int candidate = 0; candidate < pathCandidateCount; candidate++)
            {
                if (pathScores[candidate] < 0.0)
                    continue;
                if (slot < 0 || pathScores[candidate] > pathScores[slot])
                    slot = candidate;
            }
            if (slot < 0)
                break;
            pathScores[slot] = -1.0;
            Address area = pathCandidates[slot];
            if (area != anchorArea && !L4D2_NavAreaBuildPath(
                    anchorArea, area, MATRIX_SPREAD_PATH_MAX, TEAM_SURVIVOR, true))
                continue;
            bestArea = area;
            bestPosition = pathPositions[slot];
            break;
        }

        if (bestArea == Address_Null)
        {
            MatrixLog("SpreadFail map=%s anchorArea=%d selected=%d min=%.0f memberRadiusMax=%.0f teamSpreadMax=%.0f flowTolerance=%.1f",
                g_CurrentMap, anchorId, selectedCount,
                MATRIX_SPREAD_MIN, MATRIX_MEMBER_RADIUS_MAX,
                MATRIX_TEAM_SPREAD_MAX, MATRIX_SPREAD_FLOW_TOLERANCE);
            return false;
        }

        L4D_FindRandomSpot(view_as<int>(bestArea), bestPosition);
        bestPosition[2] += 8.0;
        Address actualArea = L4D2Direct_GetTerrorNavArea(bestPosition);
        if (actualArea == Address_Null)
            actualArea = L4D_GetNearestNavArea(
                bestPosition, 120.0, false, false, false, TEAM_SURVIVOR);
        if (actualArea == Address_Null)
            return false;

        float actualSeparation = DistanceToClosestSelected(
            bestPosition, selectedPositions, selectedCount);
        if (actualSeparation < MATRIX_SPREAD_MIN)
            return false;
        if (GetVectorDistance(bestPosition, anchor) > MATRIX_MEMBER_RADIUS_MAX)
            return false;
        for (int chosen = 0; chosen < selectedCount; chosen++)
        {
            if (GetVectorDistance(bestPosition, selectedPositions[chosen])
                > MATRIX_TEAM_SPREAD_MAX)
            {
                return false;
            }
        }

        selectedAreas[selectedCount] = actualArea;
        selectedPositions[selectedCount] = bestPosition;
        selectedCount++;
    }
    return true;
}

void GetFormationDistances(const float positions[TEST_SURVIVORS][3],
                           float &minDistance, float &maxDistance)
{
    minDistance = 1.0e30;
    maxDistance = 0.0;
    for (int first = 0; first < TEST_SURVIVORS; first++)
    {
        for (int second = first + 1; second < TEST_SURVIVORS; second++)
        {
            float distance = GetVectorDistance(positions[first], positions[second]);
            if (distance < minDistance)
                minDistance = distance;
            if (distance > maxDistance)
                maxDistance = distance;
        }
    }
}

float FindFormationForwardYaw(Address anchorArea, const float anchor[3],
                              float maxFlow)
{
    float anchorFlow = L4D2Direct_GetTerrorNavAreaFlow(anchorArea);
    float bestScore = -1.0;
    float bestPosition[3];
    for (int i = 0; i < g_NavAreas.Length; i++)
    {
        Address area = g_NavAreas.Get(i);
        float flow;
        if (!IsUsableRouteArea(area, maxFlow, flow) || flow <= anchorFlow)
            continue;

        float center[3];
        L4D_GetNavAreaCenter(area, center);
        float distance = GetVectorDistance(anchor, center);
        if (distance < MATRIX_SPREAD_MIN || distance > 1500.0)
            continue;

        // Prefer a nearby Nav that clearly advances map flow. This gives the
        // frozen test team one realistic forward-facing field of view instead
        // of four clients covering the full 360 degrees.
        float score = (flow - anchorFlow) / distance;
        if (score <= bestScore)
            continue;
        bestScore = score;
        bestPosition = center;
    }

    if (bestScore < 0.0)
        return 0.0;

    float direction[3];
    MakeVectorFromPoints(anchor, bestPosition, direction);
    direction[2] = 0.0;
    float angles[3];
    GetVectorAngles(direction, angles);
    return angles[1];
}

int CountTeam(int team, bool botsOnly = false)
{
    int count;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || GetClientTeam(client) != team)
            continue;
        if (botsOnly && !IsFakeClient(client))
            continue;
        count++;
    }
    return count;
}

int CountAliveSpecialBots()
{
    int count;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client)
            || GetClientTeam(client) != TEAM_INFECTED || !IsPlayerAlive(client)
            || GetEntProp(client, Prop_Send, "m_isGhost") != 0
            || !g_VisibilityChecked[client])
        {
            continue;
        }
        int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
        if (zombieClass >= 1 && zombieClass <= 6)
            count++;
    }
    return count;
}

int CountUniqueControlledNavs()
{
    int navIds[TEST_SURVIVORS];
    int count;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!g_HasTargetPosition[client] || g_TargetNavId[client] < 0)
            continue;
        bool found = false;
        for (int i = 0; i < count; i++)
        {
            if (navIds[i] == g_TargetNavId[client])
                found = true;
        }
        if (!found && count < TEST_SURVIVORS)
            navIds[count++] = g_TargetNavId[client];
    }
    return count;
}

int CountHumanClients(int team = -1)
{
    int count;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;
        if (team >= 0 && GetClientTeam(client) != team)
            continue;
        count++;
    }
    return count;
}

bool EnsureFourSurvivors()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR)
            continue;
        if (!IsPlayerAlive(client))
            CTerrorPlayerRoundRespawn(client);
    }

    int guard;
    while (CountTeam(TEAM_SURVIVOR) < TEST_SURVIVORS && guard++ < 8)
    {
        int bot = NextBotCreatePlayerBotSurvivorBot(NULL_STRING);
        if (bot <= 0 || !IsClientInGame(bot))
            break;
        ChangeClientTeam(bot, TEAM_SURVIVOR);
        if (!IsPlayerAlive(bot))
            CTerrorPlayerRoundRespawn(bot);
    }

    return CountTeam(TEAM_SURVIVOR) >= TEST_SURVIVORS;
}

public Action Command_Prepare(int client, int args)
{
    if (args != 1)
    {
        ReplyToCommand(client, "[NavMatrix] usage: sm_navmatrix_prepare <0-100>");
        return Plugin_Handled;
    }

    char value[16];
    GetCmdArg(1, value, sizeof(value));
    int requestedPercent = StringToInt(value);
    if (requestedPercent < 0 || requestedPercent > 100)
    {
        ReplyToCommand(client, "[NavMatrix] percent must be in 0..100");
        return Plugin_Handled;
    }

    if (g_RejectedTargetNavIds == null)
        g_RejectedTargetNavIds = new ArrayList();
    if (g_RejectedPercent != requestedPercent)
    {
        g_RejectedTargetNavIds.Clear();
        g_RejectedPercent = requestedPercent;
        g_HasPendingAnchor = false;
        g_PendingSourceArea = Address_Null;
        g_PendingActualArea = Address_Null;
    }

    if (!EnsureNavAreas() || !EnsureFourSurvivors())
    {
        ReplyToCommand(client, "[NavMatrix] prepare failed: nav or survivors unavailable");
        return Plugin_Handled;
    }

    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0)
    {
        ReplyToCommand(client, "[NavMatrix] prepare failed: max flow %.1f", maxFlow);
        return Plugin_Handled;
    }

    float targetFlow = maxFlow * float(requestedPercent) / 100.0;
    Address routeStart = FindRouteStartArea(maxFlow);
    if (routeStart == Address_Null)
    {
        ReplyToCommand(client, "[NavMatrix] prepare failed: no route start area");
        return Plugin_Handled;
    }
    int nearCount;
    int longCount;
    int broadCount;
    if (!g_HasPendingAnchor)
    {
        g_PendingSourceArea = FindFlowArea(targetFlow, maxFlow, routeStart);
        if (g_PendingSourceArea == Address_Null)
        {
            ReplyToCommand(client, "[NavMatrix] prepare failed: no route area");
            return Plugin_Handled;
        }

        L4D_FindRandomSpot(view_as<int>(g_PendingSourceArea), g_PendingAnchorPosition);
        g_PendingAnchorPosition[2] += 8.0;
        g_PendingActualArea = L4D2Direct_GetTerrorNavArea(g_PendingAnchorPosition);
        if (g_PendingActualArea == Address_Null)
        {
            g_PendingActualArea = L4D_GetNearestNavArea(
                g_PendingAnchorPosition, 120.0, false, false, false, TEAM_INFECTED);
        }
        if (g_PendingActualArea == Address_Null)
        {
            g_RejectedTargetNavIds.Push(L4D_GetNavAreaID(g_PendingSourceArea));
            g_PendingSourceArea = Address_Null;
            ReplyToCommand(client, "[NavMatrix] prepare pending: generated point has no Nav");
            return Plugin_Handled;
        }
        g_HasPendingAnchor = true;
    }

    bool coveragePending;
    if (!TryGetDirectedCoverage(g_PendingActualArea, coveragePending,
            nearCount, longCount, broadCount))
    {
        if (!coveragePending)
        {
            float sourceFlow = L4D2Direct_GetTerrorNavAreaFlow(g_PendingSourceArea);
            float actualFlow = L4D2Direct_GetTerrorNavAreaFlow(g_PendingActualArea);
            MatrixLog("RejectTarget map=%s requested=%d sourceArea=%d sourcePct=%.2f actualArea=%d actualPct=%.2f directed(near/long/broad)=%d/%d/%d",
                g_CurrentMap, requestedPercent, L4D_GetNavAreaID(g_PendingSourceArea),
                sourceFlow * 100.0 / maxFlow, L4D_GetNavAreaID(g_PendingActualArea),
                actualFlow * 100.0 / maxFlow, nearCount, longCount, broadCount);
            g_RejectedTargetNavIds.Push(L4D_GetNavAreaID(g_PendingSourceArea));
            g_HasPendingAnchor = false;
            g_PendingSourceArea = Address_Null;
            g_PendingActualArea = Address_Null;
        }
        ReplyToCommand(client, "[NavMatrix] prepare pending: actual target Nav has no directed route yet");
        return Plugin_Handled;
    }

    Address anchorArea = g_PendingActualArea;
    float anchor[3];
    anchor = g_PendingAnchorPosition;
    int anchorId = L4D_GetNavAreaID(anchorArea);
    Address formationAreas[TEST_SURVIVORS];
    float formationPositions[TEST_SURVIVORS][3];
    if (!SelectSpreadFormation(
            anchorArea, anchor, maxFlow,
            formationAreas, formationPositions))
    {
        if (g_RejectedTargetNavIds.FindValue(anchorId) < 0)
            g_RejectedTargetNavIds.Push(anchorId);
        g_HasPendingAnchor = false;
        g_PendingSourceArea = Address_Null;
        g_PendingActualArea = Address_Null;
        ReplyToCommand(client, "[NavMatrix] prepare failed: no valid spread formation");
        return Plugin_Handled;
    }

    float formationMinDistance;
    float formationMaxDistance;
    for (int target = 1; target <= MaxClients; target++)
    {
        g_HasTargetPosition[target] = false;
        g_TargetNavId[target] = -1;
    }
    int survivorCount;
    float areaPercentTotal;
    float minAreaPercent = 101.0;
    float maxAreaPercent = -1.0;
    bool actualCoverageReady = true;
    float forwardYaw = FindFormationForwardYaw(anchorArea, anchor, maxFlow);
    static const float yawOffsets[TEST_SURVIVORS] = {
        -45.0, -15.0, 15.0, 45.0
    };

    for (int survivor = 1; survivor <= MaxClients && survivorCount < TEST_SURVIVORS; survivor++)
    {
        if (!IsClientInGame(survivor) || GetClientTeam(survivor) != TEAM_SURVIVOR)
            continue;
        if (!IsPlayerAlive(survivor))
            CTerrorPlayerRoundRespawn(survivor);

        float position[3];
        position = formationPositions[survivorCount];
        float angles[3] = {0.0, 0.0, 0.0};
        angles[1] = MatrixNormalizeYaw(
            forwardYaw + yawOffsets[survivorCount]);
        TeleportEntity(survivor, position, angles, NULL_VECTOR);
        SetEntityHealth(survivor, 100);

        float actual[3];
        Address actualArea;
        if (!GetLiveNavArea(survivor, actualArea, actual))
        {
            actualCoverageReady = false;
            continue;
        }
        formationPositions[survivorCount] = actual;
        g_TargetPosition[survivor] = actual;
        g_TargetAngles[survivor] = angles;
        g_TargetNavId[survivor] = L4D_GetNavAreaID(actualArea);
        g_HasTargetPosition[survivor] = true;
        float areaFlow = L4D2Direct_GetTerrorNavAreaFlow(actualArea);
        float areaPercent = areaFlow * 100.0 / maxFlow;
        areaPercentTotal += areaPercent;
        if (areaPercent < minAreaPercent) minAreaPercent = areaPercent;
        if (areaPercent > maxAreaPercent) maxAreaPercent = areaPercent;
        survivorCount++;

        bool actualPending;
        int actualNear;
        int actualLong;
        int actualBroad;
        if (!TryGetDirectedCoverage(actualArea, actualPending,
                actualNear, actualLong, actualBroad))
        {
            actualCoverageReady = false;
            coveragePending = coveragePending || actualPending;
        }

        MatrixLog("Survivor map=%s requested=%d client=%d slot=%d actualArea=%d actualPct=%.2f yaw=%.1f directed(near/long/broad)=%d/%d/%d pos=(%.1f %.1f %.1f)",
            g_CurrentMap, requestedPercent, survivor, survivorCount,
            L4D_GetNavAreaID(actualArea), areaPercent, angles[1],
            actualNear, actualLong, actualBroad,
            actual[0], actual[1], actual[2]);
    }

    if (survivorCount == TEST_SURVIVORS)
    {
        GetFormationDistances(
            formationPositions, formationMinDistance, formationMaxDistance);
        g_FormationMinDistance = formationMinDistance;
        g_FormationMaxDistance = formationMaxDistance;
        if (formationMinDistance < MATRIX_SPREAD_MIN
            || formationMaxDistance > MATRIX_TEAM_SPREAD_MAX)
        {
            actualCoverageReady = false;
        }
    }

    if (survivorCount != TEST_SURVIVORS || !actualCoverageReady)
    {
        if (!coveragePending && g_RejectedTargetNavIds.FindValue(anchorId) < 0)
            g_RejectedTargetNavIds.Push(anchorId);
        if (!coveragePending)
        {
            g_HasPendingAnchor = false;
            g_PendingSourceArea = Address_Null;
            g_PendingActualArea = Address_Null;
        }
        ReplyToCommand(client, "[NavMatrix] prepare %s: actual target Nav is not directed-ready",
            coveragePending ? "pending" : "failed");
        return Plugin_Handled;
    }

    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!g_HasTargetPosition[survivor] || g_TargetNavId[survivor] <= 0)
            continue;
        AnneSpawn_NavGraphPrepareRange(
            g_TargetNavId[survivor], MATRIX_OBSERVER_MAX_PATH,
            TEAM_INFECTED, false);
    }

    float averagePercent = survivorCount > 0
        ? areaPercentTotal / float(survivorCount) : -1.0;
    MatrixLog("Ready map=%s requested=%d routeStart=%d anchorArea=%d survivors=%d uniqueNav=%d spreadMin=%.1f spreadMax=%.1f minAreaPct=%.2f maxAreaPct=%.2f avgAreaPct=%.2f forwardYaw=%.1f directed(near/long/broad)=%d/%d/%d maxFlow=%.1f",
        g_CurrentMap, requestedPercent, L4D_GetNavAreaID(routeStart), anchorId, survivorCount,
        TEST_SURVIVORS, formationMinDistance, formationMaxDistance,
        minAreaPercent, maxAreaPercent, averagePercent, forwardYaw,
        nearCount, longCount, broadCount, maxFlow);
    ReplyToCommand(client,
        "[NavMatrix] ready map=%s requested=%d survivors=%d uniqueNav=%d spreadMin=%.1f spreadMax=%.1f minAreaPct=%.2f maxAreaPct=%.2f avgAreaPct=%.2f directedNear=%d directedLong=%d directedBroad=%d",
        g_CurrentMap, requestedPercent, survivorCount, TEST_SURVIVORS,
        formationMinDistance, formationMaxDistance, minAreaPercent,
        maxAreaPercent, averagePercent, nearCount, longCount, broadCount);
    return Plugin_Handled;
}

public Action Command_Clear(int client, int args)
{
    g_FrameMeasureActive = false;
    g_FrameLastAt = 0.0;
    g_SpawnVisibilityChecks = 0;
    g_SpawnVisibilityViolations = 0;
    g_ProbeSamples = 0;
    for (int zombieClass = 0; zombieClass < sizeof(g_ProbeClassCounts); zombieClass++)
        g_ProbeClassCounts[zombieClass] = 0;
    int removed;
    int humans;
    for (int target = 1; target <= MaxClients; target++)
    {
        g_VisibilityChecked[target] = false;
        g_ProbeRecorded[target] = false;
        g_ProbePending[target] = false;
        if (!IsClientInGame(target) || GetClientTeam(target) != TEAM_INFECTED)
            continue;
        if (!IsFakeClient(target))
        {
            humans++;
            continue;
        }
        KickClient(target, "Nav wave matrix reset");
        removed++;
    }
    MatrixLog("Clear map=%s removed=%d humanInfected=%d",
        g_CurrentMap, removed, humans);
    ReplyToCommand(client, "[NavMatrix] clear removed=%d humanInfected=%d",
        removed, humans);
    return Plugin_Handled;
}

public Action Command_Status(int client, int args)
{
    SynchronizeSurvivorPositions();
    int survivors = CountTeam(TEAM_SURVIVOR);
    int infectedTeam = CountTeam(TEAM_INFECTED);
    int aliveSpecialBots = CountAliveSpecialBots();
    int probePending;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (g_ProbePending[target])
            probePending++;
    }
    int humanClients = CountHumanClients();
    int humanInfected = CountHumanClients(TEAM_INFECTED);
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    float percentTotal;
    int validPositionClients;
    int controlledSurvivors;
    float minPercent = 101.0;
    float maxPercent = -1.0;
    if (maxFlow > 0.0)
    {
        for (int target = 1; target <= MaxClients; target++)
        {
            if (!g_HasTargetPosition[target] || !IsClientInGame(target)
                || GetClientTeam(target) != TEAM_SURVIVOR || !IsPlayerAlive(target))
                continue;
            controlledSurvivors++;
            float position[3];
            Address area;
            if (!GetLiveNavArea(target, area, position))
                continue;
            float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
            if (flow < 0.0)
                continue;
            float percent = flow * 100.0 / maxFlow;
            percentTotal += percent;
            if (percent < minPercent) minPercent = percent;
            if (percent > maxPercent) maxPercent = percent;
            validPositionClients++;
        }
    }
    float averagePercent = validPositionClients > 0
        ? percentTotal / float(validPositionClients) : -1.0;
    float frameAverageMs = g_FrameSamples > 0
        ? g_FrameDeltaTotalMs / float(g_FrameSamples) : 0.0;
    AnneSpawnNavGraphStatus graphStatus = AnneSpawnNavGraph_Idle;
    int graphComplete;
    int graphAreas;
    int graphEdges;
    if (HasGraphNatives())
    {
        graphStatus = AnneSpawn_NavGraphPump(false);
        char reason[384];
        int diagnostics = AnneSpawn_NavGraphGetDiagnostics(reason, sizeof(reason));
        graphComplete = diagnostics >= 0
            && (diagnostics & ANNE_SPAWN_NAV_DIAG_COMPLETE) != 0;
        graphAreas = AnneSpawn_NavGraphGetAreaCount();
        graphEdges = AnneSpawn_NavGraphGetEdgeCount();
    }
    ReplyToCommand(client,
        "[NavMatrix] status map=%s survivors=%d controlled=%d uniqueNav=%d spreadMin=%.1f spreadMax=%.1f visibilityChecks=%d visibilityViolations=%d probeSamples=%d probePending=%d probeC1=%d probeC2=%d probeC3=%d probeC4=%d probeC5=%d probeC6=%d infectedTeam=%d aliveSI=%d humanClients=%d humanInfected=%d validPosition=%d minPositionPct=%.2f maxPositionPct=%.2f avgPositionPct=%.2f graphStatus=%d graphComplete=%d graphAreas=%d graphEdges=%d frameSamples=%d frameAvgMs=%.3f frameMaxMs=%.3f frameOverTick=%d frameOver2Tick=%d frameOver4Tick=%d",
        g_CurrentMap, survivors, controlledSurvivors, CountUniqueControlledNavs(),
        g_FormationMinDistance, g_FormationMaxDistance,
        g_SpawnVisibilityChecks, g_SpawnVisibilityViolations,
        g_ProbeSamples, probePending,
        g_ProbeClassCounts[1], g_ProbeClassCounts[2], g_ProbeClassCounts[3],
        g_ProbeClassCounts[4], g_ProbeClassCounts[5], g_ProbeClassCounts[6],
        infectedTeam,
        aliveSpecialBots, humanClients, humanInfected, validPositionClients,
        minPercent, maxPercent, averagePercent, view_as<int>(graphStatus),
        graphComplete, graphAreas, graphEdges,
        g_FrameSamples, frameAverageMs, g_FrameDeltaMaxMs,
        g_FrameOverTick, g_FrameOver2Tick, g_FrameOver4Tick);
    return Plugin_Handled;
}

public Action Command_Activate(int client, int args)
{
    if (!EnsureFourSurvivors())
    {
        ReplyToCommand(client, "[NavMatrix] activate failed: survivors unavailable");
        return Plugin_Handled;
    }

    Event roundStart = CreateEvent("round_start", true);
    if (roundStart == null)
    {
        ReplyToCommand(client, "[NavMatrix] activate failed: round_start unavailable");
        return Plugin_Handled;
    }

    roundStart.Fire();
    EnsureObserverGraphStarted();
    MatrixLog("Activate map=%s survivors=%d syntheticRoundStart=1",
        g_CurrentMap, CountTeam(TEAM_SURVIVOR));
    ReplyToCommand(client, "[NavMatrix] active map=%s survivors=%d",
        g_CurrentMap, CountTeam(TEAM_SURVIVOR));
    return Plugin_Handled;
}

public Action Command_Mark(int client, int args)
{
    char text[256];
    GetCmdArgString(text, sizeof(text));
    if (StrContains(text, "begin", false) == 0)
    {
        g_FrameDeltaTotalMs = 0.0;
        g_FrameDeltaMaxMs = 0.0;
        g_FrameSamples = 0;
        g_FrameOverTick = 0;
        g_FrameOver2Tick = 0;
        g_FrameOver4Tick = 0;
        g_FrameLastAt = GetEngineTime();
        g_FrameMeasureActive = true;
    }
    else if (StrContains(text, "result", false) == 0)
    {
        float frameAverageMs = g_FrameSamples > 0
            ? g_FrameDeltaTotalMs / float(g_FrameSamples) : 0.0;
        MatrixLog("FrameTiming map=%s samples=%d avgMs=%.3f maxMs=%.3f overTick=%d over2Tick=%d over4Tick=%d",
            g_CurrentMap, g_FrameSamples, frameAverageMs, g_FrameDeltaMaxMs,
            g_FrameOverTick, g_FrameOver2Tick, g_FrameOver4Tick);
        g_FrameMeasureActive = false;
        g_FrameLastAt = 0.0;
    }
    MatrixLog("End map=%s %s", g_CurrentMap, text);
    ReplyToCommand(client, "[NavMatrix] marked");
    return Plugin_Handled;
}
