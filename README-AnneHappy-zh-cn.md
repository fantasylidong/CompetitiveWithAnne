# **AnneHappy 插件带上对抗插件包**
* 为了保持插件包结构和上游一样方便同步，这个插件包将不会带有nav修改文件和跳舞插件的模型与声音，~~AnneHappy的Nav修改文件请到我的[anne项目](https://github.com/fantasylidong/anne)中下载~~ 新解决方案，到[release页面](https://github.com/fantasylidong/CompetitiveWithAnne/releases)下载整合插件包，里面有
* 当前版本已经是进入stable模式，大部分核心插件更新可以通过join插件自动更新，不用那么频繁检测是否有更新了
* Release 只提供两种整合包：默认完整包需要外部 MySQL，`nomysql` 包不需要外部 MySQL
* `join` 不生成独立 cfg；在各模式的 `shared_settings.cfg` 中，没有数据库时保持 `join_autoupdate=1`，配置好数据库后改为 `2`，白名单内的 Anne 私用服会自动额外更新隐藏插件

## **Accelerator 崩溃报告上传**

> [!IMPORTANT]
> 仓库内的 `addons/sourcemod/configs/core.cfg` 默认供 Anne 私有服务器使用，崩溃报告上传到 AnneWeb，并且只接收 Anne 私用 SourceBans 服务器白名单中的公网 IP。Anne 地址特意使用 HTTP，以兼容随包 Accelerator/libcurl 不支持 HTTPS 的构建；请勿复用这些私有地址。
>
> 如果你在自己的服务器部署本项目，请不要使用 Anne 的私有上传地址，应使用 Accelerator 官方的崩溃、符号和二进制上传接口：
>
> ```text
> "MinidumpUrl" "http://crash.limetech.org/submit"
> "MinidumpSymbolUrl" "http://crash.limetech.org/symbols/submit"
> "MinidumpBinaryUrl" "http://crash.limetech.org/binary/submit"
> ```
>
> `MinidumpAccount` 也应改为你自己的报告账号。Anne 专用配置填写维护者 SteamID64，是为了让 AnneWeb 将报告归属到对应的 Steam 登录账号。


## **AnneHappy 会自动更新的核心插件**
- Path_SM/plugins/optional/AnneHappy/ai_boomer_2.smx"
- Path_SM/plugins/optional/AnneHappy/ai_charger_2.smx"
- Path_SM/plugins/optional/AnneHappy/ai_hunter_2.smx"
- Path_SM/plugins/optional/AnneHappy/ai_smoker3.smx"
- Path_SM/plugins/optional/AnneHappy/ai_spitter_2.smx"
- Path_SM/plugins/optional/AnneHappy/ai_jockey_2.smx"
- Path_SM/plugins/optional/AnneHappy/ai_tank3.smx"
- Path_SM/plugins/optional/AnneHappy/infected_control.smx"
- Path_SM/plugins/optional/AnneHappy/text.smx"
- Path_SM/plugins/optional/AnneHappy/server.smx"
- Path_SM/plugins/optional/AnneHappy/SI_Target_limit.smx"
- Path_SM/plugins/optional/AnneHappy/l4d_target_override.smx"
- Path_SM/plugins/optional/AnneHappy/l4d2_Anne_stuck_tank_teleport.smx"
- Path_SM/plugins/extend/join.smx"
- Path_SM/plugins/extend/server_name.smx"

## **关于新增模式:**

> **AnneHappy新加模式:**
* **AnneHappy 普通药役模式**
* **Hunters 1vHT模式**
* **AllCharget 牛牛冲刺大赛模式**
* **Witch Party模式** 
* **Alone 单人装逼模式**
* **AnneHappy 硬核药役模式***


---

## **目录结构**
* 运行时插件 `.smx` 放在 `addons/sourcemod/plugins/`，保持和上游 `master` 一样的 SourceMod 插件目录结构
* AnneHappy 专属定制插件放在 `addons/sourcemod/plugins/optional/AnneHappy/`；通用或上游同步插件即使被 Anne 模式加载，也优先放在 `addons/sourcemod/plugins/optional/`
* 常规扩展插件放在 `addons/sourcemod/plugins/extend/`
* 项目 SourcePawn 源码 `.sp` 按插件相对路径镜像放在 `addons/sourcemod/scripting/`，例如 `plugins/extend/join.smx` 对应 `scripting/extend/join.sp`
* AnneHappy 专属定制源码放在 `addons/sourcemod/scripting/optional/AnneHappy/`，例如 `infected_control.sp` 的拆分模块放在 `addons/sourcemod/scripting/optional/AnneHappy/infected_control/`
* SourceMod 官方自带插件源码保留在 `addons/sourcemod/scripting/sourcemod/`，作为上游结构例外
* 使用 `scripts/spcomp-docker.sh` 编译时，不传第二个参数会按源码相对路径把 `.smx` 写回对应插件目录；发布 release 时也按这个规则重新编译并覆盖
* 仓库里没有 `.sp` 的旧二进制插件会在 release 时原样保留，不参与重新编译

---

## **重要内容**
* Anne 专属定制插件放到 `plugins/optional/AnneHappy`，源码位于 `scripting/optional/AnneHappy`；通用插件放到 `plugins/optional`，源码位于 `scripting/optional`
* 其中`plugins/extend`文件夹中的插件为电信服扩展所用，包括帽子、积分和商店娱乐等功能（默认启用）
* 本插件尽量在不影响Zonemod同步上游更新的基础进行更新（方便自己偷懒）
* 如果需要数据库，请使用项目里的database.sql创表，并且根据wiki里的文档进行数据库调优（尤其是服务器较多的情况）
* 正常情况下，请不要加载任何一个test插件文件夹内的插件，你加载一个文件夹内的一个插件，sourcemod的bug可能会把那个文件夹内的所有插件全部加载（感谢Harry提醒，我确实碰到这个问题）
* 对抗模式默认不开启mod，如果需要玩对抗请手动关闭mod
* 常规要加载的拓展插件放到 `plugins/extend` 文件夹，测试插件放到 `plugins/disabled/test` 文件夹，投票加载卸载和通用模式插件放到 `plugins/optional` 文件夹，Anne 专属定制插件放到 `plugins/optional/AnneHappy` 文件夹
---

## **已知问题:**
* 小刀为TLS更新前的原版小刀，正常对抗模式将不再刷新小刀，只有药役模式才会刷新小刀
* AnneHappy模式过关统计会把这一章节所有统计信息全部记录，因为对抗模式每回合不会清除统计信息（原来的方式不能正确载入对抗地图和对抗的梯子和nav）【我觉得这是Feature不是Bug，笑，反正普通信息mvp插件能够正常记录了，所以也不准备修改了】

## **无外部数据库版本:**
> Anne 的 MySQL 数据库不对外开放。自行部署时，请使用 `nomysql` 包，或者按项目内的 `database.sql` 和 Wiki 配置自己的数据库。

重新检查非 `disabled/` 的已发布插件后，共有 **18 个 `.smx` 直接调用 SourceMod 数据库 API**。`nomysql` 的处理口径如下：

* 保留 `l4d2_map_vote.smx` 和 `optional/AnneHappy/spawn_vote_menu.smx`：前者只用本地 SQLite，后者默认使用 `storage-local` SQLite
* 使用 `disabled/rpg.smx` 覆盖 `extend/rpg.smx`：插件路径和 cfg 加载项不变，但换成无数据库构建
* 删除其余 15 个直接访问外部数据库的插件，并额外删除 `sbpp_admcfg.smx`、`sbpp_report.smx` 和依赖积分时长数据的 `veterans.smx`
* 当前版和 2026-07 回滚版 `infected_control` 都通过可选的 `anne_traitor_quota.smx` 保存配额；`nomysql` 删除 provider 后，两个版本都会跳过持久化资格门槛并继续运行

因此，发布 workflow 只生成完整数据库包与 `nomysql` 包；当前完整包共有 **423 个 `.smx`**，`nomysql` 删除 **18 个**并替换 RPG 构建，最终保留 **405 个**。`disabled/` 下不会自动加载的 SourceMod SQL 管理插件不计入上述 18 个直接访问数据库的插件。

`nomysql` 删除的插件为：

```text
extend/l4d_stats.smx
extend/sbpp_admcfg.smx
extend/sbpp_checker.smx
extend/sbpp_comms.smx
extend/sbpp_main.smx
extend/sbpp_report.smx
extend/sbpp_sleuth.smx
extend/lilac.smx
extend/chatlog.smx
extend/veterans.smx
extend/l4d2_damage_show.smx
extend/l4d2_blacklist.smx
extend/l4d2_hitsound.smx
extend/l4d2_scripted_hud.smx
extend/global_chat.smx
extend/l4d_player_count_unload_mode.smx
optional/AnneHappy/annehappy_dynamic_ai_difficulty.smx
optional/AnneHappy/anne_traitor_quota.smx
```

`hextags_lite.smx`、`punch_angle.smx`、`l4d_hats.smx`、`l4d2_item_hint.smx` 和 `join.smx` 没有直接访问数据库，因此 `nomysql` 继续保留；其中依赖积分或 RPG 的附加功能以实际可用前置为准。

## **Issue 发起说明**
请先阅读完README-AnneHappy-zh-cn.md后再发起任何issue
发起issue请进来仔细描述问题，最好能提供错误的log和怎么复现的，拒绝无效Issue
	
## **感谢人员:**

> **Foundation/Advanced Work:**
* morzlee 本分支创建者及维护者
* Caibiiii 原分支创建者
* HoongDou 原分支创建者
* Moyu 原分支创建者

> **Additional Plugins/Extensions:**
* GlowingTree880 特感能力加强的巨大贡献者
* umlka 完美解决了coop_base_versus问题
* fdxx 使用了一部分fdxx的插件

> **Competitive Mapping Rework:**
* Derpduck, morzlee, Easy 地图修改

> **Testing/Issue Reporting:**
* Too many to list, keep up the great work in reporting issues!
* 所有电信服玩家，因为没有时间游玩测试，大部分bug都是由他们反馈给我

**注意事项:** 如果你的作品被使用了，而我却忘了归功于你，我真诚地向你道歉。 
我已经尽力将名单上的每个人都包括在内，只要创建一个问题，并说出你所制作/贡献的插件/扩展，我就会确保适当地记入你的名字。
