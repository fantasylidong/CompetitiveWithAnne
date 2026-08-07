#if defined _infected_control_wave_spawn_report_included
    #endinput
#endif
#define _infected_control_wave_spawn_report_included

#define WAVE_REPORT_API_SAMPLE_CAP 64

enum WaveSpawnMode
{
    WaveSpawn_NormalNav = 0,
    WaveSpawn_NormalDirectorRange,
    WaveSpawn_NormalDirectorUnrestricted,
    WaveSpawn_TeleportNav,
    WaveSpawn_TeleportDirectorRange,
    WaveSpawn_TeleportDirectorUnrestricted,
    WaveSpawnMode_Count
}

enum struct WaveSpawnReportState
{
    bool active;
    int wave;
    int plannedAi;
    int pendingAtStart;
    int calls;
    int successes;
    int normalSuccesses;
    int failures;
    int scoredSuccesses;
    int classSuccesses[SI_COUNT];
    int modeCalls[WaveSpawnMode_Count];
    int modeSuccesses[WaveSpawnMode_Count];
    float startedAt;
    float firstSuccessAt;
    float lastSuccessAt;
    float firstNormalSuccessAt;
    float lastNormalSuccessAt;
    float configuredIntervalMs;
    float countdownStartedAt;
    float holdStartedAt;
    float holdEndedAt;
    float spawnCallTotalMs;
    float spawnCallMaxMs;
    float spawnCallSamples[WAVE_REPORT_API_SAMPLE_CAP];
    int spawnCallSampleCount;
    float scoreTotal;
    float scoreMin;
    float scoreMax;
    float scoreBaseTotal;
    float scoreDistTotal;
    float scoreHeightTotal;
    float scoreFlowTotal;
    float scoreDispTotal;
    float scoreTacticalTotal;
    int targetDistanceSamples;
    float targetDistanceTotal;
    float targetDistanceMin;
    float targetDistanceMax;
    int navDistanceSamples;
    float navDistanceTotal;
    float navDistanceMin;
    float navDistanceMax;
    int navEffectiveDistanceSamples;
    float navEffectiveDistanceTotal;
    float navEffectiveDistanceMin;
    float navEffectiveDistanceMax;
    int navHighGroundCompSamples;
    float navHighGroundCompTotal;
    float navHighGroundCompMax;
    int verticalDistanceSamples;
    float verticalDistanceAbsTotal;
    float verticalDistanceAbsMax;
    int workFrames;
    int workAttempts;
    int maxAttemptsPerFrame;
    int frameBudgetStops;
    float frameWorkTotalMs;
    float frameWorkMaxMs;

    void Reset()
    {
        this.active = false;
        this.wave = 0;
        this.plannedAi = 0;
        this.pendingAtStart = 0;
        this.calls = 0;
        this.successes = 0;
        this.normalSuccesses = 0;
        this.failures = 0;
        this.scoredSuccesses = 0;
        this.startedAt = 0.0;
        this.firstSuccessAt = -1.0;
        this.lastSuccessAt = -1.0;
        this.firstNormalSuccessAt = -1.0;
        this.lastNormalSuccessAt = -1.0;
        this.configuredIntervalMs = 0.0;
        this.countdownStartedAt = -1.0;
        this.holdStartedAt = -1.0;
        this.holdEndedAt = -1.0;
        this.spawnCallTotalMs = 0.0;
        this.spawnCallMaxMs = 0.0;
        this.spawnCallSampleCount = 0;
        this.scoreTotal = 0.0;
        this.scoreMin = 999999.0;
        this.scoreMax = -999999.0;
        this.scoreBaseTotal = 0.0;
        this.scoreDistTotal = 0.0;
        this.scoreHeightTotal = 0.0;
        this.scoreFlowTotal = 0.0;
        this.scoreDispTotal = 0.0;
        this.scoreTacticalTotal = 0.0;
        this.targetDistanceSamples = 0;
        this.targetDistanceTotal = 0.0;
        this.targetDistanceMin = 999999.0;
        this.targetDistanceMax = -1.0;
        this.navDistanceSamples = 0;
        this.navDistanceTotal = 0.0;
        this.navDistanceMin = 999999.0;
        this.navDistanceMax = -1.0;
        this.navEffectiveDistanceSamples = 0;
        this.navEffectiveDistanceTotal = 0.0;
        this.navEffectiveDistanceMin = 999999.0;
        this.navEffectiveDistanceMax = -1.0;
        this.navHighGroundCompSamples = 0;
        this.navHighGroundCompTotal = 0.0;
        this.navHighGroundCompMax = 0.0;
        this.verticalDistanceSamples = 0;
        this.verticalDistanceAbsTotal = 0.0;
        this.verticalDistanceAbsMax = 0.0;
        this.workFrames = 0;
        this.workAttempts = 0;
        this.maxAttemptsPerFrame = 0;
        this.frameBudgetStops = 0;
        this.frameWorkTotalMs = 0.0;
        this.frameWorkMaxMs = 0.0;

        for (int zc = 0; zc < SI_COUNT; zc++)
            this.classSuccesses[zc] = 0;
        for (int mode = 0; mode < view_as<int>(WaveSpawnMode_Count); mode++)
        {
            this.modeCalls[mode] = 0;
            this.modeSuccesses[mode] = 0;
        }
    }
}

static WaveSpawnReportState g_WaveSpawnReport;

static void WaveSpawnReport_GetModeName(WaveSpawnMode mode, char[] output, int maxlen)
{
    switch (mode)
    {
        case WaveSpawn_NormalNav: strcopy(output, maxlen, "normal_nav");
        case WaveSpawn_NormalDirectorRange: strcopy(output, maxlen, "normal_director_range");
        case WaveSpawn_NormalDirectorUnrestricted: strcopy(output, maxlen, "normal_director_unrestricted");
        case WaveSpawn_TeleportNav: strcopy(output, maxlen, "teleport_nav");
        case WaveSpawn_TeleportDirectorRange: strcopy(output, maxlen, "teleport_director_range");
        case WaveSpawn_TeleportDirectorUnrestricted: strcopy(output, maxlen, "teleport_director_unrestricted");
        default: strcopy(output, maxlen, "unknown");
    }
}

static int WaveSpawnReport_PercentileIndex(int count, float percentile)
{
    int index = RoundToCeil(float(count) * percentile) - 1;
    if (index < 0)
        index = 0;
    if (index >= count)
        index = count - 1;
    return index;
}

static void WaveSpawnReport_BeginInternal(int wave, int plannedAi,
                                          int pendingAtStart, float startedAt)
{
    g_WaveSpawnReport.Reset();
    if (!SpawnPerfConfig_ShowStats() || wave <= 0)
        return;

    g_WaveSpawnReport.active = true;
    g_WaveSpawnReport.wave = wave;
    g_WaveSpawnReport.plannedAi = plannedAi;
    g_WaveSpawnReport.pendingAtStart = pendingAtStart;
    g_WaveSpawnReport.startedAt = startedAt;
    g_WaveSpawnReport.configuredIntervalMs =
        DifficultyStrategy_GetConfiguredWaveDelay() * 1000.0;
    SpawnPerf_Log(
        "[SpawnWave][Begin] wave=%d plannedAi=%d pendingAtStart=%d alive=%d cap=%d target=%d breach=%d configuredIntervalMs=%.1f killWindowMs=%.1f attemptsPerFrame=%d frameBudgetMs=%.2f navPerSlice=%d expensivePerSlice=%d navSliceBudgetMs=%.2f",
        wave, plannedAi, pendingAtStart, gST.totalSI, gCV.iSiLimit,
        gST.targetSurvivor, gST.breachWaveActive ? 1 : 0,
        g_WaveSpawnReport.configuredIntervalMs,
        DifficultyStrategy_GetWaveCheckDelay() * 1000.0,
        gCV.iSpawnAttemptsPerFrame, gCV.fSpawnFrameBudgetMs,
        gCV.iSpawnNavCandidatesPerSlice,
        gCV.iSpawnNavExpensivePerSlice,
        gCV.fSpawnNavSliceBudgetMs);
}

stock void WaveSpawnReport_Begin(int wave, int plannedAi,
                                 int pendingAtStart, float startedAt)
{
    WaveSpawnReport_BeginInternal(wave, plannedAi, pendingAtStart, startedAt);
}

stock void WaveSpawnReport_RecordCountdownStart(float now, const char[] reason)
{
    if (!g_WaveSpawnReport.active)
        return;

    g_WaveSpawnReport.countdownStartedAt = now;
    SpawnPerf_Log(
        "[SpawnWave][Timing] wave=%d event=countdown_start waveElapsedMs=%.1f killWindowMs=%.1f configuredIntervalMs=%.1f pending=%d alive=%d reason=%s",
        g_WaveSpawnReport.wave,
        FloatMax(0.0, now - g_WaveSpawnReport.startedAt) * 1000.0,
        DifficultyStrategy_GetWaveCheckDelay() * 1000.0,
        g_WaveSpawnReport.configuredIntervalMs,
        gST.siQueueCount, gST.totalSI, reason);
}

stock void WaveSpawnReport_RecordAntiBaitHoldStart(float now)
{
    if (!g_WaveSpawnReport.active)
        return;

    g_WaveSpawnReport.holdStartedAt = now;
    int activeCount, vulnerableCount;
    float spreadDist, avgNearestDist, stalledSecs, pressureSecs;
    AntiBait_GetHoldMetrics(activeCount, vulnerableCount, spreadDist,
        avgNearestDist, stalledSecs, pressureSecs);
    SpawnPerf_Log(
        "[SpawnWave][AntiBait] wave=%d event=hold_start waveElapsedMs=%.1f countdownElapsedMs=%.1f active=%d vulnerable=%d spread=%.1f avgNearest=%.1f stalledMs=%.1f pressureMs=%.1f",
        g_WaveSpawnReport.wave,
        FloatMax(0.0, now - g_WaveSpawnReport.startedAt) * 1000.0,
        FloatMax(0.0, now - g_WaveSpawnReport.countdownStartedAt) * 1000.0,
        activeCount, vulnerableCount, spreadDist, avgNearestDist,
        stalledSecs * 1000.0, pressureSecs * 1000.0);
}

stock void WaveSpawnReport_RecordAntiBaitHoldClearCandidate(float now)
{
    if (!g_WaveSpawnReport.active)
        return;

    int activeCount, vulnerableCount;
    float spreadDist, avgNearestDist, stalledSecs, pressureSecs;
    AntiBait_GetHoldMetrics(activeCount, vulnerableCount, spreadDist,
        avgNearestDist, stalledSecs, pressureSecs);
    SpawnPerf_Log(
        "[SpawnWave][AntiBait] wave=%d event=hold_clear_candidate extendedMs=%.1f confirmMs=%.1f active=%d vulnerable=%d holding=%d spread=%.1f avgNearest=%.1f stalledMs=%.1f",
        g_WaveSpawnReport.wave,
        FloatMax(0.0, now - g_WaveSpawnReport.holdStartedAt) * 1000.0,
        gCV.fAntiBaitReleaseConfirm * 1000.0,
        activeCount, vulnerableCount, AntiBait_IsTeamHolding() ? 1 : 0,
        spreadDist, avgNearestDist, stalledSecs * 1000.0);
}

stock void WaveSpawnReport_RecordAntiBaitHoldEnd(float now)
{
    if (!g_WaveSpawnReport.active)
        return;

    g_WaveSpawnReport.holdEndedAt = now;
    SpawnPerf_Log(
        "[SpawnWave][AntiBait] wave=%d event=hold_release extendedMs=%.1f",
        g_WaveSpawnReport.wave,
        FloatMax(0.0, now - g_WaveSpawnReport.holdStartedAt) * 1000.0);
}

static void WaveSpawnReport_EnsureActive()
{
    if (g_WaveSpawnReport.active || !SpawnPerfConfig_ShowStats()
        || gST.waveIndex <= 0)
    {
        return;
    }

    float startedAt = gST.lastWaveStartTime;
    if (startedAt <= 0.0)
        startedAt = GetGameTime();
    WaveSpawnReport_BeginInternal(gST.waveIndex, -1, gST.siQueueCount, startedAt);
}

static bool WaveSpawnReport_RecordBase(
    int zc, int spawnedClient, WaveSpawnMode mode, float spawnCallMs,
    const float requestedPos[3], float actualPos[3],
    int &sequence, float &waveElapsedMs, bool &actualValid)
{
    if (!SpawnPerfConfig_ShowStats())
        return false;

    WaveSpawnReport_EnsureActive();
    if (!g_WaveSpawnReport.active)
        return false;

    float now = GetGameTime();
    bool success = spawnedClient > 0;
    actualValid = success && spawnedClient <= MaxClients
        && IsClientInGame(spawnedClient);
    float clampedCallMs = FloatMax(0.0, spawnCallMs);

    g_WaveSpawnReport.calls++;
    sequence = g_WaveSpawnReport.calls;
    int modeIdx = view_as<int>(mode);
    if (modeIdx >= 0 && modeIdx < view_as<int>(WaveSpawnMode_Count))
        g_WaveSpawnReport.modeCalls[modeIdx]++;
    waveElapsedMs = FloatMax(0.0, (now - g_WaveSpawnReport.startedAt) * 1000.0);
    g_WaveSpawnReport.spawnCallTotalMs += clampedCallMs;
    if (clampedCallMs > g_WaveSpawnReport.spawnCallMaxMs)
        g_WaveSpawnReport.spawnCallMaxMs = clampedCallMs;
    if (g_WaveSpawnReport.spawnCallSampleCount < WAVE_REPORT_API_SAMPLE_CAP)
    {
        g_WaveSpawnReport.spawnCallSamples[g_WaveSpawnReport.spawnCallSampleCount]
            = clampedCallMs;
        g_WaveSpawnReport.spawnCallSampleCount++;
    }

    actualPos[0] = requestedPos[0];
    actualPos[1] = requestedPos[1];
    actualPos[2] = requestedPos[2];
    if (!success)
    {
        g_WaveSpawnReport.failures++;
        return false;
    }

    if (actualValid)
        GetClientAbsOrigin(spawnedClient, actualPos);
    g_WaveSpawnReport.successes++;
    if (zc >= 1 && zc <= SI_COUNT)
        g_WaveSpawnReport.classSuccesses[zc - 1]++;
    if (modeIdx >= 0 && modeIdx < view_as<int>(WaveSpawnMode_Count))
        g_WaveSpawnReport.modeSuccesses[modeIdx]++;
    if (g_WaveSpawnReport.firstSuccessAt < 0.0)
        g_WaveSpawnReport.firstSuccessAt = now;
    g_WaveSpawnReport.lastSuccessAt = now;
    if (modeIdx >= view_as<int>(WaveSpawn_NormalNav)
        && modeIdx <= view_as<int>(WaveSpawn_NormalDirectorUnrestricted))
    {
        g_WaveSpawnReport.normalSuccesses++;
        if (g_WaveSpawnReport.firstNormalSuccessAt < 0.0)
            g_WaveSpawnReport.firstNormalSuccessAt = now;
        g_WaveSpawnReport.lastNormalSuccessAt = now;
    }
    return true;
}

static bool WaveSpawnReport_GetTargetGeometry(
    const float pos[3], int targetSurvivor,
    float &distance, float &verticalDelta)
{
    int target = targetSurvivor > 0
        ? targetSurvivor : gST.targetSurvivor;
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return false;

    float targetEye[3];
    if (!Visibility_GetClientEyeSnapshot(target, targetEye))
        GetClientEyePosition(target, targetEye);
    distance = GetVectorDistance(pos, targetEye);
    verticalDelta = pos[2] - targetEye[2];
    return true;
}

static void WaveSpawnReport_RecordVerticalDistance(bool success, float verticalDelta)
{
    if (!success || verticalDelta <= -9998.0)
        return;

    float absoluteDelta = FloatAbs(verticalDelta);
    g_WaveSpawnReport.verticalDistanceSamples++;
    g_WaveSpawnReport.verticalDistanceAbsTotal += absoluteDelta;
    g_WaveSpawnReport.verticalDistanceAbsMax = FloatMax(
        g_WaveSpawnReport.verticalDistanceAbsMax, absoluteDelta);
}

stock void WaveSpawnReport_RecordScored(
    int zc, int spawnedClient, WaveSpawnMode mode, float spawnCallMs,
    const float requestedPos[3], float minRange, float maxRange,
    SpawnScoreDbg score, int targetSurvivor = 0)
{
    if (!SpawnPerfConfig_ShowStats())
        return;

    float actualPos[3];
    int sequence;
    float waveElapsedMs;
    bool actualValid;
    bool success = WaveSpawnReport_RecordBase(
        zc, spawnedClient, mode, spawnCallMs, requestedPos,
        actualPos, sequence, waveElapsedMs, actualValid);
    if (!g_WaveSpawnReport.active)
        return;

    float targetDz = -9999.0;
    float currentTargetDistance;
    WaveSpawnReport_GetTargetGeometry(
        requestedPos, targetSurvivor, currentTargetDistance, targetDz);
    WaveSpawnReport_RecordVerticalDistance(success, targetDz);

    if (success)
    {
        g_WaveSpawnReport.scoredSuccesses++;
        g_WaveSpawnReport.scoreTotal += score.total;
        g_WaveSpawnReport.scoreMin = FloatMin(g_WaveSpawnReport.scoreMin, score.total);
        g_WaveSpawnReport.scoreMax = FloatMax(g_WaveSpawnReport.scoreMax, score.total);
        g_WaveSpawnReport.scoreBaseTotal += score.baseTotal;
        g_WaveSpawnReport.scoreDistTotal += score.dist;
        g_WaveSpawnReport.scoreHeightTotal += score.hght;
        g_WaveSpawnReport.scoreFlowTotal += score.flow;
        g_WaveSpawnReport.scoreDispTotal += score.dispScaled;
        g_WaveSpawnReport.scoreTacticalTotal += score.tacticalQuality;
        g_WaveSpawnReport.targetDistanceSamples++;
        g_WaveSpawnReport.targetDistanceTotal += score.dTargetEye;
        g_WaveSpawnReport.targetDistanceMin = FloatMin(
            g_WaveSpawnReport.targetDistanceMin, score.dTargetEye);
        g_WaveSpawnReport.targetDistanceMax = FloatMax(
            g_WaveSpawnReport.targetDistanceMax, score.dTargetEye);
        if (score.navDistance >= 0.0)
        {
            g_WaveSpawnReport.navDistanceSamples++;
            g_WaveSpawnReport.navDistanceTotal += score.navDistance;
            g_WaveSpawnReport.navDistanceMin = FloatMin(
                g_WaveSpawnReport.navDistanceMin, score.navDistance);
            g_WaveSpawnReport.navDistanceMax = FloatMax(
                g_WaveSpawnReport.navDistanceMax, score.navDistance);
        }
        if (score.navDistanceEffective >= 0.0)
        {
            g_WaveSpawnReport.navEffectiveDistanceSamples++;
            g_WaveSpawnReport.navEffectiveDistanceTotal += score.navDistanceEffective;
            g_WaveSpawnReport.navEffectiveDistanceMin = FloatMin(
                g_WaveSpawnReport.navEffectiveDistanceMin,
                score.navDistanceEffective);
            g_WaveSpawnReport.navEffectiveDistanceMax = FloatMax(
                g_WaveSpawnReport.navEffectiveDistanceMax,
                score.navDistanceEffective);
        }
        if (score.navHighGroundComp > 0.0)
        {
            g_WaveSpawnReport.navHighGroundCompSamples++;
            g_WaveSpawnReport.navHighGroundCompTotal += score.navHighGroundComp;
            g_WaveSpawnReport.navHighGroundCompMax = FloatMax(
                g_WaveSpawnReport.navHighGroundCompMax,
                score.navHighGroundComp);
        }
    }

    char modeName[40];
    WaveSpawnReport_GetModeName(mode, modeName, sizeof(modeName));
    float teamMinDistance = success
        ? SquareRoot(GetMinLiveEyeDistSquaredToAnySurvivor(actualPos)) : -1.0;
    SpawnPerf_Log(
        "[SpawnWave][Spawn] wave=%d seq=%d result=%s mode=%s class=%s entity=%d waveElapsedMs=%.1f spawnCallMs=%.3f request=(%.1f %.1f %.1f) actualValid=%d actual=(%.1f %.1f %.1f) targetDistance=%.1f teamMinDistance=%.1f targetDz=%.1f navDistance=%.1f navEffective=%.1f navHighComp=%.1f navRange=%.0f..%.0f score=%.2f base=%.2f dist=%.2f height=%.2f flow=%.2f dispersion=%.2f tactical=%.2f area=%d bucket=%d targetBucket=%d deltaFlow=%d rawBadFlow=%d target=%d",
        g_WaveSpawnReport.wave, sequence, success ? "success" : "failed",
        modeName, g_sInfectedClassNames[zc], spawnedClient,
        waveElapsedMs, spawnCallMs,
        requestedPos[0], requestedPos[1], requestedPos[2], actualValid ? 1 : 0,
        actualPos[0], actualPos[1], actualPos[2],
        score.dTargetEye, teamMinDistance, targetDz, score.navDistance,
        score.navDistanceEffective, score.navHighGroundComp,
        minRange, maxRange,
        score.total, score.baseTotal, score.dist, score.hght, score.flow,
        score.dispScaled, score.tacticalQuality, score.areaIdx,
        score.candBucket, score.centerBucket, score.deltaFlow,
        score.rawBadFlow ? 1 : 0,
        targetSurvivor > 0 ? targetSurvivor : gST.targetSurvivor);
}

stock void WaveSpawnReport_RecordFallback(
    int zc, int spawnedClient, WaveSpawnMode mode, float spawnCallMs,
    const float requestedPos[3], float minRange, float maxRange,
    int targetSurvivor = 0)
{
    if (!SpawnPerfConfig_ShowStats())
        return;

    float actualPos[3];
    int sequence;
    float waveElapsedMs;
    bool actualValid;
    bool success = WaveSpawnReport_RecordBase(
        zc, spawnedClient, mode, spawnCallMs, requestedPos,
        actualPos, sequence, waveElapsedMs, actualValid);
    if (!g_WaveSpawnReport.active)
        return;

    float targetDistance = -1.0;
    float targetDz = -9999.0;
    if (WaveSpawnReport_GetTargetGeometry(
        requestedPos, targetSurvivor, targetDistance, targetDz))
    {
        if (success)
        {
            g_WaveSpawnReport.targetDistanceSamples++;
            g_WaveSpawnReport.targetDistanceTotal += targetDistance;
            g_WaveSpawnReport.targetDistanceMin = FloatMin(
                g_WaveSpawnReport.targetDistanceMin, targetDistance);
            g_WaveSpawnReport.targetDistanceMax = FloatMax(
                g_WaveSpawnReport.targetDistanceMax, targetDistance);
        }
    }
    WaveSpawnReport_RecordVerticalDistance(success, targetDz);

    char modeName[40];
    WaveSpawnReport_GetModeName(mode, modeName, sizeof(modeName));
    float teamMinDistance = success
        ? SquareRoot(GetMinLiveEyeDistSquaredToAnySurvivor(actualPos)) : -1.0;
    SpawnPerf_Log(
        "[SpawnWave][Spawn] wave=%d seq=%d result=%s mode=%s class=%s entity=%d waveElapsedMs=%.1f spawnCallMs=%.3f request=(%.1f %.1f %.1f) actualValid=%d actual=(%.1f %.1f %.1f) targetDistance=%.1f teamMinDistance=%.1f targetDz=%.1f navDistance=N/A directRange=%.0f..%.0f score=N/A target=%d",
        g_WaveSpawnReport.wave, sequence, success ? "success" : "failed",
        modeName, g_sInfectedClassNames[zc], spawnedClient,
        waveElapsedMs, spawnCallMs,
        requestedPos[0], requestedPos[1], requestedPos[2], actualValid ? 1 : 0,
        actualPos[0], actualPos[1], actualPos[2],
        targetDistance, teamMinDistance, targetDz,
        minRange, maxRange,
        targetSurvivor > 0 ? targetSurvivor : gST.targetSurvivor);
}

stock void WaveSpawnReport_RecordFrameBurst(int attempts, float elapsedMs, bool budgetStop)
{
    if (!SpawnPerfConfig_ShowStats() || attempts <= 0)
        return;

    WaveSpawnReport_EnsureActive();
    if (!g_WaveSpawnReport.active)
        return;

    float clampedMs = FloatMax(0.0, elapsedMs);
    g_WaveSpawnReport.workFrames++;
    g_WaveSpawnReport.workAttempts += attempts;
    if (attempts > g_WaveSpawnReport.maxAttemptsPerFrame)
        g_WaveSpawnReport.maxAttemptsPerFrame = attempts;
    if (budgetStop)
        g_WaveSpawnReport.frameBudgetStops++;
    g_WaveSpawnReport.frameWorkTotalMs += clampedMs;
    if (clampedMs > g_WaveSpawnReport.frameWorkMaxMs)
        g_WaveSpawnReport.frameWorkMaxMs = clampedMs;
}

static void WaveSpawnReport_Print(const char[] reason, bool finalReport)
{
    if (!g_WaveSpawnReport.active || !SpawnPerfConfig_ShowStats())
        return;

    float now = GetGameTime();
    float durationMs = FloatMax(0.0, (now - g_WaveSpawnReport.startedAt) * 1000.0);
    float firstSpawnMs = (g_WaveSpawnReport.firstSuccessAt >= 0.0)
        ? (g_WaveSpawnReport.firstSuccessAt - g_WaveSpawnReport.startedAt) * 1000.0
        : -1.0;
    float lastSpawnMs = (g_WaveSpawnReport.lastSuccessAt >= 0.0)
        ? (g_WaveSpawnReport.lastSuccessAt - g_WaveSpawnReport.startedAt) * 1000.0
        : -1.0;
    float firstNormalSpawnMs = (g_WaveSpawnReport.firstNormalSuccessAt >= 0.0)
        ? (g_WaveSpawnReport.firstNormalSuccessAt - g_WaveSpawnReport.startedAt) * 1000.0
        : -1.0;
    float lastNormalSpawnMs = (g_WaveSpawnReport.lastNormalSuccessAt >= 0.0)
        ? (g_WaveSpawnReport.lastNormalSuccessAt - g_WaveSpawnReport.startedAt) * 1000.0
        : -1.0;
    float killPhaseMs = (g_WaveSpawnReport.countdownStartedAt >= 0.0)
        ? FloatMax(0.0, g_WaveSpawnReport.countdownStartedAt - g_WaveSpawnReport.startedAt) * 1000.0
        : -1.0;
    float countdownEnd = (g_WaveSpawnReport.holdStartedAt >= 0.0)
        ? g_WaveSpawnReport.holdStartedAt
        : now;
    float countdownMs = (g_WaveSpawnReport.countdownStartedAt >= 0.0)
        ? FloatMax(0.0, countdownEnd - g_WaveSpawnReport.countdownStartedAt) * 1000.0
        : -1.0;
    float holdEnd = (g_WaveSpawnReport.holdEndedAt >= 0.0)
        ? g_WaveSpawnReport.holdEndedAt
        : now;
    float holdMs = (g_WaveSpawnReport.holdStartedAt >= 0.0)
        ? FloatMax(0.0, holdEnd - g_WaveSpawnReport.holdStartedAt) * 1000.0
        : 0.0;
    float averageCallMs = (g_WaveSpawnReport.calls > 0)
        ? g_WaveSpawnReport.spawnCallTotalMs / float(g_WaveSpawnReport.calls)
        : 0.0;
    float attemptsPerFrameAvg = (g_WaveSpawnReport.workFrames > 0)
        ? float(g_WaveSpawnReport.workAttempts) / float(g_WaveSpawnReport.workFrames)
        : 0.0;
    float frameWorkAvgMs = (g_WaveSpawnReport.workFrames > 0)
        ? g_WaveSpawnReport.frameWorkTotalMs / float(g_WaveSpawnReport.workFrames)
        : 0.0;

    float p50 = 0.0;
    float p95 = 0.0;
    int sampleCount = g_WaveSpawnReport.spawnCallSampleCount;
    if (sampleCount > 0)
    {
        float sorted[WAVE_REPORT_API_SAMPLE_CAP];
        for (int i = 0; i < sampleCount; i++)
            sorted[i] = g_WaveSpawnReport.spawnCallSamples[i];
        SortFloats(sorted, sampleCount, Sort_Ascending);
        p50 = sorted[WaveSpawnReport_PercentileIndex(sampleCount, 0.50)];
        p95 = sorted[WaveSpawnReport_PercentileIndex(sampleCount, 0.95)];
    }

    SpawnPerf_Log(
        "[SpawnWave][Summary] state=%s reason=%s wave=%d durationMs=%.1f killPhaseMs=%.1f countdownMs=%.1f antiBaitExtendedMs=%.1f configuredIntervalMs=%.1f plannedAi=%d pendingAtStart=%d remainingQueue=%d spawnCalls=%d success=%d normalSuccess=%d failed=%d firstSpawnMs=%.1f lastSpawnMs=%.1f firstNormalSpawnMs=%.1f lastNormalSpawnMs=%.1f spawnCallAvgMs=%.3f p50=%.3f p95=%.3f max=%.3f samples=%d workFrames=%d workAttempts=%d attemptsPerFrameAvg=%.2f maxAttemptsFrame=%d frameWorkAvgMs=%.3f frameWorkMaxMs=%.3f budgetStops=%d",
        finalReport ? "final" : "snapshot", reason, g_WaveSpawnReport.wave,
        durationMs, killPhaseMs, countdownMs, holdMs,
        g_WaveSpawnReport.configuredIntervalMs,
        g_WaveSpawnReport.plannedAi, g_WaveSpawnReport.pendingAtStart,
        gST.siQueueCount, g_WaveSpawnReport.calls, g_WaveSpawnReport.successes,
        g_WaveSpawnReport.normalSuccesses, g_WaveSpawnReport.failures,
        firstSpawnMs, lastSpawnMs, firstNormalSpawnMs, lastNormalSpawnMs,
        averageCallMs,
        p50, p95, g_WaveSpawnReport.spawnCallMaxMs, sampleCount,
        g_WaveSpawnReport.workFrames, g_WaveSpawnReport.workAttempts,
        attemptsPerFrameAvg, g_WaveSpawnReport.maxAttemptsPerFrame,
        frameWorkAvgMs, g_WaveSpawnReport.frameWorkMaxMs,
        g_WaveSpawnReport.frameBudgetStops);
    SpawnPerf_Log(
        "[SpawnWave][Classes] wave=%d smoker=%d boomer=%d hunter=%d spitter=%d jockey=%d charger=%d modeSuccessCalls normalNav=%d/%d normalDirectorRange=%d/%d normalDirectorUnrestricted=%d/%d teleportNav=%d/%d teleportDirectorRange=%d/%d teleportDirectorUnrestricted=%d/%d",
        g_WaveSpawnReport.wave,
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Smoker) - 1],
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Boomer) - 1],
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Hunter) - 1],
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Spitter) - 1],
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Jockey) - 1],
        g_WaveSpawnReport.classSuccesses[view_as<int>(SI_Charger) - 1],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_NormalNav],
        g_WaveSpawnReport.modeCalls[WaveSpawn_NormalNav],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_NormalDirectorRange],
        g_WaveSpawnReport.modeCalls[WaveSpawn_NormalDirectorRange],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_NormalDirectorUnrestricted],
        g_WaveSpawnReport.modeCalls[WaveSpawn_NormalDirectorUnrestricted],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_TeleportNav],
        g_WaveSpawnReport.modeCalls[WaveSpawn_TeleportNav],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_TeleportDirectorRange],
        g_WaveSpawnReport.modeCalls[WaveSpawn_TeleportDirectorRange],
        g_WaveSpawnReport.modeSuccesses[WaveSpawn_TeleportDirectorUnrestricted],
        g_WaveSpawnReport.modeCalls[WaveSpawn_TeleportDirectorUnrestricted]);

    if (g_WaveSpawnReport.scoredSuccesses > 0)
    {
        float divisor = float(g_WaveSpawnReport.scoredSuccesses);
        SpawnPerf_Log(
            "[SpawnWave][Scores] wave=%d samples=%d avg=%.2f min=%.2f max=%.2f baseAvg=%.2f distAvg=%.2f heightAvg=%.2f flowAvg=%.2f dispersionAvg=%.2f tacticalAvg=%.2f",
            g_WaveSpawnReport.wave, g_WaveSpawnReport.scoredSuccesses,
            g_WaveSpawnReport.scoreTotal / divisor,
            g_WaveSpawnReport.scoreMin, g_WaveSpawnReport.scoreMax,
            g_WaveSpawnReport.scoreBaseTotal / divisor,
            g_WaveSpawnReport.scoreDistTotal / divisor,
            g_WaveSpawnReport.scoreHeightTotal / divisor,
            g_WaveSpawnReport.scoreFlowTotal / divisor,
            g_WaveSpawnReport.scoreDispTotal / divisor,
            g_WaveSpawnReport.scoreTacticalTotal / divisor);
    }
    else
    {
        SpawnPerf_Log("[SpawnWave][Scores] wave=%d samples=0 avg=N/A", g_WaveSpawnReport.wave);
    }

    if (g_WaveSpawnReport.targetDistanceSamples > 0)
    {
        SpawnPerf_Log(
            "[SpawnWave][Distances] wave=%d directSamples=%d directAvg=%.1f directMin=%.1f directMax=%.1f navSamples=%d navAvg=%.1f navMin=%.1f navMax=%.1f navEffectiveSamples=%d navEffectiveAvg=%.1f navEffectiveMin=%.1f navEffectiveMax=%.1f highCompSamples=%d highCompAvg=%.1f highCompMax=%.1f verticalSamples=%d absZAvg=%.1f absZMax=%.1f",
            g_WaveSpawnReport.wave, g_WaveSpawnReport.targetDistanceSamples,
            g_WaveSpawnReport.targetDistanceTotal
                / float(g_WaveSpawnReport.targetDistanceSamples),
            g_WaveSpawnReport.targetDistanceMin,
            g_WaveSpawnReport.targetDistanceMax,
            g_WaveSpawnReport.navDistanceSamples,
            g_WaveSpawnReport.navDistanceSamples > 0
                ? g_WaveSpawnReport.navDistanceTotal
                    / float(g_WaveSpawnReport.navDistanceSamples)
                : 0.0,
            g_WaveSpawnReport.navDistanceSamples > 0
                ? g_WaveSpawnReport.navDistanceMin : -1.0,
            g_WaveSpawnReport.navDistanceSamples > 0
                ? g_WaveSpawnReport.navDistanceMax : -1.0,
            g_WaveSpawnReport.navEffectiveDistanceSamples,
            g_WaveSpawnReport.navEffectiveDistanceSamples > 0
                ? g_WaveSpawnReport.navEffectiveDistanceTotal
                    / float(g_WaveSpawnReport.navEffectiveDistanceSamples)
                : 0.0,
            g_WaveSpawnReport.navEffectiveDistanceSamples > 0
                ? g_WaveSpawnReport.navEffectiveDistanceMin : -1.0,
            g_WaveSpawnReport.navEffectiveDistanceSamples > 0
                ? g_WaveSpawnReport.navEffectiveDistanceMax : -1.0,
            g_WaveSpawnReport.navHighGroundCompSamples,
            g_WaveSpawnReport.navHighGroundCompSamples > 0
                ? g_WaveSpawnReport.navHighGroundCompTotal
                    / float(g_WaveSpawnReport.navHighGroundCompSamples)
                : 0.0,
            g_WaveSpawnReport.navHighGroundCompMax,
            g_WaveSpawnReport.verticalDistanceSamples,
            g_WaveSpawnReport.verticalDistanceSamples > 0
                ? g_WaveSpawnReport.verticalDistanceAbsTotal
                    / float(g_WaveSpawnReport.verticalDistanceSamples)
                : 0.0,
            g_WaveSpawnReport.verticalDistanceAbsMax);
    }
    else
    {
        SpawnPerf_Log(
            "[SpawnWave][Distances] wave=%d samples=0 avg=N/A",
            g_WaveSpawnReport.wave);
    }
}

stock void WaveSpawnReport_PrintCurrent()
{
    WaveSpawnReport_EnsureActive();
    WaveSpawnReport_Print("sm_spawnperf", false);
}

stock void WaveSpawnReport_End(const char[] reason)
{
    WaveSpawnReport_Print(reason, true);
    g_WaveSpawnReport.Reset();
}

stock void WaveSpawnReport_Reset()
{
    g_WaveSpawnReport.Reset();
}
