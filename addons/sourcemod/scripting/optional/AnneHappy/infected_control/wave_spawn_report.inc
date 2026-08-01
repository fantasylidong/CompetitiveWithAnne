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
    int failures;
    int scoredSuccesses;
    int classSuccesses[SI_COUNT];
    int modeCalls[WaveSpawnMode_Count];
    int modeSuccesses[WaveSpawnMode_Count];
    float startedAt;
    float firstSuccessAt;
    float lastSuccessAt;
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

    void Reset()
    {
        this.active = false;
        this.wave = 0;
        this.plannedAi = 0;
        this.pendingAtStart = 0;
        this.calls = 0;
        this.successes = 0;
        this.failures = 0;
        this.scoredSuccesses = 0;
        this.startedAt = 0.0;
        this.firstSuccessAt = -1.0;
        this.lastSuccessAt = -1.0;
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

    SpawnPerf_Log(
        "[SpawnWave][Begin] wave=%d plannedAi=%d pendingAtStart=%d alive=%d cap=%d target=%d breach=%d",
        wave, plannedAi, pendingAtStart, gST.totalSI, gCV.iSiLimit,
        gST.targetSurvivor, gST.breachWaveActive ? 1 : 0);
}

stock void WaveSpawnReport_Begin(int wave, int plannedAi,
                                 int pendingAtStart, float startedAt)
{
    WaveSpawnReport_BeginInternal(wave, plannedAi, pendingAtStart, startedAt);
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
    return true;
}

stock void WaveSpawnReport_RecordScored(
    int zc, int spawnedClient, WaveSpawnMode mode, float spawnCallMs,
    const float requestedPos[3], SpawnScoreDbg score)
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
    }

    char modeName[40];
    WaveSpawnReport_GetModeName(mode, modeName, sizeof(modeName));
    SpawnPerf_Log(
        "[SpawnWave][Spawn] wave=%d seq=%d result=%s mode=%s class=%s entity=%d waveElapsedMs=%.1f spawnCallMs=%.3f request=(%.1f %.1f %.1f) actualValid=%d actual=(%.1f %.1f %.1f) score=%.2f base=%.2f dist=%.2f height=%.2f flow=%.2f dispersion=%.2f tactical=%.2f area=%d bucket=%d target=%d",
        g_WaveSpawnReport.wave, sequence, success ? "success" : "failed",
        modeName, g_sInfectedClassNames[zc], spawnedClient,
        waveElapsedMs, spawnCallMs,
        requestedPos[0], requestedPos[1], requestedPos[2], actualValid ? 1 : 0,
        actualPos[0], actualPos[1], actualPos[2],
        score.total, score.baseTotal, score.dist, score.hght, score.flow,
        score.dispScaled, score.tacticalQuality, score.areaIdx,
        score.candBucket, gST.targetSurvivor);
}

stock void WaveSpawnReport_RecordFallback(
    int zc, int spawnedClient, WaveSpawnMode mode, float spawnCallMs,
    const float requestedPos[3])
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

    char modeName[40];
    WaveSpawnReport_GetModeName(mode, modeName, sizeof(modeName));
    SpawnPerf_Log(
        "[SpawnWave][Spawn] wave=%d seq=%d result=%s mode=%s class=%s entity=%d waveElapsedMs=%.1f spawnCallMs=%.3f request=(%.1f %.1f %.1f) actualValid=%d actual=(%.1f %.1f %.1f) score=N/A target=%d",
        g_WaveSpawnReport.wave, sequence, success ? "success" : "failed",
        modeName, g_sInfectedClassNames[zc], spawnedClient,
        waveElapsedMs, spawnCallMs,
        requestedPos[0], requestedPos[1], requestedPos[2], actualValid ? 1 : 0,
        actualPos[0], actualPos[1], actualPos[2], gST.targetSurvivor);
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
    float averageCallMs = (g_WaveSpawnReport.calls > 0)
        ? g_WaveSpawnReport.spawnCallTotalMs / float(g_WaveSpawnReport.calls)
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
        "[SpawnWave][Summary] state=%s reason=%s wave=%d durationMs=%.1f plannedAi=%d pendingAtStart=%d remainingQueue=%d spawnCalls=%d success=%d failed=%d firstSpawnMs=%.1f lastSpawnMs=%.1f spawnCallAvgMs=%.3f p50=%.3f p95=%.3f max=%.3f samples=%d",
        finalReport ? "final" : "snapshot", reason, g_WaveSpawnReport.wave,
        durationMs, g_WaveSpawnReport.plannedAi, g_WaveSpawnReport.pendingAtStart,
        gST.siQueueCount, g_WaveSpawnReport.calls, g_WaveSpawnReport.successes,
        g_WaveSpawnReport.failures, firstSpawnMs, lastSpawnMs, averageCallMs,
        p50, p95, g_WaveSpawnReport.spawnCallMaxMs, sampleCount);
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
