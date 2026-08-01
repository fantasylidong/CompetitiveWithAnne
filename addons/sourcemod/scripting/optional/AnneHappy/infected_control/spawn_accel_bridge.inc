#if defined _infected_control_spawn_accel_bridge_included
    #endinput
#endif
#define _infected_control_spawn_accel_bridge_included

#define SPAWN_ACCEL_MAX_SPATIAL_POINTS 100000
#define SPAWN_ACCEL_PATH_BOUNDARY_SLACK 32.0

bool g_bSpawnAccel;
bool g_bSpawnAccelGraphReady;
bool g_bSpawnAccelAvailabilityKnown;
Handle g_hSpawnAccelGraphTimer = INVALID_HANDLE;
ArrayList g_SpawnAccelRawFlowDistances = null;

static const char g_sSpawnAccelRequiredNatives[][] =
{
    "AnneSpawn_IsActive",
    "AnneSpawn_NavGraphStart",
    "AnneSpawn_NavGraphPump",
    "AnneSpawn_NavGraphStop",
    "AnneSpawn_NavGraphPrepareRange",
    "AnneSpawn_NavGraphGetAreaCount",
    "AnneSpawn_NavGraphGetEdgeCount",
    "AnneSpawn_NavGraphCollectProgress",
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
    return g_bSpawnAccel
        && gCV.bSpawnAccelNativeSafety
        && GetFeatureStatus(FeatureType_Native, "AnneSpawn_TestPointSafety")
            == FeatureStatus_Available;
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
    if (g_hSpawnAccelGraphTimer != INVALID_HANDLE)
    {
        KillTimer(g_hSpawnAccelGraphTimer);
        g_hSpawnAccelGraphTimer = INVALID_HANDLE;
    }
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

    float[] flowDistances = new float[areaCount];
    int count = AnneSpawn_NavGraphCollectProgress(
        flowDistances, areaCount, gCV.bNavBucketMapInvalid,
        gCV.fNavBucketAssignRadius);
    if (count != areaCount)
        return false;

    ClearNavBuckets();
    if (g_SpawnAccelRawFlowDistances != null)
        delete g_SpawnAccelRawFlowDistances;
    g_SpawnAccelRawFlowDistances = new ArrayList();
    for (int i = 0; i < count; i++)
        g_SpawnAccelRawFlowDistances.Push(flowDistances[i]);
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
    SpawnAccel_StopGraphTimer();
    if (stopExtension && g_bSpawnAccel)
        AnneSpawn_NavGraphStop();
    g_bSpawnAccelGraphReady = false;
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
    float maxPathDistance = gCV.fSpawnMax * 1.5 + SPAWN_ACCEL_PATH_BOUNDARY_SLACK;
    return AnneSpawn_NavGraphPrepareRange(targetId, maxPathDistance, TEAM_INFECTED, false);
}

public Action Timer_SpawnAccelGraphPump(Handle timer)
{
    if (!g_bSpawnAccel)
    {
        g_hSpawnAccelGraphTimer = INVALID_HANDLE;
        return Plugin_Stop;
    }

    AnneSpawnNavGraphStatus status = AnneSpawn_NavGraphPump();
    if (status == AnneSpawnNavGraph_Failed)
    {
        g_bSpawnAccelGraphReady = false;
        g_hSpawnAccelGraphTimer = INVALID_HANDLE;
        Debug_Print("[SPAWN ACCEL] Nav graph build/load failed; enabling legacy flow buckets and BuildPath fallback");
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
            Debug_Print("[SPAWN ACCEL] Nav progress export failed; enabling legacy flow buckets");
            SpawnAccel_EnsureLegacyBuckets();
            return Plugin_Stop;
        }
        g_bSpawnAccelGraphReady = true;
        Debug_Print("[SPAWN ACCEL] Nav graph/progress ready: areas=%d edges=%d workers=%d",
                    AnneSpawn_NavGraphGetAreaCount(), AnneSpawn_NavGraphGetEdgeCount(),
                    AnneSpawn_GetWorkerCount());
    }

    // Prepare 会发布后台 reachability，后续 AnneSpawn_PathExists 直接消费结果。
    // CollectRange 当前未进入插件热路径；图加载完成后停止 10Hz pump。
    SpawnAccel_PrepareCurrentSurvivorRange();
    g_hSpawnAccelGraphTimer = INVALID_HANDLE;
    return Plugin_Stop;
}

stock void SpawnAccel_StartNavGraph(bool forceRebuild = false)
{
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
    BuildPath(Path_SM, dataDir, sizeof dataDir, "data/anne_spawn_accel");
    CreateDirectory(dataDir, 511);
    BuildPath(Path_SM, graphDir, sizeof graphDir, "data/anne_spawn_accel/navgraph");
    CreateDirectory(graphDir, 511);
    GetCurrentMap(mapName, sizeof mapName);
    BuildPath(Path_SM, graphPath, sizeof graphPath,
              "data/anne_spawn_accel/navgraph/%s.anvg", mapName);

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
