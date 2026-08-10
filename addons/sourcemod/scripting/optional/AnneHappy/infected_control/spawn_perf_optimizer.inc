#if defined _infected_control_spawn_perf_optimizer_included
    #endinput
#endif
#define _infected_control_spawn_perf_optimizer_included

/**
 * 刷点性能统计器
 *
 * 热路径只记录定长样本和过滤计数；排序、百分位和波次总结只在
 * 显式打印或波次结束时计算。
 */

// ==================== 性能统计 ====================
#define SPAWN_PERF_GROUP_COUNT       5
#define SPAWN_PERF_TIMING_COUNT      3
#define SPAWN_PERF_FILTER_COUNT      13
#define SPAWN_PERF_SAMPLE_CAP        256

stock void SpawnPerf_Log(const char[] format, any ...)
{
    if (!SpawnPerfConfig_ShowStats())
        return;

    char buffer[1024];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogToFile("addons/sourcemod/logs/infected_control_fdxxnav.txt", "%s", buffer);
    if (gCV.iDebugMode >= 2)
        PrintToServer("[IC] %s", buffer);
}

enum SpawnPerfTimingMetric
{
    SpawnPerfTiming_CandidateBuild = 0,
    SpawnPerfTiming_MaxSlice,
    SpawnPerfTiming_FallbackApi
}

enum SpawnPerfFilterKind
{
    SpawnPerfFilter_Cooldown = 0,
    SpawnPerfFilter_PendingSameNav,
    SpawnPerfFilter_Flags,
    SpawnPerfFilter_Flow,
    SpawnPerfFilter_Distance,
    SpawnPerfFilter_Separation,
    SpawnPerfFilter_PendingSeparation,
    SpawnPerfFilter_Stuck,
    SpawnPerfFilter_Visibility,
    SpawnPerfFilter_Path,
    SpawnPerfFilter_Position,
    SpawnPerfFilter_Score,
    SpawnPerfFilter_Bucket
}

// 热路径只做定长数组写入；排序和百分位计算仅发生在显式打印统计时。
static float g_SpawnPerfTimingSamples[SPAWN_PERF_GROUP_COUNT][SPAWN_PERF_TIMING_COUNT][SPAWN_PERF_SAMPLE_CAP];
static int g_SpawnPerfTimingWrite[SPAWN_PERF_GROUP_COUNT][SPAWN_PERF_TIMING_COUNT];
static int g_SpawnPerfTimingCount[SPAWN_PERF_GROUP_COUNT][SPAWN_PERF_TIMING_COUNT];
static int g_SpawnPerfTimingTotal[SPAWN_PERF_GROUP_COUNT][SPAWN_PERF_TIMING_COUNT];
static int g_SpawnPerfFilterHits[SPAWN_PERF_GROUP_COUNT][SPAWN_PERF_FILTER_COUNT];
static int g_SpawnPerfFallbackCalls[SPAWN_PERF_GROUP_COUNT][SI_COUNT];
static int g_SpawnPerfFallbackHits[SPAWN_PERF_GROUP_COUNT][SI_COUNT];
static float g_SpawnPerfPendingMaxSliceMs;
static int g_SpawnPerfPendingSliceGroup = -1;

static int SpawnPerf_GetCurrentGroup()
{
    int limit = gCV.iSiLimit;
    if (limit <= 6)  return 0;
    if (limit <= 8)  return 1;
    if (limit <= 10) return 2;
    if (limit <= 12) return 3;
    return 4;
}

static void SpawnPerf_GetGroupLabel(int group, char[] label, int maxlen)
{
    switch (group)
    {
        case 0: strcopy(label, maxlen, "6SI");
        case 1: strcopy(label, maxlen, "8SI");
        case 2: strcopy(label, maxlen, "10SI");
        case 3: strcopy(label, maxlen, "12SI");
        default: strcopy(label, maxlen, "14+SI");
    }
}

static void SpawnPerf_RecordTiming(SpawnPerfTimingMetric metric, float timeMs)
{
    if (!SpawnPerfConfig_ShowStats())
        return;
    int group = SpawnPerf_GetCurrentGroup();
    int metricIdx = view_as<int>(metric);
    int write = g_SpawnPerfTimingWrite[group][metricIdx];

    g_SpawnPerfTimingSamples[group][metricIdx][write] = FloatMax(0.0, timeMs);
    g_SpawnPerfTimingWrite[group][metricIdx] = (write + 1) % SPAWN_PERF_SAMPLE_CAP;
    if (g_SpawnPerfTimingCount[group][metricIdx] < SPAWN_PERF_SAMPLE_CAP)
        g_SpawnPerfTimingCount[group][metricIdx]++;
    g_SpawnPerfTimingTotal[group][metricIdx]++;
}

static void SpawnPerf_RecordFilter(SpawnPerfFilterKind filter)
{
    if (!SpawnPerfConfig_ShowStats())
        return;
    g_SpawnPerfFilterHits[SpawnPerf_GetCurrentGroup()][view_as<int>(filter)]++;
}

static void SpawnPerf_FlushPendingMaxSlice()
{
    if (g_SpawnPerfPendingSliceGroup < 0)
        return;

    int currentGroup = SpawnPerf_GetCurrentGroup();
    if (currentGroup == g_SpawnPerfPendingSliceGroup)
    {
        SpawnPerf_RecordTiming(SpawnPerfTiming_MaxSlice, g_SpawnPerfPendingMaxSliceMs);
    }
    else
    {
        // SI 上限通常不会在一次搜索中变化；若变化，仍把样本记回搜索开始时的档位。
        int metricIdx = view_as<int>(SpawnPerfTiming_MaxSlice);
        int write = g_SpawnPerfTimingWrite[g_SpawnPerfPendingSliceGroup][metricIdx];
        g_SpawnPerfTimingSamples[g_SpawnPerfPendingSliceGroup][metricIdx][write] = g_SpawnPerfPendingMaxSliceMs;
        g_SpawnPerfTimingWrite[g_SpawnPerfPendingSliceGroup][metricIdx] = (write + 1) % SPAWN_PERF_SAMPLE_CAP;
        if (g_SpawnPerfTimingCount[g_SpawnPerfPendingSliceGroup][metricIdx] < SPAWN_PERF_SAMPLE_CAP)
            g_SpawnPerfTimingCount[g_SpawnPerfPendingSliceGroup][metricIdx]++;
        g_SpawnPerfTimingTotal[g_SpawnPerfPendingSliceGroup][metricIdx]++;
    }

    g_SpawnPerfPendingMaxSliceMs = 0.0;
    g_SpawnPerfPendingSliceGroup = -1;
}

static int SpawnPerf_PercentileIndex(int count, float percentile)
{
    int index = RoundToCeil(float(count) * percentile) - 1;
    if (index < 0) index = 0;
    if (index >= count) index = count - 1;
    return index;
}

static void SpawnPerf_PrintTiming(int group, SpawnPerfTimingMetric metric, const char[] metricName)
{
    int metricIdx = view_as<int>(metric);
    int count = g_SpawnPerfTimingCount[group][metricIdx];
    char groupLabel[8];
    SpawnPerf_GetGroupLabel(group, groupLabel, sizeof(groupLabel));

    if (count <= 0)
    {
        SpawnPerf_Log("[SpawnPerf][%s] %s samples=0 total=0", groupLabel, metricName);
        return;
    }

    float sorted[SPAWN_PERF_SAMPLE_CAP];
    for (int i = 0; i < count; i++)
        sorted[i] = g_SpawnPerfTimingSamples[group][metricIdx][i];
    SortFloats(sorted, count, Sort_Ascending);

    float p50 = sorted[SpawnPerf_PercentileIndex(count, 0.50)];
    float p95 = sorted[SpawnPerf_PercentileIndex(count, 0.95)];
    float p99 = sorted[SpawnPerf_PercentileIndex(count, 0.99)];
    float maxMs = sorted[count - 1];
    SpawnPerf_Log("[SpawnPerf][%s] %s samples=%d total=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f",
        groupLabel, metricName, count, g_SpawnPerfTimingTotal[group][metricIdx],
        p50, p95, p99, maxMs);
}

static void SpawnPerf_PrintGroupedStats()
{
    for (int group = 0; group < SPAWN_PERF_GROUP_COUNT; group++)
    {
        char groupLabel[8];
        SpawnPerf_GetGroupLabel(group, groupLabel, sizeof(groupLabel));

        SpawnPerf_PrintTiming(group, SpawnPerfTiming_CandidateBuild, "candidateBuildMs");
        SpawnPerf_PrintTiming(group, SpawnPerfTiming_MaxSlice, "maxSliceMs");
        SpawnPerf_PrintTiming(group, SpawnPerfTiming_FallbackApi, "fallbackApiMs");

        SpawnPerf_Log("[SpawnPerf][%s] filters cooldown=%d pendingSameNav=%d flags=%d flow=%d distance=%d separation=%d pendingSeparation=%d stuck=%d visibility=%d path=%d position=%d score=%d bucket=%d",
            groupLabel,
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Cooldown],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_PendingSameNav],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Flags],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Flow],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Distance],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Separation],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_PendingSeparation],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Stuck],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Visibility],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Path],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Position],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Score],
            g_SpawnPerfFilterHits[group][SpawnPerfFilter_Bucket]);

        SpawnPerf_Log("[SpawnPerf][%s] fallbackApi hit/call smoker=%d/%d boomer=%d/%d hunter=%d/%d spitter=%d/%d jockey=%d/%d charger=%d/%d",
            groupLabel,
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Smoker) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Smoker) - 1],
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Boomer) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Boomer) - 1],
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Hunter) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Hunter) - 1],
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Spitter) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Spitter) - 1],
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Jockey) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Jockey) - 1],
            g_SpawnPerfFallbackHits[group][view_as<int>(SI_Charger) - 1], g_SpawnPerfFallbackCalls[group][view_as<int>(SI_Charger) - 1]);
    }
}

static void SpawnPerf_ResetGroupedStats()
{
    g_SpawnPerfPendingMaxSliceMs = 0.0;
    g_SpawnPerfPendingSliceGroup = -1;

    for (int group = 0; group < SPAWN_PERF_GROUP_COUNT; group++)
    {
        for (int metric = 0; metric < SPAWN_PERF_TIMING_COUNT; metric++)
        {
            g_SpawnPerfTimingWrite[group][metric] = 0;
            g_SpawnPerfTimingCount[group][metric] = 0;
            g_SpawnPerfTimingTotal[group][metric] = 0;
        }
        for (int filter = 0; filter < SPAWN_PERF_FILTER_COUNT; filter++)
            g_SpawnPerfFilterHits[group][filter] = 0;
        for (int zc = 0; zc < SI_COUNT; zc++)
        {
            g_SpawnPerfFallbackCalls[group][zc] = 0;
            g_SpawnPerfFallbackHits[group][zc] = 0;
        }
    }
}

enum struct SpawnPerfStats
{
    int totalAttempts;
    int earlyFilteredByFlags;
    int earlyFilteredByDist;
    int earlyFilteredByVisibility;
    int earlyFilteredByBucket;
    int fullEvaluations;
    int successfulSpawns;
    float totalTimeMs;
    float avgTimePerAttempt;

    void Reset()
    {
        this.totalAttempts = 0;
        this.earlyFilteredByFlags = 0;
        this.earlyFilteredByDist = 0;
        this.earlyFilteredByVisibility = 0;
        this.earlyFilteredByBucket = 0;
        this.fullEvaluations = 0;
        this.successfulSpawns = 0;
        this.totalTimeMs = 0.0;
        this.avgTimePerAttempt = 0.0;
    }

    void RecordAttempt(float timeMs, bool success)
    {
        this.totalAttempts++;
        this.totalTimeMs += timeMs;
        if (success)
            this.successfulSpawns++;
        if (this.totalAttempts > 0)
            this.avgTimePerAttempt = this.totalTimeMs / float(this.totalAttempts);
    }

    void Print()
    {
        if (this.totalAttempts <= 0)
            return;

        SpawnPerf_Log("[PerfStats] attempts=%d success=%d filters=(flags:%d dist:%d vis:%d bucket:%d) fullEval=%d avgTime=%.2fms",
            this.totalAttempts,
            this.successfulSpawns,
            this.earlyFilteredByFlags,
            this.earlyFilteredByDist,
            this.earlyFilteredByVisibility,
            this.earlyFilteredByBucket,
            this.fullEvaluations,
            this.avgTimePerAttempt);
    }
}

// 全局性能统计实例
static SpawnPerfStats g_PerfStats;

// ==================== 性能监控 ====================

stock void SpawnPerf_OnRoundStart()
{
    WaveSpawnReport_Reset();
    g_PerfStats.Reset();
    SpawnPerf_ResetGroupedStats();
    SpawnAccel_ResetCandidatePerf();
    Visibility_ClearEyeSnapshot();
}

stock void SpawnPerf_OnMapEnd()
{
    SpawnPerf_FlushPendingMaxSlice();
    g_PerfStats.Print();
    SpawnPerf_PrintGroupedStats();
    SpawnAccel_PrintCandidatePerf();
    Visibility_ClearEyeSnapshot();
}

stock void SpawnPerf_RecordFilterByFlags()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    g_PerfStats.earlyFilteredByFlags++;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Flags);
}

stock void SpawnPerf_RecordFilterByDist()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    g_PerfStats.earlyFilteredByDist++;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Distance);
}

stock void SpawnPerf_RecordFilterByVisibility()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    g_PerfStats.earlyFilteredByVisibility++;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Visibility);
}

stock void SpawnPerf_RecordFilterByBucket()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    g_PerfStats.earlyFilteredByBucket++;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Bucket);
}

stock void SpawnPerf_RecordFilterByCooldown()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Cooldown);
}

stock void SpawnPerf_RecordFilterByPendingSameNav()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_PendingSameNav);
}

stock void SpawnPerf_RecordFilterByFlow()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Flow);
}

stock void SpawnPerf_RecordFilterBySeparation()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Separation);
}

stock void SpawnPerf_RecordFilterByPendingSeparation()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_PendingSeparation);
}

stock void SpawnPerf_RecordFilterByStuck()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Stuck);
}

stock void SpawnPerf_RecordFilterByPath()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Path);
}

stock void SpawnPerf_RecordFilterByPosition()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Position);
}

stock void SpawnPerf_RecordFilterByScore()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordFilter(SpawnPerfFilter_Score);
}

stock void SpawnPerf_RecordFullEvaluation()
{
    if (!SpawnPerfConfig_ShowStats()) return;
    g_PerfStats.fullEvaluations++;
}

stock void SpawnPerf_RecordAttempt(float timeMs, bool success)
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_FlushPendingMaxSlice();
    g_PerfStats.RecordAttempt(timeMs, success);
}

// 以下接口只记录观测数据，不参与候选资格、次数、距离或职业决策。
stock void SpawnPerf_RecordCandidateBuildMs(float timeMs)
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_FlushPendingMaxSlice();
    SpawnPerf_RecordTiming(SpawnPerfTiming_CandidateBuild, timeMs);
}

stock void SpawnPerf_RecordMaxSliceMs(float timeMs)
{
    if (!SpawnPerfConfig_ShowStats()) return;
    SpawnPerf_RecordTiming(SpawnPerfTiming_MaxSlice, timeMs);
}

stock void SpawnPerf_RecordCandidateBuild(float timeMs)
{
    SpawnPerf_RecordCandidateBuildMs(timeMs);
}

stock void SpawnPerf_RecordSlice(float timeMs)
{
    if (!SpawnPerfConfig_ShowStats()) return;
    int group = SpawnPerf_GetCurrentGroup();
    if (g_SpawnPerfPendingSliceGroup >= 0 && g_SpawnPerfPendingSliceGroup != group)
        SpawnPerf_FlushPendingMaxSlice();

    if (g_SpawnPerfPendingSliceGroup < 0)
    {
        g_SpawnPerfPendingSliceGroup = group;
        g_SpawnPerfPendingMaxSliceMs = FloatMax(0.0, timeMs);
    }
    else if (timeMs > g_SpawnPerfPendingMaxSliceMs)
    {
        g_SpawnPerfPendingMaxSliceMs = timeMs;
    }
}

stock void SpawnPerf_RecordFallbackApiMs(float timeMs, bool hit, int zc)
{
    if (!SpawnPerfConfig_ShowStats()) return;
    int group = SpawnPerf_GetCurrentGroup();
    SpawnPerf_RecordTiming(SpawnPerfTiming_FallbackApi, timeMs);

    if (zc < 1 || zc > SI_COUNT)
        return;

    int classIdx = zc - 1;
    g_SpawnPerfFallbackCalls[group][classIdx]++;
    if (hit)
        g_SpawnPerfFallbackHits[group][classIdx]++;
}

stock void SpawnPerf_PrintStats()
{
    SpawnPerf_FlushPendingMaxSlice();
    g_PerfStats.Print();
    SpawnPerf_PrintGroupedStats();
    SpawnAccel_PrintCandidatePerf();
    WaveSpawnReport_PrintCurrent();
}

stock void SpawnPerf_ResetStats()
{
    WaveSpawnReport_Reset();
    g_PerfStats.Reset();
    SpawnPerf_ResetGroupedStats();
    SpawnAccel_ResetCandidatePerf();
}
