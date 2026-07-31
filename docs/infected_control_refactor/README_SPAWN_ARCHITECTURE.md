# infected_control 刷特架构说明

这份说明面向后续维护者和 AI 助手。目标是快速理解刷特系统的目的、数据流、候选点筛选顺序，以及修改时最容易踩坑的边界。

完整交互说明：[infected_control 全流程架构](infected_control_full_pipeline.html)。页面按 1 秒波次 timer、`OnGameFrame` 热路径和事件回写三条通道拆解插件，并单独说明 Anti-Bait、职业队列、传送兜底、内鬼模式和性能边界。

Nav 专题动画：[Nav 刷特管线与性能观测](nav_spawn_pipeline.html)。该页面保留候选过滤、眼位快照和性能观测的可视化；找点控制流以本文和源码为准。

## 目标

`infected_control` 负责替代/增强 L4D2 默认导演刷特逻辑，让特感刷新满足这些目标：

- 按 `l4d_infected_limit` 和各类特感上限稳定补齐队列。
- 根据生还者 Flow 进度和职业范围寻找不可见、可达、不贴脸、不容易卡住的 NavArea 点位。
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
  -> 队列存在缺口时批量补齐（0.25s 重试节流）
  -> TryTeleportSpawnOnce 优先处理传送队列
  -> TryNormalSpawnOnce 处理普通刷特队列
  -> FindSpawnPosViaNavAreaStep 按预算续扫当前距离带
  -> DoSpawnAt
```

`Timer_CheckSpawnWindow` 决定什么时候开下一波，`OnGameFrame` 决定这一帧是否真正尝试生成。两者分离是为了让“波节奏”和“单帧 CPU 负载”可以分别调整。

## 主要模块

| 文件 | 维护重点 |
| --- | --- |
| `infected_control.sp` | 插件入口、生命周期、事件、include 顺序、帧驱动。 |
| `config.inc` | CVar 默认值和缓存字段。改配置优先看这里。 |
| `wave_decider.inc` | 下一波释放时机，以及 anti-baiter 破点波标记。 |
| `wave_control.inc` | 开波、窗口 timer、暂停恢复。 |
| `class_queue.inc` | 选类、死亡 CD、支援特感解锁、队列补位。 |
| `spawn_tactics.inc` | Boomer/Spitter 后手放行、破点波和连续战术几何评分。 |
| `spawn_attempts.inc` | 普通刷出/传送刷出一次尝试，以及成功后的状态更新。 |
| `spawn_core.inc` | NavArea 候选扫描、候选点评估、最终取分最高点。 |
| `spawn_score.inc` | 统一 0..100 的距离/高度/Flow/分散度与战术质量评分。 |
| `survivor_flow.inc` | 生还者 Flow、候选点 bucket、bucket 存活特感上限。 |
| `spawn_memory.inc` | Nav 冷却、最近刷点分散、真实位置检查。 |
| `nav_cache.inc` | NavArea 全量缓存、NavID 索引、几何采样。 |
| `nav_buckets.inc` | Flow 分桶构建和扫描顺序。 |
| `path_cache.inc` | Nav path 可达性检查与缓存。 |
| `visibility.inc` | 视线精判 trace，以及当前刷特帧的生还者眼位/朝向快照。 |
| `leftdhooks_pvs.inc` | Left4DHooks 1.167+ 的 NavArea 可见性和 PVS 粗筛。 |
| `teleport_monitor.inc` | 看不见/跑男/超时特感传送监督。 |

## 刷点核心

`FindSpawnPosViaNavAreaStep` 是刷点主入口。它保存候选源游标、当前最佳点和累计过滤统计，跨帧完成同一距离带：

- 每次调用只读取一次生还者位置/Flow，并缓存本次扫描所需的路径起点、可见性模式和评分上下文。
- 算目标生还者或最高进度生还者所在的 `centerBucket`。
- 根据 `inf_NavBucketEnable` 决定使用 Flow 分桶扫描还是全图 NavArea 扫描。
- 桶模式按原有 `bucket order -> row` 顺序扫描桶内全部 NavArea；全图模式从索引 0 扫到缓存末尾。
- 每帧最多检查 48 个 NavArea、进入 6 次昂贵精判，并受 0.8ms 软时间预算约束；达到上限只保存游标并返回 pending，不会截断整个搜索。
- 扫描会在后续帧继续，直到候选源自然耗尽、合格候选达到约 9 至 12 个的动态预算，或配置的 first-fit 条件命中；不会因为分片次数提前进入导演兜底。
- 若 `inf_NavBucketFirstFit` 开启，达到 first-fit 分数后提前返回。
- 否则保留本轮评分最高的点。

`SpawnCore_EvaluateNavCandidate` 只负责评估一个 NavArea。它的顺序很重要，原则是“先便宜过滤，再昂贵精判”。

当前顺序：

1. `areaIdx / area` 有效性：防止无效索引进入 native。
2. `SpawnAttributes` flags：安全屋、救援等区域先过滤。
3. `candidateBucket / rawBadFlow`：桶模式直接用已知 bucket；全图模式才读 Flow。
4. Nav 冷却：避免同一块 Nav 连续刷。
5. bucket 存活上限：同一 Flow 桶特感过多时提前跳过。
6. `GetRandomPoint`：到这里才取随机点；同一区域最多抽取 3 个点。
7. 最近刷点分散：避免刚刷过的区域附近继续刷。
8. 职业范围：判断随机点是否在当前职业的 `min..max` 内。
9. bucket 版真实位置检查：避免明显落后或楼层离谱。
10. stuck 检查：避免刷进障碍。
11. `IsPosVisibleSDK` 精判：过滤玩家能直接看到的点。
12. Nav path 可达性：最后才跑 path，并复用本次扫描缓存的起点 NavArea。
13. 统一评分：只有通过所有硬过滤后才计算四因子与职业战术几何分。

## 职业范围与导演兜底

每次生成保留三级职业范围。当前距离带完整续扫结束后，下一帧才进入下一档放宽范围：

| 职业 | 主区间 | 第一次放宽 | 第二次放宽 |
| --- | ---: | ---: | ---: |
| Smoker | 650–1100 | 450–1400 | 300–1500 |
| Boomer | 250–450 | 250–600 | 250–800 |
| Hunter | 450–850 | 300–1100 | 250–1300 |
| Spitter | 400–750 | 300–900 | 250–1000 |
| Jockey | 300–600 | 250–800 | 250–1000 |
| Charger | 300–600 | 250–800 | 250–1000 |

范围仍受 `inf_SpawnDistanceMin/Max` 限制；传送刷新另应用 `inf_TeleportDistanceMin`，范围过窄时最多向外补到 200。

只有职业范围内的候选源完整扫描后仍无合法点，插件才调用 `FallbackDirectorPosInRange`。受限导演点继续检查职业距离、视线和卡位。连续两轮完整流程失败后才启用原有 unrestricted 导演兜底，避免极端难刷地图长期卡住队列。

Boomer 和 Spitter 作为后手支援类，开波时若排在队首会轮转到队尾，不会丢弃。已有足够的 Smoker/Hunter/Jockey/Charger 落位，并出现交战事件或经过短宽限后才放行；另有强制超时避免队列饿死。

## Anti-Bait 破点波

Anti-Bait 不再扣住下一波。团队持续停滞后进入 `Pressure`，基础倒计时到点仍正常释放，但本次刷新会标记为破点波：

- 零特感、普通队列为空时也可以进入 `Pressure`，不再要求场上特感达到固定比例。
- 推进判定使用生还者 Flow 的下中位数，四人队需要至少三人有效推进；单人前探不会重置全队停滞计时。
- Tank、暂停或半数生还者倒地时进入 `Paused`，解除后恢复之前状态并扣除暂停时长，不再整波永久关闭。
- 破点波稳定地把 Smoker/Hunter/Jockey/Charger 移到队首并提高入队优先级；Boomer/Spitter 等控制特感落位或建立交火后再放行。
- 抱团时优先选择队伍质心边缘的有效生还者；候选使用本帧快照计算连续的后方、侧翼、外拉、推离和范围覆盖质量，不再依赖单一离散扇区三重加权。
- 每次刷点仍由 `OnGameFrame` 节流触发；破点波与普通波共用同一套跨帧预算和续扫游标。

不要轻易把 trace/path/stuck 提到前面。它们比 flags、bucket、距离、NavArea 完全可见贵很多。

## 评分模型

评分只用于“通过硬过滤后的候选点”之间排序，所有分项和总分统一为 `0..100`：

- 距离：按候选到当前目标的眼距计算职业 sweet spot；到全队最近眼距仍是不可放宽的硬边界。
- 高度：保留六职业差异曲线，再归一化到同一量纲。
- Flow：六职业使用连续 smoothstep 锚点，不在前后区间连接处跳变。
- 分散度：基础 70 分，只惩罚最近三个重复扇区，特感上限越高惩罚越轻。
- 战术质量：Smoker/Jockey 偏外拉与侧后方，Hunter 偏侧后方，Charger 偏从队伍内侧把边缘目标推出，Boomer/Spitter 偏抱团质心附近的范围收益。

四个基础分按配置权重除以权重和，后方/异常楼层最多扣 10 分；战术质量在普通波占 10%，破点波占 18%。Nav 历史权重保留为诊断字段，不改变原有扫描顺序，也不进入总分。`inf_spawn_score_floor` 默认 0，即评分不会让已经通过安全过滤的点刷不出来；需要实验性硬门槛时才设置为 `1..100`。

## 性能设计

最贵的操作大致是：

1. `IsPosVisibleSDK`：多名生还者 trace + `L4D2_IsVisibleToPlayer`。
2. `L4D2_NavAreaBuildPath`：Nav path 构建，虽然有 path cache 但首次仍贵。
3. `WillStuck`：Hull trace。
4. `L4D_GetNearestNavArea` / `L4D2Direct_GetTerrorNavArea`：点位反查 Nav。
5. `GetRandomPoint`、Flow/native、StringMap 查询。

当前优化点：

- Flow 分桶把扫描范围限制在生还者附近 bucket。
- 每只 SI 按三级职业范围逐档放宽；每一级按 48 个 Nav、6 次昂贵精判和 0.8ms 软预算分片，游标续扫到真正完成。难刷地图不会因为单帧预算过早进入导演兜底。
- Flow 桶按原有“桶顺序 → 桶内行”遍历；只保存桶号和行号，不做数组头部删除或跨帧候选搬运。
- 随机点安全硬判复用本 tick 的全队眼位快照。
- 每个实际执行刷点的 `OnGameFrame` 只读取一次活着生还者的眼位、左右视点和朝向，同 Tick 的距离、可见性和战术评分直接复用。
- 目标 Nav 起点、目标 Flow、最低生还者脚高和可见性射线模式按单次扫描缓存。
- 精确距离带全程使用平方距离，只有进入评分时才开方。
- 普通刷特队列在开波时批量补齐，不再每个 think slice 遍历 `MaxClients` 重算职业上限。
- `PassRealBucketPositionCheck` 直接使用已知 bucket，不再对候选点二次查 Nav。
- `PathPenalty_NoBuildFromStart` 复用生还者起点 NavArea，避免每个候选重复反查起点。
- NavArea 生成成功、实际生成失败和点位过滤失败仍写入历史诊断/冷却；遍历顺序保持原流程。
- `sm_spawnperf` 按 6/8/10/12/14+ 特分组输出候选准备、完整搜索和导演 API 耗时，以及 11 类过滤命中和六职业 API 命中率。

`anne_spawn_accel` 当前把批量几何、安全检查和路径入口移到 C++ native，减少 SourcePawn VM 往返；当前实现本身是同步加速，不应把 Source 引擎 Trace/Nav API 未经验证地放到工作线程。

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
- 搜索分片耗时、完整搜索累计耗时和 `fallbackApiMs`：分别判断单帧预算、完整续扫与职业范围导演兜底是否产生尖峰。
- 分组过滤计数：确认 6/8/10/12/14+ 特时真正消耗预算的过滤阶段。
