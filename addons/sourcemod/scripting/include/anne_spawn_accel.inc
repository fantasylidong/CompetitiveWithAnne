#if defined _anne_spawn_accel_included
    #endinput
#endif
#define _anne_spawn_accel_included

#define ANNE_SPAWN_ACCEL_LIBRARY "anne_spawn_accel"

enum AnneSpawnSafetyResult
{
    AnneSpawnSafety_Safe = 0,
    AnneSpawnSafety_Stuck,
    AnneSpawnSafety_Visible
};

enum AnneSpawnNavGraphStatus
{
    AnneSpawnNavGraph_Idle = 0,
    AnneSpawnNavGraph_Loading,
    AnneSpawnNavGraph_Building,
    AnneSpawnNavGraph_Ready,
    AnneSpawnNavGraph_Failed
};

#define ANNE_SPAWN_NAV_CANDIDATE_PENDING     -1
#define ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE -2
#define ANNE_SPAWN_NAV_DISTANCE_PENDING       -1
#define ANNE_SPAWN_NAV_DISTANCE_UNAVAILABLE   -2
#define ANNE_SPAWN_NAV_CANDIDATE_PERF_FLOATS 10
#define ANNE_SPAWN_NAV_CANDIDATE_PERF_COUNTS 13
#define ANNE_SPAWN_NAV_DIAG_COMPLETE              (1 << 0)
#define ANNE_SPAWN_NAV_DIAG_CACHE_HIT             (1 << 1)
#define ANNE_SPAWN_NAV_DIAG_UNKNOWN_AREA          (1 << 2)
#define ANNE_SPAWN_NAV_DIAG_INVALID_FLOOR_STORAGE (1 << 3)
#define ANNE_SPAWN_NAV_DIAG_INVALID_LADDER_STORAGE (1 << 4)
#define ANNE_SPAWN_NAV_DIAG_DYNAMIC_ELEVATOR      (1 << 5)
#define ANNE_SPAWN_NAV_DIAG_UNRESOLVED_DYNAMIC_ELEVATOR (1 << 6)

enum AnneSpawnNavCandidatePerfFloat
{
    AnneSpawnCandidatePerf_BuildLast = 0,
    AnneSpawnCandidatePerf_BuildP50,
    AnneSpawnCandidatePerf_BuildP95,
    AnneSpawnCandidatePerf_BuildP99,
    AnneSpawnCandidatePerf_BuildMax,
    AnneSpawnCandidatePerf_AgeLast,
    AnneSpawnCandidatePerf_AgeP50,
    AnneSpawnCandidatePerf_AgeP95,
    AnneSpawnCandidatePerf_AgeP99,
    AnneSpawnCandidatePerf_AgeMax
};

enum AnneSpawnNavCandidatePerfCount
{
    AnneSpawnCandidatePerf_BuildSamples = 0,
    AnneSpawnCandidatePerf_Queued,
    AnneSpawnCandidatePerf_Published,
    AnneSpawnCandidatePerf_CacheHits,
    AnneSpawnCandidatePerf_Coalesced,
    AnneSpawnCandidatePerf_StaleDrops,
    AnneSpawnCandidatePerf_CollectHits,
    AnneSpawnCandidatePerf_CollectPending,
    AnneSpawnCandidatePerf_CollectUnavailable,
    AnneSpawnCandidatePerf_LastCandidates,
    AnneSpawnCandidatePerf_InFlight,
    AnneSpawnCandidatePerf_CacheEntries,
    AnneSpawnCandidatePerf_LastRangeCandidates
};

native bool AnneSpawn_IsActive();

native bool AnneSpawn_NavGraphStart(
    const char[] mapName,
    const char[] cachePath,
    float maxFlowDistance,
    bool forceRebuild
);

// warm=true 时动态 Nav 以 0.1s 轮询；空闲时自动降到 1.0s。
native AnneSpawnNavGraphStatus AnneSpawn_NavGraphPump(bool warm = false);
native void AnneSpawn_NavGraphStop();

native bool AnneSpawn_NavGraphPrepareRange(
    int targetNavId,
    float maxPathDistance,
    int team,
    bool ignoreNavBlockers
);

// 返回图中的 area index；-1 表示查询尚未就绪。
native int AnneSpawn_NavGraphCollectRange(
    int targetNavId,
    float minPathDistance,
    float maxPathDistance,
    int[] outputAreaIndices,
    int maxResults
);

// 查询 candidate -> targetNav 的原始有向 Nav 中心累计距离。
// 返回 1=可达且 distance 有效，0=在 maxPathDistance 内不可达，
// -1=距离场仍在后台构建，-2=图或参数不可用。
native int AnneSpawn_NavGraphGetPathDistance(
    int candidateNavId,
    int targetNavId,
    float maxPathDistance,
    int team,
    bool ignoreNavBlockers,
    float &distance
);

// 后台构建 candidate -> targetNav 有向可达、全队距离过滤后的目标候选快照。
// 返回 1=已有足够新的快照，0=已排队/正在构建，-2=图不可用。
native int AnneSpawn_NavCandidatesPrepare(
    int targetClient,
    int targetNavId,
    float maxPathDistance,
    float minSurvivorDistance,
    float maxSnapshotAge
);

// 在按 candidate -> target 有向 Nav 路径距离升序的快照中分页取范围。
// 返回 >=0 的本页数量，-1=结果未就绪/已过期，-2=图不可用。
native int AnneSpawn_NavCandidatesCollect(
    int targetClient,
    int targetNavId,
    float minNavDistance,
    float maxNavDistance,
    float maxPathDistance,
    float minSurvivorDistance,
    float maxSnapshotAge,
    int startOffset,
    int[] outputAreaIndices,
    float[] outputNavDistances,
    int maxResults,
    float &resultAgeMs,
    int &totalInRange
);

// V2: raw Nav distance still controls the requested min/max range. Within that
// range, areas whose center is sufficiently above the target are globally
// ordered by rawDistance * highGroundDistanceScale. Raw and rank distances are
// returned separately so collection ranges and global visit order cannot be
// confused; callers may still apply their own class-specific effective range.
native int AnneSpawn_NavCandidatesPrepareRanked(
    int targetClient,
    int targetNavId,
    float maxPathDistance,
    float minSurvivorDistance,
    float maxSnapshotAge,
    float highGroundMinHeight,
    float highGroundDistanceScale
);

native int AnneSpawn_NavCandidatesCollectRanked(
    int targetClient,
    int targetNavId,
    float minNavDistance,
    float maxNavDistance,
    float maxPathDistance,
    float minSurvivorDistance,
    float maxSnapshotAge,
    float highGroundMinHeight,
    float highGroundDistanceScale,
    int startOffset,
    int[] outputAreaIndices,
    float[] outputNavDistances,
    float[] outputRankDistances,
    int maxResults,
    float &resultAgeMs,
    int &totalInRange
);

native bool AnneSpawn_NavCandidatesGetPerf(
    float[] timings,
    int timingCount,
    int[] counters,
    int counterCount
);
native void AnneSpawn_NavCandidatesResetPerf();

native int AnneSpawn_NavGraphGetAreaCount();
native int AnneSpawn_NavGraphGetEdgeCount();
// 返回诊断位，并把缓存来源/拓扑完整性/失效原因写入 reason。
native int AnneSpawn_NavGraphGetDiagnostics(char[] reason, int maxlen);
// 一次性导出与图 area index 对齐的原始进度距离；坏 flow 可在扩展后台按 Nav 邻接补齐。
native int AnneSpawn_NavGraphCollectProgress(
    float[] outputFlowDistances,
    int maxResults,
    bool mapInvalid,
    float maxResolveDistance
);
// 分页导出进度，避免大地图在 SourcePawn 中为全部 Nav 一次性申请动态数组。
native int AnneSpawn_NavGraphCollectProgressPage(
    float[] outputFlowDistances,
    int maxResults,
    int offset,
    bool mapInvalid,
    float maxResolveDistance
);
native int AnneSpawn_GetWorkerCount();

native bool AnneSpawn_SetSurvivorSnapshot(
    const int[] clients,
    const bool[] incapacitated,
    const float[] eyes,
    const float[] eyesLeft,
    const float[] eyesRight,
    int count
);

native void AnneSpawn_ClearSurvivorSnapshot();

native AnneSpawnSafetyResult AnneSpawn_TestPointSafety(
    const float pos[3],
    bool teleportMode,
    bool ignoreIncapSight,
    int visibilityRayMode
);

native bool AnneSpawn_ComputePointGeometry(
    const float pos[3],
    const float center[3],
    int sectors,
    const float targetEye[3],
    float &minEyeDistanceSquared,
    float &targetEyeDistance,
    int &sector
);

native bool AnneSpawn_ComputeGeometryBatch(
    const float[] positions,
    int count,
    const float center[3],
    int sectors,
    const float targetEye[3],
    float[] minEyeDistanceSquared,
    float[] targetEyeDistance,
    int[] sector
);

native int AnneSpawn_SelectTopK(
    const float[] scores,
    int count,
    int topK,
    int[] outputIndices
);

native bool AnneSpawn_MapNearest2D(
    const float[] validXY,
    const int[] validAreaIndices,
    int validCount,
    const float[] queryXY,
    int queryCount,
    float cellSize,
    float radius,
    int[] outputAreaIndices
);

native bool AnneSpawn_PathExists(
    Address navGoal,
    int navGoalId,
    Address navStart,
    int navStartId,
    float maxPathLength,
    int quantizedLength,
    int team,
    bool ignoreNavBlockers,
    bool useCache
);

native void AnneSpawn_ClearPathCache();
