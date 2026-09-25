# 云5新版进度补药：57 张官图全量实测

本轮完成 c1–c14 全部 57 张官图逐图加载。43 张非救援图全部达到安全屋外药品上限 4 个，缺额为 0；14 张救援图按现有 `confogl_pills_flow_finale=0` 配置豁免补药，不属于强制达到 4 个的范围。

| 指标 | 结果 |
|---|---:|
| 完成地图 / 唯一地图 | 57 / 57 |
| 非救援图达到上限 | 43 / 43 |
| 非救援图缺药 | 0 |
| 救援图豁免 | 14 |
| 发生补刷的非救援图 | 32 |
| 新补药总数 | 103 |
| 新补药进度最小 / 最大 | 30.2% / 98.6% |
| 筛选后原生药为 0、全部补 4 的地图 | 15 |

本轮枚举时零原生药的非救援图为 `c5m1_waterfront` 和 `c13m1_alpinecreek`，均从 0 补到 4。`c13m2_southpinestream` 保留 1 个、补 3 个，最终 4 个，单次处理耗时 0.018 秒。全轮处理耗时最大为 `c14m1_junkyard` 的 3.571 秒。耗时包含枚举、原生药路线筛选、补药和物资限额处理，不包含切图、加载和网络等待。

筛选后原生药为 0 的 15 张图：`c1m1_hotel`、`c3m2_swamp`、`c3m3_shantytown`、`c4m2_sugarmill_a`、`c5m1_waterfront`、`c5m4_quarter`、`c6m1_riverbank`、`c8m1_apartment`、`c8m4_interior`、`c10m2_drainage`、`c11m2_offices`、`c11m4_terminal`、`c13m1_alpinecreek`、`c13m3_memorialbridge`、`c14m1_junkyard`。

## 方法与统计口径

云5（`anne1`）无人时临时设密码隔离。基于当前新版源码编译测量插件；临时将 ItemTracking 的自动 `round_start` 事件注册替换为服务端测试命令，避免地图加载时先处理一次。每张图只调用一次原有 `EnumAndElimSpawns`，原样执行 `EnumerateSpawns → ApplyPillFlowFilter → RemoveToLimits`；测量命令只重置 ItemTracking 的地图限额与安全屋计数，并在完成后检查记录中的实体仍有效且确为药品。57 张地图各有且仅有一条枚举入口和一条完成记录。

测试参数：`pills_limit=4`、`pills_flow_min=0.3`、`pills_flow_max=1`、`pills_flow_max_detour=300`、`pills_flow_fill=1`、补刷范围 `0.3–1.0`、`pills_flow_finale=0`。为了逐图重新枚举，测试使用 `itemtracking_savespawns=0`。通用与 AnneHappy 的 `mapinfo.txt` 均与本地工作树 SHA-256 一致。

地图全集与 `scripts/run_nav_wave_matrix.py` 的 `OFFICIAL_MAPS` 完全一致，救援标记与上一轮 14 张救援图一致。43 张非救援图均满足 `kept + filled == tracked == live == limit == 4`。每个补刷点日志进度都在 30%–100% 内，无短缺或路线检查跳过记录。

CSV 中 `raw` 为枚举到的安全屋外原生药数量；`kept` 为路线过滤后保留数量；`filled` 为新补数量；`live` 为处理结束后的有效药品实体数。救援关跳过过滤，`kept=0` 仅表示没有过滤保留日志，不能理解为原生药全被删除；应看 `live`。本轮 `c8m5_rooftop` 的安全屋外原生药和最终实体均为 0，属于救援豁免。

有 6 张非救援图共 10 个原生药点没有可用进度数据，按既有规则保留并占用限额：`c1m2_streets`、`c4m4_milltown_b`、`c7m2_barge`、`c8m3_sewers`、`c9m1_alleys`、`c12m2_traintunnel`。因此进度范围验收针对新补药点，不代表所有保留原生药都具有有效进度。

## 证据与恢复

- [逐图 CSV](pill_flow_cloud5_progress_full_2026-09-25.csv)
- [逐图原始 ItemTracking 日志与完成计数](pill_flow_cloud5_progress_full_2026-09-25.jsonl)
- [参数、源码/二进制哈希与恢复元数据](pill_flow_cloud5_progress_full_2026-09-25.meta.json)

运行时间为 2026-09-25 04:07:24–04:18:37 UTC。云5已恢复 `c2m1_highway`、原有全部测试相关 CVar、公开访问、插件加载锁和原插件；原插件运行状态正常，恢复前后文件 SHA-256 相同，恢复警告为空。临时二进制及远端备份已清理，本地源码与测试前完全一致。此次未发布新版到生产服务器。

结论适用于本轮每图一次随机加载：全部启用补药的官图均达到上限。没有进行多随机种子压力测试、真人拾取或双方回合一致性复测；测量二进制含临时观测命令，业务逻辑来自记录哈希对应的新版源码。
