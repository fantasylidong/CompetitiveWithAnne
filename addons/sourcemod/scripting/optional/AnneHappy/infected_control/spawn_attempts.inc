#if defined _infected_control_spawn_attempts_included
    #endinput
#endif
#define _infected_control_spawn_attempts_included

// 本文件只做“一次尝试”的执行层：
// - TryNormalSpawnOnce：从普通刷特队列取一个 class，找点并生成。
// - TryTeleportSpawnOnce：从传送队列取一个 class，按 teleportMode 找点并生成。
// - FallbackDirectorPos：职业范围内的 NavArea 全部失败后，对导演 API 点执行同帧安全检查。
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

static bool DirectorFallback_IsWithinTeamDistance(
    const float pos[3], float &teamMinDistance)
{
    float distanceSq = GetMinLiveEyeDistSquaredToAnySurvivor(pos);
    if (distanceSq >= 1.0e19)
    {
        teamMinDistance = -1.0;
        return false;
    }

    teamMinDistance = SquareRoot(distanceSq);
    return distanceSq <= DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE
        * DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE;
}

static bool SpawnAttempts_IsFallbackPointSafeBeforeCreate(
    const float pos[3], bool teleportMode)
{
    float directExclusion = FloatMax(
        NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin);
    if (teleportMode)
        directExclusion = FloatMax(directExclusion, gCV.fTeleportSpawnMin);
    directExclusion += NAV_CANDIDATE_LANDING_MARGIN;
    if (GetMinEyeDistSquaredToAnySurvivor(pos)
        < directExclusion * directExclusion)
    {
        return false;
    }

    if (!PassMinSeparation(pos))
        return false;

    Visibility_RefreshEyeSnapshot();
    int rayMode = GetEffectiveVisibilityRayMode();
    if (Visibility_TestPointSafetyDirect(pos, teleportMode, rayMode)
        != AnneSpawnSafety_Safe)
    {
        return false;
    }
    if (IsPredictedSpawnLandingVisible(pos, teleportMode, rayMode))
        return false;
    if (IsPredictedSpawnLandingInHurtTrigger(pos))
        return false;

    return true;
}

static bool FallbackDirectorPos(int zc, int target, int tries,
                                bool teleportMode, float outPos[3])
{
    int tgt = ResolveFallbackTarget(target);
    if (tgt <= 0)
    {
        Debug_Print("[FALLBACK API] no valid survivor to reference, abort");
        return false;
    }
    float apiStart = GetEngineTime();
    bool apiHit = L4D_GetRandomPZSpawnPosition(tgt, zc, tries, outPos);
    SpawnPerf_RecordFallbackApiMs((GetEngineTime() - apiStart) * 1000.0, apiHit, zc);
    float teamMinDistance = -1.0;
    bool withinDistance = apiHit
        && DirectorFallback_IsWithinTeamDistance(outPos, teamMinDistance);
    bool safePoint = withinDistance
        && SpawnAttempts_IsFallbackPointSafeBeforeCreate(
            outPos, teleportMode);
    if (apiHit && !withinDistance)
    {
        SpawnPerf_Log(
            "[SpawnPerf][DirectorCap] stage=request class=%s result=rejected teamMinDistance=%.1f cap=%.1f pos=(%.1f %.1f %.1f) target=%d tries=%d",
            g_sInfectedClassNames[zc], teamMinDistance,
            DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE,
            outPos[0], outPos[1], outPos[2], tgt, tries);
    }
    Debug_Print(
        "[FALLBACK API] class=%s target=%d tries=%d result=%s teamMinDistance=%.1f cap=%.1f pos=(%.1f %.1f %.1f)",
        g_sInfectedClassNames[zc], tgt, tries,
        !apiHit ? "miss" : (!withinDistance ? "cap_reject"
            : (safePoint ? "hit" : "safety_reject")),
        teamMinDistance, DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE,
        outPos[0], outPos[1], outPos[2]);
    return safePoint;
}

static int GetAreaIndexForSpawnPoint(const float pos[3])
{
    Address nav = L4D_GetNearestNavArea(pos, 120.0, false, false, false, TEAM_INFECTED);
    if (nav == Address_Null)
        return -1;

    return GetAreaIndexByNavID_Int(L4D_GetNavAreaID(nav));
}

// 导演兜底点无论成功还是失败都短冷却同一个 NavArea：成功是为了分散，
// 失败是为了下一档不要立刻再撞同一片区域。两种情况用同一个时长，因此
// 这里不再接收 success 参数（历史版本的 if/else 两个分支完全相同）。
static void RecordDirectorSpawnResult(const float pos[3])
{
    int areaIdx = GetAreaIndexForSpawnPoint(pos);
    if (areaIdx < 0)
        return;

    TouchNavCooldown(areaIdx, GetGameTime(), NAV_CD_SECS);
}

#define ASSAULT_BURST_FOLLOWUP_DELAY 0.25
#define ASSAULT_BURST_TAIL_DELAY     0.60

static Handle g_hAssaultBurstTimer = null;
static float g_fAssaultBurstLastSpawn = 0.0;
static bool g_bAssaultBurstDirty = false;

void AssaultBurst_Reset()
{
    StopTrackedTimer(g_hAssaultBurstTimer);
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
    if (g_hAssaultBurstTimer != null && !IsValidHandle(g_hAssaultBurstTimer))
        g_hAssaultBurstTimer = null;
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

static int g_iNormalSearchBand[SI_COUNT];
static int g_iTeleportSearchBand[SI_COUNT];
static float g_fNormalRetryAfter[SI_COUNT];
static float g_fTeleportRetryAfter[SI_COUNT];
static int g_iNormalRetryTargetNav[SI_COUNT];
static int g_iTeleportRetryTargetNav[SI_COUNT];
static int g_iNormalDirectedTarget[SI_COUNT];
static bool g_bNormalDirectedTargetTried[SI_COUNT][MAXPLAYERS + 1];
static bool g_bDirectedTargetTried[MAXPLAYERS + 1];
static int g_iNormalDirectedRetargets[SI_COUNT];

#define NORMAL_DIRECTED_RETARGET_LIMIT 3

static bool SpawnAttempts_HasReachedAliveLimit(int zc)
{
    return HasReachedLimit(zc);
}

// “临时态”客户端：已被拒绝等待踢出，或已进入踢出队列（传送/内鬼刷新踢出）。
// 这些实体只在 commit/death 时增减计数，任何全图清点（RecalcSiCapFromAlive
// 等）都必须跳过，否则会被计入两次。当前刷特路径已改为创建即提交，不再有
// pending 校验窗口，因此这里只识别踢出队列中的实体。
bool SpawnAttempts_IsTransientSpawnClient(int client)
{
    if (client <= 0 || client > MaxClients)
        return false;
    return IsClientInGame(client) && IsClientInKickQueue(client);
}

static bool SpawnAttempts_HasReachedWaveLimit(int zc)
{
    return HasReachedWaveClassLimit(zc);
}

static int DoSpawnAt(const float pos[3], int zc,
                     bool enforceMinDistance = true)
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
        TeleportState_StampSpawn(idx, "spawn_created");
        Debug_Print("[SPAWN CREATED] %s idx=%d request=(%.1f %.1f %.1f)",
            g_sInfectedClassNames[zc], idx, pos[0], pos[1], pos[2]);
        return idx;
    }

    Debug_Print("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d",
        g_sInfectedClassNames[zc], pos[0], pos[1], pos[2], idx);
    return 0;
}

static void SpawnAttempts_CommitSpawn(
    int client, int zc, bool teleportMode, bool fallback,
    WaveSpawnMode mode, float spawnCallMs, const float requestedPos[3],
    int targetSurvivor, float minRange, float maxRange, int areaIdx,
    SpawnScoreDbg score)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    int droppedClass;
    if (teleportMode)
        TeleportQueue_DropHead(droppedClass);
    else
        SpawnQueue_DropHead(droppedClass);

    float now = GetGameTime();
    if (fallback)
    {
        WaveSpawnReport_RecordFallback(
            zc, client, mode, spawnCallMs, requestedPos,
            minRange, maxRange, targetSurvivor);
        RecordDirectorSpawnResult(requestedPos);
    }
    else
    {
        WaveSpawnReport_RecordScored(
            zc, client, mode, spawnCallMs, requestedPos,
            minRange, maxRange, score, targetSurvivor);
        LogChosenSpawnScore(zc, score);
        if (areaIdx >= 0)
            TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
    }

    float actualPos[3];
    actualPos[0] = requestedPos[0];
    actualPos[1] = requestedPos[1];
    actualPos[2] = requestedPos[2];
    GetClientAbsOrigin(client, actualPos);

    SpawnAttempts_RememberActualSpawn(
        client, requestedPos, targetSurvivor);
    TeleportState_StampSpawn(client, "spawn_commit");
    g_LastSpawnOkTime = now;
    InvalidateBucketShareCache();
    gST.siAlive[zc - 1]++;
    gST.totalSI++;

    if (teleportMode)
    {
        gST.teleportFallbackCycles[zc - 1] = 0;
        SpawnAttempts_ResetTeleportProgress(zc);
    }
    else
    {
        if (gST.siQueueCount > 0)
            gST.siQueueCount--;
        MarkWaveClassSpawned(zc);
        Tactical_OnClassSpawned(zc);
        gST.normalFallbackCycles[zc - 1] = 0;
        SpawnAttempts_ResetNormalProgress(zc);
    }

    TriggerAssaultBurst();
    Debug_Print(
        "[SPAWN OK] %s idx=%d committed immediately request=(%.1f %.1f %.1f) actual=(%.1f %.1f %.1f) delta=%.1f",
        g_sInfectedClassNames[zc], client,
        requestedPos[0], requestedPos[1], requestedPos[2],
        actualPos[0], actualPos[1], actualPos[2],
        GetVectorDistance(requestedPos, actualPos));
    if (gCV.iDebugMode > 0)
    {
        CreateTimer(0.15, Timer_LogSpawnedSIState,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }

    int committedUserid = GetClientUserId(client);
    if (committedUserid > 0
        && g_hSpawnCommittedForward != INVALID_HANDLE)
    {
        Call_StartForward(g_hSpawnCommittedForward);
        Call_PushCell(committedUserid);
        Call_Finish();
    }
}

static void SpawnAttempts_RememberActualSpawn(int client,
                                              const float requestedPos[3],
                                              int targetSurvivor)
{
    float actualPos[3];
    actualPos[0] = requestedPos[0];
    actualPos[1] = requestedPos[1];
    actualPos[2] = requestedPos[2];
    if (client > 0 && client <= MaxClients && IsClientInGame(client))
        GetClientAbsOrigin(client, actualPos);

    float center[3];
    GetSectorCenter(center, targetSurvivor);
    RememberSpawn(actualPos, center);
    // 波内扇区配额按实际落点统计；导演兜底路径也计入，
    // 避免兜底刷出绕过方向配额。
    MarkWaveSectorSpawned(
        ComputeSectorIndex(center, actualPos, GetCurrentSectors()));
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

void SpawnAttempts_ResetSearchProgress()
{
    for (int i = 0; i < SI_COUNT; i++)
    {
        g_iNormalSearchBand[i] = 0;
        g_iTeleportSearchBand[i] = 0;
        g_fNormalRetryAfter[i] = 0.0;
        g_fTeleportRetryAfter[i] = 0.0;
        g_iNormalRetryTargetNav[i] = -1;
        g_iTeleportRetryTargetNav[i] = -1;
    }
    SpawnSearch_Reset();
}

static void SpawnAttempts_ResetDirectedTargets(int target)
{
    for (int client = 1; client <= MaxClients; client++)
        g_bDirectedTargetTried[client] = false;
    if (target > 0 && target <= MaxClients)
        g_bDirectedTargetTried[target] = true;

    for (int idx = 0; idx < SI_COUNT; idx++)
    {
        g_iNormalDirectedTarget[idx] = target;
        g_iNormalDirectedRetargets[idx] = 0;
        for (int client = 1; client <= MaxClients; client++)
            g_bNormalDirectedTargetTried[idx][client] = false;
        if (target > 0 && target <= MaxClients)
            g_bNormalDirectedTargetTried[idx][target] = true;
    }
}

void SpawnAttempts_OnWaveTargetSelected(int target)
{
    SpawnAttempts_ResetDirectedTargets(target);
    SpawnAttempts_ResetSearchProgress();
}

void SpawnAttempts_OnTargetChanged(int target)
{
    SpawnAttempts_ResetDirectedTargets(target);
    SpawnAttempts_ResetSearchProgress();
}

static bool SpawnAttempts_TryAlternateDirectedTarget(int zc,
                                                     bool teleportMode,
                                                     bool restartRound,
                                                     bool &pending)
{
    pending = false;
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return false;
    if (!SpawnAccel_CanUseGraphCandidates())
        return false;
    if (!teleportMode
        && !restartRound
        && g_iNormalDirectedRetargets[idx] >= NORMAL_DIRECTED_RETARGET_LIMIT)
    {
        return false;
    }

    int currentTarget = teleportMode
        ? gST.targetSurvivor : g_iNormalDirectedTarget[idx];
    if (restartRound)
    {
        if (teleportMode)
        {
            for (int client = 1; client <= MaxClients; client++)
                g_bDirectedTargetTried[client] = false;
            if (currentTarget > 0 && currentTarget <= MaxClients)
                g_bDirectedTargetTried[currentTarget] = true;
        }
        else
        {
            g_iNormalDirectedRetargets[idx] = 0;
            for (int client = 1; client <= MaxClients; client++)
                g_bNormalDirectedTargetTried[idx][client] = false;
            if (currentTarget > 0 && currentTarget <= MaxClients)
                g_bNormalDirectedTargetTried[idx][currentTarget] = true;
        }
    }

    int bestTarget = -1;
    int fallbackTarget = -1;
    int bestCoverage = restartRound ? -1 : 0;
    float pathLimit = SpawnAccel_GetCandidatePathLimit();
    float minTeamDistance = FloatMax(
        NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin);
    for (int client = 1; client <= MaxClients; client++)
    {
        bool targetTried = teleportMode
            ? g_bDirectedTargetTried[client]
            : g_bNormalDirectedTargetTried[idx][client];
        if (targetTried || !IsEligibleSpawnTarget(client)
            || (g_bTargetLimitLib && IsClientReachLimit(client)))
        {
            continue;
        }
        if (fallbackTarget <= 0)
            fallbackTarget = client;

        int targetNavId;
        if (!SpawnAccel_GetClientNavId(client, targetNavId))
            continue;

        int prepareStatus = SpawnAccel_PrepareTargetCandidates(
            client, NAV_CANDIDATE_RESULT_TTL);
        if (prepareStatus == ANNE_SPAWN_NAV_CANDIDATE_PENDING)
        {
            pending = true;
            continue;
        }
        if (prepareStatus <= 0)
            continue;

        int page[1];
        float distances[1];
        float resultAgeMs;
        int totalInRange;
        int count = AnneSpawn_NavCandidatesCollect(
            client, targetNavId,
            0.0, pathLimit, pathLimit, minTeamDistance,
            NAV_CANDIDATE_RESULT_TTL, 0,
            page, distances, sizeof(page),
            resultAgeMs, totalInRange);
        if (count == ANNE_SPAWN_NAV_CANDIDATE_PENDING)
        {
            pending = true;
            continue;
        }
        if (count < 0 || totalInRange <= bestCoverage)
            continue;

        bestTarget = client;
        bestCoverage = totalInRange;
    }

    // A full failed Nav + Director cycle means the current target is exhausted.
    // Even when alternate coverage is still empty/not ready, rotate to another
    // eligible survivor so its directed candidate set can be rebuilt next frame.
    if (bestTarget <= 0 && restartRound)
    {
        bestTarget = fallbackTarget;
        bestCoverage = 0;
    }
    if (bestTarget <= 0)
        return false;

    if (teleportMode)
    {
        gST.targetSurvivor = bestTarget;
        g_bDirectedTargetTried[bestTarget] = true;
        SpawnAttempts_ResetTeleportProgress(zc);
    }
    else
    {
        g_iNormalDirectedTarget[idx] = bestTarget;
        g_bNormalDirectedTargetTried[idx][bestTarget] = true;
        g_iNormalDirectedRetargets[idx]++;
        SpawnAttempts_ResetNormalProgress(zc);
    }
    Debug_Print("[TARGET] directed %s retarget class=%s old=%d new=%d candidates=%d mode=%s normalRetargets=%d/%d",
        restartRound ? "full-cycle" : "coverage",
        g_sInfectedClassNames[zc], currentTarget, bestTarget, bestCoverage,
        teleportMode ? "teleport" : "normal",
        g_iNormalDirectedRetargets[idx], NORMAL_DIRECTED_RETARGET_LIMIT);
    return true;
}

static void SpawnAttempts_ResetNormalProgress(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    g_iNormalSearchBand[idx] = 0;
    g_fNormalRetryAfter[idx] = 0.0;
    g_iNormalRetryTargetNav[idx] = -1;
    SpawnSearch_ResetClass(zc, false);
}

static void SpawnAttempts_ResetTeleportProgress(int zc)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    g_iTeleportSearchBand[idx] = 0;
    g_fTeleportRetryAfter[idx] = 0.0;
    g_iTeleportRetryTargetNav[idx] = -1;
    SpawnSearch_ResetClass(zc, true);
}

static int SpawnAttempts_GetSearchTarget(int zc, bool teleportMode)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return 0;

    int target = teleportMode
        ? gST.targetSurvivor : g_iNormalDirectedTarget[idx];
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        target = ResolveFallbackTarget(gST.targetSurvivor);
    return target;
}

static int SpawnAttempts_GetCurrentTargetNavId(int zc, bool teleportMode)
{
    int target = SpawnAttempts_GetSearchTarget(zc, teleportMode);
    if (!IsValidSurvivor(target) || !IsPlayerAlive(target))
        return -1;

    float survivorPos[3];
    GetClientAbsOrigin(target, survivorPos);
    Address nav = L4D2Direct_GetTerrorNavArea(survivorPos);
    if (nav == Address_Null)
    {
        nav = L4D_GetNearestNavArea(
            survivorPos, 120.0, false, false, false, TEAM_INFECTED);
    }
    return nav == Address_Null ? -1 : L4D_GetNavAreaID(nav);
}

static bool SpawnAttempts_RetryDeferred(int zc, bool teleportMode)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return false;

    float retryAfter = teleportMode
        ? g_fTeleportRetryAfter[idx] : g_fNormalRetryAfter[idx];
    if (retryAfter <= 0.0)
        return false;

    int retryTargetNav = teleportMode
        ? g_iTeleportRetryTargetNav[idx] : g_iNormalRetryTargetNav[idx];
    int currentTargetNav = SpawnAttempts_GetCurrentTargetNavId(zc, teleportMode);
    if (currentTargetNav > 0 && retryTargetNav > 0
        && currentTargetNav != retryTargetNav)
    {
        if (teleportMode)
            SpawnAttempts_ResetTeleportProgress(zc);
        else
            SpawnAttempts_ResetNormalProgress(zc);
        return false;
    }

    return GetGameTime() < retryAfter;
}

static void SpawnAttempts_ScheduleFullRetry(int zc, bool teleportMode)
{
    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return;

    float retryAfter = GetGameTime() + gCV.fSpawnFailedCycleRetry;
    int targetNavId = SpawnAttempts_GetCurrentTargetNavId(zc, teleportMode);
    if (teleportMode)
    {
        g_iTeleportSearchBand[idx] = 0;
        g_fTeleportRetryAfter[idx] = retryAfter;
        g_iTeleportRetryTargetNav[idx] = targetNavId;
        SpawnSearch_ResetClass(zc, true);
    }
    else
    {
        g_iNormalSearchBand[idx] = 0;
        g_fNormalRetryAfter[idx] = retryAfter;
        g_iNormalRetryTargetNav[idx] = targetNavId;
        SpawnSearch_ResetClass(zc, false);
    }
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

    if (SpawnAttempts_HasReachedAliveLimit(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnAttempts_ResetNormalProgress(want);
        return;
    }
    if (SpawnAttempts_HasReachedWaveLimit(want))
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
    if (SpawnAttempts_RetryDeferred(want, false))
    {
        SpawnAttempts_RotatePendingNormalClass(want);
        return;
    }
    int searchTarget = SpawnAttempts_GetSearchTarget(want, false);
    if (searchTarget <= 0)
    {
        SpawnAttempts_RotatePendingNormalClass(want);
        return;
    }

    float minRange;
    float maxRange;
    if (g_iNormalSearchBand[searchIdx] < TACTICAL_BAND_STAGES)
    {
        int band = g_iNormalSearchBand[searchIdx];
        Tactical_GetDistanceBand(want, band, false, minRange, maxRange);
        float graphScanMinRange = Tactical_GetDistanceBandScanMin(
            want, band, false);

        float pos[3];
        int areaIdx = -1;
        SpawnScoreDbg bestDbg;
        SpawnSearchResult searchResult = FindSpawnPosViaNavAreaStep(
            want, searchTarget, minRange, maxRange,
            graphScanMinRange, false, band, pos, areaIdx, bestDbg);
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
        bool spawnOk = (spawnedClient > 0);
        if (!spawnOk)
        {
            WaveSpawnReport_RecordScored(
                want, 0, WaveSpawn_NormalNav, spawnCallMs,
                pos, minRange, maxRange, bestDbg, searchTarget);
            // 实际生成失败时短冷却该 NavArea，下一档不会立即重复命中同一区域。
            if (areaIdx >= 0)
            {
                float now = GetGameTime();
                TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
            }
            g_iNormalSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }
        SpawnAttempts_CommitSpawn(
            spawnedClient, want, false, false,
            WaveSpawn_NormalNav, spawnCallMs, pos,
            searchTarget, minRange, maxRange, areaIdx, bestDbg);
        return;
    }

    minRange = FloatMax(NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin)
        + NAV_CANDIDATE_LANDING_MARGIN;
    maxRange = DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE;
    bool targetPending;
    if (SpawnAttempts_TryAlternateDirectedTarget(want, false, false, targetPending)
        || targetPending)
    {
        SpawnAttempts_RotatePendingNormalClass(want);
        return;
    }
    float pt[3];
    bool usedExtendedSamples =
        (g_iNormalSearchBand[searchIdx] > TACTICAL_BAND_STAGES);
    bool fallbackFound;
    if (usedExtendedSamples)
    {
        // 第二阶段只增加 Director API 内部尝试次数；安全范围仍固定
        // 为全队最近直线距离 [minRange, 2000]。
        fallbackFound = FallbackDirectorPos(
            want, searchTarget, EXTENDED_DIRECTOR_TRIES, false, pt);
    }
    else
        fallbackFound = FallbackDirectorPos(
            want, searchTarget, DIRECTOR_BASE_API_TRIES, false, pt);
    int fallbackClient = 0;
    if (fallbackFound)
    {
        float spawnCallStart = GetEngineTime();
        fallbackClient = DoSpawnAt(pt, want, false);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnMode reportMode = WaveSpawn_NormalDirectorRange;
        if (fallbackClient > 0)
        {
            SpawnScoreDbg fallbackScore;
            SpawnAttempts_CommitSpawn(
                fallbackClient, want, false, true,
                reportMode, spawnCallMs, pt,
                searchTarget, minRange, maxRange,
                -1, fallbackScore);
        }
        else
        {
            WaveSpawnReport_RecordFallback(
                want, 0, reportMode, spawnCallMs, pt,
                minRange, maxRange, searchTarget);
        }
    }
    bool fallbackSpawned = (fallbackClient > 0);
    if (fallbackFound && !fallbackSpawned)
        RecordDirectorSpawnResult(pt);

    if (fallbackSpawned)
        return;

    if (!fallbackSpawned && !usedExtendedSamples)
    {
        int cycleIdx = want - 1;
        gST.normalFallbackCycles[cycleIdx]++;
        if (gST.normalFallbackCycles[cycleIdx] >= EXTENDED_FALLBACK_CYCLES)
        {
            gST.normalFallbackCycles[cycleIdx] = 0;
            g_iNormalSearchBand[searchIdx] = TACTICAL_BAND_STAGES + 1;
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }
    }

    if (usedExtendedSamples)
    {
        bool retryTargetPending;
        if (SpawnAttempts_TryAlternateDirectedTarget(
                want, false, true, retryTargetPending)
            || retryTargetPending)
        {
            SpawnAttempts_RotatePendingNormalClass(want);
            return;
        }
        SpawnAttempts_ScheduleFullRetry(want, false);
    }
    SpawnAttempts_RotatePendingNormalClass(want);
    Debug_Print("[SPAWN FAIL] full range cycle=%d class=%s, rotate",
                gST.normalFallbackCycles[want - 1], g_sInfectedClassNames[want]);
    // Base fallback retries keep their stage so the extended Director pass can
    // be reached. Only a fully exhausted extended cycle restarts directed bands.
}

void TryTeleportSpawnOnce()
{
    int want = 0;
    if (!TeleportQueue_Peek(want))
        return;
    int searchIdx = want - 1;
    if (gST.totalSI >= gCV.iSiLimit)
        return;
    if (SpawnAttempts_HasReachedAliveLimit(want))
    {
        RecalcSiCapFromAlive(false);
        if (gST.totalSI >= gCV.iSiLimit)
            return;

        if (SpawnAttempts_HasReachedAliveLimit(want))
        {
            TeleportQueue_DropHead(want);
            TeleportQueue_Push(want);
            gST.teleportFallbackCycles[want - 1] = 0;
            SpawnAttempts_ResetTeleportProgress(want);
            Debug_Print("[TP QUEUE ROTATE] %s reached alive-cap, rotate to tail", g_sInfectedClassNames[want]);
            return;
        }
    }
    if (SpawnAttempts_RetryDeferred(want, true))
    {
        SpawnAttempts_RotatePendingTeleportClass(want);
        return;
    }
    int teleportTarget = SpawnAttempts_GetSearchTarget(want, true);
    if (teleportTarget <= 0)
    {
        SpawnAttempts_RotatePendingTeleportClass(want);
        return;
    }

    float minRange;
    float maxRange;
    if (g_iTeleportSearchBand[searchIdx] < TACTICAL_BAND_STAGES)
    {
        int band = g_iTeleportSearchBand[searchIdx];
        Tactical_GetDistanceBand(want, band, true, minRange, maxRange);
        float graphScanMinRange = Tactical_GetDistanceBandScanMin(
            want, band, true);

        float pos[3];
        int areaIdx = -1;
        SpawnScoreDbg bestDbg;
        SpawnSearchResult searchResult = FindSpawnPosViaNavAreaStep(
            want, teleportTarget, minRange, maxRange,
            graphScanMinRange, true, band, pos, areaIdx, bestDbg);
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
        bool spawnOk = (spawnedClient > 0);
        if (!spawnOk)
        {
            WaveSpawnReport_RecordScored(
                want, 0, WaveSpawn_TeleportNav, spawnCallMs,
                pos, minRange, maxRange, bestDbg, teleportTarget);
            if (areaIdx >= 0)
            {
                float now = GetGameTime();
                TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
            }
            g_iTeleportSearchBand[searchIdx]++;
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }
        SpawnAttempts_CommitSpawn(
            spawnedClient, want, true, false,
            WaveSpawn_TeleportNav, spawnCallMs, pos,
            teleportTarget, minRange, maxRange, areaIdx, bestDbg);
        return;
    }

    minRange = FloatMax(
        NAV_CANDIDATE_TEAM_EXCLUSION,
        FloatMax(gCV.fSpawnMin, gCV.fTeleportSpawnMin))
        + NAV_CANDIDATE_LANDING_MARGIN;
    maxRange = DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE;
    bool targetPending;
    if (SpawnAttempts_TryAlternateDirectedTarget(want, true, false, targetPending)
        || targetPending)
    {
        SpawnAttempts_RotatePendingTeleportClass(want);
        return;
    }
    float pt[3];
    bool usedExtendedSamples =
        (g_iTeleportSearchBand[searchIdx] > TACTICAL_BAND_STAGES);
    bool fallbackFound;
    if (usedExtendedSamples)
        fallbackFound = FallbackDirectorPos(
            want, teleportTarget, EXTENDED_DIRECTOR_TRIES, true, pt);
    else
        fallbackFound = FallbackDirectorPos(
            want, teleportTarget, DIRECTOR_BASE_API_TRIES, true, pt);
    int fallbackClient = 0;
    if (fallbackFound)
    {
        float spawnCallStart = GetEngineTime();
        fallbackClient = DoSpawnAt(pt, want, false);
        float spawnCallMs = (GetEngineTime() - spawnCallStart) * 1000.0;
        WaveSpawnMode reportMode = WaveSpawn_TeleportDirectorRange;
        if (fallbackClient > 0)
        {
            SpawnScoreDbg fallbackScore;
            SpawnAttempts_CommitSpawn(
                fallbackClient, want, true, true,
                reportMode, spawnCallMs, pt,
                teleportTarget, minRange, maxRange,
                -1, fallbackScore);
        }
        else
        {
            WaveSpawnReport_RecordFallback(
                want, 0, reportMode, spawnCallMs, pt,
                minRange, maxRange, teleportTarget);
        }
    }
    bool fallbackSpawned = (fallbackClient > 0);
    if (fallbackFound && !fallbackSpawned)
        RecordDirectorSpawnResult(pt);

    if (fallbackSpawned)
        return;

    if (!fallbackSpawned && !usedExtendedSamples)
    {
        int cycleIdx = want - 1;
        gST.teleportFallbackCycles[cycleIdx]++;
        if (gST.teleportFallbackCycles[cycleIdx] >= EXTENDED_FALLBACK_CYCLES)
        {
            gST.teleportFallbackCycles[cycleIdx] = 0;
            g_iTeleportSearchBand[searchIdx] = TACTICAL_BAND_STAGES + 1;
            SpawnAttempts_RotatePendingTeleportClass(want);
            return;
        }
    }

    SpawnAttempts_RotatePendingTeleportClass(want);
    if (usedExtendedSamples)
        SpawnAttempts_ScheduleFullRetry(want, true);
    Debug_Print("[TP FAIL] full range cycle=%d class=%s, rotate",
                gST.teleportFallbackCycles[want - 1], g_sInfectedClassNames[want]);
    // Preserve the progressed teleport distance band for the same reason as
    // the normal queue: a failed fallback must not restart the near search.
}
