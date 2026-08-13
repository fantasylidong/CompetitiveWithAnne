#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <anne_nextbot>

#define PLUGIN_VERSION "1.2.0"
#define OBSERVED_TEAM 3
#define CLASS_BOOMER 2
#define CLASS_SPITTER 4
#define CLASS_CHARGER 6
#define CLASS_TANK 8

enum ObserveMask
{
    Observe_Tank = 1,
    Observe_Charger = 2,
    Observe_Boomer = 4,
    Observe_Spitter = 8
};

enum struct MovementSample
{
    bool valid;
    int tick;
    float time;
    float origin[3];
    float velocity[3];
    float absVelocity[3];
    float baseVelocity[3];
    float maxSpeed;
    float laggedMovement;
    int flags;
    int moveType;
    int groundEntity;
    int waterLevel;
}

enum struct PathSample
{
    bool available;
    bool segmentAvailable;
    int segmentCount;
    int currentIndex;
    bool complete;
    float age;
    float goal[3];
    int segmentType;
    float pathForward[3];
    float length;
    float distanceFromStart;
    float distanceToGoal;
}

enum struct ClientDiagState
{
    bool hooked;
    int teleportHookId;
    int userId;
    int teleportTick;
    int teleportCallsThisTick;
    int originCallsThisTick;
    int velocityCallsThisTick;
    int totalTeleportCalls;
    int totalOriginCalls;
    int totalVelocityCalls;
    int totalSampledJumps;
    int totalVelocityRewrites;
    int totalMultiWrites;
    int totalPostSamples;
    int totalMovingSamples;
    int suppressed;
    float maxDistance;
    float maxSpeed;
    float maxResidual;
    float lastEventLogTime;
    MovementSample lastPost;

    bool callOriginPresent;
    bool callAnglesPresent;
    bool callVelocityPresent;
    float callOrigin[3];
    float callAngles[3];
    float callVelocity[3];
    MovementSample callPre;

    void ResetRuntime()
    {
        this.userId = 0;
        this.teleportTick = -1;
        this.teleportCallsThisTick = 0;
        this.originCallsThisTick = 0;
        this.velocityCallsThisTick = 0;
        this.totalTeleportCalls = 0;
        this.totalOriginCalls = 0;
        this.totalVelocityCalls = 0;
        this.totalSampledJumps = 0;
        this.totalVelocityRewrites = 0;
        this.totalMultiWrites = 0;
        this.totalPostSamples = 0;
        this.totalMovingSamples = 0;
        this.suppressed = 0;
        this.maxDistance = 0.0;
        this.maxSpeed = 0.0;
        this.maxResidual = 0.0;
        this.lastEventLogTime = 0.0;
        this.lastPost.valid = false;
        this.callOriginPresent = false;
        this.callAnglesPresent = false;
        this.callVelocityPresent = false;
        this.callPre.valid = false;
    }
}

public Plugin myinfo =
{
    name = "Anne Movement Diagnostics",
    author = "AnneHappy",
    description = "Read-only Teleport and movement anomaly diagnostics",
    version = PLUGIN_VERSION,
    url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

ConVar g_Enable;
ConVar g_ClassMask;
ConVar g_TargetUserId;
ConVar g_SummaryInterval;
ConVar g_PositionThreshold;
ConVar g_ResidualThreshold;
ConVar g_VelocityDeltaThreshold;
ConVar g_DirectionThreshold;

DynamicHook g_TeleportHook;
ClientDiagState g_ClientState[MAXPLAYERS + 1];
Handle g_SummaryTimer;
char g_LogPath[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    MarkNativeAsOptional("AnneNextBot_IsActive");
    MarkNativeAsOptional("AnneNextBot_GetPathSnapshotInfo");
    MarkNativeAsOptional("AnneNextBot_GetPathSegment");
    return APLRes_Success;
}

public void OnPluginStart()
{
    BuildPath(Path_SM, g_LogPath, sizeof(g_LogPath), "logs/anne_movement_diag.log");
    g_Enable = CreateConVar("anne_move_diag_enable", "1", "Enable read-only movement diagnostics", FCVAR_DONTRECORD, true, 0.0, true, 1.0);
    g_ClassMask = CreateConVar("anne_move_diag_classmask", "15", "1=Tank, 2=Charger, 4=Boomer, 8=Spitter", FCVAR_DONTRECORD, true, 0.0, true, 15.0);
    g_TargetUserId = CreateConVar("anne_move_diag_userid", "0", "Only observe this userid; 0 observes all matching bots", FCVAR_DONTRECORD, true, 0.0);
    g_SummaryInterval = CreateConVar("anne_move_diag_summary_interval", "10.0", "Seconds between aggregate summaries", FCVAR_DONTRECORD, true, 5.0, true, 60.0);
    g_PositionThreshold = CreateConVar("anne_move_diag_position_threshold", "128.0", "Minimum sampled displacement to classify as a jump", FCVAR_DONTRECORD, true, 32.0);
    g_ResidualThreshold = CreateConVar("anne_move_diag_residual_threshold", "96.0", "Minimum prediction residual to classify as a jump", FCVAR_DONTRECORD, true, 32.0);
    g_VelocityDeltaThreshold = CreateConVar("anne_move_diag_velocity_delta", "250.0", "Minimum phase velocity delta to classify as a rewrite", FCVAR_DONTRECORD, true, 50.0);
    g_DirectionThreshold = CreateConVar("anne_move_diag_direction_delta", "60.0", "Minimum high-speed direction change to classify as a rewrite", FCVAR_DONTRECORD, true, 10.0, true, 180.0);

    RegAdminCmd("sm_anne_move_diag_status", Command_Status, ADMFLAG_ROOT, "Print movement diagnostic status");
    RegAdminCmd("sm_anne_move_diag_reset", Command_Reset, ADMFLAG_ROOT, "Reset movement diagnostic counters");

    PrepareTeleportHook();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
            HookClient(client);
    }

    StartSummaryTimer();
    LogDiag("START version=%s path_snapshot=pre-update limitation=direct-property-writes-are-sampled-not-attributed", PLUGIN_VERSION);
}

public void OnPluginEnd()
{
    delete g_SummaryTimer;
    for (int client = 1; client <= MaxClients; client++)
        UnhookClient(client);
    LogDiag("STOP version=%s", PLUGIN_VERSION);
}

public void OnMapStart()
{
    StartSummaryTimer();
}

public void OnClientPutInServer(int client)
{
    HookClient(client);
}

public void OnClientDisconnect(int client)
{
    UnhookClient(client);
    g_ClientState[client].ResetRuntime();
}

void PrepareTeleportHook()
{
    GameData gameData = new GameData("sdktools.games/game.left4dead2");
    if (gameData == null)
        SetFailState("Unable to load sdktools L4D2 gamedata");

    int offset = gameData.GetOffset("Teleport");
    delete gameData;
    if (offset < 0)
        SetFailState("Unable to find CBaseEntity::Teleport offset");

    g_TeleportHook = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
    g_TeleportHook.AddParam(HookParamType_VectorPtr);
    g_TeleportHook.AddParam(HookParamType_VectorPtr);
    g_TeleportHook.AddParam(HookParamType_VectorPtr);
}

void HookClient(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || g_ClientState[client].hooked)
        return;

    int hookId = g_TeleportHook.HookEntity(Hook_Pre, client, TeleportPre, TeleportHookRemoved);
    if (hookId == INVALID_HOOK_ID)
    {
        LogDiag("HOOK_FAIL client=%d userid=%d", client, GetClientUserId(client));
        return;
    }

    g_ClientState[client].hooked = true;
    g_ClientState[client].teleportHookId = hookId;
    g_ClientState[client].ResetRuntime();
    SDKHook(client, SDKHook_PreThink, OnPreThink);
    SDKHook(client, SDKHook_PreThinkPost, OnPreThinkPost);
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}

void UnhookClient(int client)
{
    if (client < 1 || client > MaxClients || !g_ClientState[client].hooked)
        return;

    SDKUnhook(client, SDKHook_PreThink, OnPreThink);
    SDKUnhook(client, SDKHook_PreThinkPost, OnPreThinkPost);
    SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    if (g_ClientState[client].teleportHookId != INVALID_HOOK_ID)
        DynamicHook.RemoveHook(g_ClientState[client].teleportHookId);
    g_ClientState[client].hooked = false;
    g_ClientState[client].teleportHookId = INVALID_HOOK_ID;
}

public void TeleportHookRemoved(int hookId)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_ClientState[client].teleportHookId != hookId)
            continue;
        g_ClientState[client].hooked = false;
        g_ClientState[client].teleportHookId = INVALID_HOOK_ID;
        break;
    }
}

bool IsObservedClient(int client)
{
    if (!g_Enable.BoolValue || client < 1 || client > MaxClients || !IsClientInGame(client) ||
        !IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != OBSERVED_TEAM)
        return false;

    int targetUserId = g_TargetUserId.IntValue;
    if (targetUserId > 0 && GetClientUserId(client) != targetUserId)
        return false;

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    int mask;
    switch (zombieClass)
    {
        case CLASS_TANK: mask = Observe_Tank;
        case CLASS_CHARGER: mask = Observe_Charger;
        case CLASS_BOOMER: mask = Observe_Boomer;
        case CLASS_SPITTER: mask = Observe_Spitter;
        default: return false;
    }
    return (g_ClassMask.IntValue & mask) != 0;
}

void CaptureSample(int client, MovementSample sample)
{
    sample.valid = true;
    sample.tick = GetGameTickCount();
    sample.time = GetGameTime();
    GetClientAbsOrigin(client, sample.origin);
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", sample.velocity);
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", sample.absVelocity);

    sample.baseVelocity = NULL_VECTOR;
    if (HasEntProp(client, Prop_Data, "m_vecBaseVelocity"))
        GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", sample.baseVelocity);

    sample.maxSpeed = HasEntProp(client, Prop_Data, "m_flMaxspeed") ? GetEntPropFloat(client, Prop_Data, "m_flMaxspeed") : 0.0;
    sample.laggedMovement = HasEntProp(client, Prop_Send, "m_flLaggedMovementValue") ? GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue") : 0.0;
    sample.flags = GetEntityFlags(client);
    sample.moveType = view_as<int>(GetEntityMoveType(client));
    sample.groundEntity = HasEntProp(client, Prop_Send, "m_hGroundEntity") ? GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") : -2;
    sample.waterLevel = HasEntProp(client, Prop_Data, "m_nWaterLevel") ? GetEntProp(client, Prop_Data, "m_nWaterLevel") : -1;
}

void CapturePathSample(int client, const float origin[3], PathSample sample)
{
    sample.available = false;
    sample.segmentAvailable = false;
    sample.segmentCount = 0;
    sample.currentIndex = -1;
    sample.complete = false;
    sample.age = -1.0;
    sample.goal = NULL_VECTOR;
    sample.segmentType = -1;
    sample.pathForward = NULL_VECTOR;
    sample.length = 0.0;
    sample.distanceFromStart = 0.0;
    sample.distanceToGoal = -1.0;

    if (!LibraryExists(ANNE_NEXTBOT_LIBRARY) ||
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_IsActive") != FeatureStatus_Available ||
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSnapshotInfo") != FeatureStatus_Available ||
        GetFeatureStatus(FeatureType_Native, "AnneNextBot_GetPathSegment") != FeatureStatus_Available ||
        !AnneNextBot_IsActive())
        return;

    if (!AnneNextBot_GetPathSnapshotInfo(client, sample.segmentCount, sample.currentIndex, sample.complete, sample.age))
        return;

    sample.available = true;
    if (sample.currentIndex < 0 || sample.currentIndex >= sample.segmentCount)
        return;

    Address navArea;
    int traverseType;
    if (!AnneNextBot_GetPathSegment(
        client,
        sample.currentIndex,
        navArea,
        traverseType,
        sample.goal,
        sample.segmentType,
        sample.pathForward,
        sample.length,
        sample.distanceFromStart
    ))
        return;

    sample.segmentAvailable = true;
    float delta[3];
    SubtractVectors(sample.goal, origin, delta);
    delta[2] = 0.0;
    sample.distanceToGoal = GetVectorLength(delta);
}

public MRESReturn TeleportPre(int client, DHookParam params)
{
    if (!IsObservedClient(client))
        return MRES_Ignored;

    ClientDiagState state;
    state = g_ClientState[client];
    int tick = GetGameTickCount();
    if (state.teleportTick != tick)
    {
        state.teleportTick = tick;
        state.teleportCallsThisTick = 0;
        state.originCallsThisTick = 0;
        state.velocityCallsThisTick = 0;
    }

    state.userId = GetClientUserId(client);
    state.teleportCallsThisTick++;
    state.totalTeleportCalls++;
    state.callOriginPresent = !params.IsNull(1);
    state.callAnglesPresent = !params.IsNull(2);
    state.callVelocityPresent = !params.IsNull(3);
    if (state.callOriginPresent)
    {
        params.GetVector(1, state.callOrigin);
        state.originCallsThisTick++;
        state.totalOriginCalls++;
    }
    if (state.callAnglesPresent)
        params.GetVector(2, state.callAngles);
    if (state.callVelocityPresent)
    {
        params.GetVector(3, state.callVelocity);
        state.velocityCallsThisTick++;
        state.totalVelocityCalls++;
    }
    CaptureSample(client, state.callPre);

    float requestedSpeed = state.callVelocityPresent ? GetVectorLength(state.callVelocity) : 0.0;
    if (requestedSpeed > state.maxSpeed)
        state.maxSpeed = requestedSpeed;

    bool multiWrite = state.teleportCallsThisTick >= 2;
    if (multiWrite)
        state.totalMultiWrites++;

    g_ClientState[client] = state;

    if (state.callOriginPresent || multiWrite || IsVelocityRewrite(state.callPre.absVelocity, state.callVelocity, state.callVelocityPresent))
    {
        LogTeleportEvent(client, multiWrite ? "MULTI_WRITE" : (state.callOriginPresent ? "ORIGIN_CALL" : "VELOCITY_REWRITE"));
    }
    return MRES_Ignored;
}

bool IsVelocityRewrite(const float before[3], const float requested[3], bool present)
{
    if (!present)
        return false;

    float delta[3];
    SubtractVectors(requested, before, delta);
    if (GetVectorLength(delta) >= g_VelocityDeltaThreshold.FloatValue)
        return true;

    float before2D[3], requested2D[3];
    before2D = before;
    requested2D = requested;
    before2D[2] = 0.0;
    requested2D[2] = 0.0;
    float beforeSpeed = NormalizeVector(before2D, before2D);
    float requestedSpeed = NormalizeVector(requested2D, requested2D);
    if (beforeSpeed < 200.0 || requestedSpeed < 200.0)
        return false;

    float dot = GetVectorDotProduct(before2D, requested2D);
    if (dot > 1.0)
        dot = 1.0;
    else if (dot < -1.0)
        dot = -1.0;
    return RadToDeg(ArcCosine(dot)) >= g_DirectionThreshold.FloatValue;
}

public void OnPreThink(int client)
{
    SamplePhase(client, "PRE");
}

public void OnPreThinkPost(int client)
{
    SamplePhase(client, "PRE_POST");
}

public void OnPostThinkPost(int client)
{
    if (!IsObservedClient(client))
        return;

    MovementSample current;
    CaptureSample(client, current);
    g_ClientState[client].totalPostSamples++;
    if (GetVectorLength(current.absVelocity) > 1.0)
        g_ClientState[client].totalMovingSamples++;
    AnalyzePostSample(client, current);
    g_ClientState[client].lastPost = current;
}

void SamplePhase(int client, const char[] phase)
{
    if (!IsObservedClient(client))
        return;

    MovementSample current;
    CaptureSample(client, current);
    MovementSample previous;
    previous = g_ClientState[client].lastPost;
    if (!previous.valid || previous.tick == current.tick)
        return;

    float velocityDelta[3];
    SubtractVectors(current.absVelocity, previous.absVelocity, velocityDelta);
    if (GetVectorLength(velocityDelta) < g_VelocityDeltaThreshold.FloatValue)
        return;

    g_ClientState[client].totalVelocityRewrites++;
    LogSampleEvent(client, "UNATTRIBUTED_VELOCITY_CHANGE", phase, previous, current, 0.0, 0.0);
}

void AnalyzePostSample(int client, MovementSample current)
{
    MovementSample previous;
    previous = g_ClientState[client].lastPost;
    if (!previous.valid || current.time <= previous.time || current.tick <= previous.tick)
        return;

    float dt = current.time - previous.time;
    if (dt > 0.25)
        return;

    float delta[3], predicted[3], residualVector[3];
    SubtractVectors(current.origin, previous.origin, delta);
    predicted = previous.absVelocity;
    ScaleVector(predicted, dt);
    SubtractVectors(delta, predicted, residualVector);

    float distance = GetVectorLength(delta);
    float residual = GetVectorLength(residualVector);
    float speed = GetVectorLength(current.absVelocity);
    if (distance > g_ClientState[client].maxDistance)
        g_ClientState[client].maxDistance = distance;
    if (speed > g_ClientState[client].maxSpeed)
        g_ClientState[client].maxSpeed = speed;
    if (residual > g_ClientState[client].maxResidual)
        g_ClientState[client].maxResidual = residual;

    float previousSpeed = GetVectorLength(previous.absVelocity);
    float maximumSpeed = previousSpeed > speed ? previousSpeed : speed;
    float expectedAllowance = maximumSpeed * dt * 3.0 + 32.0;
    if (expectedAllowance < 128.0)
        expectedAllowance = 128.0;
    if (distance < g_PositionThreshold.FloatValue || distance <= expectedAllowance || residual < g_ResidualThreshold.FloatValue)
        return;

    g_ClientState[client].totalSampledJumps++;
    LogSampleEvent(client, "SAMPLED_ORIGIN_JUMP", "POST", previous, current, distance, residual);
}

void LogTeleportEvent(int client, const char[] category)
{
    ClientDiagState state;
    state = g_ClientState[client];
    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    PathSample path;
    CapturePathSample(client, state.callPre.origin, path);
    float beforeSpeed = GetVectorLength(state.callPre.absVelocity);
    float requestedSpeed = state.callVelocityPresent ? GetVectorLength(state.callVelocity) : -1.0;
    LogDiag("%s tick=%d client=%d userid=%d class=%d call=%d origin=%d angles=%d velocity=%d req_origin=(%.2f,%.2f,%.2f) req_velocity=(%.2f,%.2f,%.2f) pre_origin=(%.2f,%.2f,%.2f) pre_absvel=(%.2f,%.2f,%.2f) pre_speed=%.2f req_speed=%.2f maxspeed=%.2f lagged=%.3f flags=%d movetype=%d ground=%d water=%d path=%d path_segment=%d path_count=%d path_index=%d path_complete=%d path_age=%.4f path_goal=(%.2f,%.2f,%.2f) path_forward=(%.3f,%.3f,%.3f) path_type=%d path_length=%.2f path_distance_start=%.2f path_goal_distance=%.2f",
        category,
        state.callPre.tick,
        client,
        state.userId,
        zombieClass,
        state.teleportCallsThisTick,
        state.callOriginPresent,
        state.callAnglesPresent,
        state.callVelocityPresent,
        state.callOrigin[0], state.callOrigin[1], state.callOrigin[2],
        state.callVelocity[0], state.callVelocity[1], state.callVelocity[2],
        state.callPre.origin[0], state.callPre.origin[1], state.callPre.origin[2],
        state.callPre.absVelocity[0], state.callPre.absVelocity[1], state.callPre.absVelocity[2],
        beforeSpeed,
        requestedSpeed,
        state.callPre.maxSpeed,
        state.callPre.laggedMovement,
        state.callPre.flags,
        state.callPre.moveType,
        state.callPre.groundEntity,
        state.callPre.waterLevel,
        path.available,
        path.segmentAvailable,
        path.segmentCount,
        path.currentIndex,
        path.complete,
        path.age,
        path.goal[0], path.goal[1], path.goal[2],
        path.pathForward[0], path.pathForward[1], path.pathForward[2],
        path.segmentType,
        path.length,
        path.distanceFromStart,
        path.distanceToGoal
    );
}

void LogSampleEvent(int client, const char[] category, const char[] phase, MovementSample previous, MovementSample current, float distance, float residual)
{
    float now = GetGameTime();
    if (now - g_ClientState[client].lastEventLogTime < 0.25)
    {
        g_ClientState[client].suppressed++;
        return;
    }
    g_ClientState[client].lastEventLogTime = now;

    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    PathSample path;
    CapturePathSample(client, current.origin, path);
    LogDiag("%s phase=%s tick=%d prev_tick=%d dt=%.4f client=%d userid=%d class=%d distance=%.2f residual=%.2f origin=(%.2f,%.2f,%.2f) prev_origin=(%.2f,%.2f,%.2f) absvel=(%.2f,%.2f,%.2f) prev_absvel=(%.2f,%.2f,%.2f) velocity=(%.2f,%.2f,%.2f) basevel=(%.2f,%.2f,%.2f) maxspeed=%.2f lagged=%.3f flags=%d movetype=%d ground=%d water=%d tele_calls=%d origin_calls=%d velocity_calls=%d path=%d path_segment=%d path_count=%d path_index=%d path_complete=%d path_age=%.4f path_goal=(%.2f,%.2f,%.2f) path_forward=(%.3f,%.3f,%.3f) path_type=%d path_length=%.2f path_distance_start=%.2f path_goal_distance=%.2f",
        category,
        phase,
        current.tick,
        previous.tick,
        current.time - previous.time,
        client,
        GetClientUserId(client),
        zombieClass,
        distance,
        residual,
        current.origin[0], current.origin[1], current.origin[2],
        previous.origin[0], previous.origin[1], previous.origin[2],
        current.absVelocity[0], current.absVelocity[1], current.absVelocity[2],
        previous.absVelocity[0], previous.absVelocity[1], previous.absVelocity[2],
        current.velocity[0], current.velocity[1], current.velocity[2],
        current.baseVelocity[0], current.baseVelocity[1], current.baseVelocity[2],
        current.maxSpeed,
        current.laggedMovement,
        current.flags,
        current.moveType,
        current.groundEntity,
        current.waterLevel,
        g_ClientState[client].teleportTick == current.tick ? g_ClientState[client].teleportCallsThisTick : 0,
        g_ClientState[client].teleportTick == current.tick ? g_ClientState[client].originCallsThisTick : 0,
        g_ClientState[client].teleportTick == current.tick ? g_ClientState[client].velocityCallsThisTick : 0,
        path.available,
        path.segmentAvailable,
        path.segmentCount,
        path.currentIndex,
        path.complete,
        path.age,
        path.goal[0], path.goal[1], path.goal[2],
        path.pathForward[0], path.pathForward[1], path.pathForward[2],
        path.segmentType,
        path.length,
        path.distanceFromStart,
        path.distanceToGoal
    );
}

void StartSummaryTimer()
{
    delete g_SummaryTimer;
    g_SummaryTimer = CreateTimer(g_SummaryInterval.FloatValue, Timer_Summary, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Summary(Handle timer)
{
    if (timer != g_SummaryTimer)
        return Plugin_Stop;
    WriteSummary(false);
    return Plugin_Continue;
}

void WriteSummary(bool force)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ClientDiagState state;
        state = g_ClientState[client];
        if (!state.hooked || (!force && state.totalPostSamples == 0 && state.totalTeleportCalls == 0 && state.totalSampledJumps == 0 && state.totalVelocityRewrites == 0))
            continue;

        int userId = IsClientInGame(client) ? GetClientUserId(client) : state.userId;
        int zombieClass = IsClientInGame(client) && HasEntProp(client, Prop_Send, "m_zombieClass") ? GetEntProp(client, Prop_Send, "m_zombieClass") : -1;
        LogDiag("SUMMARY client=%d userid=%d class=%d post_samples=%d moving_samples=%d teleport=%d origin=%d velocity=%d sampled_jumps=%d unattributed_velocity=%d multi=%d suppressed=%d max_distance=%.2f max_speed=%.2f max_residual=%.2f",
            client,
            userId,
            zombieClass,
            state.totalPostSamples,
            state.totalMovingSamples,
            state.totalTeleportCalls,
            state.totalOriginCalls,
            state.totalVelocityCalls,
            state.totalSampledJumps,
            state.totalVelocityRewrites,
            state.totalMultiWrites,
            state.suppressed,
            state.maxDistance,
            state.maxSpeed,
            state.maxResidual
        );

        g_ClientState[client].totalTeleportCalls = 0;
        g_ClientState[client].totalOriginCalls = 0;
        g_ClientState[client].totalVelocityCalls = 0;
        g_ClientState[client].totalSampledJumps = 0;
        g_ClientState[client].totalVelocityRewrites = 0;
        g_ClientState[client].totalMultiWrites = 0;
        g_ClientState[client].totalPostSamples = 0;
        g_ClientState[client].totalMovingSamples = 0;
        g_ClientState[client].suppressed = 0;
        g_ClientState[client].maxDistance = 0.0;
        g_ClientState[client].maxSpeed = 0.0;
        g_ClientState[client].maxResidual = 0.0;
    }
}

public Action Command_Status(int client, int args)
{
    int observed;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (IsObservedClient(target))
            observed++;
    }
    ReplyToCommand(client, "[AnneMoveDiag] version=%s enabled=%d classmask=%d userid=%d observed=%d", PLUGIN_VERSION, g_Enable.BoolValue, g_ClassMask.IntValue, g_TargetUserId.IntValue, observed);
    WriteSummary(true);
    return Plugin_Handled;
}

public Action Command_Reset(int client, int args)
{
    for (int target = 1; target <= MaxClients; target++)
        g_ClientState[target].ResetRuntime();
    ReplyToCommand(client, "[AnneMoveDiag] counters reset");
    return Plugin_Handled;
}

void LogDiag(const char[] format, any ...)
{
    char message[2048];
    VFormat(message, sizeof(message), format, 2);
    LogToFileEx(g_LogPath, "%s", message);
}
