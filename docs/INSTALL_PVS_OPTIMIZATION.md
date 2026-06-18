# leftdhooks PVS 优化 - 快速安装指南

## 前置要求

- ✅ **leftdhooks 1.150+**（必需，否则优化失效）
- ✅ SourceMod 1.10+
- ✅ L4D2 服务器

## 安装步骤

### 1. 检查 leftdhooks 版本

```bash
# 查看服务器日志或使用命令
sm plugins list

# 确认 leftdhooks 版本 >= 1.150
```

如果版本不足，请先升级 leftdhooks：
- 下载：https://github.com/left4dead2/left4dhooks/releases
- 安装最新版本

### 2. 编译插件

```bash
cd addons/sourcemod/scripting/optional/AnneHappy
spcomp infected_control.sp -o ../../../plugins/infected_control.smx
```

编译应该成功，如果有错误请检查：
- 是否包含了所有 `.inc` 文件
- `leftdhooks.inc` 是否为最新版本

### 3. 上传文件

将以下文件上传到服务器：

```
addons/sourcemod/plugins/infected_control.smx
addons/sourcemod/scripting/optional/AnneHappy/infected_control/*.inc
cfg/infected_control_pvs_optimized.cfg
```

### 4. 配置服务器

在 `server.cfg` 或启动配置中添加：

```cfg
// 加载 PVS 优化配置
exec infected_control_pvs_optimized.cfg
```

或者手动添加最小配置：

```cfg
// 启用 PVS 优化
inf_spawn_navarea_vis_filter "1"
inf_spawn_pvs_bucket_filter "1"
inf_spawn_perf_stats "1"
```

### 5. 重启服务器

```bash
# 重启服务器或换图
changelevel c2m1_highway
```

### 6. 验证安装

#### 方法 1：查看启动日志

在服务器控制台或日志文件中查找：

```
[IC-PVS] leftdhooks PVS natives available: PVS=YES NavAreaVis=YES
```

✅ 如果看到这行，说明优化已启用  
❌ 如果看到 "NOT available"，说明 leftdhooks 版本不足

#### 方法 2：回合结束统计

游戏结束后，查看日志：

```
[IC-PVS] Performance stats:
  Buckets filtered by PVS: 234
  NavAreas filtered by visibility: 1,523
```

如果有数据输出，说明优化正在工作。

#### 方法 3：性能命令

在游戏中使用管理员命令：

```
sm_spawnperf_mode
```

应该显示：

```
[IC] 当前刷点性能模式: 平衡模式 (0)
  渐进式采样: 关闭
  自适应桶窗口: 关闭
  早期距离过滤: 关闭
  NavArea可见性过滤: 开启  ← 应该是"开启"
  PVS桶预筛: 开启  ← 应该是"开启"
```

## 快速配置方案

### 方案 A：最大性能（推荐）

```cfg
inf_spawn_navarea_vis_filter "1"
inf_spawn_pvs_bucket_filter "1"
inf_spawn_perf_mode "0"  // 平衡模式
inf_spawn_perf_stats "1"  // 首次使用建议开启
```

### 方案 B：最高质量

```cfg
inf_spawn_navarea_vis_filter "1"
inf_spawn_pvs_bucket_filter "1"
inf_spawn_perf_mode "2"  // 质量模式
inf_spawn_score_floor "30.0"  // 降低评分下限
```

### 方案 C：保守模式（兼容性优先）

```cfg
inf_spawn_navarea_vis_filter "0"  // 关闭 NavArea 过滤
inf_spawn_pvs_bucket_filter "1"   // 仅使用桶预筛
inf_spawn_perf_mode "0"
```

## 常见问题

### Q: 如何知道优化是否生效？

**A:** 三种方法：

1. **查看启动日志** - 应该显示 "PVS=YES NavAreaVis=YES"
2. **对比刷特延迟** - 使用 `sm_spawnperf` 查看统计
3. **观察服务器性能** - TPS 应该更稳定，Tick 波动更小

### Q: leftdhooks 版本不足怎么办？

**A:** 有两个选择：

1. **升级 leftdhooks**（推荐）- 下载最新版本并安装
2. **使用旧版本** - 插件会自动回退到传统方法，不会报错

### Q: 刷点质量变差了？

**A:** 尝试以下方案：

```cfg
// 1. 关闭 NavArea 可见性过滤
inf_spawn_navarea_vis_filter "0"

// 2. 降低评分下限
inf_spawn_score_floor "30.0"

// 3. 使用质量模式
inf_spawn_perf_mode "2"
```

如果问题仍然存在，请在 GitHub 提交 issue。

### Q: 性能没有改善？

**A:** 检查清单：

- [ ] leftdhooks 版本 >= 1.150
- [ ] 两个优化选项都开启
- [ ] 启动日志显示 natives 可用
- [ ] 开启统计查看是否有过滤数据

如果以上都正常但性能仍然不佳，可能是其他瓶颈（CPU、网络等）。

### Q: 如何回滚到旧版本？

**A:** 简单方法：

```cfg
// 关闭 PVS 优化
inf_spawn_navarea_vis_filter "0"
inf_spawn_pvs_bucket_filter "0"
```

插件会自动使用传统方法。

或者重新编译旧版本代码。

## 性能测试

### 测试方法

1. 开启统计：
   ```
   inf_spawn_perf_stats "1"
   inf_DebugMode "1"
   ```

2. 玩一局完整游戏

3. 查看日志文件：
   ```
   addons/sourcemod/logs/infected_control_fdxxnav.txt
   ```

4. 对比优化前后的数据

### 预期结果

| 指标 | 优化前 | 优化后 | 改善 |
|------|--------|--------|------|
| 平均刷点延迟 | 12-18ms | 4-7ms | 60-70% ↓ |
| NavArea 评估 | 200-400 个 | 60-120 个 | 60-70% ↓ |
| 可见性检测 | 150-300 次 | 20-50 次 | 80-85% ↓ |
| 候选点质量 | 5-8 个 | 12 个 | 50-140% ↑ |

## 技术支持

### 日志收集

如果遇到问题，请提供以下信息：

1. **服务器环境：**
   - leftdhooks 版本
   - SourceMod 版本
   - 地图名称
   - 玩家人数

2. **启动日志：**
   ```
   [IC-PVS] leftdhooks PVS natives available: ...
   ```

3. **性能统计：**
   ```
   [IC-PVS] Performance stats: ...
   ```

4. **Debug 日志：**（如果开启了 `inf_DebugMode "1"`）
   ```
   addons/sourcemod/logs/infected_control_fdxxnav.txt
   ```

### 反馈渠道

- GitHub Issues: https://github.com/fantasylidong/CompetitiveWithAnne/issues
- 论坛帖子：（如有）

## 更多信息

- 详细说明：[LEFTDHOOKS_PVS_OPTIMIZATION.md](./addons/sourcemod/scripting/optional/AnneHappy/LEFTDHOOKS_PVS_OPTIMIZATION.md)
- 更新日志：[CHANGELOG_PVS_OPTIMIZATION.md](./CHANGELOG_PVS_OPTIMIZATION.md)
- 配置文件：[infected_control_pvs_optimized.cfg](./cfg/infected_control_pvs_optimized.cfg)

---

**祝你游戏愉快！** 🎮
