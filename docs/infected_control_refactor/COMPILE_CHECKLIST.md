# 编译前检查清单

## ✅ 文件清单

### 必需的新文件（请确认存在）
- [ ] `infected_control/wave_decider.inc`
- [ ] `infected_control/spawn_perf_optimizer.inc`
- [ ] `infected_control/spawn_perf_config.inc`

### 修改的文件
- [ ] `infected_control.sp`
- [ ] `infected_control/wave_control.inc`
- [ ] `infected_control/anti_baiter.inc`
- [ ] `infected_control/config.inc`

### 配置文件
- [ ] `infected_control_debug.cfg` (在仓库根目录)

### 文档
- [ ] `FINAL_LOGIC_EXPLANATION.md`
- [ ] `TESTING_GUIDE.md`
- [ ] `INTEGRATION_GUIDE.md`
- [ ] `REFACTOR_SUMMARY.md`
- [ ] `PERFORMANCE_OPTIMIZATION.md`

---

## 🔧 编译步骤

### 1. 检查编译器
```bash
cd addons/sourcemod/scripting
ls spcomp
```

### 2. 编译插件
```bash
./spcomp infected_control.sp -O2
```

### 3. 检查编译输出
**成功输出示例**：
```
SourcePawn Compiler 1.10.xxxx
Compilation was successful.
Code size:           XXXXX bytes
Data size:           XXXXX bytes
Stack/heap size:     XXXXX bytes
Total requirements:  XXXXX bytes
```

**如果有警告**：
- Warning 表示编译成功但有警告（通常可以忽略）
- Error 表示编译失败，需要修复

---

## 🐛 常见编译错误

### 错误1: undefined symbol "WaveDecider_OnWaveStart"
**原因**：wave_decider.inc 未正确包含
**解决**：检查 infected_control.sp 是否有这一行：
```c
#include "infected_control/wave_decider.inc"
```

### 错误2: undefined symbol "SpawnPerf_OnRoundStart"
**原因**：性能优化模块未正确包含
**解决**：检查是否包含：
```c
#include "infected_control/spawn_perf_optimizer.inc"
#include "infected_control/spawn_perf_config.inc"
```

### 错误3: undefined symbol "AntiBait_IsStalled"
**原因**：anti_baiter.inc 缺少新增的函数
**解决**：确认 anti_baiter.inc 包含这些新增函数：
```c
stock bool AntiBait_IsStalled()
stock bool AntiBait_IsTeamHolding()
stock bool AntiBait_IsAttackableSpread()
```

### 错误4: tag mismatch
**原因**：类型不匹配
**解决**：检查具体的行号和变量类型

---

## ✅ 编译成功后

### 1. 复制插件
```bash
cp infected_control.smx ../plugins/optional/AnneHappy/
```

### 2. 加载调试配置
在服务器控制台或 server.cfg 中添加：
```
exec infected_control_debug.cfg
```

### 3. 重载插件
```
sm plugins reload infected_control
```

### 4. 验证加载
```
sm plugins list | grep infected
```
应该显示：
```
[XXX] "Direct InfectedSpawn" (2025.10.26) by 东, Caibiii, ...
```

---

## 🎯 快速测试

### 立即验证功能
```
sm_wavestatus    // 应该显示状态（如果未开始会提示"尚未启动"）
sm_spawnperf     // 应该显示"已输出性能统计"
```

### 开始游戏测试
1. 创建本地服务器或进入测试服务器
2. 开始战役
3. 离开安全屋
4. 输入 `sm_wavestatus` 查看状态
5. 观察控制台和日志输出

---

## 📝 测试日志位置

日志文件：
```
addons/sourcemod/logs/infected_control_fdxxnav.txt
```

实时查看日志（Linux）：
```bash
tail -f addons/sourcemod/logs/infected_control_fdxxnav.txt
```

---

## 🔄 如果需要回滚

### 快速回滚
```bash
git checkout HEAD~1 infected_control.sp
git checkout HEAD~1 infected_control/wave_control.inc
git checkout HEAD~1 infected_control/anti_baiter.inc
git checkout HEAD~1 infected_control/config.inc
```

### 删除新文件
```bash
rm infected_control/wave_decider.inc
rm infected_control/spawn_perf_optimizer.inc
rm infected_control/spawn_perf_config.inc
```

### 重新编译
```bash
./spcomp infected_control.sp -O2
```

---

## 📞 需要帮助？

如果编译失败，请提供：
1. **完整的编译输出**（从开始到结束）
2. **错误行号**和**错误信息**
3. **你的 SourceMod 版本**（`sm version`）

我会帮你解决！

---

## ✨ 编译成功后的下一步

1. 按照 `TESTING_GUIDE.md` 进行测试
2. 重点测试4个场景（见测试指南）
3. 收集测试数据和日志
4. 根据实际效果调整参数

祝编译顺利！🚀
