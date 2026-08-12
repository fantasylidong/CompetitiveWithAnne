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
| `spawn_score.inc` | 统一距离/高度/Flow/分散度与战术质量评分，并应用高低点和后方进度的最终加减分。 |
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
- worker 从输出集合排除中心点距任意存活生还者小于 250 单位（三维直线距离）的 Nav，再按原始 `candidate Nav -> target Nav` 有向 `navDistance` 升序；相同距离按 areaIdx 稳定排序。250 范围内的 Nav 仍可作为图路径中间节点，但不会作为刷点候选返回。
- SourcePawn 按当前职业的原始 Nav 距离带分页取结果。高点不再把路径距离乘 0.50 或改变访问顺序；Smoker/Hunter 的高点优势在最终评分中按实际候选点高度离散加分。首档下界保留 128 单位边界余量，后续档只查询上一档硬上限之外的新增远端区间。原有 Smoker/Hunter `navEffective` 高点补偿继续用于职业上限、最终路径预算和距离评分。扩展不可用或图不完整时不扫描无序全 Nav，直接让职业流程进入 Director API；快照尚未完成或动态图重建时返回 pending。
- 每次启动都会先分片捕获当前地图全部 floor 连接和 ladder 端点，再把规范化有向边纳入 v7 缓存指纹。Nav Variant、Stripper 梯子、机关重连或连接变化都会使旧缓存失效，不再只依赖 Nav ID、中心点和文件时间。动态状态使用 `<map>.<fingerprint>.anvg` 多版本缓存；电梯、移动平台、渡船或自定义脚本机关返回已见过的拓扑时直接命中对应文件，不会被后一状态覆盖。
- 扩展在主线程按节流频率分片校验 `TheNavAreas` 身份以及所有 Area 的四向 `CNavArea::Connections` 和上下梯子端点；不依赖机关 classname 名单。每次最多检查 1024 个 Area，并用持久游标在连续轮询中覆盖全图；可解析 `func_elevator` 的位置、速度和 toggle state 则每次都检查，避免电梯移动中发布半成品图。空闲时每 1.0 秒一次，预计刷特前或已有刷特任务时每 0.1 秒一次；发现任意有向边变化立即提升 graph generation 并清空旧图、后台待发布结果、候选快照和 BuildPath 缓存，状态连续稳定 0.2 秒后再分片重捕获。捕获前后还会各做一次完整签名，期间发生变化则放弃该次结果。普通 Nav blocker 由既有 blocker snapshot/epoch 失效，不触发拓扑重建。
- 稳定的动态机关不是不完整错误：扩展用该状态下实时生效的有向连接发布完整图。变化发生时旧 generation、距离场、候选页和路径缓存立即失效，刷特搜索返回 `pending` 等待新图，不切全 Nav，也不执行动态图 BuildPath 兜底。电梯 Nav 无法关联实体只保留诊断，因为全 Area 有向连接仍由实时拓扑轮询覆盖；只有未知连接目标、非法连接存储等无法可靠表达有向边的问题才把图标记为真正不完整。已经映射进度的 badflow Nav 仍可进入候选，但映射只提供 Flow 评分，绝不冒充路径连通。
- 每个搜索切片默认最多检查 512 个 NavArea、进入 16 次昂贵精判，并受 2.0ms 软时间预算约束；达到上限只保存 areaIdx 游标并返回 pending，不会截断整个距离带。三项分别由 `inf_spawn_nav_candidates_per_slice`、`inf_spawn_nav_expensive_per_slice`、`inf_spawn_nav_slice_budget_ms` 热调，较弱机器可分别降回 `256/8/1.0`。
- 当前 tick 找到合格候选时，只比较本 tick 内最多 8 个评分样本并立即返回最优点；不会保存候选到下一帧，也不会比较不同 tick 的评分。
- 当前 tick 没有合格候选时才续扫下一段游标；目标 Nav 改变会重建图游标。动态图 generation 变化时立即清空所有分页游标和 offset，新图必须从当前职业距离带的第一个有向候选重新开始。未消费候选页最多保留 0.2 秒，过期后按当前快照和已消费进度重新分页。
- 若 `inf_NavBucketFirstFit` 开启，当前 tick 达到 first-fit 分数后立即返回。

`SpawnCore_EvaluateNavCandidate` 只负责评估一个 NavArea。它的顺序很重要，原则是“先便宜过滤，再昂贵精判”。

当前顺序：

1. `areaIdx / area` 有效性：防止无效索引进入 native。
2. `SpawnAttributes` flags：安全屋、救援等区域先过滤。
3. `candidate progress / rawBadFlow`：图模式复用 areaIdx 进度缓存；已经完成进度映射的 badflow Nav 仍可评估。完全未知的进度保持 unknown，不伪装成 0%。
4. 后方进度硬门：`dF = candidateFlow - targetFlow`；`dF=-8` 允许继续评分，`dF<-8` 在取随机点前直接拒绝。进度 unknown 时不执行该硬门。
5. Nav 冷却：成功确认后同一块 Nav 硬冷却 1.0 秒，避免连续复用。
6. bucket 存活上限：同一 Flow 桶特感过多时提前跳过。
7. `GetRandomPoint`：到这里才取随机点；同一区域最多抽取 3 个点。
8. 最近刷点分散：成功确认后的实际落点保留 0.5 秒，期间按动态半径硬拒绝邻近请求点。
9. 距离范围：图候选用原始 `navDistance` 执行职业下限；Smoker/Hunter 高于目标眼位时用 `navEffective = navDistance - highComp` 判断上限。所有模式同时执行全队 250 单位三维直线排除。
10. stuck 检查：避免刷进障碍。
11. `IsPosVisibleSDK` 精判：过滤玩家能直接看到的点。
12. 伤害触发器检查：对当前地图每秒刷新的 `trigger_hurt`/`trigger_hurt_ghost` 实体引用做玩家 Hull 与世界 AABB 相交测试，避免 Nav 点位本身合法但出生后立即被地图杀死。
13. Nav path 可达性：最后才跑 path，并复用本次扫描缓存的起点 NavArea；它只精确复核有向图已返回的候选，不负责无序全 Nav 兜底。
14. 统一评分：只有通过所有硬过滤后才计算四因子、战术质量和最终高低点/后方进度加减分。

## 职业范围与导演兜底

每次生成保留六级职业范围。当前距离带完整续扫结束后才进入下一档放宽范围；单帧突发预算有余量时可以在同一帧继续推进：

| 职业 | 主区间 | 放宽 1 | 放宽 2 | 放宽 3 | 放宽 4 | 最终区间 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Smoker | 500–1200 | 500–1500 | 500–1800 | 500–2100 | 500–2550 | 500–3000 |
| Boomer | 250–550 | 250–750 | 250–1000 | 250–1400 | 250–1850 | 250–2300 |
| Hunter | 350–950 | 350–1250 | 350–1500 | 350–1750 | 350–2300 | 350–2900 |
| Spitter | 300–800 | 300–1050 | 300–1250 | 300–1450 | 300–1850 | 300–2300 |
| Jockey | 250–700 | 250–900 | 250–1100 | 250–1250 | 250–1700 | 250–2200 |
| Charger | 250–700 | 250–900 | 250–1100 | 250–1250 | 250–1700 | 250–2200 |

表内范围是累计可接受的有向 Nav 路径距离，不是空间半径。放宽只提高远端上限，不降低职业下限；后续五档实际都从上一档上限之后继续扫描，因此不会重新处理已经完整失败的近端候选。Smoker 高出目标眼位 32 单位后按高度差的 `1.5` 倍折减 Nav 距离，最多折减 1000；Hunter 按 `1.15` 倍折减，最多 800。该 `navEffective` 折减用于职业上限、最终路径预算和距离评分。候选访问顺序始终使用原始 `navDistance`；高点不再乘 0.50 提前。普通有效 Nav 上限受 `inf_SpawnDistanceMax * 2` 限制，高点粗筛最多额外预取 1000。传送刷新仍把直线下限提高到 `inf_TeleportDistanceMin`。扩展或静态图不可用时不进行无序全 Nav 搜索，直接进入 Director API。日志模式名 `directRange` 为历史兼容名称；Director 点不受职业 Nav 区间限制，但必须满足距任一存活生还者最近三维直线距离不超过 2000。

职业范围内的有向 Nav 候选完整扫描后仍无合法点，或有向图明确不可用/不完整时，插件调用 `FallbackDirectorPos`。Director API 返回成功后先按实时生还者眼位检查最近三维直线距离，超过固定上限 2000 的坐标直接拒绝；通过后才交给 `L4D2_SpawnSpecial`。实体稳定落地后再执行同一 2000 上限复核，避免引擎安置位置偏移。Director 点仍不复核职业 Nav 路径区间、可见性、stuck、预测落点、伤害触发器或 `DoSpawnAt` 的最小距离门槛。第一次 API 调用内部尝试 7 次，未返回合格点时第二阶段提高到 12 次。

普通刷特为每个职业分别保存目标生还者、距离档、分页游标和已尝试目标集合，不能用一个全局目标让不同职业互相重置搜索。单个职业完整六档 Nav 与两级 Director 都失败后，先在其余存活生还者中选择有向覆盖较高且尚未尝试的目标；四人轮完后只重置该职业的目标轮次。随后该职业默认退避 `0.10s`，再从第一档重新建立有向 Nav 搜索；目标生还者切换 Nav 时提前解除退避。`inf_spawn_failed_cycle_retry` 可在 `0.02–1.0s` 调整，弱机器可提高到 `0.2s`。成功生成一只后，该职业下次仍从第一档开始，其他职业的搜索进度不受影响。这避免无合法点时每帧重复调用 Director，也避免某个职业或某个目标长期卡住整波。

Boomer 和 Spitter 作为后手支援类，开波时若排在队首会轮转到队尾，不会丢弃。已有足够的 Smoker/Hunter/Jockey/Charger 落位，并出现交战事件或经过短宽限后才放行；另有强制超时避免队列饿死。

## Anti-Bait 延长与破点波

每波先经历当前难度的击杀窗口；专家默认 8 秒。普通队列完成后若场上 SI 已降到低压阈值，可以提前开始独立的 16 秒倒计时；异步找点尚未刷完时不能误触发提前倒计时。16 秒本身不会提前结束：

- 到点时若没有稳定卡位，立即释放下一波。
- 倒计时前段只采样；最后 `inf_antibait_arm_before` 秒（默认 4 秒）才允许进入 `Pressure`。到点时若 `Pressure` 已连续达到 `inf_antibait_hold_confirm`，且至少两名有效生还者持续停滞抱团、无人倒地/挂边/被控，则进入 `IntensiveCheck`。
- `IntensiveCheck` 没有强制超时。推进、分组断开、出现孤立成员或任何脆弱状态连续达到 `inf_antibait_release_confirm` 后立即释放。
- 推进满足任一条件即可：生还者 Flow 下中位数相对基准提高 `inf_antibait_progress_pct`（默认 4%），或健康有效成员的团队中心距基准点移动 `inf_antibait_progress_dist`（默认 1000 世界单位）。四人队的 Flow 条件需要至少三人有效推进，位置条件使用团队中心，单人前探不会替全队重置停滞计时。
- 抱团使用连通组、最大跨度、平均最近队友距离和孤立成员数；单人生还者不能触发无限延长。
- 机关尸潮、终局事件或 `holdout_bonus` 标记的守点期间绕过 Anti-Bait 延长，基础刷特仍按正常节奏运行，不把合理守点判作 bait。地图机关沿用 `trigger_horde_notify` 的 Director 原因分类；警报车至少保持 10 秒、普通机关至少保持 60 秒，避免 `panic_event_finished` 的生成结束边沿过早清掉机关状态。
- Tank 存活但仍远离队伍时，健康抱团停滞可继续延长下一波；Tank 接近任一存活生还者至 `inf_antibait_tank_pressure_dist`（默认 1200）、队伍散开/推进或出现脆弱状态并稳定达到解除确认后，立即放行。至少半数生还者倒地时也不允许延长。
- 真正的游戏暂停会同时冻结击杀窗口、16 秒倒计时和延长解除确认。
- 分散但停滞仍可产生破点波，但属于可攻击队形，不会扣住刷新。
- 破点波把 Smoker/Hunter/Jockey/Charger 前置，并优先选择抱团队伍质心边缘的有效目标。
- 普通内鬼在基础倒计时开始时立即进入 ghost 找位；最后 3 秒显示最早可复活倒计时。若到点进入 `IntensiveCheck`，内鬼继续锁定并收到守点延长提示，实际放波后才开放现有 5 秒实体化窗口。内鬼提示消费 WaveDecider 的剩余时间和状态，不另读 `versus_special_respawn_interval` 建立独立计时器。

不要轻易把 trace/path/stuck 提到前面。它们比 flags、bucket、距离检查贵很多。

## 评分模型

评分只用于“通过硬过滤后的候选点”之间排序。四个质量分项、战术质量和最终分均保持 `0..100`：

- 距离：图候选的职业范围、sweet spot 和距离分按 `candidate Nav -> target Nav` 有向路径距离计算；Smoker/Hunter 保留既有 `navEffective` 高点补偿，但候选访问顺序仍按原始路径升序。候选到目标的三维直线眼距只用于日志诊断，任意生还者 250 单位三维直线距离仍是硬下限（传送使用更高下限）。
- 高度：保留六职业差异曲线，再归一化到同一量纲。Smoker/Hunter 另按候选请求点高于目标脚部的高度，每满 50u 直接给最终分加 `inf_score_high_height_per_50`（默认 6），不足 50u 不加。
- Flow：六职业使用连续 smoothstep 锚点，不在前后区间连接处跳变。`dF<-8` 已在评分前硬拒绝；允许的后点每落后目标 1% Flow，再从最终分直接扣 `inf_score_behind_per_flow`（默认 2）。因此 `dF=-1/-4/-8` 分别扣 `2/8/16`。
- 分散度：基础 70 分，只惩罚最近三个重复扇区，特感上限越高惩罚越轻。
- 战术质量：Smoker/Jockey 偏外拉与侧后方，Hunter 偏侧后方，Charger 偏从队伍内侧把边缘目标推出，Boomer/Spitter 偏抱团质心附近的范围收益。
- 低点：所有职业按候选请求点低于目标脚部的高度，每满 50u 扣 5 分；不足 50u 不扣。候选 Flow 落后目标（`dF<0`）时，该低点扣分乘 2，再由 `inf_score_low_height_cap` 钳制到 100。即非后点低 `50/100/150/200u` 扣 `5/10/15/20`，后点分别扣 `10/20/30/40`。

四个基础质量分仍按职业配置权重做归一化加权平均：`Q=(wd*距离 + wh*高度 + wf*Flow + wp*分散度)/(wd+wh+wf+wp)`。普通波先算 `0.90*Q + 0.10*战术质量`，破点波改为 `0.82*Q + 0.18*战术质量`，随后直接执行 `+高点奖励-后点扣分-低点扣分`，最后钳制到 `0..100`。因此 `+6/-2/-5` 都是最终分的精确点数，不会再被 90/10 混合稀释。Nav 历史权重及其诊断字段已完全删除。最终分 `=0` 的 Nav 候选始终淘汰；`inf_spawn_score_floor` 默认 0，表示不再提高正分门槛，需要更严格的实验门槛时才设置为 `1..100`。

## 性能设计

最贵的操作大致是：

1. `IsPosVisibleSDK`：多名生还者 trace + `L4D2_IsVisibleToPlayer`。
2. `L4D2_NavAreaBuildPath`：Nav path 构建，虽然有 path cache 但首次仍贵。
3. `WillStuck`：Hull trace。
4. `L4D_GetNearestNavArea` / `L4D2Direct_GetTerrorNavArea`：点位反查 Nav。
5. `GetRandomPoint`、Flow/native、StringMap 查询。

当前优化点：

- 有向图 worker 一次完成反向可达、全队 250 单位三维直线排除和按原始 `navDistance` 的全局排序。SourcePawn 不再按 Flow 桶枚举候选，也不在主线程重排整张图。
- 引擎 Flow 是 Nav 路线进度，不是 XY 直线距离；扩展补齐无效 Flow 时沿 Nav 邻接图传播，边权使用 Nav 中心的 3D 距离。候选的 `targetDistance` 是 3D 直线诊断值，`navDistance` 是原始有向路径距离，`navEffective` 是 Smoker/Hunter 既有职业上限与距离评分补偿。高点最终奖励按随机候选点相对目标脚部的实际 Z 差计算，不参与 worker 排序。
- 每次图启动或稳定动态状态变化后先分片捕获实时拓扑，再在 worker 上计算规范化连接指纹并加载/重建对应 v5 状态缓存。动态监测只读取主线程可安全访问的 Nav/实体字段，按空闲 1.0 秒、刷特热区 0.1 秒节流；诊断输出同时记录全图 `topology_areas/floor_edges/ladder_edges/readable/captured_hash` 和 `dynamic_state/changes/rebuilds/cache_loads/hash/poll_ms`，可直接确认变化来源及轮询成本。
- 稳定动态图和静态图都使用有向候选。动态图重建窗口暂停本次搜索；未知目标、非法存储等真正不完整拓扑不启用全 Nav 回退，而是转到 Director API。Flow 映射只提供进度、评分和密度限制数据。
- 候选快照平时每 1.0 秒构建一次；`WaveDecider` 预计刷新前 1 秒或已有刷特工作时切到 0.1 秒。完成结果每帧只做廉价发布，构建频率不随 128 tick 放大。
- 快照有效期为 0.2 秒；生还者量化位置、目标 Nav、图 generation 或 blocker epoch 改变时旧结果不匹配并重建。
- 每只 SI 按六级职业范围只向远端逐档放宽；完整图模式下，后一档只消费上一档上限之外的新 Nav 区间。每一级默认按 512 个 Nav、16 次昂贵精判和 2.0ms 软预算分片，游标续扫到真正完成。三项分别可在 `1–1024`、`1–32`、`0.1–4.0ms` 内热调；较弱机器可降到 `256/8/1.0ms`，难刷地图不会因为切片预算过早进入导演兜底。
- active think 默认最多推进 8 次普通/传送尝试，并受 `inf_spawn_frame_budget_ms=4.0` 的整体墙钟预算约束；任一上限先到就让出本帧。`inf_spawn_attempts_per_frame` 可动态调整为 1–12，较弱机器可降回 `4/2.0ms`。
- 完整失败周期按 `inf_spawn_failed_cycle_retry=0.10s` 退避；等待期间只做廉价队列轮转和目标 Nav 变化检查，不持续占满帧预算。
- 随机点安全硬判复用本 tick 的全队眼位快照。
- 每个实际执行刷点的 `OnGameFrame` 只读取一次活着生还者的眼位、左右视点和朝向，同 Tick 的距离、可见性和战术评分直接复用。
- 目标 Nav 起点、目标 Flow、目标生还者脚高和可见性射线模式每 tick 重建，不跨 tick 复用。
- 候选的 stuck、visibility、path 和评分必须在同一 tick 完成；生成前不再重复执行一整轮可见性 trace。
- 全队 250 三维直线排除使用平方距离；扩展分页返回原始 `navDistance`。随机点确认后才按实际 Z 差计算 Smoker/Hunter 高点奖励，并保留既有有限 `navEffective` 折减，不重复寻路。
- 测试探针可调用只读 `AnneSpawn_NavGraphGetPathDistance(startNavId, targetNavId, ...)` 查询任意实际出生 Nav 到夹具目标 Nav 的同代有向距离；返回 `1/0/-1/-2/-3` 分别表示可达、不可达、图 pending、参数无效、功能不可用。该 native 只读取当前图快照，不进入生产候选选择。
- 普通刷特队列在开波时批量补齐，不再每个 think slice 遍历 `MaxClients` 重算职业上限。
- Flow bucket 用于评分、同桶密度限制和 `dF<-8` 的廉价硬拒绝；旧版 `PassRealBucketPositionCheck` 不再进入主路径。
- `PathPenalty_NoBuildFromStart` 复用生还者起点 NavArea，避免每个候选重复反查起点。
- NavArea 生成成功、实际生成失败和点位过滤失败仍写入历史诊断/冷却。
- `sm_spawnperf` 除原有分组统计外，还输出图候选构建/结果年龄 p50、p95、p99、max，以及 queue、cache、stale、完整快照候选数、当前距离带候选数和 1.0s/0.1s 调度次数。
- `inf_spawn_perf_stats 1` 还会把每次实际实体生成的波号、职业、普通/传送/导演模式、开波后耗时、生成调用耗时、请求/实际坐标、目标直线距离、目标垂直差、原始/有效 Nav 距离、高点奖励及阶梯、后点/低点扣分、目标脚高、执行范围和位置评分写入同一日志；下一波或回合结束时分别汇总这些字段与单帧工作量。导演兜底没有 Nav 距离和评分时明确写 `N/A`。

`anne_spawn_accel` 的 worker 只读取主线程复制的 Nav ID、中心、边、blocker 和眼位快照；不会在线程中解引用 Source 引擎对象。随机点、flags、冷却、卡位、精确可见性、最终路径和评分仍在当前游戏 tick 复核，因此后台候选只是粗筛索引，不是可直接生成的安全凭证。

## 常见修改入口

想改刷点质量：

- 距离/高度/Flow/分散度权重，以及高点奖励、低点/后方扣分：`config.inc` 的 `inf_score_*` 和 `spawn_score.inc`。
- `inf_nav_high_sort_scale` 与 `inf_nav_high_sort_min_height` 仅为旧配置兼容项，active 搜索不再使用。
- 候选预算：`inf_spawn_candidate_budget` 和 `inf_ai_spawn_budget_bonus`。
- 图候选刷新/有效期/分页预算：`infected_control.sp` 的 `NAV_CANDIDATE_*` 与 `spawn_accel_bridge.inc`。
- 可见性/stuck：`visibility.inc`、`spawn_core.inc` 和可选的 `anne_spawn_accel` native safety。

想改刷特节奏：

- 基础间隔：`versus_special_respawn_interval` / `inf_SpawnInterval` 相关配置。
- 时序口径：难度击杀窗口结束或低压提前条件成立后，才开始独立的基础倒计时；不要用上一只 SI 的生成时间作为倒计时锚点。
- AI 难度开波判断：`difficulty_strategy.inc`、`wave_decider.inc`。
- anti-baiter：`anti_baiter.inc`。

想改传送：

- 入口：`teleport_monitor.inc`。
- 实际传送刷点：`TryTeleportSpawnOnce`。
- AI 特感创建、进入实际落点确认和确认提交时都会重置不可见计数并刷新出生时间；`player_spawn` 事件只是额外兜底，不是出生宽限的唯一数据源。插件热加载时，已在场的存活 AI 特感按加载时刻重新进入宽限。
- `inf_TeleportSpawnGrace` 默认 2.5 秒。宽限内、出生时间未知、仍在 pending 实际落点确认、ghost 或待踢队列中的实体都不能累计不可见时间；缺失时间戳按禁止传送处理，不能绕过宽限。
- 宽限结束后才开始原有不可见计数。普通阈值仍由 `inf_TeleportCheckTime` 控制，默认 5 个一秒 tick；跑男和 Anti-Bait 快通道只缩短这段不可见阈值，不绕过出生宽限。
- 注意 `teleportMode` 下 `bIgnoreIncapSight` 会影响可见性口径，SourcePawn fallback 与 native safety 必须保持一致。

## 修改守则

- 保持 include 顺序。SourcePawn include 是文本拼接，不是独立模块。
- 保持候选过滤“便宜到昂贵”的顺序，除非有明确性能数据。
- PVS 实验代码已删除，不属于当前运行架构；历史 PVS 文档不能作为现行实现依据。
- 随机候选点、安全结论、分数和本帧 best 不得跨 tick 保存。跨帧只允许保存 areaIdx 分页/游标和诊断计数，页本身受 0.2 秒有效期限制。
- 主候选循环不再调用 `PassRealBucketPositionCheck`；现行后点硬门是明确的 `dF<-8`，并在随机点和昂贵检查之前执行。该旧 helper 仅供历史/诊断入口参考。
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
- `[TP GRACE]`：确认 `player_spawn`、实体创建、pending 建立、提交或热加载接管都刷新了出生时间；同一实体允许出现多个来源，最后一次写入是宽限起点。
- `[TP] ... age=... grace=...`：真正进入传送队列时的实体年龄和配置宽限。任何 `age < grace`、pending、ghost 或待踢实体进入该日志都属于回归。
