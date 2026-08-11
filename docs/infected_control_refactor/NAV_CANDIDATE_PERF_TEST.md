# 有向 Nav 候选性能测试

测试日期：2026-08-10

> 历史兼容基准：本文前半部分保留扩展 ranked native 的性能与正确性数据。2026-08-11 起 active `infected_control` 不再调用 ranked 接口，高点不会把路径距离乘 0.50；候选按原始有向路径升序，Smoker/Hunter 改为按实际候选点相对目标脚高每满 50u 直接增加 6 个最终分。

## 测试对象

- 合成有向图：10,000 个 NavArea，60,000 条有向边。
- 生还者：4 个眼位。
- 候选规则：`candidate -> target` 有向可达，排除距任一生还者不足 250 单位（三维直线距离）的 Nav 中心。普通快照按原始路径距离升序；高点快照按独立 `rankDistance` 全局升序，同时保留原始路径距离。
- 编译：Apple Clang 17，`-std=c++17 -O2 -Wall -Wextra -Werror`。
- 主机：Apple M4。
- 每轮包含反向 Dijkstra、全队距离过滤和候选排序，共测 200 次。

## 正确性断言

测试程序会直接失败，除非以下条件全部成立：

- 在 `A -> B -> C` 图中，以 C 为目标时 A/B/C 可达；以 A 为目标时 B/C 不可达。
- 输出 areaIdx 与候选路径距离数量一致，反向距离场覆盖完整图。
- 普通快照的原始路径距离单调递增，并验证“空间更近但 Nav 绕路更远”的候选排在后面。
- 高点快照的 `rankDistance` 单调递增，并验证高点原始路径更远、乘 0.50 后仍能排到低点之前；原始路径距离不会被伪装成排序距离。
- 每个输出 Nav 中心到 4 名生还者都至少 250 单位。
- 每个输出 Nav 都有有限的 `candidate -> target` 路径距离。
- 实时拓扑指纹与边输入顺序无关，但连接目标、边类型或拓扑问题位变化时必须改变。
- 只有 `DynamicElevator` 标记时，新建图和磁盘缓存回读结果必须保持 `complete=true` 并可生成有向候选；未知目标或非法连接存储仍必须 `complete=false`。不带电梯标志的普通 floor 有向边从状态 A 变到 B 时必须产生独立缓存，B-A 返回旧拓扑时必须重新命中 A 缓存。

## 本机结果

```text
areas=10000 edges=60000 cache_bytes=320060 warm_load_us=4206
candidate_build_us runs=200 p50=262 p95=403 max=783 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=3360
candidate_build_us runs=200 p50=526 p95=998 max=2174 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=4845
candidate_build_us runs=200 p50=289 p95=818 max=1552 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=3116
candidate_build_us runs=200 p50=254 p95=460 max=674 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=3022
candidate_build_us runs=200 p50=251 p95=424 max=1081 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=3264
candidate_build_us runs=200 p50=324 p95=802 max=2056 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=3114
candidate_build_us runs=200 p50=198 p95=244 max=404 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=5175
candidate_build_us runs=200 p50=248 p95=438 max=522 candidates=9583

areas=10000 edges=60000 cache_bytes=320060 warm_load_us=7235
candidate_build_us runs=200 p50=213 p95=372 max=435 candidates=9583
ranked_candidate_build_us runs=200 p50=212 p95=344 max=503 candidates=9583
```

最近一次同进程交替测量中，普通构建 p50/p95 为 0.213/0.372ms，高点全局排序为 0.212/0.344ms，差异落在正常抖动内；ranked 最大值为 0.503ms。历史普通构建多轮 p50 约 0.20 到 0.32ms；同时进行完整扩展构建时有一轮 p50 0.53ms、最大 2.17ms。以四名生还者估算，0.1 秒热刷新约消耗单核 1% 到 2.1% 的 worker CPU，观测 p95 上界约 4%；1 秒空闲刷新约为其十分之一。工作由两个有界 worker 执行，不占用游戏主线程的 2ms 搜索软预算。候选基准不包含主线程的实时拓扑轮询；v1.4.2 开始每次轮询最多读取 1024 个 Area 的 floor/ladder 有向边，并用游标在后续轮询继续覆盖全图。实服诊断以 `topology_areas/topology_floor_edges/topology_ladder_edges`、`topology_poll_batch/topology_poll_cursor` 和 `dynamic_poll_ms=last/max` 单独记录其覆盖进度与成本。

这是合成图结果，不是对所有地图和服务器 CPU 的承诺。真实地图的边数、可达范围、CPU 频率和同时运行的插件都会改变数据，应以实服日志为准。

## 构建验证

SourcePawn 1.12.0.7230 编译成功，仅保留项目已有的 `CreateDialog` 弃用警告。Linux x86 扩展使用 CI 固定版本 SourceMod `e5de0a0cdef3eb2bc484b17ce63a4e14fcf3f221`、L4D2 HL2SDK、Clang 22 和 `-Werror` 完整构建成功：

```text
Build succeeded.
.../anne_spawn_accel.ext.2.l4d2.so
```

## 实服日志

启用 `inf_spawn_perf_stats 1`。所有结果写入
`addons/sourcemod/logs/infected_control_fdxxnav.txt`；这些性能行不再依赖 `inf_DebugMode`。执行 `sm_spawnperf` 会立即输出当前累计性能统计和当前波快照。图候选部分会增加四行 `[SpawnPerf][GraphCandidates]`：

```text
buildMs samples=... last=... p50=... p95=... p99=... max=...
resultAgeMs last=... p50=... p95=... p99=... max=...
queued=... published=... cacheHits=... coalesced=... staleDrops=... collect(hit/pending/unavailable)=... masterCandidates=... lastRangeCandidates=... inFlight=... cache=...
cadence idle=... warm=... prepare(ready/pending/unavailable)=...
```

重点判断：

- `buildMs p95`：真实地图 worker 构建成本。
- `resultAgeMs p95`：0.2 秒 TTL 是否留有余量。
- `lastRangeCandidates`：最近职业距离带的实际候选数量。
- `coalesced`：同一快照请求是否被正确合并。
- `staleDrops`：玩家快速移动或 blocker 变化造成的废弃量。
- `collectPending`：刷新前 1 秒的 0.1 秒预热是否足够。

## 实服波次报告

本地合成图基准不能模拟一局真实 L4D2 的导演、玩家位置和实体生成耗时。因此“一波生成了哪些特感、多久生成、位置多少分”由实服运行时记录，不在上面的合成基准中伪造。

每波 `[SpawnWave][Begin]` 同时记录难度击杀窗口、基础倒计时以及五项运行预算。`killWindowMs` 在专家档默认是 8000，`configuredIntervalMs` 默认是 16000；`attemptsPerFrame`、`frameBudgetMs`、`navPerSlice`、`expensivePerSlice`、`navSliceBudgetMs` 用于对照不同服务器。后三项对应 `inf_spawn_nav_candidates_per_slice`（默认 512，范围 1–1024）、`inf_spawn_nav_expensive_per_slice`（默认 16，范围 1–32）和 `inf_spawn_nav_slice_budget_ms`（默认 2.0ms，范围 0.1–4.0ms）；前两项默认 `8/4.0ms`，继续由 `inf_spawn_attempts_per_frame` 与 `inf_spawn_frame_budget_ms` 控制。较弱机器可使用 `4/2.0/256/8/1.0` 这一组低压参数。

每次实际执行 `L4D2_SpawnSpecial` 都写一行 `[SpawnWave][Spawn]`。下面仅为字段格式示例，数值不是伪造的实服测试结果：

```text
[SpawnWave][Spawn] wave=3 seq=1 result=success mode=normal_nav class=Hunter entity=7 waveElapsedMs=31.2 spawnCallMs=0.093 request=(123.0 456.0 178.0) actualValid=1 actual=(123.2 455.8 178.0) targetDistance=521.4 teamMinDistance=418.2 targetDz=146.2 navDistance=914.8 navRank=914.8 navEffective=783.5 navHighSort=1.00 navHighComp=131.3 navRange=350..950 score=85.31 quality=80.44 dist=91.20 height=74.00 flow=78.50 dispersion=70.00 tactical=89.30 highBonus=6.00 highRise=76.0 highSteps=1 extraPen=4.00 behindPen=4.00 lowHeightPen=0.00 targetFootZ=102.0 lowHeightDrop=0.0 lowHeightSteps=0 lowHeightMultiplier=2.00 area=421 bucket=54 targetBucket=55 deltaFlow=-1 bucketKnown=1 rawBadFlow=0 target=2
```

字段含义：

- `waveElapsedMs`：从本波开始到这只特感生成的真实游戏时间。
- `spawnCallMs`：最终距离复核和 `L4D2_SpawnSpecial` 调用耗时，不冒充跨帧候选搜索耗时。
- `request/actual`：请求坐标和实体生成后的实际坐标；`actualValid=0` 表示生成失败或实体坐标尚不可读。
- `targetDistance/targetDz`：候选到本次目标生还者眼位的 3D 直线距离和垂直差，只用于诊断楼层与实际空间位置。
- `navDistance/navRank/navEffective/navHighSort/navHighComp/navRange`：原始有向路径距离、兼容诊断距离、既有 Smoker/Hunter 高点有效距离/折减量，以及本次职业距离带。active 路径中 `navRank=navDistance`、`navHighSort=1.00`；职业上限和距离评分仍按既有 `navEffective` 语义。
- 导演兜底没有可靠的图路径距离，记录 `navDistance=N/A`，并用 `directRange` 明确标出其执行的直线距离范围。
- `bucket/targetBucket/deltaFlow/bucketKnown/rawBadFlow`：候选与目标的 Flow 进度、差值、该差值是否可信，以及候选原始 Flow 是否异常；`deltaFlow<-8` 的候选在评分前已淘汰。
- `score/quality/dist/height/flow/dispersion/tactical`：最终分、四因子职业加权质量及主要分项。普通波公式为 `score=0.90*quality+0.10*tactical+highBonus-behindPen-lowHeightPen`；破点波的混合比例为 0.82/0.18。
- `highBonus/highRise/highSteps`：仅 Smoker/Hunter 生效，每高于目标脚部满 50u 加 6 个最终分。
- `targetFootZ/lowHeightDrop/lowHeightSteps/lowHeightMultiplier`：低点以目标脚部为基准，每低满 50u 扣 10 个最终分；候选进度落后目标时倍率为 2，低点项最高扣 100 分。
- `mode`：区分普通/传送、Nav 候选/导演范围兜底/无限制兜底。导演兜底没有 `SpawnScoreDbg`，固定记录 `score=N/A`。

下一波开始、回合结束、地图结束或插件停止时会自动写最终总结；`sm_spawnperf` 写当前波快照但不会结束本波：

```text
[SpawnWave][Timing] wave=3 event=countdown_start waveElapsedMs=4200.0 killWindowMs=8000.0 configuredIntervalMs=16000.0 pending=0 alive=3 reason=early conditions met
[SpawnWave][AntiBait] wave=3 event=hold_start waveElapsedMs=20200.0 countdownElapsedMs=16000.0 active=4 vulnerable=0 spread=612.0 avgNearest=331.0 stalledMs=17200.0 pressureMs=5200.0
[SpawnWave][AntiBait] wave=3 event=hold_release extendedMs=7300.0
[SpawnWave][Summary] state=final reason=next_wave wave=3 durationMs=27500.0 killPhaseMs=4200.0 countdownMs=16000.0 antiBaitExtendedMs=7300.0 configuredIntervalMs=16000.0 plannedAi=4 pendingAtStart=4 remainingQueue=0 spawnCalls=4 success=4 normalSuccess=4 failed=0 firstSpawnMs=31.2 lastSpawnMs=78.1 firstNormalSpawnMs=31.2 lastNormalSpawnMs=78.1 spawnCallAvgMs=0.101 p50=0.093 p95=0.126 max=0.126 samples=4 workFrames=2 workAttempts=7 attemptsPerFrameAvg=3.50 maxAttemptsFrame=4 frameWorkAvgMs=0.742 frameWorkMaxMs=0.911 budgetStops=0
[SpawnWave][Classes] wave=3 smoker=1 boomer=0 hunter=1 spitter=1 jockey=0 charger=1 modeSuccessCalls normalNav=4/4 normalDirectorRange=0/0 normalDirectorUnrestricted=0/0 teleportNav=0/0 teleportDirectorRange=0/0 teleportDirectorUnrestricted=0/0
[SpawnWave][Scores] wave=3 samples=4 avg=80.42 min=74.15 max=86.90 qualityAvg=78.63 distAvg=84.22 heightAvg=76.50 flowAvg=79.10 dispersionAvg=70.00 tacticalAvg=87.30 highBonusAvg=3.00 behindPenAvg=1.50 lowHeightPenAvg=0.38
[SpawnWave][Distances] wave=3 directSamples=4 directAvg=482.6 directMin=318.2 directMax=676.4 navSamples=4 navAvg=901.8 navMin=614.2 navMax=1280.7 navRankSamples=4 navRankAvg=901.8 navRankMin=614.2 navRankMax=1280.7 highRankedSamples=0 navEffectiveSamples=4 navEffectiveAvg=843.6 navEffectiveMin=614.2 navEffectiveMax=1149.4 highCompSamples=2 highCompAvg=116.4 highCompMax=131.3 verticalSamples=4 absZAvg=86.3 absZMax=214.7
```

其中 `durationMs` 是完整波周期，`killPhaseMs` 是本波开始到 16 秒倒计时真正启动的时间，`countdownMs` 是独立基础倒计时，`antiBaitExtendedMs` 是到点后因稳定卡位增加的时间。`firstSpawnMs/lastSpawnMs` 包含传送补位，`firstNormalSpawnMs/lastNormalSpawnMs` 只统计普通波队列；这些生成时刻不再充当波次时钟锚点。`plannedAi` 是本次新增 AI 预算，`pendingAtStart` 是上限裁剪后的普通待刷队列。`workFrames/workAttempts` 统计实际推进刷特的帧和尝试数，`maxAttemptsFrame` 是单帧峰值，`frameWorkAvgMs/frameWorkMaxMs` 是整个单帧刷特循环的墙钟耗时，`budgetStops` 表示命中 `inf_spawn_frame_budget_ms` 后仍有工作而主动让出本帧的次数。`Classes` 同时统计普通生成和传送重刷，模式字段采用 `成功数/调用数`，传送不会错误消耗普通波预算。报告覆盖插件实际调用 `L4D2_SpawnSpecial` 的 AI 生成，不把人类玩家从 ghost 状态实体化计入其中。

基准命令：

```sh
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  extensions/anne_spawn_accel/tests/nav_graph_test.cpp \
  extensions/anne_spawn_accel/nav_graph.cpp \
  -o /tmp/anne_nav_graph_test
/tmp/anne_nav_graph_test
```
