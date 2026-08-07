# 官图每 5% 进度 12 特最终矩阵

测试日期：2026-08-06

## 结论

- 57 张官图，每张测试 5% 到 95%，步长 5%，共 1083 个场景。
- 1083/1083 场景均完成 12 特生成，并观察到 12 只同时存活。
- 12996 次成功生成全部来自有向 Nav 候选；限距 Director 和 unrestricted Director 成功数均为 0。
- 12996 次出生可见性复核违规为 0。108 次实际落点拒绝均成功换点，没有导致缺特。
- 1083 个场景的有向图均为 `topology=complete`。
- 只有 `c6m2_bedlam@85%` 超过 3 秒，刷满时间 6320.3ms；其余 1082 个场景均在 3 秒内。该长尾按当前验收标准保留，不再针对单点提高全局压力。

## 测试环境

测试在 `42.193.195.79:19365` 的 `anne1` 容器内运行，通过真实 RCON 切换 57 张官图，加载实际 Linux 扩展和生产 `infected_control.smx`。实例为 2 核 9950X、4GB 内存。

每个场景把 4 名生还者放在目标 Flow 附近的 4 个不同 NavArea，最小间距不低于 128，全队跨度不超过 800。朝向以局部 Flow 前进方向为中心，分别偏移 -45、-15、15、45 度。生还者冻结，特感保留重力、碰撞、世界伤害和 `trigger_hurt`。

同图复用测试点前，执行器在清空上一波后额外等待 0.65 秒，避开生产 NavArea 0.5 秒冷却对下一测试点的污染。该等待不计入 `server_wave_ms`。

本轮压力参数：

| CVar | 值 |
| --- | ---: |
| `inf_spawn_attempts_per_frame` | 8 |
| `inf_spawn_frame_budget_ms` | 4.0ms |
| `inf_spawn_nav_candidates_per_slice` | 512 |
| `inf_spawn_nav_expensive_per_slice` | 16 |
| `inf_spawn_nav_slice_budget_ms` | 2.0ms |
| `inf_spawn_failed_cycle_retry` | 0.10s |

## 生成结果

| 指标 | 结果 |
| --- | ---: |
| 场景完成 | 1083 / 1083 |
| 同时存活 12 只 | 1083 / 1083 |
| 成功生成 | 12996 |
| 有向 Nav 成功 | 12996 |
| 限距 Director 成功 | 0 |
| unrestricted Director 成功 | 0 |
| 实际落点拒绝并换点 | 108 |
| 可见性违规 | 0 |
| 完整有向图 | 1083 / 1083 |

普通刷特为每个职业维护独立的目标生还者、搜索距离档和失败退避。某职业扫完当前目标的三级 Nav 与两级 Director 仍失败时，只轮换该职业的目标，不会重置或污染其他职业的搜索游标。成功生成后，该职业下次仍从第一档职业范围开始。

## Director API 兜底

1083 场景矩阵运行时，Director API 返回点仍经过路径、距离与安全复核。本轮只有两个场景调用 API：

| 地图与进度 | API 调用 | API 命中 | 最终有向 Nav |
| --- | ---: | ---: | ---: |
| `c6m2_bedlam@80%` | 2 | 0 | 12 |
| `c6m2_bedlam@85%` | 106 | 0 | 12 |

总计 108 次调用、0 次通过旧复核；两处最终都由有向 Nav 完成 12 特。

矩阵完成后按最新策略改为信任 Director API：API 返回成功就直接调用 `L4D2_SpawnSpecial`，不再复算有向路径、职业距离、可见性、stuck、预测落点、伤害区域或最小直线距离。实体生成后只确认类型、存活状态和短暂稳定存在，不做位置安全复核。

使用 `inf_spawn_score_floor=100` 强制 Nav 候选失败的隔离测试结果：API 13/13 返回坐标，最终 12/12 均由 `normal_director_range` 生成，Nav 成功为 0，刷满时间 2054.6ms。1 只 Smoker 因实体在 1 秒内未稳定存在而重试；13 次 API 点的位置安全复核耗时均为 0.000ms。测试后 `inf_spawn_score_floor` 已恢复为 0。

## 刷满时间

`server_wave_ms` 从开波到第 12 只成功提交，不包含测试点准备和 0.65 秒重置等待：

| 指标 | 平均 | p50 | p95 | p99 | 最大 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 12 特刷满 | 463.0ms | 414.0ms | 655.4ms | 1091.5ms | 6320.3ms |
| 观察器墙钟 | 671.0ms | 623.1ms | 867.3ms | 1314.6ms | 6594.3ms |

16 个场景超过 1 秒，只有 1 个场景超过 3 秒。`c6m2_bedlam@85%` 的前 7 只在 414.0ms 内完成，后续 Jockey、Boomer、Charger 在冻结且分散的四眼位下反复被距离、可见性、stuck 和 bucket 过滤，最终在 6320.3ms 完成 12/12；不是图不完整或 API 生成失败。

## 生成距离

| 距离 | 平均 | p50 | p95 | p99 | 最大 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 目标生还者三维直线 | 579.4 | 504.0 | 1096.8 | 1472.8 | 2547.4 |
| 全队最近三维直线 | 466.9 | 401.7 | 889.9 | 1220.6 | 2222.6 |
| 原始有向 Nav 路径 | 773.8 | 700.8 | 1394.0 | 1833.0 | 2910.2 |
| 高点补偿后 Nav 路径 | 762.2 | 688.8 | 1374.4 | 1829.5 | 2910.2 |

全队最近直线距离用于 250 单位安全排除；职业 min/max、距离评分和候选排序使用有向 Nav 路径距离。Smoker/Hunter 高点只修改有效 Nav 距离，不修改原始路径日志和 250 单位直线安全距离。

## 性能

单次 `L4D2_SpawnSpecial` 调用平均 8.526ms，p50 7.812ms，p95 11.718ms，最大 19.531ms。该 native 是不可抢占调用，因此个别实际生成帧可能短暂超过 128 tick 的 7.8125ms 帧预算；插件通过每帧次数和 4ms 软预算把连续工作拆开，不能在 native 执行中途让出。

测试期间共采样 95586 个服务器帧：

| 指标 | 结果 |
| --- | ---: |
| 平均服务器帧时间 | 7.776ms |
| 场景 `frame_max_ms` 中位 | 15.625ms |
| 全部样本超过 1 tick | 20.71% |
| 全部样本超过 2 tick | 1.242% |
| 全部样本超过 4 tick | 0.001%（1 帧） |
| 最大服务器帧时间 | 37.109ms |

这些是整台测试服务器的帧时间，包含引擎、测试插件、地图实体和实际生成 native，不能全部归因于 `infected_control`。结果显示会有实际刷特帧的瞬时下降，但没有持续性的 128 tick 严重失速。较弱机器可把压力参数降到 `4 / 2.0ms / 256 / 8 / 1.0ms`。

37.109ms 实际是平均 7.776ms 的 4.77 倍，不是超过 5 倍；它占用约 4.75 个 128 tick 帧槽，单帧瞬时等效 `sv` 约为 26.95。net_graph 显示的是一段窗口的统计值，不会因为一个孤立峰值就持续显示 27。若假设窗口内其余帧都为 7.776ms，仅出现这一帧峰值，则 32/50/64/128 帧窗口的平均 `sv` 估算分别为 115.0/119.6/121.4/124.9；把 `var` 近似为该窗口帧时间的标准差，则约为 5.10/4.11/3.64/2.58ms。由于本轮只保存了汇总计数和最大值，没有保存完整连续帧序列与客户端实际统计窗口，所以无法从 37.109ms 单点反推出精确的 net_graph `sv`/`var`。多个峰值连续聚集时，`sv` 会比上述估算更低，`var` 更高。

## 部署状态

- 本地与 anne1 的生产 SMX SHA256 均为 `42d94599b5cc0175e9de8be12afd62c9b2a1bf6d3e4d692203319db217b75ca5`。
- `optional/AnneHappy/infected_control.smx` 状态为 `running`，未重启容器。
- `inf_spawn_perf_stats=1`，继续记录实服波次、位置、评分和性能日志。

## 产物

- 汇总 CSV：`docs/infected_control_refactor/test_results/20260806_every5_perclass_final/results.csv`
- 完整 JSONL：`docs/infected_control_refactor/test_results/20260806_every5_perclass_final/results.jsonl`
- 1083 份原始日志：`docs/infected_control_refactor/test_results/20260806_every5_perclass_final/raw_logs.tar.gz`
- API 直出强制测试：`docs/infected_control_refactor/test_results/20260806_api_direct_forced/`
- 矩阵执行器：`scripts/run_nav_wave_matrix.py`
- SourcePawn 探针：`addons/sourcemod/scripting/disabled/test/anne_nav_wave_matrix.sp`
