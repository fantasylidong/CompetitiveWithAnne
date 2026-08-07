#if defined _infected_control_spawn_score_included
    #endinput
#endif
#define _infected_control_spawn_score_included

static float SpawnScore_ExpF(float x)
{
    return Pow(FLOAT_EULER, x);
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

    Handle tr = TR_TraceRayFilterEx(start, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
    if (!TR_DidHit(tr))
    {
        delete tr;
        return false;
    }

    TR_GetEndPosition(outLand, tr);
    delete tr;

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

// raw badflow 时使用：返回“应扣的分值”，而不是改后的分。
float ComputeBadFlowHeightPenalty(float candZ, float refBestEyeZ)
{
    const float CAP = 200.0;
    float delta = refBestEyeZ - candZ;

    if (delta < -120.0)
        return 0.0;

    float pen;
    if (delta <= 0.0)
    {
        pen = 0.5 * (delta + 120.0);
    }
    else if (delta <= 60.0)
    {
        pen = 60.0 + 2.0 * delta;
    }
    else
    {
        pen = CAP;
    }

    if (pen < 0.0) pen = 0.0;
    if (pen > CAP) pen = CAP;
    return pen;
}

// 高度感知的 ring 弹性（加入近距离屋顶衰减因子）
float HeightRingSlack(const float p[3], float bucketMinZ, float bucketMaxZ, float allMaxEyeZ)
{
    float zRange = bucketMaxZ - bucketMinZ;
    if (zRange < 1.0) zRange = 1.0;

    float zNorm = (p[2] - bucketMinZ) / zRange;
    if (zNorm < 0.0) zNorm = 0.0;
    if (zNorm > 1.0) zNorm = 1.0;

    float base = FloatMin(zRange + 50.0, RING_SLACK * 2.0) * zNorm;
    float over = FloatMax(0.0, p[2] - (allMaxEyeZ + 200.0));
    float taperZ = 1.0 / (1.0 + over / 150.0);

    return base * taperZ;
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

stock float CalculateScore_Height(int zc, const float p[3], float refEyeZ)
{
    float zRel = p[2] - refEyeZ;

    if (zc == view_as<int>(SI_Charger) || zc == view_as<int>(SI_Jockey))
        return HeightScore_NearPlane(zRel, 150.0, 90.0, 20.0, 0.20, -60.0);

    float score;
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

    return ClampFloat(score, -60.0, 110.0);
}


stock float CalculateScore_Dispersion(int sidx, int preferredSector, const int a_recentSectors[3])
{
    float k = PenLimitScale();
    if (sidx == preferredSector)    return 100.0;
    if (sidx == a_recentSectors[0]) return -50.0 * k;
    if (sidx == a_recentSectors[1]) return -25.0 * k;
    if (sidx == a_recentSectors[2]) return 0.0;
    return 50.0;
}

static float ComputeBehindHeightPenalty(int zc, int candBucket, int centerBucket,
                                        float candZ, float refEyeZ, float allMaxEyeZ,
                                        float lowestFootZ)
{
    int bucketGap = centerBucket - candBucket;
    if (bucketGap <= 0)
        return 0.0;

    float softCoef;
    float deepCoef;
    float abyssCoef;
    float highCoef;
    switch (zc)
    {
        case view_as<int>(SI_Smoker):
        {
            softCoef = 0.20;
            deepCoef = 0.34;
            abyssCoef = 0.48;
            highCoef = 0.12;
        }
        case view_as<int>(SI_Hunter):
        {
            softCoef = 0.22;
            deepCoef = 0.38;
            abyssCoef = 0.55;
            highCoef = 0.14;
        }
        default:
        {
            softCoef = 0.28;
            deepCoef = 0.46;
            abyssCoef = 0.60;
            highCoef = 0.18;
        }
    }

    float penalty = 0.0;

    float gapPenalty = float(bucketGap) * 10.0;
    if (gapPenalty > 60.0)
    {
        float extraGap = FloatMax(0.0, float(bucketGap) - 6.0);
        gapPenalty = 60.0 + FloatMin(40.0, extraGap * 8.0);
    }
    penalty += FloatMin(110.0, gapPenalty);

    bool haveFoot = (lowestFootZ < 1.0e8);
    float floorBase = haveFoot ? (lowestFootZ - 40.0) : (refEyeZ - 130.0);
    float drop = floorBase - candZ;
    if (drop > 0.0)
    {
        float softDrop = FloatMin(drop, 70.0);
        float deepDrop = FloatMax(0.0, FloatMin(drop - 70.0, 60.0));
        float abyssDrop = FloatMax(0.0, drop - 130.0);
        float behindFactor = 1.0 + FloatMin(0.60, 0.06 * float(bucketGap));
        float softGain = 1.0 + 0.5 * (softDrop / 70.0);
        float deepGain = 1.0 + 0.8 * (deepDrop / 60.0);
        float abyssLinear = abyssCoef * abyssDrop;
        float abyssCurve = abyssCoef * Pow(abyssDrop, 1.10);
        float abyssTerm = FloatMin(80.0, FloatMax(abyssLinear, abyssCurve));
        float softTerm = softCoef * softDrop * softGain;
        float deepTerm = deepCoef * deepDrop * deepGain;

        penalty += (softTerm + deepTerm + abyssTerm) * behindFactor;
    }

    float highLimit = allMaxEyeZ + 150.0;
    float rise = candZ - highLimit;
    if (rise > 0.0)
        penalty += FloatMin(50.0, rise * highCoef);

    if (penalty > 150.0)
        penalty = 150.0;

    return penalty;
}

stock float ComputeFFThresholdForClass(int zc)
{
    float maxDist = 100.0, maxFlow = 100.0, maxDisp = 100.0, maxHght = 140.0;
    float theoMax = gCV.w_dist[zc] * maxDist
                  + gCV.w_hght[zc] * maxHght
                  + gCV.w_flow[zc] * maxFlow
                  + gCV.w_disp[zc] * maxDisp;
    return 0.85 * theoMax;
}

stock float ScoreDistSmooth(float dminEye, float sweet, float width)
{
    if (width < 1.0) width = 1.0;

    float t = FloatAbs(dminEye - sweet) / width;
    float k = 1.5;
    float s = 100.0 / (1.0 + SpawnScore_ExpF(k * t));

    return ClampFloat(s, 10.0, 100.0);
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

stock float ScoreFlowSmooth(int deltaFlow)
{
    if (deltaFlow <= -12) return 0.0;

    if (deltaFlow < 0)
    {
        float t = float(deltaFlow + 11) / 10.0;
        return 5.0 + t * 25.0;
    }

    if (deltaFlow == 0) return 50.0;
    if (deltaFlow <= 5) return 100.0;

    if (deltaFlow <= 12)
    {
        float t = float(deltaFlow - 6) / 6.0;
        return 85.0 - t * 40.0;
    }

    float over = float(deltaFlow - 12);
    float s = 40.0 / (1.0 + (over / 8.0));
    return 30.0 + ClampFloat(s, 0.0, 40.0);
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
    dest.dist = src.dist;
    dest.hght = src.hght;
    dest.flow = src.flow;
    dest.flowBase = src.flowBase;
    dest.flowPenalty = src.flowPenalty;
    dest.dispRaw = src.dispRaw;
    dest.dispScaled = src.dispScaled;
    dest.penK = src.penK;
    dest.extraPen = src.extraPen;
    dest.dminEye = src.dminEye;
    dest.ringEff = src.ringEff;
    dest.slack = src.slack;
    dest.sweet = src.sweet;
    dest.width = src.width;
    dest.candBucket = src.candBucket;
    dest.centerBucket = src.centerBucket;
    dest.deltaFlow = src.deltaFlow;
    dest.sector = src.sector;
    dest.areaIdx = src.areaIdx;
    dest.rawBadFlow = src.rawBadFlow;
    SpawnScore_CopyPos(dest.pos, src.pos);
}

bool SpawnScore_BuildCandidate(int zc,
                                      const float pos[3],
                                      float dminEye,
                                      float ringEff,
                                      float slack,
                                      int candBucket,
                                      int centerBucket,
                                      bool rawBadFlow,
                                      float refEyeZ,
                                      float bestSurvivorEyeZ,
                                      float lowestFootZ,
                                      int sector,
                                      int preferredSector,
                                      int areaIdx,
                                      SpawnScoreDbg dbg)
{
    // 评分只排序“已经通过硬过滤”的候选点，不负责可见性、卡壳、路径等安全判定。
    // 想让某类点完全不能刷，应放在 SpawnCore_EvaluateNavCandidate 的过滤阶段；
    // 想调整偏好强弱，才改这里的四因子或 config.inc 里的权重。
    float sweet, width;
    GetClassDistanceProfile(zc, gCV.fSpawnMin, ringEff, sweet, width);

    float scoreDist = ScoreDistSmooth(dminEye, sweet, width);
    float scoreHeight = CalculateScore_Height(zc, pos, refEyeZ);

    int deltaFlow = candBucket - centerBucket;
    float flowBase = ScoreFlowSmooth(deltaFlow);
    float flowPenalty = rawBadFlow ? ComputeBadFlowHeightPenalty(pos[2], bestSurvivorEyeZ) : 0.0;
    float scoreFlow = flowBase - flowPenalty;
    if (scoreFlow > 100.0) scoreFlow = 100.0;
    if (scoreFlow < -200.0) scoreFlow = -200.0;

    float scoreDisp = CalculateScore_Dispersion(sector, preferredSector, recentSectors);
    float penK = ComputePenScaleByLimit(gCV.iSiLimit);
    float dispScaled = ScaleNegativeOnly(scoreDisp, penK);
    float behindPenalty = ComputeBehindHeightPenalty(zc, candBucket, centerBucket,
                                                     pos[2], refEyeZ, bestSurvivorEyeZ,
                                                     lowestFootZ);

    dbg.total = gCV.w_dist[zc] * scoreDist
              + gCV.w_hght[zc] * scoreHeight
              + gCV.w_flow[zc] * scoreFlow
              + gCV.w_disp[zc] * dispScaled;
    dbg.total -= behindPenalty;
    dbg.dist = scoreDist;
    dbg.hght = scoreHeight;
    dbg.flow = scoreFlow;
    dbg.flowBase = flowBase;
    dbg.flowPenalty = flowPenalty;
    dbg.dispRaw = scoreDisp;
    dbg.dispScaled = dispScaled;
    dbg.penK = penK;
    dbg.extraPen = behindPenalty;
    dbg.dminEye = dminEye;
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
    SpawnScore_CopyPos(dbg.pos, pos);
    return !(rawBadFlow && scoreFlow < 0.0);
}

void LogChosenSpawnScore(int zc, const SpawnScoreDbg dbg)
{
    if (gCV.iDebugMode <= 0) return;

    int candReal = GetPositionBucketPercent(dbg.pos);
    int surReal = -1;
    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(fb))
        TryGetClientFlowPercentSafe(fb, surReal);

    Debug_Print("[SCORE-CHOSEN] %s pos=(%.1f,%.1f,%.1f) area=%d | tot=%.1f | dist=%.1f h=%.1f flow=%.1f disp=%.1f->%.1f(pK=%.2f) extraPen=%.1f | dEye=%.1f ringEff=%.1f slack=%.1f | bkt=%d ctr=%d dF=%d sec=%d | REAL: cand=%d%% sur=%d%% delta=%d%%",
        g_sInfectedClassNames[zc], dbg.pos[0], dbg.pos[1], dbg.pos[2], dbg.areaIdx,
        dbg.total, dbg.dist, dbg.hght, dbg.flow, dbg.dispRaw, dbg.dispScaled, dbg.penK, dbg.extraPen,
        dbg.dminEye, dbg.ringEff, dbg.slack,
        dbg.candBucket, dbg.centerBucket, dbg.deltaFlow, dbg.sector,
        candReal, surReal, candReal - surReal);
}
