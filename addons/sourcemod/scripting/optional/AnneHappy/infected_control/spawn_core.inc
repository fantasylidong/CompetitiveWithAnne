#if defined _infected_control_spawn_core_included
    #endinput
#endif
#define _infected_control_spawn_core_included

enum struct SpawnFilterStats
{
    int cooldown;
    int flags;
    int flow;
    int distance;
    int separation;
    int stuck;
    int visibility;
    int path;
    int position;
    int score;
    int bucket;

    void Reset()
    {
        this.cooldown = 0;
        this.flags = 0;
        this.flow = 0;
        this.distance = 0;
        this.separation = 0;
        this.stuck = 0;
        this.visibility = 0;
        this.path = 0;
        this.position = 0;
        this.score = 0;
        this.bucket = 0;
    }
}

// 刷点核心分两层：
// - FindSpawnPosViaNavArea：准备生还者/Flow/扇区上下文，决定桶扫描或全图扫描。
// - SpawnCore_EvaluateNavCandidate：评估单个 NavArea，按“便宜过滤 -> 昂贵精判 -> 评分”的顺序执行。
//
// 修改性能或刷点质量时优先阅读 README_SPAWN_ARCHITECTURE.md。这里的过滤顺序不是随意排列：
// 先做 area/flags/bucket/cooldown 这类区域级轻量判断，再取随机点，再做距离/stuck/visibility/path。
// IsPosVisibleSDK 和 L4D2_NavAreaBuildPath 是最贵的热点，新增过滤器应尽量放在它们之前。

static void SpawnCore_CopyPos(float dest[3], const float src[3])
{
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

// 通过 areaIdx 反查分桶：优先使用缓存，其次使用 Flow 百分比。
stock bool TryGetBucketByAreaIdx(int areaIdx, int &outBucket)
{
    outBucket = -1;
    if (areaIdx < 0) return false;

    if (g_AreaPct != null && areaIdx < g_AreaPct.Length)
    {
        int bucket = view_as<int>(g_AreaPct.Get(areaIdx));
        if (bucket >= 0 && bucket <= 100)
        {
            outBucket = bucket;
            return true;
        }
    }

    if (g_AllNavAreasCache != null && areaIdx < g_NavAreasCacheCount)
    {
        Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
        if (areaAddr != Address_Null)
        {
            NavArea area = view_as<NavArea>(areaAddr);
            if (area)
            {
                float flow = area.GetFlow();
                float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
                if (flow >= 0.0 && flow <= maxFlow)
                {
                    outBucket = ClampInt(FlowDistanceToPercent(flow), 0, 100);
                    return true;
                }
            }
        }
    }
    return false;
}

static bool SpawnCore_EvaluateNavCandidate(int zc,
                                           int targetSurvivor,
                                           const float targetPoint[3],
                                           float minRange,
                                           float searchRange,
                                           bool teleportMode,
                                           int areaIdx,
                                           int knownBucket,
                                           bool rejectBadFlow,
                                           float mapMaxFlowDist,
                                           bool finaleArea,
                                           const float center[3],
                                           int sectors,
                                           float allMaxZ,
                                           int centerBucket,
                                           int positionCheckBucket,
                                           float refEyeZ,
                                           float lowestFootZ,
                                           bool hasLowestFootZ,
                                           Address navStart,
                                           int visibilityRayMode,
                                           float minScore,
                                           float now,
                                           SpawnScoreDbg candDbg,
                                           SpawnFilterStats stats,
                                           bool &usedExpensive)
{
    usedExpensive = false;
    // 0) 防御性检查：areaIdx 必须先验证，避免无效 index 进入 NavArea native。
    if (areaIdx < 0 || areaIdx >= g_NavAreasCacheCount)
    {
        stats.position++;
        SpawnPerf_RecordFilterByPosition();
        return false;
    }

    Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
    NavArea area = view_as<NavArea>(areaAddr);

    if (!area)
    {
        stats.position++;
        SpawnPerf_RecordFilterByPosition();
        return false;
    }

    // 1) NavArea flags 是区域级过滤，不需要随机点。安全屋/救援等区域在这里直接跳过。
    if (!IsValidFlags(area.SpawnAttributes, finaleArea))
    {
        stats.flags++;
        SpawnPerf_RecordFilterByFlags();
        return false;
    }

    int candidateBucket = knownBucket;
    float flow = 0.0;
    bool flowLoaded = false;
    bool rawBadFlow = false;

    // 2) 桶模式调用方已经知道 bucket，避免每个候选都读取 Flow。
    //    全图 fallback 或需要拒绝 badflow 时才加载 area.GetFlow()。
    if (candidateBucket < 0 || rejectBadFlow)
    {
        flow = area.GetFlow();
        flowLoaded = true;
        rawBadFlow = IsFlowAbnormal(flow, mapMaxFlowDist);

        if (rejectBadFlow && rawBadFlow)
        {
            stats.flow++;
            SpawnPerf_RecordFilterByFlow();
            return false;
        }

        if (candidateBucket < 0)
            candidateBucket = FlowDistanceToPercent(flow);
    }
    candidateBucket = ClampInt(candidateBucket, 0, 100);

    // 3) 冷却和同桶上限都是区域/桶级判断，放在 GetRandomPoint 之前节省点位级成本。
    if (IsNavOnCooldown(areaIdx, now))
    {
        stats.cooldown++;
        SpawnPerf_RecordFilterByCooldown();
        return false;
    }

    if (!PassBucketShareLimit(candidateBucket))
    {
        stats.bucket++;
        SpawnPerf_RecordFilterByBucket();
        return false;
    }

    // 4) 从这里开始才进入点位级成本。一个 NavArea 内可能同时跨过距离带边界；
    //    若随机点只在廉价检查阶段失败，少量重采样比丢掉整个区域后继续扫图更划算。
    float pos[3];
    float slack = 0.0;
    float ringEff = searchRange;
    float dminEyeSq = 0.0;
    float minDistSq = minRange * minRange;
    bool haveCheapCandidate = false;
    bool geometryReady = false;
    float dTargetEye = 0.0;
    int sector = 0;
    float targetEye[3];
    if (!Visibility_GetClientEyeSnapshot(targetSurvivor, targetEye))
        SpawnCore_CopyPos(targetEye, targetPoint);

    for (int sample = 0; sample < NAV_RANDOM_POINT_TRIES; sample++)
    {
        area.GetRandomPoint(pos);

        // 5) 最近刷点分散是纯内存距离检查，比距离/trace/path 都便宜。
        if (!PassMinSeparation(pos))
        {
            stats.separation++;
            SpawnPerf_RecordFilterBySeparation();
            continue;
        }

        // 6) 当前职业范围是硬边界；高度只参与评分，不再隐式扩大搜索范围。
        geometryReady = g_bSpawnAccel
            && AnneSpawn_ComputePointGeometry(pos, center, sectors, targetEye,
                                               dminEyeSq, dTargetEye, sector);
        if (!geometryReady)
            dminEyeSq = GetMinEyeDistSquaredToAnySurvivor(pos);
        float maxDistSq = ringEff * ringEff;
        if (dminEyeSq < minDistSq || dminEyeSq > maxDistSq)
        {
            stats.distance++;
            SpawnPerf_RecordFilterByDist();
            continue;
        }

        // 7) 使用已知 candidateBucket 做真实位置检查，避免 GetPositionBucketPercent(pos) 再查 Nav。
        if (!PassRealBucketPositionCheckCached(candidateBucket, pos[2], positionCheckBucket,
                                               hasLowestFootZ, lowestFootZ, zc))
        {
            stats.position++;
            SpawnPerf_RecordFilterByPosition();
            continue;
        }

        haveCheapCandidate = true;
        break;
    }

    if (!haveCheapCandidate)
        return false;

    // 8) 卡壳、可见性、路径都是昂贵检查，必须排在轻量过滤之后。
    usedExpensive = true;
    bool pointStuck;
    bool pointVisible;
    if (SpawnAccel_CanUseNativeSafety())
    {
        AnneSpawnSafetyResult safety = AnneSpawn_TestPointSafety(
            pos, teleportMode, gCV.bIgnoreIncapSight, visibilityRayMode);
        pointStuck = (safety == AnneSpawnSafety_Stuck);
        pointVisible = (safety == AnneSpawnSafety_Visible);
    }
    else
    {
        pointStuck = WillStuck(pos);
        pointVisible = !pointStuck
            && IsPosVisibleSDKWithMode(pos, teleportMode, visibilityRayMode);
    }

    if (pointStuck)
    {
        stats.stuck++;
        SpawnPerf_RecordFilterByStuck();
        return false;
    }
    if (pointVisible)
    {
        stats.visibility++;
        SpawnPerf_RecordFilterByVisibility();
        return false;
    }
    if (PathPenalty_NoBuildFromStart(pos, navStart, searchRange, gCV.fSpawnMax) != 0.0)
    {
        stats.path++;
        SpawnPerf_RecordFilterByPath();
        return false;
    }

    // 9) 只有通过所有硬过滤的候选才需要 rawBadFlow 和评分。
    //     这能让桶模式下大量失败候选完全不读 area.GetFlow()。
    if (!flowLoaded)
    {
        flow = area.GetFlow();
        flowLoaded = true;
        rawBadFlow = IsFlowAbnormal(flow, mapMaxFlowDist);
    }

    if (!geometryReady)
    {
        sector = ComputeSectorIndex(center, pos, sectors);
        dTargetEye = GetVectorDistance(pos, targetEye);
    }
    float tacticalQuality = Tactical_GetCandidateQuality(
        zc, pos, targetSurvivor, targetPoint);
    SpawnPerf_RecordFullEvaluation();
    float navWeight = 1.0;
    if (!SpawnScore_BuildCandidate(zc, pos, dTargetEye, minRange, ringEff, slack,
                                   candidateBucket, centerBucket, rawBadFlow,
                                   refEyeZ, allMaxZ, lowestFootZ, sector, areaIdx,
                                   navWeight, tacticalQuality, candDbg))
    {
        stats.flow++;
        SpawnPerf_RecordFilterByFlow();
        return false;
    }

    // 历史权重仅保留在调试信息中，不改变原扫描顺序或候选资格。
    if (minScore > 0.0 && candDbg.total < minScore)
    {
        stats.score++;
        SpawnPerf_RecordFilterByScore();
        return false;
    }

    return true;
}

enum SpawnSearchResult
{
    SpawnSearch_Pending = 0,
    SpawnSearch_Found,
    SpawnSearch_Exhausted
}

enum SpawnCandidateSource
{
    SpawnCandidate_None = 0,
    SpawnCandidate_Buckets,
    SpawnCandidate_All
}

enum struct SpawnSearchState
{
    bool active;
    int zc;
    int targetSurvivor;
    int targetUserid;
    float minRange;
    float maxRange;
    bool teleportMode;

    SpawnCandidateSource source;
    int allRow;
    int bucketOrder[FLOW_BUCKETS];
    int bucketOrderLen;
    int bucketOrderIdx;
    int bucketRow;

    int candidateBudget;
    int acceptedHits;
    int inspected;
    bool firstFit;
    bool found;
    float bestScore;
    float elapsedMs;
    SpawnScoreDbg bestDbg;
    SpawnFilterStats stats;

    float mapMaxFlowDist;
    bool finaleArea;
    float center[3];
    int sectors;
    float allMaxZ;
    int centerBucket;
    int positionCheckBucket;
    float targetPoint[3];
    float refEyeZ;
    float lowestFootZ;
    bool hasLowestFootZ;
    Address navStart;
    int visibilityRayMode;
    float minScore;
    float firstFitScore;
}

static SpawnSearchState g_NormalSpawnSearchStates[SI_COUNT];
static SpawnSearchState g_TeleportSpawnSearchStates[SI_COUNT];

static void SpawnSearch_ResetState(SpawnSearchState state)
{
    state.active = false;
    state.source = SpawnCandidate_None;
    state.allRow = 0;
    state.bucketOrderLen = 0;
    state.bucketOrderIdx = 0;
    state.bucketRow = 0;
    state.navStart = Address_Null;
    state.acceptedHits = 0;
    state.inspected = 0;
    state.found = false;
    state.bestScore = -1.0e9;
    state.elapsedMs = 0.0;
    state.stats.Reset();
}

void SpawnSearch_Reset()
{
    for (int i = 0; i < SI_COUNT; i++)
    {
        SpawnSearch_ResetState(g_NormalSpawnSearchStates[i]);
        SpawnSearch_ResetState(g_TeleportSpawnSearchStates[i]);
    }
}

void SpawnSearch_ResetClass(int zc, bool teleportMode)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    if (teleportMode)
        SpawnSearch_ResetState(g_TeleportSpawnSearchStates[idx]);
    else
        SpawnSearch_ResetState(g_NormalSpawnSearchStates[idx]);
}

static bool SpawnSearch_Matches(SpawnSearchState state,
                                int zc, int targetSurvivor, float minRange,
                                float maxRange, bool teleportMode)
{
    if (!state.active || state.zc != zc
        || state.targetSurvivor != targetSurvivor
        || state.minRange != minRange || state.maxRange != maxRange
        || state.teleportMode != teleportMode)
    {
        return false;
    }

    int userid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    return userid == state.targetUserid;
}

static bool SpawnSearch_Begin(SpawnSearchState state,
                              int zc, int targetSurvivor, float minRange,
                              float maxRange, bool teleportMode)
{
    SpawnSearch_ResetState(state);
    if (!Visibility_HasCurrentEyeSnapshot())
        Visibility_RefreshEyeSnapshot();

    float buildStart = GetEngineTime();
    if (!GetSurPosData())
    {
        SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
        Debug_Print("[FIND FAIL] no survivor data");
        return false;
    }

    EnsureNavAreasCache();
    if (g_AllNavAreasCache == null || g_NavAreasCacheCount <= 0)
    {
        SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
        return false;
    }
    EnsureNavCooldownSlots();

    state.zc = zc;
    state.targetSurvivor = targetSurvivor;
    state.targetUserid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    state.minRange = minRange;
    state.maxRange = maxRange;
    state.teleportMode = teleportMode;
    state.mapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    state.finaleArea = L4D_IsMissionFinalMap()
        && L4D2_GetCurrentFinaleStage() < FINALE_STAGE_ESCAPE;
    GetSectorCenter(state.center, targetSurvivor);
    state.sectors = GetCurrentSectors();

    state.allMaxZ = -1.0e9;
    SurPosData data;
    for (int i = 0; i < g_iSurPosDataLen; i++)
    {
        g_aSurPosData.GetArray(i, data);
        if (data.fPos[2] > state.allMaxZ)
            state.allMaxZ = data.fPos[2];
    }

    state.positionCheckBucket = -1;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        TryGetClientFlowPercentSafe(targetSurvivor, state.positionCheckBucket);
    }
    if (state.positionCheckBucket < 0)
    {
        float bestFlow = -1.0;
        for (int i = 0; i < g_iSurPosDataLen; i++)
        {
            g_aSurPosData.GetArray(i, data);
            if (data.fFlow > bestFlow)
                bestFlow = data.fFlow;
        }
        if (bestFlow >= 0.0)
            state.positionCheckBucket = FlowDistanceToPercent(bestFlow);
    }
    state.centerBucket = (state.positionCheckBucket >= 0)
        ? state.positionCheckBucket : 50;

    SpawnCore_CopyPos(state.targetPoint, state.center);
    state.refEyeZ = state.allMaxZ;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        GetClientEyePosition(targetSurvivor, state.targetPoint);
        state.refEyeZ = state.targetPoint[2];
    }
    state.hasLowestFootZ = TryGetLowestSurvivorFootZ(state.lowestFootZ);

    int pathTarget = targetSurvivor;
    if (!IsValidSurvivor(pathTarget) || !IsPlayerAlive(pathTarget)
        || L4D_IsPlayerIncapacitated(pathTarget))
    {
        pathTarget = (g_iSurCount > 0) ? g_iSurvivors[0] : -1;
    }
    if (IsValidSurvivor(pathTarget) && IsPlayerAlive(pathTarget))
    {
        float survivorPos[3];
        GetClientAbsOrigin(pathTarget, survivorPos);
        state.navStart = L4D2Direct_GetTerrorNavArea(survivorPos);
        if (state.navStart == Address_Null)
        {
            state.navStart = L4D_GetNearestNavArea(
                survivorPos, 120.0, false, false, false, TEAM_INFECTED);
        }
    }
    if (state.navStart == Address_Null)
    {
        SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
        return false;
    }

    if (gCV.bNavBucketEnable && g_BucketsReady)
    {
        state.source = SpawnCandidate_Buckets;
        int win = ClampInt(ComputeDynamicBucketWindow(maxRange), 0, 100);
        if (SpawnPerfConfig_UseAdaptiveBucketWindow())
            win = ClampInt(ComputeAdaptiveBucketWindow(maxRange, win), 0, 100);
        state.bucketOrderLen = SpawnPerfConfig_UseProgressiveSampling()
            ? BuildOptimizedBucketOrder(state.centerBucket, win,
                gCV.bNavBucketIncludeCtr, state.bucketOrder)
            : BuildBucketOrder(state.centerBucket, win,
                gCV.bNavBucketIncludeCtr, state.bucketOrder);
    }
    else
    {
        state.source = SpawnCandidate_All;
    }

    state.candidateBudget = DifficultyStrategy_GetCandidateBudget();
    // 回退 Trace 的单候选成本明显更高。只压缩评分样本，不减少 Nav 扫描范围，
    // 原生安全检查启用后仍使用完整的难度预算。
    if (!SpawnAccel_CanUseNativeSafety()
        && state.candidateBudget > NAV_SCAN_FALLBACK_SCORE_BUDGET)
    {
        state.candidateBudget = NAV_SCAN_FALLBACK_SCORE_BUDGET;
    }
    state.visibilityRayMode = GetEffectiveVisibilityRayMode();
    state.firstFit = gCV.bNavBucketFirstFit;
    state.minScore = gCV.fSpawnScoreFloor;
    state.firstFitScore = FloatMax(
        ComputeFFThreshold(), state.minScore);
    state.active = true;
    SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
    return true;
}

static bool SpawnSearch_NextCandidate(SpawnSearchState state,
                                      int &areaIdx, int &candidateBucket,
                                      bool &rejectBadFlow)
{
    candidateBucket = -1;
    rejectBadFlow = false;
    if (state.source == SpawnCandidate_Buckets)
    {
        while (state.bucketOrderIdx < state.bucketOrderLen)
        {
            int bucketIdx = state.bucketOrder[state.bucketOrderIdx];
            if (bucketIdx < 0 || bucketIdx >= FLOW_BUCKETS
                || g_FlowBuckets[bucketIdx] == null
                || state.bucketRow >= g_FlowBuckets[bucketIdx].Length)
            {
                state.bucketOrderIdx++;
                state.bucketRow = 0;
                continue;
            }
            areaIdx = g_FlowBuckets[bucketIdx].Get(state.bucketRow++);
            candidateBucket = bucketIdx;
            return true;
        }
        return false;
    }

    if (state.source == SpawnCandidate_All
        && state.allRow < g_NavAreasCacheCount)
    {
        areaIdx = state.allRow++;
        rejectBadFlow = true;
        return true;
    }
    return false;
}

static SpawnSearchResult SpawnSearch_Finish(SpawnSearchState state,
                                            bool exhausted, float outPos[3],
                                            int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    if (!exhausted)
        return SpawnSearch_Pending;

    if (state.found)
    {
        SpawnScore_CopyDbg(dbgOut, state.bestDbg);
        SpawnCore_CopyPos(outPos, state.bestDbg.pos);
        outAreaIdx = state.bestDbg.areaIdx;
        SpawnPerf_RecordAttempt(state.elapsedMs, true);
        SpawnSearch_ResetState(state);
        return SpawnSearch_Found;
    }
    Debug_Print("[FIND FAIL] range=%.1f..%.1f inspected=%d. Filters: cd=%d,flag=%d,flow=%d,dist=%d,sep=%d,stuck=%d,vis=%d,path=%d,pos=%d,score=%d,bkt=%d",
                state.minRange, state.maxRange, state.inspected,
                state.stats.cooldown, state.stats.flags,
                state.stats.flow, state.stats.distance,
                state.stats.separation, state.stats.stuck,
                state.stats.visibility, state.stats.path,
                state.stats.position, state.stats.score,
                state.stats.bucket);
    SpawnPerf_RecordAttempt(state.elapsedMs, false);
    SpawnSearch_ResetState(state);
    return SpawnSearch_Exhausted;
}

static SpawnSearchResult FindSpawnPosViaNavAreaStepForState(
    SpawnSearchState state,
    int zc, int targetSurvivor, float minRange, float maxRange, bool teleportMode,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    outAreaIdx = -1;
    if (!SpawnSearch_Matches(state, zc, targetSurvivor, minRange, maxRange, teleportMode))
    {
        if (!SpawnSearch_Begin(state, zc, targetSurvivor, minRange, maxRange, teleportMode))
        {
            SpawnPerf_RecordAttempt(0.0, false);
            return SpawnSearch_Exhausted;
        }
    }
    if (!Visibility_HasCurrentEyeSnapshot())
        Visibility_RefreshEyeSnapshot();

    float sliceStart = GetEngineTime();
    int sliceInspected = 0;
    int sliceExpensive = 0;
    bool exhausted = false;
    while (sliceInspected < NAV_SCAN_CANDIDATES_PER_SLICE
        && sliceExpensive < NAV_SCAN_EXPENSIVE_PER_SLICE
        && state.acceptedHits < state.candidateBudget
        && (GetEngineTime() - sliceStart) * 1000.0 < NAV_SCAN_TIME_BUDGET_MS)
    {
        int areaIdx;
        int candidateBucket;
        bool rejectBadFlow;
        if (!SpawnSearch_NextCandidate(state, areaIdx, candidateBucket, rejectBadFlow))
        {
            exhausted = true;
            break;
        }

        sliceInspected++;
        state.inspected++;
        bool usedExpensive;
        SpawnScoreDbg candDbg;
        bool accepted = SpawnCore_EvaluateNavCandidate(
            state.zc, state.targetSurvivor,
            state.targetPoint, state.minRange,
            state.maxRange, state.teleportMode,
            areaIdx, candidateBucket, rejectBadFlow,
            state.mapMaxFlowDist, state.finaleArea,
            state.center, state.sectors,
            state.allMaxZ, state.centerBucket,
            state.positionCheckBucket, state.refEyeZ,
            state.lowestFootZ, state.hasLowestFootZ,
            state.navStart, state.visibilityRayMode,
            state.minScore, GetGameTime(), candDbg,
            state.stats, usedExpensive);
        if (usedExpensive)
            sliceExpensive++;
        if (!accepted)
            continue;

        state.acceptedHits++;
        if (!state.found || candDbg.total > state.bestScore)
        {
            state.found = true;
            state.bestScore = candDbg.total;
            SpawnScore_CopyDbg(state.bestDbg, candDbg);
        }
        if (state.firstFit && candDbg.total >= state.firstFitScore)
            break;
    }

    float sliceMs = (GetEngineTime() - sliceStart) * 1000.0;
    state.elapsedMs += sliceMs;
    SpawnPerf_RecordSlice(sliceMs);
    bool complete = exhausted
        || state.acceptedHits >= state.candidateBudget
        || (state.firstFit && state.found
            && state.bestScore >= state.firstFitScore);
    return SpawnSearch_Finish(state, complete, outPos, outAreaIdx, dbgOut);
}

SpawnSearchResult FindSpawnPosViaNavAreaStep(
    int zc, int targetSurvivor, float minRange, float maxRange, bool teleportMode,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return SpawnSearch_Exhausted;

    if (teleportMode)
    {
        return FindSpawnPosViaNavAreaStepForState(
            g_TeleportSpawnSearchStates[idx], zc, targetSurvivor,
            minRange, maxRange, true, outPos, outAreaIdx, dbgOut);
    }

    return FindSpawnPosViaNavAreaStepForState(
        g_NormalSpawnSearchStates[idx], zc, targetSurvivor,
        minRange, maxRange, false, outPos, outAreaIdx, dbgOut);
}

// 计算到任意幸存者“眼睛”的最小距离，用于刷出硬下限判定。
float GetMinEyeDistSquaredToAnySurvivor(const float pos[3])
{
    float best = 1.0e20;
    int snapshotCount = Visibility_GetEyeSnapshotCount();
    if (snapshotCount > 0)
    {
        for (int slot = 0; slot < snapshotCount; slot++)
        {
            int client;
            float eyes[3], viewDir[2];
            if (!Visibility_GetEyeSnapshot(slot, client, eyes, viewDir))
                continue;
            float distanceSq = GetVectorDistance(pos, eyes, true);
            if (distanceSq < best)
                best = distanceSq;
        }
        return best;
    }

    float eyes[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientEyePosition(i, eyes);
        float distanceSq = GetVectorDistance(pos, eyes, true);
        if (distanceSq < best)
            best = distanceSq;
    }
    return best;
}

stock float GetMinEyeDistToAnySurvivor(const float pos[3])
{
    return SquareRoot(GetMinEyeDistSquaredToAnySurvivor(pos));
}
