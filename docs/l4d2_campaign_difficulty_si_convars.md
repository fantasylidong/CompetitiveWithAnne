# L4D2 战役难度（`z_difficulty`）特感 ConVar 与底层行为逆向速查

本文档整理自 Linux 服务端实服（`mp_gamemode = coop`）RCON 对照实验与 `left4dead2/bin/server_srv.so`（32-bit x86 ELF，未 strip，BuildID `63d548cd906cf59fea09cf23d729b56d92467d0e`）完整符号及反汇编取证，用于排查战役、写实、绝境及自定义突变模式下各特感、Tank、Witch 与导演系统在四档战役难度（`Easy` / `Normal` / `Hard` / `Impossible`）下的真实差异。

AnneHappy 药役模式下的六档动态 AI 难度（`level1` 简单 ~ `level6` 音理）由插件读取 `addons/sourcemod/configs/AnneHappy/dynamic_ai_difficulty.cfg` 独立驱动，详见同目录 `docs/annehappy_dynamic_ai_difficulty.md`。

---

## 1. 核心结论

1. **切换 `z_difficulty` 不会动态改写任何其他 ConVar 的数值**：在实服 `coop` 模式下依次执行 `sm_cvar z_difficulty Easy / Normal / Hard / Impossible` 并对比 `differences`，除 `z_difficulty` 本身外，没有任何特感或导演 ConVar 被引擎改写。
2. **战役难度差异全部在引擎读取处分支实现**，`server_srv.so` 共使用三套机制：
   - **按难度后缀拆分的独立 ConVar**：全库共 10 组（如 `tank_burn_duration_{hard,expert}`、`sb_friend_immobilized_reaction_time_{normal,hard,expert}`、`z_hit_incap_factor_*`），代码按 `GetDifficulty()` 选择对应后缀读取。
   - **共用同一个无后缀 ConVar，在读取函数内乘难度系数或直接硬编码覆盖**：最典型的陷阱是 `smoker_tongue_delay` 在 `Hard / Impossible` 下被硬编码为 `0.0s`，`boomer_vomit_delay` 在 `Hard / Impossible` 下被硬编码为 `0.2s / 0.0s`，完全不再读取 ConVar。
   - **按 `CTerrorGameRules::HasPlayerControlledZombies()` 隔离对抗与战役公式**：战役向模式（返回 `false`）直接绕开全部 `*_pz_claw_dmg`、`vs_tank_damage` 与 `tongue_drag_damage_amount`，改走按难度查表的 AI 专属公式。

---

## 2. 引擎难度门控与仓库模式对照

### 2.1 内部枚举与对抗模式改难度的真实表现（含进程内存实测）

- 内部全局静态枚举 `s_difficulty`（`0x00f0c330`，`.data` 段初始值为 `1`）由 `GetDifficulty()`（`0x0050f1a0`：`mov eax, ds:0x00f0c330; ret`）直接返回，引擎全部 51 个难度分支函数**只看 `s_difficulty`，不读 `z_difficulty` 的字符串**：
  - `0` = `Easy`（简单）
  - `1` = `Normal`（普通）
  - `2` = `Hard`（高级 / 困难）
  - `3` = `Impossible`（专家，客户端 UI 与部分 ConVar 后缀写作 `Expert`）
- **在对抗模式（`mp_gamemode "versus"`）下直接改 `z_difficulty Impossible` 的结果**：
  1. **引擎 C++ 层完全无效（`s_difficulty` 仍为 `1`），但 ConVar 字符串会停留在 `"Impossible"` 造成假象**：
     - `DifficultyChanged`（`0x0050f080`）先解析新字符串得到 `ebx = 3`，读取旧值 `edi = s_difficulty`（默认为 `1`）；
     - 因 `ebx != 1`，调用 `CTerrorGameRules::HasConfigurableDifficultySetting()`（`0x004f6ac0`），在 `versus` / `scavenge` / `survival` 下返回 `false`，`0x0050f0c2: cmove ebx, eax` 将目标值强制钳回 `1 (Normal)`；
     - 紧接着 `0x0050f0c5: cmp ebx, edi; je 0x0050f18d` 发现钳回后的 `1` 与旧 `s_difficulty (1)` 相等，**直接提前 `return`，跳过了末尾 `0x0050f18b` 将 ConVar 字符串写回 `"Normal"` 的调用**；
     - 实服 `/proc/<pid>/mem` 验证（`Anne云服#82` 实测及线上药役服抽检）：在 `versus` 下执行 `sm_cvar z_difficulty Impossible`（或 `annehappy/confogl.cfg` 先设 `mp_gamemode "versus"` 再设 `z_difficulty "Impossible"`）后，`sm_cvar z_difficulty` 显示 `"Impossible"`，但内存中 `s_difficulty` 恒为 `1 (Normal)`。
  2. **SourceMod 插件层若直接读 `z_difficulty` 字符串则会按 `"Impossible"` 生效**：
     - `l4d_stats`（`stats_rules.inc`、`persistence.inc`）直接调用 `GetConVarString` 匹配 `"Impossible"`，因此 `annehappy/confogl.cfg` 写 `z_difficulty "Impossible"` 实际作用是让统计插件按专家倍率 `ExpMult` 算分并记入 `*_exp` 字段；
     - `l4d2_dirspawn.sp` 开局难度播报等直接读 ConVar 字符串的逻辑同样会读到 `"Impossible"`。
  3. **逆序切换残留边界（先 `coop + Impossible` 再切 `mp_gamemode versus`）**：
     - `mp_gamemode` 的回调 `ValidateMpGameMode`（`0x004f4000`）不会重置 `s_difficulty`；全二进制仅 `DifficultyChanged` 会写 `s_difficulty`。
     - 若先在 `coop` 下设 `z_difficulty Impossible` 使 `s_difficulty = 3`，随后仅执行 `sm_cvar mp_gamemode versus` 且不再触发 `DifficultyChanged`，实测内存中 `s_difficulty` **会残留在 `3`**（Confogl 切模式会先重置受管 ConVar 为默认值 `"Normal"` 再加载 `confogl.cfg`，因此正常比赛加载不会残留；残留态下只要再执行一次 `sm_cvar z_difficulty Impossible/Hard` 触发回调，因 `1 != 3` 便会立即把 `s_difficulty` 和 ConVar 字符串一并打回 `1 / "Normal"`）。
     - 若在 `versus` 下通过上述残留或内存补丁强行令 `s_difficulty = 3`：先检查 `HasPlayerControlledZombies()` 的分支（Tank `1.5×` 血量、`vs_tank_damage`、全特感 `*_pz_claw_dmg`、`tongue_drag_damage_amount`、`z_max_player_zombies`）**仍保持对抗数值不变**；而仅检查 `GetDifficulty()` 的分支（Smoker 绞杀 `3×`、Hunter 扑倒 `3×`、Jockey 骑乘 `3×`、Charger 撞飞 `2×` 与撞墙 `20`、AI 拉舌/喷吐前摇硬编码清零、Tank 烧死 `85s`、友伤系数、Witch 秒杀）**会在对抗中按专家难度生效**。

### 2.2 本仓库 `cfg/cfgogl/*` 各模式实际落入的底层分支

| 仓库模式代表 | `mp_gamemode` | `confogl.cfg` 中的 `z_difficulty` | 实际 `GetDifficulty()` | `HasPlayerControlledZombies()` | 实际生效机制 |
| --- | --- | --- | --- | --- | --- |
| `annehappy`、`annehappy_hardcore`、`annehappy_shotgun`、`alone`、`hunters`、`allcharger`、`witchparty` | `versus` | `"Impossible"` | **`1 (Normal)`**（被引擎强制钳回） | `true` | 走对抗玩家特感公式；`smoker_tongue_delay` / `boomer_vomit_delay` / `*_pz_claw_dmg` / `vs_tank_damage` 全部正常读取 ConVar，难度由 `shared_cvars.cfg` 与 `dynamic_ai_difficulty.cfg` 控制 |
| `zonemod`、`nextmod*`、`eq*`、`acemodrv`、`apex`、`pmelite`、`neomod`、`zm*`、`zh*`、`amrv*` | `versus` | `"normal"` | **`1 (Normal)`** | `true` | 标准竞技对抗分支 |
| `not0721_coop_*`（除 `wtf`）、`not0721_realism_*`、`not0721_mutation4*`、`not0721_community2`、`not0721_community5*`、`purecommunity5` | `coop` / `realism` / `mutation4` / `community2` / `community5` | `"Impossible"` | **`3 (Impossible)`** | `false` | 真正进入专家分支：`smoker_tongue_delay` 与 `boomer_vomit_delay` 被硬编码清零，控制持续伤害 `3×`，绕开 `*_pz_claw_dmg` 与 `vs_tank_damage` |
| `not0721_coop_wtf` | `coop` | `"Easy"` | **`0 (Easy)`** | `false` | 真正进入简单分支：拉舌/喷吐前摇 `2×`，倒地受击 `0.1×`，Tank 血量 `0.75×` 且石头半径 `0.75×` |
| `purecoop`、`purerealism`、`puremutation4`、`coop`、`realism`、`mutation4` | `coop` / `realism` / `mutation4` | 未锁死（跟随大厅/投票 `z_difficulty`） | `0 ~ 3` 动态可调 | `false` | 随 `z_difficulty` 实时切换下文全部战役分支 |

---

## 3. 全库按难度后缀拆分的引擎 ConVar 全集

穷尽扫描 `server_srv.so` 全部 1883 次 `ConVar::ConVar` 注册与 `.rodata` 字符串表，带难度后缀的引擎 ConVar 仅有以下 **10 组**（外加 3 个难度控制项与 1 个孤立遗留项 `z_hunter_ground_normal`）：

### 3.1 难度控制项

| ConVar | 默认值 | 标志 | 作用与读取位置 |
| --- | --- | --- | --- |
| `z_difficulty` | `"Normal"` | `0x82000` (`FCVAR_REPLICATED \| FCVAR_DONTRECORD`) | 当前战役难度（`Easy`、`Normal`、`Hard`、`Impossible`），回调 `DifficultyChanged` (`0x0050f080`) |
| `sv_vote_issue_change_difficulty_allowed` | `"1"` | `0x0` | 是否允许发起切难度投票，读取于 `CChangeDifficultyIssue::CanCallVote` (`0x009f5550`) |
| `z_use_next_difficulty_damage_factor` | `"0"` | `0x0` | 开启后普通感染者非爆头躯干衰减按高一档难度计算，读取于 `Infected::TraceAttack` (`0x009ff0b0`) |

### 3.2 按难度后缀拆分的 10 组 ConVar

| 功能分类 | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 对抗专用变体 / 备注 |
| --- | --- | --- | --- | --- | --- |
| **Tank 燃烧致死秒数**<br>`CTerrorPlayer::OnTakeDamage` (`0x009c8260`) | `tank_burn_duration` = **`75`** | `tank_burn_duration` = **`75`** | `tank_burn_duration_hard` = **`80`** | `tank_burn_duration_expert` = **`85`** | 对抗与生还者模式固定走 `tank_burn_duration` (`75`) |
| **求生 Bot 察觉队友被扑/被拉反应延迟（秒）**<br>`SurvivorBot::SaveFriendsInImmediateTrouble` (`0x0092df10`) | `sb_friend_immobilized_reaction_time_normal` = **`2.0`** | `sb_friend_immobilized_reaction_time_normal` = **`2.0`** | `sb_friend_immobilized_reaction_time_hard` = **`1.0`** | `sb_friend_immobilized_reaction_time_expert` = **`0.5`** | 对抗模式优先读取 `sb_friend_immobilized_reaction_time_vs` = **`0.5`** |
| **倒地生还者受感染者攻击伤害乘数**<br>`CTerrorPlayer::OnTakeDamage_Alive` (`0x009c6570`) | `z_hit_incap_factor_easy` = **`0.1`** | `z_hit_incap_factor_normal` = **`1.0`** | `z_hit_incap_factor_hard` = **`1.0`** | `z_hit_incap_factor_expert` = **`1.0`** | 同时作用于小尸、特感爪击与战役 Tank 捶倒地生还者 |
| **导演尸潮最小刷新间隔（秒）**<br>`CDirector::GetMobSpawnMinInterval` (`0x00869110`) | `z_mob_spawn_min_interval_easy` = **`120`** | `z_mob_spawn_min_interval_normal` = **`90`** | `z_mob_spawn_min_interval_hard` = **`90`** | `z_mob_spawn_min_interval_expert` = **`90`** | 可被 VScript `MobSpawnMinTime` 覆盖 |
| **导演尸潮最大刷新间隔（秒）**<br>`CDirector::GetMobSpawnMaxInterval` (`0x008691b0`) | `z_mob_spawn_max_interval_easy` = **`240`** | `z_mob_spawn_max_interval_normal` = **`180`** | `z_mob_spawn_max_interval_hard` = **`180`** | `z_mob_spawn_max_interval_expert` = **`180`** | 可被 VScript `MobSpawnMaxTime` 覆盖 |
| **导演 RELAX 阶段允许刷游荡小尸的压力阈值**<br>`CDirector::GetIntensityRelaxAllowWanderersThreshold` (`0x00868cf0`) | `director_intensity_relax_allow_wanderers_threshold` = **`0.3`** | 同左 = **`0.3`** | `..._hard` = **`0.5`** | `..._expert` = **`0.8`** | 可被 VScript 覆盖 |
| **小尸非爆头躯干伤害乘数**<br>`Infected::TraceAttack` (`0x009ff0b0`) | `z_non_head_damage_factor_easy` = **`2.0`** | `..._normal` = **`1.0`** | `..._hard` = **`0.75`** | `..._expert` = **`0.5`** | **仅作用于普通感染者 `Infected`**，特感 `CTerrorPlayer` 不走该函数；对抗或写实模式另有分支覆盖 |
| **小尸围殴受击最小间隔（秒）**<br>`CTerrorPlayer::CheckAttackFrequency` (`0x009aae80`) | `z_throttle_hit_interval_easy` = **`0.5`** | `..._normal` = **`0.33`** | `..._hard` = **`0.5`** | `..._expert` = **`1.0`** | 控制同一窗口内多名普通感染者命中生还者的节流间隔 |
| **生还者枪械友伤系数**<br>`CTerrorPlayer::GetFriendlyFireScale` (`0x00992e90`) | `survivor_friendly_fire_factor_easy` = **`0`** | `..._normal` = **`0.1`** | `..._hard` = **`0.3`** | `..._expert` = **`0.5`** | 榴弹另有 `grenadelauncher_ff_scale` (`0.12`) |
| **生还者火焰友伤系数**<br>`CTerrorPlayer::GetFriendlyFireScale` (`0x00992e90`) | `survivor_burn_factor_easy` = **`0.2`** | `..._normal` = **`0.2`** | `..._hard` = **`0.4`** | `..._expert` = **`1.0`** | 控制燃烧瓶/油桶火焰对生还者每跳伤害倍率 |

> 注：二进制中还存在一个孤立参数 `z_hunter_ground_normal`（默认 `"0.2"`，标志 `0x6000`），用于地面法线判定，不存在 `_easy` / `_hard` / `_expert` 变体，也未参与 `GetDifficulty()` 分支。

---

## 4. 六大特感四档战役难度行为与 ConVar 明细

以下表格列出六大特感在 `server_srv.so` 中所有随 `GetDifficulty()` 变化的属性；凡未在下表出现的特感 ConVar（见第 7 节）在四档战役难度下均无引擎级差异。

### 4.1 Smoker

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **AI 瞄准拉舌蓄力前摇** | `smoker_tongue_delay` (`1.5`) | `2.0 × ConVar`<br>（默认 `3.0s`） | `1.0 × ConVar`<br>（默认 `1.5s`） | **硬编码 `0.0s`**<br>（**不读 ConVar**） | **硬编码 `0.0s`**<br>（**不读 ConVar**） | `SmokerTongueVictim::OnStart` (`0x00aba760`)：`eax == 0` 时 `addss xmm0, xmm0`；`eax == 1` 原值读取；`eax == 2/3` 直接 `xorps xmm0, xmm0` 置零计时器。因此在 `coop / realism / mutation4` 的 `Hard` 或 `Impossible` 下，修改 `smoker_tongue_delay` 完全无效 |
| **舌头拖拽阶段伤害** | `tongue_drag_damage_amount` (`3`)<br>`tongue_choke_damage_interval` (`1.0`) | **`0`**（跳过拖拽伤害） | **`0`**（跳过拖拽伤害） | **`0`**（跳过拖拽伤害） | **`0`**（跳过拖拽伤害） | `CTerrorPlayer::UpdateHangingFromTongue` (`0x009ec350`)：拖拽分支先检查 `HasPlayerControlledZombies()`，战役模式下返回 `false` 直接跳过拖拽扣血；对抗模式下才按 `tongue_drag_damage_amount` 扣血 |
| **舌头绞杀阶段单次伤害** | `tongue_choke_damage_amount` (`10`)<br>`tongue_choke_damage_interval` (`1.0`) | `1.0×`<br>（默认 **`10`**） | `1.0×`<br>（默认 **`10`**） | `2.0×`<br>（默认 **`20`**） | `3.0×`<br>（默认 **`30`**） | `CTerrorPlayer::UpdateHangingFromTongue` (`0x009ec67e`)：无论战役或对抗均经过 `GetDifficulty()` 倍率缩放（对抗因锁在 `Normal` 故恒为 `1.0×`） |
| **副攻击爪击伤害（站立目标）** | 战役绕开 `smoker_pz_claw_dmg` (`4`) | **`1`** | **`2`** | **`5`** | **`20`** | 战役模式走 `CDirector::GetZombieAttackDamage` (`0x00864880`)：基础值 `1.0`（可由挑战模式 `GetBaseCommonAttackDamage` 改写）乘 `1× / 2× / 5× / 20×`；仅 `HasPlayerControlledZombies() == true` 时读取 `smoker_pz_claw_dmg` |
| **副攻击爪击伤害（倒地目标）** | `z_attack_incapacitated_damage` (`10`) × `z_hit_incap_factor_*` | **`1.0`** (`10 × 0.1`) | **`10.0`** (`10 × 1.0`) | **`10.0`** (`10 × 1.0`) | **`10.0`** (`10 × 1.0`) | `GetZombieAttackDamage` 对倒地生还者返回 `z_attack_incapacitated_damage` (`10`)，随后在 `OnTakeDamage_Alive` 乘 `z_hit_incap_factor_*` |

### 4.2 Boomer

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **AI 喷吐起手前摇** | `boomer_vomit_delay` (`1`) | `2.0 × ConVar`<br>（默认 `2.0s`） | `1.0 × ConVar`<br>（默认 `1.0s`） | **硬编码 `0.2s`**<br>（**不读 ConVar**） | **硬编码 `0.0s`**<br>（**不读 ConVar**） | `BoomerVomitOnVictim::OnStart` (`0x00a658e0`)：`Hard` 直接加常量 `0.2f` (`0x3e4ccccd`)，`Impossible` 直接 `xorps xmm0, xmm0` 为 `0.0s`，均不读取 `boomer_vomit_delay` |
| **AI 卡死/无路自爆倒计时** | 无 ConVar（硬编码） | **`4.0s`** | **`2.0s`** | **`1.0s`** | **`1.0s`** | `BoomerSelfDestruct::OnStart` (`0x00a650b0`) |
| **AI 喷吐后撤退判定** | 无 ConVar（硬编码） | 满足条件时撤退 | 满足条件时撤退 | 不走该撤退分支 | 不走该撤退分支 | `Boomer::ShouldBackOff` (`0x00a54620`)：非救援关且导演处于特定节奏阶段时，仅 `GetDifficulty() <= 1` 检查 `!IsAnySurvivorBypassingTank()` 触发后撤；`Hard / Impossible` 直接返回不撤退 |
| **副攻击爪击伤害（站立目标）** | 战役绕开 `boomer_pz_claw_dmg` (`4`) | **`1`** | **`2`** | **`5`** | **`20`** | 同 `CDirector::GetZombieAttackDamage` (`0x00864880`) |

### 4.3 Hunter

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **AI 飞扑蓄力前摇** | 无 ConVar（硬编码） | **`0.20 ~ 0.66s` 随机** | **`0.10 ~ 0.33s` 随机** | **固定 `0.10s`** | **固定 `0.10s`** | `HunterLungeAtVictim::OnStart` (`0x00a90690`)：Easy 调 `RandomFloat(0.2f, 0.66f)`，Normal 调 `RandomFloat(0.1f, 0.33f)`，Hard / Impossible 固定 `0.1f` (`0xbea0f4`) |
| **扑倒撕咬单次伤害** | `z_pounce_damage` (`5`)<br>`z_pounce_damage_interval` (`0.5`) | `1.0×`<br>（默认 **`5`**，DPS `10`） | `1.0×`<br>（默认 **`5`**，DPS `10`） | `2.0×`<br>（默认 **`10`**，DPS `20`） | `3.0×`<br>（默认 **`15`**，DPS `30`） | `CTerrorPlayer::UpdatePounce` (`0x009e8c40`) |
| **副攻击爪击伤害** | 战役绕开 `hunter_pz_claw_dmg` (`6`) | **`10`** | **`10`** | **`20`** | **`40`** | `CDirector::GetHunterAttackDamage` (`0x00864850`)：战役模式不走通用小尸爪击，而是独立查表 `0x00cd0d94` `(10.0, 10.0, 20.0, 40.0)`；对抗模式才读 `hunter_pz_claw_dmg` |

### 4.4 Jockey

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **AI 飞跃蓄力前摇** | 无 ConVar（硬编码） | **`0.20 ~ 0.66s` 随机** | **`0.10 ~ 0.33s` 随机** | **固定 `0.10s`** | **固定 `0.10s`** | `JockeyLeap::OnStart` (`0x00aa53c0`)：与 Hunter 蓄力分布完全一致 |
| **骑乘持续单次伤害** | `z_jockey_ride_damage` (`4`)<br>`z_jockey_ride_damage_interval` (`1.0`) | `1.0×`<br>（默认 **`4`**） | `1.0×`<br>（默认 **`4`**） | `2.0×`<br>（默认 **`8`**） | `3.0×`<br>（默认 **`12`**） | `CTerrorPlayer::UpdateLeap` (`0x009e9e4d`) |
| **副攻击爪击伤害（站立目标）** | 战役绕开 `jockey_pz_claw_dmg` (`4`) | **`1`** | **`2`** | **`5`** | **`20`** | 同 `CDirector::GetZombieAttackDamage` (`0x00864880`) |

### 4.5 Charger

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **AI 冲锋起手前摇** | 无 ConVar（硬编码） | **`0.20 ~ 0.66s` 随机** | **`0.10 ~ 0.33s` 随机** | **固定 `0.10s`** | **固定 `0.10s`** | `ChargerChargeAtVictim::OnStart` (`0x00a7c3a0`) |
| **冲锋撞飞旁人最大伤害** | `z_charge_max_damage` (`10`) | `0.5×`<br>（默认 **`5`**） | `1.0×`<br>（默认 **`10`**） | `1.5×`<br>（默认 **`15`**） | `2.0×`<br>（默认 **`20`**） | `ThrowImpactedSurvivor` (`0x004c3410`)：按冲锋距离比例结算后再乘难度系数 |
| **携人撞墙停下瞬间冲击伤害** | 无 ConVar（硬编码） | **`10`** | **`10`** | **`15`** | **`20`** | `CTerrorPlayer::OnSlammedSurvivor` (`0x009a0e50`)：完整冲锋撞墙硬编码 `10 / 10 / 15 / 20` |
| **抓人锤地每次动画伤害** | `z_charger_pound_dmg` (`15`) | `1.0×`<br>（默认 **`15`**） | `1.0×`<br>（默认 **`15`**） | `1.0×`<br>（默认 **`15`**） | `1.0×`<br>（默认 **`15`**） | `CTerrorPlayer::HandleAnimEvent` (`0x009cdd37`)：函数内调用了 `GetDifficulty()`，但返回值未参与任何分支计算直接被覆盖，四档恒为 `1.0 × z_charger_pound_dmg` |
| **普攻拳击（Claw）伤害** | 战役绕开 `charger_pz_claw_dmg` (`10`) | **`5`** | **`10`** | **`15`** | **`20`** | `CChargerClaw::GetPlayerDamage` (`0x00524760`)：`!HasPlayerControlledZombies()` 时硬编码 `5 / 10 / 15 / 20`（攻击 Witch 特判 `100`）；对抗模式才读 `charger_pz_claw_dmg` |

### 4.6 Spitter

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **酸液池每秒伤害（DPS）** | 无难度 ConVar（内置时间曲线） | **基础项 `0.5×`** | **`1.0×`** | **`1.0×`** | **`1.0×`** | `CInsectSwarm::GetDamagePerSecond` (`0x008b6820`)：酸液池按存在秒数查表 `(0, 5, 10, 20, 30, 30, 20, 7)` 线性插值；`!HasPlayerControlledZombies()` 且 `GetDifficulty() == 0` 时将当前秒基准值乘 `0.5`，其余三档战役难度与对抗一致（Anne 系药役另由 `l4d2_spit_dmg` 等插件接管） |
| **副攻击爪击伤害（站立目标）** | 战役绕开 `spitter_pz_claw_dmg` (`4`) | **`1`** | **`2`** | **`5`** | **`20`** | 同 `CDirector::GetZombieAttackDamage` (`0x00864880`) |

---

## 5. Tank 与 Witch 四档战役难度行为与 ConVar 明细

### 5.1 Tank

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **生成最大生命值** | `z_tank_health` (`4000`) | `0.75×`<br>（默认 **`3000`**） | `1.0×`<br>（默认 **`4000`**） | `2.0×`<br>（默认 **`8000`**） | `2.0×`<br>（默认 **`8000`**） | `CDirector::GetTankHealth` (`0x00869070`)：先按战役难度置倍率 `0.75 / 1.0 / 2.0 / 2.0`；随后若 `HasPlayerControlledZombies() == true`（对抗模式），强制把倍率覆写为 **`1.5×`**（即默认 `6000`）；最终再经 VScript `TankHealth` 覆盖 |
| **拳击与投石命中站立生还者伤害** | 战役绕开 `vs_tank_damage` (`24`) | **`24`** | **`24`** | **`33`** | **`100`** | `CTankClaw::GetPlayerDamage` (`0x0054d2f0`) 查表 `0x00c3fbd8` `(24, 24, 33, 100)`；`CDirector::GetTankDamage` (`0x00868e60`) 在战役下同样返回 `24 / 24 / 33 / 100`（可受 VScript 缩放），仅 `HasPlayerControlledZombies() == true` 时读取 `vs_tank_damage` |
| **拳击与投石命中倒地生还者伤害** | 基础硬编码 × `z_hit_incap_factor_*` | 基础 `75` × `0.1` = **`7.5`** | **`75`** (`75 × 1.0`) | **`75`** (`75 × 1.0`) | **`150`** (`150 × 1.0`) | `CDirector::GetTankDamage` (`0x00868ffd`) 对倒地生还者返回基础值 `75 / 75 / 75 / 150`，进入 `OnTakeDamage_Alive` 后再乘 `z_hit_incap_factor_*`（对特感友军恒为 `250`，对 Witch 恒为秒杀级伤害） |
| **点火后自然烧死时长** | `tank_burn_duration*` | **`75s`** (`tank_burn_duration`) | **`75s`** (`tank_burn_duration`) | **`80s`** (`tank_burn_duration_hard`) | **`85s`** (`tank_burn_duration_expert`) | `CTerrorPlayer::OnTakeDamage` (`0x009c8260`) |
| **投石碰撞判定半径** | `z_tank_rock_radius` (`100`) | `0.75×`<br>（默认 **`75`**） | `1.0×`<br>（默认 **`100`**） | `1.0×`<br>（默认 **`100`**） | `1.0×`<br>（默认 **`100`**） | `ForEachPlayer<ProximityCheck>` (`0x004d2118`) |
| **AI 投石随机瞄准偏转** | `tank_throw_aim_error` (`100`) | **启用偏转**（乘 `0.5 × ConVar`） | **无偏转（`0`）** | **无偏转（`0`）** | **无偏转（`0`）** | `TankAttack::UpdateThrowAimError` (`0x00ad1570`)：仅 `GetDifficulty() == 0` 计算随机角度误差，其余难度误差清零 |
| **AI 投石目标移速提前量预判** | `tank_throw_lead_time_factor` (`0.5`) | **关闭提前量预判** | **启用提前量预判** | **启用提前量预判** | **启用提前量预判** | `TankAttack::TryToThrowRock` (`0x00ad15d0`)：Easy 直接瞄准目标当前坐标，Normal 及以上叠加目标速度提前量 |
| **救援关单轮 Tank 上限** | 无独立难度 ConVar | **固定返回 `1`** | 走导演救援配置 | 走导演救援配置 | 走导演救援配置 | `CDirector::GetFinaleTankLimit` (`0x00864260`)：`GetDifficulty() == 0` 直接返回 `1`，否则转交 `CDirectorVersusMode::GetFinaleTankLimit()` |

### 5.2 Witch

| 行为项 | 关联 ConVar（引擎默认值） | Easy (`0`) | Normal (`1`) | Hard (`2`) | Impossible (`3`) | 逆向函数与说明 |
| --- | --- | --- | --- | --- | --- | --- |
| **受惊怒气增长速率** | `z_witch_anger_rate` (`0.2`) | **`0.5×`** | **`1.0×`** | **`1.0×`** | **`1.0×`** | `WitchAngry::Update` (`0x00a2bd60`)：Easy 将每帧怒气增量折半 |
| **抓击站立生还者是否直接秒杀** | `z_witch_damage` (`100`)<br>`z_witch_always_kills` (`0`) | **只抓倒、不秒杀**（即使设 `z_witch_always_kills 1` 也**不秒杀**） | 默认抓倒；设 `z_witch_always_kills 1` 则秒杀 | 默认抓倒；设 `z_witch_always_kills 1` 则秒杀 | **直接秒杀**（无需 `z_witch_always_kills`） | `WitchSlashEnumerator::EnumElement` (`0x00a39b36`) 仅在 `GetDifficulty() != 0` 时给伤害打上 `0x8000` 标记；`CTerrorPlayer::AllowDamage` (`0x009a6de7` / `0x009a6ffa`) 在 `Impossible` 或（`z_witch_always_kills != 0` 且 `GetDifficulty() != 0`）时跳过倒地直接致死 |
| **处决倒地生还者每抓伤害** | `z_witch_damage_per_kill_hit` (`30`)<br>`survivor_incap_health` (`300`) | `0.5×`<br>（默认 **`15`**） | `1.0×`<br>（默认 **`30`**） | `2.0×`<br>（默认 **`60`**） | **读取 `survivor_incap_health`**（默认 **`300`**，一抓必死） | `WitchKillIncapVictim::OnAnimationEvent` (`0x00a30b40`) |

---

## 6. 导演系统特感同屏上限（`CDirector::GetMaxPlayerZombies`）

未加载自定义刷特插件（如原版 `purecoop` / `purerealism`）时，引擎通过 `CDirector::GetMaxPlayerZombies()`（`0x0086a770`）决定特感槽位上限：

1. 若处于 Challenge（突变脚本）或 Survival 模式且模式重写了上限，优先采用模式值；
2. 若 `HasPlayerControlledZombies() == true`（如对抗模式），直接返回 `z_max_player_zombies`（默认 `4`）；
3. 否则（原版战役/写实），按 `[GetDifficulty()][clamp(GetMapArcValue(), 0, 4)]` 查只读表 `0x00cd0ee0`，再将该值作为默认值传给 `CDirector::GetScriptValue("MaxSpecials", default)`：

| 战役难度 | MapArc `0` | MapArc `1` | MapArc `2` | MapArc `3` | MapArc `4` |
| --- | --- | --- | --- | --- | --- |
| **Easy (`0`)** | `1` | `1` | `1` | `2` | `2` |
| **Normal (`1`)** | `1` | `2` | `2` | `3` | `3` |
| **Hard (`2`)** | `1` | `2` | `3` | `3` | `3` |
| **Impossible (`3`)** | `3` | `3` | `3` | `3` | `3` |

---

## 7. 常见误区：完全不受战役难度影响的特感属性

调参或排查问题时，以下属性在 `server_srv.so` 中**没有任何 `GetDifficulty()` 分支**，四档战役难度完全一致：

- **六大特感基础生命值**：`z_gas_health` (`250`)、`z_exploding_health` (`50`)、`z_hunter_health` (`250`)、`z_jockey_health` (`325`)、`z_charger_health` (`600`)、`z_spitter_health` (`100`) 以及 `z_witch_health` (`1000`)。
- **六大特感与 Tank / Witch 移动速度**：`z_gas_speed`、`z_exploding_speed`、`z_hunter_speed`、`z_jockey_speed`、`z_charge_max_speed`、`z_spitter_speed`、`z_tank_speed` (`210`)、`z_tank_speed_vs` (`210`)、`z_witch_speed` (`300`)。
- **特感技能射程、飞行速度与冷却时间**：`tongue_range` (`750`)、`tongue_fly_speed` (`1000`)、`tongue_miss_delay` (`15`)、`tongue_hit_delay` (`20`)、`tongue_los_forgiveness_time` (`1.0`)、`tongue_no_progress_choke_early_delay` (`1.5`)、`z_vomit_range` (`300`)、`z_vomit_interval` (`30`)、`z_lunge_power` (`600`)、`z_jockey_leap_range` (`200`)、`z_charge_duration` (`2.5`)、`z_charge_interval` (`12`)、`z_spit_range` (`900`)、`z_spit_interval` (`20`)、`z_special_spawn_interval` (`45`)、`versus_special_respawn_interval` (`20`)。
- **特感受击部位倍率**：`z_non_head_damage_factor_{easy,normal,hard,expert}` 仅在普通感染者 `Infected::TraceAttack`（`0x009ff0b0`）中生效；特感与 Tank 继承自 `CTerrorPlayer`，不经过该函数，因此专家难度下打特感躯干不会像打普通小尸那样减半伤害。

---

## 8. 附录：`server_srv.so` 全部调用 `GetDifficulty()` 的 51 个函数索引

全二进制共有 66 条 `call GetDifficulty` 指令，分布在以下 51 个函数中，供后续逆向或 SourceMod DHooks / 内存补丁定位时直接按符号和地址核查：

| 序号 | 函数起始地址 | C++ 符号名 | 难度作用简述 |
| --- | --- | --- | --- |
| 1 | `0x004c3410` | `ThrowImpactedSurvivor(CTerrorPlayer*, CTerrorPlayer*, float, bool)` | Charger 撞飞旁人伤害 `z_charge_max_damage` 乘 `0.5 / 1.0 / 1.5 / 2.0` |
| 2 | `0x004d1e00` | `bool ForEachPlayer<ProximityCheck>(ProximityCheck&)` | Tank 石头碰撞半径 `z_tank_rock_radius` 在 Easy 乘 `0.75` |
| 3 | `0x00524760` | `CChargerClaw::GetPlayerDamage(CTerrorPlayer*) const` | 战役 Charger 普攻伤害 `5 / 10 / 15 / 20` |
| 4 | `0x0054d2f0` | `CTankClaw::GetPlayerDamage(CTerrorPlayer*) const` | Tank 拳击基础表 `24 / 24 / 33 / 100` |
| 5 | `0x00864260` | `CDirector::GetFinaleTankLimit()` | Easy 救援关单轮 Tank 上限锁为 `1` |
| 6 | `0x00864850` | `CDirector::GetHunterAttackDamage() const` | 战役 Hunter 爪击伤害 `10 / 10 / 20 / 40` |
| 7 | `0x00864880` | `CDirector::GetZombieAttackDamage(CTerrorPlayer*) const` | 小尸及 Smoker/Boomer/Jockey/Spitter 战役爪击伤害 `1 / 2 / 5 / 20` |
| 8 | `0x008673b0` | `CDirector::OnFinaleEscapeFinished()` | 战役通关成就与难度统计结算 |
| 9 | `0x00868cf0` | `CDirector::GetIntensityRelaxAllowWanderersThreshold()` | RELAX 游荡小尸阈值 `0.3 / 0.3 / 0.5 / 0.8` |
| 10 | `0x00868e60` | `CDirector::GetTankDamage(CBaseEntity*) const` | 战役 Tank 对站立（`24/24/33/100`）与倒地（`75/75/75/150`）伤害 |
| 11 | `0x00869070` | `CDirector::GetTankHealth() const` | 战役 Tank 血量倍率 `0.75 / 1.0 / 2.0 / 2.0`（对抗覆写 `1.5`） |
| 12 | `0x00869110` | `CDirector::GetMobSpawnMinInterval() const` | 尸潮最小间隔 `120 / 90 / 90 / 90` |
| 13 | `0x008691b0` | `CDirector::GetMobSpawnMaxInterval() const` | 尸潮最大间隔 `240 / 180 / 180 / 180` |
| 14 | `0x0086a770` | `CDirector::GetMaxPlayerZombies() const` | 战役特感上限按难度与 MapArc 查表 `1~3` |
| 15 | `0x008956b0` | `CDirectorItemManager::UpdateItems()` | 按难度参与医疗包转止痛药（`director_convert_pills`）物品刷新过滤 |
| 16 | `0x008b6820` | `CInsectSwarm::GetDamagePerSecond()` | 战役 Easy 下 Spitter 酸液池基准 DPS 乘 `0.5` |
| 17 | `0x008d0620` | `CL4DGameStats::AddMapStats()` | 地图统计记录当前难度 |
| 18 | `0x008d1560` | `CL4DGameStats::AddSurvivorStats(bool)` | 生还者通关统计记录当前难度 |
| 19 | `0x008fa400` | `SurvivorCheckpointLeaving::Update(SurvivorBot*, float)` | 求生 Bot 出安全屋前补血/吃药决策阈值随难度变化 |
| 20 | `0x0092df10` | `SurvivorBot::SaveFriendsInImmediateTrouble(Action<SurvivorBot>*)` | 求生 Bot 救被控队友反应时间 `2.0 / 2.0 / 1.0 / 0.5` |
| 21 | `0x0095a500` | `CSurvivorRescue::InputRescue(inputdata_t&)` | 复活柜救出生命值按难度调整（Easy 更高，其余走 `z_survivor_respawn_health`） |
| 22 | `0x00987e10` | `CTerrorPlayer::OnAttackSuccess(CBaseCombatCharacter*, bool)` | 命中事件统计与提示 |
| 23 | `0x00992e90` | `CTerrorPlayer::GetFriendlyFireScale(CTakeDamageInfo const&) const` | 枪械友伤 `0 / 0.1 / 0.3 / 0.5` 与火伤 `0.2 / 0.2 / 0.4 / 1.0` |
| 24 | `0x0099da20` | `CTerrorPlayer::FireChallengeModeExplanationEvents()` | 难度/写实教学提示事件触发 |
| 25 | `0x009a0e50` | `CTerrorPlayer::OnSlammedSurvivor(CTerrorPlayer*, bool, bool)` | Charger 抓人撞墙伤害 `10 / 10 / 15 / 20` |
| 26 | `0x009a1640` | `CTerrorPlayer::OnRevivedByDefibrillator(CTerrorPlayer*, CSurvivorDeathModel*)` | 电击器救起生命值按难度调整 |
| 27 | `0x009a5d30` | `CTerrorPlayer::OnFriendlyFire(CTerrorPlayer*, IGameEvent*)` | 友伤语音/警告触发阈值随难度调整 |
| 28 | `0x009a6d20` | `CTerrorPlayer::AllowDamage(CTakeDamageInfo const&)` | Witch 抓击在 Impossible（或非 Easy 且 `z_witch_always_kills`）直接秒杀 |
| 29 | `0x009aae80` | `CTerrorPlayer::CheckAttackFrequency(CTakeDamageInfo const&, bool)` | 小尸围殴节流 `z_throttle_hit_interval_*` |
| 30 | `0x009c6570` | `CTerrorPlayer::OnTakeDamage_Alive(CTakeDamageInfo const&)` | 倒地生还者受击乘 `z_hit_incap_factor_*` 等伤害修正 |
| 31 | `0x009c8260` | `CTerrorPlayer::OnTakeDamage(CTakeDamageInfo const&)` | Tank 烧死时长选择 `75 / 75 / 80 / 85` 秒 |
| 32 | `0x009cdc50` | `CTerrorPlayer::HandleAnimEvent(animevent_t*)` | Charger 锤地调了 `GetDifficulty()` 但返回值丢弃，恒为 `z_charger_pound_dmg` |
| 33 | `0x009cfa70` | `CTerrorPlayer::Event_Killed(CTakeDamageInfo const&)` | 击杀统计与成就难度判定 |
| 34 | `0x009e88d0` | `CTerrorPlayer::UpdatePounce()` | Hunter 扑倒伤害 `z_pounce_damage` 乘 `1 / 1 / 2 / 3` |
| 35 | `0x009e9ab0` | `CTerrorPlayer::UpdateLeap()` | Jockey 骑乘伤害 `z_jockey_ride_damage` 乘 `1 / 1 / 2 / 3` |
| 36 | `0x009ec350` | `CTerrorPlayer::UpdateHangingFromTongue()` | Smoker 绞杀伤害 `tongue_choke_damage_amount` 乘 `1 / 1 / 2 / 3` |
| 37 | `0x009f5550` | `CChangeDifficultyIssue::CanCallVote(int, char const*, char*)` | 检查目标难度是否与当前 `GetDifficulty()` 相同 |
| 38 | `0x009ff0b0` | `Infected::TraceAttack(CTakeDamageInfo const&, Vector const&, CGameTrace*)` | 小尸非爆头衰减 `z_non_head_damage_factor_*` |
| 39 | `0x00a054e0` | `Infected::Spawn()` | 普通小尸按难度调整奔跑/倾斜姿态参数 |
| 40 | `0x00a2bd60` | `WitchAngry::Update(Infected*, float)` | Witch 在 Easy 下怒气增长速率乘 `0.5` |
| 41 | `0x00a30b40` | `WitchKillIncapVictim::OnAnimationEvent(Infected*, animevent_t*)` | Witch 处决倒地每抓 `0.5× / 1× / 2× / survivor_incap_health` |
| 42 | `0x00a396f0` | `WitchSlashEnumerator::EnumElement(IHandleEntity*)` | 非 Easy 时为 Witch 抓击附加 `0x8000` 伤害位供秒杀判定 |
| 43 | `0x00a54620` | `Boomer::ShouldBackOff() const` | Easy / Normal 下允许满足条件的 AI Boomer 后撤 |
| 44 | `0x00a650b0` | `BoomerSelfDestruct::OnStart(Boomer*, Action<Boomer>*)` | AI Boomer 自爆前摇 `4s / 2s / 1s / 1s` |
| 45 | `0x00a658e0` | `BoomerVomitOnVictim::OnStart(Boomer*, Action<Boomer>*)` | AI Boomer 喷吐前摇 `2× / 1× / 0.2s / 0.0s` |
| 46 | `0x00a7c3a0` | `ChargerChargeAtVictim::OnStart(Charger*, Action<Charger>*)` | AI Charger 冲锋前摇 `0.2~0.66s / 0.1~0.33s / 0.1s / 0.1s` |
| 47 | `0x00a90690` | `HunterLungeAtVictim::OnStart(Hunter*, Action<Hunter>*)` | AI Hunter 飞扑前摇 `0.2~0.66s / 0.1~0.33s / 0.1s / 0.1s` |
| 48 | `0x00aa53c0` | `JockeyLeap::OnStart(Jockey*, Action<Jockey>*)` | AI Jockey 飞跃前摇 `0.2~0.66s / 0.1~0.33s / 0.1s / 0.1s` |
| 49 | `0x00aba760` | `SmokerTongueVictim::OnStart(Smoker*, Action<Smoker>*)` | AI Smoker 拉舌前摇 `2× / 1× / 0.0s / 0.0s` |
| 50 | `0x00ad1570` | `TankAttack::UpdateThrowAimError()` | AI Tank 仅在 Easy 计算投石随机瞄准偏转 |
| 51 | `0x00ad15d0` | `TankAttack::TryToThrowRock(Tank*)` | AI Tank 在 Easy 关闭目标速度提前量预判并放宽非救援投石限制 |

（另：`Script_GetDifficultyString()` @ `0x00b32e60` 调用 `Script_GetDifficulty()` @ `0x00b32e50` 供 VScript 读取当前难度字符串。）
