#if defined _infected_control_spawn_perf_optimizer_included
    #endinput
#endif
#define _infected_control_spawn_perf_optimizer_included

/**
 * 刷点性能优化器
 *
 * 核心优化策略：
 * 1. 早期过滤：在评分前就淘汰明显不合格的候选点
 * 2. 渐进式采样：从粗到细，找到足够好的点就停止
 * 3. 缓存复用：高度、距离等计算结果缓存
 * 4. 智能桶序：优先扫描最有可能的桶
 */

// ==================== 性能统计 ====================
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

        LogMsg("[PerfStats] attempts=%d success=%d filters=(flags:%d dist:%d vis:%d bucket:%d) fullEval=%d avgTime=%.2fms",
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

// ==================== 智能桶序优化 ====================

/**
 * 根据扩圈距离智能调整桶窗口
 * 原理：距离越大，生还者附近的桶越多，需要更窄的窗口避免过度扫描
 */
stock int ComputeAdaptiveBucketWindow(float searchRange, int baseWindow)
{
    // 基于扩圈比例动态缩小窗口
    float ratio = searchRange / gCV.fSpawnMax;
    if (ratio < 0.5)
        return baseWindow; // 近距离，保持原窗口

    if (ratio < 0.75)
        return RoundToFloor(float(baseWindow) * 0.85); // 中距离，缩小15%

    return RoundToFloor(float(baseWindow) * 0.70); // 远距离，缩小30%
}

/**
 * 优化的桶序生成：优先中心±1，然后跳跃式扩展
 * 原理：大部分情况下，生还者附近±1-2个桶就能找到合适刷点
 */
stock int BuildOptimizedBucketOrder(int centerBucket, int window, bool includeCenter, int outBuckets[FLOW_BUCKETS])
{
    int n = 0;

    // 阶段1：中心 ± 1（最有可能）
    if (includeCenter && n < FLOW_BUCKETS)
        outBuckets[n++] = centerBucket;

    for (int offset = 1; offset <= 1 && n < FLOW_BUCKETS; offset++)
    {
        int fwd = centerBucket + offset;
        if (fwd >= 0 && fwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = fwd;

        int bwd = centerBucket - offset;
        if (bwd >= 0 && bwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = bwd;
    }

    // 阶段2：跳跃式扫描（2, 4, 6...）避免连续桶浪费
    for (int offset = 2; offset <= window && n < FLOW_BUCKETS; offset += 2)
    {
        int fwd = centerBucket + offset;
        if (fwd >= 0 && fwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = fwd;

        int bwd = centerBucket - offset;
        if (bwd >= 0 && bwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = bwd;
    }

    // 阶段3：填补缺失的奇数偏移
    for (int offset = 3; offset <= window && n < FLOW_BUCKETS; offset += 2)
    {
        int fwd = centerBucket + offset;
        if (fwd >= 0 && fwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = fwd;

        int bwd = centerBucket - offset;
        if (bwd >= 0 && bwd <= 100 && n < FLOW_BUCKETS)
            outBuckets[n++] = bwd;
    }

    return n;
}

// ==================== 早期过滤优化 ====================

/**
 * 快速距离预检：使用包围盒 + 平方距离避免昂贵的sqrt
 */
stock bool QuickDistancePrecheck(const float pos[3], const float targetPos[3], float minDist, float maxDist)
{
    // 包围盒检查（非常快）
    float dx = pos[0] - targetPos[0];
    float dy = pos[1] - targetPos[1];

    float maxComponent = FloatMax(FloatAbs(dx), FloatAbs(dy));
    if (maxComponent > maxDist + 200.0) // 保守估计，加200容差
        return false;

    // 平方距离检查（避免sqrt）
    float dist2 = dx * dx + dy * dy;
    float minDist2 = minDist * minDist;
    float maxDist2 = (maxDist + 200.0) * (maxDist + 200.0);

    return (dist2 >= minDist2 * 0.81 && dist2 <= maxDist2); // 0.81 = 0.9^2，预留10%容差
}

/**
 * 批量可见性检查：一次扫描多个候选点（利用CPU缓存）
 * 注意：此函数为示例，实际使用需要根据具体情况调整
 */
/*
stock int BatchVisibilityCheck(float positions[][], int count, bool teleportMode, bool results[])
{
    int passed = 0;
    for (int i = 0; i < count; i++)
    {
        results[i] = !IsPosVisibleSDK(positions[i], teleportMode);
        if (results[i])
            passed++;
    }
    return passed;
}
*/

// ==================== 渐进式采样优化 ====================

/**
 * 渐进式采样：从粗到细，找到足够好就停止
 *
 * 策略：
 * - 第1轮：每个桶采样1个NavArea，评估前3个桶
 * - 第2轮：如果没找到，每个桶采样2个，评估前5个桶
 * - 第3轮：全面扫描
 */

enum SamplingStage
{
    Stage_Quick = 1,      // 快速采样：1个/桶，前3桶
    Stage_Normal = 2,     // 正常采样：2个/桶，前5桶
    Stage_Exhaustive = 3  // 穷尽采样：全部
}

stock int GetSamplingBudgetForStage(SamplingStage stage)
{
    switch (stage)
    {
        case Stage_Quick:     return 3;
        case Stage_Normal:    return 8;
        case Stage_Exhaustive: return DifficultyStrategy_GetCandidateBudget();
    }
    return 8;
}

stock int GetMaxBucketsForStage(SamplingStage stage)
{
    switch (stage)
    {
        case Stage_Quick:     return 3;
        case Stage_Normal:    return 5;
        case Stage_Exhaustive: return 999;
    }
    return 5;
}

stock int GetSamplesPerBucketForStage(SamplingStage stage)
{
    switch (stage)
    {
        case Stage_Quick:     return 1;
        case Stage_Normal:    return 2;
        case Stage_Exhaustive: return 4;
    }
    return 2;
}

// ==================== 性能监控 ====================

stock void SpawnPerf_OnRoundStart()
{
    g_PerfStats.Reset();
}

stock void SpawnPerf_OnMapEnd()
{
    g_PerfStats.Print();
}

stock void SpawnPerf_RecordFilterByFlags()
{
    g_PerfStats.earlyFilteredByFlags++;
}

stock void SpawnPerf_RecordFilterByDist()
{
    g_PerfStats.earlyFilteredByDist++;
}

stock void SpawnPerf_RecordFilterByVisibility()
{
    g_PerfStats.earlyFilteredByVisibility++;
}

stock void SpawnPerf_RecordFilterByBucket()
{
    g_PerfStats.earlyFilteredByBucket++;
}

stock void SpawnPerf_RecordFullEvaluation()
{
    g_PerfStats.fullEvaluations++;
}

stock void SpawnPerf_RecordAttempt(float timeMs, bool success)
{
    g_PerfStats.RecordAttempt(timeMs, success);
}

stock void SpawnPerf_PrintStats()
{
    g_PerfStats.Print();
}

stock void SpawnPerf_ResetStats()
{
    g_PerfStats.Reset();
}
