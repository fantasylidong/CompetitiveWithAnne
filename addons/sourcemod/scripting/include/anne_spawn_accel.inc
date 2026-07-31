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

native bool AnneSpawn_IsActive();

native bool AnneSpawn_NavGraphStart(
    const char[] mapName,
    const char[] cachePath,
    float maxFlowDistance,
    bool forceRebuild
);

native AnneSpawnNavGraphStatus AnneSpawn_NavGraphPump();
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

native int AnneSpawn_NavGraphGetAreaCount();
native int AnneSpawn_NavGraphGetEdgeCount();
// 一次性导出与图 area index 对齐的原始进度距离；坏 flow 可在扩展后台按 Nav 邻接补齐。
native int AnneSpawn_NavGraphCollectProgress(
    float[] outputFlowDistances,
    int maxResults,
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
