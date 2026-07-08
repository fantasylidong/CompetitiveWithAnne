#if defined _infected_control_spawn_attempts_included
    #endinput
#endif
#define _infected_control_spawn_attempts_included

// 本文件只做“一次尝试”的执行层：
// - TryNormalSpawnOnce：从普通刷特队列取一个 class，找点并生成。
// - TryTeleportSpawnOnce：从传送队列取一个 class，按 teleportMode 找点并生成。
// - FallbackDirectorPosAtMax：NavArea 主路扩到最大仍失败时，向导演要一个兜底点。
//
// 选类、队列补位、波释放时机不在这里改；分别看 class_queue.inc、wave_decider.inc、wave_control.inc。
// 找点质量和性能不在这里改；看 spawn_core.inc / spawn_score.inc。

static bool FallbackDirectorPosAtMax(int zc, int target, bool teleportMode, float outPos[3])
{
    float bestPt[3];
    bool have = false;
    float bestDelta = 999999.0;

    float spawnMax = gCV.fSpawnMax;
    float spawnMin = gCV.fSpawnMin;

    int tgt = target;
    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
        tgt = GetHighestFlowSurvivorSafe();

    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsValidSurvivor(i) && IsPlayerAlive(i))
            {
                tgt = i;
                break;
            }
        }
    }

    if (!IsValidSurvivor(tgt) || !IsPlayerAlive(tgt))
    {
        Debug_Print("[FALLBACK] no valid survivor to reference, abort");
        return false;
    }

    float tFeet[3];
    GetClientAbsOrigin(tgt, tFeet);
    Address navTarget = L4D2Direct_GetTerrorNavArea(tFeet);
    if (navTarget == Address_Null)
        navTarget = view_as<Address>(L4D_GetNearestNavArea(tFeet, 300.0, false, false, false, TEAM_INFECTED));
    if (navTarget == Address_Null)
        return false;

    for (int i = 0; i < DIRECTOR_FALLBACK_TRIES; i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(tgt, zc, 7, pt)) continue;

        float minD = GetMinDistToAnySurvivor(pt);
        if (minD < spawnMin || minD > spawnMax + 200.0) continue;
        if (IsPosVisibleSDK(pt, teleportMode)) continue;
        if (WillStuck(pt)) continue;

        float delta = FloatAbs(spawnMax - minD);
        bool prefer = (minD <= spawnMax);

        if (!have)
        {
            bestPt = pt;
            have = true;
            bestDelta = delta;
        }
        else
        {
            float bestMinD = GetMinDistToAnySurvivor(bestPt);
            bool bestPrefer = (bestMinD <= spawnMax);
            if ((prefer && !bestPrefer) || (prefer == bestPrefer && delta < bestDelta))
            {
                bestPt = pt;
                bestDelta = delta;
            }
        }
    }

    if (!have) return false;
    outPos = bestPt;
    return true;
}

static Action Timer_AssaultBurst(Handle timer)
{
    BypassAndExecuteCommand("nb_assault");
    return Plugin_Stop;
}

static void TriggerAssaultBurst()
{
    BypassAndExecuteCommand("nb_assault");
    CreateTimer(0.25, Timer_AssaultBurst, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(0.60, Timer_AssaultBurst, _, TIMER_FLAG_NO_MAPCHANGE);
}

static Action Timer_LogSpawnedSIState(Handle timer, any userid)
{
    if (gCV.iDebugMode <= 0)
        return Plugin_Stop;

    int client = GetClientOfUserId(userid);
    if (!IsInfectedBot(client))
    {
        Debug_Print("[SPAWN STATE] userid=%d no longer a valid infected bot", userid);
        return Plugin_Stop;
    }

    float pos[3];
    GetClientAbsOrigin(client, pos);

    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vel);
    float speed = GetVectorLength(vel);

    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);
    int navid = (nav != Address_Null) ? L4D_GetNavAreaID(nav) : -1;
    float pathPenalty = PathPenalty_NoBuild(pos, gST.targetSurvivor, gCV.fSpawnMax, gCV.fSpawnMax);
    int ground = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");

    Debug_Print("[SPAWN STATE] %s idx=%d ghost=%d alive=%d move=%d ground=%d speed=%.1f nav=%d path=%s stuck=%d pos=(%.1f %.1f %.1f)",
                g_sInfectedClassNames[GetInfectedClass(client)], client,
                IsGhost(client) ? 1 : 0,
                IsPlayerAlive(client) ? 1 : 0,
                view_as<int>(GetEntityMoveType(client)),
                ground, speed, navid,
                (pathPenalty == 0.0) ? "ok" : "fail",
                WillStuck(pos) ? 1 : 0,
                pos[0], pos[1], pos[2]);

    return Plugin_Stop;
}

static int DoSpawnAt(const float pos[3], int zc)
{
    if (GetMinEyeDistToAnySurvivor(pos) < gCV.fSpawnMin)
    {
        Debug_Print("[SPAWN BLOCK] too close (< SpawnMin=%.1f) at (%.1f %.1f %.1f)",
                    gCV.fSpawnMin, pos[0], pos[1], pos[2]);
        return 0;
    }

    int idx = L4D2_SpawnSpecial(zc, pos, NULL_VECTOR);
    if (idx > 0)
    {
        g_LastSpawnOkTime = GetGameTime();
        InvalidateBucketShareCache();
        Debug_Print("[SPAWN OK] %s idx=%d at (%.1f %.1f %.1f)", g_sInfectedClassNames[zc], idx, pos[0], pos[1], pos[2]);
        CreateTimer(0.15, Timer_LogSpawnedSIState, GetClientUserId(idx), TIMER_FLAG_NO_MAPCHANGE);
        return idx;
    }

    Debug_Print("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d", g_sInfectedClassNames[zc], pos[0], pos[1], pos[2], idx);
    return 0;
}

static int GetAssaultCommandClient()
{
    if (IsValidSurvivor(gST.targetSurvivor) && IsPlayerAlive(gST.targetSurvivor))
        return gST.targetSurvivor;

    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(fb) && IsPlayerAlive(fb))
        return fb;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
            return i;
    }

    return 0;
}

static void BypassAndExecuteCommand(const char[] cmd)
{
    // 临时去除 FCVAR_CHEAT 标志以在非作弊服务器上执行命令。
    // nb_assault 是让 AI 特感立即进攻的关键命令，不应依赖 sv_cheats。
    int flags = GetCommandFlags(cmd);
    if (flags == INVALID_FCVAR_FLAGS)
    {
        Debug_Print("[ASSAULT FAIL] command not found: %s", cmd);
        return;
    }

    int client = GetAssaultCommandClient();
    SetCommandFlags(cmd, flags & ~FCVAR_CHEAT);

    if (client > 0)
    {
        FakeClientCommand(client, "%s", cmd);
    }
    else
    {
        ServerCommand("%s", cmd);
    }

    SetCommandFlags(cmd, flags);
}

void TryNormalSpawnOnce()
{
    static const float EPS_RADIUS = 1.0;
    if (SpawnQueue_Length() <= 0)
        return;

    // 普通刷特只看队首。若队首是被支援解锁规则拦住的 Boomer/Spitter，直接丢弃；
    // 若是死亡 CD，则旋到队尾，给其他 class 机会。
    int want = 0;
    while (SpawnQueue_Length() > 0)
    {
        SpawnQueue_Peek(want);
        if (!IsSupportGateClassInt(want) || !SupportRestrictionActive())
            break;

        Debug_Print("[QUEUE DROP] support %s blocked (need killers)", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
    }

    if (SpawnQueue_Length() <= 0)
        return;

    if (HasReachedLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        return;
    }
    if (HasReachedWaveClassLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached wave-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        return;
    }

    if (!PassDeathCooldown(want) && !ShouldRelaxDeathCD())
    {
        SpawnQueue_RotateHead(want);
        Debug_Print("[QUEUE ROTATE] %s under death-cooldown, rotate to tail", g_sInfectedClassNames[want]);
        return;
    }

    bool isSupport = (want == view_as<int>(SI_Boomer) || want == view_as<int>(SI_Spitter));

    float pos[3];
    int areaIdx = -1;
    float ring = gST.spawnDistCur;

    float maxR = gCV.fSpawnMax;
    if (isSupport && SUPPORT_EXPAND_MAX < maxR)
        maxR = SUPPORT_EXPAND_MAX;

    SpawnScoreDbg bestDbg;
    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, false, pos, areaIdx, bestDbg);

    // 防御性复查：FindSpawnPosViaNavArea 内已经做过可见性精判，但生成前再确认一次，
    // 防止候选评估和真正刷出之间幸存者视线/位置变化。
    if (ok && IsPosVisibleSDK(pos, false)) ok = false;

    bool triedSpawn = false;
    bool spawnOk = false;

    if (ok)
    {
        triedSpawn = true;
        spawnOk = (DoSpawnAt(pos, want) > 0);
    }

    if (ok && spawnOk)
    {
        LogChosenSpawnScore(want, bestDbg);
        if (areaIdx >= 0) TouchNavCooldown(areaIdx, GetGameTime(), NAV_CD_SECS);

        // 成功后必须同步三类状态：
        // 1) 记录最近刷点和 Nav 冷却，影响后续分散度/重复区域；
        // 2) 更新 siAlive/totalSI/队列计数，影响上限和下一帧是否继续刷；
        // 3) 收缩 ring，让下一只优先从更近的距离重新扩圈。
        float center[3];
        GetSectorCenter(center, gST.targetSurvivor);
        RememberSpawn(pos, center);

        gST.siQueueCount--;
        gST.siAlive[want - 1]++;
        gST.totalSI++;
        MarkWaveClassSpawned(want);
        SpawnQueue_DropHead(want);

        TriggerAssaultBurst();

        float nextStart = ring * 0.7;
        if (nextStart < gCV.fSpawnMin) nextStart = gCV.fSpawnMin;
        if (nextStart > gCV.fSpawnMax) nextStart = gCV.fSpawnMax;
        gST.spawnDistCur = nextStart;

        Debug_Print("[SPAWN] success ring=%.1f -> nextStart=%.1f", ring, gST.spawnDistCur);
        return;
    }

    // DoSpawnAt 失败通常表示点位附近运行时状态不适合生成。短冷却这个 NavArea，
    // 避免下一帧马上重复命中同一块区域。
    if (triedSpawn && !spawnOk && areaIdx >= 0)
        TouchNavCooldown(areaIdx, GetGameTime(), 0.8);

    // 找不到/刷不出时扩圈。支援特感有 SUPPORT_EXPAND_MAX，避免 Boomer/Spitter 被推得过远。
    float nextR = gST.spawnDistCur + LOW_SCORE_EXPAND;
    if (nextR > maxR) nextR = maxR;
    gST.spawnDistCur = nextR;

    Debug_Print("[SPAWN] expand -> %.1f (max=%.1f) class=%s", gST.spawnDistCur, maxR, g_sInfectedClassNames[want]);

    if (gST.spawnDistCur + EPS_RADIUS >= maxR)
    {
        float pt[3];
        if (FallbackDirectorPosAtMax(want, gST.targetSurvivor, false, pt) && DoSpawnAt(pt, want) > 0)
        {
            float center[3];
            GetSectorCenter(center, gST.targetSurvivor);
            RememberSpawn(pt, center);

            gST.siQueueCount--;
            gST.siAlive[want - 1]++;
            gST.totalSI++;
            MarkWaveClassSpawned(want);
            SpawnQueue_DropHead(want);

            TriggerAssaultBurst();

            gST.spawnDistCur *= 0.8;
            Debug_Print("[SPAWN] fallback@max success");
        }
        else
        {
            Debug_Print("[SPAWN FAIL] fallback@max failed class=%s", g_sInfectedClassNames[want]);
        }
    }
}

void TryTeleportSpawnOnce()
{
    static const float EPS_RADIUS = 1.0;

    int want = 0;
    if (!TeleportQueue_Peek(want))
        return;
    if (gST.totalSI >= gCV.iSiLimit)
        return;
    if (HasReachedLimit(want))
    {
        RecalcSiCapFromAlive(false);
        if (gST.totalSI >= gCV.iSiLimit)
            return;

        if (HasReachedLimit(want))
        {
            TeleportQueue_DropHead(want);
            TeleportQueue_Push(want);
            Debug_Print("[TP QUEUE ROTATE] %s reached alive-cap, rotate to tail", g_sInfectedClassNames[want]);
            return;
        }
    }

    float pos[3];
    int areaIdx = -1;
    float ring = gST.teleportDistCur;
    float maxR = gCV.fSpawnMax;

    SpawnScoreDbg bestDbg;
    bool ok = FindSpawnPosViaNavArea(want, gST.targetSurvivor, ring, true, pos, areaIdx, bestDbg);

    // teleportMode 下 IsPosVisibleSDK 会按配置忽略倒地视线；NavArea 团队可见 native 无法表达这个口径，
    // 所以最终仍以这里的旧可见性复查为准。
    if (ok && IsPosVisibleSDK(pos, true)) ok = false;

    bool triedSpawn = false;
    bool spawnOk = false;

    if (ok)
    {
        triedSpawn = true;
        spawnOk = (DoSpawnAt(pos, want) > 0);
    }

    if (ok && spawnOk)
    {
        LogChosenSpawnScore(want, bestDbg);
        if (areaIdx >= 0) TouchNavCooldown(areaIdx, GetGameTime(), NAV_CD_SECS);

        // 传送成功不消耗普通 siQueueCount，只移除 teleport queue。
        // 仍要更新 siAlive/totalSI，因为 DoSpawnAt 实际生成了一只新的 bot。
        float center[3];
        GetSectorCenter(center, gST.targetSurvivor);
        RememberSpawn(pos, center);

        gST.siAlive[want - 1]++;
        gST.totalSI++;
        TeleportQueue_DropHead(want);
        TriggerAssaultBurst();

        float nextTP = ring * 0.8;
        if (nextTP < gCV.fSpawnMin) nextTP = gCV.fSpawnMin;
        if (nextTP > gCV.fSpawnMax) nextTP = gCV.fSpawnMax;
        gST.teleportDistCur = nextTP;

        if (TeleportQueue_Length() == 0)
            gST.teleportDistCur = gCV.fSpawnMin;

        Debug_Print("[TP] success ring=%.1f -> nextStart=%.1f", ring, gST.teleportDistCur);
        return;
    }

    if (triedSpawn && !spawnOk && areaIdx >= 0)
        TouchNavCooldown(areaIdx, GetGameTime(), 0.8);

    float nextR = gST.teleportDistCur + LOW_SCORE_EXPAND;
    if (nextR > maxR) nextR = maxR;
    gST.teleportDistCur = nextR;

    Debug_Print("[TP] expand -> %.1f (max=%.1f) class=%s", gST.teleportDistCur, maxR, g_sInfectedClassNames[want]);

    if (gST.teleportDistCur + EPS_RADIUS >= maxR)
    {
        float pt[3];
        if (FallbackDirectorPosAtMax(want, gST.targetSurvivor, true, pt) && DoSpawnAt(pt, want) > 0)
        {
            float center[3];
            GetSectorCenter(center, gST.targetSurvivor);
            RememberSpawn(pt, center);

            gST.siAlive[want - 1]++;
            gST.totalSI++;
            TeleportQueue_DropHead(want);
            TriggerAssaultBurst();

            gST.teleportDistCur = FloatMax(gCV.fSpawnMin, gST.teleportDistCur * 0.7);
            Debug_Print("[TP] fallback@max success, ring now %.1f", gST.teleportDistCur);
        }
        else
        {
            Debug_Print("[TP FAIL] fallback@max failed class=%s", g_sInfectedClassNames[want]);
        }
    }
}
