# 云35：纯战役三方图的对抗投票与载图实测

测试日期：2026-10-03，约 04:08–04:21（America/Los_Angeles，UTC−7）。

## 环境和范围

- 节点注册名 `anne-cloud-35-41`，仅操作云35（容器 `anne1`）；云36–41未修改。
- 各阶段状态检查均为 `0 humans`。SRCDS `2.2.4.3 9309`，SourceMod `1.12.0.7230`，Left4DHooks `1.168`，Stripper `1.2.2`。
- 原始状态：`c2m1_highway`、`mp_gamemode=coop`、地图投票 `0.9.2-custom`、`l4d2_mapvote_versus_from_coop=1`。
- 临时部署：地图投票 `0.9.3-custom`、`l4d2_coop_versus_compat 1.0.0`、仅供这次测试的观察插件。测试未加载 ZoneMod 对战配置，因此结论是基础 `versus` 环境的结果。
- 使用服务器命令 `sm_mapvote_list` 读取实际 `ShowVoteMap` 构建的 `Menu` 条目。没有绕过真人命令入口创建机器人，也没有把重新实现的过滤器当作菜单证据。

## 先发现并隔离的挂载问题

共享目录里的六个 VPK 均存在、可读，mission 数据可以正常解析，但引擎只挂载了三套战役。
未挂载的三个文件名都有扩展名前的额外小数点：SchoolLive 的 `V1.5`、Utopia 的 `v1.1`、Pearl River Rage 的 `v1.0`。

对本机引擎文件枚举实现的只读分析发现：`*.vpk` 从首个句点匹配后失败不会回溯。
动态验证时，仅在云35添加临时软链接：

```text
addons/anne_coop_test_utopia_3778253592.vpk
  -> /map/Utopia v1.1_3778253592_server.vpk
```

随后执行 `sm_reload_vpk`，`show_addon_load_order` 出现该包，Utopia 进入 mission 注册表。
没有改名共享 VPK，没有改动其他容器；测试结束后撤回临时链接和自动生成的 addonlist 变化。
正式上线仍需要在地图分发/挂载环节规范服务端 VPK 文件名，测试没有永久修复该问题。

## 对抗菜单的开关对照

原始 `missions/utopia.txt` 仅包含 `modes/coop`，三章为 `utopia1`、`utopia2`、`utopia3`，不含 versus。

在 `mp_gamemode=versus` 下，每次变更开关后刷新 mission：

| `l4d2_mapvote_versus_from_coop` | 实际三方菜单项数 | Utopia |
|---|---:|---|
| 0 | 3 | 不显示 |
| 2 | 4 | 显示，item key 为 `utopia` |

开启时关键控制台输出：

```text
[MapVote] mode=versus third_party_items=4
[MapVote] pierpressure | Pier Pressure
[MapVote] salvationfalls | Salvation Falls
[MapVote] AmidTheRuins | Amid The Ruins
[MapVote] utopia | utopia
[Probe] mission=utopia coop=1 versus=1 injected=1 indexed=1
```

`indexed=1` 来自直接比较 `GameModes/versus/missions/utopia` 与该 mission 的指针。
其余三套原生对抗战役保持 `injected=0`。

## 三章载入

首章通过与投票通过路径相同的 `CDirector::OnChangeMissionVote("utopia")` 入口进入；后两章通过控制台 `changelevel` 单独载入。
每次切图期间 RCON 连接关闭，随后重新查询状态确认结果，未把断连本身算作成功或崩溃。

| 地图 | mp_gamemode | 引擎基础模式 | 章节 | 终局标志 | 最大 flow |
|---|---|---:|---:|---:|---:|
| utopia1 | versus | 2 | 1 | 0 | 65272.5 |
| utopia2 | versus | 2 | 2 | 0 | 36673.6 |
| utopia3 | versus | 2 | 3 | 1 | 34486.9 |

每章兼容插件均运行正常，报告 `Detected coop-only mission: 0 entities, 0 coop output connections adapted.`。
原始 BSP 和运行实体检查一致：Utopia 三章均没有 `info_gamemode`；另查 SchoolLive 三章也没有此实体。
因此零改接是正确结果，这些地图不能证明 `OnCoop` 改接功能的正向效果。

## 验证边界与测试工具问题

- 已验证：实际菜单数据、注入开关对照、mission 的 versus 索引、首章引擎换战役入口、三章分别载入、章节及终局识别、flow 非零。
- 未验证：真人菜单画面及语言、投票计票、自然换边、自动章节衔接、救援触发、距离分和完整结算、ZoneMod/Anne 的完整玩法配置。
- 尝试在空服调用回合结束 native 后，状态仍为第一半场，不能据此声称换边通过。
- 观察插件最初误用绝对日志路径产生一次错误，已改为相对路径；该错误来自临时探针。测试日志未发现地图投票或兼容插件自身的运行异常。
- 观察插件使用 VScript 返回值时受到现有地图防护对 `Convars.SetValue` 的限制；没有关闭防护。后续改为只打印读取结果，Utopia 本身没有可枚举的模式实体。

## 恢复验收

云35已恢复 `c2m1_highway`、`coop`、注入开关 `1`、原地图投票 `0.9.2-custom` 和插件加载锁。
原投票 SMX 的 SHA-256 与备份一致：

```text
1dd5e7f8f833fdb88652e03fc35c98fcf7b3a7a80069e4aab5211af3cefc3690
```

临时兼容插件、观察插件、兼容配置和 VPK 别名均已撤回；`addonlist.txt` 与翻译目录已和备份逐文件核对。
新版本保留在本地仓库，未批量发布。新增的 `sm_mapvote_list` 可用于后续服务器端复核实际菜单。
