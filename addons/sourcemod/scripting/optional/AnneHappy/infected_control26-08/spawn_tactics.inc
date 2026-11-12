#if defined _infected_control_spawn_tactics_included
    #endinput
#endif
#define _infected_control_spawn_tactics_included

#define BREACH_SUPPORT_RELEASE_GRACE 0.75
#define BREACH_SUPPORT_RELEASE_FORCE 1.50

bool Tactical_IsPressureClass(int zc)
{
    return zc == view_as<int>(SI_Smoker)
        || zc == view_as<int>(SI_Hunter)
        || zc == view_as<int>(SI_Jockey)
        || zc == view_as<int>(SI_Charger);
}

static int Tactical_CountPressureSpawnedThisWave()
{
    return gST.siSpawnedThisWave[view_as<int>(SI_Smoker) - 1]
         + gST.siSpawnedThisWave[view_as<int>(SI_Hunter) - 1]
         + gST.siSpawnedThisWave[view_as<int>(SI_Jockey) - 1]
         + gST.siSpawnedThisWave[view_as<int>(SI_Charger) - 1];
}

// 每波按概率放宽支援闸门：偶尔允许 Boomer/Spitter 先于压制类出场，
// 打破"每波必然杀手先、支援后"的固定顺序。
static bool g_bSupportGateWaived = false;

bool Tactical_IsSupportGateWaived()
{
    return g_bSupportGateWaived;
}

void Tactical_ResetSupportGateWaiver()
{
    g_bSupportGateWaived = false;
}

void Tactical_OnWaveStart()
{
    gST.breachWaveActive = gST.breachWavePending;
    gST.breachWavePending = false;
    gST.waveEngaged = false;
    gST.firstPressureSpawnTime = 0.0;
    // Breach 波保持压制类优先，不参与支援闸门放宽。
    g_bSupportGateWaived = !gST.breachWaveActive
        && gCV.fSupportWaiveProb > 0.0
        && GetURandomFloat() < gCV.fSupportWaiveProb;
    if (g_bSupportGateWaived)
        Debug_Print("[SUPPORT GATE] waived for this wave (p=%.2f)", gCV.fSupportWaiveProb);
    for (int i = 0; i < SI_COUNT; i++)
    {
        gST.normalFallbackCycles[i] = 0;
        gST.teleportFallbackCycles[i] = 0;
    }
}

void Tactical_PrepareBreachWave()
{
    if (!AntiBait_ShouldPrepareBreachWave())
        return;

    gST.breachWavePending = true;
    gST.breachTarget = AntiBait_GetPreferredTarget();
    Debug_Print("[BREACH] prepared target=%d", gST.breachTarget);
}

void Tactical_OnEventPressureStarted()
{
    if (gST.breachWaveActive || gST.breachWavePending || gST.breachTarget > 0)
        Debug_Print("[BREACH] cleared by event pressure");

    gST.breachWaveActive = false;
    gST.breachWavePending = false;
    gST.breachTarget = -1;
}

bool Tactical_IsBreachWave()
{
    return gST.breachWaveActive;
}

void Tactical_PrioritizeBreachQueue()
{
    if (!Tactical_IsBreachWave() || gQ.spawn == null || gQ.spawn.Length <= 1)
        return;

    int ordered[MAXPLAYERS];
    int count = 0;
    int length = gQ.spawn.Length;
    if (length > sizeof(ordered))
        return;

    for (int pass = 0; pass < 2; pass++)
    {
        bool wantPressure = (pass == 0);
        for (int i = 0; i < length; i++)
        {
            int zc = gQ.spawn.Get(i);
            if (Tactical_IsPressureClass(zc) == wantPressure)
                ordered[count++] = zc;
        }
    }

    gQ.spawn.Clear();
    for (int i = 0; i < count; i++)
        gQ.spawn.Push(ordered[i]);
    Queue_SyncSizes();
    Debug_Print("[BREACH] prioritized pressure classes queue=%d", count);
}

float Tactical_AdjustQueueScarcity(int zc, float score)
{
    if (!Tactical_IsBreachWave())
        return score;

    return Tactical_IsPressureClass(zc) ? (score - 0.40) : (score + 0.40);
}

int Tactical_ResolveWaveTarget()
{
    if (Tactical_IsBreachWave()
        && IsEligibleSpawnTarget(gST.breachTarget)
        && !SpawnTarget_IsAtCapacity(gST.breachTarget))
        return gST.breachTarget;

    gST.breachTarget = -1;
    return ChooseTargetSurvivor();
}

int Tactical_ResolveRuntimeTarget()
{
    int preferred = AntiBait_GetPreferredTarget();
    if (preferred > 0 && IsEligibleSpawnTarget(preferred)
        && !SpawnTarget_IsAtCapacity(preferred))
    {
        return preferred;
    }

    if (gST.bPickRushMan && IsEligibleSpawnTarget(gST.rushManIndex)
        && !SpawnTarget_IsAtCapacity(gST.rushManIndex))
    {
        return gST.rushManIndex;
    }

    // 普通波内保持目标稳定。每秒随机换人会让某职业在 A 目标推进的距离带
    // 继续套到 B 目标，并反复丢弃有向候选游标。
    if (IsEligibleSpawnTarget(gST.targetSurvivor)
        && !SpawnTarget_IsAtCapacity(gST.targetSurvivor))
    {
        return gST.targetSurvivor;
    }

    return ChooseTargetSurvivor();
}

void Tactical_OnPressureEngaged()
{
    if (gST.bLate)
        gST.waveEngaged = true;
}

void Tactical_OnClassSpawned(int zc)
{
    if (Tactical_IsPressureClass(zc) && gST.firstPressureSpawnTime <= 0.0)
        gST.firstPressureSpawnTime = GetGameTime();
}

bool Tactical_CanReleaseSupport(int zc)
{
    if (!IsSupportGateClassInt(zc))
        return true;

    if (Tactical_IsSupportGateWaived())
        return true;

    int need = GetSupportUnlockNeed();
    if (need <= 0)
        return true;

    float now = GetGameTime();
    float waveAge = now - gST.lastWaveStartTime;
    float forceAfter = Tactical_IsBreachWave() ? BREACH_SUPPORT_RELEASE_FORCE : SUPPORT_RELEASE_FORCE;
    if (waveAge >= forceAfter)
        return true;

    if (Tactical_CountPressureSpawnedThisWave() < need)
        return false;

    if (gST.waveEngaged)
        return true;

    float grace = Tactical_IsBreachWave() ? BREACH_SUPPORT_RELEASE_GRACE : SUPPORT_RELEASE_GRACE;
    return gST.firstPressureSpawnTime > 0.0
        && (now - gST.firstPressureSpawnTime) >= grace;
}

static bool Tactical_Normalize2D(float &x, float &y)
{
    float length = SquareRoot(x * x + y * y);
    if (length < 0.001)
        return false;
    x /= length;
    y /= length;
    return true;
}

static float Tactical_Gaussian(float value, float sweet, float width)
{
    if (width < 1.0)
        width = 1.0;
    float t = (value - sweet) / width;
    return 100.0 * Pow(FLOAT_EULER, -0.5 * t * t);
}

static void Tactical_SortFloatAscending(float values[MAXPLAYERS + 1], int count)
{
    for (int i = 1; i < count; i++)
    {
        float value = values[i];
        int j = i - 1;
        while (j >= 0 && values[j] > value)
        {
            values[j + 1] = values[j];
            j--;
        }
        values[j + 1] = value;
    }
}

// 只使用当前 OnGameFrame 的生还者快照做向量运算，不增加 Trace、Nav 或玩家 native。
// 结果是 0..100 的职业战术质量，作为安全候选之间的软排序项。
float Tactical_GetCandidateQuality(int zc, const float candidate[3], int targetClient,
                                   const float fallbackTarget[3])
{
    int survivorCount = Visibility_GetEyeSnapshotCount();
    if (survivorCount <= 0)
        return 50.0;

    float teamCenter[3];
    float avgForward[2];
    for (int slot = 0; slot < survivorCount; slot++)
    {
        int client;
        float eyes[3], viewDir[2];
        if (!Visibility_GetEyeSnapshot(slot, client, eyes, viewDir))
            continue;
        teamCenter[0] += eyes[0];
        teamCenter[1] += eyes[1];
        teamCenter[2] += eyes[2];
        avgForward[0] += viewDir[0];
        avgForward[1] += viewDir[1];
    }
    teamCenter[0] /= float(survivorCount);
    teamCenter[1] /= float(survivorCount);
    teamCenter[2] /= float(survivorCount);

    float target[3];
    if (!Visibility_GetClientEyeSnapshot(targetClient, target))
    {
        target[0] = fallbackTarget[0];
        target[1] = fallbackTarget[1];
        target[2] = fallbackTarget[2];
    }

    float outwardX = target[0] - teamCenter[0];
    float outwardY = target[1] - teamCenter[1];
    if (!Tactical_Normalize2D(outwardX, outwardY))
    {
        outwardX = -avgForward[0];
        outwardY = -avgForward[1];
        if (!Tactical_Normalize2D(outwardX, outwardY))
        {
            outwardX = 1.0;
            outwardY = 0.0;
        }
    }

    float rearScores[MAXPLAYERS + 1];
    float flankScores[MAXPLAYERS + 1];
    float rearMean = 0.0;
    float flankMean = 0.0;
    int valid = 0;
    for (int slot = 0; slot < survivorCount; slot++)
    {
        int client;
        float eyes[3], viewDir[2];
        if (!Visibility_GetEyeSnapshot(slot, client, eyes, viewDir))
            continue;

        float vx = candidate[0] - eyes[0];
        float vy = candidate[1] - eyes[1];
        if (!Tactical_Normalize2D(vx, vy))
            continue;

        float dot = ClampFloat(viewDir[0] * vx + viewDir[1] * vy, -1.0, 1.0);
        float rear = (1.0 - dot) * 50.0;
        float flank = (1.0 - FloatAbs(dot)) * 100.0;
        rearScores[valid] = rear;
        flankScores[valid] = flank;
        rearMean += rear;
        flankMean += flank;
        valid++;
    }

    if (valid <= 0)
        return 50.0;

    Tactical_SortFloatAscending(rearScores, valid);
    Tactical_SortFloatAscending(flankScores, valid);
    rearMean /= float(valid);
    flankMean /= float(valid);
    int lowerMedian = (valid - 1) / 2;
    float rearQuality = 0.70 * rearScores[lowerMedian] + 0.30 * rearMean;
    float flankQuality = 0.70 * flankScores[lowerMedian] + 0.30 * flankMean;

    float fromTargetX = candidate[0] - target[0];
    float fromTargetY = candidate[1] - target[1];
    float edgeQuality = 50.0;
    float pushQuality = 50.0;
    if (Tactical_Normalize2D(fromTargetX, fromTargetY))
    {
        float outwardDot = ClampFloat(fromTargetX * outwardX + fromTargetY * outwardY, -1.0, 1.0);
        edgeQuality = (outwardDot + 1.0) * 50.0;
        // Charger 站在目标内侧（dot=-1）时，冲锋更可能把边缘目标推出队形。
        pushQuality = (1.0 - outwardDot) * 50.0;
    }

    float centerDx = candidate[0] - teamCenter[0];
    float centerDy = candidate[1] - teamCenter[1];
    float centerDistance = SquareRoot(centerDx * centerDx + centerDy * centerDy);
    float bestAngle = FloatMax(rearQuality, flankQuality);
    float quality;
    switch (zc)
    {
        case view_as<int>(SI_Smoker):
            quality = 0.40 * edgeQuality + 0.35 * bestAngle + 0.25 * rearQuality;
        case view_as<int>(SI_Boomer):
            quality = 0.35 * rearQuality + 0.20 * flankQuality
                + 0.45 * Tactical_Gaussian(centerDistance, 350.0, 160.0);
        case view_as<int>(SI_Hunter):
            quality = 0.55 * flankQuality + 0.40 * edgeQuality + 0.05 * rearQuality;
        case view_as<int>(SI_Spitter):
            quality = 0.25 * rearQuality + 0.20 * flankQuality
                + 0.55 * Tactical_Gaussian(centerDistance, 550.0, 220.0);
        case view_as<int>(SI_Jockey):
            quality = 0.45 * edgeQuality + 0.55 * flankQuality;
        case view_as<int>(SI_Charger):
            quality = 0.55 * pushQuality + 0.25 * flankQuality + 0.20 * edgeQuality;
        default:
            quality = 0.50 * rearQuality + 0.50 * flankQuality;
    }
    return ClampFloat(quality, 0.0, 100.0);
}

float Tactical_GetMaxHighGroundNavCompensation(int zc)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker): return NAV_HIGH_GROUND_SMOKER_MAX;
        case view_as<int>(SI_Hunter): return NAV_HIGH_GROUND_HUNTER_MAX;
    }
    return 0.0;
}

float Tactical_GetHighGroundNavCompensation(int zc,
                                             float candidateZ,
                                             float targetEyeZ)
{
    // 起点与参考面由 HighGround_GetStartZ() 统一提供（见 spawn_score.inc）：
    // 三处高点机制共用 inf_nav_high_sort_min_height，一律相对目标眼位。
    float maxCompensation = Tactical_GetMaxHighGroundNavCompensation(zc);
    float startZ = HighGround_GetStartZ();
    float heightAbove = candidateZ - targetEyeZ;
    if (maxCompensation <= 0.0 || heightAbove <= startZ)
        return 0.0;

    float scale = zc == view_as<int>(SI_Hunter)
        ? NAV_HIGH_GROUND_HUNTER_SCALE
        : NAV_HIGH_GROUND_SMOKER_SCALE;
    return FloatMin(
        (heightAbove - startZ) * scale,
        maxCompensation);
}

// 每类三个锚点：最小距离 / 首选档上界(stage 0) / 最远档上界(最后一档)。
// 固定 TACTICAL_BAND_STAGES 档：stage 0 保持完整首选区间，其余档在首选
// 上界与最远上界之间线性扩圈，第 N 档上界 =
//   baseMax + (finalMax - baseMax) * N / (TACTICAL_BAND_STAGES - 1)
// 职业最小距离在所有档位保持不变，扩圈只向远端推。
//
// 档数是精度与延迟的权衡：档越多，命中的那一档越贴近理想距离，但完整
// 走完所有档需要更多帧。10 档下扩圈环约 200u，已经窄于
// NAV_TERTILE_MIN_RING_WIDTH，档内近/中/远三分位会自动退化为单池
// （见 spawn_core.inc::SpawnSearch_PreparePageOrder）。
static bool Tactical_GetClassBandProfile(int zc, float &minRange,
                                         float &baseMax, float &finalMax)
{
    switch (zc)
    {
        case view_as<int>(SI_Smoker):
        {
            minRange = 500.0; baseMax = 1200.0; finalMax = 3000.0;
        }
        case view_as<int>(SI_Boomer):
        {
            minRange = 250.0; baseMax = 550.0;  finalMax = 2300.0;
        }
        case view_as<int>(SI_Hunter):
        {
            minRange = 350.0; baseMax = 850.0;  finalMax = 2600.0;
        }
        case view_as<int>(SI_Spitter):
        {
            minRange = 300.0; baseMax = 800.0;  finalMax = 2300.0;
        }
        case view_as<int>(SI_Jockey):
        {
            minRange = 250.0; baseMax = 550.0;  finalMax = 2000.0;
        }
        case view_as<int>(SI_Charger):
        {
            minRange = 250.0; baseMax = 600.0;  finalMax = 2000.0;
        }
        default:
        {
            return false;
        }
    }
    return true;
}

stock float Tactical_GetClassPathCap(int zc)
{
    float classMin;
    float baseMax;
    float finalMax;
    if (!Tactical_GetClassBandProfile(zc, classMin, baseMax, finalMax))
        return gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE;
    return FloatMin(finalMax, gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE);
}

static const float TEAM_NAV_LAYER_EDGES[TEAM_NAV_LAYER_COUNT + 1] = {
    250.0, 350.0, 500.0, 700.0, 900.0, 1150.0,
    1400.0, 1700.0, 2000.0, 2400.0, 3000.0
};

stock bool Tactical_IsTeamNearestSearch()
{
    return SpawnAccel_CanUseTeamCandidates();
}

static void Tactical_GetTeamLayerBand(int zc, int stage,
                                      float &minRange, float &maxRange)
{
    stage = ClampInt(stage, 0, TEAM_NAV_LAYER_COUNT - 1);
    float layerLo = TEAM_NAV_LAYER_EDGES[stage];
    float layerHi = TEAM_NAV_LAYER_EDGES[stage + 1];
    float classMin;
    float baseMax;
    float finalMax;
    if (!Tactical_GetClassBandProfile(zc, classMin, baseMax, finalMax))
    {
        classMin = NAV_CANDIDATE_TEAM_EXCLUSION;
        finalMax = gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE;
    }
    classMin = FloatMax(classMin, NAV_CANDIDATE_TEAM_EXCLUSION);
    finalMax = FloatMin(finalMax, gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE);
    minRange = FloatMax(layerLo, classMin);
    maxRange = FloatMin(layerHi, finalMax);
}

void Tactical_GetDistanceBand(int zc, int stage, bool teleportMode,
                              float &minRange, float &maxRange)
{
    if (Tactical_IsTeamNearestSearch())
    {
        Tactical_GetTeamLayerBand(zc, stage, minRange, maxRange);
        return;
    }

    stage = ClampInt(stage, 0, TACTICAL_BAND_STAGES - 1);

    float baseMax, finalMax;
    if (Tactical_GetClassBandProfile(zc, minRange, baseMax, finalMax))
    {
        maxRange = baseMax
            + (finalMax - baseMax) * float(stage)
                / float(TACTICAL_BAND_STAGES - 1);
    }
    else
    {
        minRange = NAV_CANDIDATE_TEAM_EXCLUSION;
        maxRange = gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE;
    }

    minRange = FloatMax(minRange, NAV_CANDIDATE_TEAM_EXCLUSION);
    maxRange = FloatMin(maxRange, gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE);
    if (maxRange < minRange)
        minRange = maxRange;

    if (teleportMode)
    {
        if (maxRange < minRange + 150.0)
            maxRange = FloatMin(
                gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE, minRange + 200.0);
    }

    if (maxRange < minRange)
        minRange = maxRange;
}

float Tactical_GetDistanceBandScanMin(int zc, int stage, bool teleportMode)
{
    stage = ClampInt(stage, 0, TACTICAL_BAND_STAGES - 1);

    float minRange;
    float maxRange;
    Tactical_GetDistanceBand(zc, stage, teleportMode, minRange, maxRange);
    if (Tactical_IsTeamNearestSearch() || stage == 0)
        return minRange;

    float previousMinRange;
    float previousMaxRange;
    Tactical_GetDistanceBand(
        zc, stage - 1, teleportMode, previousMinRange, previousMaxRange);

    // 后续档只向远端扩展图查询，不重新扫描上一档已经完整检查的区间。
    if (previousMaxRange >= maxRange)
    {
        return maxRange + NAV_CANDIDATE_RANGE_SLACK
            + Tactical_GetMaxHighGroundNavCompensation(zc);
    }
    return FloatMax(
        FloatMax(minRange, previousMinRange), previousMaxRange + 0.01);
}
