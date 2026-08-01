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
 * 3. Anti-Bait 只标记下一波为破点波，不延长基础刷新时间
 * 4. 旧密集检测状态保留兼容，但到达基础时间立即放行
 */

enum WaveDecisionState
{
    WD_Idle = 0,           // 空闲：没有活跃波
    WD_EarlyCheck,         // 提前检查：0-checkWindow 秒，评估是否提前触发
    WD_TimerRunning,       // 定时器运行中：16秒倒计时，监控玩家行为
    WD_IntensiveCheck      // 兼容旧状态：基础时间到达后立即放行
}

enum struct WaveDecider
{
    WaveDecisionState state;
    float waveStartTime;       // 本波开始时间
    float stateStartTime;      // 当前状态开始时间
    float timerStartTime;      // 16秒定时器开始时间
    bool earlyTriggered;       // 是否已触发提前机制
    bool pressureObserved;     // 定时器运行期间是否观察到破点压力
    int earlyCheckCount;       // 提前检查次数（用于调试）
    int intensiveCheckCount;   // 密集检测次数（用于调试）

    void OnWaveStart()
    {
        float now = GetGameTime();
        this.state = WD_EarlyCheck;
        this.waveStartTime = now;
        this.stateStartTime = now;
        this.timerStartTime = 0.0;
        this.earlyTriggered = false;
        this.pressureObserved = false;
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
        this.earlyTriggered = false;
        this.pressureObserved = false;
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

        // 在刚性倒计时期间记录 Pressure，只改变下一波战术，不改变截止时间。

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
                // 卡位不会延后刷新；ReleaseWave 会把本波标记为专用破点波。
                this.ReleaseWave("timer reached with breach pressure");
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
        if (AntiBait_ShouldReleaseFromIntensive())
        {
            if (AntiBait_IsAttackableSpread())
                this.ReleaseWave("survivors spread out");
            else
                this.ReleaseWave("survivors progressed");
            return;
        }

        // 理论上不会再进入此状态；热重载遗留状态最多等待到基础截止时间。
        this.intensiveCheckCount++;
    }

    void StartSpawnTimer(const char[] reason)
    {
        float now = GetGameTime();
        this.timerStartTime = now;
        this.TransitionTo(WD_TimerRunning, reason);
        Traitor_OnFinalRefreshStarted();

        float interval = DifficultyStrategy_GetConfiguredWaveDelay();
        WaveDecider_Debug("Start %0.fs timer (%s)", interval, reason);
    }

    bool ShouldEarlyTrigger()
    {
        // 条件1：特感数量过低
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
        WaveDecider_Debug("Release wave: %s (elapsed=%.1fs early=%d intensive=%d)",
            reason,
            GetGameTime() - this.waveStartTime,
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

stock WaveDecisionState WaveDecider_GetState()
{
    return gWD.state;
}

stock bool WaveDecider_IsActive()
{
    return gWD.state != WD_Idle;
}

stock float WaveDecider_GetReleaseEta()
{
    if (gWD.state != WD_TimerRunning)
        return -1.0;

    float remaining = DifficultyStrategy_GetConfiguredWaveDelay()
        - (GetGameTime() - gWD.timerStartTime);
    return (remaining > 0.0) ? remaining : 0.0;
}
