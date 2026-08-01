#if defined _infected_control_spawn_attempts_included
    #endinput
#endif
#define _infected_control_spawn_attempts_included

// 本文件只做“一次尝试”的执行层：
// - TryNormalSpawnOnce：从普通刷特队列取一个 class，找点并生成。
// - TryTeleportSpawnOnce：从传送队列取一个 class，按 teleportMode 找点并生成。
// - FallbackDirectorPosInRange：职业范围内的 NavArea 全部失败后，向导演要受限兜底点。
// - FallbackDirectorPosUnrestricted：连续完整流程失败后，完全交给导演找最终点。
//
// 选类、队列补位、波释放时机不在这里改；分别看 class_queue.inc、wave_decider.inc、wave_control.inc。
// 找点质量和性能不在这里改；看 spawn_core.inc / spawn_score.inc。

static int ResolveFallbackTarget(int target)
{
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

    return (IsValidSurvivor(tgt) && IsPlayerAlive(tgt)) ? tgt : 0;
}

static bool FallbackDirectorPosInRange(int zc, int target, bool teleportMode,
                                       float minRange, float maxRange, float outPos[3])
{
    float bestPt[3];
    bool have = false;
    float bestDelta = 999999.0;

    int tgt = ResolveFallbackTarget(target);
    if (tgt <= 0)
    {
        Debug_Print("[FALLBACK] no valid survivor to reference, abort");
        return false;
    }

    float desired = (minRange + maxRange) * 0.5;
    Visibility_EnsureCurrentEyeSnapshot();
    int visibilityRayMode = GetEffectiveVisibilityRayMode();
    for (int i = 0; i < DIRECTOR_FALLBACK_SAMPLES; i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(tgt, zc, 7, pt)) continue;

        float minDSq = GetMinEyeDistSquaredToAnySurvivor(pt);
        if (minDSq < minRange * minRange || minDSq > maxRange * maxRange) continue;
        if (Visibility_TestPointSafety(pt, teleportMode, visibilityRayMode)
            != AnneSpawnSafety_Safe) continue;

        float minD = SquareRoot(minDSq);
        float delta = FloatAbs(desired - minD);

        if (!have)
        {
            bestPt = pt;
            have = true;
            bestDelta = delta;
        }
        else if (delta < bestDelta)
        {
            bestPt = pt;
            bestDelta = delta;
        }
    }

    if (!have) return false;
    outPos = bestPt;
    return true;
}

static bool FallbackDirectorPosUnrestricted(int zc, int target, float outPos[3])
{
    int tgt = ResolveFallbackTarget(target);
    if (tgt <= 0)
    {
        Debug_Print("[FALLBACK API] no valid survivor to reference, abort");
        return false;
    }

    float apiStart = GetEngineTime();
    bool apiHit = L4D_GetRandomPZSpawnPosition(tgt, zc, UNRESTRICTED_DIRECTOR_TRIES, outPos);
    SpawnPerf_RecordFallbackApiMs((GetEngineTime() - apiStart) * 1000.0, apiHit, zc);
    return apiHit;
}

static int GetAreaIndexForSpawnPoint(const float pos[3])
{
    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);
    if (nav == Address_Null)
        return -1;

    return GetAreaIndexByNavID_Int(L4D_GetNavAreaID(nav));
}

static void RecordDirectorSpawnResult(const float pos[3], bool success)
{
    int areaIdx = GetAreaIndexForSpawnPoint(pos);
    if (areaIdx < 0)
        return;

    float now = GetGameTime();
    if (success)
    {
        TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
    }
    else
    {
        TouchNavCooldown(areaIdx, now, 0.8);
    }
}

#define ASSAULT_BURST_FOLLOWUP_DELAY 0.25
#define ASSAULT_BURST_TAIL_DELAY     0.60

static Handle g_hAssaultBurstTimer = null;
static float g_fAssaultBurstLastSpawn = 0.0;
static bool g_bAssaultBurstDirty = false;

void AssaultBurst_Reset()
{
    delete g_hAssaultBurstTimer;
    g_hAssaultBurstTimer = null;
    g_fAssaultBurstLastSpawn = 0.0;
    g_bAssaultBurstDirty = false;
}

static Action Timer_AssaultBurst(Handle timer)
{
    if (timer != g_hAssaultBurstTimer)
        return Plugin_Stop;

    g_hAssaultBurstTimer = null;
    bool executed = false;

    if (g_bAssaultBurstDirty)
    {
        L4D2_StartAssault();
        g_bAssaultBurstDirty = false;
        executed = true;
    }

    float remaining = g_fAssaultBurstLastSpawn + ASSAULT_BURST_TAIL_DELAY - GetGameTime();
    if (remaining > 0.0)
    {
        float delay = (remaining < ASSAULT_BURST_FOLLOWUP_DELAY)
            ? remaining
            : ASSAULT_BURST_FOLLOWUP_DELAY;
        g_hAssaultBurstTimer = CreateTimer(delay, Timer_AssaultBurst, _, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    if (!executed)
        L4D2_StartAssault();
    g_fAssaultBurstLastSpawn = 0.0;
    g_bAssaultBurstDirty = false;
    return Plugin_Stop;
}

static void TriggerAssaultBurst()
{
    g_fAssaultBurstLastSpawn = GetGameTime();
    if (g_hAssaultBurstTimer != null)
    {
        g_bAssaultBurstDirty = true;
        return;
    }

    L4D2_StartAssault();
    // Preserve one delayed pulse for a single spawn. Later spawns coalesce
    // into the same dirty flag and are serviced at most once per interval.
    g_bAssaultBurstDirty = true;
    g_hAssaultBurstTimer = CreateTimer(
        ASSAULT_BURST_FOLLOWUP_DELAY,
        Timer_AssaultBurst,
        _,
        TIMER_FLAG_NO_MAPCHANGE);
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

static int DoSpawnAt(const float pos[3], int zc, bool enforceMinDistance = true)
{
    if (enforceMinDistance)
    {
        float minDistSq = gCV.fSpawnMin * gCV.fSpawnMin;
        if (GetMinEyeDistSquaredToAnySurvivor(pos) < minDistSq)
        {
            Debug_Print("[SPAWN BLOCK] too close (< SpawnMin=%.1f) at (%.1f %.1f %.1f)",
                        gCV.fSpawnMin, pos[0], pos[1], pos[2]);
            return 0;
        }
    }

    int idx = L4D2_SpawnSpecial(zc, pos, NULL_VECTOR);
    if (idx > 0)
    {
        g_LastSpawnOkTime = GetGameTime();
        InvalidateBucketShareCache();
        Debug_Print("[SPAWN OK] %s idx=%d at (%.1f %.1f %.1f)", g_sInfectedClassNames[zc], idx, pos[0], pos[1], pos[2]);
        if (gCV.iDebugMode > 0)
            CreateTimer(0.15, Timer_LogSpawnedSIState, GetClientUserId(idx), TIMER_FLAG_NO_MAPCHANGE);
        return idx;
    }

    Debug_Print("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d", g_sInfectedClassNames[zc], pos[0], pos[1], pos[2], idx);
    return 0;
}

static void SpawnAttempts_RememberActualSpawn(int client, const float requestedPos[3])
{
    float actualPos[3];
    actualPos[0] = requestedPos[0];
    actualPos[1] = requestedPos[1];
    actualPos[2] = requestedPos[2];
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        GetClientAbsOrigin(client, actualPos);

    float center[3];
    GetSectorCenter(center, gST.targetSurvivor);
    RememberSpawn(actualPos, center);
}

static bool SelectTacticalNormalQueueHead(int &want)
{
    int guard = SpawnQueue_Length();
    while (guard-- > 0 && SpawnQueue_Peek(want))
    {
        bool supportBlocked = IsSupportGateClassInt(want) && SupportRestrictionActive();
        bool tacticalBlocked = IsSupportGateClassInt(want) && !Tactical_CanReleaseSupport(want);
        if (!supportBlocked && !tacticalBlocked)
            return true;

        SpawnQueue_RotateHead(want);
        Debug_Print("[QUEUE DEFER] %s support=%d tactical=%d",
                    g_sInfectedClassNames[want], supportBlocked ? 1 : 0, tacticalBlocked ? 1 : 0);
    }

    want = 0;
    return false;
}

static int g_iNormalSearchBand[SI_COUNT];
static int g_iTeleportSearchBand[SI_COUNT];

void SpawnAttempts_ResetSearchProgress()
{
    for (int i = 0; i < SI_COUNT; i++)
    {
        g_iNormalSearchBand[i] = 0;
        g_iTeleportSearchBand[i] = 0;
    }
    SpawnSearch_Reset();
}

static void SpawnAttempts_ResetNormalProgress(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    g_iNormalSearchBand[idx] = 0;
    SpawnSearch_ResetClass(zc, false);
}

static void SpawnAttempts_ResetTeleportProgress(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    g_iTeleportSearchBand[idx] = 0;
    SpawnSearch_ResetClass(zc, true);
}

static void SpawnAttempts_RotatePendingNormalClass(int zc)
{
    int remaining = SpawnQueue_Length();
    int head;
    while (remaining-- > 0 && SpawnQueue_Peek(head) && head == zc)
        SpawnQueue_RotateHead(head);
}

static void SpawnAttempts_RotatePendingTeleportClass(int zc)
{
    int remaining = TeleportQueue_Length();
    int head;
    while (remaining-- > 0 && TeleportQueue_Peek(head) && head == zc)
    {
        TeleportQueue_DropHead(head);
        TeleportQueue_Push(head);
    }
}

void TryNormalSpawnOnce()
{
    if (SpawnQueue_Length() <= 0)
        return;

    int want = 0;
    if (!SelectTacticalNormalQueueHead(want))
        return;
    int searchIdx = want - 1;

    if (HasReachedLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnAttempts_ResetNormalProgress(want);
        return;
    }
    if (HasReachedWaveClassLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached wave-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnAttempts_ResetNormalProgress(want);
        return;
    }

    if (!PassDeathCooldown(want) && !ShouldRelaxDeathCD())
    {
        SpawnQueue_RotateHead(want);
        SpawnAttempts_ResetNormalProgress(want);
        Debug_Print("[QUEUE ROTATE] %s under death-cooldown, rotate to tail", g_sInfectedClassNames[want]);
        return;
    }

    float minRange;
    float maxRange;
    if (g_iNormalSearchBand[searchIdx] < TACTICAL_BAND_STAGES)
    {
        int band = g_iNormalSearchBand[searchIdx];
        Tactical_GetDistanceBand(want, band, false, minRange, maxRange);

        float pos[3];
        int areaIdx = -1;
        SpawnScoreDbg bestDbg;
        SpawnSearchResult searchResult = FindSpawnPosViaNavAreaStep(
            want, gST.targetSurvivor, minRange, maxRange, false, pos, areaIdx, bestDbg);
        if (searchResult == SpawnSearch_Pending)
        {
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }

        bool ok = (searchResult == SpawnSearch_Found);
        if (!ok)
        {
            g_iNormalSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }

        // FindSpawnPos 只返回当前 tick 完成 safety/path/评分的候选，无需再次
        // 遍历生还者做距离与可见性复查。
        float spawnCallStart = GetEngineTime();
        int spawnedClient = DoSpawnAt(pos, want, false);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnReport_RecordScored(
            want, spawnedClient, WaveSpawn_NormalNav, spawnCallMs, pos, bestDbg);
        bool spawnOk = (spawnedClient > 0);
        if (!spawnOk)
        {
            // 实际生成失败时短冷却该 NavArea，下一档不会立即重复命中同一区域。
            if (areaIdx >= 0)
            {
                float now = GetGameTime();
                TouchNavCooldown(areaIdx, now, 0.8);
            }
            g_iNormalSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }

        LogChosenSpawnScore(want, bestDbg);
        if (areaIdx >= 0)
        {
            float now = GetGameTime();
            TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
        }

        SpawnAttempts_RememberActualSpawn(spawnedClient, pos);

        gST.siQueueCount--;
        gST.siAlive[want - 1]++;
        gST.totalSI++;
        MarkWaveClassSpawned(want);
        Tactical_OnClassSpawned(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnQueue_DropHead(want);
        SpawnAttempts_ResetNormalProgress(want);

        TriggerAssaultBurst();
        Debug_Print("[SPAWN] success class=%s band=%d range=%.0f..%.0f",
                    g_sInfectedClassNames[want], band + 1, minRange, maxRange);
        return;
    }

    Tactical_GetDistanceBand(want, TACTICAL_BAND_STAGES - 1, false, minRange, maxRange);
    float pt[3];
    bool usedUnrestricted = (g_iNormalSearchBand[searchIdx] > TACTICAL_BAND_STAGES);
    bool fallbackFound;
    if (usedUnrestricted)
        fallbackFound = FallbackDirectorPosUnrestricted(want, gST.targetSurvivor, pt);
    else
        fallbackFound = FallbackDirectorPosInRange(
            want, gST.targetSurvivor, false, minRange, maxRange, pt);
    int fallbackClient = 0;
    if (fallbackFound)
    {
        float spawnCallStart = GetEngineTime();
        fallbackClient = DoSpawnAt(pt, want, !usedUnrestricted);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnMode reportMode = usedUnrestricted
            ? WaveSpawn_NormalDirectorUnrestricted
            : WaveSpawn_NormalDirectorRange;
        WaveSpawnReport_RecordFallback(
            want, fallbackClient, reportMode, spawnCallMs, pt);
    }
    bool fallbackSpawned = (fallbackClient > 0);
    if (fallbackFound)
        RecordDirectorSpawnResult(pt, fallbackSpawned);

    if (!fallbackSpawned && !usedUnrestricted)
    {
        int cycleIdx = want - 1;
        gST.normalFallbackCycles[cycleIdx]++;
        if (gST.normalFallbackCycles[cycleIdx] >= UNRESTRICTED_FALLBACK_CYCLES)
        {
            gST.normalFallbackCycles[cycleIdx] = 0;
            g_iNormalSearchBand[searchIdx] = TACTICAL_BAND_STAGES + 1;
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }
    }

    if (fallbackSpawned)
    {
        SpawnAttempts_RememberActualSpawn(fallbackClient, pt);

        gST.siQueueCount--;
        gST.siAlive[want - 1]++;
        gST.totalSI++;
        MarkWaveClassSpawned(want);
        Tactical_OnClassSpawned(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnQueue_DropHead(want);
        SpawnAttempts_ResetNormalProgress(want);
        TriggerAssaultBurst();
        Debug_Print("[SPAWN] %s director fallback success class=%s",
                    usedUnrestricted ? "unrestricted" : "in-range", g_sInfectedClassNames[want]);
    }
    else
    {
        SpawnAttempts_RotatePendingNormalClass(want);
        Debug_Print("[SPAWN FAIL] full range cycle=%d class=%s, rotate",
                    gST.normalFallbackCycles[want - 1], g_sInfectedClassNames[want]);
        SpawnAttempts_ResetNormalProgress(want);
    }
}

void TryTeleportSpawnOnce()
{
    int want = 0;
    if (!TeleportQueue_Peek(want))
        return;
    int searchIdx = want - 1;
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
            gST.teleportFallbackCycles[want - 1] = 0;
            SpawnAttempts_ResetTeleportProgress(want);
            Debug_Print("[TP QUEUE ROTATE] %s reached alive-cap, rotate to tail", g_sInfectedClassNames[want]);
            return;
        }
    }

    float minRange;
    float maxRange;
    if (g_iTeleportSearchBand[searchIdx] < TACTICAL_BAND_STAGES)
    {
        int band = g_iTeleportSearchBand[searchIdx];
        Tactical_GetDistanceBand(want, band, true, minRange, maxRange);

        float pos[3];
        int areaIdx = -1;
        SpawnScoreDbg bestDbg;
        SpawnSearchResult searchResult = FindSpawnPosViaNavAreaStep(
            want, gST.targetSurvivor, minRange, maxRange, true, pos, areaIdx, bestDbg);
        if (searchResult == SpawnSearch_Pending)
        {
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }

        bool ok = (searchResult == SpawnSearch_Found);
        if (!ok)
        {
            g_iTeleportSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }

        // teleportMode 的倒地视线口径已在当前 tick 的安全判定中处理。
        float spawnCallStart = GetEngineTime();
        int spawnedClient = DoSpawnAt(pos, want, false);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnReport_RecordScored(
            want, spawnedClient, WaveSpawn_TeleportNav, spawnCallMs, pos, bestDbg);
        bool spawnOk = (spawnedClient > 0);
        if (!spawnOk)
        {
            if (areaIdx >= 0)
            {
                float now = GetGameTime();
                TouchNavCooldown(areaIdx, now, 0.8);
            }
            g_iTeleportSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }

        LogChosenSpawnScore(want, bestDbg);
        if (areaIdx >= 0)
        {
            float now = GetGameTime();
            TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
        }

        // 传送成功不消耗普通 siQueueCount，只移除 teleport queue。
        // 仍要更新 siAlive/totalSI，因为 DoSpawnAt 实际生成了一只新的 bot。
        SpawnAttempts_RememberActualSpawn(spawnedClient, pos);

        gST.siAlive[want - 1]++;
        gST.totalSI++;
        gST.teleportFallbackCycles[want - 1] = 0;
        TeleportQueue_DropHead(want);
        SpawnAttempts_ResetTeleportProgress(want);
        TriggerAssaultBurst();

        Debug_Print("[TP] success class=%s band=%d range=%.0f..%.0f",
                    g_sInfectedClassNames[want], band + 1, minRange, maxRange);
        return;
    }

    Tactical_GetDistanceBand(want, TACTICAL_BAND_STAGES - 1, true, minRange, maxRange);
    float pt[3];
    bool usedUnrestricted = (g_iTeleportSearchBand[searchIdx] > TACTICAL_BAND_STAGES);
    bool fallbackFound;
    if (usedUnrestricted)
        fallbackFound = FallbackDirectorPosUnrestricted(want, gST.targetSurvivor, pt);
    else
        fallbackFound = FallbackDirectorPosInRange(
            want, gST.targetSurvivor, true, minRange, maxRange, pt);
    int fallbackClient = 0;
    if (fallbackFound)
    {
        float spawnCallStart = GetEngineTime();
        fallbackClient = DoSpawnAt(pt, want, !usedUnrestricted);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnMode reportMode = usedUnrestricted
            ? WaveSpawn_TeleportDirectorUnrestricted
            : WaveSpawn_TeleportDirectorRange;
        WaveSpawnReport_RecordFallback(
            want, fallbackClient, reportMode, spawnCallMs, pt);
    }
    bool fallbackSpawned = (fallbackClient > 0);
    if (fallbackFound)
        RecordDirectorSpawnResult(pt, fallbackSpawned);

    if (!fallbackSpawned && !usedUnrestricted)
    {
        int cycleIdx = want - 1;
        gST.teleportFallbackCycles[cycleIdx]++;
        if (gST.teleportFallbackCycles[cycleIdx] >= UNRESTRICTED_FALLBACK_CYCLES)
        {
            gST.teleportFallbackCycles[cycleIdx] = 0;
            g_iTeleportSearchBand[searchIdx] = TACTICAL_BAND_STAGES + 1;
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }
    }

    if (fallbackSpawned)
    {
        SpawnAttempts_RememberActualSpawn(fallbackClient, pt);

        gST.siAlive[want - 1]++;
        gST.totalSI++;
        gST.teleportFallbackCycles[want - 1] = 0;
        TeleportQueue_DropHead(want);
        SpawnAttempts_ResetTeleportProgress(want);
        TriggerAssaultBurst();
        Debug_Print("[TP] %s director fallback success class=%s",
                    usedUnrestricted ? "unrestricted" : "in-range", g_sInfectedClassNames[want]);
    }
    else
    {
        SpawnAttempts_RotatePendingTeleportClass(want);
        Debug_Print("[TP FAIL] full range cycle=%d class=%s, rotate",
                    gST.teleportFallbackCycles[want - 1], g_sInfectedClassNames[want]);
        SpawnAttempts_ResetTeleportProgress(want);
    }
}
