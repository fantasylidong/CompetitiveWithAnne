#if defined _infected_control_teleport_monitor_included
    #endinput
#endif
#define _infected_control_teleport_monitor_included

// 传送监督（1s）：出生宽限 + 跑男/anti-bait 快通道。
Action Timer_TeleportTick(Handle timer)
{
    if (timer != gST.hTeleport)
        return Plugin_Stop;

    g_fTeleportHeartbeat = GetGameTime();
    if (!gST.bLate || !gCV.bTeleport)
    {
        gST.hTeleport = INVALID_HANDLE;
        return Plugin_Stop;
    }

    if (g_bPauseLib && IsInPause())
        return Plugin_Continue;

    RefreshLastGoodSurPctTick();
    // AntiBait_Update() 已在 Timer_CheckSpawnWindow 中每秒调用，此处不重复调用

    if (Survivors_AllPinnedOrDown())
        return Plugin_Continue;

    float now = GetGameTime();

    for (int c = 1; c <= MaxClients; c++)
    {
        if (SpawnAttempts_IsPendingActualClient(c))
        {
            gST.teleCount[c] = 0;
            continue;
        }

        if (TeleportState_IsInSpawnGrace(c, now))
        {
            gST.teleCount[c] = 0;
            continue;
        }

        if (!CanBeTeleport(c))
            continue;

        float eyes[3];
        GetClientEyePosition(c, eyes);
        bool vis = IsPosVisibleSDK(eyes, true);

        if (!vis)
        {
            int zc = GetInfectedClass(c);
            if (zc == view_as<int>(SI_Smoker) && g_bSmokerLib)
            {
                if (!IsSmokerReadyToAttack(c))
                {
                    gST.teleCount[c]++;
                    if (gST.teleCount[c] > 0 && gST.teleCount[c] % 5 == 0)
                        LogMsg("[TP] smoker %N: ability not ready -> skip teleport (tick=%d)", c, gST.teleCount[c]);
                    continue;
                }
            }

            gST.teleCount[c]++;

            float needSecs = float(gCV.iTeleportCheckTime);
            bool runnerFastPath = (gST.bPickRushMan && TeleportQueue_Length() == 0);
            if (runnerFastPath && gCV.fTeleportRunnerFast > 0.0 && gCV.fTeleportRunnerFast < needSecs)
                needSecs = gCV.fTeleportRunnerFast;
            if (AntiBait_ShouldFastTeleport(c) && gCV.fAntiBaitFastTeleport < needSecs)
                needSecs = gCV.fAntiBaitFastTeleport;
            if (needSecs < MIN_TELEPORT_SECONDS) needSecs = MIN_TELEPORT_SECONDS;

            if (float(gST.teleCount[c]) >= needSecs)
            {
                if (zc >= 1 && zc <= SI_COUNT)
                {
                    TeleportQueue_Push(zc);

                    if (gST.siAlive[zc - 1] > 0) gST.siAlive[zc - 1]--; else gST.siAlive[zc - 1] = 0;
                    if (gST.totalSI > 0) gST.totalSI--; else gST.totalSI = 0;
                    InvalidateBucketShareCache();

                    float born = g_LastSpawnTime[c];
                    float age = born > 0.0 ? now - born : -1.0;
                    LogMsg("[TP] %N class=%s invisible for %.1f sec age=%.2f grace=%.2f%s -> teleport respawn",
                           c, g_sInfectedClassNames[zc], float(gST.teleCount[c]),
                           age, gCV.fTeleportSpawnGrace,
                           runnerFastPath ? " (runner-fast)" : "");

                    KickClient(c, "Teleport SI");
                    TeleportState_ClearClient(c);
                    RecalcSiCapFromAlive(false);
                }
            }
        }
        else
        {
            if (gST.teleCount[c] > 0 && (gST.teleCount[c] % 5 == 0))
                LogMsg("[TP] %N visible again (reset tick=%d)", c, gST.teleCount[c]);

            gST.teleCount[c] = 0;
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
