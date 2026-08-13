#if defined _infected_control_wave_decider_included
    #endinput
#endif
#define _infected_control_wave_decider_included

/**
 * Wave Decider - 波决策器
 *
 * 负责管理整个刷特时序决策流程：
 * 1. 提前检查窗口（0-checkWindow秒）
 * 2. 正常等待窗口（checkWindow-interval秒）
 * 3. 16 秒倒计时到点时，由 Anti-Bait 决定正常放行或进入延长
 * 4. 延长阶段没有超时；队伍推进或稳定散开后立即恢复刷特
 */

enum WaveDecisionState
{
    WD_Idle = 0,           // 空闲：没有活跃波
    WD_EarlyCheck,         // 提前检查：0-checkWindow 秒，评估是否提前触发
    WD_TimerRunning,       // 定时器运行中：16秒倒计时，监控玩家行为
    WD_IntensiveCheck      // Anti-Bait 延长：无超时，条件稳定解除后放行
}

enum struct WaveDecider
{
    WaveDecisionState state;
    float waveStartTime;       // 本波开始时间
    float stateStartTime;      // 当前状态开始时间
    float timerStartTime;      // 16秒定时器开始时间
    float pauseStartedAt;      // 暂停期间冻结全部波次时钟
    bool earlyTriggered;       // 是否已触发提前机制
    bool pressureObserved;     // 定时器运行期间是否观察到破点压力
    float holdReleaseSince;    // 延长条件首次解除的时间
    int earlyCheckCount;       // 提前检查次数（用于调试）
    int intensiveCheckCount;   // 密集检测次数（用于调试）

    void OnWaveStart()
    {
        float now = GetGameTime();
        this.state = WD_EarlyCheck;
        this.waveStartTime = now;
        this.stateStartTime = now;
        this.timerStartTime = 0.0;
        this.pauseStartedAt = 0.0;
        this.earlyTriggered = false;
        this.pressureObserved = false;
        this.holdReleaseSince = 0.0;
        this.earlyCheckCount = 0;
        this.intensiveCheckCount = 0;

        WaveDecider_Debug("Wave started, enter EarlyCheck");
    }

    void Reset()
    {
        this.state = WD_Idle;
        this.waveStartTime = 0.0;
        this.stateStartTime = 0.0;
        this.timerStartTime = 0.0;
        this.pauseStartedAt = 0.0;
        this.earlyTriggered = false;
        this.pressureObserved = false;
        this.holdReleaseSince = 0.0;
        this.earlyCheckCount = 0;
        this.intensiveCheckCount = 0;
    }

    void TransitionTo(WaveDecisionState newState, const char[] reason)
    {
        if (this.state == newState)
            return;

        WaveDecisionState oldState = this.state;
        this.state = newState;
        this.stateStartTime = GetGameTime();

        char oldStateName[32], newStateName[32];
        WaveDecider_GetStateName(oldState, oldStateName, sizeof(oldStateName));
        WaveDecider_GetStateName(newState, newStateName, sizeof(newStateName));
        WaveDecider_Debug("State: %s -> %s (%s)", oldStateName, newStateName, reason);
    }

    void OnPause()
    {
        if (this.state != WD_Idle && this.pauseStartedAt <= 0.0)
            this.pauseStartedAt = GetGameTime();
    }

    void OnUnpause()
    {
        if (this.pauseStartedAt <= 0.0)
            return;

        float pausedFor = FloatMax(0.0, GetGameTime() - this.pauseStartedAt);
        this.waveStartTime += pausedFor;
        this.stateStartTime += pausedFor;
        if (this.timerStartTime > 0.0)
            this.timerStartTime += pausedFor;
        if (this.holdReleaseSince > 0.0)
            this.holdReleaseSince += pausedFor;
        this.pauseStartedAt = 0.0;
    }

    // 每秒调用一次的更新函数
    void Update()
    {
        if (this.state == WD_Idle)
            return;

        float now = GetGameTime();
        float waveElapsed = now - this.waveStartTime;

        switch (this.state)
        {
            case WD_EarlyCheck:
            {
                this.UpdateEarlyCheck(waveElapsed);
            }
            case WD_TimerRunning:
            {
                this.UpdateTimerRunning(now);
            }
            case WD_IntensiveCheck:
            {
                this.UpdateIntensiveCheck();
            }
        }
    }

    void UpdateEarlyCheck(float waveElapsed)
    {
        float checkWindow = DifficultyStrategy_GetWaveCheckDelay();

        // 提前触发条件检查
        if (!this.earlyTriggered && this.ShouldEarlyTrigger())
        {
            this.earlyTriggered = true;
            this.StartSpawnTimer("early conditions met");
            return;
        }

        // 检查是否到达兜底时间（checkWindow秒）
        if (waveElapsed >= checkWindow)
        {
            // 兜底：强制开启16秒定时器
            this.StartSpawnTimer("check window floor reached");
            return;
        }

        this.earlyCheckCount++;
    }

    void UpdateTimerRunning(float now)
    {
        float timerElapsed = now - this.timerStartTime;
        float interval = DifficultyStrategy_GetConfiguredWaveDelay();
        float remaining = interval - timerElapsed;
        Traitor_UpdateSpawnLockedCountdown(remaining);

        // 16 秒倒计时本身不可提前结束；Pressure 只决定到点后是否延长。

        // 检查是否进入卡位状态
        if (AntiBait_ShouldPrepareBreachWave())
        {
            if (!this.pressureObserved)
            {
                this.pressureObserved = true;
                WaveDecider_Debug("Detected baiting at timer %.1fs, prepare breach wave at deadline", timerElapsed);
            }
        }
        else
        {
            if (this.pressureObserved)
            {
                this.pressureObserved = false;
                WaveDecider_Debug("Baiting cleared at timer %.1fs, will spawn normally", timerElapsed);
            }
        }

        // 检查定时器是否到达（刚性16秒）
        if (timerElapsed >= interval)
        {
            // 根据标记决定走向
            if (this.pressureObserved)
            {
                if (AntiBait_ShouldHoldWave())
                {
                    this.holdReleaseSince = 0.0;
                    this.TransitionTo(WD_IntensiveCheck, "timer reached with stable holding pressure");
                    Traitor_OnAntiBaitHoldStarted();
                    WaveSpawnReport_RecordAntiBaitHoldStart(now);
                    return;
                }

                // 分散停滞等 Pressure 仍可生成破点波，但不会无限延长。
                this.ReleaseWave("timer reached with attackable pressure");
            }
            else
            {
                // 定时器期间正常，直接刷新
                this.ReleaseWave("timer reached normally");
            }
        }
    }

    void UpdateIntensiveCheck()
    {
        float now = GetGameTime();
        if (!AntiBait_ShouldReleaseFromIntensive())
        {
            this.holdReleaseSince = 0.0;
            this.intensiveCheckCount++;
            return;
        }

        if (this.holdReleaseSince <= 0.0)
        {
            this.holdReleaseSince = now;
            WaveSpawnReport_RecordAntiBaitHoldClearCandidate(now);
            if (gCV.fAntiBaitReleaseConfirm > 0.0)
            {
                this.intensiveCheckCount++;
                return;
            }
        }

        if ((now - this.holdReleaseSince) < gCV.fAntiBaitReleaseConfirm)
        {
            this.intensiveCheckCount++;
            return;
        }

        WaveSpawnReport_RecordAntiBaitHoldEnd(now);
        this.ReleaseWave("anti-bait hold cleared");
    }

    void StartSpawnTimer(const char[] reason)
    {
        float now = GetGameTime();
        this.timerStartTime = now;
        this.TransitionTo(WD_TimerRunning, reason);
        Traitor_OnFinalRefreshStarted();
        WaveSpawnReport_RecordCountdownStart(now, reason);

        float interval = DifficultyStrategy_GetConfiguredWaveDelay();
        Traitor_UpdateSpawnLockedCountdown(interval);
        WaveDecider_Debug("Start %0.fs timer (%s)", interval, reason);
    }

    bool ShouldEarlyTrigger()
    {
        // 普通波尚未完成实际生成时，totalSI 可能暂时为 0；不能把异步找点误判成快速击杀。
        if (gST.siQueueCount > 0 || SpawnQueue_Length() > 0)
            return false;

        // 条件1：本波已刷完且场上特感已降到当前难度的低压阈值
        if (!DifficultyStrategy_IsLowSiPressure())
            return false;

        // 条件2：生还者状态良好
        if (!WaveDecider_IsSurvivorsHealthy())
            return false;

        // 条件3：不在坦克/团灭状态
        if (IsAnyTankOrAboveHalfSurvivorDownOrDied())
            return false;

        return true;
    }

    void ReleaseWave(const char[] reason)
    {
        float now = GetGameTime();
        WaveDecider_Debug("Release wave: %s (elapsed=%.1fs early=%d intensive=%d)",
            reason,
            now - this.waveStartTime,
            this.earlyCheckCount,
            this.intensiveCheckCount);

        Tactical_PrepareBreachWave();
        this.Reset();
        StartWave();
    }
}

// 全局波决策器实例
static WaveDecider gWD;

// ==================== 辅助函数 ====================

static const char g_sWaveDecisionStateNames[][] =
{
    "Idle",
    "EarlyCheck",
    "TimerRunning",
    "IntensiveCheck"
};

stock void WaveDecider_GetStateName(WaveDecisionState state, char[] buffer, int maxlen)
{
    int idx = view_as<int>(state);
    if (idx < 0 || idx >= sizeof(g_sWaveDecisionStateNames))
    {
        strcopy(buffer, maxlen, "Unknown");
        return;
    }
    strcopy(buffer, maxlen, g_sWaveDecisionStateNames[idx]);
}

stock void WaveDecider_Debug(const char[] fmt, any ...)
{
    if (gCV.iDebugMode <= 0)
        return;

    char msg[256];
    VFormat(msg, sizeof msg, fmt, 2);
    Debug_Print("[WaveDecider] %s", msg);
}

stock bool WaveDecider_IsSurvivorsHealthy()
{
    int alive = 0;
    int healthy = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        alive++;

        // 健康标准：非倒地、非黑白、血量>30、没被控
        if (L4D_IsPlayerIncapacitated(i))
            continue;
        if (GetEntProp(i, Prop_Send, "m_currentReviveCount") >= 2)
            continue;
        if (GetClientHealth(i) < 30)
            continue;
        if (IsPinned(i))
            continue;

        healthy++;
    }

    if (alive <= 0)
        return false;

    // 至少一半人状态良好
    return (healthy * 2) >= alive;
}

// ==================== Anti-Bait 辅助接口（声明在 anti_baiter.inc） ====================
// AntiBait_IsStalled() - 已在 anti_baiter.inc 中定义
// AntiBait_IsTeamHolding() - 已在 anti_baiter.inc 中定义
// AntiBait_IsAttackableSpread() - 已在 anti_baiter.inc 中定义
// AntiBait_ShouldReleaseFromIntensive() - 已在 anti_baiter.inc 中定义

// ==================== 公共接口 ====================

stock void WaveDecider_OnRoundStart()
{
    gWD.Reset();
}

stock void WaveDecider_OnWaveStart()
{
    gWD.OnWaveStart();
}

stock void WaveDecider_Update()
{
    gWD.Update();
}

stock void WaveDecider_OnPause()
{
    gWD.OnPause();
}

stock void WaveDecider_OnUnpause()
{
    gWD.OnUnpause();
}

stock WaveDecisionState WaveDecider_GetState()
{
    return gWD.state;
}

stock bool WaveDecider_IsActive()
{
    return gWD.state != WD_Idle;
}

stock bool WaveDecider_IsAntiBaitArmWindowOpen()
{
    if (gWD.state == WD_IntensiveCheck)
        return true;
    if (gWD.state != WD_TimerRunning || gWD.timerStartTime <= 0.0)
        return false;

    float interval = DifficultyStrategy_GetConfiguredWaveDelay();
    float remaining = interval - (GetGameTime() - gWD.timerStartTime);
    return remaining <= gCV.fAntiBaitArmBefore;
}

stock float WaveDecider_GetReleaseEta()
{
    if (gWD.state == WD_IntensiveCheck)
        return 0.0;
    if (gWD.state != WD_TimerRunning)
        return -1.0;

    float remaining = DifficultyStrategy_GetConfiguredWaveDelay()
        - (GetGameTime() - gWD.timerStartTime);
    return (remaining > 0.0) ? remaining : 0.0;
}

// 击杀阶段（EarlyCheck）剩余的兜底时间；非该状态返回 -1。
// 供 ETA 估算使用：击杀阶段的时间不属于基础 16 秒倒计时，估算下一波
// 时间时应为“剩余检查窗口 + 完整基础倒计时”，而不是从波开始起算间隔。
stock float WaveDecider_GetEarlyCheckRemaining()
{
    if (gWD.state != WD_EarlyCheck)
        return -1.0;

    float remaining = DifficultyStrategy_GetWaveCheckDelay()
        - (GetGameTime() - gWD.waveStartTime);
    return (remaining > 0.0) ? remaining : 0.0;
}
