# Confogl 计分 / 刷特计时 / PVE 兼容 / 插件冲突审计（2026-11-18）

## 1. 计分

| 项 | 结论 |
| --- | --- |
| 实际计分模块 | 所有 matchmode 均为 `confogl_SM_enable 0`，Confogl ScoreMod 未参与计分；实际走 `l4d2_hybrid_scoremod_zone` 等插件。 |
| ScoreMod 回合判断 | 原实现靠 `round_end`/`round_start` 事件计数判断第二回合；战役/PVE 团灭重开会被当作第二回合。已改为 `m_bInSecondHalfOfRound` + 每半场去重（本 PR）。 |
| ScoreMod 除零 | `SM_CalculateAvgHealth()` 在无生还者时 `/ iSurvCount` 除零。已修复（本 PR）。 |
| 重复公式 | 同一公式在 4 处复制，已抽为 `SM_BonusPerSurvivor()` / `SM_CalculateRoundBonus()`。 |
| hybrid_scoremod | 已使用 `InSecondHalfOfRound()` 索引数组，无同类问题。 |

## 2. 特感刷新计时

- `confoglcompmod` 本身不控制 SI 刷新计时；只有 `BossSpawning`（Tank/Witch 位置复刻）、`GhostTank`（Tank 冻结）、`FinaleSpawn`（救援阶段灵魂态距离）。
- Anne 模式的刷特完全由 `optional/AnneHappy/infected_control` 管理（wave / kill phase / `versus_special_respawn_interval 16` / Anti-Bait / traitor）。`AGENTS.md` 对其时序有严格契约，本次**未改动**。
- 已知问题沿用 `docs/infected_control_spawn_timing_audit_2026-06-03.md` 与 `docs/infected_control_refactor_bug_audit_2026-06-04.md`，建议在单独 PR 中逐项处理并保留 timing logs。
- `cfg/cfgogl/annehappy/annehappy.cfg:63` 注释掉的 `confogl_addcvar versus_special_respawn_interval 16` 与 `confogl_plugins.cfg:83` 的 `sm_cvar` 重复，建议删除注释行，保留一个来源。

## 3. Versus 专属功能在 Coop/PVE

结论：Anne 的 PVE 本身就跑在 `versus` 模式（`versus_coop_mode.smx` detour `CDirectorVersusMode::RestartVsMode` 并 patch 回合结束标志），Director 已由该插件 hook，**不需要再新增 Director hook**。真正的问题是各插件用不同方式判断模式：

| 方式 | 问题 | 建议 |
| --- | --- | --- |
| `StrContains(mp_gamemode, "versus")` / `StrEqual(..., "versus")` | 漏判 mutation12、community 对抗等；不能区分「对抗基础模式」与「有真人感染者」 | 改用 `L4D_GetGameModeType()` |
| `GetClientTeam(client) == L4D2Team_Infected` | 本身正确（AI 特感也在感染者队）；问题在于把它当成「有真人感染者」 | 需要真人时额外判断 `!IsFakeClient` 或 `L4D_HasPlayerControlledZombies()` |
| `L4D_HasPlayerControlledZombies()` / `L4D_IsVersusMode()` | 正确，已有 14 个文件使用 | 作为统一标准 |

仍使用字符串判断的现役源码（`archive/`、`disabled/` 除外）：

- `l4d2_coop_versus_compat.sp`（仅 `mode == "versus"` 才改写 coop-only 地图）
- `l4d2_map_vote.sp`
- `optional/AnneHappy/ai_jockey_2.sp`
- `optional/AnneHappy/l4d2_anne_thirdperson_fix.sp`
- `optional/AnneHappy/l4d2_tank_announce.sp`
- `optional/MeleeInTheSafeRoom.sp`
- `optional/l4d_tank_damage_announce.sp`
- `optional/nosaferoomkits.sp`
- `extend/ThirdPersonShoulder_Detect.sp`、`extend/new_player_guide.sp`、`extend/l4d_stats/stats_rules.inc`

`confoglcompmod` 内的处理（本 PR）：

- `IsVersus()` / `IsScavengeMode()` 改用 `L4D_GetGameModeType()`；删除 `ItemTracking.sp` 中重复的 `InSecondHalfOfRound()`。
- `BossSpawning` 仅在对抗基础模式下运行。
- `GhostTank` 仅在 `L4D_HasPlayerControlledZombies()` 且感染者队有真人时冻结 AI Tank。
- `FinaleSpawn` 只处理灵魂态（只有真人感染者会进入），感染者队检查保留。

## 4. 过时 / 冲突插件

**配置引用但不存在的 SMX（加载会报错）** — `cfg/sharedplugins.cfg`：

- `extend/anne_status_privacy.smx`
- `anne_mission_cfg_rules.smx`
- `anne_srcds_master_register.smx`

**存在但未被任何 cfg 加载的 SMX**：

- `extend/Survivor_Legs.smx`、`extend/l4d_ragdoll_fader.smx`
- `fixes/l4d2_jockey_unteleport.smx`、`fixes/l4d2_null_cusercmd_fix.smx`、`fixes/l4d2_shove_fix.smx`
- `optional/AnneHappy/anne_navgraph_export.smx`
- `optional/christmas_surprise.smx`、`optional/pill_passer.smx`、`optional/visualise_impacts.smx`

**同名源码重复（两份源码可能编译成同一 SMX，易混淆）**：`l4d2_nativevote`、`l4d2_nobhaps`、`l4d2_tank_announce`、`l4d_boss_vote`、`l4d_rock_lagcomp`、`l4d_tank_damage_announce`。

**无同名源码的 SMX（28 个）**：主要是 `infected_controlYY-MM.smx` 回滚版本和 AI 版本归档；按 `AGENTS.md` 的版本回滚流程属于有意保留，**不应删除**。

## 5. 最小模块化配置建议

| 层 | 文件 | 内容 |
| --- | --- | --- |
| 基础修复 | `cfg/generalfixes.cfg` | `anne_db` 首行 + `fixes/*`，所有模式共用 |
| 通用 | `cfg/sharedplugins.cfg` | 与模式无关的扩展（统计、投票、语言）；先移除 3 个缺失引用 |
| 对抗核心 | `cfgogl/<mode>/confogl_plugins.cfg` | `confoglcompmod`、readyup、scoremod、boss 相关 |
| Anne PVE | `cfgogl/annehappy/confogl_plugins.cfg` + `shared_plugins.cfg` | `versus_coop_mode`、`infected_control`、AI 特感、`anne_traitor_quota`、target override |
| Coop | `cfgogl/coop/*.cfg` | `confoglcompmod` + `l4d2_dirspawn`、`spawn_vote_menu` |

建议的后续动作（需确认后执行，均为破坏性改动）：

1. 删除或补齐 3 个缺失 SMX 的引用。
2. 确认 9 个未加载 SMX 是否仍需要；不需要则移到 `disabled/`。
3. 每组重复源码只保留实际编译部署的一份。
4. 将第 3 节列出的字符串模式判断统一为 left4dhooks 判断（逐插件单独 PR）。
