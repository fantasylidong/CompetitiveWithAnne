# infected_control 刷特架构说明

这份说明面向后续维护者和 AI 助手。目标是快速理解刷特系统的目的、数据流、候选点筛选顺序，以及修改时最容易踩坑的边界。

## 目标

`infected_control` 负责替代/增强 L4D2 默认导演刷特逻辑，让特感刷新满足这些目标：

- 按 `l4d_infected_limit` 和各类特感上限稳定补齐队列。
- 根据生还者 Flow 进度和距离环寻找不可见、可达、不贴脸、不容易卡住的 NavArea 点位。
- 尽量把特感刷在“有威胁但不离谱”的位置：距离合适、高度合理、Flow 不明显落后、扇区分布不重复。
- 在生还者拖节奏、跑男、特感长时间看不见时，通过 wave/teleport 逻辑保持节奏。
- 在高特感上限下控制 CPU：用 Nav 分桶、缓存、Left4DHooks PVS、早期过滤和候选预算减少昂贵 trace/path 调用。

## 总体数据流

```text
round_start / saferoom reset
  -> ResetMatchState / StopAll
  -> BuildNavBuckets / RebuildNavBuckets

left safe area / sm_startspawn
  -> Timer_SpawnFirstWave
  -> StartWave
  -> Timer_CheckSpawnWindow 每秒更新波决策

OnGameFrame 按轻量节流执行
  -> MaintainSpawnQueueOnce
  -> TryTeleportSpawnOnce 优先处理传送队列
  -> TryNormalSpawnOnce 处理普通刷特队列
  -> FindSpawnPosViaNavArea
  -> SpawnCore_EvaluateNavCandidate
  -> DoSpawnAt
```

`Timer_CheckSpawnWindow` 决定什么时候开下一波，`OnGameFrame` 决定这一帧是否真正尝试生成。两者分离是为了让“波节奏”和“单帧 CPU 负载”可以分别调整。

## 主要模块

| 文件 | 维护重点 |
| --- | --- |
| `infected_control.sp` | 插件入口、生命周期、事件、include 顺序、帧驱动。 |
| `config.inc` | CVar 默认值和缓存字段。改配置优先看这里。 |
| `wave_decider.inc` | 下一波是否释放、anti-baiter 是否拦截。 |
| `wave_control.inc` | 开波、窗口 timer、暂停恢复。 |
| `class_queue.inc` | 选类、死亡 CD、支援特感解锁、队列补位。 |
| `spawn_attempts.inc` | 普通刷出/传送刷出一次尝试，以及成功后的状态更新。 |
| `spawn_core.inc` | NavArea 候选扫描、候选点评估、最终取分最高点。 |
| `spawn_score.inc` | 距离/高度/Flow/分散度四因子评分。 |
| `survivor_flow.inc` | 生还者 Flow、候选点 bucket、bucket 存活特感上限。 |
| `spawn_memory.inc` | Nav 冷却、最近刷点分散、真实位置检查。 |
| `nav_cache.inc` | NavArea 全量缓存、NavID 索引、几何采样。 |
| `nav_buckets.inc` | Flow 分桶构建和扫描顺序。 |
| `path_cache.inc` | Nav path 可达性检查与缓存。 |
| `visibility.inc` | 旧视线精判 trace。 |
| `leftdhooks_pvs.inc` | Left4DHooks 1.167+ 的 NavArea 可见性和 PVS 粗筛。 |
| `teleport_monitor.inc` | 看不见/跑男/超时特感传送监督。 |

## 刷点核心

`FindSpawnPosViaNavArea` 是刷点主入口，职责是准备上下文并扫描候选：

- 读取生还者位置/Flow 缓存。
- 算目标生还者或最高进度生还者所在的 `centerBucket`。
- 根据 `inf_NavBucketEnable` 决定使用 Flow 分桶扫描还是全图 NavArea 扫描。
- 根据 `DifficultyStrategy_GetCandidateBudget()` 限制进入评分的候选数量。
- 若 `inf_NavBucketFirstFit` 开启，达到 first-fit 分数后提前返回。
- 否则保留本轮评分最高的点。

`SpawnCore_EvaluateNavCandidate` 只负责评估一个 NavArea。它的顺序很重要，原则是“先便宜过滤，再昂贵精判”。

当前顺序：

1. `areaIdx / area` 有效性：防止无效索引进入 native。
2. `SpawnAttributes` flags：安全屋、救援等区域先过滤。
3. `candidateBucket / rawBadFlow`：桶模式直接用已知 bucket；全图模式才读 Flow。
4. Nav 冷却：避免同一块 Nav 连续刷。
5. bucket 存活上限：同一 Flow 桶特感过多时提前跳过。
6. `L4D_IsCompletelyVisibleToTeam`：整块 NavArea 完全暴露时跳过。
7. `GetRandomPoint`：到这里才取随机点，减少点位级成本。
8. 最近刷点分散：避免刚刷过的区域附近继续刷。
9. 高度 slack 和距离环：判断是否在 `SpawnMin..ringEff`。
10. bucket 版真实位置检查：避免明显落后或楼层离谱。
11. stuck 检查：避免刷进障碍。
12. PVS 粗筛：不在任何生还者 PVS 内时跳过旧 trace。
13. `IsPosVisibleSDK` 精判：仍可能可见时才跑昂贵视线检查。
14. Nav path 可达性：最后才跑 path，并使用当前 `areaAddr` 避免候选点二次找 Nav。
15. 四因子评分：只有通过所有硬过滤后才进入评分。

不要轻易把 trace/path/stuck 提到前面。它们比 flags、bucket、距离、NavArea 完全可见贵很多。

## 评分模型

评分只用于“通过硬过滤后的候选点”之间排序：

- 距离：不同特感有自己的 sweet spot，`inf_ai_dist_width_scale` 可以让低难度更宽容。
- 高度：Hunter/Smoker 等偏好不同高度，避免所有点都贴地或过高。
- Flow：候选 bucket 相对生还者 bucket 的前后关系。
- 分散度：避免连续从同一扇区刷出。

`SpawnScore_BuildCandidate` 返回 `false` 的主要情况是 raw badflow 经过高度惩罚后 Flow 分低于 0。普通低分由 `inf_spawn_score_floor` 在外层过滤。

## 性能设计

最贵的操作大致是：

1. `IsPosVisibleSDK`：多名生还者 trace + `L4D2_IsVisibleToPlayer`。
2. `L4D2_NavAreaBuildPath`：Nav path 构建，虽然有 path cache 但首次仍贵。
3. `WillStuck`：Hull trace。
4. `L4D_GetNearestNavArea` / `L4D2Direct_GetTerrorNavArea`：点位反查 Nav。
5. `GetRandomPoint`、Flow/native、StringMap 查询。

当前优化点：

- Flow 分桶把扫描范围限制在生还者附近 bucket。
- `inf_spawn_candidate_budget` 默认 12，再由 AI 难度 bonus 降为 `9/10/11/12/12`。
- `PassRealBucketPositionCheck` 直接使用已知 bucket，不再对候选点二次查 Nav。
- `PathPenalty_NoBuildFromArea` 使用当前 NavArea 作为 path 终点，避免重复 nearest nav。
- `L4D_IsCompletelyVisibleToTeam` 在取随机点前过滤完全暴露的 NavArea。
- PVS 粗筛只能证明“肯定不在潜在可见集合里”，命中时跳过旧 trace；命中率过低会自动关闭本波 PVS 点位过滤。

## 常见修改入口

想改刷点质量：

- 距离/高度/Flow/分散度权重：`config.inc` 的 `inf_score_*` 和 `spawn_score.inc`。
- 候选预算：`inf_spawn_candidate_budget` 和 `inf_ai_spawn_budget_bonus`。
- 桶窗口：`inf_NavBucketWindow*` 和 `nav_buckets.inc`。
- 完全可见/PVS：`spawn_perf_config.inc` 和 `leftdhooks_pvs.inc`。

想改刷特节奏：

- 基础间隔：`versus_special_respawn_interval` / `inf_SpawnInterval` 相关配置。
- AI 难度开波判断：`difficulty_strategy.inc`、`wave_decider.inc`。
- anti-baiter：`anti_baiter.inc`。

想改传送：

- 入口：`teleport_monitor.inc`。
- 实际传送刷点：`TryTeleportSpawnOnce`。
- 注意 `teleportMode` 下 `bIgnoreIncapSight` 会影响可见性口径，NavArea 团队可见性 native 无法排除倒地视线。

## 修改守则

- 保持 include 顺序。SourcePawn include 是文本拼接，不是独立模块。
- 保持候选过滤“便宜到昂贵”的顺序，除非有明确性能数据。
- PVS 不能替代 `IsPosVisibleSDK`。PVS 只能跳过“肯定不可能可见”的点。
- `L4D_IsCompletelyVisibleToTeam` 只能过滤整块完全可见 NavArea，不能证明其他点安全。
- `PassRealBucketPositionCheck` 是主路径优化入口；不要在主候选循环重新调用 `GetPositionBucketPercent(pos)`。
- 修改 CVar 默认值后，检查线上 cfg 是否覆盖。
- 每次改刷点核心后至少编译 `infected_control.sp`，最好开 `inf_spawn_perf_stats 1` 跑一局看过滤统计。

## 快速验证

编译：

```sh
cd addons/sourcemod/scripting
./spcomp -iinclude -o../plugins/optional/AnneHappy/infected_control.smx optional/AnneHappy/infected_control.sp
```

推荐测试命令/CVar：

```text
inf_spawn_perf_stats 1
inf_spawn_navarea_vis_filter 1
inf_spawn_pvs_bucket_filter 1
sm_wavestatus
sm_rebuildnavcache
```

看日志时重点关注：

- `filters=...`：哪些过滤器命中最多。
- `navvis`：NavArea 完全可见初筛是否有效。
- `pvsskip`：PVS 是否真正跳过旧 trace。
- `avgTime`：每次找点耗时是否因为预算/过滤顺序变化而上升。
