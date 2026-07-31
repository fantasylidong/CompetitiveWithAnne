# AnneHappy 自 8b9e26b 起的性能审计

日期：2026-07-31

基线：`8b9e26b35425da1c72642b697cb3871911deaca2`

审计范围：

- `cfg/server.cfg`、`cfg/generalfixes.cfg`、
  `cfg/cfgogl/annehappy/confogl_plugins.cfg`、
  `cfg/cfgogl/annehappy/shared_plugins.cfg` 和 `cfg/sharedplugins.cfg` 组成的
  AnneHappy 默认加载链。
- 基线提交之后的源码与二进制变化，包括
  `/Users/morzlee/Documents/GitHub/Myl4d2privateplugins` 私有插件。
- 当前未提交的性能优化工作树视为“当前状态”。

这是一份静态排序，不是实测 CPU 百分比。排序综合了回调频率、单次工作量、
八特下的扩张程度、主线程阻塞和尖峰放大。统一估算场景为 100 tick、4 名生还者、
8 名特感。要声称精确收益，仍需运行服 profiler 数据。

## 加载集合结论

解析后的 AnneHappy 插件集合约从 230 个增至 247 个，净增 17 个，但这个数字不能
直接等同于性能增加：

- `servercleanup`、`l4d_tongue_block_fix`、`l4d2_melee_spawn_control`、
  `l4d2_npc_manager`、`l4d2_blackscreen_fix` 包含路径迁移或替换。
- `survivor_mvp` 去掉了重复加载；`chat-processor`、旧 `hextags`、`basevotes`
  和服务器更新检查器被删除或替换。
- `l4d_fix_prop_los` 会被 general fixes 加载，但随后又被 AnneHappy 卸载。
- `archive/`、`disabled/` 和投票配置中条件加载的文件不计为默认常驻成本。

## 原始新增损耗 Top 20

| 排名 | 插件或子系统 | 上榜原因 | 当前工作树状态 |
|---:|---|---|---|
| 1 | `infected_control` | 刷特选择由 `OnGameFrame` 驱动，包含 Nav、可见性、路径和 Trace；八特出生还会放大 assault、debug Timer 与内鬼额度查询。 | 已改为跨帧续扫：单帧最多检查 48 个 Nav、执行 6 次昂贵精判并受 0.8ms 软预算限制，游标和最佳结果会保留到候选源真正完成；三级距离带也分帧推进。另已合并 assault burst、按需 Hook/Timer、内鬼额度快照与原子扣减。 |
| 2 | 私有 `l4d2_pwa_native_attrs` | 最初常驻 11 个全局武器 Detour，并无条件挂伤害 Hook；属性生效时每枪还会执行 WeaponInfo 应用、回读和恢复。 | 空闲 Detour 已从 `11 -> 0`；无伤害属性时，对玩家、普通感染者和 Witch 的伤害 Hook 也降为 0；日志关闭时不再格式化正常射击事务日志。当前管理员枪械规则需要 3 个 Detour。 |
| 3 | `ai_charger3` | Charger 状态逻辑由 UserCmd 驱动；PathFollower 原本与 Tank 重复映射，同一次更新最多复制 512 个路径段。 | Charger/Tank 已共用一个 PathFollower broker；默认快照上限从 `512 -> 21`。LOS 结果按玩家槽/userid 缓存 40ms，更优冲锋目标扫描限制到 12.5Hz；非近战目标不再扫描 watcher，远距离候选和 Charging 软退出均先于重型 Trace。 |
| 4 | `l4d2_ai_ladder_boost` | 所有 AI 特感永久持有 PostThink/动画 Hook；100 tick 下八特约 800 次 PostThink/秒。 | 全局 UserCmd 已移除。非 Tank 特感由 10 Hz 扫描发现上梯后才挂 PostThink，离梯立即排队卸载；Tank 保留常驻 PostThink/动画 Hook。视野检查已有快筛与预算。 |
| 5 | `l4d2_incap_fire_fix` | 全局 `OnPlayerRunCmd` 让所有客户端每 tick 进入 SourcePawn；12 客户端约 1200 回调/秒。 | 全局 UserCmd 已移除。仅当前倒地的生还者挂 `SDKHook_PreThink`，扶起、死亡、换队及生命周期边界会卸载。 |
| 6 | `l4d2_door_lock` | 又增加一个全局 UserCmd，约 1200 回调/秒；Ready 模式还会给每个面板建立 0.1 秒递归 Timer。 | UserCmd 已移除。锁门阶段只用一个 0.25 秒共享 Bot 冻结 Timer；Ready 面板复用现有 0.5 秒共享检查器刷新。 |
| 7 | `l4d_stats` | 完整统计开启时，每只计分 SI 死亡新增 5 个 SQL 任务：模式得分/击杀、季度得分/击杀、积分流水。 | 同表得分和击杀已合并，单只总任务 `6 -> 4`。积分流水再按 0.25 秒或 16 行合并为 multi-row INSERT；八特同波总任务约 `48 -> 25`。公共感染者批量结算复用同一路径。 |
| 8 | `ai_tank3` | Tank 与 Charger 各自挂全局 PathFollower Detour，并各做一次相同的 NextBot 映射；Tank 还运行 Tank 专属 UserCmd 行为。 | PathFollower 已由 `ai_tank3_pathfollower` 统一持有，只剩一个全局 Detour 和一次映射 SDKCall。Tank 专属逻辑保留。 |
| 9 | 私有 `l4d2_pma_native_attrs` | 新增一个全局近战挥舞 Detour、Left4DHooks 挥舞/伤害 forward 和嵌套 WeaponInfo overlay。 | 只保留 `DoMeleeSwing` detour 这一套挥砍 overlay，删除重复的 `StartMeleeSwing` forward；空闲时 detour 为 0，伤害 forward 保留 O(1) 无 profile 快筛。当前管理员近战规则需要 1 个 detour。 |
| 10 | 私有 `l4d2_player_attr_db` | WeaponSwitch pre 和 post 都会重建 profile，并各自扫描全部规则；当前数据库有 56 行。 | 玩家认证完成时一次性缓存身份、管理员状态和全部匹配规则，并按模式/武器建桶。正常切枪不查数据库、不解析模式、不扫描 56 行，只合并最多四个命中桶；post 继续复用 pre 的命中行。 |
| 11 | `l4d2_block_autoaim` | 全局 `CBasePlayer::ShouldAutoaim` Detour，每次引擎调用都会跨入 SourcePawn。 | 回调已是最小的直接返回；它按射击动作而非逐帧触发，八特不会直接放大。四名全自动武器玩家粗估约 64 次/秒，仍需 DHooks profiler 核实；缺少 Linux/Windows 入口字节校验前不改 MemoryPatch。 |
| 12 | `l4d2_damage_show` | 原有逐帧扫描仍在；数据库使用同步 `SQL_Connect`，远端数据库慢或故障时可能形成连接尖峰。 | 按要求保留原有同步连接和同步探测流程。`OnGameFrame` 已由活跃伤害对列表和一个 10 Hz 共享 Timer 取代；无人启用显示时伤害 Hook 为 0。 |
| 13 | `l4d2_hitsound` | 命中回调频繁；偏好设置使用原有同步数据库连接。 | 按要求保留原有同步连接流程。逐命中 Precache 已归零；每次命中销毁/创建客户端 Timer 改为按需单个 10 Hz 共享 Timer；相同图标续期只更新 deadline，不再重复下发 overlay 命令。 |
| 14 | `annehappy_dynamic_ai_difficulty` | 常态频率不高，但同步数据库连接和配置解析可能造成配置阶段尖峰。 | 按要求完整恢复原有同步连接流程；它不属于战斗热路径，后续只通过运行服数据判断是否需要处理配置阶段尖峰。 |
| 15 | `l4d2_nav_variant` | 在确认文件是否为 Nav 之前就拦截所有文件系统 `ReadFile`。 | Raw Hook 仍需覆盖 Nav 加载时机，但每次文件读取只先做缓存布尔和 `.nav` 后缀快筛；非 Nav 文件不再读取 pathID、规范化路径、解析当前配置或查 KeyValues。主要成本仍只在换图。 |
| 16 | `anne_cvar_shield` | 一个受保护 CVar 变化会立即检查，并创建 0.2、1、3 秒三个校验 Timer；模式切换会连续改多个 CVar。 | 已改为单句柄、可续期的 0.2/1/3 秒状态机；拒绝恢复额外保留 0.05 秒阶段。连续触发任意时刻最多只有一个待执行 Timer。 |
| 17 | `global_chat` | 每 5 秒异步 SQL 轮询，另有 blacklist 刷新和逐消息客户端/缓存扫描。 | 有真人时仍保持 5 秒实时轮询；空服默认改为 30 秒，首个真人进服后恢复。单台空服查询从每小时约 `720 -> 120`。Blacklist 在无人时原本就不发查询。 |
| 18 | `l4d_player_count_unload_mode` | 每 180 秒数据库心跳；多人同时换队会创建未合并的 1 秒 Timer。 | 换队事件已合并为一个可重置的 1 秒 debounce Timer；一批 N 个换队事件只执行最后一次状态扫描。 |
| 19 | `new_player_guide` | 每次 `player_spawn` 都先创建 0.2 秒 Timer，包括每只 SI 出生，之后才排除非生还者。 | 出生事件现在先确认是生还者才创建 Timer；八特一波的无效 SI 出生 Timer 从 `8 -> 0`。 |
| 20 | `spawn_vote_menu` | 插件或配置启动阶段存在同步数据库工作。 | 按要求保留原有数据库连接和预设管理流程；主要影响启动与低频管理命令，正常战斗近似为零。 |

## 已完成优化的量化结果

- Infected assault burst：八特一波原先产生 24 次全局 assault 和 16 个 assault
  Timer。密集出生现在共用一个 burst 状态和一个 Timer，通常约为 3 至 4 次
  assault 启动。
- 刷点完整度：恢复 48 个受检 Nav 的单帧上限，并新增每帧 6 次昂贵精判与 0.8ms
  软时间预算，但不再用时间片次数截断搜索。桶模式保存 `bucket order -> row` 游标，
  全图模式保存 area 游标；后续帧会继续扫描到候选源耗尽或命中 9 至 12 个质量预算。
- 刷点 Trace：可见性 Ray、卡位 Hull 和落点评分由每条 Trace 创建/销毁 Handle，改为
  同步全局 Trace 结果；mask、filter 和判断顺序不变。生还者眼位快照也从尝试前
  无条件采集改为通过职业/冷却门槛并真正进入找点时按 tick 采集。
- 刷点范围：每只 SI 仍按三级职业范围从主区间逐步放宽，但每一级和各级之间均
  跨帧推进。三级完整失败后才调用受职业距离/视线/卡位约束的导演兜底；连续两轮
  完整流程失败后保留原 unrestricted 兜底，避免极端地图卡住队列。
- 梯子加速：移除全局 UserCmd，并移除非 Tank 特感的永久 PostThink。按 12 个活动
  客户端、100 tick、八特无人爬梯估算，分别减少约 1200 和 800 次回调/秒；空闲期
  只保留 10 Hz 梯子状态扫描，Tank 维持原有常驻路径。
- 倒地开火：移除约 1200 次/秒的全局 UserCmd，只在当前倒地生还者身上逐帧工作。
- 门锁：再移除约 1200 次/秒的全局 UserCmd。安全区锁门期改为一个 4 Hz Timer
  扫描，而不是每条客户端命令检查。
- PathFollower：两个全局 Detour 和两次实体映射缩为一个 broker Detour 和一次映射；
  Charger 默认路径段复制上限从 512 降至 21。
- Charger 状态机：Bait 同一 tick 对每名生还者最多三次的可见性查询合并为一次；
  非近战分支不再计算 watcher。Approach 先用距离淘汰候选再查 LOS，Charging 在非
  最后一跳时先判定距离/丢失视野退出，再执行路径阻挡和逐段地面 Trace。
- 统计数据库：同表计数合并先把八特一波从 48 个 SQL 任务降至 32 个；追加型
  `score_log` 再把同一 0.25 秒窗口内的 8 条流水合成一个 multi-row INSERT，总任务约
  降至 25。流水行数、顺序、`score_after` 和原因上下文不变。
- 内鬼额度：普通 SI 一次成功出生原本通常有约 5 次同步额度库操作，Tank 约 8 次。
  30 秒快照复用后，典型路径缩为首次一次完整读取和最终一次更新，即分别约 `5 -> 2`
  与 `8 -> 2`；退款和 Tank 处罚不再先读后写。最终消费带数据库余额条件，多服并发时
  不再因“先读后无条件递增”而超额。
- 伤害显示：移除每帧 32 槽扫描，100 tick 空闲期约减少 3200 次槽位检查；没有合格
  的真人生还者启用显示时，不安装伤害 Hook。存在累计伤害时，一个 10 Hz Timer 只
  遍历实际活跃的攻击者/受害者组合。
- 命中反馈：连续 H 次相同图标命中由 H 次 Timer 创建及最多 H-1 次销毁，降为一次
  共享 Timer 创建和 H 次 deadline 更新；命中路径不再调用 PrecacheSound/PrecacheDecal，
  相同图标活跃期间也不再重复发送 `r_screenoverlay`。
- 私有属性：没有匹配 profile 时，PWA+PMA 当前启用 0 个 Detour，PWA 也启用
  0 个伤害 Hook。现有数据库中，命中管理员枪械规则启用 3 个 Detour，命中管理员
  近战规则启用 1 个，两类 profile 被不同玩家同时激活时并集上限为 4 个。
- 私有属性协调器：认证完成时一次扫描全局规则快照，保存该玩家所有匹配属性并按
  `target/mode/item` 建桶。WeaponSwitch pre 只合并最多四个小桶，post 校验身份、
  武器实体和配置代数后重放命中行；正常切枪的全表规则匹配检查从 112 降至 0。
- 低频尖峰：八特出生不再为新手引导创建 8 个无效 Timer；连续换队事件由 N 个状态
  Timer 合并为 1 个。
- 配置触发尖峰：CVar shield 的 N 次连续触发从最多 3N 个待执行 Timer 降为 1 个。
- Nav 变体：配置、Ready 名称和 Stripper 路径是否允许替换已事件驱动缓存；大量非 Nav
  `ReadFile` 回调在后缀快筛后立即返回，不再执行路径规范化与配置查找。
- 全服聊天：默认空服轮询由 5 秒降至 30 秒，单台空服每小时 SELECT 约从 720 降到
  120；有人进服时仍维持原来的 5 秒消息延迟上限。

## 当前私有属性规则

当前数据库有 56 条启用规则：

- 54 条 PWA：管理员专用、2 个模式、9 种枪，每种设置 `verticalpunch`、
  `horizontalpunch`、`maxmovespread`。
- 2 条 PMA：管理员专用、全模式、全近战，设置 `damageflags=4`、
  `decapitates=1`。

当前没有 PWA `damage` / `tankdamagemult`，也没有 PMA `damage`。因此优化后的
PWA 不安装伤害 Hook，PMA 伤害 forward 会在 native 检查前返回。

## 后续优化顺序

1. 在实际 100-tick 服务器采集受控 profile：空服、八特战斗、八特出生尖峰、
   管理员枪械 profile、管理员近战 profile。记录帧时间、forward 次数、DHooks 次数
   和 SQL 队列深度。
2. 继续降低 PWA/PMA 生效态 overlay 成本。生产模式可减少诊断性 readback，审计模式
   保持完整 get/set/readback，但必须先在运行服做 A/B 正确性验证。
3. 用 profiler 确定 `infected_control` 去除 VM 搬移/Handle 分配后剩余的 Nav/Trace
   引擎成本，以及 Charger 的
   `nextTickPosCheck`、Gap、Path 前瞻各自占比；这些安全判断不能仅凭静态计数跨 tick
   限频。
4. 按要求保留现有同步数据库连接方式。内鬼额度仅通过 30 秒快照减少重复读取，并用
   原子条件更新修复并发超额；不引入异步连接、懒连接或异步出生状态。
5. 用 DHooks profiler 测量 `l4d2_block_autoaim`，并单独记录 `l4d2_nav_variant` 优化后
   的换图 ReadFile 拦截成本；两者目前没有证据能解释八特战斗期持续卡顿。

## 验证状态

所有改动的 SourcePawn 插件均可由 SourcePawn 1.12.0.7230 编译。唯一警告是项目公共
`halflife.inc` 中已有的 `CreateDialog` deprecated 警告。Infected Control、Hitsound、
Damage Show、CVar shield、Charger、Nav variant 和 Global Chat 本轮也已重新编译；动态难度源码与 SMX 均恢复为
`HEAD` 原版本。私有属性的 106 项结构测试
全部通过，两个仓库的 `git diff --check` 通过；PWA/PMA/player_attr_db 的插件目录、
`build`、发布归档和 NewAnneWeb 手动更新镜像哈希一致，更新清单同步状态为 `complete`。
`anne_spawn_accel` 的 10,000 Nav / 60,000 边缓存往返测试通过；Linux L4D2 32 位 `.so`
已由 Clang 22 / AMBuild 成功构建。Windows `.dll` 本机没有对应交叉编译工具链，本轮未重建。

仓库内没有可用的本地 `srcds`，因此热加载/卸载、实际 CPU 时间、数据库断线恢复仍需
在预发布或生产服务器验证。静态回调数量不能替代运行时测量。
