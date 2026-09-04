# infected_control 2026-09-04 修复版 5% 矩阵（云8，2026-09-04）

## 结论

- 完成 57 张官方图 × 5%–95%（每 5% 一格），共 1083 格；`c5m5_bridge@10` 是唯一夹具定位失败，其余 1082 格全部进入波次。
- **本次要验收的核心指标全部达标**：1082/1082 进入波次的格都实际生成 12/12，共 12984/12984，**零缺失**；`normal_nav` 12912（99.445%），`normal_director_range` 只有 72（0.555%）；`normal_director_unrestricted` 0。
- 新增的 `[FIND EARLY-EXHAUSTED]` 节流日志在整轮 1083 格、27.5 万行调试日志里**一次都没有触发**，`ownerCapacity` 全程为 0，`[SPAWN TIMEOUT]` 与 `band timeout` 也都是 0。这直接证明「owner 集合被容量硬剔到空 → 静默 Exhausted → 每帧 band++ → 10 帧内落进 Director」这条 09-02 回归路径已经关闭。
- 相对 2026-08-26 基线（同一份扩展 1.4.4）：实际未满格 1 → 0，缺失 2 → 0，Nav 成功 12864 → 12912，Director Range 118 → 72，需要 Director 兜底的格 47 → 22。
- 性能同向改善：均值 `364.595 → 332.378 ms`（-8.84%），P50 `281.2 → 257.8 ms`，P95 `679.6 → 609.3 ms`，max `6734.3 → 6335.9 ms`，超过 1 秒 23 → 17 格，超过 3 秒 4 → 3 格。唯一退步的是 P99（`1601.5 → 1726.5 ms`），来自 `c6m2_bedlam@85` 这一格的重新分布，不是整体趋势。
- **阻塞性缺陷（必须在发布前修）**：仓库工作区里的 `anne_spawn_accel.ext.2.l4d2.so`（1.5.0，`025090ca…`）**无法在生产运行时装载**。SourceMod 报 `bin/libgcc_s.so.1: version 'GCC_7.0.0' not found`——这份 .so 动态链接了新 GCC 的 libgcc 展开符号，而 srcds 强制使用 Valve 自带的老 `libgcc_s.so.1`。因此新 native `AnneSpawn_NavCandidatesCollectTeamEx` 在真机上一次都没被调用过。
- 由此推论，Update_log 里「验证（云4，4 图 × 10 个进度点）」那一段的前提是错的：云4 那轮的 `orchestrate.log` 每次 `sm exts list` 都停在 `Anne Spawn Accel (1.4.4)`，从头到尾跑的都是老扩展。本轮全量矩阵同样只能在扩展 1.4.4 上跑。
- 也就是说：**本轮验收的是插件侧修复在老扩展下的「不排除」退回路径**，而这条路径已经足够把 09-02 的 Director 兜底回归修掉并反超 08-26 基线。扩展 1.5.0 的 `CollectTeamEx` 快路径仍然完全未验证，需要用 `-static-libgcc`（并尽量 `-static-libstdc++`）重新构建后另跑一轮。

## 测试对象

服务器：Anne 云服 #8，宿主机 `mccn.online:18189`，容器 `anne4`，内网 RCON `172.16.0.59:18934`。测试开始与结束都是 `0 humans, 0 bots`。

部署并核对版本：

| 组件 | 测试 SHA-256 | 版本核对 |
|---|---|---|
| `infected_control.smx` | `8a48b1f12c42c775ef8abed4dd48164757451fcf2cfcba2ff6f20c4b9d1e276d` | `Version: 2026-09-04.1 Status: running` |
| `SI_Target_limit.smx` | `05f7ccb46b0d8d4b31063ffd380a81c8224c4e735ab681a5ebc4af7b5e8c5373` | `Version: 1.9 Status: running` |
| `l4d_target_override.smx` | `8066fc32597348c16f1c87595700c7b642ec357bb9f425ca36e035c9e378e37e` | `Version: 2.28 Status: running` |
| `anne_spawn_accel.ext.2.l4d2.so` | `3c9825e64babeb7cf93eedcc4cda3ab1bb5436814540868084a55848bb6d8253` | `Anne Spawn Accel (1.4.4)`，见下 |

夹具：`disabled/test/anne_nav_wave_matrix.smx`（`c3adafa0…`）、`optional/AnneHappy/l4d_CreateSurvivorBot.smx`（`156bcb6c…`）。矩阵执行器 `scripts/run_nav_wave_matrix.py`，`--reuse-map`，与 08-26 基线同一份脚本、同一组 `TEST_CVARS`。

### 扩展 1.5.0 装载失败的证据

`025090ca…` 曾被 `docker cp` 到容器里，但没能成为运行中的镜像：

1. 覆盖同名文件 + `sm exts unload` / `sm exts load` 之后，`sm exts info` 仍然报 `Loaded: Yes (version 1.4.4)`、`Binary info: API version 8 (compiled Aug 25 2026)`。SourceMod 的 unload 没有把 dlopen 引用计数降到 0，同一路径再 dlopen 直接复用了常驻镜像，于是版本号和编译日期都还是旧的——**这个失败模式是静默的**，只看 `sm exts load` 的成功回显会被骗过去。
2. 换成一个没被占用的文件名 `anne_spawn_accel15.ext.2.l4d2.so` 强制新映射，真实错误才暴露：

   ```text
   [SM] Extension anne_spawn_accel15.ext.so failed to load:
     bin/libgcc_s.so.1: version `GCC_7.0.0' not found (required by
     .../extensions/anne_spawn_accel15.ext.2.l4d2.so)
   ```

3. `readelf -V` 对比两份 .so 的 `.gnu.version_r`：

   | | 对 `libgcc_s.so.1` 的版本需求 |
   |---|---|
   | 1.4.4（`3c9825e6…`，可装载） | `GLIBC_2.0` |
   | 1.5.0（`025090ca…`，装不上） | `GCC_7.0.0`、`GLIBC_2.0` |

   容器本身是 Debian 13 / glibc 2.41，`GLIBC_2.32/2.33/2.34` 这些需求都能满足；卡住的只有 srcds 自带的 `/home/louis/l4d2/bin/libgcc_s.so.1`，那是 GCC 4.x 时代的库，没有 `GCC_7.0.0` 这个版本节点。

4. `extensions/anne_spawn_accel/AMBuilder` 里只有 `-fPIC -gdwarf-4` 和 `-pthread -Wl,--strip-debug`，没有 `-static-libgcc`。在 Ubuntu 22.04（GCC 11/12）里构建必然会引入 `GCC_7.0.0` 版本化的展开符号。1.4.4 是用更老的工具链产出的，所以只需要 `GLIBC_2.0`。

影响面不止本次测试：如果这份 .so 就这么发出去，`anne_spawn_accel.autoload` 会在开服时装载失败，`infected_control` 会整局退回没有有向 Nav 加速的状态。建议按 `-static-libgcc` 重建后，用「改文件名强制新映射」的办法在真机上确认 `sm exts info` 报到 1.5.0，再重跑一次全量矩阵。

为了让磁盘状态和实际运行的镜像一致，正式跑矩阵之前已经把 `3c9825e6…`（1.4.4）写回 `anne_spawn_accel.ext.2.l4d2.so` 并重新装载核对。**整轮 1083 格期间，磁盘上和内存里的扩展都是 1.4.4。** 这一点反而让本轮与 08-26 基线在扩展这一维上完全同源，插件改动被单独隔离出来。

## 测试隔离参数

- 生产联动 cvar 按 `cfg/cfgogl/annehappy/shared_settings.cfg`：`l4d_target_override_type 1`、`l4d_target_override_specials 127`、`l4d_target_override_forward 1`、`SI_enable_option 53`、`SI_target_limit_auto 1`、`SI_target_rushman_scope 1`、`inf_nav_team_nearest 1`。`sm_targetlimit_status` 回显 `enable=1 active=1 scope=1`。
- 4 名冻结生还者（`sb_stop 1`、`nb_stop 0`）、12 SI（六职业各 2）、8 秒观察窗、`l4d_infected_limit 12`、`versus_special_respawn_interval 16.0`。
- `inf_score_behind_soft_pct=90`、`inf_spawn_behind_eval_budget=32`、`inf_spawn_nav_band_timeout=3.0`、`inf_spawn_sep_radius=100.0`、`inf_spawn_kernel_radius=280.0`、`inf_spawn_kernel_points=50.0`。
- teleport 关闭（`inf_TeleportSi 0`）、内鬼关闭、Anti-Bait 关闭、`z_common_limit 0`、`director_no_bosses 1`，Director Range 兜底保留。
- 测试期间用 `sv_password` 做隔离，结束清空。

一处需要如实记录的口径偏差：`run_nav_wave_matrix.py` 的 `configure_map()` 用不带引号的 `sm_cvar <name> <value>` 写入 `TEST_CVARS`，所以两个向量 cvar 只有第一个分量生效。调试日志里实际值是 `highSortScale=0.85/1.00/1.00/1.00/1.00/1.00`，而 `TEST_CVARS` 想写的是 `0.85 1.00 0.95 1.00 1.00 1.00`（Hunter 那一档 0.95 被默认值 1.00 取代）；`inf_score_w_disp` 同理只落到 `2.20`。08-26 基线用的是同一份脚本，所以两轮都跑在同一个被截断的口径上，对比不受影响。这条属于矩阵执行器的既有问题，本次没有改动仓库里的脚本。

## 与基线对比

完整性口径与 08-26 报告一致：`entered` 要求确实开始波次；`实际 12/12` 要求 `spawn_success=12` 且 `probe_success=12`；`严格 complete_12` 额外要求探针距离/可见性交叉校验全部满足。

| 指标 | 基线（云3，08-26） | 本轮（云8，09-04） | 变化 |
|---|---:|---:|---:|
| 总格数 | 1083 | 1083 | 0 |
| 进入波次 | 1082 | 1082 | 0 |
| 实际 12/12 | 1081 | **1082** | +1 |
| 实际未满格 | 1 | **0** | -1 |
| 严格 `complete_12` | 1068 | 1072 | +4 |
| 实际生成 / 目标 | 12982 / 12984 | **12984 / 12984** | +2 |
| 缺失 | 2 | **0** | -2 |
| Nav 成功 | 12864（99.091%） | **12912（99.445%）** | +48 |
| Director Range | 118（0.909%） | **72（0.555%）** | -46 |
| Director Unrestricted | 0 | 0 | 0 |
| 需要 Director 兜底的格 | 47 | **22** | -25 |
| Director API calls | 1397 | 1285 | -112 |
| Director API hits | 118 | 72 | -46 |
| Director API misses | 142 | 237 | +95 |
| Director API safety_reject | 986 | 808 | -178 |
| Director API cap_reject | 151 | 168 | +17 |
| `ownerCapacity` | 0 | 0 | 0 |
| `ownerInvalid` | 0 | 0 | 0 |
| `[FIND EARLY-EXHAUSTED]` | 该日志尚不存在 | **0** | — |
| `[SPAWN TIMEOUT]` / `band timeout` | 0 / 0 | 0 / 0 | 0 |
| `normal_nav` 可见性违例 | 8 | 4 | -4 |
| `directed range exhausted`（日志行） | 未统计 | 307 | — |
| teleport 成功 | 0 | 0 | 0 |
| 实际刷点驳回 | 0 | 0 | 0 |

两轮唯一未进入波次的格都是 `c5m5_bridge@10`，夹具报 `actual target Nav has no directed route yet`（本轮的具体回显：`actualPct=7.05 directed(near/long/broad)=13/41/81`），与刷特插件无关。

`[FIND EARLY-EXHAUSTED]` 是这次为「owner 集合被剔空」新加的节流日志，基线版本里没有这条，所以没有同口径对比值。它在本轮 0 次，配合 `ownerCapacity` 恒为 0，说明热循环已经不再因为容量把 owner 剔出集合。

`directed range exhausted` 307 行与 `[SPAWN TIMEOUT]` 0 次要一起看：有向范围耗尽后走的是正常的逐层扩带，3 秒 `inf_spawn_nav_band_timeout` 一次都没有到期，band 推进不再是「10 帧内走完全部分层」。

Director API misses 从 142 涨到 237 看似变差，但它的分母变了——本轮只有 22 格需要进 Director，而这些格里 `c5m5_bridge@5` 一格就占了 136 次 miss。真正的结论是 hits 从 118 降到 72：需要 Director 真正刷出来的特感少了 39%。

## 性能

统一使用插件内部 `server_wave_ms`，两轮各 N=1082；百分位为 nearest-rank，与 08-26 报告同一算法。

| 指标 | 基线（云3） | 本轮（云8） | 变化 |
|---|---:|---:|---:|
| mean | 364.595 ms | 332.378 ms | -32.217 ms（-8.84%） |
| P50 | 281.2 ms | 257.8 ms | -23.4 ms（-8.32%） |
| P95 | 679.6 ms | 609.3 ms | -70.3 ms（-10.34%） |
| P99 | 1601.5 ms | 1726.5 ms | +125.0 ms（+7.81%） |
| max | 6734.3 ms | 6335.9 ms | -398.4 ms（-5.92%） |
| > 1 s | 23 | 17 | -6 |
| > 3 s | 4 | 3 | -1 |
| > 8 s | 0 | 0 | 0 |

P99 是唯一退步项。它落在 `c6m2_bedlam@85`：基线那一格 585.9 ms（8 Nav + 4 Director），本轮变成 6335.9 ms（12 Nav + 0 Director）。同一张图的 `@70/@75/@80` 三格本轮全部变快（3187.5→1812.5、6648.4→2843.7、6734.3→3218.7 ms），`@80` 还从 10/12 补到了 12/12。所以 c6m2 这一段是把长尾在四个进度点之间重新分配了，总体是好的：四格合计从 17156 ms 降到 14211 ms，且不再漏刷。

两轮跑在不同云实例上，刷点本身也有随机性，因此这些数字是强改善信号，但不能单独归因到某一行改动。

## 进度分段

| 分段 | entered | mean（基线 → 本轮） | P95（基线 → 本轮） | 平均 Nav / 波（基线 → 本轮） | Director 次数（基线 → 本轮） | 实际未满 |
|---|---:|---|---|---|---|---:|
| 5%–10% | 113 | 362.997 → 358.852 ms | 609.3 → 593.7 ms | 11.841 → 11.867 | 18 → 15 | 0 |
| 15%–85% | 855 | 369.355 → 329.168 ms | 703.1 → 632.8 ms | 11.915 → 11.956 | 71 → 38 | 0 |
| 90%–95% | 114 | 330.480 → 330.206 ms | 593.7 → 500.0 ms | 11.746 → 11.833 | 29 → 19 | 0 |

改善集中在中段（855 格，均值 -40 ms、Director 次数几乎腰斩），这与「预留把名额瞬间扣光」最容易在常规推进段发生的判断一致。首尾两段的均值基本不动，但 Director 回退次数同样下降。

Director 回退仍然集中在少数几张开阔图：

| 地图 | Director 次数 | 涉及格数 |
|---|---:|---:|
| `c13m4_cutthroatcreek` | 14 | 4 |
| `c12m5_cornfield` | 13 | 4 |
| `c1m3_mall` | 9 | 1 |
| `c5m5_bridge` | 8 | 2 |
| `c12m3_bridge` | 7 | 1 |
| `c10m3_ranchhouse` | 6 | 1 |
| `c2m1_highway` | 4 | 2 |
| 其余 6 张图 | 各 1–2 | 各 1–2 |

57 张图里只有 13 张、22 格出现过 Director 回退；基线是 21 张图、47 格，分布明显更广。

## 关键异常格

### 超过 3 秒的三格（全部 12/12）

| index | 地图进度 | 结果 | Nav / Director | server wave | Director API | 主要过滤 |
|---:|---|---:|---:|---:|---|---|
| 473 | `c6m2_bedlam@85` | 12/12 | 12 / 0 | 6335.9 ms | 303 calls，298 safety reject，5 miss | visibility 15399 |
| 419 | `c5m5_bridge@5` | 12/12 | 6 / 6 | 4343.7 ms | 164 calls，6 hit，136 miss，22 safety reject | stuck 786、visibility 3219 |
| 472 | `c6m2_bedlam@80` | 12/12 | 10 / 2 | 3218.7 ms | 97 calls，2 hit，95 safety reject | visibility 12233 |

三格 `behindBudget=0`，没有 Pending、没有反复 Exhausted、没有 band timeout。机制和基线报告的判断一样：c6m2 的多层紧凑地形让 Nav 可见性过滤持续失败，Director 候选又被安全检查拒绝；差别是本轮 8 秒窗口内**全部补齐了 12 只**，基线的 `@80` 停在 10/12。

`c5m5_bridge@5` 是有向范围耗尽后扩大搜索、再进 Director 的典型格，两轮都慢（2640.6 → 4343.7 ms），本轮 Director hit 6 次（基线 7 次），都是 12/12。

### 其他值得记录的格

- `c1m3_mall@95`（index 57）：12/12，3 Nav + 9 Director，1109.3 ms。57 次 Director API 里 36 次 cap_reject，是本轮单格 Director 依赖最高的一格（基线同格 6 Nav + 6 Director、406.2 ms）。
- `c2m1_highway@90`（index 94）：12/12，9 Nav + 3 Director，2929.6 ms，`behindBudget=904`。过滤以 visibility 15014、stuck 2907 为主，属于开阔终局段的既有长尾。
- `c13m4_cutthroatcreek@35/@40`（index 1033/1034）：12/12，6+6 与 8+4，726.5 / 1703.1 ms。基线同段（`@35`）为 4421.8 ms，本轮明显变快。
- `c5m5_bridge@10`（index 420）：夹具定位失败，未进入波次，两轮相同，不能归因于刷特插件。

### 11 格未满足严格 `complete_12`

除 index 420 之外，其余 10 格都实际生成了 12/12，只是探针交叉校验没满：

| index | 地图进度 | 生成 | 未满足项 |
|---:|---|---:|---|
| 10 | `c1m1_hotel@50` | 12/12 | `nearest_nav_distance` 只有 10 个采样（2 只走 Director） |
| 57 | `c1m3_mall@95` | 12/12 | 同上，只有 3 个采样（9 只走 Director） |
| 208 | `c3m2_swamp@90` | 12/12 | `normal_nav` 可见性违例 1 |
| 297 | `c4m3_sugarmill_b@60` | 12/12 | `normal_nav` 可见性违例 1 |
| 419 | `c5m5_bridge@5` | 12/12 | `nearest_nav_distance` 只有 6 个采样 |
| 749 | `c10m4_mainstreet@40` | 12/12 | `normal_nav` 可见性违例 1 |
| 848 | `c11m4_terminal@60` | 12/12 | `normal_nav` 可见性违例 1 |
| 943 | `c12m4_barn@60` | 12/12 | `nearest_nav_distance` 只有 10 个采样 |
| 1033 | `c13m4_cutthroatcreek@35` | 12/12 | `nearest_nav_distance` 只有 10 个采样 |
| 1034 | `c13m4_cutthroatcreek@40` | 12/12 | `nearest_nav_distance` 只有 11 个采样 |
| 420 | `c5m5_bridge@10` | — | 夹具定位失败，未进入波次 |

`nearest_nav_distance` 采样数不足是探针只对 Nav 模式刷点记这项距离造成的，Director 兜底的特感天然没有这个采样，不是漏刷。基线同口径为 15 格（其中 13 格实际 12/12）。

## 结果文件

- `test_results/20260904_every5_team_exclude_full/results.jsonl`
- `test_results/20260904_every5_team_exclude_full/results.csv`
- `test_results/20260904_every5_team_exclude_full/raw_logs.tar.gz`

文件校验：JSONL 1083 行、CSV 1088 行（含表头，长字段内含换行）、raw_logs 内含 1082 份逐格调试日志切片。

本轮完整调试日志切片（66.4 MB / 275206 行，gzip 后 7.0 MB）与执行日志另存于 `/tmp/anne_ab_test/results/cloud8_full_20260904/`：`full_run.log.gz`、`marker_counts.txt`、`matrix_final.log`、`orchestrate_run.log`、`prestate.json`、`poststate.json`、`analysis.json`。

矩阵起止：宿主机时间 `2026-09-03 14:43:02` → `15:58:08`（UTC），实测 75 分 06 秒，1083 格。

## 云8恢复核对

四个生产文件已按测试前哈希回写并逐项核对（`RESTORE_SHA_OK`）：

```text
d03d40df5f69cbd333b68f1c06654898fd5c85e636e7d01788c1d605f94bafaa  infected_control.smx
05f7ccb46b0d8d4b31063ffd380a81c8224c4e735ab681a5ebc4af7b5e8c5373  SI_Target_limit.smx
8066fc32597348c16f1c87595700c7b642ec357bb9f425ca36e035c9e378e37e  l4d_target_override.smx
3c9825e64babeb7cf93eedcc4cda3ab1bb5436814540868084a55848bb6d8253  anne_spawn_accel.ext.2.l4d2.so
```

这四个哈希与仓库 `HEAD` 一致，也与测试前容器内的实际文件一致；夹具 `anne_nav_wave_matrix.smx`、`l4d_CreateSurvivorBot.smx` 同样按原哈希回写。文件属主与权限也已用 `docker exec -u 0` 复位（`docker cp` 会把文件变成 `root:root`）：

```text
plugins/optional/AnneHappy/infected_control.smx        root:root  644
plugins/optional/AnneHappy/SI_Target_limit.smx         root:root  644
plugins/optional/AnneHappy/l4d_target_override.smx     root:root  644
plugins/optional/AnneHappy/l4d_CreateSurvivorBot.smx   louis:louis 644
plugins/disabled/test/anne_nav_wave_matrix.smx         louis:louis 644
extensions/anne_spawn_accel.ext.2.l4d2.so              louis:louis 755
```

其余恢复项：

- 扩展回到 `Anne Spawn Accel (1.4.4)`；`sm exts list` 共 25 项，与测试前数量一致。
- 三个可选插件与夹具全部卸载（测试前本来就没加载），`sm plugins list` 回到 164 项，`sm plugins load_lock` 已重新生效。
- 引擎 cvar 逐项回到测试前记录值：`sv_password=""`、`sb_stop=0`、`nb_stop=0`、`sv_cheats=0`、`director_no_specials=0`、`director_no_bosses=0`、`z_common_limit=30`、`z_{smoker,boomer,hunter,spitter,jockey,charger}_limit=1`、`z_max_player_zombies=4`、`versus_special_respawn_interval=20`、`sb_all_bot_game=0`、`sv_hibernate_when_empty=0`。
- 插件侧 51 个 `inf_*` / `SI_*` / `l4d_infected_limit` / `l4d_target_override_*` cvar 在插件卸载前逐个写回源码 `CreateConVar` 默认值并复读核对，0 个不符。
- 地图回到 `c2m1_highway`，`status` 为 `0 humans, 0 bots`。

两处需要说明的残留：

1. `z_max_player_zombies` 在第一遍恢复后是 6 而不是测试前的 4——把 `l4d_infected_limit` 写回默认值 6 时，还在运行的 `infected_control` 会同步推一次 `z_max_player_zombies`，插件卸载后这个值留在了引擎里。已在插件卸载后单独改回 4 并复读确认。
2. `sm exts list` 里 Anne Spawn Accel 的编号从 `[10]` 变成了 `[25]`。这只是运行时卸载/重装后追加到列表末尾造成的序号漂移，文件、版本、`sm exts info` 的编译信息完全一致，下次开服重新按目录装载就会回到原位。**除此之外没有未恢复项。**

四个测试前后哈希对照以及完整 `prestate.json` / `poststate.json` 保存在 `/tmp/anne_ab_test/results/cloud8_full_20260904/`；宿主机上的备份与脚本保留于 `/root/anne-full-20260904/`（含 `backup/` 原始文件、`out_final/` 结果、`logs/full_run.log.gz`）。

## 后续建议

1. 用 `-static-libgcc`（并考虑 `-static-libstdc++`）重建 `anne_spawn_accel.ext.2.l4d2.so`，在 `AMBuilder` 的 `linkflags` 里固定下来，避免以后换构建机再犯。
2. 重建后在真机上用「换一个未占用的文件名装载」的办法确认 `sm exts info` 报到 1.5.0，再重跑一次本矩阵，专门验收 `AnneSpawn_NavCandidatesCollectTeamEx` 这条快路径；本轮的 1083 格数据可以直接当那一轮的基线。
3. 订正 Update_log「2026年9月4日」条目里「验证（云4…）」的措辞：那一轮跑的是老扩展 1.4.4，不是 1.5.0。
4. `run_nav_wave_matrix.py` 的 `configure_map()` 写向量 cvar 时缺引号，`inf_nav_high_sort_scale` / `inf_score_w_disp` 只有第一个分量生效。历史轮次都带着这个偏差，修之前先想清楚会不会让新旧数据不可比。

## 后续：扩展 1.5.0 重建后的装载结果

扩展已按建议 1 用 `-static-libgcc` 重建（`dc536708…`），并在云8 上重跑了本矩阵。结果见 [`NAV_WAVE_MATRIX_20260904_TEAM_EXCLUDE_EXT150.md`](NAV_WAVE_MATRIX_20260904_TEAM_EXCLUDE_EXT150.md)。

- 重建版**装载成功**：`readelf -d` 已不再 NEEDED `libgcc_s.so.1`，`sm exts info` 在临时文件名与正式路径 + `docker restart` 两种方式下都报 `1.5.0` / `compiled Sep 3 2026`。本报告「扩展 1.5.0 装载失败的证据」一节描述的 `GCC_7.0.0` 阻塞性缺陷已解除。
- 全量 1083 格在 1.5.0 上跑出的结果与本轮（1.4.4）**在噪声量级内持平**：Nav 12912 → 12906、Director Range 72 → 77、均值 332.378 → 359.808 ms；相对 08-26 基线的收益全部保住。
- 原因是口径：本报告使用的 4 名生还者 / 12 SI / `SI_target_limit_auto 1` 口径下每人容量为 5，没有成员会达到上限，`CollectTeamEx` 的排除列表恒为空、与 `CollectTeam` 走同一段代码。因此本轮 1083 格数据可以直接当作 1.5.0 的回归基线，但**不能**用来衡量快路径的收益。
- 同时订正本报告隐含的一个验收预期：`ownerCapacity` 在新扩展下恒为 0 才是正常——排除已在 native 内部按「最近目标重算」吸收，被排除 owner 的候选不会回到插件热循环。
