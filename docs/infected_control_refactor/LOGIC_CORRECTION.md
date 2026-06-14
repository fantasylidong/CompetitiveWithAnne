# 刷特时序逻辑修正说明

## ❌ 之前的错误理解

### 错误1：定时器时长计算错误
```
误以为：NormalWait 持续 (16 - 8) = 8秒
实际：16秒是独立的倒计时，不是相对于 checkWindow 的
```

### 错误2：存在强制兜底机制
```
误以为：密集检测有超时，到达某个时间必须刷新
实际：只有 0-8秒有兜底，密集检测可以无限等待
```

### 错误3：状态机设计过于复杂
```
误以为：需要 5 个状态（Idle/EarlyCheck/NormalWait/IntensiveCheck/ForceRelease）
实际：只需要 4 个状态（Idle/EarlyCheck/TimerRunning/IntensiveCheck）
```

---

## ✅ 修正后的正确逻辑

### 完整时序图（专家难度16秒为例）

```
第0秒：刷特完成
  ↓
═══════════════════════════════════════════════════
【阶段1：EarlyCheck 提前检查窗口 0-8秒】
═══════════════════════════════════════════════════
  每秒检查条件：
  ├─ 特感数量低(IsLowSiPressure) AND
  ├─ 生还者状态好(IsSurvivorsHealthy) AND
  └─ 无坦克/团灭
  
  满足条件 → 开启16秒定时器 → 进入 TimerRunning
  ↓
  第8秒兜底 → 强制开启16秒定时器 → 进入 TimerRunning

═══════════════════════════════════════════════════
【阶段2：TimerRunning 定时器运行中 16秒倒计时】
═══════════════════════════════════════════════════
  每秒检查玩家行为：
  
  判断条件：
  ├─ 是否推进：!IsStalled()
  └─ 是否卡位：IsTeamHolding()
  
  场景分析：
  ┌──────────────┬──────────┬──────────────────┐
  │   玩家行为   │  是否卡位 │      处理逻辑      │
  ├──────────────┼──────────┼──────────────────┤
  │ 推进 + 无卡位 │    否    │ 继续等待16秒      │
  │ 推进 + 卡位   │    是    │ 取消定时器 → 密集 │
  │ 不推进+无卡位 │    否    │ 继续等待16秒(消耗)│
  │ 不推进+卡位   │    是    │ 取消定时器 → 密集 │
  └──────────────┴──────────┴──────────────────┘
  
  简化逻辑：
  if (isBaiting) → 取消定时器 → IntensiveCheck
  else → 继续等待
  ↓
  16秒到达 → 刷新特感 → 完成

═══════════════════════════════════════════════════
【阶段3：IntensiveCheck 密集检测 无时间限制】
═══════════════════════════════════════════════════
  每秒检查：
  ├─ 推进了？(!IsStalled()) → 刷新
  ├─ 分散了？(IsAttackableSpread()) → 刷新
  └─ 继续卡位 → 继续等待
  
  ⚠️ 注意：无超时兜底，可以无限等待！
```

---

## 🔑 关键修正点

### 1. 定时器的正确理解

**16秒定时器是独立计时的**：

```c
// ❌ 错误：相对于 waveStartTime 计算
if (waveElapsed >= interval) { ... }

// ✅ 正确：相对于 timerStartTime 计算
float timerElapsed = now - this.timerStartTime;
if (timerElapsed >= interval) { ... }
```

**示例时间轴**：
```
0秒：刷特完成，进入 EarlyCheck
3秒：条件满足，开启16秒定时器 (timerStartTime = 3秒)
19秒：定时器到达 (3 + 16 = 19秒)，刷新
```

### 2. 兜底机制的正确理解

**只有 EarlyCheck 阶段有兜底**：

```c
// ✅ EarlyCheck 阶段：8秒兜底
if (waveElapsed >= checkWindow) {
    this.StartSpawnTimer("check window floor reached");
}

// ✅ IntensiveCheck 阶段：无兜底，可以无限等
// 没有类似这样的代码：
// if (intensiveElapsed >= maxTime) { ... }
```

### 3. 状态转换的正确理解

```
Idle
  ↓ 刷特开始
EarlyCheck (0-8秒)
  ├→ 条件满足 → TimerRunning
  └→ 8秒兜底 → TimerRunning
  
TimerRunning (16秒倒计时)
  ├→ 16秒到达 → Idle (刷新)
  └→ 检测到卡位 → IntensiveCheck
  
IntensiveCheck (密集检测)
  ├→ 推进 → Idle (刷新)
  ├→ 分散 → Idle (刷新)
  └→ 继续卡位 → 保持 IntensiveCheck (无限等待)
```

---

## 🛡️ 防止误判卡位的措施

### 问题：玩家一直跑，但被误判为卡位

**原因分析**：
- `AntiBait_IsTeamHolding()` 只检查队形密集程度
- 没有同时检查推进状态

**解决方案**：

#### 方案1：在 TimerRunning 阶段同时检查推进和卡位

```c
void UpdateTimerRunning(float now, float waveElapsed)
{
    // ... 定时器检查 ...
    
    bool isProgressing = !AntiBait_IsStalled();  // 是否在推进
    bool isBaiting = AntiBait_IsTeamHolding();   // 是否密集队形
    
    // ✅ 修正：只有"密集且停滞"才取消定时器
    if (isBaiting && !isProgressing)
    {
        this.TransitionTo(WD_IntensiveCheck, "baiting: holding + stalled");
    }
    
    // 如果推进中，即使队形密集也继续等待定时器
}
```

#### 方案2：使用 Anti-Bait 的压力状态

```c
void UpdateTimerRunning(float now, float waveElapsed)
{
    // ... 定时器检查 ...
    
    // ✅ 使用 Anti-Bait 的 Pressure 状态（它已经综合判断了）
    if (gAB.state == AB_Pressure)
    {
        this.TransitionTo(WD_IntensiveCheck, "anti-bait pressure state");
    }
}
```

**推荐使用方案2**，因为 Anti-Bait 已经有完整的状态机，包含：
- Grace 期（8秒）
- Observe 期（监控推进）
- Pressure 期（停滞+密集）
- Recover 期（恢复）

---

## 📊 修正后的代码逻辑

### UpdateTimerRunning 修正版

```c
void UpdateTimerRunning(float now, float waveElapsed)
{
    float timerElapsed = now - this.timerStartTime;
    float interval = DifficultyStrategy_GetConfiguredWaveDelay();

    // 检查定时器是否到达
    if (timerElapsed >= interval)
    {
        // 16秒到达，正常刷新
        this.ReleaseWave("timer reached");
        return;
    }

    // ✅ 方案2：使用 Anti-Bait 的压力状态
    if (gAB.state == AB_Pressure)
    {
        // 进入 Pressure 说明：停滞时间够长 + 队形密集
        this.TransitionTo(WD_IntensiveCheck, "anti-bait pressure");
        WaveDecider_Debug("Timer canceled at %.1fs due to AB_Pressure", timerElapsed);
        return;
    }

    // 否则继续等待定时器
}
```

### UpdateIntensiveCheck 修正版

```c
void UpdateIntensiveCheck(float now, float waveElapsed)
{
    // ✅ 无超时兜底

    // 检查 Anti-Bait 状态变化
    if (gAB.state == AB_Recover || gAB.state == AB_Observe)
    {
        // 退出 Pressure 状态，说明玩家推进了或分散了
        this.ReleaseWave("anti-bait state changed");
        return;
    }

    // ✅ 继续在 Pressure 状态，继续等待（无限期）
    this.intensiveCheckCount++;
}
```

---

## 🧪 测试场景

### 场景1：正常推进无卡位
```
0秒：刷特完成
5秒：条件满足，开启16秒定时器
6-20秒：玩家正常推进，队形分散
21秒：定时器到达，刷新 ✅
```

### 场景2：推进中队形密集但不卡位
```
0秒：刷特完成
3秒：条件满足，开启16秒定时器
4-18秒：玩家推进中，但队形很密集
  → Anti-Bait 处于 Grace/Observe，不进入 Pressure
  → WaveDecider 继续等待定时器
19秒：定时器到达，刷新 ✅
```

### 场景3：停滞且密集卡位
```
0秒：刷特完成
8秒：兜底，开启16秒定时器
12秒：玩家停止推进，队形密集
  → Anti-Bait 进入 Pressure
  → WaveDecider 取消定时器，进入密集检测
13-60秒：继续卡位
  → 一直在密集检测，不刷新 ✅
61秒：玩家推进
  → Anti-Bait 进入 Recover
  → WaveDecider 刷新 ✅
```

### 场景4：不推进但分散
```
0秒：刷特完成
8秒：兜底，开启16秒定时器
15秒：玩家停止推进，但队形分散
  → Anti-Bait 进入 Pressure（根据修正后的逻辑）
  → WaveDecider 取消定时器，进入密集检测
16秒：检测到分散
  → 刷新（消耗状态）✅
```

---

## ✅ 总结

修正的核心点：

1. **16秒定时器独立计时**，不是相对波开始时间
2. **只有0-8秒有兜底**，密集检测无超时
3. **防止误判**：使用 Anti-Bait 的 Pressure 状态而非单纯检查队形
4. **状态精简**：4个状态足够，不需要 ForceRelease

这样设计后：
- ✅ 玩家正常推进不会被误判卡位
- ✅ 玩家恶意卡位可以无限拦截
- ✅ 兜底机制只在必要时触发（0-8秒）
