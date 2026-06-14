# 快速集成指南

## 第一步：修改主文件 infected_control.sp

### 1.1 在 OnPluginStart() 中添加

在 `RegAdminCmd("sm_nt", Cmd_NavTest, ...)` 这一行之后添加：

```c
RegAdminCmd("sm_wavestatus", Cmd_WaveStatus, ADMFLAG_GENERIC, "查看当前波决策器状态");
RegisterSpawnPerfCommands();
```

然后在函数末尾，`HookEvent` 之前添加：

```c
SpawnPerfConfig_Create();
```

### 1.2 在 OnConfigsExecuted() 之后添加新函数

```c
public void OnConfigsExecuted()
{
    // 现有代码...
}

// 新增
public Action Cmd_WaveStatus(int client, int args)
{
    if (!gST.bLate)
    {
        ReplyToCommand(client, "[IC] 刷特系统尚未启动");
        return Plugin_Handled;
    }

    WaveDecisionState state = WaveDecider_GetState();
    float elapsed = GetGameTime() - gST.lastWaveStartTime;
    
    char stateName[32];
    strcopy(stateName, sizeof(stateName), WaveDecider_GetStateName(state));
    
    ReplyToCommand(client, "[IC] 波决策器状态: %s", stateName);
    ReplyToCommand(client, "  波序号: %d", gST.waveIndex);
    ReplyToCommand(client, "  已用时: %.1f秒", elapsed);
    ReplyToCommand(client, "  特感: %d/%d", gST.totalSI, gCV.iSiLimit);
    ReplyToCommand(client, "  Anti-Bait: %s", AntiBait_IsTeamHolding() ? "拦截中" : "放行");
    
    return Plugin_Handled;
}
```

### 1.3 在 gCV.Refresh() 调用后添加

找到 `Config::Refresh()` 的调用位置（通常在 OnConfigsExecuted 里），在其后添加：

```c
gCV.Refresh();
SpawnPerfConfig_Refresh();  // 新增
```

### 1.4 在 Event_RoundStart 和 Event_RoundEnd 中添加

```c
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopAll();
    AntiBait_OnRoundStart();
    SpawnPerf_OnRoundStart();  // 新增
    WaveDecider_OnRoundStart();  // 新增
    CreateTimer(0.1, Timer_ApplyMaxSpecials);
    // ... 其余代码
}

public void OnMapEnd()
{
    // ... 现有代码
    
    if (SpawnPerfConfig_ShowStats())  // 新增
        SpawnPerf_OnMapEnd();
}
```

---

## 第二步：性能优化集成到 spawn_core.inc（可选）

这是**可选的高级优化**，如果当前刷点性能已满足需求，可以跳过此步骤。

### 2.1 找到 FindSpawnPosViaNavArea 函数

定位到 `infected_control/spawn_core.inc` 的 `FindSpawnPosViaNavArea()` 函数。

### 2.2 优化桶窗口计算（在函数开头）

找到类似这样的代码：
```c
int window = gCV.iNavBucketWindow;
```

替换为：
```c
int window = gCV.iNavBucketWindow;
if (SpawnPerfConfig_UseAdaptiveBucketWindow())
    window = ComputeAdaptiveBucketWindow(searchRange, window);
```

### 2.3 优化桶序生成

找到类似这样的代码：
```c
int bucketOrder[FLOW_BUCKETS];
int bucketCount = BuildBucketOrder(centerBucket, window, includeCenter, bucketOrder);
```

替换为：
```c
int bucketOrder[FLOW_BUCKETS];
int bucketCount = BuildOptimizedBucketOrder(centerBucket, window, includeCenter, bucketOrder);
```

### 2.4 添加渐进式采样（高级）

这需要重构整个候选点扫描循环。如果你对当前性能已满意，建议先跳过，只应用上面两个简单优化即可。

---

## 第三步：编译与测试

### 3.1 编译
```bash
cd addons/sourcemod/scripting
./spcomp infected_control.sp -O2
```

如果遇到编译错误，检查：
- 是否所有 `.inc` 文件都在正确位置
- 是否有语法错误（缺少分号、括号不匹配等）

### 3.2 测试清单

#### 基础功能测试
- [ ] 服务器能正常启动
- [ ] 回合开始后特感正常刷新
- [ ] 没有报错或崩溃

#### 波决策器测试
- [ ] 使用 `sm_wavestatus` 查看状态是否正确
- [ ] 简单难度（16秒）：观察是否在 0-8秒有提前触发机会
- [ ] 专家难度（16秒）：确认时序逻辑正确

#### Anti-Bait 测试
- [ ] 玩家密集不推进：应进入 Pressure 状态
- [ ] 玩家分散不推进：应主动施压（新逻辑）
- [ ] 玩家推进：应正常放行

#### 性能测试
- [ ] 开启 `inf_spawn_perf_stats 1`
- [ ] 运行一个完整回合
- [ ] 查看服务器日志，找到 `[PerfStats]` 输出
- [ ] 检查过滤效果和耗时

### 3.3 推荐测试 ConVar 设置

```cfg
// 调试模式
inf_DebugMode 2                      // 输出详细日志
inf_antibait_debug 1                 // Anti-Bait 调试

// 性能统计
inf_spawn_perf_stats 1               // 显示性能统计
inf_spawn_perf_mode 0                // 平衡模式（默认）

// 波决策器测试（专家难度）
ah_ai_dynamic_fixed_level 4          // 固定为专家难度
versus_special_respawn_interval 16   // 16秒刷新间隔
```

---

## 第四步：调优参数

根据测试结果调整：

### 4.1 如果刷特太快（压力过大）
```cfg
inf_ai_wave_check_time "18.0 14.0 12.0 10.0 8.0"  // 增加检查窗口
inf_antibait_window 15.0                          // 增加停滞判定时间
```

### 4.2 如果刷特太慢（压力不足）
```cfg
inf_ai_wave_check_time "14.0 10.0 8.0 6.0 4.0"   // 减少检查窗口
inf_antibait_window 10.0                          // 减少停滞判定时间
```

### 4.3 如果性能不佳
```cfg
inf_spawn_perf_mode 1                 // 切换到快速模式
inf_NavBucketWindow 8                 // 减小桶窗口
inf_spawn_candidate_budget 5          // 减少候选预算
```

### 4.4 如果刷点质量差
```cfg
inf_spawn_perf_mode 2                 // 切换到质量模式
inf_NavBucketWindow 12                // 增大桶窗口
inf_spawn_candidate_budget 12         // 增加候选预算
```

---

## 常见问题

### Q1: 编译错误 "undefined symbol WaveDecider_OnWaveStart"
**A**: 确认已在 infected_control.sp 中添加：
```c
#include "infected_control/wave_decider.inc"
```

### Q2: 服务器报错 "Native not found: SpawnPerf_OnRoundStart"
**A**: 确认已在 infected_control.sp 中添加：
```c
#include "infected_control/spawn_perf_optimizer.inc"
#include "infected_control/spawn_perf_config.inc"
```

### Q3: 波决策器状态一直是 Idle
**A**: 检查：
1. `gST.bLate` 是否为 true（生还者已离开安全屋）
2. `Timer_CheckSpawnWindow` 是否正常运行
3. 日志中是否有 `[WaveDecider]` 输出

### Q4: 性能统计显示全是 0
**A**: 确认：
1. `inf_spawn_perf_stats 1` 已设置
2. 已运行至少一个完整回合
3. 特感确实有刷新（不是被其他插件拦截）

---

## 回退方案

如果新版本出现严重问题，可以临时回退：

### 方案1：禁用波决策器
在 `wave_control.inc` 的 `Timer_CheckSpawnWindow()` 中注释掉：
```c
// WaveDecider_Update();  // 临时禁用
```

### 方案2：禁用性能优化
```cfg
inf_spawn_perf_mode 2  // 质量模式（关闭所有优化）
```

### 方案3：完全回退
使用 git 回退到重构前的版本：
```bash
git checkout HEAD~1 infected_control.sp
git checkout HEAD~1 infected_control/wave_control.inc
git checkout HEAD~1 infected_control/anti_baiter.inc
```

---

## 需要帮助？

如果遇到问题，提供以下信息：
1. **错误日志**：完整的服务器日志（包含时间戳）
2. **配置信息**：相关 ConVar 的值（`sm_cvar inf_*`）
3. **场景描述**：什么难度、多少玩家、预期行为vs实际行为
4. **性能数据**：`[PerfStats]` 输出（如果有）

祝测试顺利！🎉
