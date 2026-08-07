#if defined _infected_control_spawn_accel_bridge_included
    #endinput
#endif
#define _infected_control_spawn_accel_bridge_included

#define SPAWN_ACCEL_MAX_SPATIAL_POINTS 100000
#define SPAWN_ACCEL_PROGRESS_PAGE_SIZE 16384
#define SPAWN_ACCEL_PATH_BOUNDARY_SLACK 32.0
#define SPAWN_ACCEL_TOPOLOGY_RETRY_DELAY 30.0
#define SPAWN_ACCEL_RETRYABLE_TOPOLOGY_DIAGS (ANNE_SPAWN_NAV_DIAG_UNKNOWN_AREA \
    | ANNE_SPAWN_NAV_DIAG_INVALID_FLOOR_STORAGE \
    | ANNE_SPAWN_NAV_DIAG_INVALID_LADDER_STORAGE \
    | ANNE_SPAWN_NAV_DIAG_UNRESOLVED_DYNAMIC_ELEVATOR)

bool g_bSpawnAccel;
bool g_bSpawnAccelGraphReady;
bool g_bSpawnAccelGraphCandidatesAvailable;
bool g_bSpawnAccelAvailabilityKnown;
bool g_bSpawnAccelNativeSafetyAvailable;
Handle g_hSpawnAccelStartTimer = INVALID_HANDLE;
Handle g_hSpawnAccelGraphTimer = INVALID_HANDLE;
Handle g_hSpawnAccelTopologyRetryTimer = INVALID_HANDLE;
bool g_bSpawnAccelTopologyRetryAttempted;
bool g_bSpawnAccelTopologyRetryInProgress;
bool g_bSpawnAccelDynamicRebuildPending;
ArrayList g_SpawnAccelRawFlowDistances = null;
float g_fSpawnAccelNextCandidateRefresh;
bool g_bSpawnAccelCandidateWarm;
int g_iSpawnAccelCandidateIdleRefreshes;
int g_iSpawnAccelCandidateWarmRefreshes;
int g_iSpawnAccelCandidatePrepareReady;
int g_iSpawnAccelCandidatePreparePending;
int g_iSpawnAccelCandidatePrepareUnavailable;

static const char g_sSpawnAccelRequiredNatives[][] =
{
    "AnneSpawn_IsActive",
    "AnneSpawn_NavGraphStart",
    "AnneSpawn_NavGraphPump",
    "AnneSpawn_NavGraphStop",
    "AnneSpawn_NavGraphPrepareRange",
    "AnneSpawn_NavCandidatesPrepare",
    "AnneSpawn_NavCandidatesCollect",
    "AnneSpawn_NavCandidatesGetPerf",
    "AnneSpawn_NavCandidatesResetPerf",
    "AnneSpawn_NavGraphGetAreaCount",
    "AnneSpawn_NavGraphGetEdgeCount",
    "AnneSpawn_NavGraphCollectProgressPage",
    "AnneSpawn_GetWorkerCount",
    "AnneSpawn_SetSurvivorSnapshot",
    "AnneSpawn_ClearSurvivorSnapshot",
    "AnneSpawn_ComputePointGeometry",
    "AnneSpawn_MapNearest2D",
    "AnneSpawn_PathExists",
    "AnneSpawn_ClearPathCache"
};

stock bool SpawnAccel_HasRequiredNatives()
{
    for (int i = 0; i < sizeof(g_sSpawnAccelRequiredNatives); i++)
    {
        if (GetFeatureStatus(FeatureType_Native, g_sSpawnAccelRequiredNatives[i])
            != FeatureStatus_Available)
        {
            return false;
        }
    }
    return true;
}

stock bool SpawnAccel_IsAvailable()
{
    return LibraryExists(ANNE_SPAWN_ACCEL_LIBRARY)
        && SpawnAccel_HasRequiredNatives()
        && AnneSpawn_IsActive();
}

stock bool SpawnAccel_CanUseNativeSafety()
{
    return g_bSpawnAccelNativeSafetyAvailable
        && gCV.bSpawnAccelNativeSafety;
}

stock bool SpawnAccel_CanUseGraphCandidates()
{
    return g_bSpawnAccel && g_bSpawnAccelGraphReady
        && g_bSpawnAccelGraphCandidatesAvailable;
}

stock bool SpawnAccel_IsDynamicGraphPending()
{
    return g_bSpawnAccel && g_bSpawnAccelDynamicRebuildPending;
}

stock bool SpawnAccel_ShouldRetryTopology(int diagnosticFlags)
{
    return diagnosticFlags >= 0
        && (diagnosticFlags & SPAWN_ACCEL_RETRYABLE_TOPOLOGY_DIAGS) != 0;
}

stock void SpawnAccel_LogUnavailableReason()
{
    if (!LibraryExists(ANNE_SPAWN_ACCEL_LIBRARY))
    {
        Debug_Print("[SPAWN ACCEL] reason: library '%s' is not loaded; check 'sm exts list' and SourceMod error logs",
                    ANNE_SPAWN_ACCEL_LIBRARY);
        return;
    }

    bool missingNative = false;
    for (int i = 0; i < sizeof(g_sSpawnAccelRequiredNatives); i++)
    {
        if (GetFeatureStatus(FeatureType_Native, g_sSpawnAccelRequiredNatives[i])
            != FeatureStatus_Available)
        {
            Debug_Print("[SPAWN ACCEL] reason: required native missing: %s",
                        g_sSpawnAccelRequiredNatives[i]);
            missingNative = true;
        }
    }
    if (missingNative)
        return;

    Debug_Print("[SPAWN ACCEL] reason: AnneSpawn_IsActive returned false");
}

stock void SpawnAccel_UpdateAvailability(bool forceLog = false)
{
    bool available = SpawnAccel_IsAvailable();
    bool shouldLog = forceLog || !g_bSpawnAccelAvailabilityKnown || available != g_bSpawnAccel;
    g_bSpawnAccel = available;
    if (!available)
    {
        g_bSpawnAccelGraphCandidatesAvailable = false;
        g_bSpawnAccelDynamicRebuildPending = false;
    }
    g_bSpawnAccelNativeSafetyAvailable = available
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_TestPointSafety")
            == FeatureStatus_Available;
    g_bSpawnAccelAvailabilityKnown = true;

    if (shouldLog)
    {
        Debug_Print("[SPAWN ACCEL] extension %s",
                    available ? "active (all required natives available)"
                              : "unavailable (using SourcePawn fallbacks)");
        if (!available)
            SpawnAccel_LogUnavailableReason();
        else
            Debug_Print("[SPAWN ACCEL] native safety traces %s",
                        SpawnAccel_CanUseNativeSafety() ? "enabled" : "disabled (SourcePawn fallback)");
    }
}

stock void SpawnAccel_StopGraphTimer()
{
    StopTrackedTimer(g_hSpawnAccelGraphTimer);
}

stock void SpawnAccel_StopGraphStartTimer()
{
    StopTrackedTimer(g_hSpawnAccelStartTimer);
}

stock void SpawnAccel_StopTopologyRetryTimer()
{
    StopTrackedTimer(g_hSpawnAccelTopologyRetryTimer);
}

stock void SpawnAccel_ResetTopologyRetryState()
{
    SpawnAccel_StopTopologyRetryTimer();
    g_bSpawnAccelTopologyRetryAttempted = false;
    g_bSpawnAccelTopologyRetryInProgress = false;
}

stock void SpawnAccel_ScheduleNavGraphStart(bool forceRebuild = false)
{
    SpawnAccel_StopGraphStartTimer();
    SpawnAccel_ResetTopologyRetryState();
    if (!g_bInfectedControlStarted)
        return;

    // 给 Nav Variant 与 Stripper 一秒完成地图拓扑替换，再捕获实时连接。
    g_hSpawnAccelStartTimer = CreateTimer(
        1.0, Timer_StartSpawnAccelGraph, view_as<any>(forceRebuild),
        TIMER_FLAG_NO_MAPCHANGE);
}

stock int SpawnAccel_GetGraphDiagnostics(char[] reason, int maxlen)
{
    if (GetFeatureStatus(FeatureType_Native, "AnneSpawn_NavGraphGetDiagnostics")
        != FeatureStatus_Available)
    {
        strcopy(reason, maxlen, "legacy_extension_no_diagnostics");
        return -1;
    }
    return AnneSpawn_NavGraphGetDiagnostics(reason, maxlen);
}

stock void SpawnAccel_ClearGraphProgress()
{
    if (g_SpawnAccelRawFlowDistances == null)
        return;

    delete g_SpawnAccelRawFlowDistances;
    g_SpawnAccelRawFlowDistances = null;
    ClearNavBuckets();
    g_BucketsReady = false;
}

stock bool SpawnAccel_RebuildAreaProgress()
{
    if (g_SpawnAccelRawFlowDistances == null)
        return false;

    for (int bucket = 0; bucket < FLOW_BUCKETS; bucket++)
    {
        if (g_FlowBuckets[bucket] != null)
        {
            delete g_FlowBuckets[bucket];
            g_FlowBuckets[bucket] = null;
        }
        g_BucketMinZ[bucket] = 1.0e9;
        g_BucketMaxZ[bucket] = -1.0e9;
    }
    if (g_AreaPct != null)
        delete g_AreaPct;
    g_AreaPct = new ArrayList();
    for (int i = 0; i < g_SpawnAccelRawFlowDistances.Length; i++)
    {
        float flow = view_as<float>(g_SpawnAccelRawFlowDistances.Get(i));
        int percent = flow >= 0.0 ? FlowDistanceToPercent(flow) : -1;
        if (percent >= 0)
            percent = ClampInt(percent, 0, 100);
        g_AreaPct.Push(percent);
        if (percent < 0)
            continue;

        if (g_FlowBuckets[percent] == null)
            g_FlowBuckets[percent] = new ArrayList();
        g_FlowBuckets[percent].Push(i);
    }
    g_BucketsReady = true;
    InvalidateBucketShareCache();
    return true;
}

stock bool SpawnAccel_LoadGraphProgress()
{
    int areaCount = AnneSpawn_NavGraphGetAreaCount();
    EnsureNavAreasCache();
    if (areaCount <= 0 || areaCount != g_NavAreasCacheCount ||
        areaCount > SPAWN_ACCEL_MAX_SPATIAL_POINTS)
        return false;

    ArrayList flowDistances = new ArrayList();
    float page[SPAWN_ACCEL_PROGRESS_PAGE_SIZE];
    int offset = 0;
    while (offset < areaCount)
    {
        int pageSize = areaCount - offset;
        if (pageSize > sizeof(page))
            pageSize = sizeof(page);
        int count = AnneSpawn_NavGraphCollectProgressPage(
            page, pageSize, offset, gCV.bNavBucketMapInvalid,
            gCV.fNavBucketAssignRadius);
        if (count != pageSize)
        {
            delete flowDistances;
            return false;
        }
        for (int i = 0; i < count; i++)
            flowDistances.Push(page[i]);
        offset += count;
    }

    ClearNavBuckets();
    if (g_SpawnAccelRawFlowDistances != null)
        delete g_SpawnAccelRawFlowDistances;
    g_SpawnAccelRawFlowDistances = flowDistances;
    g_BucketsReady = false;
    return SpawnAccel_RebuildAreaProgress();
}

stock void SpawnAccel_EnsureLegacyBuckets()
{
    if (!g_BucketsReady)
        BuildNavBuckets();
}

stock void SpawnAccel_ClearGraphState(bool stopExtension)
{
    SpawnAccel_StopGraphStartTimer();
    SpawnAccel_StopGraphTimer();
    SpawnAccel_StopTopologyRetryTimer();
    if (stopExtension && g_bSpawnAccel)
        AnneSpawn_NavGraphStop();
    g_bSpawnAccelGraphReady = false;
    g_bSpawnAccelGraphCandidatesAvailable = false;
    g_bSpawnAccelDynamicRebuildPending = false;
    g_fSpawnAccelNextCandidateRefresh = 0.0;
    g_bSpawnAccelCandidateWarm = false;
    SpawnAccel_ClearGraphProgress();
}

stock bool SpawnAccel_PrepareCurrentSurvivorRange()
{
    if (!g_bSpawnAccel || !g_bSpawnAccelGraphReady)
        return false;

    int target = gST.targetSurvivor;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target)
        || L4D_IsPlayerIncapacitated(target))
    {
        target = -1;
        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsValidSurvivor(client) && IsPlayerAlive(client)
                && !L4D_IsPlayerIncapacitated(client))
            {
                target = client;
                break;
            }
        }
    }
    if (target < 1)
        return false;

    float pos[3];
    GetClientAbsOrigin(target, pos);
    Address navStart = L4D2Direct_GetTerrorNavArea(pos);
    if (navStart == Address_Null)
        navStart = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);
    if (navStart == Address_Null)
        return false;

    int targetId = L4D_GetNavAreaID(navStart);
    float maxPathDistance = gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE
        + SPAWN_ACCEL_PATH_BOUNDARY_SLACK + NAV_HIGH_GROUND_MAX_COMP;
    return AnneSpawn_NavGraphPrepareRange(targetId, maxPathDistance, TEAM_INFECTED, false);
}

stock bool SpawnAccel_GetClientNavId(int client, int &navId)
{
    navId = -1;
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
        return false;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    Address nav = L4D2Direct_GetTerrorNavArea(pos);
    if (nav == Address_Null)
        nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);
    if (nav == Address_Null)
        return false;

    navId = L4D_GetNavAreaID(nav);
    return navId > 0;
}

stock float SpawnAccel_GetCandidatePathLimit()
{
    return gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE
        + SPAWN_ACCEL_PATH_BOUNDARY_SLACK + NAV_HIGH_GROUND_MAX_COMP;
}

stock int SpawnAccel_PrepareTargetCandidates(int target, float maxAge)
{
    if (!SpawnAccel_CanUseGraphCandidates())
        return ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE;

    int targetNavId;
    if (!SpawnAccel_GetClientNavId(target, targetNavId))
        return ANNE_SPAWN_NAV_CANDIDATE_PENDING;

    int status = AnneSpawn_NavCandidatesPrepare(
        target, targetNavId, SpawnAccel_GetCandidatePathLimit(),
        FloatMax(NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin), maxAge);
    if (status > 0)
        g_iSpawnAccelCandidatePrepareReady++;
    else if (status == 0 || status == ANNE_SPAWN_NAV_CANDIDATE_PENDING)
        g_iSpawnAccelCandidatePreparePending++;
    else
        g_iSpawnAccelCandidatePrepareUnavailable++;
    return status;
}

stock void SpawnAccel_UpdateCandidateSnapshots(float now, bool warm)
{
    if (!g_bSpawnAccel)
        return;

    // 有向拓扑监测必须独立于 directed candidate 可用性持续运行。扩展内部按
    // 空闲 1.0s / 临近刷特 0.1s 节流，变化后稳定 0.2s 才重捕获。
    AnneSpawnNavGraphStatus graphStatus = AnneSpawn_NavGraphPump(warm);
    if (graphStatus != AnneSpawnNavGraph_Ready)
    {
        if (g_bSpawnAccelGraphReady && g_hSpawnAccelGraphTimer == INVALID_HANDLE)
        {
            g_bSpawnAccelGraphReady = false;
            g_bSpawnAccelGraphCandidatesAvailable = false;
            g_bSpawnAccelDynamicRebuildPending = true;
            // 分页 offset 属于旧拓扑；新图发布后必须从当前距离范围的第一个
            // 有向候选重新开始，不能把旧图游标套到新图上。
            SpawnSearch_Reset();
            char diagnostics[768];
            SpawnAccel_GetGraphDiagnostics(diagnostics, sizeof diagnostics);
            Debug_Print("[SPAWN ACCEL] directed Nav topology change detected; old graph/path cache invalidated, directed searches paused until rebuild; diagnostics=(%s)",
                        diagnostics);
        }
        return;
    }

    if (!g_bSpawnAccelGraphReady && g_hSpawnAccelGraphTimer == INVALID_HANDLE)
    {
        if (!SpawnAccel_LoadGraphProgress())
        {
            if (!g_bSpawnAccelDynamicRebuildPending)
                SpawnAccel_EnsureLegacyBuckets();
            return;
        }
        char diagnostics[768];
        int diagnosticFlags = SpawnAccel_GetGraphDiagnostics(
            diagnostics, sizeof diagnostics);
        g_bSpawnAccelGraphReady = true;
        g_bSpawnAccelGraphCandidatesAvailable = diagnosticFlags < 0
            || (diagnosticFlags & ANNE_SPAWN_NAV_DIAG_COMPLETE) != 0;
        g_bSpawnAccelDynamicRebuildPending = false;
        g_fSpawnAccelNextCandidateRefresh = 0.0;
        Debug_Print("[SPAWN ACCEL] directed Nav graph ready: candidateSource=%s diagnostics=(%s)",
                    g_bSpawnAccelGraphCandidatesAvailable
                        ? "directed" : "all_path_bracket",
                    diagnostics);
    }

    if (!SpawnAccel_CanUseGraphCandidates())
        return;

    if (warm != g_bSpawnAccelCandidateWarm)
    {
        g_bSpawnAccelCandidateWarm = warm;
        g_fSpawnAccelNextCandidateRefresh = 0.0;
    }

    float interval = warm ? NAV_CANDIDATE_WARM_INTERVAL : NAV_CANDIDATE_IDLE_INTERVAL;
    if (now < g_fSpawnAccelNextCandidateRefresh)
        return;
    g_fSpawnAccelNextCandidateRefresh = now + interval;

    Visibility_EnsureCurrentEyeSnapshot();
    float maxAge = interval * 0.75;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
            continue;
        int status = SpawnAccel_PrepareTargetCandidates(client, maxAge);
        if (status == ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE)
        {
            g_bSpawnAccelGraphCandidatesAvailable = false;
            char diagnostics[256];
            SpawnAccel_GetGraphDiagnostics(diagnostics, sizeof diagnostics);
            Debug_Print("[SPAWN ACCEL] directed candidate snapshots unavailable; using all-Nav path-bracket fallback; diagnostics=(%s)",
                        diagnostics);
            break;
        }
    }

    if (warm)
        g_iSpawnAccelCandidateWarmRefreshes++;
    else
        g_iSpawnAccelCandidateIdleRefreshes++;
}

stock void SpawnAccel_PrintCandidatePerf()
{
    if (!g_bSpawnAccel)
        return;

    float timings[ANNE_SPAWN_NAV_CANDIDATE_PERF_FLOATS];
    int counters[ANNE_SPAWN_NAV_CANDIDATE_PERF_COUNTS];
    if (!AnneSpawn_NavCandidatesGetPerf(
            timings, sizeof(timings), counters, sizeof(counters)))
        return;

    SpawnPerf_Log("[SpawnPerf][GraphCandidates] buildMs samples=%d last=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f",
        counters[AnneSpawnCandidatePerf_BuildSamples],
        timings[AnneSpawnCandidatePerf_BuildLast],
        timings[AnneSpawnCandidatePerf_BuildP50],
        timings[AnneSpawnCandidatePerf_BuildP95],
        timings[AnneSpawnCandidatePerf_BuildP99],
        timings[AnneSpawnCandidatePerf_BuildMax]);
    SpawnPerf_Log("[SpawnPerf][GraphCandidates] resultAgeMs last=%.1f p50=%.1f p95=%.1f p99=%.1f max=%.1f",
        timings[AnneSpawnCandidatePerf_AgeLast],
        timings[AnneSpawnCandidatePerf_AgeP50],
        timings[AnneSpawnCandidatePerf_AgeP95],
        timings[AnneSpawnCandidatePerf_AgeP99],
        timings[AnneSpawnCandidatePerf_AgeMax]);
    SpawnPerf_Log("[SpawnPerf][GraphCandidates] queued=%d published=%d cacheHits=%d coalesced=%d staleDrops=%d collect(hit/pending/unavailable)=%d/%d/%d masterCandidates=%d lastRangeCandidates=%d inFlight=%d cache=%d",
        counters[AnneSpawnCandidatePerf_Queued],
        counters[AnneSpawnCandidatePerf_Published],
        counters[AnneSpawnCandidatePerf_CacheHits],
        counters[AnneSpawnCandidatePerf_Coalesced],
        counters[AnneSpawnCandidatePerf_StaleDrops],
        counters[AnneSpawnCandidatePerf_CollectHits],
        counters[AnneSpawnCandidatePerf_CollectPending],
        counters[AnneSpawnCandidatePerf_CollectUnavailable],
        counters[AnneSpawnCandidatePerf_LastCandidates],
        counters[AnneSpawnCandidatePerf_LastRangeCandidates],
        counters[AnneSpawnCandidatePerf_InFlight],
        counters[AnneSpawnCandidatePerf_CacheEntries]);
    SpawnPerf_Log("[SpawnPerf][GraphCandidates] cadence idle=%d warm=%d prepare(ready/pending/unavailable)=%d/%d/%d",
        g_iSpawnAccelCandidateIdleRefreshes,
        g_iSpawnAccelCandidateWarmRefreshes,
        g_iSpawnAccelCandidatePrepareReady,
        g_iSpawnAccelCandidatePreparePending,
        g_iSpawnAccelCandidatePrepareUnavailable);
}

stock void SpawnAccel_ResetCandidatePerf()
{
    g_iSpawnAccelCandidateIdleRefreshes = 0;
    g_iSpawnAccelCandidateWarmRefreshes = 0;
    g_iSpawnAccelCandidatePrepareReady = 0;
    g_iSpawnAccelCandidatePreparePending = 0;
    g_iSpawnAccelCandidatePrepareUnavailable = 0;
    if (g_bSpawnAccel)
        AnneSpawn_NavCandidatesResetPerf();
}

public Action Timer_SpawnAccelGraphPump(Handle timer)
{
    if (timer != g_hSpawnAccelGraphTimer)
        return Plugin_Stop;

    if (!g_bSpawnAccel)
    {
        g_hSpawnAccelGraphTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    AnneSpawnNavGraphStatus status = AnneSpawn_NavGraphPump();
    if (status == AnneSpawnNavGraph_Failed)
    {
        g_bSpawnAccelGraphReady = false;
        g_bSpawnAccelGraphCandidatesAvailable = false;
        g_bSpawnAccelDynamicRebuildPending = false;
        g_hSpawnAccelGraphTimer = INVALID_HANDLE;
        char diagnostics[768];
        SpawnAccel_GetGraphDiagnostics(diagnostics, sizeof diagnostics);
        Debug_Print("[SPAWN ACCEL] Nav graph build/load failed; using SourcePawn progress cache and all-Nav path-bracket fallback; diagnostics=(%s)",
                    diagnostics);
        if (g_bSpawnAccelTopologyRetryInProgress)
        {
            Debug_Print("[SPAWN ACCEL] topology retry outcome=failed classification=persistent_or_build_failure diagnostics=(%s)",
                        diagnostics);
            g_bSpawnAccelTopologyRetryInProgress = false;
        }
        SpawnAccel_EnsureLegacyBuckets();
        return Plugin_Stop;
    }
    if (status != AnneSpawnNavGraph_Ready)
        return Plugin_Continue;

    if (!g_bSpawnAccelGraphReady)
    {
        if (!SpawnAccel_LoadGraphProgress())
        {
            g_hSpawnAccelGraphTimer = INVALID_HANDLE;
            Debug_Print("[SPAWN ACCEL] Nav progress export failed; using SourcePawn progress cache and all-Nav candidate fallback");
            if (g_bSpawnAccelTopologyRetryInProgress)
            {
                Debug_Print("[SPAWN ACCEL] topology retry outcome=failed classification=progress_export_failure");
                g_bSpawnAccelTopologyRetryInProgress = false;
            }
            SpawnAccel_EnsureLegacyBuckets();
            return Plugin_Stop;
        }
        g_bSpawnAccelGraphReady = true;
        char diagnostics[768];
        int diagnosticFlags = SpawnAccel_GetGraphDiagnostics(
            diagnostics, sizeof diagnostics);
        g_bSpawnAccelGraphCandidatesAvailable = diagnosticFlags < 0
            || (diagnosticFlags & ANNE_SPAWN_NAV_DIAG_COMPLETE) != 0;
        g_bSpawnAccelDynamicRebuildPending = false;
        Debug_Print("[SPAWN ACCEL] Nav graph/progress ready: areas=%d edges=%d workers=%d candidateSource=%s diagnostics=(%s)",
                    AnneSpawn_NavGraphGetAreaCount(), AnneSpawn_NavGraphGetEdgeCount(),
                    AnneSpawn_GetWorkerCount(),
                    g_bSpawnAccelGraphCandidatesAvailable ? "directed" : "all_path_bracket",
                    diagnostics);
        if (!g_bSpawnAccelGraphCandidatesAvailable)
        {
            Debug_Print("[SPAWN ACCEL] live topology is incomplete; mapped bad-flow areas remain eligible, final min/max uses directed BuildPath");
            if (g_bSpawnAccelTopologyRetryInProgress)
            {
                Debug_Print("[SPAWN ACCEL] topology retry outcome=incomplete classification=persistent_topology diagnostics=(%s)",
                            diagnostics);
                g_bSpawnAccelTopologyRetryInProgress = false;
            }
            else if (SpawnAccel_ShouldRetryTopology(diagnosticFlags)
                && !g_bSpawnAccelTopologyRetryAttempted)
            {
                g_bSpawnAccelTopologyRetryAttempted = true;
                g_hSpawnAccelTopologyRetryTimer = CreateTimer(
                    SPAWN_ACCEL_TOPOLOGY_RETRY_DELAY, Timer_SpawnAccelTopologyRetry,
                    _, TIMER_FLAG_NO_MAPCHANGE);
                Debug_Print("[SPAWN ACCEL] topology retry armed delay=%.1fs diagnostics=(%s)",
                            SPAWN_ACCEL_TOPOLOGY_RETRY_DELAY, diagnostics);
            }
            else if (!SpawnAccel_ShouldRetryTopology(diagnosticFlags))
            {
                Debug_Print("[SPAWN ACCEL] topology retry skipped classification=persistent_runtime_topology diagnostics=(%s)",
                            diagnostics);
            }
        }
        else if (g_bSpawnAccelTopologyRetryInProgress)
        {
            Debug_Print("[SPAWN ACCEL] topology retry outcome=complete classification=load_order_recovered diagnostics=(%s)",
                        diagnostics);
            g_bSpawnAccelTopologyRetryInProgress = false;
        }
    }

    // 预热 reachability；候选快照由 OnGameFrame 按空闲/临近刷新频率调度。
    // 图加载完成后停止建图 timer，后续每帧 pump 只发布已完成结果。
    SpawnAccel_PrepareCurrentSurvivorRange();
    g_hSpawnAccelGraphTimer = INVALID_HANDLE;
    return Plugin_Stop;
}

public Action Timer_SpawnAccelTopologyRetry(Handle timer)
{
    if (timer != g_hSpawnAccelTopologyRetryTimer)
        return Plugin_Stop;

    g_hSpawnAccelTopologyRetryTimer = INVALID_HANDLE;
    if (!g_bInfectedControlStarted || g_bRuntimeMapEnding || !g_bSpawnAccel)
        return Plugin_Stop;

    char mapName[64];
    GetCurrentMap(mapName, sizeof mapName);
    g_bSpawnAccelTopologyRetryInProgress = true;
    Debug_Print("[SPAWN ACCEL] topology retry started map=%s delay=%.1fs forceRebuild=1",
                mapName, SPAWN_ACCEL_TOPOLOGY_RETRY_DELAY);
    SpawnAccel_StartNavGraph(true);
    return Plugin_Stop;
}

stock void SpawnAccel_StartNavGraph(bool forceRebuild = false)
{
    SpawnAccel_StopGraphStartTimer();
    SpawnAccel_ClearGraphState(false);
    if (!g_bSpawnAccel)
    {
        SpawnAccel_EnsureLegacyBuckets();
        return;
    }

    char dataDir[PLATFORM_MAX_PATH];
    char graphDir[PLATFORM_MAX_PATH];
    char graphPath[PLATFORM_MAX_PATH];
    char mapName[64];
    dataDir[0] = '\0';
    graphDir[0] = '\0';
    graphPath[0] = '\0';
    mapName[0] = '\0';
    if (BuildPath(Path_SM, dataDir, sizeof dataDir, "data/anne_spawn_accel") <= 0
        || (!DirExists(dataDir) && !CreateDirectory(dataDir, 511))
        || !DirExists(dataDir))
    {
        Debug_Print("[SPAWN ACCEL] cache directory unavailable path=%s", dataDir);
        SpawnAccel_EnsureLegacyBuckets();
        return;
    }
    if (BuildPath(Path_SM, graphDir, sizeof graphDir,
                  "data/anne_spawn_accel/navgraph") <= 0
        || (!DirExists(graphDir) && !CreateDirectory(graphDir, 511))
        || !DirExists(graphDir))
    {
        Debug_Print("[SPAWN ACCEL] graph cache directory unavailable path=%s", graphDir);
        SpawnAccel_EnsureLegacyBuckets();
        return;
    }
    GetCurrentMap(mapName, sizeof mapName);
    if (mapName[0] == '\0'
        || BuildPath(Path_SM, graphPath, sizeof graphPath,
                     "data/anne_spawn_accel/navgraph/%s.anvg", mapName) <= 0)
    {
        Debug_Print("[SPAWN ACCEL] graph cache path unavailable map=%s", mapName);
        SpawnAccel_EnsureLegacyBuckets();
        return;
    }

    float maxFlowDistance = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlowDistance <= 0.0 ||
        !AnneSpawn_NavGraphStart(mapName, graphPath, maxFlowDistance, forceRebuild))
    {
        SpawnAccel_EnsureLegacyBuckets();
        return;
    }
    g_hSpawnAccelGraphTimer = CreateTimer(
        0.10, Timer_SpawnAccelGraphPump, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

stock bool SpawnAccel_MapInvalidNavAreas(ArrayList validIdxs, ArrayList badIdxs,
                                         float radius, int &mapped, int &dropped)
{
    mapped = 0;
    dropped = 0;

    if (!g_bSpawnAccel || validIdxs == null || badIdxs == null)
        return false;

    int validCount = validIdxs.Length;
    int queryCount = badIdxs.Length;
    if (validCount <= 0 || queryCount <= 0
        || validCount > SPAWN_ACCEL_MAX_SPATIAL_POINTS
        || queryCount > SPAWN_ACCEL_MAX_SPATIAL_POINTS)
    {
        return false;
    }

    float[] validXY = new float[validCount * 2];
    int[] validAreaIndices = new int[validCount];
    float[] queryXY = new float[queryCount * 2];
    int[] outputAreaIndices = new int[queryCount];

    for (int i = 0; i < validCount; i++)
    {
        int areaIdx = validIdxs.Get(i);
        validAreaIndices[i] = areaIdx;
        validXY[i * 2] = view_as<float>(g_AreaCX.Get(areaIdx));
        validXY[i * 2 + 1] = view_as<float>(g_AreaCY.Get(areaIdx));
    }

    for (int i = 0; i < queryCount; i++)
    {
        int areaIdx = badIdxs.Get(i);
        queryXY[i * 2] = view_as<float>(g_AreaCX.Get(areaIdx));
        queryXY[i * 2 + 1] = view_as<float>(g_AreaCY.Get(areaIdx));
    }

    if (!AnneSpawn_MapNearest2D(validXY, validAreaIndices, validCount,
                                queryXY, queryCount, 2000.0, radius,
                                outputAreaIndices))
    {
        return false;
    }

    for (int i = 0; i < queryCount; i++)
    {
        int sourceAreaIdx = badIdxs.Get(i);
        int nearestAreaIdx = outputAreaIndices[i];
        if (nearestAreaIdx < 0 || nearestAreaIdx >= g_AreaPct.Length)
        {
            dropped++;
            continue;
        }

        int percent = ClampInt(view_as<int>(g_AreaPct.Get(nearestAreaIdx)), 0, 100);
        if (g_FlowBuckets[percent] == null)
            g_FlowBuckets[percent] = new ArrayList();
        g_FlowBuckets[percent].Push(sourceAreaIdx);

        float zmin = view_as<float>(g_AreaZMin.Get(sourceAreaIdx));
        float zmax = view_as<float>(g_AreaZMax.Get(sourceAreaIdx));
        if (zmin < g_BucketMinZ[percent]) g_BucketMinZ[percent] = zmin;
        if (zmax > g_BucketMaxZ[percent]) g_BucketMaxZ[percent] = zmax;
        g_AreaPct.Set(sourceAreaIdx, percent);
        mapped++;
    }

    return true;
}
