#if defined _infected_control_teleport_monitor_included
    #endinput
#endif
#define _infected_control_teleport_monitor_included

static void TeleportMonitor_ResetInvisibleTime(int client)
{
    gST.teleInvisibleSeconds[client] = 0.0;
    gST.teleLastSampleTime[client] = 0.0;
}

static void TeleportMonitor_PauseInvisibleTime(int client)
{
    // 保留已累计时间，但不把暂停到下次可计时检查的间隔算进去。
    gST.teleLastSampleTime[client] = 0.0;
}

static void TeleportMonitor_ResetAllInvisibleTime()
{
    for (int client = 1; client <= MaxClients; client++)
        TeleportMonitor_ResetInvisibleTime(client);
}

static void TeleportMonitor_PauseAllInvisibleTime()
{
    for (int client = 1; client <= MaxClients; client++)
        TeleportMonitor_PauseInvisibleTime(client);
}

static float TeleportMonitor_AccumulateInvisibleTime(int client, float now)
{
    float last = gST.teleLastSampleTime[client];
    if (last > 0.0 && now >= last)
        gST.teleInvisibleSeconds[client] += now - last;

    gST.teleLastSampleTime[client] = now;
    return gST.teleInvisibleSeconds[client];
}

// 传送监督（1s）：出生宽限 + 跑男/anti-bait 快通道。
Action Timer_TeleportTick(Handle timer)
{
    if (timer != gST.hTeleport)
        return Plugin_Stop;

    g_fTeleportHeartbeat = GetGameTime();
    if (!gST.bLate || !gCV.bTeleport)
    {
        TeleportMonitor_ResetAllInvisibleTime();
        gST.hTeleport = INVALID_HANDLE;
        return Plugin_Stop;
    }

    if (g_bPauseLib && IsInPause())
    {
        TeleportMonitor_PauseAllInvisibleTime();
        return Plugin_Continue;
    }

    RefreshLastGoodSurPctTick();
    // AntiBait_Update() 已在 Timer_CheckSpawnWindow 中每秒调用，此处不重复调用

    if (Survivors_AllPinnedOrDown())
    {
        TeleportMonitor_PauseAllInvisibleTime();
        return Plugin_Continue;
    }

    float now = GetGameTime();
    Visibility_EnsureCurrentEyeSnapshot();

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsInfectedBot(c) || !IsPlayerAlive(c)
            || IsGhost(c) || IsClientInKickQueue(c)
            || GetInfectedClass(c) == ZC_TANK)
        {
            TeleportMonitor_ResetInvisibleTime(c);
            continue;
        }

        if (TeleportState_IsInSpawnGrace(c, now))
        {
            TeleportMonitor_ResetInvisibleTime(c);
            continue;
        }

        float origin[3];
        GetClientAbsOrigin(c, origin);
        bool vis = IsPosVisibleSDK(origin, true);
        if (vis)
        {
            float invisibleSecs = gST.teleInvisibleSeconds[c];
            if (invisibleSecs >= 5.0)
                LogMsg("[TP] %N visible again (reset elapsed=%.2f)", c, invisibleSecs);

            TeleportMonitor_ResetInvisibleTime(c);
            continue;
        }

        // 近距离交战或已跑到队伍前方不属于“落后且不可见”；
        // 这些状态会结束本次连续隐身时段。
        if (GetClosestSurvivorDistance(c) < gCV.fSpawnMin
            || IsPosAheadOfHighest(origin))
        {
            TeleportMonitor_ResetInvisibleTime(c);
            continue;
        }

        // 控人和 Spitter 技能保护期只暂停监督，不丢弃之前已经
        // 累计的合格隐身时间。
        if (IsPinningSomeone(c)
            || (IsSpitter(c) && (now - gST.spitterSpitTime[c]) < SPIT_INTERVAL))
        {
            TeleportMonitor_PauseInvisibleTime(c);
            continue;
        }

        if (!CanBeTeleport(c))
        {
            TeleportMonitor_PauseInvisibleTime(c);
            continue;
        }

        float invisibleSecs = TeleportMonitor_AccumulateInvisibleTime(c, now);

        int zc = GetInfectedClass(c);
        if (zc == view_as<int>(SI_Smoker) && g_bSmokerLib)
        {
            if (!IsSmokerReadyToAttack(c))
            {
                int elapsedWhole = RoundToFloor(invisibleSecs);
                if (elapsedWhole > 0 && elapsedWhole % 5 == 0)
                    LogMsg("[TP] smoker %N: ability not ready -> skip teleport (elapsed=%.2f)", c, invisibleSecs);
                continue;
            }
        }

        float needSecs = float(gCV.iTeleportCheckTime);
        bool runnerFastPath = (gST.bPickRushMan && TeleportQueue_Length() == 0);
        if (runnerFastPath && gCV.fTeleportRunnerFast > 0.0 && gCV.fTeleportRunnerFast < needSecs)
            needSecs = gCV.fTeleportRunnerFast;
        if (AntiBait_ShouldFastTeleport(c) && gCV.fAntiBaitFastTeleport < needSecs)
            needSecs = gCV.fAntiBaitFastTeleport;
        if (needSecs < MIN_TELEPORT_SECONDS) needSecs = MIN_TELEPORT_SECONDS;

        if (invisibleSecs >= needSecs)
        {
            if (zc >= 1 && zc <= SI_COUNT)
            {
                TeleportQueue_Push(zc);

                if (gST.siAlive[zc - 1] > 0) gST.siAlive[zc - 1]--; else gST.siAlive[zc - 1] = 0;
                if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
                InvalidateBucketShareCache();

                float born = g_LastSpawnTime[c];
                float age = born > 0.0 ? now - born : -1.0;
                LogMsg("[TP] %N class=%s invisible for %.2f sec age=%.2f grace=%.2f%s -> teleport respawn",
                       c, g_sInfectedClassNames[zc], invisibleSecs,
                       age, gCV.fTeleportSpawnGrace,
                       runnerFastPath ? " (runner-fast)" : "");

                KickClient(c, "Teleport SI");
                TeleportState_ClearClient(c);
                RecalcSiCapFromAlive(false);
            }
        }
    }

    int oldTarget = gST.targetSurvivor;
    int newTarget = Tactical_ResolveRuntimeTarget();
    if (newTarget != oldTarget)
    {
        gST.targetSurvivor = newTarget;
        SpawnAttempts_OnTargetChanged(newTarget);
        Debug_Print("[TARGET] runtime change old=%d new=%d; all directed bands reset",
            oldTarget, newTarget);
    }
    return Plugin_Continue;
}
