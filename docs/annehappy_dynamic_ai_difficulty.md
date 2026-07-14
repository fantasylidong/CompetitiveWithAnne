# AnneHappy 动态 AI 难度

## PPM 分档

PPM 从 `l4d_stats` 获取。当前默认对每个真人生还者使用总积分 / 总游玩分钟数得到个人 PPM，再对当前生还者队伍取算术平均，避免高积分或长时长玩家把整队难度单独拉高。等下个完整季度数据可信后，可以打开 `ah_ai_dynamic_use_quarter_stats 1`：每个真人生还者季度样本达到 5 小时时使用季度积分 / 季度游玩分钟数，否则回退总积分 / 总游玩分钟数。

插件调用的是 `l4d_stats.smx` 暴露的 native：

- `l4dstats_GetClientScore(client)`
- `l4dstats_GetClientPlayTime(client)`
- `l4dstats_GetClientQuarterScore(client)`
- `l4dstats_GetClientQuarterPlayTime(client)`

只统计当前在生还者队伍的真人玩家，忽略 Bot 和没有有效游玩时间的数据。最终队伍 PPM 使用所有有效玩家的个人 PPM 算术平均，每个当前玩家权重一致；`sm_aippm` 仍显示采用后的积分总和和分钟总和，方便排查数据来源。

定档时机：

- 每回合 `round_start` 后先应用简单难度作为保底，然后立即尝试自动定档。
- 如果 `l4d_stats` 数据还没加载完成，会在安全门内按间隔重试。
- 一旦定档成功，本回合锁定该难度，出门后不会再动态变化。
- 锁定后默认不再定时重刷 cvar，避免覆盖投票或手动 `sm_cvar`；如需防覆盖，可手动把 `ah_ai_dynamic_enforce_interval` 设为大于 `0`。
- `player_left_start_area` 只负责锁定兜底状态：如果出门前仍未读到统计数据，本回合保持简单难度。

默认分档：

| 难度 | PPM 条件 | 说明 |
| --- | --- | --- |
| 1 简单 | `< 30.89` | 低压档，降低速度和进攻行为强度 |
| 2 普通 | `30.89 <= PPM < 43.23` | 标准偏低 |
| 3 困难 | `43.23 <= PPM < 63.70` | 标准偏高 |
| 4 专家 | `63.70 <= PPM < 77.57` | 当前 AnneHappy 专家强度 |
| 5 极限 | `>= 77.57` | 参考 `cfg/vote/hard_on.cfg` 的高压 AI/Tank 属性 |
| 6 音理 | 不参与自动分档 | 固定-only 档，以极限档为底，只叠同级 `Anne-Neri` 的 `si_level_hard` / `hunter_hentai` 中更难的特感/Tank 行为 CVar；不覆盖人数、尸潮、Tank 血量、刷点/传送距离等基础环境，必须通过投票或 `sm_aidiff 6` 手动开启 |

可调 cvar：

插件默认 cvar 配置已生成在：

`cfg/sourcemod/annehappy_dynamic_ai_difficulty.cfg`

| Cvar | 默认值 | 说明 |
| --- | --- | --- |
| `ah_ai_dynamic_enable` | `1` | 是否启用动态难度 |
| `ah_ai_dynamic_check_interval` | `5.0` | 回合定档前，从 `l4d_stats` 重试检查平均 PPM 的间隔 |
| `ah_ai_dynamic_ppm_normal` | `30.89` | 进入普通难度阈值 |
| `ah_ai_dynamic_ppm_hard` | `43.23` | 进入困难难度阈值 |
| `ah_ai_dynamic_ppm_expert` | `63.70` | 进入专家难度阈值 |
| `ah_ai_dynamic_ppm_extreme` | `77.57` | 进入极限难度阈值 |
| `ah_ai_dynamic_threshold_mode` | `1` | 阈值来源：`0=固定 cfg`，`1=读取数据库每日分位阈值` |
| `ah_ai_dynamic_threshold_db_config` | `l4dstats` | 每日阈值表所在数据库配置名，对应 `databases.cfg` |
| `ah_ai_dynamic_threshold_table` | `ai_dynamic_ppm_thresholds` | 每日阈值表名 |
| `ah_ai_dynamic_threshold_max_age` | `172800` | 数据库阈值最大有效秒数；默认 2 天，过期回退固定 cfg |
| `ah_ai_dynamic_fixed_level` | `0` | `0=自动`，`1-5=固定简单/普通/困难/专家/极限`，`6=音理`；音理不会被自动难度选中 |
| `ah_ai_dynamic_config` | `configs/AnneHappy/dynamic_ai_difficulty.cfg` | 每档难度的特感/Tank cvar 配置文件，相对 `addons/sourcemod` |
| `ah_ai_dynamic_enforce_interval` | `0.0` | 难度锁定后定期重刷当前档位 cvar；默认关闭，避免覆盖投票或手动 `sm_cvar` |
| `ah_ai_dynamic_tank_bhop_override` | `-1` | Tank 连跳覆盖：`-1=跟随档位配置`，`0=强制关闭`，`1=强制开启`；Alone 使用 `0` |
| `ah_ai_dynamic_use_quarter_stats` | `0` | 是否启用季度 PPM 优先；当前季度数据失真，默认关闭 |
| `ah_ai_dynamic_quarter_min_minutes` | `300` | 启用季度 PPM 时，玩家季度样本低于该分钟数则回退总积分 PPM |
| `ah_ai_dynamic_announce` | `1` | 调档时聊天提示 |
| `ah_ai_dynamic_debug` | `0` | 输出调试日志 |

命令：

| 命令 | 说明 |
| --- | --- |
| `sm_aippm` | 查看当前积分、时间、PPM、难度 |
| `sm_aidiff <0-6>` | 管理员切换模式；`0=自动`，`1-5=固定自动档`，`6=音理固定档` |
| `sm_aidiff_reload` | 重新读取配置文件，并把当前难度重新应用一次 |

## 每日分位阈值

推荐流程是网页或 cron 每天凌晨 4 点计算一次 PPM 分位数，然后写入数据库；插件只读取 `id=1` 这一行，不在游戏内跑排行榜大查询。网页脚本按“每个玩家一条个人 PPM 样本”计算分位，和游戏内当前队伍个人 PPM 均值的口径一致。读取失败、数据为空或超过 `ah_ai_dynamic_threshold_max_age` 时，插件回退使用 cfg 里的固定阈值。

分位映射：

| 难度 | 数据库字段 |
| --- | --- |
| 简单/普通分界 | `ppm_p60` |
| 普通/困难分界 | `ppm_p75` |
| 困难/专家分界 | `ppm_p90` |
| 专家/极限分界 | `ppm_p95` |

插件会自动建表，也可以提前建：

```sql
CREATE TABLE IF NOT EXISTS ai_dynamic_ppm_thresholds (
  id TINYINT UNSIGNED NOT NULL DEFAULT 1,
  source VARCHAR(32) NOT NULL DEFAULT 'daily',
  sample_count INT NOT NULL DEFAULT 0,
  ppm_p60 FLOAT NOT NULL DEFAULT 30.89,
  ppm_p75 FLOAT NOT NULL DEFAULT 43.23,
  ppm_p90 FLOAT NOT NULL DEFAULT 63.70,
  ppm_p95 FLOAT NOT NULL DEFAULT 77.57,
  updated_at INT NOT NULL DEFAULT 0,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

网页/cron 算完后写入：

```sql
INSERT INTO ai_dynamic_ppm_thresholds
  (id, source, sample_count, ppm_p60, ppm_p75, ppm_p90, ppm_p95, updated_at)
VALUES
  (1, 'mixed_5h', 7379, 30.89, 43.23, 63.70, 77.57, UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE
  source = VALUES(source),
  sample_count = VALUES(sample_count),
  ppm_p60 = VALUES(ppm_p60),
  ppm_p75 = VALUES(ppm_p75),
  ppm_p90 = VALUES(ppm_p90),
  ppm_p95 = VALUES(ppm_p95),
  updated_at = VALUES(updated_at);
```

## 难度配置文件

每档特感/Tank 属性已经移到：

`addons/sourcemod/configs/AnneHappy/dynamic_ai_difficulty.cfg`

格式为 SourceMod KeyValues：

```text
"AnneHappyDynamicAIDifficulty"
{
    "level1"
    {
        "ai_smoker3_bhop" "1"
        "ai_SmokerBhopSpeed" "70"
    }

    "level2"
    {
        "ai_smoker3_bhop" "1"
        "ai_SmokerBhopSpeed" "90"
    }
}
```

插件定档后只读取对应的 `level1` / `level2` / `level3` / `level4` / `level5` / `level6` 节点，把里面的键名当作 cvar、值当作 cvar 值应用。不存在的 cvar 会被忽略；开启 `ah_ai_dynamic_debug 1` 后会在日志里提示。`level6` 是固定音理档，不会被自动难度选中。

改完配置后可以执行 `sm_aidiff_reload` 热重载当前难度；下一回合也会自动读取最新配置。

## 分档主要改动的属性

AI 难度插件本身只负责定档和应用 AI/Tank 行为 cvar；刷特插件会读取 `ah_ai_dynamic_current_level`，按当前档位调整“什么时候开始判定下一波”“什么时候允许补下一波”“刷点评分甜区”和 anti-baiter 压力。1-5 自动档里，`l4d_infected_limit`、`versus_special_respawn_interval`、`inf_SpawnDistanceMin` 仍由当前章节/配置决定基础值，动态难度只在这些基础值上做策略缩放。固定音理 `level6` 也不覆盖这些基础环境；它以极限档为底，只额外叠加 `Anne-Neri` 高难投票档里更坐牢的特感/Tank 行为 CVar，Hunter 使用 `si_level_hard` 中更狠的 `hunter_hentai` 值。插件应用任意档位前都会先把受控 CVar 恢复到首次接管时的基线，避免音理档残留影响正常难度。

### 刷特策略联动

刷特插件新增了一个轻量策略层：

| CVar | 默认 | 说明 |
| --- | --- | --- |
| `inf_ai_difficulty_link` | `1` | 是否读取 `ah_ai_dynamic_current_level` 联动刷特策略 |
| `inf_ai_difficulty_fallback_level` | `3` | 动态难度未定档或插件缺失时使用的刷特策略档 |
| `inf_ai_wave_check_ratio` | `1.00 0.75 0.625 0.50 0.375 0.375` | 1-6 档分别在刷新间隔的多少比例后开始判定下一波；第 6 档沿用极限节奏 |
| `inf_ai_wave_floor_ratio` | `1.50 1.40 1.25 1.15 1.10 1.10` | 1-6 档普通补波的最早时间，乘以 `versus_special_respawn_interval`；新版 `0.1s` 开波 timer 下用它恢复旧版实战节奏 |
| `inf_ai_wave_low_si_ratio` | `0.12 0.20 0.27 0.34 0.50 0.50` | 场上存活特感低于该比例时允许补波 |
| `inf_ai_dist_sweet_offset` | `0.00 0.00 0.00 0.00 0.00 0.00` | 刷点距离甜区偏移；默认不动各特感自己的甜点距离 |
| `inf_ai_dist_width_scale` | `1.25 1.15 1.08 1.00 1.00 1.00` | 刷点距离评分宽度；低档更宽容，专家/极限/音理保持当前基准，避免影响刷出速度 |
| `inf_spawn_candidate_budget` | `12` | 单次刷点基础候选预算；实际预算还会按 AI 难度档位调整 |
| `inf_ai_spawn_budget_bonus` | `-3 -2 -1 0 0 0` | 1-6 档对候选预算的额外加减；默认实际预算为 `9/10/11/12/12/12` |
| `inf_FrameThinkStep` | `0.05` | 空闲刷特帧思考间隔，降低无队列时的单核负担 |
| `inf_FrameThinkStepActive` | `0.02` | 有待补波/待刷/待传送时使用原版响应间隔 |
| `inf_BucketCountCacheTTL` | `0.20` | Flow 桶存活特感计数缓存 TTL，减少候选点重复扫描 |

以 16 秒刷新为例，专家档约 8 秒开始检查、18.4 秒作为普通补波下限；简单档约 14.4 秒才开始检查且普通补波要等到 24.0 秒；极限档约 5.6 秒开始检查，但普通补波下限仍为 17.6 秒。anti-baiter 可以提前识别蹲点等刷，但 `AntiBait_ShouldStartWaveEarly()` 仍必须通过普通补波下限；Pressure 快速传送只用于把不可见的存活 SI 换点，不是新增普通补波。刷点距离甜点仍由特感类型决定，难度默认只让低档更宽容，不让极限更吃候选扫描。

旧配置里的 `inf_AntiBaitMode` 和 `inf_TeleportDistance` 仍作为兼容别名读取；推荐新配置逐步迁移到 `inf_antibait_enable` 和 `inf_TeleportDistanceMin`。

### Anti-baiter 重做

新的 anti-baiter 不再单纯因为玩家停留就惩罚，而是同时看三件事：

- 生还是否持续没有推进，默认 `inf_antibait_window 12.0` 秒。
- 是否进入压力窗口：场上还有特感，或已经有待刷/待传送队列，或已经到达可判定下一波窗口。
- 生还是否仍是互相覆盖的整体队形：硬抱团看 `inf_antibait_cluster_dist 800.0`，软队形看整体跨度、平均最近队友距离和是否断成多个小组；默认分散/队友/孤立距离分别为 `1500.0`、`800.0`、`1200.0`。进入 Pressure 后，只要有效推进或队伍分散，就会进入恢复/放波。

进入 Pressure 后，`inf_antibait_action 1` 会限制最晚开波时间，`2` 还会让不可见特感走快速传送换点，用于对抗“站在甜点等刷新”的打法；跑男仍会被单独标记并优先作为刷点目标。

### 特感和 Tank AI 强化

从简单到极限逐步增强，但非极限档尽量保持同一套基础行为，不再用大量开关差异制造难度。

- Tank：默认所有档都保留 AITank3 连跳和无视野连跳；Alone 通过 `ah_ai_dynamic_tank_bhop_override 0` 强制关闭 Tank 连跳。无视野连跳角度按各模式 `shared_settings.cfg` 的普通强度基准恢复为 `57.0`，不参与动态难度分档。主要区分停跳距离、连跳加速度、最大速度、空中修正角度和攀爬倍速。`ai_TankSneakTime` 和旧的 `ai_TankAirAngleRestrict` 不属于当前 `ai_tank3.smx`，已经从配置移除。
- Boomer：所有档都开启连跳和转视角，主要区分连跳速度与转视角帧数；专家保持 15 帧，极限为 10 帧。
- Charger：所有档都开启连跳，主要区分 `ai_ChagrerBhopSpeed`。
- Spitter：所有档都开启连跳，主要区分 `ai_SpitterBhopSpeed`。
- Jockey：所有档都开启连跳，连跳启动距离统一为 `600`，骗推行为概率统一为冻结/后跳/高跳 `40/10/50`。`ai_JockeyAllowInterControl` 全档固定为 `0`，抢控目标由 `target_override` 控制。
- Hunter：主要区分基础飞扑空速和低飞角度。简单档垂直角度更大，Hunter 更容易飞高，给玩家更多空爆窗口；越难越低飞。极限档额外启用 `l4d2_hunter_patch_convert_leap 1` + `l4d2_hunter_patch_crouch_pounce 2`，等同原 `crouch_on` 强化。
- Smoker：所有档都开启连跳和无视野连跳，主要区分连跳速度、左右偏角、无视野角度和空中速度修正角度。越难空中修正阈值越小，修正更早介入。

`cfg/vote/hard_on.cfg` 里属于投票/样本或刷点节奏的项目没有加入动态难度：`sm_veterans_*` 不是特感/Tank 行为属性，`inf_TeleportCheckTime` 属于传送检查节奏。

### 极限档新增属性合并记录

动态难度配置里不写 `sm_cvar` 命令，而是写成 KeyValues：`"cvar名" "值"`。例如 `sm_cvar z_lunge_reflect 1` 在 `level5` 里对应 `"z_lunge_reflect" "1"`，意思是极限档定档时由 `annehappy_dynamic_ai_difficulty.smx` 找到这个 ConVar 并把值设为 `1`。

插件会把各档配置里出现过的所有 ConVar 作为受控范围，在 `OnConfigsExecuted` 后首次接管时记录当前模式已经应用完成的服务器值作为基线；之后每次应用档位前都会先把受控 ConVar 恢复到基线，再写入目标档的值。因此极限/音理独有参数不会在切回专家、困难、普通或简单后残留，也不会把 AnneHappy 的基准硬套到 1vHunters、Alone 或 WitchParty。

| 特感 | 参数 | 原极限档或基础值 | 新参数 | 合并值 | 说明 |
| --- | --- | --- | --- | --- | --- |
| Hunter | `z_pounce_crouch_delay` | patch 已运行时置 0 | 0 | 0 | 显式锁定无蹲伏等待 |
| Hunter | `z_lunge_interval` / `z_lunge_cooldown` | 默认 0.1 / 0.1 | 0 / 0 | 未合并 | 极限档不覆盖，保持默认 `0.1` |
| Hunter | `z_lunge_reflect` / `z_lunge_up` | 游戏默认 0 / 200 | 1 / 150 | 1 / 150 | 极限档启用墙面反射并降低上抬力；退出该档后恢复当前模式基线 |
| Hunter | `z_hunter_lunge_distance` | 基础 5000 | 99999 | 99999 | 极限档允许超远飞扑判定 |
| Hunter | `hunter_leap_away_give_up_range` | 未在极限档设置 | 99999 | 99999 | 不轻易放弃远距离 leap away 逻辑 |
| Hunter | `ai_hunter_angle_mean` / `ai_hunter_angle_std` | 默认 10 / 极限 20 | 30 / 10 | 30 / 10 | 侧飞角更偏，随机波动更收束 |
| Hunter | `ai_hunter_angle_diff` | 3 | 6 | 6 | 放宽左右侧飞次数差 |
| Hunter | `ai_hunter_no_sight_pounce_range` | 300,250 | 500,250 | 500,250 | `no_sign` 是旧兼容名，配置使用当前正名 `no_sight` |
| Hunter | `ai_hunter_back_vision` | 25 | 0 | 0 | 关闭空中背视角概率 |
| Hunter | `ai_hunter_melee_first` | 300.0,1000.0 | 1 | 300.0,1000.0 | 本插件里它是距离范围，不是布尔开关，写 1 会削弱 |
| Hunter | `ai_hunter_sight_revise` | 无此 ConVar | 1 | 未合并 | 当前 `ai_hunter_2.smx` 源码没有定义，写入不会生效 |
| Jockey | `z_jockey_leap_range` / `z_leap_interval` | 未在极限档设置 | 99999 / 0.1 | 99999 / 0.1 | 扩大骑乘跳跃范围，降低跳跃间隔 |
| Jockey | `ai_JockeyBhopSpeed` | 150 | 100 | 150 | 当前极限更强，保留不降级 |
| Jockey | `ai_JockeySpecialJumpChance` | 75 | 20 | 75 | 当前极限骗推概率更高，保留不降级 |
| Jockey | `ai_JockeyStartHopDistance` | 900 | 600 | 600 | 按当前配置统一为 600，避免动态难度高档覆盖基础设置 |
| Jockey | `ai_JockeySpecialJumpRange` | 无此 ConVar | 400 | 未合并 | 当前 `ai_jockey_2.smx` 源码没有定义，写入不会生效 |
| Spitter | `l4d2_spit_dmg` / `l4d2_spit_alternate_dmg` | 基础 2 / 3 | 3 / 2 | 3 / 2 | 主 tick 更疼，交替 tick 稍低 |
| Smoker | `smoker_tongue_delay` | 0.0 | 0.1 | 0.0 | 当前基础值更快，极限档显式保留 0.0 |
| Smoker | `tongue_miss_delay` / `tongue_range` / `tongue_fly_speed` | 未在极限档设置 | 3 / 800 / 1200 | 3 / 800 / 1200 | 舌头失败冷却、距离、飞行速度进入极限档 |
| Boomer | `z_vomit_fatigue` / `z_vomit_range` / `z_vomit_maxdamagedist` | 未在极限档设置 | 专家疲劳一半 / 专家距离 / 保持极限原值 | 1500 / 300 / 500 | 喷吐距离回专家基线，只降低疲劳到专家值的一半；最大伤害距离不改 |
| Boomer | `boomer_horde_amount` 基准值 | 12 / 13 / 10 / 10 | 保持专家基准 | 12 / 13 / 10 / 10 | 基准已迁到 Anne 三套 `confogl_plugins.cfg` 的插件加载后，只初始化一次；极限覆盖值按专家值 + `5 * 被喷人数` 计算为 17 / 23 / 25 / 30 |
| Boomer | `ai_BoomerBhopSpeed` | 250 | 120 | 250 | 当前极限连跳速度更高，保留不降级 |

## 五档对比

| 属性组 | 简单 `<30.89` | 普通 `30.89-43.23` | 困难 `43.23-63.70` | 专家 `63.70-77.57` | 极限 `>=77.57` |
| --- | --- | --- | --- | --- | --- |
| 反应时间 | 远距 5.0 / 近距 0.5 | 5.0 / 0.5 | 5.0 / 0.5 | 5.0 / 0.5 | 0.0 / 0.0 |
| Hunter/Jockey 空速 | 700 / 700 | 750 / 750 | 800 / 800 | 850 / 850 | 900 / 900 |
| Hunter 垂直角度 | 12，更容易飞高 | 10 | 8 | 7 | 6 |
| Hunter patch | 关闭 | 关闭 | 关闭 | 关闭 | `convert_leap=1`，`crouch_pounce=2` |
| Smoker 连跳 | 开启，速度 70，修正角 70 | 速度 90，修正角 60 | 速度 105，修正角 55 | 速度 120，修正角 50 | 速度 150，修正角 45 |
| Jockey | 速度 50，距离 600，骗推 40/10/50 | 速度 60，距离 600，骗推 40/10/50 | 速度 70，距离 600，骗推 40/10/50 | 速度 80，距离 600，骗推 40/10/50 | 速度 150，距离 600，骗推 40/10/50，背视角 100% |
| Spitter | 连跳速度 45 | 65 | 85 | 100 | 250 |
| Charger | 连跳速度 45 | 60 | 75 | 90 | 150 |
| Boomer | 速度 70，30 帧转目标 | 95，25 帧 | 125，20 帧 | 150，15 帧 | 250，10 帧，喷吐距离 300，疲劳 1500；尸潮基准仍由 `confogl_plugins.cfg` 初始化 |
| Tank | 无视野 57，220 / 650 / 60 | 57，190 / 720 / 55 | 57，170 / 820 / 50 | 57，150 / 920 / 45 | 57，135 / 980 / 45 |

## confogl_plugins.cfg 中 AI 和 Hunter Patch 的 ConVar

### `ai_smoker3.smx`

`ai_smoker3_bhop`, `ai_smoker3_bhop_no_vision`, `ai_SmokerBhopSpeed`, `ai_smoker3_bhop_min_speed`, `ai_smoker3_bhop_max_speed`, `ai_smoker3_bhop_min_dist`, `ai_smoker3_bhop_max_dist`, `ai_smoker3_bhop_side_minang`, `ai_smoker3_bhop_side_maxang`, `_ai_smoker3_bhop_nvis_maxang`, `ai_smoker3_airvec_modify_degree`, `ai_smoker3_airvec_modify_degree_max`, `ai_smoker3_airvec_modify_interval`, `ai_smoker3_imm_pull`, `ai_smoker3_pull_back_vision`, `ai_smoker3_anti_retreat`, `ai_smoker3_move2_newtar_interval`, `ai_smoker3_stop_warn_snd`, `ai_smoker3_plugin_name`, `ai_smoker3_log_level`

### `ai_hunter_2.smx`

`ai_hunter_fast_pounce_distance`, `ai_hunter_vertical_angle`, `ai_hunter_angle_mean`, `ai_hunter_angle_std`, `ai_hunter_straight_pounce_distance`, `ai_hunter_aim_offset`, `ai_hunter_no_sight_pounce_range`, `ai_hunter_back_vision`, `ai_hunter_melee_first`, `ai_hunter_high_pounce`, `ai_hunter_wall_detect_distance`, `ai_hunter_angle_diff`

### `l4d2_hunter_patch.smx`

`l4d2_hunter_patch_convert_leap`, `l4d2_hunter_patch_crouch_pounce`, `l4d2_hunter_patch_bonus_damage`, `l4d2_hunter_patch_pounce_interrupt`

### `ai_jockey_2.smx`

`ai_JockeyBhopSpeed`, `ai_JockeyStartHopDistance`, `ai_JockeyStumbleRadius`, `ai_JockeySpecialJumpAngle`, `ai_JockeySpecialJumpChance`, `ai_jockeyNoActionChance`, `ai_JockeyAllowInterControl`, `ai_JockeyBackVision`

### `ai_spitter_2.smx`

`ai_SpitterBhop`, `ai_SpitterBhopSpeed`, `ai_SpitterTarget`, `ai_SpitterPinnedPr`, `ai_SpiiterDieAfterSpit`

### `ai_charger_2.smx`

`ai_ChargerBhop`, `ai_ChagrerBhopSpeed`, `ai_ChargerChargeDistance`, `ai_ChargerExtraTargetDistance`, `ai_ChargerAimOffset`, `ai_ChargerMeleeAvoid`, `ai_ChargerMeleeDamage`, `ai_ChargerTarget`, `ai_ChargerChargeHeightDiff`

### `ai_boomer_2.smx`

`ai_BoomerBhop`, `ai_BoomerBhopSpeed`, `ai_BoomerUpVision`, `ai_BoomerTurnVision`, `ai_BoomerForceBile`, `ai_BoomerBileFindRange`, `ai_BoomerTurnInterval`, `ai_BoomerDegreeForceBile`, `ai_BoomerAutoFrame`

### `boomer_horde_equalizer_refactored.smx`

插件本体保持原版逻辑，不读取 `ah_ai_dynamic_current_level`。AnneHappy、AnneHappy Hardcore、AnneHappy Shotgun 三套模式在各自 `confogl_plugins.cfg` 中，紧跟 `sm plugins load optional/boomer_horde_equalizer_refactored.smx` 后初始化当前专家基准：

| 被喷人数 | 专家/基准值 | 极限覆盖参考值 |
| --- | --- | --- |
| 1 | 12 | 17 |
| 2 | 13 | 23 |
| 3 | 10 | 25 |
| 4 | 10 | 30 |

三套模式 cfg 里的旧 `boomer_horde_amount` 行已注释保留，只作为基准记录，避免模式配置重复执行时覆盖运行期调整。

### `ai_tank3.smx`

`ai_tank3_enable`, `ai_tank_bhop`, `ai_Tank_StopDistance`, `ai_tank3_bhop_max_dist`, `ai_tank3_bhop_min_speed`, `ai_tank3_bhop_max_speed`, `ai_tank3_bhop_impulse`, `ai_tank3_bhop_no_vision`, `_ai_tank3_bhop_nvis_maxang`, `ai_tank3_airvec_modify_degree`, `ai_tank3_airvec_modify_degree_max`, `ai_tank3_airvec_modify_interval`, `ai_tank3_throw_min_dist`, `ai_tank3_throw_max_dist`, `ai_tank3_climb_anim_rate`, `ai_tank3_low_climb_anim_rate`, `ai_tank3_ladder_climb_rate`, `ai_tank3_rock_target_adjust`, `ai_tank3_back_fist`, `ai_tank3_back_fist_range`, `ai_tank3_back_fist_max_spd`, `ai_tank3_punch_lock_vision`, `ai_tank3_jump_rock`, `ai_tank3_back_fist_window`, `ai_tank3_head_block_enable`, `ai_tank3_head_block_time`, `ai_tank3_head_block_vertical`, `ai_tank3_head_block_horizontal`, `ai_tank3_head_block_ignore_time`, `ai_tank3_head_block_force_rock_time`, `ai_tank3_head_block_force_rock_range`, `ai_tank3_head_block_force_rock_release_h`, `ai_tank3_head_block_force_rock_release_v`, `ai_tank3_plugin_name`, `ai_tank3_log_level`

第 4 档保留专家强度但回调 Tank 机动上限；第 5 档参考 `cfg/vote/hard_on.cfg` 作为极限强度，并只调整特感和 Tank 的行为属性。Tank 翻越/爬梯速率已整体回落，降低卡住、卡点抖动或同一位置反复上下攀爬的风险。
