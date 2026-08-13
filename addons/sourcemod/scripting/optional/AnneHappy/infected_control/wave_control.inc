#if defined _infected_control_wave_control_included
    #endinput
#endif
#define _infected_control_wave_control_included

// 波控制：负责开波、自动刷特窗口以及暂停恢复。
// 重构后使用 WaveDecider 进行决策，本模块只负责执行。

void StartWave()
{
    // 下一次开波就是上一波的自然结算边界；首波时没有活动报告。
    WaveSpawnReport_End("next_wave");
    ClearPathCache();
    RecalcSiCapFromAlive(true);
    ResetWaveClassSpawnCounts();
    ResetWaveSectorSpawnCounts();
    Tactical_OnWaveStart();

    gST.survCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i) && gST.survCount < sizeof(gST.survIdx))
            gST.survIdx[gST.survCount++] = i;
    }

    int waveNumber = gST.waveIndex + 1;
    int aiBudget = Traitor_AdjustWaveSpawnBudget(gCV.iSiLimit, waveNumber);
    gST.siQueueCount   += aiBudget;

    gST.bShouldCheck = true;
    gST.waveIndex++;
    Traitor_AdvanceNoDamageWaveBlocks();
    Traitor_OnWaveReleased(gST.waveIndex);
    gST.lastWaveAvgFlow = GetSurAvrFlow();
    gST.lastSpawnSecs   = 0;
    gST.lastWaveStartTime = GetGameTime();

    if (gST.siQueueCount > gCV.iSiLimit)
        gST.siQueueCount = gCV.iSiLimit;

    FillSpawnQueueToPendingBudget(false);
    Tactical_PrioritizeBreachQueue();

    AntiBait_OnWaveStart();
    gST.targetSurvivor = Tactical_ResolveWaveTarget();
    SpawnAttempts_OnWaveTargetSelected(gST.targetSurvivor);
    WaveSpawnReport_Begin(
        gST.waveIndex, aiBudget, gST.siQueueCount, gST.lastWaveStartTime);
    WaveDecider_OnWaveStart();  // 通知波决策器
    Traitor_ActivateWaitingClients(); // 仅在新的 EarlyCheck 安全窗口晋升普通内鬼
    Debug_Print("Start wave %d", gST.waveIndex);
}

Action Timer_StartNewWave(Handle timer)
{
    if (timer != gST.hSpawn)
        return Plugin_Stop;

    gST.hSpawn = INVALID_HANDLE;
    StartWave();
    return Plugin_Stop;
}

static void ScheduleNextWave()
{
    gST.bShouldCheck = false;
    StopTrackedTimer(gST.hSpawn);
    gST.hSpawn = CreateTimer(0.1, Timer_StartNewWave, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_CheckSpawnWindow(Handle timer)
{
    if (timer != gST.hCheck)
        return Plugin_Stop;

    g_fWaveCheckHeartbeat = GetGameTime();
    if (!gST.bLate)
    {
        gST.hCheck = INVALID_HANDLE;
        return Plugin_Stop;
    }

    // 暂停检查
    if (g_bPauseLib && IsInPause())
    {
        if (gST.hSpawn != INVALID_HANDLE)
        {
            gST.unpauseDelay = gCV.fSiInterval - (GetGameTime() - gST.lastWaveStartTime);
            if (gST.unpauseDelay < 0.1)
                gST.unpauseDelay = 0.1;
            StopTrackedTimer(gST.hSpawn);
            gST.bPausedSpawnTimer = true;
        }
        return Plugin_Continue;
    }

    gST.lastSpawnSecs++;

    // 更新 Anti-Bait 状态
    AntiBait_Update();

    // 更新波决策器（核心逻辑）
    WaveDecider_Update();

    // 兼容性：保持原有的手动触发逻辑（如果波决策器未激活）
    if (!WaveDecider_IsActive() && gST.bShouldCheck && gST.hSpawn == INVALID_HANDLE)
    {
        int survivorLimit = (gCV.SurvivorLimit != null) ? gCV.SurvivorLimit.IntValue : 4;
        if (survivorLimit >= 2 && IsAnyTankOrAboveHalfSurvivorDownOrDied(1) && !DifficultyStrategy_CanEvaluateWave())
            return Plugin_Continue;

        bool reachedConfiguredSpawnTime = DifficultyStrategy_CanStartConfiguredWave();
        if (reachedConfiguredSpawnTime)
        {
            if (gST.siQueueCount == gCV.iSiLimit)
            {
                gST.lastSpawnSecs = 0;
            }
            else
            {
                Tactical_PrepareBreachWave();
                ScheduleNextWave();
            }
        }
    }

    return Plugin_Continue;
}

void PauseSpawnTimer()
{
    if (gST.hSpawn != INVALID_HANDLE)
    {
        gST.unpauseDelay = gCV.fSiInterval - (GetGameTime() - gST.lastWaveStartTime);
        if (gST.unpauseDelay < 0.1)
            gST.unpauseDelay = 0.1;
        StopTrackedTimer(gST.hSpawn);
        gST.bPausedSpawnTimer = true;
        Debug_Print("Pause spawn timer, resume after %.2f", gST.unpauseDelay);
    }
}

void UnpauseSpawnTimer(float delay)
{
    if (gST.bPausedSpawnTimer && gST.hSpawn == INVALID_HANDLE)
    {
        gST.bPausedSpawnTimer = false;
        gST.hSpawn = CreateTimer(delay, Timer_StartNewWave, _, TIMER_FLAG_NO_MAPCHANGE);
        Debug_Print("Resume spawn in %.2f", delay);
    }
}
