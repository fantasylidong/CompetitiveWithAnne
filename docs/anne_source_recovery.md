# Anne 历史源码恢复

已直接恢复每个 Anne 发布系列最后一个刷特源码，不包含中间版本。源码位于
`addons/sourcemod/scripting/archive/AnneHappy/legacy_versions`：

| 最后版本 | Git 源码快照 | 备注 |
| --- | --- | --- |
| `Anne11-28` | `CompetitiveWithAnne-stable-release-2022-12-01` | 2021 系列在 rebase 时整体导入；这是 Git 中最早可恢复的对应快照。 |
| `Anne22-12` | `CompetitiveWithAnne-stable-release-2022-12-29` | `716711974` 加入该版本二进制。 |
| `Anne23-1` | `CompetitiveWithAnne-stable-release-2023-01-14` | 使用 2023 年 1 月发布快照。 |
| `Anne24-5` | `CompetitiveWithAnne-stable-release-2024-05-04` | 24-5 beta 快照。 |
| `Anne25-11` | `fb2a834ec` | 25-11 二进制在该提交中加入。 |

源码会落在 `legacy_versions/<版本>/infected_control.sp`；模块化的 `Anne25-11` 还恢复了同一提交下的 `infected_control/*.inc`。历史 `.smx` 不保证能用今天的 SourceMod 编译器逐字节重建；编译器版本、include 和 gamedata 都会影响二进制。

## 22-11 句柄异常

虽然 `Anne22-11` 是中间版本、没有导出，但日志对应的历史源码可以由
`CompetitiveWithAnne-stable-release-2022-12-01` 查看：

- `InitStatus()` 第 339 行检查 `g_hTeleHandle != INVALID_HANDLE`，第 342 行执行 `delete g_hTeleHandle`。
- `SpawnFirstInfected()` 创建 `CreateTimer(1.0, Timer_PositionSi, _, TIMER_REPEAT)` 并保存到该全局变量。
- `Timer_PositionSi()` 在 `CheckRushManAndAllPinned()` 返回真时返回 `Plugin_Stop`。重复定时器自关闭后，全局变量没有同步清成 `INVALID_HANDLE`。
- 下一次 `round_start` 再次进入 `InitStatus()`，旧句柄通过检查并被二次 `delete`，所以 `CloseHandle` 报 `Handle ... is invalid (error 1)`。

后续提交 `b931361d1`（2022-12-08）把该分支改成 `Plugin_Continue`，避免定时器自关闭；继续使用旧 22-11 二进制会保留这个问题，应切换到恢复出的 22-12、25-11 或当前 `infected_control.smx`。
