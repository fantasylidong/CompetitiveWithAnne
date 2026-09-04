# anne_spawn_accel 1.5.0 重建版装载确认 + 5% 矩阵（云8，2026-09-04）

本轮是 [`NAV_WAVE_MATRIX_20260904_TEAM_EXCLUDE_FULL.md`](NAV_WAVE_MATRIX_20260904_TEAM_EXCLUDE_FULL.md) 的续集。上一轮的阻塞性缺陷是 1.5.0 扩展链接了新 GCC 的 libgcc 展开符号、在真机上装不上，整轮只能跑在扩展 1.4.4 上。扩展已按建议用 `-static-libgcc` 重建，本轮要确认它真的被装载，并验收 `AnneSpawn_NavCandidatesCollectTeamEx` 快路径。

## 结论

- **扩展 1.5.0 重建版在真机上装载成功，`-static-libgcc` 修复有效。** 三个独立证据：临时文件名 `anne_spawn_accel_150` 强制新映射后 `sm exts info` 报 `Loaded: Yes (version 1.5.0)`、`compiled Sep 3 2026`，SourceMod 错误日志 0 行相关；覆盖正式路径 + `docker restart anne4` 后自动装载同样报 1.5.0，且序号从上一轮遗留的 `[25]` 回到自动装载的 `[10]`；`readelf -d` 已不再 NEEDED `libgcc_s.so.1`，`.gnu.version_r` 里没有任何 `GCC_*` 需求。
- **`AnneSpawn_NavCandidatesCollectTeamEx` 确认被调用。** `strings` 对比证明只有 1.5.0 导出这个符号、1.4.4 里根本没有这个字符串；插件侧 `[SPAWN ACCEL] extension active (all required natives available)`；而 `spawn_accel_bridge.inc` 里 `SpawnAccel_CollectTeamCandidatesPage()` 在该 native 存在时**无条件**走 `CollectTeamEx`，因此本轮全量矩阵 51009 次 collect 全部经由新 native。
- **名额收紧复现轮（快路径真正生效的场景）全绿：** 40 格 480/480 全部 `normal_nav`，Director Range 0，Director API 一次都没调用，wave 均值 231.6 ms、max 500.0 ms。云4 线上版同组是 400 nav / 80 Director Range，插件侧修复是 480/480；1.5.0 保持在修复后的水平。
- **全量 1083 格：1.5.0 完整保住了插件侧修复相对 08-26 基线的收益**，Nav 成功 12864 → 12906，Director Range 118 → 77，需要 Director 兜底的格 47 → 23，wave 均值 364.595 → 359.808 ms。
- **但相对上一轮（同插件 + 扩展 1.4.4），1.5.0 没有带来可测量的额外收益**，两轮差异落在跑次噪声量级：Nav 12912 → 12906（-6，占比 99.445% → 99.407%），Director 72 → 77，均值 332.378 → 359.808 ms。原因是口径而非缺陷，见下节「为什么全量矩阵测不出快路径的收益」。
- `[FIND EARLY-EXHAUSTED]` 在 1083 格、27.7 万行调试日志里仍然 **0 次**，`ownerCapacity` 全程 0（39852 个采样点），09-02 的 Director 兜底回归路径保持关闭。`[SPAWN TIMEOUT]` 1 次，是 `inf_spawn_nav_band_timeout 3.0` 守卫按设计触发（boomer，band-walk 3.01s > 3.00s），不是挂死。
- 快照重建量下降：`candidateBuildMs` 采样总数 100499 → 95951（-4.5%），满足「应低于或等于上一轮」。
- **两处必须如实记录的过程问题**：第一次全量跑（run1）在第 437 格 `c5m5_bridge@95` 撞上 srcds 看守狗 `Alarm clock` 重启，`SI_Target_limit` / `l4d_target_override` 被静默卸载且矩阵脚本不会恢复它们，后 646 格失去目标上限耦合，该轮作废；加了耦合看守后重跑的 run2 干净完成（看守一次都没触发），本报告的全量数字全部来自 run2。

## 测试对象

服务器：Anne 云服 #8，宿主机 `mccn.online:18189`，容器 `anne4`，内网 RCON `172.16.0.59:18934`。测试开始与结束都是 `0 humans, 0 bots`，地图 `c2m1_highway`。

| 组件 | 测试 SHA-256 | 版本核对 |
|---|---|---|
| `anne_spawn_accel.ext.2.l4d2.so` | `dc5367087cbef44bac851d2e9beda720611a4a26e8425d6cd17890b36197acd9` | `Anne Spawn Accel (1.5.0)`，`compiled Sep 3 2026` |
| `infected_control.smx` | `8a48b1f12c42c775ef8abed4dd48164757451fcf2cfcba2ff6f20c4b9d1e276d` | `Version: 2026-09-04.1 Status: running` |
| `SI_Target_limit.smx` | `05f7ccb46b0d8d4b31063ffd380a81c8224c4e735ab681a5ebc4af7b5e8c5373` | `Version: 1.9 Status: running` |
| `l4d_target_override.smx` | `8066fc32597348c16f1c87595700c7b642ec357bb9f425ca36e035c9e378e37e` | `Version: 2.28 Status: running` |

夹具：`disabled/test/anne_nav_wave_matrix.smx`（`c3adafa0…`）、`optional/AnneHappy/l4d_CreateSurvivorBot.smx`（`156bcb6c…`）。矩阵执行器 `scripts/run_nav_wave_matrix.py`，`--reuse-map`，与 08-26 基线、上一轮同一份脚本、同一组 `TEST_CVARS`，脚本本身未改动。

## 扩展 1.5.0 装载确认

上一轮的失败模式是静默的：直接覆盖同名文件再 `sm exts unload` / `load`，SourceMod 不会把 dlopen 引用计数降到 0，同一路径再 dlopen 直接复用常驻镜像，`sm exts info` 继续报旧版本却回显「装载成功」。本轮因此用两级确认，第二级是**容器重启**——服务器无人，重启是唯一能保证不复用常驻镜像的办法。

### 1) 临时文件名强制新映射

先 `sm plugins unload` 掉依赖扩展的插件（`infected_control`、夹具），再卸掉常驻的 1.4.4，然后把新 .so 以 `anne_spawn_accel_150.ext.2.l4d2.so` 拷进 `addons/sourcemod/extensions/` 装载：

```text
===== sm exts load anne_spawn_accel_150 (raw) =====
[SM] Loaded extension anne_spawn_accel_150.ext.so successfully.
----- after load anne_spawn_accel_150: sm exts list (Anne rows) -----
[SM] Displaying 25 extensions:
[08] Anne NextBot (1.3.0): Native NextBot scheduling and PathFollower snapshots for AnneHappy
[25] Anne Spawn Accel (1.5.0): Directed Nav candidates, spawn traces, geometry, and path cache
----- after load anne_spawn_accel_150: sm exts info 25 -----
 File: anne_spawn_accel_150.ext.2.l4d2.so
 Loaded: Yes (version 1.5.0)
 Name: Anne Spawn Accel (Directed Nav candidates, spawn traces, geometry, and path cache)
 Author: AnneHappy (https://github.com/morzlee/CompetitiveWithAnne)
 Binary info: API version 8 (compiled Sep  3 2026)
 Method: Loaded by SourceMod, attached to Metamod:Source
----- errors_*.log lines mentioning the extension (0) -----
EXT_TEMP_OK
```

对比上一轮同一手法拿到的真实错误（`bin/libgcc_s.so.1: version 'GCC_7.0.0' not found`），本轮 `addons/sourcemod/logs/errors_*.log` 里 0 行相关记录。确认后卸载该镜像、删除临时文件（`sm exts list` 掉回 24 项、无 Anne Spawn Accel 常驻）。

### 2) 覆盖正式路径 + `docker restart anne4`

```text
----- AFTER-RESTART: sm exts list (Anne rows) -----
[SM] Displaying 25 extensions:
[08] Anne NextBot (1.3.0): Native NextBot scheduling and PathFollower snapshots for AnneHappy
[10] Anne Spawn Accel (1.5.0): Directed Nav candidates, spawn traces, geometry, and path cache
----- AFTER-RESTART: sm exts info 10 -----
 File: anne_spawn_accel.ext.2.l4d2.so
 Loaded: Yes (version 1.5.0)
 Name: Anne Spawn Accel (Directed Nav candidates, spawn traces, geometry, and path cache)
 Author: AnneHappy (https://github.com/morzlee/CompetitiveWithAnne)
 Binary info: API version 8 (compiled Sep  3 2026)
 Method: Loaded by SourceMod, attached to Metamod:Source
EXT_INFO_OK version=1.5.0
```

`File` 已经是正式路径、由 `anne_spawn_accel.autoload` 从磁盘装载，序号也从上一轮运行时卸载/重装留下的 `[25]` 漂移回到自动装载位 `[10]`——这两点一起证明是全新映射，不是复用镜像。重启前后 `sm plugins list` 都是 164 项、`sm exts list` 都是 25 项。

容器 `entrypoint.sh` 在启动时跑 `refresh-addons.sh`（只做 `/map`、`/sm_configs` 到 `addons/` 的软链）和 `init-plugins.sh`（插件包复制整段被 `if [ ! -d addons/sourcemod/ ]` 挡住，只剩一次幂等的 `join_autoupdate` sed），都不会碰 `extensions/` 或 `plugins/optional/AnneHappy/`，所以 `docker cp` 进去的文件能安全越过重启。

### 3) ELF 层面的独立复核

在宿主机上对三份 .so 做 `readelf -d` / `readelf -V`：

| 构建 | NEEDED `libgcc_s.so.1` | 对 `libgcc_s.so.1` 的版本需求 | 最高 GLIBC 需求 |
|---|---|---|---|
| 1.4.4（`3c9825e6…`，一直可装载） | 是 | `GLIBC_2.0` | `GLIBC_2.4` |
| 1.5.0 旧构建（`025090ca…`，装不上） | 是 | **`GCC_7.0.0`**、`GLIBC_2.0` | `GLIBC_2.33` |
| 1.5.0 重建（`dc536708…`，本轮） | **否** | — | `GLIBC_2.34` |

重建版连 `libpthread.so.0` 都不再单独 NEEDED（glibc 2.34 起并入 libc）。srcds 自带的私有库只有 `bin/libgcc_s.so.1` 和 `bin/libstdc++.so.6`，没有私有 libc，容器是 Debian 13 / glibc 2.41，因此 `GLIBC_2.34` 能满足，唯一卡点（老 libgcc 缺 `GCC_7.0.0`）已经被 `-static-libgcc` 消除。

### 4) 新 native 确实存在且被走到

```text
$ strings -a anne_spawn_accel.ext.2.l4d2.so | grep -o 'AnneSpawn_NavCandidatesCollectTeam[A-Za-z]*' | sort -u
1.5.0 (dc536708):  AnneSpawn_NavCandidatesCollectTeam
                   AnneSpawn_NavCandidatesCollectTeamEx
1.4.4 (3c9825e6):  AnneSpawn_NavCandidatesCollectTeam
```

1.4.4 里根本没有 `AnneSpawn_NavCandidatesCollectTeamEx` 这个字符串，所以在旧扩展上 `GetFeatureStatus` 必然不可用、`g_bSpawnAccelTeamExcludeAvailable` 恒为 false。1.5.0 常驻后插件在 `inf_DebugMode 1` 下打出：

```text
L 09/04/2026 - 04:26:46: [.../infected_control.smx] [SPAWN ACCEL] extension active (all required natives available)
L 09/04/2026 - 04:26:46: [.../infected_control.smx] [SPAWN ACCEL] native safety traces disabled (SourcePawn fallback)
```

配合 `spawn_accel_bridge.inc` 的分支：

```592:601:addons/sourcemod/scripting/optional/AnneHappy/infected_control/spawn_accel_bridge.inc
    if (g_bSpawnAccelTeamExcludeAvailable)
    {
        return AnneSpawn_NavCandidatesCollectTeamEx(
            clients, navIds, count,
            minNavDistance, maxNavDistance, pathLimit, minTeamDistance,
            NAV_CANDIDATE_RESULT_TTL, maxInclusive, startOffset,
            page, distances, owners, maxResults,
            resultAgeMs, totalInRange,
            excluded, excludedCount);
    }
```

结论是本轮所有有向团队分页读取都经由新 native：`[SpawnPerf][GraphCandidates] collect(hit/pending/unavailable)` 全量累计 **51009 / 0 / 0**（上一轮同一指标 49345 / 0 / 0，量级一致）。

## 订正：`ownerCapacity > 0` 这个预期不成立

任务书预期名额收紧轮的 `ownerCapacity` 之和 **> 0**，用来证明「排除真的发生」。按 1.5.0 的实际实现，这个预期在任何情况下都不会满足，`ownerCapacity = 0` 才是快路径正常工作的表现。

插件侧只在候选的 owner 被本游标显式排除时才计数：

```1406:1411:addons/sourcemod/scripting/optional/AnneHappy/infected_control/spawn_core.inc
            if (SpawnSearch_IsOwnerExcluded(cursor, ownerClient))
            {
                cursor.stats.ownerCapacity++;
                SpawnPerf_RecordFilterByOwnerCapacity();
                continue;
            }
```

但扩展的 `CollectTeamEx` 会把被排除的生还者从「最近目标」计算里摘掉，**逐行重算 owner**，只有被排除者可达的行直接跳过：

```3064:3074:extensions/anne_spawn_accel/extension.cpp
    for (std::uint32_t source : result->flowOrder)
    {
        float distance = result->pathDistances[source];
        int owner = result->ownerClients[source];
        if (useLayers &&
            !AnneResolveTeamCandidateForActiveTargets(
                result->perTargetDistances, result->targetClients, activeTargets,
                source, distance, owner))
        {
            continue;
        }
```

也就是说：owner 为被排除者的候选**根本不会带着那个 owner 返回给插件**，`SpawnSearch_IsOwnerExcluded` 因此永远为假。这正是 1.5.0 的设计目的——排除在 native 内部完成，既不重建快照、也不在插件热循环里把候选整批丢掉。旧扩展上 `ownerCapacity = 0` 是因为压根不做排除；新扩展上 `ownerCapacity = 0` 是因为排除已经在更早的一层吸收掉了。两者数值相同、含义相反，不能用这个计数器区分快路径。

可用的区分证据只有前一节那四条（`sm exts info` 版本与编译日期、`strings` 符号差异、插件的 native 可用性日志、代码里无条件走 TeamEx 的分支）。

## 为什么全量矩阵测不出快路径的收益

`SpawnAccel_CollectTeamExclusions()` 只把「已达目标上限」的成员放进排除列表，并且**全员都满时返回 0**（退回无排除）：

```469:484:addons/sourcemod/scripting/optional/AnneHappy/infected_control/spawn_accel_bridge.inc
int SpawnAccel_CollectTeamExclusions(const int[] clients, int count,
                                     int[] excluded, int maxExcluded)
{
    if (!g_bSpawnAccelTeamExcludeAvailable || count <= 0 || maxExcluded <= 0)
        return 0;

    int n = 0;
    for (int i = 0; i < count && n < maxExcluded; i++)
    {
        if (SpawnTarget_IsAtCapacity(clients[i]))
            excluded[n++] = clients[i];
    }
    if (n >= count)
        return 0;
    return n;
}
```

全量矩阵的口径是 4 名冻结生还者 + 12 SI + `SI_target_limit_auto 1`。`sm_targetlimit_status` 在这个口径下回显 `budget=4 base=5 pushed=5`，即每人容量 5；12 只 SI 平摊到 4 个目标是每人 3 只，**没有人会到达上限**，排除列表恒为空。扩展侧 `activeCount == snapshotTargets` → `useLayers` 为 false → `CollectTeamEx` 逐行走的是与 `CollectTeam` 完全相同的代码。

所以全量矩阵在这个口径下**结构上不可能显示快路径的差异**，它的作用是回归检查（确认 1.5.0 没有把已有收益吃掉）。真正验收快路径的是名额收紧轮：`SI_target_limit_manual 2` 时 `base=2 pushed=2`，12 只 SI / 4 个目标必然把人打满，排除列表非空、`useLayers` 生效。

## 小样本与名额收紧轮

两轮都在 `inf_DebugMode 1` 下跑（`TEST_CVARS` 自带），逐格调试日志按 offset 切片后统计。

| 指标 | 小样本（2 图 × 3 点） | 名额收紧（4 图 × 10 点） |
|---|---:|---:|
| 命令行 | `--maps c2m1_highway,c5m1_waterfront --progress 25,50,75` | `--maps c1m1_hotel,c2m4_barns,c5m1_waterfront,c8m1_apartment --progress 5,15,…,95` |
| 名额口径 | `SI_target_limit_auto 1`（`base=5 pushed=5`） | `SI_target_limit_auto 0` + `manual 2`（`base=2 pushed=2`） |
| 格数 / 进入波次 | 6 / 6 | 40 / 40 |
| 实际生成 | 72 / 72 | **480 / 480** |
| `mode=normal_nav` | **72（100%）** | **480（100%）** |
| `mode=normal_director_range` | **0** | **0** |
| Director API calls / hits | 0 / 0 | **0 / 0** |
| `ownerCapacity` 之和（采样数） | 0（185） | 0（1175） |
| `[FIND EARLY-EXHAUSTED]` | 0 | 0 |
| `[SPAWN TIMEOUT]` | 0 | 0 |
| `collect(hit/pending/unavailable)` | 298 / 0 / 0 | 1619 / 0 / 0 |
| `candidateBuildMs` 日志行 | 45 | 225 |
| wave 均值 / P95 / max | 295.5 / 585.9 / 585.9 ms | **231.6 / 343.7 / 500.0 ms** |

名额收紧轮与云4 参照对比（云4 数据取自 `/tmp/anne_ab_test/results/cloud4_20260904/summary3.txt`，同为 40 格 / 480 只）：

| 组合 | Nav 成功 | Director Range | Director API calls / hits |
|---|---:|---:|---:|
| 线上版 + 旧扩展（云4 `v1cap`） | 400 | **80** | 110 / 80 |
| 插件侧修复 + 扩展 1.4.4（云4 `basecap`） | 480 | 0 | 0 / 0 |
| 插件侧修复 + 扩展 1.5.0（本轮） | **480** | **0** | **0 / 0** |

`ownerCapacity` 之和为 0 的原因见上一节（排除被 native 吸收），不代表排除没发生：这一轮每人容量 2、12 只 SI 打满 4 个目标，排除列表必然非空，而结果是 480/480 全部走 Nav、Director 一次都没被调用。

## 全量矩阵三方对比

三轮都是 57 张官方图 × 5%–95%（每 5% 一格）共 1083 格，同一份执行器与 `TEST_CVARS`。三组数字全部由同一个分析脚本（`test_results/.../logs/analyze.py`）从各轮 `results.jsonl` 重算，并已用 `--check` 校验能逐字段复现上一轮 `analysis.json` 的 `baseline` 与 `current` 两块，口径完全一致。

| 指标 | 08-26 基线（云3，1.4.4） | 09-04 修复（云8，1.4.4） | 09-04 修复（云8，**1.5.0**） |
|---|---:|---:|---:|
| 总格数 | 1083 | 1083 | 1083 |
| 进入波次 | 1082 | 1082 | 1082 |
| 实际 12/12 | 1081 | 1082 | 1081 |
| 实际未满格 | 1 | 0 | 1 |
| 严格 `complete_12` | 1068 | 1072 | 1067 |
| 实际生成 / 目标 | 12982 / 12984 | 12984 / 12984 | 12983 / 12984 |
| 缺失 | 2 | 0 | 1 |
| Nav 成功 | 12864（99.091%） | 12912（99.445%） | **12906（99.407%）** |
| Director Range | 118（0.909%） | 72（0.555%） | **77（0.593%）** |
| Director Unrestricted | 0 | 0 | 0 |
| 需要 Director 兜底的格 | 47 | 22 | **23** |
| Director API calls | 1397 | 1285 | 1679 |
| Director API hits | 118 | 72 | 77 |
| Director API misses | 142 | 237 | 346 |
| Director API safety_reject | 986 | 808 | 1037 |
| Director API cap_reject | 151 | 168 | 219 |
| 实际刷点驳回 | 0 | 0 | 0 |
| `ownerCapacity` | 0 | 0 | 0 |
| `ownerInvalid` | 0 | 0 | 0 |
| `behindBudget` | 20489 | 8583 | 10308 |
| `[FIND EARLY-EXHAUSTED]` | 该日志尚不存在 | 0 | **0** |
| `[SPAWN TIMEOUT]` | 0 | 0 | **1** |
| `normal_nav` 可见性违例 | 8 | 4 | 6 |
| `directed range exhausted`（日志行） | 未统计 | 307 | 448 |
| teleport 成功 | 0 | 0 | 0 |
| `collect(hit/pending/unavailable)` | 未统计 | 49345 / 0 / 0 | 51009 / 0 / 0 |
| `candidateBuildMs` 采样总数 | 未统计 | 100499 | **95951** |
| wave N | 1082 | 1082 | 1082 |
| wave mean | 364.595 ms | 332.378 ms | **359.808 ms** |
| wave P50 | 281.2 ms | 257.8 ms | 265.6 ms |
| wave P95 | 679.6 ms | 609.3 ms | 679.6 ms |
| wave P99 | 1601.5 ms | 1726.5 ms | 1726.5 ms |
| wave max | 6734.3 ms | 6335.9 ms | 8078.1 ms |
| > 1 s | 23 | 17 | 23 |
| > 3 s | 4 | 3 | 4 |
| > 8 s | 0 | 0 | 1 |

怎么读这张表：

- **相对 08-26 基线，1.5.0 保住了插件侧修复的全部核心收益**：Nav 多 42 只，Director Range 少 41 只，需要兜底的格从 47 降到 23（少一半），均值略快 4.8 ms，`> 1s` / `> 3s` 持平。
- **相对上一轮 1.4.4，1.5.0 基本是平手**：Nav 差 6 只（12906 vs 12912，占比差 0.038 个百分点），Director Range 差 5 只，实际生成差 1 只。这个量级与「同一插件在不同跑次之间的抖动」同阶，不构成回归结论，也不构成改进结论。
- 均值 332 → 360 ms 与 `> 1s` 17 → 23 的退步几乎全部来自 c6m2_bedlam 那一簇长尾格的重新分布（见异常格一节），不是全局趋势：中段 15%–85%（855 格，占 79%）的 Director 次数反而是三轮最低的 35（08-26 是 71、上一轮 38），90%–95% 段也是三轮最低的 15。
- `directed range exhausted` 307 → 448 与 Director API calls 1285 → 1679 要一起看：有向范围耗尽后走的仍然是正常逐层扩带，`[SPAWN TIMEOUT]` 只有 1 次、`band timeout` 0 次，说明 band 推进没有退化成「10 帧内走完全部分层」。
- `candidateBuildMs` 采样总数 100499 → 95951（-4.5%），快照重建次数低于上一轮，符合验收要求。

### 进度分段

| 分段 | entered | mean（08-26 → 1.4.4 → 1.5.0） | P95 | 平均 Nav / 波 | Director 次数 | 实际未满 |
|---|---:|---|---|---|---|---:|
| 5%–10% | 113 | 362.997 → 358.852 → 394.869 ms | 609.3 → 593.7 → 609.3 | 11.841 → 11.867 → 11.761 | 18 → 15 → 27 | 0 |
| 15%–85% | 855 | 369.355 → 329.168 → 359.341 ms | 703.1 → 632.8 → 679.6 | 11.915 → 11.956 → **11.958** | 71 → 38 → **35** | 1 |
| 90%–95% | 114 | 330.480 → 330.206 → 328.555 ms | 593.7 → 500.0 → 539.0 | 11.746 → 11.833 → **11.868** | 29 → 19 → **15** | 0 |

首段（113 格）是本轮唯一明确退步的分段：Director 次数 15 → 27，均值 +36 ms。这一段的 Director 回退集中在 `c5m5_bridge@5`（12 次）与 `c12m5_cornfield@10`（8 次）、`c13m3_memorialbridge@5`（5 次）三格，合计 25 次，占该段 27 次里的绝大部分——是少数几张开阔起始段的抖动，不是分段整体的系统性变化。

### Director 回退的地图分布

| 地图 | Director 次数 | 涉及格数 |
|---|---:|---:|
| `c5m5_bridge` | 25 | 3 |
| `c12m5_cornfield` | 12 | 3 |
| `c1m3_mall` | 7 | 1 |
| `c12m3_bridge` | 6 | 1 |
| `c13m1_alpinecreek` | 5 | 2 |
| `c13m3_memorialbridge` | 5 | 1 |
| `c13m4_cutthroatcreek` | 4 | 2 |
| 其余 9 张图 | 各 1–2 | 各 1–2 |

57 张图里 16 张、23 格出现过 Director 回退（08-26 是 21 张图 / 47 格，上一轮是 13 张图 / 22 格）。

## 关键异常格

### 唯一未进入波次

`c5m5_bridge@10`（index 420），夹具报 `survivor flow positioning failed`（`actualPct=7.17 directed(near/long/broad)` 三名生还者读到 `-1/-1/-1`）。**三轮完全一致**，与刷特插件无关。

### 唯一实际未满格：`c6m2_bedlam@85`（index 473）

| 轮次 | 生成 / 探针 | Nav / Director | server wave | Director API | 主要过滤 |
|---|---:|---:|---:|---|---|
| 08-26 基线 | 12 / 12 | 8 / 4 | 585.9 ms | 15 calls，4 hit，11 safety | visibility 1644 |
| 上一轮（1.4.4） | 12 / 12 | 12 / 0 | 6335.9 ms | 303 calls，5 miss，298 safety | visibility 15399 |
| 本轮（1.5.0） | **11 / 10** | 10 / 1 | **8078.1 ms** | 439 calls，1 hit，44 miss，394 safety | visibility 21108、stuck 481 |

`behindBudget=0`，没有 Pending、没有反复 Exhausted、没有 band timeout。这一格在三轮里分别是 586 / 6336 / 8078 ms，波动一个数量级，是 c6m2 多层紧凑地形上 Nav 可见性过滤持续失败 + Director 候选被安全检查拒绝的既有长尾，不是本轮新引入的问题。

### 超过 3 秒的四格

| index | 地图进度 | 生成 | Nav / Director | server wave | 上一轮同格 | 08-26 同格 |
|---:|---|---:|---:|---:|---:|---:|
| 473 | `c6m2_bedlam@85` | 11/12 | 10 / 1 | 8078.1 ms | 6335.9 ms | 585.9 ms |
| 471 | `c6m2_bedlam@75` | 12/12 | 12 / 0 | 7828.1 ms | 2843.7 ms | 6648.4 ms |
| 419 | `c5m5_bridge@5` | 12/12 | **0 / 12** | 4859.3 ms | 4343.7 ms | 2640.6 ms |
| 241 | `c3m4_plantation@65` | 12/12 | 11 / 1 | 3343.7 ms | 710.9 ms | 312.5 ms |

c6m2_bedlam 的 `@75/@80/@85` 三格在三轮之间反复换位（本轮 7828 / 1820 / 8078，上一轮 2844 / 3219 / 6336，08-26 是 6648 / 6734 / 586），三格合计 08-26 13968 ms、上一轮 12399 ms、本轮 17726 ms。本轮这一簇确实是三轮里最差的，也是均值与 `> 1s` 退步的主要来源。

`c5m5_bridge@5` 本轮 12 只全部由 Director 刷出（Nav 0），上一轮是 6 + 6、08-26 是 5 + 7；280 次 Director API 里 220 次 miss。这一格在三轮里都慢（2641 / 4344 / 4859 ms），是有向范围耗尽后扩大搜索再进 Director 的典型格。

### `[SPAWN TIMEOUT]`（1 次）

```text
L 09/04/2026 - 06:15:13: [.../infected_control.smx] [SPAWN TIMEOUT] class=boomer mode=normal band-walk 3.01s > 3.00s at band=7; jump to Director fallback stage
```

`inf_spawn_nav_band_timeout` 设为 3.0，band-walk 用了 3.01 秒后按设计跳到 Director 兜底档。守卫按预期生效，不是挂死；同轮 `band timeout` 计数 0、`[FIND EARLY-EXHAUSTED]` 0。

### `normal_nav` 可见性违例（6 格，各 1 次）

`c1m3_mall@65`、`c4m3_sugarmill_b@20`、`c4m3_sugarmill_b@50`、`c4m3_sugarmill_b@60`、`c7m2_barge@30`、`c13m2_southpinestream@40`。上一轮 4 次、08-26 8 次。`c4m3_sugarmill_b@60` 是上一轮也命中的同一格。

## 过程问题：run1 因 srcds 看守狗重启作废

第一次全量跑（宿主机 16:36:37 → 17:51:40，1083 格）不能用作结论，原因如下。

在第 437 格 `c5m5_bridge@95`，`sm_navmatrix_prepare 95` 的 RCON 调用拿到 `Connection refused`。容器日志里对应的是 srcds 进程本身被看守狗杀掉后由 `run.sh` 重启：

```text
Alarm clock
Add "-debug" to the ./srcds_run command line to generate a debug.log to help with solving this problem
Fri Sep  4 05:06:46 CST 2026: Server restart in 10 seconds
```

`docker inspect` 显示容器 `RestartCount=0`、`OOMKilled=false`，所以是容器内的 srcds 进程重启，不是容器重启。挂住的位置是夹具的 prepare 路径（最后几行调试日志是 `anne_nav_wave_matrix.smx` 在给 `c5m5_bridge@95` 定位生还者，三名生还者的 `directed(near/long/broad)` 读到 `-1/-1/-1`，前一格刚报过 `SpreadFail`），而同一时刻 `infected_control` 侧的性能计数完全健康（`candidateBuildMs max=1.708 ms`、`maxSliceMs max=2.197 ms`、`GraphCandidates buildMs max=2.645 ms`），没有任何证据指向扩展。重跑时同一格 12/12 全 Nav、632.8 ms 正常完成，**该挂死不可复现**。

真正致命的是重启的副作用：`run_nav_wave_matrix.py` 的 `configure_map()` 明确处理「受监督的 SRCDS 重启」，但它只恢复 `PLUGIN_PATHS` 里那三个插件（`l4d_CreateSurvivorBot`、`anne_nav_wave_matrix`、`infected_control`），**不含 `SI_Target_limit` 与 `l4d_target_override`**。这两个插件在重启后被静默卸载、整轮再没被装回来，`g_bTargetLimitLib` 变成 false、`SpawnTarget_GetHeadroom()` 恒返回 UNLIMITED，也就是后 646 格完全没有目标上限账本——而这恰好是容量排除快路径依赖的耦合。跑完时实测 `SI_target_limit_auto`、`l4d_target_override_type` 等 cvar 全部不存在，`sm_targetlimit_status` 回显 `Unknown command`。

按 437 格切窗对比 run1 与上一轮的同一批格，可以确认这次耦合丢失并没有污染 Nav/Director 结论（两个窗口的表现几乎一样），但 60% 的格跑在非预期口径上，这一轮不适合作为验收数据：

| 指标 | 1–436 格（耦合完好） | 438–1083 格（耦合丢失） |
|---|---|---|
| Nav 占比（run1 / 上一轮） | 99.234% / 99.502% | 99.252% / 99.407% |
| wave 均值（run1 / 上一轮） | 360.265 / 331.208 ms | 361.170 / 332.846 ms |
| `ownerCapacity`（run1） | 0 | 0 |

因此加了一个独立的耦合看守进程（每 15 秒检查这两个插件是否在跑，缺失就补装并重写 7 个耦合 cvar；**不改矩阵脚本本身**，保持与历史轮次同源）后重跑。run2（17:58:52 → 19:13:31，74 分 39 秒）期间 srcds 重启 0 次、`Alarm clock` 0 次，看守一次都没触发，1083 格全程耦合完好。本报告的全量数字全部来自 run2；run1 的原始数据保留在 `test_results/20260904_every5_team_exclude_ext150/run1_srcds_restart/` 备查。

需要单独记一笔的既有缺陷：`run_nav_wave_matrix.py` 的重启恢复清单漏了 `SI_Target_limit` 和 `l4d_target_override`，而 srcds 被看守狗重启在长矩阵里是会发生的。这个洞会让整轮静默跑在「没有目标上限」的口径上而不报错，历史轮次里只要发生过重启就同样受影响。本次按要求没有改动仓库脚本。

## 测试隔离参数

与 08-26 基线、上一轮完全一致：

- 生产联动 cvar 按 `cfg/cfgogl/annehappy/shared_settings.cfg`：`l4d_target_override_type 1`、`l4d_target_override_specials 127`、`l4d_target_override_forward 1`、`SI_enable_option 53`、`SI_target_limit_auto 1`、`SI_target_rushman_scope 1`、`inf_nav_team_nearest 1`。`sm_targetlimit_status` 回显 `enable=1 active=1 budget=4 mobile=0 base=5 pushed=5 scope=1`。
- 4 名冻结生还者（`sb_stop 1`、`nb_stop 0`）、12 SI（六职业各 2）、8 秒观察窗、`l4d_infected_limit 12`、`versus_special_respawn_interval 16.0`。
- `inf_score_behind_soft_pct=90`、`inf_spawn_behind_eval_budget=32`、`inf_spawn_nav_band_timeout=3.0`、`inf_spawn_sep_radius=100.0`、`inf_spawn_kernel_radius=280.0`、`inf_spawn_kernel_points=50.0`。
- teleport 关闭（`inf_TeleportSi 0`）、内鬼关闭、Anti-Bait 关闭、`z_common_limit 0`、`director_no_bosses 1`，Director Range 兜底保留。
- 测试期间用 `sv_password` 做隔离，结束清空。

沿用上一轮已记录的口径偏差：`configure_map()` 用不带引号的 `sm_cvar <name> <value>` 写 `TEST_CVARS`，两个向量 cvar 只有第一个分量生效（`inf_nav_high_sort_scale` 实际是 `0.85/1.00/1.00/1.00/1.00/1.00`，`inf_score_w_disp` 只落到 `2.20`）。三轮跑在同一个被截断的口径上，对比不受影响。本次未改动仓库脚本。

## 结果文件

- `test_results/20260904_every5_team_exclude_ext150/results.jsonl`（run2，1083 行）
- `test_results/20260904_every5_team_exclude_ext150/results.csv`（1090 行，含表头，长字段内含换行）
- `test_results/20260904_every5_team_exclude_ext150/raw_logs.tar.gz`（1082 份逐格调试日志切片）
- `test_results/20260904_every5_team_exclude_ext150/analysis.json`（run2 汇总 / 分段 / 异常格 / Director 分布）
- `test_results/20260904_every5_team_exclude_ext150/smoke/results.jsonl`、`quota/results.jsonl`
- `test_results/20260904_every5_team_exclude_ext150/logs/`：三次 `sm exts info` 原始回显（`ext_temp_load.txt`、`ext_after_restart.txt`、`post_ext_info.txt`）、各阶段执行日志、`marker_counts.txt`、`full_run.log.gz`（66.7 MB / 276670 行，gzip 后 7.0 MB）、`prestate.json` / `poststate.json`、分析脚本（`analyze.py`、`threeway.py`、`split.py`）
- `test_results/20260904_every5_team_exclude_ext150/run1_srcds_restart/`：作废的 run1 原始数据与执行日志

宿主机上的备份与脚本保留于 `/root/anne-ext150-20260904/`（含 `backup/` 原始文件、`out_final/` run2 结果、`run1_out/` run1 结果、`logs/`）。

矩阵起止（宿主机本地时间，UTC-4）：run1 `16:36:37 → 17:51:40`；run2 `17:58:52 → 19:13:31`（74 分 39 秒，1083 格）。

## 云8恢复核对

六个文件已按测试前哈希回写并逐项核对（`RESTORE_SHA_OK`、`RESTORE_PERMS_OK`）：

```text
d03d40df5f69cbd333b68f1c06654898fd5c85e636e7d01788c1d605f94bafaa  plugins/optional/AnneHappy/infected_control.smx
05f7ccb46b0d8d4b31063ffd380a81c8224c4e735ab681a5ebc4af7b5e8c5373  plugins/optional/AnneHappy/SI_Target_limit.smx
8066fc32597348c16f1c87595700c7b642ec357bb9f425ca36e035c9e378e37e  plugins/optional/AnneHappy/l4d_target_override.smx
156bcb6c6a504c1939ccdebb8c9f4d6647de57652a062e9fe3cc7876c97cbb8a  plugins/optional/AnneHappy/l4d_CreateSurvivorBot.smx
c3adafa082fd7d22d65a4661b724f9a87bc18c33f937bc93e1ca1e6ba2df1c01  plugins/disabled/test/anne_nav_wave_matrix.smx
3c9825e64babeb7cf93eedcc4cda3ab1bb5436814540868084a55848bb6d8253  extensions/anne_spawn_accel.ext.2.l4d2.so
```

属主与权限同样按测试前快照复位（`docker cp` 会把文件变成 `root:root`，已用 `docker exec -u 0 chown` 修回）：

```text
plugins/optional/AnneHappy/infected_control.smx        root:root   644
plugins/optional/AnneHappy/SI_Target_limit.smx         root:root   644
plugins/optional/AnneHappy/l4d_target_override.smx     root:root   644
plugins/optional/AnneHappy/l4d_CreateSurvivorBot.smx   louis:louis 644
plugins/disabled/test/anne_nav_wave_matrix.smx         louis:louis 644
extensions/anne_spawn_accel.ext.2.l4d2.so              louis:louis 755
```

其余恢复项：

- 旧扩展覆盖回正式路径后 `docker restart anne4`，`sm exts info` 核对回 `Anne Spawn Accel (1.4.4)`、`compiled Aug 25 2026`、`File: anne_spawn_accel.ext.2.l4d2.so`。
- 临时文件 `anne_spawn_accel_150.ext.2.l4d2.so` 已删除，`extensions/` 目录只剩 `anne_spawn_accel.autoload` / `.dll` / `.so` 三项。
- `sm plugins list` 164 项、`sm exts list` 25 项，与测试前数量一致；五个测试插件与夹具全部未加载（与测试前一致），`sm plugins load_lock` 已生效。
- 引擎 cvar 19 项逐项核对，0 项不符：`sv_password=""`、`sb_stop=0`、`nb_stop=0`、`sv_cheats=0`、`director_no_specials=0`、`director_no_bosses=0`、`z_common_limit=30`、`z_{smoker,boomer,hunter,spitter,jockey,charger}_limit=1`、**`z_max_player_zombies=4`**、`versus_special_respawn_interval=20`、`sb_all_bot_game=0`、`sv_hibernate_when_empty=0`。其中 `sb_all_bot_game` 与 `sv_hibernate_when_empty` 在重启后的开服值是 1，已单独写回测试前的 0 并复读确认。
- 插件侧 51 个 `inf_*` / `SI_*` / `l4d_infected_limit` / `l4d_target_override_*` cvar 在插件卸载前先逐个写回源码 `CreateConVar` 默认值并复读核对（0 个不符）。
- 地图回到 `c2m1_highway`，`status` 为 `0 humans, 0 bots`。

两处与测试前状态不同、但属于「更干净」的良性差异：

1. **51 个插件 cvar 从「存在且为源码默认值」变成「不存在」。** 测试前这些 cvar 在引擎里是存在的——SourceMod 会把已卸载插件创建过的 ConVar 保留到 srcds 进程结束，它们是上一轮测试在同一个 srcds 进程里装载/卸载插件留下的残留（实测测试前 51 项全部等于源码默认值，0 项偏离）。本轮要求的 `docker restart` 换掉了 srcds 进程，这些残留自然消失，等同于一次正常开服后的状态。没有任何实质配置丢失。
2. **`sm exts list` 里 Anne Spawn Accel 的序号从 `[25]` 回到 `[10]`。** `[25]` 是上一轮运行时卸载/重装造成的序号漂移，`[10]` 才是按目录自动装载的原位。这一项实际上是把上一轮遗留的漂移修正了。

除以上两条外没有未恢复项。

## 后续建议

1. **`AnneSpawn_NavCandidatesCollectTeamEx` 的装载性已验收，快路径的性能收益尚未验收。** 全量矩阵的口径（4 名生还者 / 12 SI / `SI_target_limit_auto 1` → 每人容量 5）结构上不会产生「部分成员已满」的状态，排除列表恒为空，`CollectTeamEx` 与 `CollectTeam` 走同一段代码。要量化快路径就得在收紧名额的口径下跑全量（例如 `SI_target_limit_auto 0` + `manual 2`），而不是在默认口径下跑。
2. 订正验收指标：不要再用 `ownerCapacity > 0` 判断排除是否发生。新扩展下排除在 native 内部完成，`ownerCapacity` 恒为 0 才是正常。可用的信号是 `sm exts info` 版本 + `strings` 符号 + `[SPAWN ACCEL] extension active`，若要运行时计数，建议在 `SpawnAccel_CollectTeamExclusions()` 返回值上加一条节流日志（例如 `[SPAWN ACCEL] team exclusions n=… of …`），这样排除规模才可观测。
3. 给 `run_nav_wave_matrix.py` 的 SRCDS 重启恢复清单补上 `SI_Target_limit` 与 `l4d_target_override`。现在只要长矩阵中途撞上一次看守狗重启，后续所有格都会静默跑在「没有目标上限账本」的口径上且不报错。
4. c6m2_bedlam 的 `@75/@80/@85` 与 `c5m5_bridge@5` 这四格已经连续三轮占据长尾，且在轮次之间波动一个数量级，建议单独做多次重复采样定位（同一格连跑 N 次），否则每轮的 mean / P95 / `> 1s` 都会被这几格的随机换位主导，掩盖真实趋势。
5. `c5m5_bridge@10` 的夹具定位失败连续三轮完全一致，属于夹具在该图的既有缺陷，建议单独修夹具而不是每轮记为异常。
6. 沿用上一轮未处理的两条：订正 Update_log「2026年9月4日」条目里「验证（云4…）」的措辞（那一轮跑的是老扩展 1.4.4）；`configure_map()` 写向量 cvar 缺引号的问题。
