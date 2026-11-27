# 玩家分武器战斗统计 + NewAnneWeb 命中率展示：计划

> 范围：公开部分（CompetitiveWithAnne 插件 + NewAnneWeb 页面）。
> 作弊检测部分只在私有仓库 `Myl4d2privateplugins/docs/COMBAT_ANTICHEAT_PLAN.md` 中描述，公开文档与公开代码里不出现检测特征和阈值。

## 0. 现状（调研结论）

| 来源 | 现有内容 | 缺口 |
| --- | --- | --- |
| `extend/l4d_stats`（`players` / `player_mode_stats` / `score_quarter`） | 每个玩家的 `kills`、`headshots`；网页“爆头率” = 爆头击杀 / 击杀 | 只按击杀算，没有武器维度，没有命中数、开枪数和伤害 |
| `extend/l4d2_weapon_balance_stats`（`weapon_balance_daily` / `usage_daily` / `tank_fights`） | 按武器 × 目标 × 距离 × 移动状态 × 技术档的 hits / headshots / 伤害 / 击杀 / 开枪数 | **匿名**，没有 steamid，没法做个人统计 |
| `extend/HitStatistics` | 只在聊天里报每局被控次数 | 不入库 |
| NewAnneWeb `stats/weapons` | 全服武器平衡看板 | 没有命中率列，也没有个人武器页 |
| NewAnneWeb `stats/ranking/player.php` | 总体爆头率卡片 | 没有分武器统计 |

结论：命中判定已经在 `l4d2_weapon_balance_stats` 里实现（`player_hurt` / `infected_hurt` 的 hitgroup、霰弹按弹丸、穿透、GL 爆炸都处理过），**个人统计直接复用这套判定，只需新增一个按 steamid 的聚合维度**，不另写一个 hook 同样事件的插件，避免同一次命中被两套逻辑算出不同结果。

## 1. 指标口径（先定死，网页和插件共用）

| 指标 | 定义 | 备注 |
| --- | --- | --- |
| 击杀爆头率（**保留旧口径**） | 爆头击杀 / 击杀 | `players.headshots` 不改，网页原有卡片不动 |
| 命中爆头率（新） | 爆头命中 / 命中 | 霰弹按弹丸算；对 Tank / Witch 单独统计，不计入总体 |
| 开枪命中率（新） | 至少命中一个目标的射击次数 / 射击次数 | 一发子弹穿透多个目标只算一次命中射击 |
| 弹丸命中率（霰弹，新） | 命中弹丸数 / 发射弹丸数 | |
| 伤害 | 原始伤害、有效伤害（扣掉溢出） | 和平衡统计同一口径 |
| 击杀效率 | 每次击杀消耗的子弹数、一枪毙命率 | |
| 辅助维度 | 目标类型（普感 / 各特感 / Tank / Witch）、距离档、移动状态 | 个人表只保留粗粒度，见 §2 |

统计范围：只统计真人生还者、离开安全区以后、人数满足 `HasEnoughHumanSurvivors` 的局，和现有平衡统计保持一致；友伤和打 bot 生还者不计入。

## 2. 插件改动（公开）：`l4d2_weapon_balance_stats` 1.3.0 → 1.4.0

1. **按玩家累加**：新增 `g_iPlayerStats[MAXPLAYERS+1][WEP_COUNT][TGROUP_COUNT][PFIELDS]`。
   - `TGROUP` = 普感 / 特感 / Tank / Witch（4 档）。个人层面不保留距离和移动状态的全量笛卡尔积，避免行数暴涨。
   - 距离只保留“远距离命中数”和“距离总和”两个列，用来算平均交战距离。
   - 在 `RecordHit` / `Event_WeaponFire` / 击杀处同时写入，和匿名统计共用同一次判定。
   - 玩家断线、换队、回合结束时把该玩家的数据落盘并清零（steamid 在 `OnClientAuthorized` 时缓存）。
2. **新表 `player_weapon_daily`**（同一个 `l4dstats` 库，通过 anne_db 共享连接）：
   ```
   stat_date, steamid(ascii 32), ruleset_key, anne_version, difficulty_type, difficulty,
   weapon_key, target_group,
   shots_fired, pellets_fired, shots_hit, pellets_hit, hits, headshots,
   raw_damage, effective_damage, kills, headshot_kills, one_shot_kills,
   long_range_hits, dist_sum, hold_seconds
   PK(stat_date, steamid, ruleset_key, anne_version, difficulty_type, difficulty, weapon_key, target_group)
   KEY(steamid, stat_date)
   ```
   - 写入方式：回合结束 / 换图时用 `Transaction` 批量 `INSERT ... ON DUPLICATE KEY UPDATE col = col + VALUES(col)`，每批 32 行，沿用现有 `SQL_BATCH_ROWS`。
   - 估算：每人每天约 5~8 把武器 × 4 档 ≈ 30 行，日活 500 人约 1.5 万行/天，可以接受。
3. **按地图回合的明细表 `player_combat_rounds`**（一行 = 一名玩家在一张图的一回合，合计所有武器）：开枪、命中、爆头、伤害、击杀、存活时长、倒地次数。用于网页的“近期对局”趋势，也作为私有检测插件的基础数据源（它只读这张表，不需要往公开插件里塞检测逻辑）。保留 180 天，由网页端的定时任务清理。
4. 对外提供 forward `L4D2WBS_OnRoundPlayerStatsFlushed(client, ...)`（可选），供私有插件挂靠。默认不需要，私有插件自己 hook 事件更安全。
5. 新 ConVar：`l4d2_wbs_player_enable`（默认 1）、`l4d2_wbs_player_min_shots`（单回合少于该开枪数不写 rounds 表，默认 20）。
6. 遵守 AGENTS.md 的数据库规则：只用 `AnneDB_ConnectCompat`，不调 `SetCharset`，建表放在现有 schema 事务里，迁移用 `ALTER TABLE ... ADD COLUMN` 并带列存在性检查（已有 `OnSchemaTxnSuccess` 检查列的模式可以复用）。
7. 不往聊天栏输出内容；如果以后加 `!wstats` 指令，用 translations 文件（chi/zho/en/ja/ko）。
8. 同步 `Update_log.md` / `.en` / `.ja` / `.ko`。

## 3. NewAnneWeb 改动

1. `stats/lib/` 新增 `player_weapon_repository.php`（风格参照 `weapon_balance_repository.php`，PDO 预处理，表不存在时优雅降级）。
2. **个人页 `stats/ranking/player.php`**：
   - 原有总体爆头率卡片保留，旁边新增“命中爆头率”“开枪命中率”两张卡，提示文字说明两种口径的区别。
   - 新增“武器”标签页：每把武器的使用时长、开枪数、命中率、命中爆头率、有效伤害、击杀、每杀耗弹，可按时间范围（7 / 30 / 90 天 / 季度）和模式筛选。
   - **战斗画像**：雷达图，各项为玩家相对同模式、同武器人群的百分位（精准度、爆头倾向、远距离倾向、清特效率、Tank 输出、武器多样性），附 30 天趋势折线。
   - 样本门槛：某武器开枪数低于 200 时显示“样本不足”，不参与百分位计算。
3. **全服武器页 `stats/weapons`**：在现有看板加“平均命中率 / 命中爆头率”列（直接从 `weapon_balance_daily` 的 hits 和 usage 的 shots 推导，不依赖新表）。
4. **分武器排行**：`stats/ranking` 加“按武器”筛选，排序项为命中爆头率 / 命中率 / 有效伤害，要求最低样本量，并按季度重置。
5. 缓存：个人武器数据在服务端缓存 10 分钟（现有 `stats/storage` 缓存机制）。
6. i18n：按 NewAnneWeb/AGENTS.md 同步所有语言包。
7. 测试：`stats/tests/player_weapon_repository_test.php`。

## 4. 性能

- **不新增 hook**：个人维度只在现有回调里多做一次数组累加（O(1)），不新增 `OnPlayerRunCmd`、SDKHook 或 trace。
- **普感命中路径**：`infected_hurt` 是最频繁的事件。个人统计只累加 `[client][wep][TGROUP_COMMON]` 几个整数，不做额外的实体属性读取。
- **内存**：`[MAXPLAYERS+1][19][4][约 20 列]` 的 int 数组，约 200 KB，固定分配。
- **数据库**：只在回合结束、换图、玩家断线时异步批量写入；单回合 4 名玩家约 100 行，分 4 批；不新增连接。
- **网页**：个人页按 `(steamid, stat_date)` 索引查询，结果缓存 10 分钟；百分位和排行由每日 cron 预计算，页面不做全表聚合。
- **验收**：测试服对比加载前后 `sm prof` 中本插件的耗时增量（目标 < 0.02 ms/帧），以及 `stats` 的 `var`。

## 5. 阶段与验收

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P1 | 插件个人维度 + 两张新表，测试服跑一周 | `sm_annedb_status` 连接数不增加；人工开 100 枪对比数据库数值；同一次命中在匿名表和个人表里计数一致 |
| P2 | 网页个人武器页 + 全服命中率列 | 旧爆头率数值不变；表不存在时页面不报错 |
| P3 | 战斗画像百分位 + 分武器排行 | 百分位每日由 cron 预计算到 `player_weapon_percentile` 表，页面不做实时聚合 |
| P4 | 私有检测插件接入（见私有仓库文档） | 公开仓库里不出现检测相关代码 |

## 6. 风险

- 霰弹 / 穿透 / GL 溅射的命中判定必须复用现有逻辑，否则命中率可能超过 100%。
- 被控、倒地时开的枪：按移动状态单独标记，画像里排除。
- 第三方武器配置（`weapon_config` / `config_hash`）改变时，命中率不可比；个人表需要带 `ruleset_key` 和 `anne_version`，网页默认只比较同版本。
