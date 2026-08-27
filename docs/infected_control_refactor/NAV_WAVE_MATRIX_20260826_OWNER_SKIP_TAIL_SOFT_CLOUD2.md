# infected_control owner skip / tail soft 5% 矩阵（云2，2026-08-26）

## 结论

- owner 无效或达到 `SITargetLimit` 时，搜索现在会记录原因、消费当前候选并继续，不再重置游标后返回 `Pending`。
- 新矩阵完成 57 张官方图 × 5%–95%（每 5% 一格）共 1083 格；除 `c5m5_bridge@10` 已知夹具定位失败外，1082 格均进入波次。
- 进入波次的格中，1077/1082 实际生成 12/12；共生成 12964/12984，只缺 20。严格交叉校验为 1060/1083。
- Nav 成功从旧轮 12699 提高到 12824，Director Range 从 275 降到 140；但真实缺失从 10 增到 20。不能把更少回退等同于更高完整性。
- `ownerInvalid`、`ownerCapacity` 在 1082 格和原始日志 42575 处统计中全部为 0。本矩阵证明改动没有产生普遍回归，但没有触发 owner skip 分支，因此不能作为该分支已运行验证的证据。
- 新旧轮分别运行于云2和云1，且刷点有随机性。性能均值、长尾和逐格差异只能作为观察，不能单独归因于本次改动。

## 改动与统计

`spawn_core.inc` 的队伍最近 Nav 热路径改为：

1. 读出候选并先增加 `inspected`。
2. owner 已无效：`ownerInvalid++`，跳过当前候选。
3. owner 已达到 limit：`ownerCapacity++`，跳过当前候选。
4. owner frame 无法绑定：跳过当前候选。
5. 只有候选源返回 Pending 时，搜索才返回 `SpawnSearch_Pending`。

统计同时写入：

- `[FIND FAIL] ... ownerInvalid=... ownerCapacity=...`
- `[SpawnPerf][12SI] filters ... ownerInvalid=... ownerCapacity=...`
- 矩阵 JSONL / CSV 的 `filter_stats`

编译命令：

```bash
scripts/spcomp-docker.sh \
  addons/sourcemod/scripting/optional/AnneHappy/infected_control.sp \
  addons/sourcemod/plugins/optional/AnneHappy/infected_control.smx
```

编译成功，只有项目既有的 `CreateDialog` deprecated 警告。测试 SMX SHA-256：

```text
a5e7cb4d0f1a262b1dcb156a970d10dac24d9b1e783c220409aed9e54285cad9
```

## 测试条件

- 服务器：Anne 云服 #2，容器 `anne2`，`172.16.0.60:18922`
- 测试范围：57 张官方图，5%–95%，步长 5%，共 1083 格
- 每格：4 名冻结生还者、12 SI（六职业各 2）、8 秒观察窗
- 队伍最近 Nav：开启
- 同桶比例限制：`inf_spawn_bucket_ratio=0`
- owner Flow >= 90：不执行 behindFlow 硬拒绝，仍保留扣分
- teleport：关闭；Director 内部 Range fallback：保留
- owner / SI limit 栈：`l4d_target_override`、`SI_Target_limit`、`infected_control`

结果文件：

- `test_results/20260826_every5_cloud2_owner_skip_tail_soft/results.jsonl`
- `test_results/20260826_every5_cloud2_owner_skip_tail_soft/results.csv`
- `test_results/20260826_every5_cloud2_owner_skip_tail_soft/raw_logs.tar.gz`

## 完整性

| 指标 | 旧轮（云1） | 新轮（云2） |
|---|---:|---:|
| 总格数 | 1083 | 1083 |
| 进入波次 | 1082 | 1082 |
| 实际 12/12 | 1079 | 1077 |
| 严格 `complete_12` | 1071 | 1060 |
| 实际生成 / 目标 | 12974 / 12984 | 12964 / 12984 |
| 缺失 | 10 | 20 |
| Nav 成功 | 12699（97.88%） | 12824（98.92%） |
| Director Range 成功 | 275（2.12%） | 140（1.08%） |
| Director Unrestricted | 0 | 0 |
| 使用 Director 成功兜底的格 | 93 | 47 |

新轮真实不足 12 的 5 格：

| 地图进度 | 结果 | Nav | Director Range | 剩余队列 |
|---|---:|---:|---:|---:|
| `c2m4_barns@90` | 6/12 | 6 | 0 | 6 |
| `c2m4_barns@95` | 8/12 | 8 | 0 | 4 |
| `c3m4_plantation@65` | 8/12 | 8 | 0 | 4 |
| `c6m2_bedlam@75` | 11/12 | 10 | 1 | 1 |
| `c14m1_junkyard@75` | 7/12 | 7 | 0 | 5 |

另有 17 格实际 12/12，但因探针最近 Nav 样本不足或发生一次 Nav 可见性交叉校验违规而被严格标记为 `complete_12=false`。`c5m5_bridge@10` 是唯一未进入波次的夹具定位失败：4 人实际位于 3.91%–7.17%，未通过 10% 格的 ±5 容差。

旧轮三个真实未满点的新结果：

| 地图进度 | 旧轮 | 新轮 | 观察 |
|---|---:|---:|---|
| `c3m4_plantation@65` | 7/12 | 8/12 | 多 1，只，仍未满 |
| `c5m3_cemetery@70` | 11/12 | 12/12 | 恢复满编，Nav 8 + Director 4 |
| `c13m2_southpinestream@15` | 8/12 | 12/12 | 恢复满编，纯 Nav 12 |

## Director API

| 指标 | 旧轮 | 新轮 |
|---|---:|---:|
| calls | 2203 | 1619 |
| hits | 275 | 140 |
| misses | 316 | 208 |
| request cap rejects | 629 | 356 |
| request safety rejects | 983 | 915 |
| actual cap rejects | 0 | 0 |

85%–95% 段：Director Range 成功从 127 降到 49，兜底格从 40 降到 13；Nav 比例从 93.81% 升到 97.60%。但该段实际缺失从 0 增到 10，说明“更少回退”没有转化为更高完整性。`c2m4_barns@90/95` 旧轮均靠 4 次 Director 成功补满，新轮 Director API calls 为 0 并分别停在 6/12、8/12，值得后续单点回放。

## 性能

统一用插件内部 `server_wave_ms`，排除无波次的 `c5m5_bridge@10`。百分位采用 nearest-rank：`rank=ceil(p*N)`。

| 指标 | 旧轮（云1） | 新轮（云2） |
|---|---:|---:|
| N | 1082 | 1082 |
| mean | 430.418 ms | 435.898 ms |
| P50 | 320.3 ms | 312.5 ms |
| P95 | 890.6 ms | 898.4 ms |
| P99 | 2046.8 ms | 2218.7 ms |
| max | 7679.6 ms | 7640.6 ms |
| > 1 s | 41 | 40 |
| > 3 s | 5 | 7 |
| > 8 s | 0 | 0 |

同格差值（新减旧）：均值 `+5.481 ms`，中位数 `0.0 ms`；517 格改善、509 格变慢、56 格相等。85%–95% 段均值 `-5.021 ms`、中位数 `-23.4 ms`，但配对差 P95 为 `+718.7 ms`，说明典型格略快、少数长尾更抖。

结论：中位性能基本持平；均值、P95、P99 与 >3 秒样本略差。考虑跨云和随机性，没有足够证据判定本次版本系统性更快或更慢。

## owner 统计与 Pending 判断

- 有 `filter_stats` 的 1082 格：`ownerInvalid=0`、`ownerCapacity=0`。
- 原始归档 1082 个日志中，42575 处 owner 字段（含 37165 条 `[FIND FAIL]`）全部为 0。
- 抽查的所有 `[FIND FAIL]` 都有 `inspected>0`，未发现 owner 导致的 inspected=0 空转。
- `c3m4@65` 主要耗在 separation/path/score；`c2m4@90/95` 主要耗在 visibility/separation/stuck；`c6m2@75/85` 主要耗在 visibility；`c14m1@75` 主要耗在 visibility/separation/stuck。
- 旧轮 `c3m4@65` 和 `c13m2@15` 同样有正的 `inspected` 并推进到候选耗尽；旧格式没有 owner 计数或 slice Pending 原因，不能从旧日志证明当时触发了 owner ResetCursor 路径。

因此：源码中的无进度路径已经移除，统计链路也已落盘；但这套冻结 bot 矩阵没有让 owner 在候选构建与消费之间变成无效/满 limit，尚未运行命中修复分支。后续应补一个强制 owner 达限额/失效的单格夹具，并记录 `SpawnCandidateRead_Pending` 次数、`graphFetchOffset` 前进量和 owner skip 次数，才能完成该分支的功能验收。

## 云2恢复验收

测试结束后已恢复原始文件并重启 `anne2`：

```text
d0ed03cd2963e0606dfc9a06e703465e7b1782c201123879c25ccc52a61d99a0  infected_control.smx
607cce511fc07588f9203b725b9d0a6988882ae67c3378399d447acec8971494  SI_Target_limit.smx
ddb0cdd0be458496c2d0375c9069efcd8ca2f96a589f6412cf680214239275ed  anne_spawn_accel.ext.2.l4d2.so
```

恢复后：`c2m1_highway`、0 human、0 bot；测试插件及三项临时 owner/SI 插件均未加载；`sv_password=""`、`sb_stop=0`、`director_no_bosses=0`、`z_common_limit=30`。

远端恢复目录保留于：`/root/anne-nav-owner-skip-cloud2-20260826.PoihtU`。
