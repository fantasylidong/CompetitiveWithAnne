#if defined _infected_control_spawn_score_included
    #endinput
#endif
#define _infected_control_spawn_score_included

#define SPAWN_SCORE_FIRST_FIT       80.0
#define SPAWN_SCORE_TACTICAL_BLEND_NORMAL  0.10
#define SPAWN_SCORE_TACTICAL_BLEND_BREACH  0.18
#define SPAWN_SCORE_LOW_HEIGHT_STEP_UNITS  50.0

static float SpawnScore_ExpF(float x)
{
    return Pow(FLOAT_EULER, x);
}

static float SpawnScore_SmoothStep(float value)
{
    float t = ClampFloat(value, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

float GetMinDistToAnySurvivor(const float p[3])
{
    float best = 999999.0;
    float s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d < best) best = d;
    }
    return best;
}

static bool FindDropLanding(const float from[3], float outLand[3], float maxDrop = 480.0)
{
    float start[3];
    start[0] = from[0];
    start[1] = from[1];
    start[2] = from[2] + 1.0;

    float end[3];
    end[0] = from[0];
    end[1] = from[1];
    end[2] = from[2] - maxDrop;

    TR_TraceRayFilter(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
    if (!TR_DidHit())
        return false;

    TR_GetEndPosition(outLand);

    Address nav = L4D_GetNearestNavArea(outLand, 120.0, false, false, false, TEAM_INFECTED);
    return nav != Address_Null;
}

stock int GetSepMax()
{
    int cap = gCV.iSiLimit;
    if (cap < 0)  cap = 0;
    if (cap > 20) cap = 20;
    return cap;
}

static float HeightScore_NearPlane(float zRel, float planeWindow, float peakScore, float windowDrop, float falloff, float floorScore)
{
    if (planeWindow < 1.0)
        planeWindow = 1.0;

    float distPlane = FloatAbs(zRel);
    float score;
    if (distPlane <= planeWindow)
    {
        score = peakScore - (distPlane / planeWindow) * windowDrop;
    }
    else
    {
        score = peakScore - windowDrop - (distPlane - planeWindow) * falloff;
    }

    return ClampFloat(score, floorScore, peakScore);
}

static float HeightScore_ModerateAbove(float zRel, float baseScore, float peakScore, float peakZ, float falloff, float floorScore)
{
    if (peakZ < 1.0)
        peakZ = 1.0;

    float score;
    if (zRel <= 0.0)
    {
        score = baseScore + zRel * 0.10;
    }
    else if (zRel <= peakZ)
    {
        score = baseScore + (peakScore - baseScore) * (zRel / peakZ);
    }
    else
    {
        score = peakScore - (zRel - peakZ) * falloff;
    }

    return ClampFloat(score, floorScore, peakScore);
}

static void GetClassHeightScoreRange(int zc, float &scoreMin, float &scoreMax)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker):  { scoreMin = 20.0;  scoreMax = 100.0; }
        case view_as<int>(SI_Boomer):  { scoreMin = 18.0;  scoreMax = 82.0; }
        case view_as<int>(SI_Hunter):  { scoreMin = 22.0;  scoreMax = 108.0; }
        case view_as<int>(SI_Spitter): { scoreMin = 28.0;  scoreMax = 72.0; }
        case view_as<int>(SI_Jockey),
             view_as<int>(SI_Charger): { scoreMin = -60.0; scoreMax = 90.0; }
        default:                       { scoreMin = 24.0;  scoreMax = 76.0; }
    }
}

stock float CalculateScore_Height(int zc, const float p[3], float refEyeZ)
{
    float zRel = p[2] - refEyeZ;
    float score;
    if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
    {
        score = HeightScore_NearPlane(zRel, 150.0, 90.0, 20.0, 0.20, -60.0);
    }
    else
    {
        switch (zc)
        {
            case view_as<int>(SI_Boomer):
            {
                score = HeightScore_NearPlane(zRel, 80.0, 82.0, 12.0, 0.16, 18.0);
            }
            case view_as<int>(SI_Hunter):
            {
                score = HeightScore_ModerateAbove(zRel, 42.0, 90.0, 260.0, 0.13, 22.0);
            }
            case view_as<int>(SI_Smoker):
            {
                score = HeightScore_ModerateAbove(zRel, 46.0, 82.0, 220.0, 0.16, 20.0);
            }
            case view_as<int>(SI_Spitter):
            {
                score = HeightScore_ModerateAbove(zRel, 58.0, 72.0, 140.0, 0.12, 28.0);
            }
            default:
            {
                score = HeightScore_ModerateAbove(zRel, 50.0, 76.0, 180.0, 0.14, 24.0);
            }
        }
    }

    if (zc == view_as<int>(SI_Hunter) || zc == view_as<int>(SI_Smoker))
    {
        float land[3];
        if (FindDropLanding(p, land))
        {
            float d = GetMinDistToAnySurvivor(land);
            if (d < 450.0)
                score += 18.0 * (1.0 - d / 450.0);
        }
    }

    float scoreMin, scoreMax;
    GetClassHeightScoreRange(zc, scoreMin, scoreMax);
    float span = FloatMax(1.0, scoreMax - scoreMin);
    return ClampFloat((score - scoreMin) * 100.0 / span, 0.0, 100.0);
}


static float CalculateScore_DispersionWithScale(int sidx,
                                                const int a_recentSectors[3], float penaltyScale,
                                                float kernelProximity)
{
    float recentPenalty = 0.0;
    if (sidx == a_recentSectors[0])      recentPenalty = 70.0;
    else if (sidx == a_recentSectors[1]) recentPenalty = 45.0;
    else if (sidx == a_recentSectors[2]) recentPenalty = 25.0;

    // 方向偏好由连续战术几何分表达；扇区项避免连续同方向刷出，
    // 核密度项对靠近存活特感/最近刷点的候选做连续距离衰减扣分。
    float kernelPenalty = gCV.fKernelPoints
        * ClampFloat(kernelProximity, 0.0, 1.5);
    float score = 100.0
        - ClampFloat(penaltyScale, 0.0, 1.0) * recentPenalty
        - kernelPenalty;
    return ClampFloat(score, 0.0, 100.0);
}

stock bool SpawnScore_ShouldRejectBehindFlow(int candBucket, int centerBucket)
{
    if (candBucket < 0 || centerBucket < 0 || gCV.iScoreBehindRejectGap < 0)
        return false;

    return candBucket - centerBucket < -gCV.iScoreBehindRejectGap;
}

static float ComputeBehindFlowPenalty(int deltaFlow)
{
    int bucketGap = -deltaFlow;
    if (bucketGap <= 0)
        return 0.0;
    return FloatMin(gCV.fScoreBehindCap,
        float(bucketGap) * gCV.fScoreBehindPerFlow);
}

static float ComputeLowHeightPenalty(float candZ, float targetFootZ, int deltaFlow,
                                     float &drop, int &steps, float &multiplier)
{
    drop = FloatMax(0.0, targetFootZ - candZ);
    steps = 0;
    multiplier = deltaFlow < 0
        ? FloatMax(1.0, gCV.fScoreLowHeightBehindMultiplier) : 1.0;

    if (gCV.fScoreLowHeightCap <= 0.0
        || drop < gCV.fScoreLowHeightStart)
    {
        return 0.0;
    }

    steps = RoundToFloor(
        (drop - gCV.fScoreLowHeightStart) / SPAWN_SCORE_LOW_HEIGHT_STEP_UNITS) + 1;
    float pointsPerStep = gCV.fScoreLowHeightPer100
        * (SPAWN_SCORE_LOW_HEIGHT_STEP_UNITS / 100.0);
    return FloatMin(gCV.fScoreLowHeightCap,
        float(steps) * pointsPerStep * multiplier);
}

static bool SpawnScore_IsHighGroundClass(int zc)
{
    return zc == view_as<int>(SI_Smoker)
        || zc == view_as<int>(SI_Hunter);
}

static float ComputeHighHeightBonus(int zc, float candZ, float targetFootZ,
                                    float &rise, int &steps)
{
    rise = FloatMax(0.0, candZ - targetFootZ);
    steps = 0;
    if (!SpawnScore_IsHighGroundClass(zc)
        || gCV.fScoreHighHeightCap <= 0.0
        || rise < SPAWN_SCORE_LOW_HEIGHT_STEP_UNITS)
    {
        return 0.0;
    }

    steps = RoundToFloor(rise / SPAWN_SCORE_LOW_HEIGHT_STEP_UNITS);
    return FloatMin(gCV.fScoreHighHeightCap,
        float(steps) * gCV.fScoreHighHeightPer50);
}

stock float ComputeFFThreshold()
{
    return SPAWN_SCORE_FIRST_FIT;
}

stock float ScoreDistSmooth(float dTargetEye, float sweet, float width)
{
    if (width < 1.0) width = 1.0;

    float t = FloatAbs(dTargetEye - sweet) / width;
    float s = 100.0 * SpawnScore_ExpF(-0.5 * t * t);

    return ClampFloat(s, 0.0, 100.0);
}

stock void GetClassDistanceProfile(int zc, float min, float max, float &sweet, float &width)
{
    float span = FloatMax(1.0, max - min);
    switch (zc)
    {
        case view_as<int>(SI_Boomer):  { sweet = min + 0.25 * span; width = 0.22 * span; }
        case view_as<int>(SI_Hunter):  { sweet = min + 0.45 * span; width = 0.28 * span; }
        case view_as<int>(SI_Smoker):  { sweet = min + 0.60 * span; width = 0.30 * span; }
        case view_as<int>(SI_Spitter): { sweet = min + 0.40 * span; width = 0.25 * span; }
        case view_as<int>(SI_Jockey):  { sweet = min + 0.35 * span; width = 0.24 * span; }
        case view_as<int>(SI_Charger): { sweet = min + 0.38 * span; width = 0.26 * span; }
        default:                       { sweet = min + 0.40 * span; width = 0.25 * span; }
    }

    sweet += DifficultyStrategy_GetDistSweetOffset() * span;
    sweet = ClampFloat(sweet, min, max);
    width *= DifficultyStrategy_GetDistWidthScale();
    width = ClampFloat(width, span * 0.12, span * 0.80);
}

static void GetClassFlowProfile(int zc, int &backAnchor, int &peakAnchor, int &frontAnchor)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker),
             view_as<int>(SI_Spitter): { backAnchor = -12; peakAnchor = 4; frontAnchor = 20; }
        case view_as<int>(SI_Boomer):  { backAnchor = -8;  peakAnchor = 1; frontAnchor = 14; }
        case view_as<int>(SI_Hunter):  { backAnchor = -10; peakAnchor = 3; frontAnchor = 18; }
        case view_as<int>(SI_Jockey),
             view_as<int>(SI_Charger): { backAnchor = -9;  peakAnchor = 2; frontAnchor = 16; }
        default:                       { backAnchor = -10; peakAnchor = 3; frontAnchor = 18; }
    }
}

stock float ScoreFlowSmooth(int zc, int deltaFlow)
{
    int backAnchor, peakAnchor, frontAnchor;
    GetClassFlowProfile(zc, backAnchor, peakAnchor, frontAnchor);

    if (deltaFlow <= backAnchor)
        return 5.0;

    if (deltaFlow < peakAnchor)
    {
        float t = float(deltaFlow - backAnchor) / float(peakAnchor - backAnchor);
        return 5.0 + 95.0 * SpawnScore_SmoothStep(t);
    }

    if (deltaFlow < frontAnchor)
    {
        float t = float(deltaFlow - peakAnchor) / float(frontAnchor - peakAnchor);
        return 100.0 - 70.0 * SpawnScore_SmoothStep(t);
    }

    return 30.0;
}

stock float PenLimitScale()
{
    float L = float(gCV.iSiLimit);
    float t = (L - float(PEN_LIMIT_MINL)) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

stock float ComputePenScaleByLimit(int L)
{
    int Lc = ClampInt(L, PEN_LIMIT_MINL, PEN_LIMIT_MAXL);
    float t = float(Lc - PEN_LIMIT_MINL) / float(PEN_LIMIT_MAXL - PEN_LIMIT_MINL);
    return PEN_LIMIT_SCALE_HI + (PEN_LIMIT_SCALE_LO - PEN_LIMIT_SCALE_HI) * t;
}

stock float ScaleNegativeOnly(float v, float k)
{
    return (v < 0.0) ? (v * k) : v;
}

static float SpawnScore_WeightedAverage(int zc, float scoreDist, float scoreHeight,
                                        float scoreFlow, float scoreDisp)
{
    float weightDist = FloatMax(0.0, gCV.w_dist[zc]);
    float weightHeight = FloatMax(0.0, gCV.w_hght[zc]);
    float weightFlow = FloatMax(0.0, gCV.w_flow[zc]);
    float weightDisp = FloatMax(0.0, gCV.w_disp[zc]);
    float weightTotal = weightDist + weightHeight + weightFlow + weightDisp;

    if (weightTotal <= 0.0001)
        return 0.25 * (scoreDist + scoreHeight + scoreFlow + scoreDisp);

    return (weightDist * scoreDist
          + weightHeight * scoreHeight
          + weightFlow * scoreFlow
          + weightDisp * scoreDisp) / weightTotal;
}

static void SpawnScore_CopyPos(float dest[3], const float src[3])
{
    dest[0] = src[0];
    dest[1] = src[1];
    dest[2] = src[2];
}

// 注意：SourcePawn enum struct 参数为引用传递，dest 的修改会反映到调用方。
void SpawnScore_CopyDbg(SpawnScoreDbg dest, const SpawnScoreDbg src)
{
    dest.total = src.total;
    dest.baseTotal = src.baseTotal;
    dest.weightedQuality = src.weightedQuality;
    dest.dist = src.dist;
    dest.hght = src.hght;
    dest.flow = src.flow;
    dest.flowBase = src.flowBase;
    dest.flowPenalty = src.flowPenalty;
    dest.dispRaw = src.dispRaw;
    dest.dispScaled = src.dispScaled;
    dest.dispKernel = src.dispKernel;
    dest.penK = src.penK;
    dest.extraPen = src.extraPen;
    dest.behindPen = src.behindPen;
    dest.lowHeightPen = src.lowHeightPen;
    dest.targetFootZ = src.targetFootZ;
    dest.lowHeightDrop = src.lowHeightDrop;
    dest.lowHeightMultiplier = src.lowHeightMultiplier;
    dest.highHeightBonus = src.highHeightBonus;
    dest.highHeightRise = src.highHeightRise;
    dest.tacticalQuality = src.tacticalQuality;
    dest.dTargetEye = src.dTargetEye;
    dest.navDistance = src.navDistance;
    dest.navRankDistance = src.navRankDistance;
    dest.navDistanceEffective = src.navDistanceEffective;
    dest.navHighSortScale = src.navHighSortScale;
    dest.navHighGroundComp = src.navHighGroundComp;
    dest.ringEff = src.ringEff;
    dest.slack = src.slack;
    dest.sweet = src.sweet;
    dest.width = src.width;
    dest.candBucket = src.candBucket;
    dest.centerBucket = src.centerBucket;
    dest.deltaFlow = src.deltaFlow;
    dest.lowHeightSteps = src.lowHeightSteps;
    dest.highHeightSteps = src.highHeightSteps;
    dest.sector = src.sector;
    dest.areaIdx = src.areaIdx;
    dest.rawBadFlow = src.rawBadFlow;
    dest.flowBucketKnown = src.flowBucketKnown;
    SpawnScore_CopyPos(dest.pos, src.pos);
}

bool SpawnScore_BuildCandidate(int zc,
                                      const float pos[3],
                                      float dTargetEye,
                                      float navDistance,
                                      float navDistanceEffective,
                                      float navHighGroundComp,
                                      float minRange,
                                      float ringEff,
                                      float slack,
                                      int candBucket,
                                      int centerBucket,
                                      bool rawBadFlow,
                                      bool flowBucketKnown,
                                      float refEyeZ,
                                      float targetFootZ,
                                      int sector,
                                      int areaIdx,
                                      float tacticalQuality,
                                      float kernelProximity,
                                      SpawnScoreDbg dbg)
{
    // 评分只排序“已经通过硬过滤”的候选点，不负责可见性、卡壳、路径等安全判定。
    // 想让某类点完全不能刷，应放在 SpawnCore_EvaluateNavCandidate 的过滤阶段；
    // 想调整偏好强弱，才改这里的四因子或 config.inc 里的权重。
    float sweet, width;
    GetClassDistanceProfile(zc, minRange, ringEff, sweet, width);

    float scoreDistance = navDistanceEffective >= 0.0
        ? navDistanceEffective : dTargetEye;
    float scoreDist = ScoreDistSmooth(scoreDistance, sweet, width);
    float scoreHeight = CalculateScore_Height(zc, pos, refEyeZ);

    int deltaFlow = candBucket - centerBucket;
    float flowBase = ScoreFlowSmooth(zc, deltaFlow);
    float flowPenalty = rawBadFlow ? ClampFloat(gCV.fFlowBadPenalty, 0.0, 100.0) : 0.0;
    float scoreFlow = ClampFloat(flowBase - flowPenalty, 0.0, 100.0);

    float penK = ComputePenScaleByLimit(gCV.iSiLimit);
    float scoreDisp = CalculateScore_DispersionWithScale(
        sector, recentSectors, 1.0, kernelProximity);
    float dispScaled = CalculateScore_DispersionWithScale(
        sector, recentSectors, penK, kernelProximity);
    float behindPenalty = ComputeBehindFlowPenalty(deltaFlow);
    float lowHeightDrop, lowHeightMultiplier;
    int lowHeightSteps;
    float lowHeightPenalty = ComputeLowHeightPenalty(
        pos[2], targetFootZ, deltaFlow,
        lowHeightDrop, lowHeightSteps, lowHeightMultiplier);
    float extraPenalty = behindPenalty + lowHeightPenalty;
    float highHeightRise;
    int highHeightSteps;
    float highHeightBonus = ComputeHighHeightBonus(
        zc, pos[2], targetFootZ, highHeightRise, highHeightSteps);

    float weightedQuality = SpawnScore_WeightedAverage(
        zc, scoreDist, scoreHeight, scoreFlow, dispScaled);
    dbg.weightedQuality = ClampFloat(weightedQuality, 0.0, 100.0);
    dbg.baseTotal = dbg.weightedQuality;
    dbg.tacticalQuality = ClampFloat(tacticalQuality, 0.0, 100.0);
    float tacticalBlend = Tactical_IsBreachWave()
        ? SPAWN_SCORE_TACTICAL_BLEND_BREACH
        : SPAWN_SCORE_TACTICAL_BLEND_NORMAL;
    dbg.total = ClampFloat(
        dbg.baseTotal * (1.0 - tacticalBlend)
        + dbg.tacticalQuality * tacticalBlend
        + highHeightBonus - extraPenalty,
        0.0, 100.0);
    dbg.dist = scoreDist;
    dbg.hght = scoreHeight;
    dbg.flow = scoreFlow;
    dbg.flowBase = flowBase;
    dbg.flowPenalty = flowPenalty;
    dbg.dispRaw = scoreDisp;
    dbg.dispScaled = dispScaled;
    dbg.dispKernel = kernelProximity;
    dbg.penK = penK;
    dbg.extraPen = extraPenalty;
    dbg.behindPen = behindPenalty;
    dbg.lowHeightPen = lowHeightPenalty;
    dbg.targetFootZ = targetFootZ;
    dbg.lowHeightDrop = lowHeightDrop;
    dbg.lowHeightMultiplier = lowHeightMultiplier;
    dbg.lowHeightSteps = lowHeightSteps;
    dbg.highHeightBonus = highHeightBonus;
    dbg.highHeightRise = highHeightRise;
    dbg.highHeightSteps = highHeightSteps;
    dbg.dTargetEye = dTargetEye;
    dbg.navDistance = navDistance;
    dbg.navDistanceEffective = navDistanceEffective;
    dbg.navHighGroundComp = navHighGroundComp;
    dbg.ringEff = ringEff;
    dbg.slack = slack;
    dbg.sweet = sweet;
    dbg.width = width;
    dbg.candBucket = candBucket;
    dbg.centerBucket = centerBucket;
    dbg.deltaFlow = deltaFlow;
    dbg.sector = sector;
    dbg.areaIdx = areaIdx;
    dbg.rawBadFlow = rawBadFlow;
    dbg.flowBucketKnown = flowBucketKnown;
    SpawnScore_CopyPos(dbg.pos, pos);
    return true;
}

void LogChosenSpawnScore(int zc, const SpawnScoreDbg dbg)
{
    if (gCV.iDebugMode <= 0) return;

    int candReal = GetPositionBucketPercent(dbg.pos);
    int surReal = -1;
    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(fb))
        TryGetClientFlowPercentSafe(fb, surReal);

    Debug_Print("[SCORE-CHOSEN] %s pos=(%.1f,%.1f,%.1f) area=%d | tot=%.1f quality=%.1f tacticalQ=%.1f | dist=%.1f h=%.1f flow=%.1f disp=%.1f->%.1f(pK=%.2f kern=%.2f) highBonus=%.1f(rise=%.1f steps=%d) extraPen=%.1f(back=%.1f low=%.1f) lowGeom=foot%.1f/drop%.1f/steps%d/x%.1f | dTargetEye=%.1f navDistance=%.1f navRank=%.1f navEffective=%.1f highSort=%.2f highComp=%.1f navRangeMax=%.1f slack=%.1f | bkt=%d ctr=%d dF=%d known=%d sec=%d | REAL: cand=%d%% sur=%d%% delta=%d%%",
        g_sInfectedClassNames[zc], dbg.pos[0], dbg.pos[1], dbg.pos[2], dbg.areaIdx,
        dbg.total, dbg.weightedQuality, dbg.tacticalQuality,
        dbg.dist, dbg.hght, dbg.flow, dbg.dispRaw, dbg.dispScaled, dbg.penK, dbg.dispKernel,
        dbg.highHeightBonus, dbg.highHeightRise, dbg.highHeightSteps,
        dbg.extraPen, dbg.behindPen, dbg.lowHeightPen,
        dbg.targetFootZ, dbg.lowHeightDrop, dbg.lowHeightSteps,
        dbg.lowHeightMultiplier,
        dbg.dTargetEye, dbg.navDistance, dbg.navRankDistance,
        dbg.navDistanceEffective, dbg.navHighSortScale,
        dbg.navHighGroundComp, dbg.ringEff, dbg.slack,
        dbg.candBucket, dbg.centerBucket, dbg.deltaFlow,
        dbg.flowBucketKnown ? 1 : 0, dbg.sector,
        candReal, surReal, candReal - surReal);
}
