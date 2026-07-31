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
    if (g_bSpawnAccel)
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

static SpawnSearchState g_SpawnSearch;

void SpawnSearch_Reset()
{
    g_SpawnSearch.active = false;
    g_SpawnSearch.source = SpawnCandidate_None;
    g_SpawnSearch.allRow = 0;
    g_SpawnSearch.bucketOrderLen = 0;
    g_SpawnSearch.bucketOrderIdx = 0;
    g_SpawnSearch.bucketRow = 0;
    g_SpawnSearch.navStart = Address_Null;
    g_SpawnSearch.acceptedHits = 0;
    g_SpawnSearch.inspected = 0;
    g_SpawnSearch.found = false;
    g_SpawnSearch.bestScore = -1.0e9;
    g_SpawnSearch.elapsedMs = 0.0;
    g_SpawnSearch.stats.Reset();
}

static bool SpawnSearch_Matches(int zc, int targetSurvivor, float minRange,
                                float maxRange, bool teleportMode)
{
    if (!g_SpawnSearch.active || g_SpawnSearch.zc != zc
        || g_SpawnSearch.targetSurvivor != targetSurvivor
        || g_SpawnSearch.minRange != minRange || g_SpawnSearch.maxRange != maxRange
        || g_SpawnSearch.teleportMode != teleportMode)
    {
        return false;
    }

    int userid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    return userid == g_SpawnSearch.targetUserid;
}

static bool SpawnSearch_Begin(int zc, int targetSurvivor, float minRange,
                              float maxRange, bool teleportMode)
{
    SpawnSearch_Reset();
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

    g_SpawnSearch.zc = zc;
    g_SpawnSearch.targetSurvivor = targetSurvivor;
    g_SpawnSearch.targetUserid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    g_SpawnSearch.minRange = minRange;
    g_SpawnSearch.maxRange = maxRange;
    g_SpawnSearch.teleportMode = teleportMode;
    g_SpawnSearch.mapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    g_SpawnSearch.finaleArea = L4D_IsMissionFinalMap()
        && L4D2_GetCurrentFinaleStage() < FINALE_STAGE_ESCAPE;
    GetSectorCenter(g_SpawnSearch.center, targetSurvivor);
    g_SpawnSearch.sectors = GetCurrentSectors();

    g_SpawnSearch.allMaxZ = -1.0e9;
    SurPosData data;
    for (int i = 0; i < g_iSurPosDataLen; i++)
    {
        g_aSurPosData.GetArray(i, data);
        if (data.fPos[2] > g_SpawnSearch.allMaxZ)
            g_SpawnSearch.allMaxZ = data.fPos[2];
    }

    g_SpawnSearch.positionCheckBucket = -1;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        TryGetClientFlowPercentSafe(targetSurvivor, g_SpawnSearch.positionCheckBucket);
    }
    if (g_SpawnSearch.positionCheckBucket < 0)
    {
        float bestFlow = -1.0;
        for (int i = 0; i < g_iSurPosDataLen; i++)
        {
            g_aSurPosData.GetArray(i, data);
            if (data.fFlow > bestFlow)
                bestFlow = data.fFlow;
        }
        if (bestFlow >= 0.0)
            g_SpawnSearch.positionCheckBucket = FlowDistanceToPercent(bestFlow);
    }
    g_SpawnSearch.centerBucket = (g_SpawnSearch.positionCheckBucket >= 0)
        ? g_SpawnSearch.positionCheckBucket : 50;

    SpawnCore_CopyPos(g_SpawnSearch.targetPoint, g_SpawnSearch.center);
    g_SpawnSearch.refEyeZ = g_SpawnSearch.allMaxZ;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        GetClientEyePosition(targetSurvivor, g_SpawnSearch.targetPoint);
        g_SpawnSearch.refEyeZ = g_SpawnSearch.targetPoint[2];
    }
    g_SpawnSearch.hasLowestFootZ = TryGetLowestSurvivorFootZ(g_SpawnSearch.lowestFootZ);

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
        g_SpawnSearch.navStart = L4D2Direct_GetTerrorNavArea(survivorPos);
        if (g_SpawnSearch.navStart == Address_Null)
        {
            g_SpawnSearch.navStart = L4D_GetNearestNavArea(
                survivorPos, 120.0, false, false, false, TEAM_INFECTED);
        }
    }
    if (g_SpawnSearch.navStart == Address_Null)
    {
        SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
        return false;
    }

    if (gCV.bNavBucketEnable && g_BucketsReady)
    {
        g_SpawnSearch.source = SpawnCandidate_Buckets;
        int win = ClampInt(ComputeDynamicBucketWindow(maxRange), 0, 100);
        if (SpawnPerfConfig_UseAdaptiveBucketWindow())
            win = ClampInt(ComputeAdaptiveBucketWindow(maxRange, win), 0, 100);
        g_SpawnSearch.bucketOrderLen = SpawnPerfConfig_UseProgressiveSampling()
            ? BuildOptimizedBucketOrder(g_SpawnSearch.centerBucket, win,
                gCV.bNavBucketIncludeCtr, g_SpawnSearch.bucketOrder)
            : BuildBucketOrder(g_SpawnSearch.centerBucket, win,
                gCV.bNavBucketIncludeCtr, g_SpawnSearch.bucketOrder);
    }
    else
    {
        g_SpawnSearch.source = SpawnCandidate_All;
    }

    g_SpawnSearch.candidateBudget = DifficultyStrategy_GetCandidateBudget();
    g_SpawnSearch.visibilityRayMode = GetEffectiveVisibilityRayMode();
    g_SpawnSearch.firstFit = gCV.bNavBucketFirstFit;
    g_SpawnSearch.minScore = gCV.fSpawnScoreFloor;
    g_SpawnSearch.firstFitScore = FloatMax(
        ComputeFFThreshold(), g_SpawnSearch.minScore);
    g_SpawnSearch.active = true;
    SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
    return true;
}

static bool SpawnSearch_NextCandidate(int &areaIdx, int &candidateBucket,
                                      bool &rejectBadFlow)
{
    candidateBucket = -1;
    rejectBadFlow = false;
    if (g_SpawnSearch.source == SpawnCandidate_Buckets)
    {
        while (g_SpawnSearch.bucketOrderIdx < g_SpawnSearch.bucketOrderLen)
        {
            int bucketIdx = g_SpawnSearch.bucketOrder[g_SpawnSearch.bucketOrderIdx];
            if (bucketIdx < 0 || bucketIdx >= FLOW_BUCKETS
                || g_FlowBuckets[bucketIdx] == null
                || g_SpawnSearch.bucketRow >= g_FlowBuckets[bucketIdx].Length)
            {
                g_SpawnSearch.bucketOrderIdx++;
                g_SpawnSearch.bucketRow = 0;
                continue;
            }
            areaIdx = g_FlowBuckets[bucketIdx].Get(g_SpawnSearch.bucketRow++);
            candidateBucket = bucketIdx;
            return true;
        }
        return false;
    }

    if (g_SpawnSearch.source == SpawnCandidate_All
        && g_SpawnSearch.allRow < g_NavAreasCacheCount)
    {
        areaIdx = g_SpawnSearch.allRow++;
        rejectBadFlow = true;
        return true;
    }
    return false;
}

static SpawnSearchResult SpawnSearch_Finish(bool exhausted, float outPos[3],
                                            int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    if (!exhausted)
        return SpawnSearch_Pending;

    if (g_SpawnSearch.found)
    {
        SpawnScore_CopyDbg(dbgOut, g_SpawnSearch.bestDbg);
        SpawnCore_CopyPos(outPos, g_SpawnSearch.bestDbg.pos);
        outAreaIdx = g_SpawnSearch.bestDbg.areaIdx;
        SpawnPerf_RecordAttempt(g_SpawnSearch.elapsedMs, true);
        SpawnSearch_Reset();
        return SpawnSearch_Found;
    }
    Debug_Print("[FIND FAIL] range=%.1f..%.1f inspected=%d. Filters: cd=%d,flag=%d,flow=%d,dist=%d,sep=%d,stuck=%d,vis=%d,path=%d,pos=%d,score=%d,bkt=%d",
                g_SpawnSearch.minRange, g_SpawnSearch.maxRange, g_SpawnSearch.inspected,
                g_SpawnSearch.stats.cooldown, g_SpawnSearch.stats.flags,
                g_SpawnSearch.stats.flow, g_SpawnSearch.stats.distance,
                g_SpawnSearch.stats.separation, g_SpawnSearch.stats.stuck,
                g_SpawnSearch.stats.visibility, g_SpawnSearch.stats.path,
                g_SpawnSearch.stats.position, g_SpawnSearch.stats.score,
                g_SpawnSearch.stats.bucket);
    SpawnPerf_RecordAttempt(g_SpawnSearch.elapsedMs, false);
    SpawnSearch_Reset();
    return SpawnSearch_Exhausted;
}

SpawnSearchResult FindSpawnPosViaNavAreaStep(
    int zc, int targetSurvivor, float minRange, float maxRange, bool teleportMode,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    outAreaIdx = -1;
    if (!SpawnSearch_Matches(zc, targetSurvivor, minRange, maxRange, teleportMode))
    {
        if (!SpawnSearch_Begin(zc, targetSurvivor, minRange, maxRange, teleportMode))
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
        && g_SpawnSearch.acceptedHits < g_SpawnSearch.candidateBudget
        && (GetEngineTime() - sliceStart) * 1000.0 < NAV_SCAN_TIME_BUDGET_MS)
    {
        int areaIdx;
        int candidateBucket;
        bool rejectBadFlow;
        if (!SpawnSearch_NextCandidate(areaIdx, candidateBucket, rejectBadFlow))
        {
            exhausted = true;
            break;
        }

        sliceInspected++;
        g_SpawnSearch.inspected++;
        bool usedExpensive;
        SpawnScoreDbg candDbg;
        bool accepted = SpawnCore_EvaluateNavCandidate(
            g_SpawnSearch.zc, g_SpawnSearch.targetSurvivor,
            g_SpawnSearch.targetPoint, g_SpawnSearch.minRange,
            g_SpawnSearch.maxRange, g_SpawnSearch.teleportMode,
            areaIdx, candidateBucket, rejectBadFlow,
            g_SpawnSearch.mapMaxFlowDist, g_SpawnSearch.finaleArea,
            g_SpawnSearch.center, g_SpawnSearch.sectors,
            g_SpawnSearch.allMaxZ, g_SpawnSearch.centerBucket,
            g_SpawnSearch.positionCheckBucket, g_SpawnSearch.refEyeZ,
            g_SpawnSearch.lowestFootZ, g_SpawnSearch.hasLowestFootZ,
            g_SpawnSearch.navStart, g_SpawnSearch.visibilityRayMode,
            g_SpawnSearch.minScore, GetGameTime(), candDbg,
            g_SpawnSearch.stats, usedExpensive);
        if (usedExpensive)
            sliceExpensive++;
        if (!accepted)
            continue;

        g_SpawnSearch.acceptedHits++;
        if (!g_SpawnSearch.found || candDbg.total > g_SpawnSearch.bestScore)
        {
            g_SpawnSearch.found = true;
            g_SpawnSearch.bestScore = candDbg.total;
            SpawnScore_CopyDbg(g_SpawnSearch.bestDbg, candDbg);
        }
        if (g_SpawnSearch.firstFit && candDbg.total >= g_SpawnSearch.firstFitScore)
            break;
    }

    float sliceMs = (GetEngineTime() - sliceStart) * 1000.0;
    g_SpawnSearch.elapsedMs += sliceMs;
    SpawnPerf_RecordSlice(sliceMs);
    bool complete = exhausted
        || g_SpawnSearch.acceptedHits >= g_SpawnSearch.candidateBudget
        || (g_SpawnSearch.firstFit && g_SpawnSearch.found
            && g_SpawnSearch.bestScore >= g_SpawnSearch.firstFitScore);
    return SpawnSearch_Finish(complete, outPos, outAreaIdx, dbgOut);
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
