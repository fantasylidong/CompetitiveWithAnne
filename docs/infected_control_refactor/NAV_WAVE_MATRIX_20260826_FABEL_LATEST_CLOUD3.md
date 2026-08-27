# infected_control Fabel 最新版 5% 矩阵（云3，2026-08-26）

## 结论

- 完成 57 张官方图 × 5%–95%（每 5% 一格），共 1083 格。
- `c5m5_bridge@10` 是唯一夹具定位失败；其余 1082 格均进入波次。
- 进入波次的格中，1081/1082 实际生成 12/12；共生成 12982/12984，只缺 2。唯一实际未满为 `c6m2_bedlam@80` 的 10/12。
- 严格 `complete_12` 为 1068/1083；其中 13 格实际已经 12/12，只是探针距离/可见性交叉校验未满足，不能当作漏刷。
- 相对上一轮云2：实际 12/12 从 1077 增至 1081，缺失从 20 降到 2，Nav 成功从 12824 增至 12864，Director Range 从 140 降到 118。
- 性能明显改善：均值 `435.898 -> 364.595 ms`，P95 `898.4 -> 679.6 ms`，P99 `2218.7 -> 1726.5 ms`，超过 3 秒从 7 格降到 4 格。
- Fabel 新增的 `behindBudget=32` 确实命中：累计跳过 20489 个候选、64 格非零。但它没有解决 `c6m2@70/75/80` 长尾；这些格 `behindBudget=0`，主要被 visibility 过滤和 Director `safety_reject` 卡住。
- 仍有残余风险：`c6m2@80` 在 8 秒观察窗结束时剩余队列 2；`c6m2@70/75` 和 `c13m4@35` 的服务端波耗时超过 3 秒。

## 测试对象

本轮从工作区当前源码重新编译并部署完整联动栈：

| 组件 | 测试 SHA-256 |
|---|---|
| `infected_control.smx` | `17351a7e15052b89edd5e2afa558ee2e3b3e2fe2aee8addce718217452c8b823` |
| `SI_Target_limit.smx` | `e2121827d9b538b64a774eb704c64d9ed356f9b7a79901872df8ba50dc941c83` |
| `l4d_target_override.smx` | `7cca10e2f79f1724283f95e62f8874c6a516104359b8cea9f9388e0bdaa72d97` |
| `anne_spawn_accel.ext.2.l4d2.so` | `3c9825e64babeb7cf93eedcc4cda3ab1bb5436814540868084a55848bb6d8253` |

编译使用 SourcePawn 1.12.0.7230，三项插件与矩阵夹具均成功；只有项目既有的 `CreateDialog` deprecated 警告。

测试隔离显式固定：

- `inf_score_behind_soft_pct=90`
- `inf_spawn_behind_eval_budget=32`
- `inf_spawn_nav_band_timeout=3.0`
- 4 名冻结生还者、12 SI（六职业各 2）、8 秒观察窗
- team-nearest Nav 开启；teleport 关闭；Director Range fallback 保留

服务器：Anne 云服 #3，容器 `anne3`，内网 RCON `172.16.0.60:18923`。

## 与上一轮对比

完整性口径：`entered` 要求确实开始波次；`actual 12/12` 要求 `spawn_success=12` 且 `probe_success=12`。

| 指标 | 上一轮云2 | Fabel 最新版云3 | 变化 |
|---|---:|---:|---:|
| 总格数 | 1083 | 1083 | 0 |
| 严格 `complete_12` | 1060 | 1068 | +8 |
| 进入波次 | 1082 | 1082 | 0 |
| 实际 12/12 | 1077 | 1081 | +4 |
| 实际未满格 | 5 | 1 | -4 |
| 实际生成 / 目标 | 12964 / 12984 | 12982 / 12984 | +18 |
| 缺失 | 20 | 2 | -18 |
| Nav 成功 | 12824（98.920%） | 12864（99.091%） | +40 |
| Director Range | 140 | 118 | -22 |
| Director 成功兜底格 | 47 | 47 | 0 |
| Director Unrestricted | 0 | 0 | 0 |

两轮唯一未进入波次的格均为 `c5m5_bridge@10`。

## 性能

统一使用插件内部 `server_wave_ms`，两轮各 N=1082；百分位为 nearest-rank。

| 指标 | 上一轮云2 | Fabel 最新版云3 | 变化 |
|---|---:|---:|---:|
| mean | 435.898 ms | 364.595 ms | -71.303 ms（-16.36%） |
| P50 | 312.5 ms | 281.2 ms | -31.3 ms（-10.02%） |
| P95 | 898.4 ms | 679.6 ms | -218.8 ms（-24.35%） |
| P99 | 2218.7 ms | 1726.5 ms | -492.2 ms（-22.18%） |
| max | 7640.6 ms | 6734.3 ms | -906.3 ms（-11.86%） |
| > 1 s | 40 | 23 | -17 |
| > 3 s | 7 | 4 | -3 |
| > 8 s | 0 | 0 | 0 |

本轮和上一轮运行于不同云实例，刷点也有随机性，因此这些数字是强改善信号，但不能单独归因于某一行改动。

## 进度分段

| 分段 | entered N | mean | P95 | 平均 Nav / 波 | Director 次数 | 实际未满 |
|---|---:|---:|---:|---:|---:|---:|
| 5%–10% | 113 | 362.997 ms | 679.6 ms | 11.841 | 18 | 0 |
| 15%–85% | 855 | 369.355 ms | 703.1 ms | 11.915 | 71 | 1 |
| 90%–95% | 114 | 330.480 ms | 617.1 ms | 11.746 | 29 | 0 |

尾段每波 Director 回退更集中：90%–95% 共 114 波、29 次；开局 5%–10% 共 113 波、18 次；中段 855 波、71 次。但尾段的均值和 P95 并没有变慢，也没有实际少刷。

## behindBudget

| 指标 | 结果 |
|---|---:|
| 累计跳过候选 | 20489 |
| 非零格 | 64 / 1082 |
| 单格最大 | 2287（`c5m5_bridge@80`，index 434） |
| 90%–95% 合计 | 8922，21 格非零 |
| 80%–85% 合计 | 7910，26 格非零 |

旧轮没有 `behindBudget` 字段，无法同口径比较。

值得注意：非零命中并不只出现在夹具 requested 90%/95%，而是分布于 35%–95%。例如 `c4m5_milltown_escape@35` 的夹具实际均值为 36.61%，但记录了 `behindBudget=372`。源码阈值判断使用运行时映射的 owner `centerBucket >= 90`，夹具百分比使用路线定位口径；两者会分叉。本轮能证明预算保护确实工作，但不能证明它只在夹具尾段生效。后续若要验收这一点，需要把每次命中时的 owner、`centerBucket` 和夹具 route percent 同时落盘。

`ownerInvalid`、`ownerCapacity` 在 1082 格中仍全部为 0；本矩阵没有触发 owner skip / owner 达限分支。

## 关键异常

### `c6m2_bedlam@70/75/80`

| index | 进度 | 结果 | Nav / Director | server wave | visibility | Director API |
|---:|---:|---:|---:|---:|---:|---|
| 470 | 70% | 12/12 | 12 / 0 | 3187.5 ms | 4762 | 102 calls，102 safety reject |
| 471 | 75% | 12/12 | 12 / 0 | 6648.4 ms | 21449 | 225 calls，225 safety reject |
| 472 | 80% | 10/12 | 10 / 0 | 6734.3 ms | 35658 | 333 calls，330 safety reject，3 miss |

三格 `behindBudget=0`，未发现 Pending、反复 Exhausted 或 `band timeout` 日志。80% 的最终 Summary 为：`durationMs=8203.1 remainingQueue=2 success=10 workAttempts=4105`。这说明队列没有停，但 Nav 可见性过滤持续失败，Director 候选又被安全检查拒绝，8 秒窗口内没能补上最后 2 只。

### 其他高回退 / 长尾

- `c13m4_cutthroatcreek@35`（index 1033）：12/12，6 Nav + 6 Director，4421.8 ms；`behindBudget=0`。过滤以 visibility=14442、separation=5724、stuck=4819 为主，Director 69 calls 中 58 次 cap reject。
- `c12m3_bridge@95`（index 931）：12/12，3 Nav + 9 Director，1007.8 ms；`behindBudget=1431`。这是预算跳过大量后方候选后及时进入 Director 兜底的直接证据。
- `c5m5_bridge@5`（index 419）：12/12，5 Nav + 7 Director，2640.6 ms；`behindBudget=0`。有向范围耗尽后扩大搜索，Director 107 calls 中 7 hit、69 miss、31 safety reject。
- `c5m5_bridge@10`（index 420）：夹具报 `actual target Nav has no directed route yet`，没有进入波次，不能归因于刷特插件。

本轮超过 3 秒的完整清单：

| index | 地图进度 | 结果 | Nav / Director | server wave |
|---:|---|---:|---:|---:|
| 472 | `c6m2_bedlam@80` | 10/12 | 10 / 0 | 6734.3 ms |
| 471 | `c6m2_bedlam@75` | 12/12 | 12 / 0 | 6648.4 ms |
| 1033 | `c13m4_cutthroatcreek@35` | 12/12 | 6 / 6 | 4421.8 ms |
| 470 | `c6m2_bedlam@70` | 12/12 | 12 / 0 | 3187.5 ms |

## 结果文件

- `test_results/20260826_every5_cloud3_fabel_latest/results.jsonl`
- `test_results/20260826_every5_cloud3_fabel_latest/results.csv`
- `test_results/20260826_every5_cloud3_fabel_latest/raw_logs.tar.gz`

文件校验：JSONL 1083 行、CSV 1084 行（含表头）。

## 云3恢复验收

测试结束后已恢复测试前四个生产文件并重启 `anne3`：

```text
d0ed03cd2963e0606dfc9a06e703465e7b1782c201123879c25ccc52a61d99a0  infected_control.smx
607cce511fc07588f9203b725b9d0a6988882ae67c3378399d447acec8971494  SI_Target_limit.smx
a1cd6e3aa77c883c0889477d6048e43965ab62aa52997cc246e7426d2d14518b  l4d_target_override.smx
ddb0cdd0be458496c2d0375c9069efcd8ca2f96a589f6412cf680214239275ed  anne_spawn_accel.ext.2.l4d2.so
```

恢复后：`c2m1_highway`、0 human、0 bot；测试插件与三项可选插件均未加载；`sv_password=""`、`sb_stop=0`、`director_no_bosses=0`、`z_common_limit=30`。

远端恢复目录保留于：`/root/anne-nav-fabel-latest-cloud3-20260826.6WE9uE`。
