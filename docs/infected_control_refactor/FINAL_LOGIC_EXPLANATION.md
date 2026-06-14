# 最终刷特逻辑说明（已确认正确）

## 🎯 核心原则

### 关键约束
1. **16秒定时器是刚性时间** - 开启后必须等满16秒，不能提前取消
2. **只有0-8秒有兜底** - 其他阶段无超时，可以无限等待
3. **防止误判推进** - 玩家一直跑不能被判定为卡位

---

## ✅ 完整时序逻辑（专家难度16秒为例）

```
═══════════════════════════════════════════════════════════════
第0秒：刷特完成，进入 EarlyCheck
═══════════════════════════════════════════════════════════════

【阶段1：EarlyCheck 提前检查窗口 0-8秒】

每秒检查提前触发条件：
  ├─ 特感数量过低 (DifficultyStrategy_IsLowSiPressure)
  ├─ 生还者状态良好 (WaveDecider_IsSurvivorsHealthy)  
  └─ 无坦克/团灭 (!IsAnyTankOrAboveHalfSurvivorDownOrDied)

场景A：第3秒条件满足
  → 开启16秒定时器 (timerStartTime = 3秒)
  → 进入 TimerRunning
  → 第19秒 (3+16) 定时器到达

场景B：第8秒兜底
  → 强制开启16秒定时器 (timerStartTime = 8秒)
  → 进入 TimerRunning
  → 第24秒 (8+16) 定时器到达

═══════════════════════════════════════════════════════════════
【阶段2：TimerRunning 定时器运行中 0-16秒（刚性时间）】
═══════════════════════════════════════════════════════════════

⚠️ 关键：定时器不能被取消，只能打标记

每秒监控玩家行为：
  ├─ 检查 Anti-Bait 状态 (gAB.state == AB_Pressure?)
  │  ├─ 是 Pressure → 标记 needIntensiveCheck = true
  │  └─ 非 Pressure → 标记 needIntensiveCheck = false
  │
  └─ 等待定时器到达...

16秒到达时：
  ├─ needIntensiveCheck == false → 正常刷新
  └─ needIntensiveCheck == true → 进入 IntensiveCheck

═══════════════════════════════════════════════════════════════
【阶段3：IntensiveCheck 密集检测（无时间限制）】
═══════════════════════════════════════════════════════════════

⚠️ 关键：无超时兜底，可以无限等待

每秒检查 Anti-Bait 状态：
  ├─ 退出 Pressure 状态 (AB_Recover/AB_Observe) → 刷新
  │  └─ 说明玩家推进了或分散了
  │
  └─ 继续 Pressure 状态 → 继续等待
     └─ 玩家还在卡位，不刷新
```

---

## 📊 时间轴示例

### 示例1：提前触发 + 正常推进

```
时间 | 状态           | 事件                           | needIntensiveCheck
-----|---------------|--------------------------------|-------------------
0秒  | EarlyCheck    | 刷特完成                       | false
3秒  | → TimerRunning| 条件满足，开启16秒定时器       | false
5秒  | TimerRunning  | 玩家正常推进，AB_Observe       | false
10秒 | TimerRunning  | 玩家继续推进                   | false
15秒 | TimerRunning  | 玩家继续推进                   | false
19秒 | → Idle        | 定时器到达，正常刷新 ✅        | -
```

### 示例2：提前触发 + 途中卡位 + 16秒后密集检测

```
时间 | 状态           | 事件                           | needIntensiveCheck
-----|---------------|--------------------------------|-------------------
0秒  | EarlyCheck    | 刷特完成                       | false
3秒  | → TimerRunning| 条件满足，开启16秒定时器       | false
5秒  | TimerRunning  | 玩家正常推进                   | false
10秒 | TimerRunning  | 玩家停止+密集 → AB_Pressure    | → true ⚠️
15秒 | TimerRunning  | 玩家继续卡位                   | true
19秒 | → IntensiveCheck | 定时器到达，进入密集检测    | -
20秒 | IntensiveCheck| 玩家继续卡位，不刷新           | -
30秒 | IntensiveCheck| 玩家继续卡位，不刷新           | -
45秒 | IntensiveCheck| 玩家推进 → AB_Recover          | -
45秒 | → Idle        | 刷新 ✅                        | -
```

### 示例3：兜底触发 + 持续推进

```
时间 | 状态           | 事件                           | needIntensiveCheck
-----|---------------|--------------------------------|-------------------
0秒  | EarlyCheck    | 刷特完成                       | false
1-7秒| EarlyCheck    | 条件不满足                     | false
8秒  | → TimerRunning| 兜底触发，开启16秒定时器       | false
10秒 | TimerRunning  | 玩家正常推进                   | false
20秒 | TimerRunning  | 玩家继续推进                   | false
24秒 | → Idle        | 定时器到达，正常刷新 ✅        | -
```

### 示例4：卡位后恢复再卡位（标记会更新）

```
时间 | 状态           | 事件                           | needIntensiveCheck
-----|---------------|--------------------------------|-------------------
0秒  | EarlyCheck    | 刷特完成                       | false
8秒  | → TimerRunning| 兜底，开启16秒定时器           | false
10秒 | TimerRunning  | 玩家卡位 → AB_Pressure         | → true
15秒 | TimerRunning  | 玩家推进 → AB_Recover          | → false ✅
20秒 | TimerRunning  | 玩家又卡位 → AB_Pressure       | → true
24秒 | → IntensiveCheck | 定时器到达，进入密集检测    | -
25秒 | IntensiveCheck| 玩家推进 → AB_Recover          | -
25秒 | → Idle        | 刷新 ✅                        | -
```

---

## 🔑 关键代码逻辑

### UpdateTimerRunning（核心修正）

```c
void UpdateTimerRunning(float now, float waveElapsed)
{
    float timerElapsed = now - this.timerStartTime;
    float interval = DifficultyStrategy_GetConfiguredWaveDelay();

    // ✅ 监控玩家行为，打标记（不取消定时器）
    if (gAB.state == AB_Pressure)
    {
        if (!this.needIntensiveCheck)
        {
            this.needIntensiveCheck = true;
            Debug("Detected baiting, mark for intensive check");
        }
    }
    else
    {
        if (this.needIntensiveCheck)
        {
            this.needIntensiveCheck = false;
            Debug("Baiting cleared, will spawn normally");
        }
    }

    // ✅ 等待刚性16秒到达
    if (timerElapsed >= interval)
    {
        if (this.needIntensiveCheck)
        {
            // 期间检测到卡位，进入密集检测
            this.TransitionTo(WD_IntensiveCheck, "timer reached with baiting");
        }
        else
        {
            // 期间正常，直接刷新
            this.ReleaseWave("timer reached normally");
        }
    }
}
```

### UpdateIntensiveCheck（无超时）

```c
void UpdateIntensiveCheck(float now, float waveElapsed)
{
    // ✅ 检查 Anti-Bait 状态变化
    if (gAB.state == AB_Recover || gAB.state == AB_Observe)
    {
        // 退出 Pressure，说明推进或分散了
        this.ReleaseWave("anti-bait state changed");
        return;
    }

    // ✅ 继续 Pressure，继续等待（无超时）
    this.intensiveCheckCount++;
}
```

---

## 🛡️ 防止误判的机制

### 问题：玩家一直跑但队形密集被误判

**解决方案**：使用 Anti-Bait 的状态机

Anti-Bait 进入 Pressure 的条件：
```c
bool stalled = (now - gAB.lastProgressTime) >= gCV.fAntiBaitWindow;  // 停滞12秒
bool hasEnoughSI = AntiBait_HasEnoughSiPressure();  // 特感压力够
bool holding = gAB.teamHolding;  // 队形密集

// 只有同时满足才进入 Pressure
if (stalled && hasEnoughSI && holding)
    AntiBait_SetState(AB_Pressure, ...);
```

关键点：
- `stalled` 检查推进进度，一直跑不会满足
- 即使队形密集，只要在推进就不会进入 Pressure
- WaveDecider 只看 `gAB.state == AB_Pressure`，不单独判断

---

## ✅ 逻辑验证

### 验证点1：16秒刚性时间
✅ 定时器开启后，只监控不取消，必须等满16秒

### 验证点2：卡位判断准确
✅ 使用 Anti-Bait 的 Pressure 状态，综合判断停滞+密集

### 验证点3：推进不被误判
✅ Anti-Bait 检查 lastProgressTime，持续推进不会进入 Pressure

### 验证点4：密集检测无超时
✅ IntensiveCheck 只检查状态变化，无时间兜底

### 验证点5：标记可以动态更新
✅ needIntensiveCheck 每秒根据 AB 状态更新

---

## 📋 状态转换图

```
Idle
  ↓ 刷特完成
EarlyCheck (0-8秒)
  ├→ 条件满足 → TimerRunning（开启16秒定时器）
  └→ 8秒兜底 → TimerRunning（开启16秒定时器）

TimerRunning (16秒倒计时 - 刚性)
  每秒更新 needIntensiveCheck 标记
  ↓ 16秒到达
  ├→ needIntensiveCheck == false → Idle（刷新）
  └→ needIntensiveCheck == true → IntensiveCheck

IntensiveCheck (密集检测 - 无限)
  ├→ AB状态退出Pressure → Idle（刷新）
  └→ AB继续Pressure → 保持 IntensiveCheck
```

---

## 🎉 总结

修正后的逻辑完全符合你的设计：

1. ✅ **16秒刚性时间** - 不能提前取消，只能打标记
2. ✅ **只有0-8秒兜底** - 密集检测可以无限等
3. ✅ **防止误判推进** - 依赖 Anti-Bait 状态机
4. ✅ **标记动态更新** - 玩家行为变化会实时反映

代码已完全按此逻辑修正，可以放心使用！
