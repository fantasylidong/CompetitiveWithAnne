#if defined _infected_control_leftdhooks_pvs_included
    #endinput
#endif
#define _infected_control_leftdhooks_pvs_included

/**
 * leftdhooks PVS 优化模块
 * 使用新的 PVS (Potentially Visible Set) natives 给候选点做粗筛。
 *
 * 重要边界：
 * - L4D_IsCompletelyVisibleToTeam 只过滤“整块 NavArea 完全暴露”的区域。
 * - PVS 只能证明候选点“不可能被看见”，不能证明“真的安全”。
 * - 因此 PVS 命中时仍要继续 IsPosVisibleSDK；只有不在任何生还者 PVS 内时才跳过旧 trace。
 */

// ==================== 全局变量 ====================

// PVS 功能可用性检测
bool g_bPVSNativesAvailable = false;
bool g_bNavAreaCompleteVisNativeAvailable = false;

// 生还者 PVS 缓存。PVS 只能证明“不可能可见”，不能证明“真的看见”。
#define PVS_SURVIVOR_CACHE_SLOTS 8
static int g_SurvivorPVSBuffer[PVS_SURVIVOR_CACHE_SLOTS][PVS_BUFFER_SIZE];
static int g_SurvivorPVSClient[PVS_SURVIVOR_CACHE_SLOTS];
static int g_SurvivorPVSCluster[PVS_SURVIVOR_CACHE_SLOTS];
static bool g_SurvivorPVSReady[PVS_SURVIVOR_CACHE_SLOTS];
static int g_SurvivorPVSCount = 0;
float g_LastPVSCheckTime = 0.0;
const float PVS_CACHE_TTL = 0.20;

#define PVS_AUTO_WINDOW_CHECKS 128
#define PVS_AUTO_MIN_SKIP_PERCENT 20

// 统计信息
int g_PVSNavAreaFiltered = 0;
int g_PVSPointChecks = 0;
int g_PVSPointNeedsTrace = 0;
int g_PVSPointTraceSkipped = 0;
int g_PVSBufferRebuilds = 0;
int g_PVSAutoDisabledCount = 0;

static bool g_PVSRuntimeEnabled = true;
static int g_PVSWindowChecks = 0;
static int g_PVSWindowSkipped = 0;

// ==================== 初始化 ====================

void LeftDHooks_PVS_Init()
{
    // 检测 PVS natives 是否可用
    g_bPVSNativesAvailable = (
        GetFeatureStatus(FeatureType_Native, "L4D_GetClusterForOrigin") == FeatureStatus_Available &&
        GetFeatureStatus(FeatureType_Native, "L4D_GetPVSForCluster") == FeatureStatus_Available
    );

    g_bNavAreaCompleteVisNativeAvailable = (
        GetFeatureStatus(FeatureType_Native, "L4D_IsCompletelyVisibleToTeam") == FeatureStatus_Available
    );

    if (g_bPVSNativesAvailable || g_bNavAreaCompleteVisNativeAvailable)
    {
        LogMessage("[IC-PVS] leftdhooks PVS natives available: PVS=%s NavAreaCompleteVis=%s",
            g_bPVSNativesAvailable ? "YES" : "NO",
            g_bNavAreaCompleteVisNativeAvailable ? "YES" : "NO");
    }
    else
    {
        LogMessage("[IC-PVS] leftdhooks PVS natives NOT available - using legacy visibility checks");
    }

    InvalidateSurvivorPVSCache();
}

void LeftDHooks_PVS_OnMapEnd()
{
    InvalidateSurvivorPVSCache();
    g_PVSNavAreaFiltered = 0;
    g_PVSPointChecks = 0;
    g_PVSPointNeedsTrace = 0;
    g_PVSPointTraceSkipped = 0;
    g_PVSBufferRebuilds = 0;
    g_PVSAutoDisabledCount = 0;
}

// ==================== PVS 缓存管理 ====================

void InvalidateSurvivorPVSCache()
{
    for (int i = 0; i < PVS_SURVIVOR_CACHE_SLOTS; i++)
    {
        g_SurvivorPVSReady[i] = false;
        g_SurvivorPVSClient[i] = 0;
        g_SurvivorPVSCluster[i] = -1;
    }
    g_SurvivorPVSCount = 0;
    g_LastPVSCheckTime = 0.0;
}

static void LeftDHooks_PVS_ResetRuntimeGuard()
{
    g_PVSRuntimeEnabled = true;
    g_PVSWindowChecks = 0;
    g_PVSWindowSkipped = 0;
}

// 每波开始时清理缓存
void LeftDHooks_PVS_OnWaveStart()
{
    InvalidateSurvivorPVSCache();
    LeftDHooks_PVS_ResetRuntimeGuard();
}

// ==================== NavArea 可见性检测 ====================

/**
 * 检查 NavArea 是否完全暴露给生还者团队。
 * 这是区域级初筛，在获取随机点之前就能过滤。
 * 返回 false 不代表安全，只代表这块区域没有“完全暴露”，后面仍要做点位级可见性。
 *
 * @param area NavArea 地址
 * @return true 表示可见（需要过滤），false 表示不可见（可以使用）
 */
bool IsNavAreaVisibleToSurvivors(Address area, bool teleportMode)
{
    if (!g_bNavAreaCompleteVisNativeAvailable)
        return false;  // native 不可用，跳过此检测

    if (!SpawnPerfConfig_UseNavAreaVisibilityFilter())
        return false;  // 配置关闭，跳过此检测

    if (teleportMode && gCV.bIgnoreIncapSight)
        return false;  // 团队 native 无法排除倒地视线，传送模式保持旧逻辑口径。

    return L4D_IsCompletelyVisibleToTeam(area, TEAM_SURVIVOR);
}

// ==================== PVS 粗筛 ====================

/**
 * 刷新生还者 PVS 缓存。L4D_GetPVSForCluster 会跨 native 边界复制大 buffer，
 * 所以只在 TTL 到期且生还者 cluster 变化时重建。
 */
static void LeftDHooks_PVS_RefreshSurvivorCache()
{
    if (!g_bPVSNativesAvailable)
        return;

    float now = GetGameTime();
    if (g_LastPVSCheckTime > 0.0 && (now - g_LastPVSCheckTime) <= PVS_CACHE_TTL)
        return;

    g_LastPVSCheckTime = now;

    int nextSlot = 0;
    for (int i = 1; i <= MaxClients && nextSlot < PVS_SURVIVOR_CACHE_SLOTS; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        float eye[3];
        GetClientEyePosition(i, eye);

        int cluster = L4D_GetClusterForOrigin(eye);
        if (cluster < 0)
            continue;

        int slot = nextSlot++;
        if (!g_SurvivorPVSReady[slot] || g_SurvivorPVSClient[slot] != i || g_SurvivorPVSCluster[slot] != cluster)
        {
            L4D_GetPVSForCluster(cluster, g_SurvivorPVSBuffer[slot]);
            g_PVSBufferRebuilds++;
        }

        g_SurvivorPVSClient[slot] = i;
        g_SurvivorPVSCluster[slot] = cluster;
        g_SurvivorPVSReady[slot] = true;
    }

    for (int slot = nextSlot; slot < PVS_SURVIVOR_CACHE_SLOTS; slot++)
    {
        g_SurvivorPVSReady[slot] = false;
        g_SurvivorPVSClient[slot] = 0;
        g_SurvivorPVSCluster[slot] = -1;
    }

    g_SurvivorPVSCount = nextSlot;
}

static bool LeftDHooks_PVS_BufferContainsCluster(int slot, int cluster)
{
    if (cluster < 0)
        return true;

    int byteIndex = cluster / 8;
    if (byteIndex < 0 || byteIndex >= PVS_BUFFER_SIZE * 4)
        return true;

    int cell = g_SurvivorPVSBuffer[slot][byteIndex / 4];
    int byteShift = (byteIndex % 4) * 8;
    int byteValue = (cell >> byteShift) & 0xFF;

    return (byteValue & (1 << (cluster % 8))) != 0;
}

static void LeftDHooks_PVS_RecordWindowResult(bool skippedTrace)
{
    g_PVSWindowChecks++;
    if (skippedTrace)
        g_PVSWindowSkipped++;

    if (g_PVSWindowChecks < PVS_AUTO_WINDOW_CHECKS)
        return;

    if (g_PVSWindowSkipped * 100 < g_PVSWindowChecks * PVS_AUTO_MIN_SKIP_PERCENT)
    {
        g_PVSRuntimeEnabled = false;
        g_PVSAutoDisabledCount++;
        LogMessage("[IC-PVS] Auto disabled PVS point filter for this wave: skip=%d/%d (<%d%%)",
            g_PVSWindowSkipped, g_PVSWindowChecks, PVS_AUTO_MIN_SKIP_PERCENT);
        return;
    }

    g_PVSWindowChecks = 0;
    g_PVSWindowSkipped = 0;
}

/**
 * 检查候选点是否落入任一生还者 PVS。
 * PVS 是粗筛：false 才有强语义，表示候选点不在任何生还者潜在可见集合里；
 * true 只是“不确定/可能可见/无法判断”，调用方必须继续旧 trace 精判。
 *
 * @return true 表示可能可见，需要继续旧 trace 精判；
 *         false 表示不在任何 PVS 内，可认为不可见并跳过旧 trace。
 */
bool IsPointInAnySurvivorPVS(float origin[3])
{
    if (!g_bPVSNativesAvailable || !SpawnPerfConfig_UsePVSBucketFilter())
        return true;

    if (!g_PVSRuntimeEnabled)
        return true;

    bool hasPVS = false;
    LeftDHooks_PVS_RefreshSurvivorCache();

    for (int slot = 0; slot < g_SurvivorPVSCount; slot++)
    {
        if (g_SurvivorPVSReady[slot])
            hasPVS = true;
    }

    if (!hasPVS)
        return true;

    g_PVSPointChecks++;

    int originCluster = L4D_GetClusterForOrigin(origin);
    if (originCluster < 0)
    {
        g_PVSPointNeedsTrace++;
        LeftDHooks_PVS_RecordWindowResult(false);
        return true;
    }

    for (int slot = 0; slot < g_SurvivorPVSCount; slot++)
    {
        if (!g_SurvivorPVSReady[slot])
            continue;

        if (LeftDHooks_PVS_BufferContainsCluster(slot, originCluster))
        {
            g_PVSPointNeedsTrace++;
            LeftDHooks_PVS_RecordWindowResult(false);
            return true;
        }
    }

    LeftDHooks_PVS_RecordWindowResult(true);
    return false;
}

// ==================== 统计信息 ====================

void LeftDHooks_PVS_RecordPointTraceSkipped()
{
    g_PVSPointTraceSkipped++;
}

void LeftDHooks_PVS_RecordNavAreaFilter()
{
    g_PVSNavAreaFiltered++;
}

void LeftDHooks_PVS_PrintStats()
{
    if (!g_bPVSNativesAvailable && !g_bNavAreaCompleteVisNativeAvailable)
        return;

    LogMessage("[IC-PVS] Performance stats:");
    LogMessage("  NavAreas filtered by visibility: %d", g_PVSNavAreaFiltered);
    LogMessage("  Point PVS checks: %d", g_PVSPointChecks);
    LogMessage("  Point checks still requiring legacy trace: %d", g_PVSPointNeedsTrace);
    LogMessage("  Point visibility traces skipped by PVS: %d", g_PVSPointTraceSkipped);
    LogMessage("  Survivor PVS buffer rebuilds: %d", g_PVSBufferRebuilds);
    LogMessage("  PVS point filter auto-disabled waves: %d", g_PVSAutoDisabledCount);
}
