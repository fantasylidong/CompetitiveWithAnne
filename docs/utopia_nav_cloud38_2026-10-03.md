# Utopia v1.1：云38 NAV 每5%取点实测

日期：2026-10-03。节点 `anne-cloud-35-41`，仅操作云38 `anne4`，端口21003。原计划云36，复查已有真人，改用空闲云38。测试时使用临时游戏密码隔离，并核验无人；其他六个实例未修改。

报告日期按 `America/Los_Angeles`；原始日志保留服务器时间，因此后续批次部分日志显示10月4日。

## 结论

原包 NAV 能在 versus 中读取，三章的每个5%进度范围都存在从起始 NAV 可达的代表区域，没有发现必须重建整份 NAV 的证据。

**Boomer 模型列表缺项已定位到任务注入时机，并已修复初始化。** 地图投票在 `OnMapInit` 重新注入 versus 任务信息后，原生模型初始化能读到 Utopia mission，列表由一个男模型恢复为两个有效模型。三章六个模型分支用例全部通过，合计成功生成612只特感，其中Boomer为女68只、男34只，未出现新崩溃。57个常规进度点中45个完整通过、11个定位失败、1个找位超时；不再依赖 `no_female_boomers=1`。具体回归范围见下方“模型列表初始化修复”。

早期还有独立的 `anne_spawn_accel::PumpNavGraph` 无效指针崩溃，本次未修改该扩展。测试时在切章前卸载刷特插件和矩阵探针，待新图稳定后再加载，不能据此宣布该切图问题已解决。上述结果不代替真实行走、机关、换边、救援及完整通关测试。

修复前曾按用户建议单独预缓存 `boomer.mdl` 与 `boomette.mdl`，确认两模型均已缓存；即使提前到 `OnMapStart`，首章20%仍在Boomer生成时因相同异常模型字符串崩溃。**普通模型预缓存不会补齐本次不完整的模型选择列表，不能单独修复此故障。** 以下保留调查与对照过程。

## 地图与测试环境

原包 `/map/Utopia v1.1_3778253592_server.vpk`，SHA-256：

```text
2a546286063680355053234854cb95c1701dc6c90bc38f7ecf5b564ffc5c1a72
```

沿用之前发现的多小数点文件枚举问题，只在云38的 addons 增加临时安全文件名软链接，目标仍为原 VPK；没有重写 BSP、NAV，也没有运行 `nav_generate` 或 `nav_analyze`。

静态取点环境是基础 `versus` + `cfg/stripper/zonemod_anne`，没有装载整套 Anne 玩法插件。三章的 `sm_nav_variant_status` 均为 `configured=0`、`redirects=0`、`no configured variant for this map`，原始路径为 `maps/utopiaN.nav`。

动态对照使用服务器现有二进制：`infected_control` 实际插件版本 `2026-09-04.1`、Anne Spawn Accel `1.5.0`、矩阵探针 `1.3.0`。完整 Anne 配置的 `AnnePluginVersion` 标签仍为 `2026-08`。没有升级或替换这些生产二进制。

## 静态取点：三章共63点

每章请求0%、5%、…、100%，包含端点，21点。按引擎 flow / mapMaxFlow 计算百分比；不是剧情任务进度或真人实际通关比例。

| 地图 | NAV区域总数 | 最大flow | 取点数量 | 最近区域最大误差 |
|---|---:|---:|---:|---:|
| utopia1 | 10,021 | 65,272.55 | 21 | 0.1908个百分点 |
| utopia2 | 3,411 | 36,673.66 | 21 | 0.2771个百分点 |
| utopia3 | 1,265 | 34,486.94 | 21 | 0.5177个百分点 |

每个请求进度的±2.5个百分点范围内均存在 NAV 区域，也存在未带起点、安全屋、救援车辆或救援壁橱排除标记且有出邻接的区域。这里的筛选不等于合格特感出生点验证。

最初选择 flow 最接近请求值、有出邻接的区域。起始 NAV → 代表区域的生还者路径查询，尊重/忽略 NAV blocker 两种设置均为59/63成功。四个失败点均为单点选择问题的候选，不能直接判为整段不可达；复查同进度附近最近32个候选后，都找到可达替代区域：

| 地图/进度 | 原区域ID | 替代区域ID | 替代实际进度 |
|---|---:|---:|---:|
| utopia1 / 75% | 26817 | 29188 | 74.9953% |
| utopia1 / 95% | 24506 | 24465 | 94.9961% |
| utopia2 / 70% | 8281 | 1031 | 70.0827% |
| utopia2 / 80% | 7878 | 617 | 79.9898% |

四个替代点均通过起点→该点、前一进度点→该点的生还者路径查询，以及前一进度点↔该点的特感双向路径查询。**因此63个进度都有起点可达的代表区域，但不是全部区域都可达。** 原始抽样有四条“后一点→原异常点”的特感反向路径失败，未针对替代点重查该方向，不改判为通过。

方法使用 `L4D2_NavAreaBuildPath`，生还者team=2、特感team=3，路径长度上限为 `maxFlow*3+10000`。这是 NAV 图路径查询，不检查真实行走、实体碰撞、机关推进或全程连续通路。起点是最接近0%且有邻接的区域；例如utopia3没有 PLAYER_START 标记，不能把它等同于真实出生点。

## 动态与完整配置：失败，未完成63波

1. **13:07:18 UTC**：完整 Anne 切入utopia1后发生 `Alarm clock`，SRCDS被SIGALRM终止并由 `srcds_run` 重启。没有该次可用栈，原因未确认。
2. **13:09:54 UTC**：切图对照发生SIGSEGV。匹配Build ID的二进制解析得到：

   ```text
   anne_spawn_accel.ext.2.l4d2.so + 0x85f1e
   (anonymous namespace)::PumpNavGraph(bool) + 15838
   (anonymous namespace)::Native_NavGraphPump(...) + 48
   ```

   指令从区域 `+0x58` 读到非空指针，随后解引用失败。源码中对应位置与读取 NAV 连接存储吻合。切图/建图过程中保留了失效地址是调查方向，**尚未证明具体生命周期根因，不能直接归因于原NAV损坏**。
3. 地图稳定后再加载矩阵和刷怪插件，utopia1能完成有向建图：10,021区域、42,018连接。请求5%的四名测试生还者实际位于4.08%–4.98%，均值4.61%。计划12只特感、六种各2只。
4. **13:13:35 UTC**：第一波仅记录Smoker、Hunter、Charger、Jockey各1只成功出生，随后SIGSEGV，未完成整波。该次dump已由现有Accelerator上传并移除，本地没有取得栈，不能认定与第二次同源。现有崩溃编号 `CR-9DA1DA2E3EE9E9C6AAF5`。

上述失败后停止反复运行出生波次，改用不创建机器人、不调用自定义建图扩展的只读NAV探针完成63点覆盖。**没有“63个出生波次通过”的结果，没有真人或机器人走完全图的结果。**

## 补查：普通、对抗、插件覆盖项与 VScript 上限

用户指出需要按战役刷特插件的方法解锁并同步同时特感上限。复查发现原测试存在两个遗漏：没有更新 VScript `MaxSpecials`，也没有显式核验 `z_versus_*_limit`。原报告不能据插件日志里的 `cap=12` 就排除其他层的限制；`target=3` 是目标生还者索引，不是数量上限。

运行态先取得以下对照：加载刷特插件前，`GetMaxPlayerZombies=4`；加载后为31，`l4d_infected_limit=12`、`z_max_player_zombies=12`，但脚本 `MaxSpecials` 仍为2，`cm_MaxSpecials` 与 `DominatorLimit` 缺失。对抗刷特插件已使用与战役 `l4d2_dirspawn` 相同的 return-31 补丁，缺少的是脚本及其他上限的同步/核验。

第一轮按战役方式同步当前/基础 `DirectorOptions` 后，首章5%、10%、15%、20%各完成12只（六类各2），耗时分别476.5、375.0、226.5、210.9毫秒。25%成功11只后，在第二只Boomer生成期间因异常模型参数崩溃。这一轮仍缺对抗专用职业CVar快照，不能作为“所有数量CVar都正确”的对照。

之后把以下三组18项全部显式设置并在起波前回读为2：

```text
z_{smoker,boomer,hunter,spitter,jockey,charger}_limit
z_versus_{smoker,boomer,hunter,spitter,jockey,charger}_limit
inf_{smoker,boomer,hunter,spitter,jockey,charger}_limit
```

同时回读确认 `engineMax=31`、`maxClients=31`，插件总数、`z_max_player_zombies`、`MaxSpecials`、`cm_MaxSpecials`、`DominatorLimit` 均为12，六职业脚本上限各2。[完整上限快照](utopia_nav_cloud38_2026-10-03/caps-retest/all_caps/si_caps.jsonl) 包含配置完成及5%起波前两次读回。

**全部上限一致后仍复现模型崩溃，且当时没有刷超这些限制：** 5%波次成功生成Smoker、Hunter、Jockey、Charger、Spitter各1只，Boomer为0；随后第一次Boomer生成在 `UTIL_SetModel` 中触发引擎 fatal error：

```text
10/ - player:  UTIL_SetModel:  not precached: ACT_PRIMARYATTACK_o22_IDLE
ZombieManager::SpawnSpecial -> Boomer::Spawn -> CTerrorPlayer::SetModelFromClass
-> UTIL_SetModel -> Error -> Sys_Error_Internal
```

此时成功生成总数5，小于总上限12；Boomer为0，小于职业上限2。错误参数是活动名式字符串，并非正常模型路径，不能直接等同于“漏预缓存正常胖子模型”。后续运行态快照在模型向量的无效第二槽找到相同字符串，见下面的对照复测。

另一次0%阶段故障的转储也解析到Boomer生成/`UTIL_SetModel`，并非单纯NAV查询栈；该阶段尚未进入工具标记的0%波次，不应描述为“没有任何生成调用”。

测试探针更新为1.4.0：同步当前/基础脚本表，短时守护其值，SDK回读引擎上限；驱动核验普通/对抗/插件覆盖三组职业CVar，并留档后才起波。旧版没有 `inf_*` 覆盖项时明确按不存在处理。工具还保存原脚本键及其存在性，清理时撤回覆盖；真人检查移至切图之前，清理时遇真人也不切图。编译成功；限额拒绝、旧版兼容、真人拒绝与清理不切图的驱动检查通过。新测试二进制只保留在本地仓库，云38原测试SMX已经恢复。

**六职业各2只的完整三章动态矩阵仍未完成。** 所有63个静态进度点的结果仍有效；后续无 Boomer 对照和首章绕过复测见下，不能据此宣称全图正常。

复测证据：[普通+脚本上限批次](utopia_nav_cloud38_2026-10-03/caps-retest/script_caps_only/results.csv)、[全部上限批次](utopia_nav_cloud38_2026-10-03/caps-retest/all_caps/results.csv)、[最新崩溃函数链](utopia_nav_cloud38_2026-10-03/caps-retest/all_caps_crash_symbols.txt)、[错误原文](utopia_nav_cloud38_2026-10-03/caps-retest/all_caps_crash_error-string.txt)、[最新恢复验收](utopia_nav_cloud38_2026-10-03/caps-retest/all_caps/restoration-verification.json)。

## 地图是否修改 Boomer：只读资源与引擎核查

核查对象是服务器正在使用的 `Utopia v1.1_3778253592_server.vpk`，不等同于客户端原始 Workshop 包。外层VPK完整目录11项，没有 `models/infected`、材质、population 或 gamemodes 覆盖文件。三章BSP内嵌pakfile分别213、938、219项，逐项CRC校验通过；内容为材质/贴图、顶点光照及字符串字典，没有模型文件或内嵌脚本。

地图没有配置 `BoomerVariant`、`BoometteVariant` 或 `no_female_boomers`；mission的 `survivor_set=2`。唯一BSP实体中的胖子模型引用是第三章 `prop_dynamic` 的 `models/infected/limbs/exploded_boomer_steak3.mdl`（hammerid 61228），属于肢体道具，不能当作活体胖子模型替换。DCT字符串字典中虽然有标准Boomer/Boomette资源名，但没有对应替换资源；三个字典均没有 `ACT_PRIMARYATTACK` 字符串。

唯一 `utopia.nut` 共18行，修改视野、雾中生成、生成/回收距离和保留人数，其中 `NumReservedSpecials=8`；没有模型或性别选择逻辑。这不支持“Utopia主动替换活体胖子模型”的说法。

匹配转储的 `server_srv.so` 反汇编提供了更具体的调查方向：

- `SetModelFromClass` 从 `InfectedModels[2]` 的字符串指针向量中取值并调用 `SetModel`；坏参数已是 `ACT_PRIMARYATTACK_o22_IDLE`。它不是在报错时才由模型预缓存索引转换出来的。
- `PrecachePlayerModelAndMaterials` 正常会读取任务中的模型变体，或使用默认 `boomer.mdl` / `boomette.mdl`，复制字符串后加入该向量。
- 模型不可用时，helper存在不加入向量的路径；任务信息缺失或 `no_female_boomers` 非零时也存在只加入一个模型的正常路径。
- Boomer选择分支可按性别选择第0/1项，但在最终读取前没有再次校验 `count>=2`。因此“列表不完整但选择了第二项”存在静态可能；**转储没有保存列表本体，不能证明本次真的只有一项或发生了越界**。字符串/向量指针失效也仍是候选。
- `survivor_set` 不直接控制上述Boomette加入分支，因此不能仅因Character Manager覆盖生还者集合就将其认定为根因。

另查到同服 Salvation Falls 的 `scripts/vscripts/scriptedmode_addon.nut` 无地图名限制地包装 `ScriptMode_Init`，并最终返回true；它可能跨图影响脚本初始化，但没有直接设置Boomer/Boomette模型。该包需通过单包对照才能判断关联，现有证据不支持直接归因。

该阶段只读核查没有进行新切图、刷怪或部署，也没有改NAV。其后取得的运行态模型列表和刷怪对照如下。

资源证据：[VPK目录](utopia_nav_cloud38_2026-10-03/map-resource-audit/vpk-index.txt)、[任务配置](utopia_nav_cloud38_2026-10-03/map-resource-audit/mission-utopia.txt)、[地图脚本](utopia_nav_cloud38_2026-10-03/map-resource-audit/utopia.nut)。引擎关键ELF地址：`InfectedModels=0x1007360`，Boomer向量 `0x1007388`，最终读指针 `0x9b9a6c–0x9b9a70`，Boomette预缓存调用 `0x9c20bf`，Boomer预缓存调用 `0x9c1a03`。对应SO与此前转储Build ID匹配。

## 无 Boomer 对照：三章57点

在同一云38、versus、Anne stripper 和原NAV条件下，每章请求5%至95%，步长5%，三章各19点。五职业各2、总上限10；普通、versus、插件三组 Boomer CVar及脚本 `BoomerLimit` 均为0。49份起波/初始化快照均符合这一配置。

| 地图 | 完整10只波次 | 生还者定位失败点 | 起波但未找到出生位置 | 成功出生 |
|---|---:|---|---|---:|
| utopia1 | 17 | 70%、75% | 无 | 170 |
| utopia2 | 16 | 15%、20%、60% | 无 | 160 |
| utopia3 | 11 | 5%、10%、35%、40%、70%、75%、85% | 25% | 110 |
| 合计 | 44 | 12点 | 1点 | 440 |

Smoker、Hunter、Spitter、Jockey、Charger各88只，实际成功与独立出生探针计数一致；Boomer事件为0。431只通过正常NAV路径生成，9只通过正常Director范围回退生成，没有不受距离限制的强制生成。实验未出现服务器崩溃；第一批因驱动误将 `humanClients=0` 当作有人而停止，第二批续跑剩余点，合计57个唯一请求点，无重复或遗漏。

第三章25%已经完成生还者定位（均值25.21%），但10.27秒测试窗口内出生调用为0、队列剩10。日志显示范围候选耗尽，745次Director找点全部miss，候选被距离、卡住或可见性筛选排除；图状态为 `ready/complete/stable`。这证明该测试场景下没有找到合格出生位置，不能直接推定NAV损坏或生成函数崩溃。

总数10与此前含Boomer的12只波次不同，因此本对照本身不能单独排除总压力影响；下面恢复12只、保留Boomer的对照进一步缩小了问题范围。

证据：[第一批结果](utopia_nav_cloud38_2026-10-03/no-boomer/batch1/results.jsonl)、[第二批结果](utopia_nav_cloud38_2026-10-03/no-boomer/batch2/results.jsonl)、[第一批上限](utopia_nav_cloud38_2026-10-03/no-boomer/batch1/si_caps.jsonl)、[第二批上限](utopia_nav_cloud38_2026-10-03/no-boomer/batch2/si_caps.jsonl)。两批目录中的 `raw.tar.gz` 保存逐点原始日志。

## Boomer 模型列表实证与保留 Boomer 的复测

直接读取正在运行的进程内指定模型向量，未暂停进程或修改内存。服务器与本地解析SO的Build ID均为 `63d548cd906cf59fea09cf23d729b56d92467d0e`，映射inode匹配。

- 第二章无Boomer对照期间：有效元素数2，slot 0为 `models/infected/boomette.mdl`，slot 1为 `models/infected/boomer.mdl`。
- 首章重新载入、尚未开始标记波次时：有效元素数1、分配容量8，唯一有效slot 0为 `models/infected/boomer.mdl`；**有效范围外的slot 1指向 `ACT_PRIMARYATTACK_o22_IDLE`**，与此前fatal error参数一致。
- 该次已先启用战役转对抗、强制 `sm_reload_vpk` 完成mission注入再切图，仍出现单元素列表，不能声称仅调整刷新顺序就已解决。

结合反汇编：预缓存阶段在mission信息为空或 `no_female_boomers` 非零时可只加入男模型；选择阶段若mission有效且未禁女性，可能访问第0或1项，仅校验总数非零，没有再次检查至少两项。若该键非零，选择阶段强制访问第0项。**正常双模型列表的第0项是女性、第1项是男性，不能把“无效第二项”等同于“女模型”。** 现有证据强烈支持列表构建状态与选择状态不一致导致越界选择；快照不是逐指令调用跟踪，列表为什么漏一项尚未锁定。

随后在同样单元素首章，临时通过现有 SourceKeyValues API 将当前 Utopia mission的 `no_female_boomers` 设为1，每波前回读确认。它是mission键，**不是可用 `sm_cvar` 设置的控制变量**。保留六职业各2、总数12，与所有普通/versus/插件/脚本上限一致。

| 请求进度 | 实际均值 | 生成数量 | Boomer实际模型 | 整波耗时 |
|---|---:|---:|---|---:|
| 5% | 4.84% | 12 | 男胖子×2 | 773.4 ms |
| 10% | 10.28% | 12 | 男胖子×2 | 195.3 ms |
| 15% | 14.17% | 12 | 男胖子×2 | 234.3 ms |
| 20% | 19.25% | 12 | 男胖子×2 | 250.0 ms |
| 25% | 25.59% | 12 | 男胖子×2 | 500.0 ms |

五波共60只、每职业10只，全部成功且峰值同时存活12。10条Boomer出生模型记录全部为 `models/infected/boomer.mdl`，未复现崩溃。复测期间只读快照仍是count=1、slot 1为同一异常活动名，因此这次设置绕过了有问题的选择分支，并未修好模型列表。只验证了首章五个点的AI生成，没有验证真人感染者、后续章节、换边、死亡效果或长期运行。

可落地的短期处理是让受影响地图在模型初始化与生成选择阶段一致禁用女性模型，保留Boomer职业；正式接入需覆盖重载、逐章及换边时机。不能把本次后加载的测试命令直接当作全图通用修复：双模型列表若已建立，第0项可能是女性。长期仍应查明mission初始化为何导致列表不完整，并保证模型选择不访问无效项。不要预缓存 `ACT_*` 字符串，也不要把降低总特感数当作本故障的修复。

证据：[首章原始快照](utopia_nav_cloud38_2026-10-03/boomer-model-vector/utopia1-before-wave.json)、[第二章快照](utopia_nav_cloud38_2026-10-03/boomer-model-vector/utopia2-no-boomer.json)、[绕过期间快照](utopia_nav_cloud38_2026-10-03/boomer-model-vector/utopia1-with-guard.json)、[五波结果](utopia_nav_cloud38_2026-10-03/boomer-guard/results.jsonl)、[临时探针源码](utopia_nav_cloud38_2026-10-03/boomer-guard/utopia_boomer_guard.sp)。

## 补测：只预缓存男、女 Boomer 模型

按用户要求，在云38重新进行两轮隔离测试，未设置 `no_female_boomers`，每波仍为12只、六类各2。临时插件仅使用普通 `PrecacheModel`，不写mission、不修改模型选择向量。mission逐点回读均为 `no_female_boomers=0`、键类型0（原键不存在）。

| 对照 | 缓存时机 | 结果 |
|---|---|---|
| 载图后缓存 | 地图/矩阵配置完成后，起波前缓存两模型 | 5%、10%、15%、20%、25%五波通过，共60只，10只Boomer全部为男模型 |
| 提前缓存 | 插件在切图前加载，`OnMapStart` 缓存两模型 | 5%、10%、15%三波通过，共36只；20%成功4只其他职业后发生Boomer模型崩溃 |

第一轮缓存前：男模型已缓存，女模型未缓存。调用后得到有效模型索引43和694，并确认 `male_cached=1 female_cached=1`。预缓存前、预缓存后、波次中三次运行态快照的向量头、指针和字符串完全一致：count=1、capacity=8；slot0为 `models/infected/boomer.mdl`，无效slot1仍指向 `ACT_PRIMARYATTACK_o22_IDLE`。因此“两个模型都在缓存中”不等于“选择列表有两个有效元素”。第一轮没有进程重启，但十次实际Boomer均为男模型，不能用该短样本证明已修复。

第二轮确认 `map_start_applied=1`，每个起波前仍确认两个模型已缓存。其运行态快照同样为单元素列表；同时只读确认全局 `g_ZombieReplacementGender=0`。保持原 `z_female_boomer_spawn_chance=25`，20%波次在Hunter、Smoker、Jockey、Charger各1只成功后中断，未记录成功Boomer。服务器进程PID从1378085变成1491624。

新转储 `05304b0c-a5e1-4681-fb6011a3-0da2e150` 的匹配符号链为：

```text
9/ - player:  UTIL_SetModel:  not precached: ACT_PRIMARYATTACK_o22_IDLE
ZombieManager::SpawnSpecial -> DispatchSpawn -> Boomer::Spawn
-> CTerrorPlayer::Spawn -> SetClass -> SetModelFromClass
-> SetModel -> UTIL_SetModel -> Error -> Sys_Error_Internal
```

这排除了“只需把两个正常活体模型加入资源缓存”的修复方案，也排除了本轮缓存晚于 `OnMapStart` 的解释。它仍未定位模型列表为什么少一项；转储也未直接保存选取瞬间的随机数或全局性别覆盖值。原计划追加概率0/100边界用例，因默认25就已复现，停止继续刷怪；**0/100用例、第二轮25%均未执行**。

反汇编进一步核验：mission缺失、`no_female_boomers`非零或 `g_ZombieReplacementGender=1` 时取slot0；覆盖值2取slot1；其余情况下 `RandomInt(1,100) <= z_female_boomer_spawn_chance` 取slot1，否则取slot0。该分支没有根据 `IsModelPrecached` 检查修复或扩展列表，也不保证槽位内容一定对应某个性别。一次未命中异常分支的成功波次不能当作修复证据。

两轮临时插件均已卸载并移除，地图、模式、Stripper、原密码、addonlist、翻译文件及矩阵SMX恢复，原VPK哈希一致。最终77个捕获CVar中，29个仍存在的项目全部为原值；48个原先已卸载刷特插件留下的CVar随游戏进程重启消失，该插件测试前后都未运行，没有为了重建这些闲置CVar再加载玩法插件。未修改其他实例或共享VPK/NAV。

证据：[晚缓存调用结果](utopia_nav_cloud38_2026-10-03/boomer-precache/late/cache-apply.txt)、[晚缓存前快照](utopia_nav_cloud38_2026-10-03/boomer-precache/late/model-vector-before-precache.json)、[晚缓存后快照](utopia_nav_cloud38_2026-10-03/boomer-precache/late/model-vector-after-precache.json)、[晚缓存五波结果](utopia_nav_cloud38_2026-10-03/boomer-precache/late/results.jsonl)、[早缓存逐点确认](utopia_nav_cloud38_2026-10-03/boomer-precache/early/cache-status.jsonl)、[早缓存快照](utopia_nav_cloud38_2026-10-03/boomer-precache/early/model-vector-after-early-precache.json)、[新崩溃符号栈](utopia_nav_cloud38_2026-10-03/boomer-precache/early/crash-symbols.txt)、[恢复验收](utopia_nav_cloud38_2026-10-03/boomer-precache/early/restoration-verification.json)。两轮目录的 `raw.tar.gz` 保存逐点原始日志，完整转储未进入仓库。

## 模型列表初始化修复

对 `CTerrorPlayer::Precache` 和 `GetMissionInfo` 只读跟踪，确认调用顺序为 `OnMapInit → Precache → OnMapStart → OnConfigsExecuted`。旧地图投票插件在新图 `OnMapInit` 没有重新注入任务；即使切图前已经刷新并注入，Utopia 首章进入模型初始化时，任务注册表中的 `modes/versus` 仍缺失。8次原生Precache中，16次 `GetMissionInfo` 查询全部为空；Utopia的原coop mission已在注册表中。引擎因此跳过女性模型条目，后续配置阶段补入任务时，模型列表不会自动重建。

生产改动仅在 `l4d2_map_vote.sp` 增加 `OnMapInit`，调用 `MarkMissionKVDirty()` 和现有 `InjectMissionKV()`，版本升级为 `0.9.4-custom`。这清除上一张图的注入缓存，在模型初始化之前准备 versus 任务信息。没有添加生产detour，没有直接写模型向量、改模型顺序、额外缓存固定模型或覆盖 `no_female_boomers`。

同样从官方图coop切入Utopia versus，修复后8次原生Precache中的16次查询全部返回Utopia mission，`noFemale=0`。独立内存快照确认count=2、capacity=8，两个有效元素为 `models/infected/boomette.mdl` 和 `models/infected/boomer.mdl`，由引擎自身分配和填入。

随后卸载只读trace插件，保留生产修复，再运行出生测试。只读状态探针不调用 `PrecacheModel`，也不写mission。两个概率边界用例按当前引擎实际映射验证模型选择：chance=0访问slot0（此处为女模型），chance=100访问slot1（此处为男模型）；不按CVar名称猜测模型性别。

每章先跑两个模型分支用例，再按5%、10%、…、95%进行常规取点；合计6个分支用例加57个常规进度点，**不包含动态0%/100%端点测试**。第一批因首章70%的定位拒绝而结束并恢复；第二批跳过已覆盖的16个唯一场景续跑47个，定位拒绝仅记录后继续，RCON/真人/意外换图仍立即停止。合并后63个 `(kind,map,percent)` 唯一键，无遗漏或重复。

| 地图 | 模型分支通过 | 常规取点通过 | 定位失败点 | 找位超时点 | 全场景成功生成/探针 |
|---|---:|---:|---|---|---:|
| utopia1 | 2/2 | 17/19 | 70%、75% | 无 | 228/228 |
| utopia2 | 2/2 | 15/19 | 15%、20%、60%、70% | 无 | 204/204 |
| utopia3 | 2/2 | 13/19 | 10%、40%、70%、75%、85% | 25% | 180/180 |
| 合计 | 6/6 | 45/57 | 11点 | 1点 | 612/612 |

51个完整通过场景均为六类各2、同时存活峰值12，六职业实际/探针各102；102条Boomer模型记录中女68、男34。597只通过正常NAV生成，15只通过正常Director范围回退，没有不受距离限制的强制生成。56份上限快照全部正确，63份模型状态快照均为mission `utopia`、`no_female_boomers=0`且原键不存在、男女模型均已缓存。

第二章70%的定位失败仅因最低实际进度67.49%低于允许下限67.50%，没有起波；未放宽标准改判通过。第三章25%已定位并起波，但10.37秒内797次Director找点全部miss，出生调用为0、队列剩12，正常结束后继续；并非模型崩溃。不同批次先前位置及地图状态不完全相同，定位通过数的变化不能解释为NAV修复。

两批起止游戏进程均为PID1491624，未重启，逐点日志未出现新的 `UTIL_SetModel` 错误。最终恢复原 `c2m1_highway/coop`、Stripper路径和密码，77个捕获CVar全部回读一致；原地图投票 `0.9.2-custom`、原矩阵SMX、addonlist及翻译文件恢复并核验一致，临时插件和gamedata移除，原VPK哈希不变。测试后的云38没有保留新生产SMX；本地已重编译的 `0.9.4-custom` 与测试文件逐字节一致，SHA-256为 `a7a99524ea79318a2baf919492625e06475f3ca52d7b04c8c73e6d0eb9084cfe`。

沿用原有 `l4d2_mapvote_versus_from_coop` 开关，默认2。该值须在载图前生效；模式1还要求当时的ready cfg已匹配Anne，后置执行的配置不能追溯修改已经建立的模型列表。插件晚加载或更改开关后需重新载图。

证据：[修复前初始化trace](utopia_nav_cloud38_2026-10-03/model-init-fix/trace.txt)、[修复后初始化trace](utopia_nav_cloud38_2026-10-03/model-init-fix/trace-init-fix.txt)、[两个有效模型快照](utopia_nav_cloud38_2026-10-03/model-init-fix/model-vector-init-fix.json)、[只读状态探针](utopia_nav_cloud38_2026-10-03/model-init-fix/utopia_model_status.sp)。trace中的 `nativeVS` 字段仅表示存在 `modes/versus` 节点，包含临时注入的节点，并不表示地图作者声明了原生对抗支持。

回归证据：[汇总](utopia_nav_cloud38_2026-10-03/model-init-fix/summary.json)、[第一批结果](utopia_nav_cloud38_2026-10-03/model-init-fix/batch1/results.jsonl)、[第二批结果](utopia_nav_cloud38_2026-10-03/model-init-fix/batch2/results.jsonl)、[测试版本与哈希](utopia_nav_cloud38_2026-10-03/model-init-fix/batch2/map-vote-build.txt)、[最终恢复验收](utopia_nav_cloud38_2026-10-03/model-init-fix/batch2/restoration-verification.json)。两批的 `raw.tar.gz` 保存完整逐点日志。

## 模式区别与公开案例

本次AI生成走 `ZombieManager::SpawnSpecial → Boomer::Spawn → CTerrorPlayer::SetModelFromClass`，战役和对抗共用这条底层路径，模型列表构建/选择逻辑没有“对抗专用胖子模型”的区分。模式相关的任务信息、脚本初始化、职业上限，以及AI与真人感染者入口仍可不同，不能由共用底层推断全部行为相同。[Left4DHooks的生成接口](https://github.com/SilvDev/Left4DHooks/blob/main/sourcemod/scripting/include/left4dhooks.inc)也明确区分其AI生成接口与玩家生成。

公开插件已有女性胖子死亡时漏预缓存 `models/infected/limbs/exploded_boomette.mdl` 的崩溃案例，作者在2022-03-10的1.0.5版补了预缓存。该案例是正常模型路径缺少预缓存，与本次生成阶段读到 `ACT_*` 不同。[原报告与修复记录](https://forums.alliedmods.net/showthread.php?t=328929)。没有可用的服务器总样本/运行时长统计，无法判断Boomer炸服的总体发生率，不能称其为普遍现象。

## 恢复

云38已恢复测试前 `c2m1_highway`、`coop`、`addons/stripper`、原游戏密码及插件加载锁。临时VPK别名、静态探针SMX/远端源码已移除，矩阵探针和临时加载的刷怪插件已卸载。地图包哈希、addonlist及翻译目录与备份一致；所有捕获的原始CVar均逐项复核。未改其他实例或共享地图包。

最后一轮Boomer绕过测试结束后，再次核验76个捕获CVar全部一致，临时guard已卸载并移除，原矩阵SMX恢复为SHA-256 `c3adafa082fd7d22d65a4661b724f9a87bc18c33f937bc93e1ca1e6ba2df1c01`。卸载时撤回mission键值，并通过 `sm_reload_vpk` / `mission_reload` 重建任务信息，随后切回原图。[最后一轮恢复验收](utopia_nav_cloud38_2026-10-03/boomer-guard/restoration-verification.json)。该绕过没有作为生产配置留在服务器上。

## 证据

- [63点CSV](utopia_nav_cloud38_2026-10-03/points.csv)
- [逐点原始输出](utopia_nav_cloud38_2026-10-03/raw.txt)、[四点复查](utopia_nav_cloud38_2026-10-03/recheck.txt)
- [统计与方法边界](utopia_nav_cloud38_2026-10-03/static-summary.json)、[探针源码](utopia_nav_cloud38_2026-10-03/utopia_nav_audit.sp)
- [首个5%波次失败日志](utopia_nav_cloud38_2026-10-03/utopia1_5pct_spawn_failed.log)
- [已取得的崩溃栈](utopia_nav_cloud38_2026-10-03/navgraph_crash_stack.txt)、[函数解析](utopia_nav_cloud38_2026-10-03/navgraph_crash_symbols.txt)
- [恢复结果](utopia_nav_cloud38_2026-10-03/restoration.json)
