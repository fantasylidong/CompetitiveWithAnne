# 地图记录 v2 迁移方案

## 目标

地图记录 v2 把“玩法配置”从旧的 `mode=0..7` 中拆出，使用 `ruleset_key` 区分 Anne、合作、对抗、清道夫和各种自定义 cfg。

- `map_runs`：一局一行，保存规则、版本、时长和结果。
- `map_run_players`：保存该局的幸存者/感染者参与者。
- `legacy_map_bests`：保存旧 `timedmaps` 的“每名玩家最佳值 + plays”。
- `timedmaps` 和 `timedmap_runs` 不删除；Anne/合作类竞速仍双写旧表，方便快速回退。

## 记录策略

`l4d_stats_map_record_policy` 默认为 `-1` 自动判断：

| 规则 | 策略 | `timing_profile` |
| --- | --- | --- |
| Anne、硬核、喷子硬核、WitchParty、AllCharger、Alone、Hunters | 最佳成绩榜 | `completion` |
| 合作、写实、突变、生存 | 最佳成绩榜 | `completion` / `survival` |
| 对抗、写实对抗、清道夫 | 回合历史，不比较最快 | `round_history` |

未设置 `l4d_stats_map_ruleset` 时，插件会优先识别 Anne 模式，其他 cfg 从 `l4d_ready_cfg_name` 生成稳定 slug。可用以下 cvar 显式覆盖：

```cfg
l4d_stats_map_record_policy "-1"        // -1 自动，0 关闭，1 回合历史，2 成绩榜
l4d_stats_map_ruleset ""                // 例如 zonemod；空值自动
l4d_stats_map_ruleset_version ""        // 空值从 AnnePluginVersion/配置名获取
l4d_stats_map_timing_profile ""         // completion/survival/round_history
l4d_stats_map_difficulty_profile ""     // anne_ai/game/none
```

不要只在一个 cfg 中设置非空覆盖后就遗留到下一个模式；如果使用显式覆盖，每个模式都必须设置或重置。通常保持自动值即可。

## 历史数据映射

| 旧 `mode` | 新 `ruleset_key` |
| --- | --- |
| 1 | `annehappy` |
| 2 | `witchparty` |
| 3 | `allcharger` |
| 4 | `alone` |
| 5 | `hunters` |
| 6 | `anne_hardcore` |
| 7 | `anne_shotgun` |
| 0 | 根据 `gamemode` 映射到 `legacy_coop`、`legacy_realism`、`legacy_survival` 等 |

重要边界：

- 旧 `mode=0` 没有记录当时的 cfg 名，无法无损还原为 Zonemod/Acemod/其他具体规则，因此放入 `legacy_*` 隔离区。
- `timedmaps` 只有每名玩家最佳值，无法重建每一局；这些数据进入 `legacy_map_bests`，网页明确标记为“旧版最佳/人次”。
- 存在 `timedmap_runs` 时会额外还原真实旧局和参与者；更老的库缺少该表也可迁移。
- 2026-05-19 以前 Anne `difficulty=3` 表示旧专家记录，迁移时归一到新 AI 专家档 `4`。

## 上线顺序

1. 备份 Stats 数据库，至少单独导出 `timedmaps` 和 `timedmap_runs`。
2. 部署包含迁移脚本的 NewAnneWeb，但先不部署新 `l4d_stats.smx`。
3. 暂停所有会写 Stats 库的游戏服，或进入维护窗口。
4. 在 NewAnneWeb 目录执行预检：

```bash
docker exec anneweb_php php /var/www/html/stats/scripts/migrate_map_records.php --dry-run
```

5. 执行正式迁移。该脚本支持 `STATS_DB_PREFIX` 并可重复执行：

```bash
docker exec anneweb_php php /var/www/html/stats/scripts/migrate_map_records.php
docker exec anneweb_php php /var/www/html/stats/scripts/migrate_map_records.php --verify-only
```

无表前缀的库也可直接执行 `database/migrations/20260726_map_records_v2.sql`。

6. 部署重新编译的 `addons/sourcemod/plugins/extend/l4d_stats.smx`，重启插件或换图。
7. 打开 NewAnneWeb `/stats/campaigns/`，分别检查 Anne、一个合作 cfg 和一个对抗 cfg。
8. 恢复游戏服对外服务，观察 SourceMod 错误日志中是否有 `Map record v2 tables are missing`。

## 回滚

1. 先回滚 NewAnneWeb 和 `l4d_stats.smx`到旧版；旧 `timedmaps`/`timedmap_runs` 在整个过程中都保留。
2. 确认旧页面和插件正常后，如需清理 v2 表，再执行 `database/migrations/20260726_map_records_v2_rollback.sql`。
3. 回滚脚本会删除上线后已产生的 v2 新局，因此不要在未导出 `map_runs`/`map_run_players` 时轻易执行。

