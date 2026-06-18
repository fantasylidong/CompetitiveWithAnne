#if defined _infected_control_spawn_perf_config_included
    #endinput
#endif
#define _infected_control_spawn_perf_config_included

/**
 * 刷特性能配置 - 可通过 ConVar 动态调整
 */

// ==================== ConVar 定义 ====================

ConVar g_cvSpawnPerfMode;
ConVar g_cvSpawnPerfProgressiveSampling;
ConVar g_cvSpawnPerfAdaptiveBucketWindow;
ConVar g_cvSpawnPerfEarlyDistanceFilter;
ConVar g_cvSpawnPerfStats;
ConVar g_cvUseNavAreaVisFilter;
ConVar g_cvUsePVSBucketFilter;

enum SpawnPerfMode
{
    PerfMode_Balanced = 0,     // 平衡模式（默认）
    PerfMode_Fast = 1,         // 快速模式（优先性能）
    PerfMode_Quality = 2       // 质量模式（优先刷点质量）
}

// ==================== 全局配置 ====================

SpawnPerfMode g_CurrentPerfMode = PerfMode_Balanced;
bool g_bProgressiveSampling = false;
bool g_bAdaptiveBucketWindow = false;
bool g_bEarlyDistanceFilter = false;
bool g_bShowPerfStats = false;
bool g_bUseNavAreaVisFilter = true;
bool g_bUsePVSBucketFilter = true;

// ==================== 初始化 ====================

void SpawnPerfConfig_Create()
{
    g_cvSpawnPerfMode = CreateConVar(
        "inf_spawn_perf_mode", "0",
        "刷点性能模式：0=平衡，1=快速（优先性能），2=质量（优先刷点质量）",
        CVAR_FLAG, true, 0.0, true, 2.0
    );

    g_cvSpawnPerfProgressiveSampling = CreateConVar(
        "inf_spawn_perf_progressive", "0",
        "启用渐进式采样：从少到多逐步增加候选点，找到合适就停止",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvSpawnPerfAdaptiveBucketWindow = CreateConVar(
        "inf_spawn_perf_adaptive_bucket", "0",
        "启用自适应桶窗口：根据扩圈距离动态调整Flow桶扫描范围",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvSpawnPerfEarlyDistanceFilter = CreateConVar(
        "inf_spawn_perf_early_dist_filter", "0",
        "启用早期距离过滤：使用包围盒快速淘汰明显不合格的候选点",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvSpawnPerfStats = CreateConVar(
        "inf_spawn_perf_stats", "0",
        "显示刷点性能统计：0=关闭，1=回合结束时输出",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvUseNavAreaVisFilter = CreateConVar(
        "inf_spawn_navarea_vis_filter", "1",
        "使用 NavArea 完全可见初筛（需 leftdhooks 1.167+ 支持）",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvUsePVSBucketFilter = CreateConVar(
        "inf_spawn_pvs_bucket_filter", "1",
        "使用 PVS 对候选点做粗筛，不在任何生还者PVS内时跳过旧可见性trace（需 leftdhooks 1.167+ 支持）",
        CVAR_FLAG, true, 0.0, true, 1.0
    );

    g_cvSpawnPerfMode.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvSpawnPerfProgressiveSampling.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvSpawnPerfAdaptiveBucketWindow.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvSpawnPerfEarlyDistanceFilter.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvSpawnPerfStats.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvUseNavAreaVisFilter.AddChangeHook(OnSpawnPerfConfigChanged);
    g_cvUsePVSBucketFilter.AddChangeHook(OnSpawnPerfConfigChanged);
}

void SpawnPerfConfig_Refresh()
{
    if (g_cvSpawnPerfMode == null)
        return;

    g_CurrentPerfMode = view_as<SpawnPerfMode>(g_cvSpawnPerfMode.IntValue);
    g_bProgressiveSampling = g_cvSpawnPerfProgressiveSampling.BoolValue;
    g_bAdaptiveBucketWindow = g_cvSpawnPerfAdaptiveBucketWindow.BoolValue;
    g_bEarlyDistanceFilter = g_cvSpawnPerfEarlyDistanceFilter.BoolValue;
    g_bShowPerfStats = g_cvSpawnPerfStats.BoolValue;
    g_bUseNavAreaVisFilter = g_cvUseNavAreaVisFilter.BoolValue;
    g_bUsePVSBucketFilter = g_cvUsePVSBucketFilter.BoolValue;

    // 根据性能模式应用预设
    ApplyPerfModePreset(g_CurrentPerfMode);
}

void OnSpawnPerfConfigChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    SpawnPerfConfig_Refresh();
}

void ApplyPerfModePreset(SpawnPerfMode mode)
{
    switch (mode)
    {
        case PerfMode_Fast:
        {
            // 快速模式：激进优化，可能牺牲刷点质量
            g_bProgressiveSampling = true;
            g_bAdaptiveBucketWindow = true;
            g_bEarlyDistanceFilter = true;
        }
        case PerfMode_Quality:
        {
            // 质量模式：关闭所有优化，全面扫描
            g_bProgressiveSampling = false;
            g_bAdaptiveBucketWindow = false;
            g_bEarlyDistanceFilter = false;
        }
        case PerfMode_Balanced:
        {
            // 平衡模式：根据 ConVar 设置
            // 不覆盖，保持用户自定义
        }
    }
}

// ==================== 查询接口 ====================

stock bool SpawnPerfConfig_UseProgressiveSampling()
{
    return g_bProgressiveSampling;
}

stock bool SpawnPerfConfig_UseAdaptiveBucketWindow()
{
    return g_bAdaptiveBucketWindow;
}

stock bool SpawnPerfConfig_UseEarlyDistanceFilter()
{
    return g_bEarlyDistanceFilter;
}

stock bool SpawnPerfConfig_ShowStats()
{
    return g_bShowPerfStats;
}

stock SpawnPerfMode SpawnPerfConfig_GetMode()
{
    return g_CurrentPerfMode;
}

stock bool SpawnPerfConfig_UseNavAreaVisibilityFilter()
{
    return g_bUseNavAreaVisFilter;
}

stock bool SpawnPerfConfig_UsePVSBucketFilter()
{
    return g_bUsePVSBucketFilter;
}

// ==================== 调试命令 ====================

public Action Cmd_SpawnPerfStats(int client, int args)
{
    SpawnPerf_PrintStats();
    ReplyToCommand(client, "[IC] 已输出刷点性能统计到服务器日志");
    return Plugin_Handled;
}

public Action Cmd_SpawnPerfReset(int client, int args)
{
    SpawnPerf_ResetStats();
    ReplyToCommand(client, "[IC] 已重置刷点性能统计");
    return Plugin_Handled;
}

public Action Cmd_SpawnPerfMode(int client, int args)
{
    if (args < 1)
    {
        char modeName[32];
        GetPerfModeName(g_CurrentPerfMode, modeName, sizeof(modeName));
        ReplyToCommand(client, "[IC] 当前刷点性能模式: %s (%d)", modeName, g_CurrentPerfMode);
        ReplyToCommand(client, "  渐进式采样: %s", g_bProgressiveSampling ? "开启" : "关闭");
        ReplyToCommand(client, "  自适应桶窗口: %s", g_bAdaptiveBucketWindow ? "开启" : "关闭");
        ReplyToCommand(client, "  早期距离过滤: %s", g_bEarlyDistanceFilter ? "开启" : "关闭");
        ReplyToCommand(client, "  NavArea可见性过滤: %s", g_bUseNavAreaVisFilter ? "开启" : "关闭");
        ReplyToCommand(client, "  PVS点位粗筛: %s", g_bUsePVSBucketFilter ? "开启" : "关闭");
        return Plugin_Handled;
    }

    char arg[8];
    GetCmdArg(1, arg, sizeof(arg));
    int mode = StringToInt(arg);

    if (mode < 0 || mode > 2)
    {
        ReplyToCommand(client, "[IC] 错误：模式必须是 0-2 (0=平衡, 1=快速, 2=质量)");
        return Plugin_Handled;
    }

    g_cvSpawnPerfMode.SetInt(mode, true, false);

    char modeName[32];
    GetPerfModeName(view_as<SpawnPerfMode>(mode), modeName, sizeof(modeName));
    ReplyToCommand(client, "[IC] 已切换刷点性能模式为: %s", modeName);

    return Plugin_Handled;
}

void GetPerfModeName(SpawnPerfMode mode, char[] buffer, int maxlen)
{
    switch (mode)
    {
        case PerfMode_Fast:     strcopy(buffer, maxlen, "快速模式");
        case PerfMode_Quality:  strcopy(buffer, maxlen, "质量模式");
        default:                strcopy(buffer, maxlen, "平衡模式");
    }
}

void RegisterSpawnPerfCommands()
{
    RegAdminCmd("sm_spawnperf", Cmd_SpawnPerfStats, ADMFLAG_GENERIC, "显示刷点性能统计");
    RegAdminCmd("sm_spawnperf_reset", Cmd_SpawnPerfReset, ADMFLAG_GENERIC, "重置刷点性能统计");
    RegAdminCmd("sm_spawnperf_mode", Cmd_SpawnPerfMode, ADMFLAG_CONFIG, "查看或设置刷点性能模式");
}
