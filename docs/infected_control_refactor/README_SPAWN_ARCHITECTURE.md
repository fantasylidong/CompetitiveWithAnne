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
- 在高特感上限下控制 CPU：用有向 Nav 图候选快照、缓存、早期过滤和候选预算减少昂贵 trace/path 调用。

## 总体数据流

```text
round_start / saferoom reset
  -> ResetMatchState / StopAll
  -> AnneSpawn_NavGraphStart
  -> 主线程分批复制 Nav 数据，worker 加载或构建有向图

left safe area / sm_startspawn
  -> Timer_SpawnFirstWave
  -> StartWave
  -> Timer_CheckSpawnWindow 每秒更新波决策

OnGameFrame 按轻量节流执行
  -> 每帧发布已完成的 worker 结果
  -> 平时每 1.0s、预计刷新前 1s 每 0.1s 为全部存活生还者预热候选快照
  -> 队列存在缺口时批量补齐（0.25s 重试节流）
  -> 单个 active think 在次数上限与墙钟预算内突发推进多次尝试
  -> TryTeleportSpawnOnce 优先处理传送队列，否则 TryNormalSpawnOnce 处理普通队列
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
| `spawn_accel_bridge.inc` | 扩展能力检测、有向图候选预热/分页和性能日志。 |
| `spawn_core.inc` | NavArea 候选扫描、候选点评估、最终取分最高点。 |
| `spawn_score.inc` | 统一 0..100 的距离/高度/Flow/分散度与战术质量评分。 |
| `survivor_flow.inc` | 生还者 Flow、候选点 bucket、bucket 存活特感上限。 |
| `spawn_memory.inc` | Nav 冷却、最近刷点分散、真实位置检查。 |
| `nav_cache.inc` | NavArea 全量缓存、NavID 索引、几何采样。 |
| `nav_buckets.inc` | Flow 进度映射、高度缓存和评分所需数据；不再提供候选扫描顺序。 |
| `path_cache.inc` | Nav path 可达性检查与缓存。 |
| `visibility.inc` | 视线精判 trace，以及当前刷特帧的生还者眼位/朝向快照。 |
| `teleport_monitor.inc` | 看不见/跑男/超时特感传送监督。 |

## 刷点核心

`FindSpawnPosViaNavAreaStep` 是刷点主入口。它只保存候选源游标和累计过滤统计，跨帧遍历同一距离带，但候选的完整判定不会跨 tick：

- 每次调用重新读取一次生还者位置/Flow，并为当前 tick 建立路径起点、可见性模式和评分上下文。
- 扩展从目标 Nav 反向遍历有向边，得到 `candidate Nav -> target Nav` 可达集合；正向不可达的 Nav 不会进入候选源。
- worker 从输出集合排除中心点距任意存活生还者小于 250 单位（三维直线距离）的 Nav，再按 `candidate Nav -> target Nav` 有向路径距离升序排序，路径距离相同时只按 areaIdx 保持稳定次序。250 范围内的 Nav 仍可作为图路径的中间节点，否则会切断所有到目标附近的路径，但不会作为刷点候选返回。
- SourcePawn 按当前职业 Nav 距离带加 128 单位边界余量分页取结果，并直接复用扩展返回的 `navDistance` 做硬范围和评分。扩展不可用或图不完整时才从索引 0 扫描全量 Nav；快照暂未完成时返回 pending，不会偷偷切回 Flow 桶或全图抢跑。
- 动态电梯成员关系不属于稳定静态拓扑。地图只要出现这种 Nav，扩展会把图标记为不完整并禁用图候选，整轮使用全 Nav 候选回退和当前帧 `BuildPath` 精判，避免静态图漏掉经过电梯的合法点；回退仍不使用 Flow 桶枚举。
- 每帧最多检查 256 个 NavArea、进入 8 次昂贵精判，并受 1.0ms 软时间预算约束；达到上限只保存 areaIdx 游标并返回 pending，不会截断整个距离带。
- 当前 tick 找到合格候选时，只比较本 tick 内最多 8 个评分样本并立即返回最优点；不会保存候选到下一帧，也不会比较不同 tick 的评分。
- 当前 tick 没有合格候选时才续扫下一段游标；目标 Nav 改变会重建图游标。未消费候选页最多保留 0.2 秒，过期后按当前快照和已消费进度重新分页。
- 若 `inf_NavBucketFirstFit` 开启，当前 tick 达到 first-fit 分数后立即返回。

`SpawnCore_EvaluateNavCandidate` 只负责评估一个 NavArea。它的顺序很重要，原则是“先便宜过滤，再昂贵精判”。

当前顺序：

1. `areaIdx / area` 有效性：防止无效索引进入 native。
2. `SpawnAttributes` flags：安全屋、救援等区域先过滤。
3. `candidate progress / rawBadFlow`：图模式复用 areaIdx 进度缓存；全图兜底才强制拒绝异常 Flow。
4. Nav 冷却：避免同一块 Nav 连续刷。
5. bucket 存活上限：同一 Flow 桶特感过多时提前跳过。
6. `GetRandomPoint`：到这里才取随机点；同一区域最多抽取 3 个点。
7. 最近刷点分散：避免刚刷过的区域附近继续刷。
8. 距离范围：图候选按有向 `navDistance` 执行职业 `min..max`；同时对随机点执行全队 250 单位三维直线排除。
9. bucket 版真实位置检查：只拒绝明显落后超过 6% Flow 的回头点，不再按绝对 Z 硬杀多层地图候选。
10. stuck 检查：避免刷进障碍。
11. `IsPosVisibleSDK` 精判：过滤玩家能直接看到的点。
12. Nav path 可达性：最后才跑 path，并复用本次扫描缓存的起点 NavArea。
13. 统一评分：只有通过所有硬过滤后才计算四因子与职业战术几何分。

## 职业范围与导演兜底

每次生成保留三级职业范围。当前距离带完整续扫结束后才进入下一档放宽范围；单帧突发预算有余量时可以在同一帧继续推进：

| 职业 | 主区间 | 第一次放宽 | 第二次放宽 |
| --- | ---: | ---: | ---: |
| Smoker | 700–1650 | 500–2400 | 300–3000 |
| Boomer | 250–700 | 250–1050 | 250–1600 |
| Hunter | 500–1300 | 350–1900 | 250–2600 |
| Spitter | 450–1150 | 300–1550 | 250–2000 |
| Jockey | 300–900 | 250–1350 | 250–2000 |
| Charger | 300–900 | 250–1350 | 250–2000 |

表内范围是有向 Nav 路径距离，不是空间半径。Nav 上限受 `inf_SpawnDistanceMax * 2` 限制；`inf_SpawnDistanceMin`（默认 250）仍是对任意生还者的三维直线安全距离，传送刷新再把这条直线下限提高到 `inf_TeleportDistanceMin`。扩展或静态图不可用时，全 Nav/导演兼容兜底没有可信 `navDistance`，改用 `inf_SpawnDistanceMin..Max` 的三维直线范围，避免拿欧氏距离冒充路径距离。

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

不要轻易把 trace/path/stuck 提到前面。它们比 flags、bucket、距离检查贵很多。

## 评分模型

评分只用于“通过硬过滤后的候选点”之间排序，所有分项和总分统一为 `0..100`：

- 距离：图候选的职业范围、sweet spot 和距离分都按 `candidate Nav -> target Nav` 有向路径距离计算；候选到目标的三维直线眼距只用于日志诊断。所有模式仍硬拒绝到任意生还者三维直线距离不足 250 的点（传送使用更高直线下限）。
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

- 有向图 worker 一次完成反向可达、全队 250 单位三维直线排除和 `navDistance` 排序；SourcePawn 不再按 Flow 桶枚举候选。
- 引擎 Flow 是 Nav 路线进度，不是 XY 直线距离；扩展补齐无效 Flow 时沿 Nav 邻接图传播，边权使用 Nav 中心的 3D 距离。候选的 `targetDistance` 是 3D 直线诊断值，`navDistance` 才是职业范围、分页顺序和距离评分口径。只有扩展不可用时的兼容旧桶映射仍按 XY 就近匹配，不参与正常扩展主路径。
- 静态拓扑不完整（目前主要是动态电梯）时只启用保守的全 Nav 候选回退；Flow 桶继续只提供进度、评分和密度限制数据。
- 候选快照平时每 1.0 秒构建一次；`WaveDecider` 预计刷新前 1 秒或已有刷特工作时切到 0.1 秒。完成结果每帧只做廉价发布，构建频率不随 128 tick 放大。
- 快照有效期为 0.2 秒；生还者量化位置、目标 Nav、图 generation 或 blocker epoch 改变时旧结果不匹配并重建。
- 每只 SI 按三级职业范围逐档放宽；每一级按 256 个 Nav、8 次昂贵精判和 1.0ms 软预算分片，游标续扫到真正完成。难刷地图不会因为单帧预算过早进入导演兜底。
- active think 默认最多推进 4 次普通/传送尝试，并受 `inf_spawn_frame_budget_ms=2.0` 的整体墙钟预算约束；任一上限先到就让出本帧。`inf_spawn_attempts_per_frame` 可在测试服动态调整为 1–12。
- 随机点安全硬判复用本 tick 的全队眼位快照。
- 每个实际执行刷点的 `OnGameFrame` 只读取一次活着生还者的眼位、左右视点和朝向，同 Tick 的距离、可见性和战术评分直接复用。
- 目标 Nav 起点、目标 Flow、最低生还者脚高和可见性射线模式每 tick 重建，不跨 tick 复用。
- 候选的 stuck、visibility、path 和评分必须在同一 tick 完成；生成前不再重复执行一整轮可见性 trace。
- 全队 250 三维直线排除使用平方距离；有向 Nav 距离由扩展随分页结果同时返回，职业硬范围和评分直接复用，不重复寻路。
- 普通刷特队列在开波时批量补齐，不再每个 think slice 遍历 `MaxClients` 重算职业上限。
- `PassRealBucketPositionCheck` 直接使用已知 bucket，不再对候选点二次查 Nav。
- `PathPenalty_NoBuildFromStart` 复用生还者起点 NavArea，避免每个候选重复反查起点。
- NavArea 生成成功、实际生成失败和点位过滤失败仍写入历史诊断/冷却。
- `sm_spawnperf` 除原有分组统计外，还输出图候选构建/结果年龄 p50、p95、p99、max，以及 queue、cache、stale、完整快照候选数、当前距离带候选数和 1.0s/0.1s 调度次数。
- `inf_spawn_perf_stats 1` 还会把每次实际实体生成的波号、职业、普通/传送/导演模式、开波后耗时、生成调用耗时、请求/实际坐标、目标直线距离、目标垂直差、有向 Nav 距离、执行范围和位置评分写入同一日志；下一波或回合结束时分别汇总直线距离、Nav 距离、垂直差、分数和单帧工作量。导演兜底没有 Nav 距离和评分时明确写 `N/A`。

`anne_spawn_accel` 的 worker 只读取主线程复制的 Nav ID、中心、边、blocker 和眼位快照；不会在线程中解引用 Source 引擎对象。随机点、flags、冷却、卡位、精确可见性、最终路径和评分仍在当前游戏 tick 复核，因此后台候选只是粗筛索引，不是可直接生成的安全凭证。

## 常见修改入口

想改刷点质量：

- 距离/高度/Flow/分散度权重：`config.inc` 的 `inf_score_*` 和 `spawn_score.inc`。
- 候选预算：`inf_spawn_candidate_budget` 和 `inf_ai_spawn_budget_bonus`。
- 图候选刷新/有效期/分页预算：`infected_control.sp` 的 `NAV_CANDIDATE_*` 与 `spawn_accel_bridge.inc`。
- 可见性/stuck：`visibility.inc`、`spawn_core.inc` 和可选的 `anne_spawn_accel` native safety。

想改刷特节奏：

- 基础间隔：`versus_special_respawn_interval` / `inf_SpawnInterval` 相关配置。
- AI 难度开波判断：`difficulty_strategy.inc`、`wave_decider.inc`。
- anti-baiter：`anti_baiter.inc`。

想改传送：

- 入口：`teleport_monitor.inc`。
- 实际传送刷点：`TryTeleportSpawnOnce`。
- 注意 `teleportMode` 下 `bIgnoreIncapSight` 会影响可见性口径，SourcePawn fallback 与 native safety 必须保持一致。

## 修改守则

- 保持 include 顺序。SourcePawn include 是文本拼接，不是独立模块。
- 保持候选过滤“便宜到昂贵”的顺序，除非有明确性能数据。
- PVS 实验代码已删除，不属于当前运行架构；历史 PVS 文档不能作为现行实现依据。
- 随机候选点、安全结论、分数和本帧 best 不得跨 tick 保存。跨帧只允许保存 areaIdx 分页/游标和诊断计数，页本身受 0.2 秒有效期限制。
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
inf_VisEyeRayMode 2
inf_spawn_accel_native_safety 0
sm_wavestatus
sm_rebuildnavcache
```

看日志时重点关注：

- `filters=...`：哪些过滤器命中最多。
- `stuck` / `vis`：Hull 和精确可见性分别过滤了多少候选。
- `[SpawnPerf][GraphCandidates] buildMs/resultAgeMs`：worker 构建时间和 SourcePawn 消费时的结果年龄。
- `masterCandidates/lastRangeCandidates`：全队 250 排除后的完整集合，以及最近职业距离带实际可扫数量。
- `queued/published/cacheHits/coalesced/staleDrops`：节流、复用和位置变化造成的废弃是否健康。
- 搜索分片耗时、完整搜索累计耗时和 `fallbackApiMs`：分别判断单帧预算、完整续扫与职业范围导演兜底是否产生尖峰。
- 分组过滤计数：确认 6/8/10/12/14+ 特时真正消耗预算的过滤阶段。
