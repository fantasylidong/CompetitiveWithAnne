#if defined _infected_control_spawn_core_included
    #endinput
#endif
#define _infected_control_spawn_core_included

enum struct SpawnFilterStats
{
    int cooldown;
    int flags;
    int flow;
    int behindFlow;
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
        this.behindFlow = 0;
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
// - FindSpawnPosViaNavArea：准备生还者/Flow/扇区上下文，只消费有向图候选。
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

// 目标进度优先取脚下实际 NavArea 的 raw/mapped bucket。若脚下 Area 存在但
// 无法映射，保持 unknown，避免多层地图用几何最近的另一层伪造目标进度。
static bool SpawnCore_TryGetTargetBucket(int client, int &outBucket)
{
    outBucket = -1;
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client))
        return false;

    float pos[3];
    GetClientAbsOrigin(client, pos);
    Address current = L4D2Direct_GetTerrorNavArea(pos);
    if (current != Address_Null)
    {
        int areaIdx = GetAreaIndexByNavID_Int(L4D_GetNavAreaID(current));
        return TryGetBucketByAreaIdx(areaIdx, outBucket);
    }

    return TryGetClientFlowPercentSafe(client, outBucket);
}

static bool SpawnCore_EvaluateNavCandidate(int zc,
                                           int targetSurvivor,
                                           const float targetPoint[3],
                                           float minRange,
                                           float searchRange,
                                           bool teleportMode,
                                           bool enforceSectorQuota,
                                           int areaIdx,
                                           float navDistance,
                                           float navRankDistance,
                                           int knownBucket,
                                           bool rejectBadFlow,
                                           float mapMaxFlowDist,
                                           bool finaleArea,
                                           const float center[3],
                                           int sectors,
                                           int centerBucket,
                                           float refEyeZ,
                                           float targetFootZ,
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
    bool candidateBucketKnown = candidateBucket >= 0;

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

        if (candidateBucket < 0 && !rawBadFlow)
        {
            candidateBucket = FlowDistanceToPercent(flow);
            candidateBucketKnown = true;
        }
    }
    // 完全无法映射的 badflow 不得伪装成 0% 并触发后点硬拒绝；它继续接受
    // rawBadFlow 分项扣分，Flow 相对位置按中性处理。
    if (!candidateBucketKnown)
        candidateBucket = centerBucket >= 0 ? centerBucket : 50;
    candidateBucket = ClampInt(candidateBucket, 0, 100);
    int scoringCenterBucket = centerBucket >= 0 ? centerBucket : candidateBucket;

    // 3) dF=-8 仍参与评分，dF<-8 在随机点、trace/path 前直接淘汰。
    if (candidateBucketKnown
        && SpawnScore_ShouldRejectBehindFlow(candidateBucket, scoringCenterBucket))
    {
        stats.behindFlow++;
        SpawnPerf_RecordFilterByBehindFlow();
        return false;
    }

    // 4) 冷却和同桶上限都是区域/桶级判断，放在 GetRandomPoint 之前节省点位级成本。
    if (IsNavOnCooldown(areaIdx, now))
    {
        stats.cooldown++;
        SpawnPerf_RecordFilterByCooldown();
        return false;
    }

    if (candidateBucketKnown && !PassBucketShareLimit(candidateBucket))
    {
        stats.bucket++;
        SpawnPerf_RecordFilterByBucket();
        return false;
    }

    // 5) 从这里开始才进入点位级成本。一个 NavArea 内可能同时跨过距离带边界；
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

        // 6) 最近刷点分散是纯内存距离检查，比距离/trace/path 都便宜。
        if (!PassMinSeparation(pos))
        {
            stats.separation++;
            SpawnPerf_RecordFilterBySeparation();
            continue;
        }

        // 7) 当前职业范围是硬边界；Smoker/Hunter 的正高度差只折减 Nav
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

    // 7.5) 波内扇区配额：便宜的角度/计数判断，放在昂贵检查之前。
    //      后 1/3 远带搜索不受限，避免狭长地形因配额而完全找不到点。
    if (!geometryReady)
        sector = ComputeSectorIndex(center, pos, sectors);
    if (enforceSectorQuota && !PassWaveSectorQuota(sector))
    {
        stats.separation++;
        SpawnPerf_RecordFilterBySeparation();
        return false;
    }

    // 8) 有向图已经按 candidate -> survivor 路径距离筛出连通候选。
    //    Flow 已在廉价阶段执行 dF<-8 硬拒绝；允许范围内继续参与评分。
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

    // 9) 只有通过所有硬过滤的候选才需要 rawBadFlow 和评分。
    //     这能让图候选路径中大量失败候选完全不读 area.GetFlow()。
    if (!flowLoaded)
    {
        flow = area.GetFlow();
        flowLoaded = true;
        rawBadFlow = IsFlowAbnormal(flow, mapMaxFlowDist);
    }

    float tacticalQuality = Tactical_GetCandidateQuality(
        zc, pos, targetSurvivor, targetPoint);
    float kernelProximity = SpawnMemory_GetKernelProximity(pos);
    SpawnPerf_RecordFullEvaluation();
    float scoreMinRange = minRange;
    float scoreMaxRange = ringEff;
    if (!SpawnScore_BuildCandidate(
                                   zc, pos, dTargetEye, navDistance,
                                   navDistanceEffective, navHighGroundComp,
                                   scoreMinRange, scoreMaxRange, slack,
                                   candidateBucket, scoringCenterBucket, rawBadFlow,
                                   candidateBucketKnown,
                                   refEyeZ, targetFootZ, sector, areaIdx,
                                   tacticalQuality, kernelProximity, candDbg))
    {
        stats.flow++;
        SpawnPerf_RecordFilterByFlow();
        return false;
    }
    candDbg.navRankDistance = navRankDistance;
    candDbg.navHighSortScale = (zc >= 1 && zc <= SI_COUNT)
        ? gCV.fNavHighSortScale[zc] : 1.0;

    // 公式结果低于 0 时最终分钳制为 0；0 分候选不具备生成资格。
    // 正数 floor 仍作为额外实验门槛，等于 floor 的候选允许参与选择。
    if (candDbg.total <= 0.0
        || (minScore > 0.0 && candDbg.total < minScore))
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
    SpawnCandidate_Graph
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
    float targetFootZ;
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
    int graphTargetClient;
    int graphTargetNavId;
    float graphPathLimit;
    float graphMinNavDistance;
    float graphMaxNavDistance;
    float graphHighSortMinHeight;
    float graphHighSortScale;
    int graphOffset;
    int graphTotalInRange;
    int graphPage[NAV_CANDIDATE_PAGE_SIZE];
    float graphPageNavDistance[NAV_CANDIDATE_PAGE_SIZE];
    float graphPageRankDistance[NAV_CANDIDATE_PAGE_SIZE];
    int graphPageTertile[NAV_CANDIDATE_PAGE_SIZE];
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
    cursor.graphTargetClient = -1;
    cursor.graphTargetNavId = -1;
    cursor.graphPathLimit = 0.0;
    cursor.graphScanMinRange = 0.0;
    cursor.graphMinNavDistance = 0.0;
    cursor.graphMaxNavDistance = 0.0;
    cursor.graphHighSortMinHeight = 0.0;
    cursor.graphHighSortScale = 1.0;
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
    SpawnMemory_RefreshKernelSnapshot();

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
    bool targetUsable = IsValidSurvivor(targetSurvivor)
        && IsPlayerAlive(targetSurvivor)
        && !L4D_IsPlayerIncapacitated(targetSurvivor);
    if (targetUsable)
    {
        SpawnCore_TryGetTargetBucket(targetSurvivor, frame.positionCheckBucket);
    }
    if (frame.positionCheckBucket < 0 && !targetUsable)
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
    frame.centerBucket = frame.positionCheckBucket;

    SpawnCore_CopyPos(frame.targetPoint, frame.center);
    frame.refEyeZ = frame.allMaxZ;
    frame.targetFootZ = frame.center[2];
    if (targetUsable)
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

        float targetOrigin[3];
        GetClientAbsOrigin(targetSurvivor, targetOrigin);
        frame.targetFootZ = targetOrigin[2];
    }
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

// Smoker/Hunter 走 ranked 有向候选：范围仍按原始路径距离取，只有排序
// 会把足够高于目标的候选前置，让高点进入有限的评分名额。
static float SpawnSearch_WantedHighSortScale(int zc)
{
    if (!SpawnAccel_CanUseRankedCandidates())
        return 1.0;
    if (zc < 1 || zc > SI_COUNT)
        return 1.0;
    return ClampFloat(gCV.fNavHighSortScale[zc], 0.50, 1.0);
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
    cursor.graphHighSortMinHeight = gCV.fNavHighSortMinHeight;
    cursor.graphHighSortScale = SpawnSearch_WantedHighSortScale(zc);
    cursor.source = (graphTargetClient > 0 && graphTargetNavId > 0
        && SpawnAccel_CanUseGraphCandidates())
        ? SpawnCandidate_Graph : SpawnCandidate_None;
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
        ? SpawnCandidate_Graph : SpawnCandidate_None;
    bool graphTargetMoved = wantedSource == SpawnCandidate_Graph
        && (cursor.graphTargetClient != graphTargetClient
            || cursor.graphTargetNavId != graphTargetNavId);
    bool rankedParamsChanged = wantedSource == SpawnCandidate_Graph
        && (cursor.graphHighSortScale != SpawnSearch_WantedHighSortScale(zc)
            || cursor.graphHighSortMinHeight != gCV.fNavHighSortMinHeight);
    if (!matches
        || cursor.source != wantedSource || graphTargetMoved
        || rankedParamsChanged)
    {
        SpawnSearch_ConfigureCursor(
            cursor, zc, targetSurvivor, minRange, maxRange,
            graphScanMinRange, teleportMode,
            graphTargetClient, graphTargetNavId);
    }
}

#define SPAWN_TERTILE_NEAR 0
#define SPAWN_TERTILE_MID  1
#define SPAWN_TERTILE_FAR  2

static bool SpawnSearch_TertileEnabled()
{
    return gCV.iSpawnBudgetNear > 0
        || gCV.iSpawnBudgetMid > 0
        || gCV.iSpawnBudgetFar > 0;
}

static int SpawnSearch_TertileBudget(int tertile, int totalBudget)
{
    if (!SpawnSearch_TertileEnabled())
        return totalBudget;
    int cap = 0;
    if (tertile == SPAWN_TERTILE_NEAR)
        cap = gCV.iSpawnBudgetNear;
    else if (tertile == SPAWN_TERTILE_MID)
        cap = gCV.iSpawnBudgetMid;
    else
        cap = gCV.iSpawnBudgetFar;
    if (cap < 0)
        cap = 0;
    if (cap > totalBudget)
        cap = totalBudget;
    return cap;
}

static int SpawnSearch_TertileOfDistance(float navDistance, float lo, float hi)
{
    if (navDistance < 0.0 || hi - lo < 8.0)
        return SPAWN_TERTILE_NEAR;
    float t = (navDistance - lo) / (hi - lo);
    if (t < 0.33333334)
        return SPAWN_TERTILE_NEAR;
    if (t < 0.66666669)
        return SPAWN_TERTILE_MID;
    return SPAWN_TERTILE_FAR;
}

static void SpawnSearch_CountUnreadTertiles(SpawnSearchCursor cursor, int unread[3])
{
    unread[0] = unread[1] = unread[2] = 0;
    for (int row = cursor.graphPageRow; row < cursor.graphPageLen; row++)
    {
        int tertile = cursor.graphPageTertile[row];
        if (tertile < 0 || tertile > 2)
            tertile = SPAWN_TERTILE_NEAR;
        unread[tertile]++;
    }
}

static bool SpawnSearch_TertileCanTake(
    int tertile, int accepted[3], int unread[3],
    int totalBudget, int acceptedHits)
{
    if (acceptedHits >= totalBudget)
        return false;
    if (tertile < 0 || tertile > 2)
        tertile = SPAWN_TERTILE_NEAR;
    int cap = SpawnSearch_TertileBudget(tertile, totalBudget);
    if (accepted[tertile] < cap)
        return true;
    for (int other = 0; other < 3; other++)
    {
        if (other == tertile)
            continue;
        if (accepted[other] < SpawnSearch_TertileBudget(other, totalBudget)
            && unread[other] > 0)
        {
            return false;
        }
    }
    return true;
}

static void SpawnSearch_ShuffleIndexRange(int indices[NAV_CANDIDATE_PAGE_SIZE], int start, int len)
{
    if (len <= 2)
        return;
    int last = start + len - 1;
    for (int row = last; row > start; row--)
    {
        int swap = GetRandomInt(start, row);
        if (swap == row)
            continue;
        int tmp = indices[row];
        indices[row] = indices[swap];
        indices[swap] = tmp;
    }
}

static void SpawnSearch_PreparePageOrder(SpawnSearchCursor cursor, bool ranked)
{
    int count = cursor.graphPageLen;
    for (int row = 0; row < count; row++)
        cursor.graphPageTertile[row] = SPAWN_TERTILE_NEAR;
    if (count <= 2)
        return;

    bool tertileOn = SpawnSearch_TertileEnabled();
    if (!tertileOn)
    {
        if (gCV.bCandidateShuffle && !ranked)
        {
            for (int row = count - 1; row > 0; row--)
            {
                int swap = GetRandomInt(0, row);
                if (swap == row)
                    continue;
                int tmpArea = cursor.graphPage[row];
                cursor.graphPage[row] = cursor.graphPage[swap];
                cursor.graphPage[swap] = tmpArea;
                float tmpNav = cursor.graphPageNavDistance[row];
                cursor.graphPageNavDistance[row] = cursor.graphPageNavDistance[swap];
                cursor.graphPageNavDistance[swap] = tmpNav;
                float tmpRank = cursor.graphPageRankDistance[row];
                cursor.graphPageRankDistance[row] = cursor.graphPageRankDistance[swap];
                cursor.graphPageRankDistance[swap] = tmpRank;
            }
        }
        return;
    }

    float lo = 1.0e20;
    float hi = -1.0;
    for (int row = 0; row < count; row++)
    {
        float navDistance = cursor.graphPageNavDistance[row];
        if (navDistance < 0.0)
            continue;
        if (navDistance < lo)
            lo = navDistance;
        if (navDistance > hi)
            hi = navDistance;
    }

    int binIdx[NAV_CANDIDATE_PAGE_SIZE];
    int binLen[3];
    binLen[0] = binLen[1] = binLen[2] = 0;
    for (int row = 0; row < count; row++)
    {
        int tertile = (hi >= lo)
            ? SpawnSearch_TertileOfDistance(cursor.graphPageNavDistance[row], lo, hi)
            : SPAWN_TERTILE_NEAR;
        cursor.graphPageTertile[row] = tertile;
        binLen[tertile]++;
    }
    int binStart[3];
    binStart[0] = 0;
    binStart[1] = binLen[0];
    binStart[2] = binLen[0] + binLen[1];
    int binFill[3];
    binFill[0] = binStart[0];
    binFill[1] = binStart[1];
    binFill[2] = binStart[2];
    for (int row = 0; row < count; row++)
    {
        int tertile = cursor.graphPageTertile[row];
        binIdx[binFill[tertile]++] = row;
    }
    if (gCV.bCandidateShuffle && !ranked)
    {
        SpawnSearch_ShuffleIndexRange(binIdx, binStart[0], binLen[0]);
        SpawnSearch_ShuffleIndexRange(binIdx, binStart[1], binLen[1]);
        SpawnSearch_ShuffleIndexRange(binIdx, binStart[2], binLen[2]);
    }

    int takeN[3];
    takeN[0] = 3;
    takeN[1] = 2;
    takeN[2] = 1;
    int binCursor[3];
    binCursor[0] = binStart[0];
    binCursor[1] = binStart[1];
    binCursor[2] = binStart[2];
    int binEnd[3];
    binEnd[0] = binStart[0] + binLen[0];
    binEnd[1] = binStart[1] + binLen[1];
    binEnd[2] = binStart[2] + binLen[2];

    int order[NAV_CANDIDATE_PAGE_SIZE];
    int outRow = 0;
    int guard = 0;
    while (outRow < count && guard++ < NAV_CANDIDATE_PAGE_SIZE * 4)
    {
        bool progressed = false;
        for (int tertile = 0; tertile < 3; tertile++)
        {
            int remain = takeN[tertile];
            while (remain-- > 0 && binCursor[tertile] < binEnd[tertile] && outRow < count)
            {
                order[outRow++] = binIdx[binCursor[tertile]++];
                progressed = true;
            }
        }
        if (!progressed)
            break;
    }
    for (int tertile = 0; tertile < 3 && outRow < count; tertile++)
    {
        while (binCursor[tertile] < binEnd[tertile] && outRow < count)
            order[outRow++] = binIdx[binCursor[tertile]++];
    }

    int newArea[NAV_CANDIDATE_PAGE_SIZE];
    float newNav[NAV_CANDIDATE_PAGE_SIZE];
    float newRank[NAV_CANDIDATE_PAGE_SIZE];
    int newTertile[NAV_CANDIDATE_PAGE_SIZE];
    for (int row = 0; row < count; row++)
    {
        int src = order[row];
        newArea[row] = cursor.graphPage[src];
        newNav[row] = cursor.graphPageNavDistance[src];
        newRank[row] = cursor.graphPageRankDistance[src];
        newTertile[row] = cursor.graphPageTertile[src];
    }
    for (int row = 0; row < count; row++)
    {
        cursor.graphPage[row] = newArea[row];
        cursor.graphPageNavDistance[row] = newNav[row];
        cursor.graphPageRankDistance[row] = newRank[row];
        cursor.graphPageTertile[row] = newTertile[row];
    }
}

static SpawnCandidateReadResult SpawnSearch_NextCandidate(
    SpawnSearchCursor cursor, int &areaIdx, int &candidateBucket,
    float &navDistance, float &navRankDistance, int &candidateTertile,
    bool &rejectBadFlow)
{
    candidateBucket = -1;
    navDistance = -1.0;
    navRankDistance = -1.0;
    candidateTertile = SPAWN_TERTILE_NEAR;
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
                navRankDistance = cursor.graphPageRankDistance[pageRow];
                candidateTertile = cursor.graphPageTertile[pageRow];
                if (candidateTertile < SPAWN_TERTILE_NEAR || candidateTertile > SPAWN_TERTILE_FAR)
                    candidateTertile = SPAWN_TERTILE_NEAR;
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

            bool ranked = cursor.graphHighSortScale < 0.999
                && SpawnAccel_CanUseRankedCandidates();
            int prepareStatus = ranked
                ? SpawnAccel_PrepareTargetCandidatesRanked(
                    cursor.graphTargetClient, NAV_CANDIDATE_RESULT_TTL,
                    cursor.graphHighSortMinHeight, cursor.graphHighSortScale)
                : SpawnAccel_PrepareTargetCandidates(
                    cursor.graphTargetClient, NAV_CANDIDATE_RESULT_TTL);
            if (prepareStatus == ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE)
            {
                if (SpawnAccel_IsDynamicGraphPending())
                    return SpawnCandidateRead_Pending;
                g_bSpawnAccelGraphCandidatesAvailable = false;
                cursor.source = SpawnCandidate_None;
                Debug_Print("[SPAWN ACCEL] directed candidates unavailable during search; all-Nav fallback disabled");
                return SpawnCandidateRead_Exhausted;
            }
            if (prepareStatus <= 0)
                return SpawnCandidateRead_Pending;

            float resultAgeMs;
            int totalInRange;
            int page[NAV_CANDIDATE_PAGE_SIZE];
            float pageNavDistance[NAV_CANDIDATE_PAGE_SIZE];
            float pageRankDistance[NAV_CANDIDATE_PAGE_SIZE];
            int count;
            if (ranked)
            {
                count = AnneSpawn_NavCandidatesCollectRanked(
                    cursor.graphTargetClient,
                    cursor.graphTargetNavId,
                    cursor.graphMinNavDistance,
                    cursor.graphMaxNavDistance,
                    cursor.graphPathLimit,
                    FloatMax(NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin),
                    NAV_CANDIDATE_RESULT_TTL,
                    cursor.graphHighSortMinHeight,
                    cursor.graphHighSortScale,
                    cursor.graphOffset,
                    page,
                    pageNavDistance,
                    pageRankDistance,
                    NAV_CANDIDATE_PAGE_SIZE,
                    resultAgeMs,
                    totalInRange);
            }
            else
            {
                count = AnneSpawn_NavCandidatesCollect(
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
                for (int row = 0; row < count; row++)
                    pageRankDistance[row] = pageNavDistance[row];
            }
            if (count == ANNE_SPAWN_NAV_CANDIDATE_UNAVAILABLE)
            {
                if (SpawnAccel_IsDynamicGraphPending())
                    return SpawnCandidateRead_Pending;
                g_bSpawnAccelGraphCandidatesAvailable = false;
                cursor.source = SpawnCandidate_None;
                Debug_Print("[SPAWN ACCEL] directed candidate collect unavailable; all-Nav fallback disabled");
                return SpawnCandidateRead_Exhausted;
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
                cursor.graphPageRankDistance[row] = pageRankDistance[row];
                cursor.graphPageTertile[row] = SPAWN_TERTILE_NEAR;
            }
            // 页内按路径距离三分位交错消费：近:中:远 = 3:2:1，
            // 评分名额默认 6/4/2。非 ranked 时三分位内部仍可洗牌；
            // ranked 高点通道只做三分位交错，组内保序。
            SpawnSearch_PreparePageOrder(cursor, ranked);
            float ttlRemaining = NAV_CANDIDATE_RESULT_TTL - resultAgeMs / 1000.0;
            cursor.graphPageExpiresAt = now + FloatMax(0.001, ttlRemaining);
            continue;
        }

        return SpawnCandidateRead_Exhausted;
    }
    return SpawnCandidateRead_Exhausted;
}

static SpawnSearchResult FindSpawnPosViaNavAreaStepForCursor(
    SpawnSearchCursor cursor,
    int zc, int targetSurvivor, float minRange, float maxRange,
    float graphScanMinRange, bool teleportMode, int bandStage,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    outAreaIdx = -1;
    if (SpawnAccel_ShouldWaitForGraph())
        return SpawnSearch_Pending;

    // 扇区配额只约束前 2/3 的距离带；进入后 1/3 远带说明近处已找不到点，
    // 此时优先保证按时刷出，不再限制方向。(10 档时为 0..6 受限、7..9 放开)
    bool enforceSectorQuota = bandStage >= 0
        && bandStage < TACTICAL_BAND_STAGES - (TACTICAL_BAND_STAGES / 3);

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
    int tertileAccepted[3];
    tertileAccepted[0] = tertileAccepted[1] = tertileAccepted[2] = 0;
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
        float navRankDistance;
        int candidateTertile;
        bool rejectBadFlow;
        SpawnCandidateReadResult readResult = SpawnSearch_NextCandidate(
            cursor, areaIdx, candidateBucket, navDistance,
            navRankDistance, candidateTertile, rejectBadFlow);
        if (readResult == SpawnCandidateRead_Pending)
            break;
        if (readResult == SpawnCandidateRead_Exhausted)
        {
            exhausted = true;
            break;
        }

        sliceInspected++;
        cursor.inspected++;
        if (SpawnSearch_TertileEnabled())
        {
            int unread[3];
            SpawnSearch_CountUnreadTertiles(cursor, unread);
            if (!SpawnSearch_TertileCanTake(
                    candidateTertile, tertileAccepted, unread,
                    frame.candidateBudget, acceptedHits))
            {
                continue;
            }
        }
        bool usedExpensive;
        SpawnScoreDbg candDbg;
        bool accepted = SpawnCore_EvaluateNavCandidate(
            zc, targetSurvivor,
            frame.targetPoint, minRange,
            maxRange, teleportMode,
            enforceSectorQuota,
            areaIdx, navDistance, navRankDistance,
            candidateBucket, rejectBadFlow,
            frame.mapMaxFlowDist, frame.finaleArea,
            frame.center, frame.sectors,
            frame.centerBucket, frame.refEyeZ, frame.targetFootZ,
            frame.navStart, frame.visibilityRayMode,
            frame.minScore, now, candDbg,
            cursor.stats, usedExpensive);
        if (usedExpensive)
            sliceExpensive++;
        if (!accepted)
            continue;

        acceptedHits++;
        if (candidateTertile < 0 || candidateTertile > 2)
            candidateTertile = SPAWN_TERTILE_NEAR;
        tertileAccepted[candidateTertile]++;
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
        Debug_Print("[SCORE BUDGET] near=%d/%d mid=%d/%d far=%d/%d accepted=%d budget=%d inspected=%d expensive=%d",
            tertileAccepted[0], SpawnSearch_TertileBudget(SPAWN_TERTILE_NEAR, frame.candidateBudget),
            tertileAccepted[1], SpawnSearch_TertileBudget(SPAWN_TERTILE_MID, frame.candidateBudget),
            tertileAccepted[2], SpawnSearch_TertileBudget(SPAWN_TERTILE_FAR, frame.candidateBudget),
            acceptedHits, frame.candidateBudget, sliceInspected, sliceExpensive);
        SpawnScore_CopyDbg(dbgOut, bestDbg);
        SpawnCore_CopyPos(outPos, bestDbg.pos);
        outAreaIdx = bestDbg.areaIdx;
        SpawnPerf_RecordAttempt(cursor.elapsedMs, true);
        SpawnSearch_ResetCursor(cursor);
        return SpawnSearch_Found;
    }
    if (!exhausted)
        return SpawnSearch_Pending;

    Debug_Print("[FIND FAIL] navRange=%.1f..%.1f graphScanMin=%.1f inspected=%d. Filters: cd=%d,flag=%d,flow=%d,behindFlow=%d,dist=%d,sep=%d,stuck=%d,vis=%d,path=%d,pos=%d,score=%d,bkt=%d",
                cursor.minRange, cursor.maxRange, cursor.graphScanMinRange,
                cursor.inspected,
                cursor.stats.cooldown, cursor.stats.flags,
                cursor.stats.flow, cursor.stats.behindFlow,
                cursor.stats.distance,
                cursor.stats.separation,
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
    float graphScanMinRange, bool teleportMode, int bandStage,
    float outPos[3], int &outAreaIdx, SpawnScoreDbg dbgOut)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return SpawnSearch_Exhausted;

    if (teleportMode)
    {
        return FindSpawnPosViaNavAreaStepForCursor(
            g_TeleportSpawnSearchCursors[idx], zc, targetSurvivor,
            minRange, maxRange, graphScanMinRange, true, bandStage,
            outPos, outAreaIdx, dbgOut);
    }

    return FindSpawnPosViaNavAreaStepForCursor(
        g_NormalSpawnSearchCursors[idx], zc, targetSurvivor,
        minRange, maxRange, graphScanMinRange, false, bandStage,
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
