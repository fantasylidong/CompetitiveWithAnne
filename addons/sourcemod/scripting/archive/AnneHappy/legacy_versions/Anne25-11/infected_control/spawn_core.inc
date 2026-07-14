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
    int navarea_vis;  // NavArea 级别可见性过滤
    int pvs_skip;     // PVS 已确认不可见，跳过昂贵点位可见性精判
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
                                           float searchRange,
                                           bool teleportMode,
                                           int areaIdx,
                                           int knownBucket,
                                           bool rejectBadFlow,
                                           float mapMaxFlowDist,
                                           bool finaleArea,
                                           const float center[3],
                                           int sectors,
                                           int preferredSector,
                                           float allMinZ,
                                           float allMaxZ,
                                           int centerBucket,
                                           float refEyeZ,
                                           float minScore,
                                           SpawnScoreDbg candDbg,
                                           SpawnFilterStats stats)
{
    // 0) 防御性检查：areaIdx 必须先验证，避免无效 index 进入 NavArea native。
    if (areaIdx < 0 || areaIdx >= g_NavAreasCacheCount)
    {
        stats.position++;
        return false;
    }

    Address areaAddr = g_AllNavAreasCache.Get(areaIdx);
    NavArea area = view_as<NavArea>(areaAddr);

    if (!area)
    {
        stats.position++;
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
            return false;
        }

        if (candidateBucket < 0)
            candidateBucket = FlowDistanceToPercent(flow);
    }
    candidateBucket = ClampInt(candidateBucket, 0, 100);

    // 3) 冷却和同桶上限都是区域/桶级判断，放在 GetRandomPoint 之前节省点位级成本。
    if (IsNavOnCooldown(areaIdx, GetGameTime()))
    {
        stats.cooldown++;
        return false;
    }

    if (!PassBucketShareLimit(candidateBucket))
    {
        stats.bucket++;
        SpawnPerf_RecordFilterByBucket();
        return false;
    }

    // NavArea 级别完全可见初筛：整块区域暴露时直接跳过，再进入点位级检测。
    if (IsNavAreaVisibleToSurvivors(areaAddr, teleportMode))
    {
        stats.navarea_vis++;
        LeftDHooks_PVS_RecordNavAreaFilter();
        return false;
    }

    // 4) 从这里开始才进入点位级成本。GetRandomPoint 会调用 leftdhooks 随机 Nav 点。
    float pos[3];
    area.GetRandomPoint(pos);

    // 5) 最近刷点分散是纯内存距离检查，比距离/trace/path 都便宜。
    if (!PassMinSeparation(pos))
    {
        stats.separation++;
        return false;
    }

    // 6) 高度 slack 会放宽 ring，但只用于非 Charger/Jockey，避免这些类刷得过远。
    float bucketMinZ = g_BucketMinZ[candidateBucket];
    float bucketMaxZ = g_BucketMaxZ[candidateBucket];
    if (bucketMaxZ <= bucketMinZ)
    {
        bucketMinZ = allMinZ - 50.0;
        bucketMaxZ = allMaxZ + 50.0;
    }

    float slack = 0.0;
    if (zc != view_as<int>(SI_Charger) && zc != view_as<int>(SI_Jockey))
        slack = HeightRingSlack(pos, bucketMinZ, bucketMaxZ, allMaxZ);

    float ringEff = FloatMin(searchRange + slack, gCV.fSpawnMax);

    // 7) 距离检查分两层：可选快速包围盒预筛，然后精确 eye distance。
    if (!SpawnCore_QuickDistancePrecheckAnySurvivor(pos, ringEff))
    {
        stats.distance++;
        SpawnPerf_RecordFilterByDist();
        return false;
    }

    float dminEye = GetMinEyeDistToAnySurvivor(pos);

    if (!(dminEye >= gCV.fSpawnMin && dminEye <= ringEff))
    {
        stats.distance++;
        SpawnPerf_RecordFilterByDist();
        return false;
    }
    // 8) 使用已知 candidateBucket 做真实位置检查，避免 GetPositionBucketPercent(pos) 再查 Nav。
    if (!PassRealBucketPositionCheck(candidateBucket, pos[2], targetSurvivor, zc))
    {
        stats.position++;
        return false;
    }
    // 9) 卡壳、可见性、路径都是昂贵检查，必须排在轻量过滤之后。
    if (WillStuck(pos))
    {
        stats.stuck++;
        return false;
    }
    // PVS 只能证明“不在任何生还者潜在可见集合内”，命中时跳过旧 trace；
    // 如果仍在 PVS 内，必须继续跑 IsPosVisibleSDK 精判。
    if (!IsPointInAnySurvivorPVS(pos))
    {
        stats.pvs_skip++;
        LeftDHooks_PVS_RecordPointTraceSkipped();
    }
    else if (IsPosVisibleSDK(pos, teleportMode))
    {
        stats.visibility++;
        SpawnPerf_RecordFilterByVisibility();
        return false;
    }
    // 候选 NavArea 已知，传给 path 检查可避免对 candPos 再做一次 L4D_GetNearestNavArea。
    if (PathPenalty_NoBuildFromArea(pos, areaAddr, targetSurvivor, searchRange, gCV.fSpawnMax) != 0.0)
    {
        stats.path++;
        return false;
    }

    // 10) 只有通过所有硬过滤的候选才需要 rawBadFlow 和评分。
    //     这能让桶模式下大量失败候选完全不读 area.GetFlow()。
    if (!flowLoaded)
    {
        flow = area.GetFlow();
        flowLoaded = true;
        rawBadFlow = IsFlowAbnormal(flow, mapMaxFlowDist);
    }

    int sector = ComputeSectorIndex(center, pos, sectors);
    SpawnPerf_RecordFullEvaluation();
    if (!SpawnScore_BuildCandidate(zc, pos, dminEye, ringEff, slack,
                                   candidateBucket, centerBucket, rawBadFlow,
                                   refEyeZ, allMaxZ, sector, preferredSector,
                                   areaIdx, candDbg))
    {
        stats.flow++;
        return false;
    }

    if (candDbg.total < minScore)
    {
        stats.score++;
        return false;
    }

    return true;
}

static bool SpawnCore_QuickDistancePrecheckAnySurvivor(const float pos[3], float maxDist)
{
    if (!SpawnPerfConfig_UseEarlyDistanceFilter())
        return true;

    float surPos[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientAbsOrigin(i, surPos);
        if (QuickDistancePrecheck(pos, surPos, 0.0, maxDist))
            return true;
    }
    return false;
}

bool FindSpawnPosViaNavArea(int zc, int targetSurvivor, float searchRange, bool teleportMode,
                            float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    float perfStart = GetEngineTime();

    // 生还者 Flow/位置缓存是整个刷点决策的基准。拿不到数据时不猜点，避免刷到离谱位置。
    if (!GetSurPosData())
    {
        Debug_Print("[FIND FAIL] no survivor data");
        SpawnPerf_RecordAttempt((GetEngineTime() - perfStart) * 1000.0, false);
        return false;
    }

    EnsureNavAreasCache();
    int areaCount = g_NavAreasCacheCount;

    float mapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    bool finaleArea = L4D_IsMissionFinalMap() && L4D2_GetCurrentFinaleStage() < FINALE_STAGE_ESCAPE;

    // 扇区中心用于“分散度”评分：同一波/最近几次不要总从同一个方向刷。
    float center[3];
    GetSectorCenter(center, targetSurvivor);
    int sectors = GetCurrentSectors();
    int preferredSector = PickSector(sectors);

    float allMinZ = 1.0e9;
    float allMaxZ = -1.0e9;
    SurPosData data;
    for (int i = 0; i < g_iSurPosDataLen; i++)
    {
        g_aSurPosData.GetArray(i, data);
        if (data.fPos[2] < allMinZ) allMinZ = data.fPos[2];
        if (data.fPos[2] > allMaxZ) allMaxZ = data.fPos[2];
    }

    // centerBucket 是本轮扫描窗口中心。优先用目标生还者，目标无效时退到最高 Flow 生还者。
    int centerBucket = 50;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor) && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        int pct;
        if (TryGetClientFlowPercentSafe(targetSurvivor, pct))
            centerBucket = pct;
    }
    else
    {
        float bestFlow = -1.0;
        SurPosData fallbackData;
        for (int i = 0; i < g_iSurPosDataLen; i++)
        {
            g_aSurPosData.GetArray(i, fallbackData);
            if (fallbackData.fFlow > bestFlow) bestFlow = fallbackData.fFlow;
        }
        if (bestFlow >= 0.0)
            centerBucket = FlowDistanceToPercent(bestFlow);
    }

    float refEyeZ = allMaxZ;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor) && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        float eye[3];
        GetClientEyePosition(targetSurvivor, eye);
        refEyeZ = eye[2];
    }

    bool found = false;
    float bestScore = -1.0e9;
    int acceptedHits = 0;

    bool useBuckets = (gCV.bNavBucketEnable && g_BucketsReady);
    bool firstFit = gCV.bNavBucketFirstFit;
    float minScore = gCV.fSpawnScoreFloor;
    float firstFitScore = FloatMax(ComputeFFThresholdForClass(zc), minScore);
    // 候选预算表示“通过硬过滤并进入评分的候选数量”，不是扫描的 NavArea 数量。
    // 默认基础 12，再由 AI 难度 bonus 调成 9/10/11/12/12。
    int candidateBudget = DifficultyStrategy_GetCandidateBudget();

    SpawnScoreDbg bestDbg;
    SpawnFilterStats stats;

    if (useBuckets)
    {
        // 桶模式是主路径：只扫描 centerBucket 附近的 Flow 桶，极大减少 NavArea 数量。
        int win = ClampInt(ComputeDynamicBucketWindow(searchRange), 0, 100);
        if (SpawnPerfConfig_UseAdaptiveBucketWindow())
            win = ClampInt(ComputeAdaptiveBucketWindow(searchRange, win), 0, 100);

        int order[FLOW_BUCKETS];
        int orderLen = SpawnPerfConfig_UseProgressiveSampling()
            ? BuildOptimizedBucketOrder(centerBucket, win, gCV.bNavBucketIncludeCtr, order)
            : BuildBucketOrder(centerBucket, win, gCV.bNavBucketIncludeCtr, order);

        for (int orderIdx = 0; orderIdx < orderLen; orderIdx++)
        {
            int bucketIdx = order[orderIdx];
            if (bucketIdx < 0 || bucketIdx > 100 || g_FlowBuckets[bucketIdx] == null)
                continue;

            int bucketLen = g_FlowBuckets[bucketIdx].Length;
            if (bucketLen <= 0)
                continue;

            for (int row = 0; row < bucketLen && acceptedHits < candidateBudget; row++)
            {
                int areaIdx = g_FlowBuckets[bucketIdx].Get(row);
                SpawnScoreDbg candDbg;
                if (!SpawnCore_EvaluateNavCandidate(zc, targetSurvivor, searchRange, teleportMode,
                                                     areaIdx, bucketIdx, false,
                                                     mapMaxFlowDist, finaleArea, center,
                                                     sectors, preferredSector, allMinZ, allMaxZ,
                                                     centerBucket, refEyeZ, minScore,
                                                     candDbg, stats))
                {
                    continue;
                }

                acceptedHits++;

                if (firstFit && candDbg.total >= firstFitScore)
                {
                    SpawnScore_CopyDbg(dbgOut, candDbg);
                    SpawnCore_CopyPos(outPos, candDbg.pos);
                    outAreaIdx = areaIdx;
                    SpawnPerf_RecordAttempt((GetEngineTime() - perfStart) * 1000.0, true);
                    return true;
                }

                if (!found || candDbg.total > bestScore)
                {
                    found = true;
                    bestScore = candDbg.total;
                    SpawnScore_CopyDbg(bestDbg, candDbg);
                }
            }
            if (acceptedHits >= candidateBudget)
                break;
        }
    }
    else
    {
        // 全图模式是 fallback/debug 路径：更保守，会拒绝 badflow，成本也更高。
        for (int areaIdx = 0; areaIdx < areaCount && acceptedHits < candidateBudget; areaIdx++)
        {
            SpawnScoreDbg candDbg;
            if (!SpawnCore_EvaluateNavCandidate(zc, targetSurvivor, searchRange, teleportMode,
                                                 areaIdx, -1, true,
                                                 mapMaxFlowDist, finaleArea, center,
                                                 sectors, preferredSector, allMinZ, allMaxZ,
                                                 centerBucket, refEyeZ, minScore,
                                                 candDbg, stats))
            {
                continue;
            }

            acceptedHits++;

            if (firstFit && candDbg.total >= firstFitScore)
            {
                SpawnScore_CopyDbg(dbgOut, candDbg);
                SpawnCore_CopyPos(outPos, candDbg.pos);
                outAreaIdx = areaIdx;
                SpawnPerf_RecordAttempt((GetEngineTime() - perfStart) * 1000.0, true);
                return true;
            }

            if (!found || candDbg.total > bestScore)
            {
                found = true;
                bestScore = candDbg.total;
                SpawnScore_CopyDbg(bestDbg, candDbg);
            }
        }
    }

    if (!found)
    {
        Debug_Print("[FIND FAIL] ring=%.1f. Filters: cd=%d,flag=%d,flow=%d,dist=%d,sep=%d,stuck=%d,vis=%d,path=%d,pos=%d,score=%d,bkt=%d,navvis=%d,pvsskip=%d",
                    searchRange, stats.cooldown, stats.flags, stats.flow, stats.distance, stats.separation,
                    stats.stuck, stats.visibility, stats.path, stats.position, stats.score, stats.bucket,
                    stats.navarea_vis, stats.pvs_skip);
        SpawnPerf_RecordAttempt((GetEngineTime() - perfStart) * 1000.0, false);
        return false;
    }

    SpawnScore_CopyDbg(dbgOut, bestDbg);
    SpawnCore_CopyPos(outPos, bestDbg.pos);
    outAreaIdx = bestDbg.areaIdx;
    SpawnPerf_RecordAttempt((GetEngineTime() - perfStart) * 1000.0, true);
    return true;
}

// 计算到任意幸存者“眼睛”的最小距离，用于刷出硬下限判定。
float GetMinEyeDistToAnySurvivor(const float pos[3])
{
    float best = 999999.0;
    float eyes[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientEyePosition(i, eyes);
        float distance = GetVectorDistance(pos, eyes);
        if (distance < best)
            best = distance;
    }
    return best;
}
