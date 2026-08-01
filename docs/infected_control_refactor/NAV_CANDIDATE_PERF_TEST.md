# 有向 Nav 候选性能测试

测试日期：2026-08-01

## 测试对象

- 合成有向图：10,000 个 NavArea，60,000 条有向边。
- 生还者：4 个眼位。
- 候选规则：`candidate -> target` 有向可达，排除距任一生还者不足 250 单位的 Nav 中心，按目标空间距离升序。
- 编译：Apple Clang 17，`-std=c++17 -O2 -Wall -Wextra -Werror`。
- 主机：Apple M4。
- 每轮包含反向 Dijkstra、全队距离过滤和候选排序，共测 200 次。

## 正确性断言

测试程序会直接失败，除非以下条件全部成立：

- 在 `A -> B -> C` 图中，以 C 为目标时 A/B/C 可达；以 A 为目标时 B/C 不可达。
- 输出 areaIdx 与目标距离数量一致，路径距离覆盖完整图。
- 输出目标距离单调递增。
- 每个输出 Nav 中心到 4 名生还者都至少 250 单位。
- 每个输出 Nav 都有有限的 `candidate -> target` 路径距离。

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
```

普通独立运行多轮的本机 p50 约 0.25 到 0.32ms；同时进行完整扩展构建时有一轮 p50 0.53ms、最大 2.17ms。以四名生还者估算，0.1 秒热刷新约消耗单核 1% 到 2.1% 的 worker CPU，观测 p95 上界约 4%；1 秒空闲刷新约为其十分之一。工作由两个有界 worker 执行，不占用游戏主线程的 1ms 搜索预算。

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

每次实际执行 `L4D2_SpawnSpecial` 都写一行 `[SpawnWave][Spawn]`。下面仅为字段格式示例，数值不是伪造的实服测试结果：

```text
[SpawnWave][Spawn] wave=3 seq=1 result=success mode=normal_nav class=Hunter entity=7 waveElapsedMs=184.4 spawnCallMs=0.093 request=(123.0 456.0 78.0) actualValid=1 actual=(123.2 455.8 78.0) score=82.31 base=80.44 dist=91.20 height=74.00 flow=78.50 dispersion=70.00 tactical=89.30 area=421 bucket=57 target=2
```

字段含义：

- `waveElapsedMs`：从本波开始到这只特感生成的真实游戏时间。
- `spawnCallMs`：最终距离复核和 `L4D2_SpawnSpecial` 调用耗时，不冒充跨帧候选搜索耗时。
- `request/actual`：请求坐标和实体生成后的实际坐标；`actualValid=0` 表示生成失败或实体坐标尚不可读。
- `score/base/dist/height/flow/dispersion/tactical`：最终 Nav 候选的总分与主要分项。
- `mode`：区分普通/传送、Nav 候选/导演范围兜底/无限制兜底。导演兜底没有 `SpawnScoreDbg`，固定记录 `score=N/A`。

下一波开始、回合结束、地图结束或插件停止时会自动写最终总结；`sm_spawnperf` 写当前波快照但不会结束本波：

```text
[SpawnWave][Summary] state=final reason=next_wave wave=3 durationMs=16002.1 plannedAi=4 pendingAtStart=4 remainingQueue=0 spawnCalls=4 success=4 failed=0 firstSpawnMs=184.4 lastSpawnMs=712.8 spawnCallAvgMs=0.101 p50=0.093 p95=0.126 max=0.126 samples=4
[SpawnWave][Classes] wave=3 smoker=1 boomer=0 hunter=1 spitter=1 jockey=0 charger=1 modeSuccessCalls normalNav=4/4 normalDirectorRange=0/0 normalDirectorUnrestricted=0/0 teleportNav=0/0 teleportDirectorRange=0/0 teleportDirectorUnrestricted=0/0
[SpawnWave][Scores] wave=3 samples=4 avg=80.42 min=74.15 max=86.90 baseAvg=78.63 distAvg=84.22 heightAvg=76.50 flowAvg=79.10 dispersionAvg=70.00 tacticalAvg=87.30
```

其中 `durationMs` 是完整波间隔，`lastSpawnMs` 才是本波最后一只成功生成的完成时间；`plannedAi` 是本次新增 AI 预算，`pendingAtStart` 是上限裁剪后的普通待刷队列。`Classes` 同时统计普通生成和传送重刷，模式字段采用 `成功数/调用数`，传送不会错误消耗普通波预算。报告覆盖插件实际调用 `L4D2_SpawnSpecial` 的 AI 生成，不把人类玩家从 ghost 状态实体化计入其中。

基准命令：

```sh
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
  extensions/anne_spawn_accel/tests/nav_graph_test.cpp \
  extensions/anne_spawn_accel/nav_graph.cpp \
  -o /tmp/anne_nav_graph_test
/tmp/anne_nav_graph_test
```
