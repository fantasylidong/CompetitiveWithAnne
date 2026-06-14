# 快速测试指南

## 🚀 启动测试

### 1. 编译插件
```bash
cd addons/sourcemod/scripting
./spcomp infected_control.sp -O2
```

如果编译成功，会生成 `infected_control.smx`

### 2. 加载调试配置
```
exec infected_control_debug.cfg
```

### 3. 重启插件
```
sm plugins reload infected_control
```

---

## 🔍 测试命令

### 查看波决策器状态
```
sm_wavestatus
```
输出示例：
```
[IC] 波决策器状态: TimerRunning
  波序号: 3
  已用时: 12.3秒
  特感: 4/6
  Anti-Bait: 放行 (state=2)
```

### 查看性能统计
```
sm_spawnperf
```

### 查看性能模式
```
sm_spawnperf_mode
```

---

## 📋 测试场景

### 场景1：正常推进测试
**操作**：
1. 开始游戏
2. 正常推进，保持分散队形
3. 观察日志输出

**预期结果**：
```
[WaveDecider] Wave started, enter EarlyCheck
[WaveDecider] Early trigger activated at 3.2s
[WaveDecider] State: EarlyCheck -> TimerRunning (early conditions met)
[WaveDecider] Start 16s timer (early conditions met)
... (16秒后)
[WaveDecider] Release wave: timer reached normally (elapsed=19.2s)
```

### 场景2：提前触发后卡位测试
**操作**：
1. 开始游戏
2. 推进一段后停下
3. 所有人聚集密集队形
4. 观察日志

**预期结果**：
```
[WaveDecider] Start 16s timer
[AB] Observe -> Pressure (team holding near spawn window)
[WaveDecider] Detected baiting at timer 8.3s, will enter intensive check after timer
... (继续等待到16秒)
[WaveDecider] State: TimerRunning -> IntensiveCheck (timer reached with baiting)
[WaveDecider] enter intensive check due to baiting
```

### 场景3：密集检测无限等待测试
**操作**：
1. 进入密集检测状态后
2. 持续卡位不推进
3. 观察是否会一直等待

**预期结果**：
```
[IC] IntensiveCheck state, waiting for progress...
... (玩家持续卡位，不刷新)
... (30秒后仍在等待)
... (直到玩家推进)
[AB] Pressure -> Recover (progress)
[WaveDecider] Release wave: anti-bait state changed
```

### 场景4：推进中队形密集测试（防误判）
**操作**：
1. 持续推进
2. 保持密集队形
3. 观察是否会被误判为卡位

**预期结果**：
```
[AB] State: Observe (not entering Pressure due to progress)
[WaveDecider] State: TimerRunning (needIntensiveCheck=false)
... (16秒后)
[WaveDecider] Release wave: timer reached normally
✅ 不会进入密集检测
```

---

## 🎯 关键日志关键词

### WaveDecider 日志
```
[WaveDecider] Wave started, enter EarlyCheck
[WaveDecider] Early trigger activated at X.Xs
[WaveDecider] Start Xs timer
[WaveDecider] State: X -> Y (reason)
[WaveDecider] Detected baiting at timer X.Xs
[WaveDecider] Baiting cleared at timer X.Xs
[WaveDecider] Timer reached, enter intensive check
[WaveDecider] Release wave: reason
```

### Anti-Bait 日志
```
[AB] Off -> Grace (reason)
[AB] Grace -> Observe (grace done)
[AB] Observe -> Pressure (reason)
[AB] Pressure -> Recover (progress/spread)
```

### 性能统计日志
```
[PerfStats] attempts=X success=Y filters=(flags:A dist:B vis:C bucket:D) fullEval=E avgTime=F.Fms
```

---

## ⚠️ 常见问题排查

### 问题1：看不到 [WaveDecider] 日志
**检查**：
```
inf_DebugMode 2  // 确保是 2
```

### 问题2：状态一直是 Idle
**检查**：
1. 生还者是否已离开安全屋
2. `sm_wavestatus` 查看详细状态
3. 是否有其他插件冲突

### 问题3：16秒定时器提前刷新了
**检查日志**：
- 应该看到 "timer reached normally" 或 "timer reached with baiting"
- 不应该看到 "cancel timer"

### 问题4：玩家一直跑但进入密集检测
**检查日志**：
- `[AB]` 日志应显示 Observe 或 Recover，不是 Pressure
- 如果错误进入 Pressure，说明 Anti-Bait 判断有问题

---

## 📊 测试数据收集

测试完成后，请提供：

1. **完整日志** - 从回合开始到第一次刷特的完整日志
2. **场景描述** - 你在做什么操作
3. **预期vs实际** - 你期望发生什么，实际发生了什么
4. **sm_wavestatus 输出** - 在关键时刻的状态快照

---

## 🔧 快速调整参数

### 如果8秒太短/太长
```
// 修改检查窗口（第4个值是专家难度）
inf_ai_wave_check_time "16.0 12.0 10.0 6.0 4.0"  // 改为6秒
```

### 如果Anti-Bait太敏感/不敏感
```
inf_antibait_window 15.0          // 增加到15秒（更不敏感）
inf_antibait_progress_pct 3       // 增加到3%（更不敏感）
```

### 如果想看更详细的输出
查看日志文件：
```
addons/sourcemod/logs/infected_control_fdxxnav.txt
```

---

## ✅ 测试通过标准

1. ✅ 正常推进16秒后刷新
2. ✅ 卡位时进入密集检测
3. ✅ 密集检测可以无限等待
4. ✅ 推进中不会被误判卡位
5. ✅ 16秒定时器不会被提前取消

---

祝测试顺利！有任何问题随时反馈！🎉
