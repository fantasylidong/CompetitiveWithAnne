#if defined _infected_control_spawn_core_included
    #endinput
#endif
#define _infected_control_spawn_core_included

enum struct SpawnFilterStats
{
    int cooldown;
    int pendingSameNav;
    int flags;
    int flow;
    int distance;
    int separation;
    int pendingSeparation;
    int stuck;
    int visibility;
    int path;
    int position;
    int score;
    int bucket;

    void Reset()
    {
        this.cooldown = 0;
        this.pendingSameNav = 0;
        this.flags = 0;
        this.flow = 0;
        this.distance = 0;
        this.separation = 0;
        this.pendingSeparation = 0;
        this.stuck = 0;
        this.visibility = 0;
        this.path = 0;
        this.position = 0;
        this.score = 0;
        this.bucket = 0;
    }
}

// 刷点核心分两层：
// - FindSpawnPosViaNavArea：准备生还者/Flow/扇区上下文，决定有向图候选或全图兜底。
// - SpawnCore_EvaluateNavCandidate：评估单个 NavArea，按“便宜过滤 -> 昂贵精判 -> 评分”的顺序执行。
//
// 修改性能或刷点质量时优先阅读 README_SPAWN_ARCHITECTURE.md。这里的过滤顺序不是随意排列：
// 先做 area/flags/progress/cooldown 这类区域级轻量判断，再取随机点，再做距离/stuck/visibility/path。
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
                                           float navDistance,
                                           int knownBucket,
                                           bool rejectBadFlow,
                                           float mapMaxFlowDist,
                                           bool finaleArea,
                                           const float center[3],
                                           int sectors,
                                           float allMaxZ,
                                           int centerBucket,
                                           float refEyeZ,
                                           float lowestFootZ,
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

    // 2) 图候选已携带 areaIdx 对应的进度 bucket，避免每个候选都读取 Flow。
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
    float directExclusion = FloatMax(
        NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin);
    if (teleportMode)
        directExclusion = FloatMax(directExclusion, gCV.fTeleportSpawnMin);
        float requestExclusion = directExclusion + NAV_CANDIDATE_LANDING_MARGIN;
        float directExclusionSq = requestExclusion * requestExclusion;
    bool haveCheapCandidate = false;
    bool geometryReady = false;
    float dTargetEye = 0.0;
    float navDistanceEffective = navDistance;
    float navHighGroundComp = 0.0;
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

        bool pendingSameNav;
        if (!PassPendingSpawnSeparation(areaIdx, pos, pendingSameNav))
        {
            if (pendingSameNav)
            {
                stats.pendingSameNav++;
                SpawnPerf_RecordFilterByPendingSameNav();
            }
            else
            {
                stats.pendingSeparation++;
                SpawnPerf_RecordFilterByPendingSeparation();
            }
            continue;
        }

        // 6) 当前职业范围是硬边界；Smoker/Hunter 的正高度差只折减 Nav
        //    上限判定，原始距离和全队三维安全距离保持不变。
        geometryReady = g_bSpawnAccel
            && AnneSpawn_ComputePointGeometry(pos, center, sectors, targetEye,
                                               dminEyeSq, dTargetEye, sector);
        if (!geometryReady)
        {
            dminEyeSq = GetMinEyeDistSquaredToAnySurvivor(pos);
            dTargetEye = GetVectorDistance(pos, targetEye);
        }
        navHighGroundComp = Tactical_GetHighGroundNavCompensation(
            zc, pos[2], targetEye[2]);
        navDistanceEffective = navDistance >= 0.0
            ? FloatMax(minRange, navDistance - navHighGroundComp)
            : -1.0;
        // 无完整图时 direct 只作为路径上限的下界：直线都超上限可直接拒绝；
        // 最小/最大职业路径边界稍后在同一帧用 candidate -> survivor BuildPath 精判。
        float fallbackPathMax = ringEff + navHighGroundComp
            + NAV_CANDIDATE_RANGE_SLACK;
        bool outsideRange = navDistance >= 0.0
            ? (navDistance < minRange || navDistanceEffective > ringEff)
            : (dTargetEye > fallbackPathMax);
        if (dminEyeSq < directExclusionSq || outsideRange)
        {
            stats.distance++;
            SpawnPerf_RecordFilterByDist();
            continue;
        }

        haveCheapCandidate = true;
        break;
    }

    if (!haveCheapCandidate)
        return false;

    // 7) 有向图已经按 candidate -> survivor 路径距离筛出连通候选。
    //    Flow 只参与后续评分，不再以旧的进度桶阈值二次否决候选。
    //    卡壳、可见性、路径都是昂贵检查，必须排在轻量过滤之后。
    usedExpensive = true;
    AnneSpawnSafetyResult safety = Visibility_TestPointSafety(
        pos, teleportMode, visibilityRayMode);

    if (safety == AnneSpawnSafety_Stuck)
    {
        stats.stuck++;
        SpawnPerf_RecordFilterByStuck();
        return false;
    }
    if (safety == AnneSpawnSafety_Visible)
    {
        stats.visibility++;
        SpawnPerf_RecordFilterByVisibility();
        return false;
    }
    if (IsPredictedSpawnLandingVisible(pos, teleportMode, visibilityRayMode))
    {
        stats.visibility++;
        SpawnPerf_RecordFilterByVisibility();
        return false;
    }
    if (IsPredictedSpawnLandingInHurtTrigger(pos))
    {
        stats.position++;
        SpawnPerf_RecordFilterByPosition();
        return false;
    }
    float minPathRange = navDistance < 0.0 && dTargetEye < minRange
        ? minRange : 0.0;
    if (PathPenalty_NoBuildFromStart(
            pos, navStart, searchRange + navHighGroundComp,
            gCV.fSpawnMax, minPathRange) != 0.0)
    {
        stats.path++;
        SpawnPerf_RecordFilterByPath();
        return false;
    }

    // 8) 只有通过所有硬过滤的候选才需要 rawBadFlow 和评分。
    //     这能让图候选路径中大量失败候选完全不读 area.GetFlow()。
    if (!flowLoaded)
    {
        flow = area.GetFlow();
        flowLoaded = true;
        rawBadFlow = IsFlowAbnormal(flow, mapMaxFlowDist);
    }

    if (!geometryReady)
    {
        sector = ComputeSectorIndex(center, pos, sectors);
    }
    float tacticalQuality = Tactical_GetCandidateQuality(
        zc, pos, targetSurvivor, targetPoint);
    SpawnPerf_RecordFullEvaluation();
    float navWeight = 1.0;
    float scoreMinRange = minRange;
    float scoreMaxRange = ringEff;
    if (!SpawnScore_BuildCandidate(
                                   zc, pos, dTargetEye, navDistance,
                                   navDistanceEffective, navHighGroundComp,
                                   scoreMinRange, scoreMaxRange, slack,
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
    SpawnCandidate_Graph,
    SpawnCandidate_All
}

enum SpawnCandidateReadResult
{
    SpawnCandidateRead_Pending = 0,
    SpawnCandidateRead_Found,
    SpawnCandidateRead_Exhausted
}

// 评估上下文每次调用都从当前 tick 重建。候选点、目标位置、路径起点和评分
// 不得跨帧保存，否则会把旧 Flow/Nav 上下文和新眼位快照混在一次判定中。
enum struct SpawnFrameContext
{
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
    Address navStart;
    int navStartClient;
    int navStartId;
    int visibilityRayMode;
    int candidateBudget;
    bool firstFit;
    float minScore;
    float firstFitScore;
}

// 跨 tick 只保留候选源游标和诊断计数。一个候选从安全检查到评分、刷出
// 必须在同一 tick 完成，不保存历史 best candidate。
enum struct SpawnSearchCursor
{
    bool active;
    int zc;
    int targetSurvivor;
    int targetUserid;
    float minRange;
    float maxRange;
    float graphScanMinRange;
    bool teleportMode;
    SpawnCandidateSource source;
    int allRow;
    int graphTargetClient;
    int graphTargetNavId;
    float graphPathLimit;
    float graphMinNavDistance;
    float graphMaxNavDistance;
    int graphOffset;
    int graphTotalInRange;
    int graphPage[NAV_CANDIDATE_PAGE_SIZE];
    float graphPageNavDistance[NAV_CANDIDATE_PAGE_SIZE];
    int graphPageLen;
    int graphPageRow;
    float graphPageExpiresAt;
    int inspected;
    float elapsedMs;
    SpawnFilterStats stats;
}

static SpawnSearchCursor g_NormalSpawnSearchCursors[SI_COUNT];
static SpawnSearchCursor g_TeleportSpawnSearchCursors[SI_COUNT];

static void SpawnSearch_ResetCursor(SpawnSearchCursor cursor)
{
    cursor.active = false;
    cursor.source = SpawnCandidate_None;
    cursor.allRow = 0;
    cursor.graphTargetClient = -1;
    cursor.graphTargetNavId = -1;
    cursor.graphPathLimit = 0.0;
    cursor.graphScanMinRange = 0.0;
    cursor.graphMinNavDistance = 0.0;
    cursor.graphMaxNavDistance = 0.0;
    cursor.graphOffset = 0;
    cursor.graphTotalInRange = -1;
    cursor.graphPageLen = 0;
    cursor.graphPageRow = 0;
    cursor.graphPageExpiresAt = 0.0;
    cursor.inspected = 0;
    cursor.elapsedMs = 0.0;
    cursor.stats.Reset();
}

void SpawnSearch_Reset()
{
    for (int i = 0; i < SI_COUNT; i++)
    {
        SpawnSearch_ResetCursor(g_NormalSpawnSearchCursors[i]);
        SpawnSearch_ResetCursor(g_TeleportSpawnSearchCursors[i]);
    }
}

void SpawnSearch_ResetClass(int zc, bool teleportMode)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    if (teleportMode)
        SpawnSearch_ResetCursor(g_TeleportSpawnSearchCursors[idx]);
    else
        SpawnSearch_ResetCursor(g_NormalSpawnSearchCursors[idx]);
}

static bool SpawnSearch_Matches(SpawnSearchCursor cursor,
                                int zc, int targetSurvivor, float minRange,
                                float maxRange, float graphScanMinRange,
                                bool teleportMode)
{
    if (!cursor.active || cursor.zc != zc
        || cursor.targetSurvivor != targetSurvivor
        || cursor.minRange != minRange || cursor.maxRange != maxRange
        || cursor.graphScanMinRange != graphScanMinRange
        || cursor.teleportMode != teleportMode)
    {
        return false;
    }

    int userid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    return userid == cursor.targetUserid;
}

static bool SpawnSearch_BuildFrameContext(
    int targetSurvivor, SpawnFrameContext frame)
{
    float buildStart = GetEngineTime();
    Visibility_EnsureCurrentEyeSnapshot();
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

    frame.mapMaxFlowDist = L4D2Direct_GetMapMaxFlowDistance();
    frame.finaleArea = L4D_IsMissionFinalMap()
        && L4D2_GetCurrentFinaleStage() < FINALE_STAGE_ESCAPE;
    GetSectorCenter(frame.center, targetSurvivor);
    frame.sectors = GetCurrentSectors();

    frame.allMaxZ = -1.0e9;
    SurPosData data;
    for (int i = 0; i < g_iSurPosDataLen; i++)
    {
        g_aSurPosData.GetArray(i, data);
        if (data.fPos[2] > frame.allMaxZ)
            frame.allMaxZ = data.fPos[2];
    }

    frame.positionCheckBucket = -1;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        TryGetClientFlowPercentSafe(targetSurvivor, frame.positionCheckBucket);
    }
    if (frame.positionCheckBucket < 0)
    {
        float bestFlow = -1.0;
        for (int i = 0; i < g_iSurPosDataLen; i++)
        {
            g_aSurPosData.GetArray(i, data);
            if (data.fFlow > bestFlow)
                bestFlow = data.fFlow;
        }
        if (bestFlow >= 0.0)
            frame.positionCheckBucket = FlowDistanceToPercent(bestFlow);
    }
    frame.centerBucket = (frame.positionCheckBucket >= 0)
        ? frame.positionCheckBucket : 50;

    SpawnCore_CopyPos(frame.targetPoint, frame.center);
    frame.refEyeZ = frame.allMaxZ;
    if (IsValidSurvivor(targetSurvivor) && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor))
    {
        GetClientEyePosition(targetSurvivor, frame.targetPoint);
        frame.refEyeZ = frame.targetPoint[2];

        // 同一 tick 内其他插件可能在本插件抓完快照后传送生还者。图起点已经
        // 使用实时位置，此处同步校验目标眼位，避免路径距离与直线/可视判断
        // 分别基于传送后的 Nav 和传送前的眼位。
        float snapshotTarget[3];
        if (!Visibility_GetClientEyeSnapshot(targetSurvivor, snapshotTarget)
            || GetVectorDistance(snapshotTarget, frame.targetPoint) > 8.0)
        {
            Debug_Print("[VIS SNAPSHOT] target drifted within tick; refreshing target=%d drift=%.1f",
                targetSurvivor,
                Visibility_GetClientEyeSnapshot(targetSurvivor, snapshotTarget)
                    ? GetVectorDistance(snapshotTarget, frame.targetPoint) : -1.0);
            Visibility_RefreshEyeSnapshot();
        }
    }
    if (!TryGetLowestSurvivorFootZ(frame.lowestFootZ))
        frame.lowestFootZ = 1.0e9;

    frame.navStart = Address_Null;
    frame.navStartClient = -1;
    frame.navStartId = -1;
    int pathTarget = targetSurvivor;
    if (!IsValidSurvivor(pathTarget) || !IsPlayerAlive(pathTarget)
        || L4D_IsPlayerIncapacitated(pathTarget))
    {
        pathTarget = (g_iSurCount > 0) ? g_iSurvivors[0] : -1;
    }
    if (IsValidSurvivor(pathTarget) && IsPlayerAlive(pathTarget))
    {
        frame.navStartClient = pathTarget;
        float survivorPos[3];
        GetClientAbsOrigin(pathTarget, survivorPos);
        frame.navStart = L4D2Direct_GetTerrorNavArea(survivorPos);
        if (frame.navStart == Address_Null)
        {
            frame.navStart = L4D_GetNearestNavArea(
                survivorPos, 120.0, false, false, false, TEAM_INFECTED);
        }
    }
    if (frame.navStart == Address_Null)
    {
        SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
        return false;
    }
    frame.navStartId = L4D_GetNavAreaID(frame.navStart);

    frame.candidateBudget = DifficultyStrategy_GetCandidateBudget();
    // 安全检查实现不应改变刷特节奏。统一限制评分样本，同时保留完整 Nav
    // 候选源和跨帧游标；找不到足够样本时仍会继续扫描后续区域。
    if (frame.candidateBudget > NAV_SCAN_SCORE_BUDGET_CAP)
        frame.candidateBudget = NAV_SCAN_SCORE_BUDGET_CAP;
    frame.visibilityRayMode = GetEffectiveVisibilityRayMode();
    frame.firstFit = gCV.bNavBucketFirstFit;
    frame.minScore = gCV.fSpawnScoreFloor;
    frame.firstFitScore = FloatMax(ComputeFFThreshold(), frame.minScore);
    SpawnPerf_RecordCandidateBuild((GetEngineTime() - buildStart) * 1000.0);
    return true;
}

static void SpawnSearch_ConfigureCursor(
    SpawnSearchCursor cursor, int zc, int targetSurvivor,
    float minRange, float maxRange, float graphScanMinRange,
    bool teleportMode,
    int graphTargetClient, int graphTargetNavId)
{
    SpawnSearch_ResetCursor(cursor);
    cursor.zc = zc;
    cursor.targetSurvivor = targetSurvivor;
    cursor.targetUserid = (targetSurvivor >= 1 && targetSurvivor <= MaxClients
        && IsClientInGame(targetSurvivor)) ? GetClientUserId(targetSurvivor) : 0;
    cursor.minRange = minRange;
    cursor.maxRange = maxRange;
    cursor.graphScanMinRange = graphScanMinRange;
    cursor.teleportMode = teleportMode;
    cursor.graphTargetClient = graphTargetClient;
    cursor.graphTargetNavId = graphTargetNavId;
    cursor.graphPathLimit = SpawnAccel_GetCandidatePathLimit();
    cursor.graphMinNavDistance = graphScanMinRange > minRange
        ? graphScanMinRange
        : FloatMax(0.0, minRange - NAV_CANDIDATE_RANGE_SLACK);
    cursor.graphMaxNavDistance = maxRange + NAV_CANDIDATE_RANGE_SLACK
        + Tactical_GetMaxHighGroundNavCompensation(zc);
    cursor.source = (graphTargetClient > 0 && graphTargetNavId > 0
        && SpawnAccel_CanUseGraphCandidates())
        ? SpawnCandidate_Graph : SpawnCandidate_All;
    cursor.active = true;
}

static void SpawnSearch_EnsureCursor(
    SpawnSearchCursor cursor, int zc, int targetSurvivor,
    float minRange, float maxRange, float graphScanMinRange,
    bool teleportMode,
    int graphTargetClient, int graphTargetNavId)
{
    bool matches = SpawnSearch_Matches(
        cursor, zc, targetSurvivor, minRange, maxRange,
        graphScanMinRange, teleportMode);
    SpawnCandidateSource wantedSource = graphTargetClient > 0 && graphTargetNavId > 0
        && SpawnAccel_CanUseGraphCandidates()
        ? SpawnCandidate_Graph : SpawnCandidate_All;
    bool graphTargetMoved = wantedSource == SpawnCandidate_Graph
        && (cursor.graphTargetClient != graphTargetClient
            || cursor.graphTargetNavId != graphTargetNavId);
    if (!matches
        || cursor.source != wantedSource || graphTargetMoved)
    {
        SpawnSearch_ConfigureCursor(
            cursor, zc, targetSurvivor, minRange, maxRange,
            graphScanMinRange, teleportMode,
            graphTargetClient, graphTargetNavId);
    }
}

static SpawnCandidateReadResult SpawnSearch_NextCandidate(
    SpawnSearchCursor cursor, int &areaIdx, int &candidateBucket,
    float &navDistance, bool &rejectBadFlow)
{
    candidateBucket = -1;
    navDistance = -1.0;
    rejectBadFlow = false;
    while (cursor.source != SpawnCandidate_None)
    {
        if (cursor.source == SpawnCandidate_Graph)
        {
            float now = GetGameTime();
            if (cursor.graphPageRow < cursor.graphPageLen
                && now <= cursor.graphPageExpiresAt)
            {
                int pageRow = cursor.graphPageRow++;
                areaIdx = cursor.graphPage[pageRow];
                navDistance = cursor.graphPageNavDistance[pageRow];
                cursor.graphOffset++;
                TryGetBucketByAreaIdx(areaIdx, candidateBucket);
                return SpawnCandidateRead_Found;
            }

            // 未消费页只是一批 areaIdx，不是安全结论；超过 0.2 秒后重新取当前快照。
            cursor.graphPageLen = 0;
            cursor.graphPageRow = 0;
            if (cursor.graphTotalInRange >= 0
                && cursor.graphOffset >= cursor.graphTotalInRange)
            {
                return SpawnCandidateRead_Exhausted;
            }

            int prepareStatus = SpawnAccel_PrepareTargetCandidates(
                cursor.graphTargetClient, NAV_CANDIDATE_RESULT_TTL);
            if (prepareStatus == ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE)
            {
                if (SpawnAccel_IsDynamicGraphPending())
                    return SpawnCandidateRead_Pending;
                g_bSpawnAccelGraphCandidatesAvailable = false;
                cursor.source = SpawnCandidate_All;
                cursor.allRow = 0;
                Debug_Print("[SPAWN ACCEL] directed candidates unavailable during search; using all-Nav fallback");
                continue;
            }
            if (prepareStatus <= 0)
                return SpawnCandidateRead_Pending;

            float resultAgeMs;
            int totalInRange;
            int page[NAV_CANDIDATE_PAGE_SIZE];
            float pageNavDistance[NAV_CANDIDATE_PAGE_SIZE];
            int count = AnneSpawn_NavCandidatesCollect(
                cursor.graphTargetClient,
                cursor.graphTargetNavId,
                cursor.graphMinNavDistance,
                cursor.graphMaxNavDistance,
                cursor.graphPathLimit,
                FloatMax(NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin),
                NAV_CANDIDATE_RESULT_TTL,
                cursor.graphOffset,
                page,
                pageNavDistance,
                NAV_CANDIDATE_PAGE_SIZE,
                resultAgeMs,
                totalInRange);
            if (count == ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE)
            {
                if (SpawnAccel_IsDynamicGraphPending())
                    return SpawnCandidateRead_Pending;
                g_bSpawnAccelGraphCandidatesAvailable = false;
                cursor.source = SpawnCandidate_All;
                cursor.allRow = 0;
                Debug_Print("[SPAWN ACCEL] directed candidate collect unavailable; using all-Nav fallback");
                continue;
            }
            if (count == ANNE_SPAWN_NAV_CANDIDATE_PENDING)
                return SpawnCandidateRead_Pending;

            cursor.graphTotalInRange = totalInRange;
            if (count == 0 && totalInRange == 0 && cursor.graphOffset == 0)
            {
                Debug_Print("[SPAWN ACCEL] directed range exhausted target=%d nav=%d range=%.1f..%.1f; widening directed range",
                    cursor.graphTargetClient, cursor.graphTargetNavId,
                    cursor.graphMinNavDistance, cursor.graphMaxNavDistance);
                return SpawnCandidateRead_Exhausted;
            }
            if (count <= 0)
                return SpawnCandidateRead_Exhausted;

            cursor.graphPageLen = count;
            for (int row = 0; row < count; row++)
            {
                cursor.graphPage[row] = page[row];
                cursor.graphPageNavDistance[row] = pageNavDistance[row];
            }
            float ttlRemaining = NAV_CANDIDATE_RESULT_TTL - resultAgeMs / 1000.0;
            cursor.graphPageExpiresAt = now + FloatMax(0.001, ttlRemaining);
            continue;
        }

        if (cursor.source == SpawnCandidate_All
            && cursor.allRow < g_NavAreasCacheCount)
        {
            areaIdx = cursor.allRow++;
            // 映射 badflow 只用于召回/进度评分，绝不冒充路径连通性；
            // 未映射的坏 Flow 仍拒绝，映射成功的点交给同帧 BuildPath 最终判定。
            rejectBadFlow = !TryGetBucketByAreaIdx(areaIdx, candidateBucket);
            return SpawnCandidateRead_Found;
        }
        return SpawnCandidateRead_Exhausted;
    }
    return SpawnCandidateRead_Exhausted;
}

static SpawnSearchResult FindSpawnPosViaNavAreaStepForCursor(
    SpawnSearchCursor cursor,
    int zc, int targetSurvivor, float minRange, float maxRange,
    float graphScanMinRange, bool teleportMode,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    outAreaIdx = -1;
    if (SpawnAccel_IsDynamicGraphPending())
        return SpawnSearch_Pending;

    SpawnFrameContext frame;
    if (!SpawnSearch_BuildFrameContext(targetSurvivor, frame))
    {
        SpawnSearch_ResetCursor(cursor);
        SpawnPerf_RecordAttempt(0.0, false);
        return SpawnSearch_Exhausted;
    }
    SpawnSearch_EnsureCursor(
        cursor, zc, targetSurvivor, minRange, maxRange, graphScanMinRange,
        teleportMode, frame.navStartClient, frame.navStartId);

    float sliceStart = GetEngineTime();
    int sliceInspected = 0;
    int sliceExpensive = 0;
    int acceptedHits = 0;
    bool exhausted = false;
    bool foundThisTick = false;
    float bestScore = -1.0e9;
    float now = GetGameTime();
    SpawnScoreDbg bestDbg;
    while (sliceInspected < gCV.iSpawnNavCandidatesPerSlice
        && sliceExpensive < gCV.iSpawnNavExpensivePerSlice
        && acceptedHits < frame.candidateBudget
        && (GetEngineTime() - sliceStart) * 1000.0 < gCV.fSpawnNavSliceBudgetMs)
    {
        int areaIdx;
        int candidateBucket;
        float navDistance;
        bool rejectBadFlow;
        SpawnCandidateReadResult readResult = SpawnSearch_NextCandidate(
            cursor, areaIdx, candidateBucket, navDistance, rejectBadFlow);
        if (readResult == SpawnCandidateRead_Pending)
            break;
        if (readResult == SpawnCandidateRead_Exhausted)
        {
            exhausted = true;
            break;
        }

        sliceInspected++;
        cursor.inspected++;
        bool usedExpensive;
        SpawnScoreDbg candDbg;
        bool accepted = SpawnCore_EvaluateNavCandidate(
            zc, targetSurvivor,
            frame.targetPoint, minRange,
            maxRange, teleportMode,
            areaIdx, navDistance, candidateBucket, rejectBadFlow,
            frame.mapMaxFlowDist, frame.finaleArea,
            frame.center, frame.sectors,
            frame.allMaxZ, frame.centerBucket,
            frame.refEyeZ,
            frame.lowestFootZ,
            frame.navStart, frame.visibilityRayMode,
            frame.minScore, now, candDbg,
            cursor.stats, usedExpensive);
        if (usedExpensive)
            sliceExpensive++;
        if (!accepted)
            continue;

        acceptedHits++;
        if (!foundThisTick || candDbg.total > bestScore)
        {
            foundThisTick = true;
            bestScore = candDbg.total;
            SpawnScore_CopyDbg(bestDbg, candDbg);
        }
        if (frame.firstFit && candDbg.total >= frame.firstFitScore)
            break;
    }

    float sliceMs = (GetEngineTime() - sliceStart) * 1000.0;
    cursor.elapsedMs += sliceMs;
    SpawnPerf_RecordSlice(sliceMs);

    if (foundThisTick)
    {
        SpawnScore_CopyDbg(dbgOut, bestDbg);
        SpawnCore_CopyPos(outPos, bestDbg.pos);
        outAreaIdx = bestDbg.areaIdx;
        SpawnPerf_RecordAttempt(cursor.elapsedMs, true);
        SpawnSearch_ResetCursor(cursor);
        return SpawnSearch_Found;
    }
    if (!exhausted)
        return SpawnSearch_Pending;

    Debug_Print("[FIND FAIL] navRange=%.1f..%.1f graphScanMin=%.1f inspected=%d. Filters: cd=%d,pendingSameNav=%d,flag=%d,flow=%d,dist=%d,sep=%d,pendingSep=%d,stuck=%d,vis=%d,path=%d,pos=%d,score=%d,bkt=%d",
                cursor.minRange, cursor.maxRange, cursor.graphScanMinRange,
                cursor.inspected,
                cursor.stats.cooldown, cursor.stats.pendingSameNav,
                cursor.stats.flags,
                cursor.stats.flow, cursor.stats.distance,
                cursor.stats.separation, cursor.stats.pendingSeparation,
                cursor.stats.stuck,
                cursor.stats.visibility, cursor.stats.path,
                cursor.stats.position, cursor.stats.score,
                cursor.stats.bucket);
    SpawnPerf_RecordAttempt(cursor.elapsedMs, false);
    SpawnSearch_ResetCursor(cursor);
    return SpawnSearch_Exhausted;
}

SpawnSearchResult FindSpawnPosViaNavAreaStep(
    int zc, int targetSurvivor, float minRange, float maxRange,
    float graphScanMinRange, bool teleportMode,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return SpawnSearch_Exhausted;

    if (teleportMode)
    {
        return FindSpawnPosViaNavAreaStepForCursor(
            g_TeleportSpawnSearchCursors[idx], zc, targetSurvivor,
            minRange, maxRange, graphScanMinRange, true,
            outPos, outAreaIdx, dbgOut);
    }

    return FindSpawnPosViaNavAreaStepForCursor(
        g_NormalSpawnSearchCursors[idx], zc, targetSurvivor,
        minRange, maxRange, graphScanMinRange, false,
        outPos, outAreaIdx, dbgOut);
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

    return GetMinLiveEyeDistSquaredToAnySurvivor(pos);
}

// 低频最终验证/日志使用实时眼位，不复用候选扫描快照。除了让日志距离可独立
// 核验，也避免同 tick 内其他插件传送生还者时记录到传送前的旧眼位。
float GetMinLiveEyeDistSquaredToAnySurvivor(const float pos[3])
{
    float best = 1.0e20;
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
