#if defined _infected_control_spawn_attempts_included
    #endinput
#endif
#define _infected_control_spawn_attempts_included

// 本文件只做“一次尝试”的执行层：
// - TryNormalSpawnOnce：从普通刷特队列取一个 class，找点并生成。
// - TryTeleportSpawnOnce：从传送队列取一个 class，按 teleportMode 找点并生成。
// - FallbackDirectorPos：职业范围内的 NavArea 全部失败后，采用团队距离不超过 2000u 的导演 API 点。
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

static bool FallbackDirectorPos(int zc, int target, int tries,
                                float outPos[3])
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
        !apiHit ? "miss" : (withinDistance ? "hit" : "cap_reject"),
        teamMinDistance, DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE,
        outPos[0], outPos[1], outPos[2]);
    return withinDistance;
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
        TouchNavCooldown(areaIdx, now, NAV_CD_SECS);
    }
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

static bool g_bRejectedActualSpawn[MAXPLAYERS + 1];
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
#define EXTENDED_DIRECTOR_MAX_SCALE 1.5

enum struct PendingActualSpawn
{
    bool active;
    float createdAt;
    bool hasStableSample;
    float stableSince;
    float stablePos[3];
    int userid;
    int zc;
    int targetSurvivor;
    int areaIdx;
    int navId;
    int band;
    bool teleportMode;
    bool fallback;
    WaveSpawnMode mode;
    float spawnCallMs;
    float minRange;
    float maxRange;
    float graphScanMinRange;
    float requestedPos[3];
    int reservationToken;
    SpawnScoreDbg score;
}

#define ACTUAL_SPAWN_VALIDATION_MIN_AGE       0.10
#define ACTUAL_SPAWN_STABLE_CONFIRM_SECONDS   0.10
#define ACTUAL_SPAWN_STABLE_RADIUS             8.00
#define ACTUAL_SPAWN_VALIDATION_MAX_AGE        1.00

static PendingActualSpawn g_PendingActualSpawns[MAXPLAYERS + 1];

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse,
                             float vel[3], float angles[3], int &weapon,
                             int &subtype, int &cmdnum, int &tickcount,
                             int &seed, int mouse[2])
{
    if (!SpawnAttempts_IsPendingActualClient(client))
        return Plugin_Continue;

    // 只阻止待确认特感主动移动；保留实体物理，允许引擎完成重力落地
    // 与碰撞修正。确认完成后 pending 状态清除，下一条指令即恢复。
    int moveButtons = IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT
        | IN_JUMP | IN_SPEED | IN_ATTACK | IN_ATTACK2;
    buttons &= ~moveButtons;
    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    return Plugin_Changed;
}

void SpawnAttempts_ClearRejectedActualSpawn(int client)
{
    if (client > 0 && client <= MaxClients)
        g_bRejectedActualSpawn[client] = false;
}

void SpawnAttempts_OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients
        || g_bRejectedActualSpawn[client]
        || !g_PendingActualSpawns[client].active)
    {
        return;
    }

    // 自然断线没有实体可继续确认。立即解除空间占位，并让统一超时失败
    // 路径在下一帧记录失败、恢复队列和推进距离档位。
    ReleasePendingSpawnReservation(
        g_PendingActualSpawns[client].reservationToken);
    g_PendingActualSpawns[client].reservationToken = 0;
    g_PendingActualSpawns[client].createdAt = GetGameTime()
        - ACTUAL_SPAWN_VALIDATION_MAX_AGE;
}

bool SpawnAttempts_ConsumeRejectedActualDeath(int client)
{
    if (client <= 0 || client > MaxClients || !g_bRejectedActualSpawn[client])
        return false;

    g_bRejectedActualSpawn[client] = false;
    return true;
}

bool SpawnAttempts_HasPendingActualSpawn()
{
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (g_PendingActualSpawns[slot].active)
            return true;
    }
    return false;
}

int SpawnAttempts_CountPendingActualSpawns(bool teleportOnly = false)
{
    int count = 0;
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (!g_PendingActualSpawns[slot].active)
            continue;
        if (teleportOnly && !g_PendingActualSpawns[slot].teleportMode)
            continue;
        count++;
    }
    return count;
}

int SpawnAttempts_CountRejectedActualSpawns()
{
    int count = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_bRejectedActualSpawn[client]
            && IsClientInGame(client)
            && IsPlayerAlive(client))
        {
            count++;
        }
    }
    return count;
}

int SpawnAttempts_CountPendingNormalSpawns()
{
    int count = 0;
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (g_PendingActualSpawns[slot].active
            && !g_PendingActualSpawns[slot].teleportMode)
        {
            count++;
        }
    }
    return count;
}

int SpawnAttempts_CountPendingClass(int zc, bool normalOnly = false)
{
    int count = 0;
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (!g_PendingActualSpawns[slot].active
            || g_PendingActualSpawns[slot].zc != zc
            || (normalOnly && g_PendingActualSpawns[slot].teleportMode))
        {
            continue;
        }
        count++;
    }
    return count;
}

static bool SpawnAttempts_HasReachedAliveLimitWithPending(int zc)
{
    if (HasReachedLimit(zc))
        return true;

    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return true;

    int reserved = Traitor_CountReservedClassSlots(zc);
    int cap = gST.siAlive[idx] + gST.siCap[idx] + reserved;
    return gST.siAlive[idx] + SpawnAttempts_CountPendingClass(zc)
        + reserved >= cap;
}

static bool SpawnAttempts_HasReachedWaveLimitWithPending(int zc)
{
    if (HasReachedWaveClassLimit(zc))
        return true;

    int idx = zc - 1;
    if (idx < 0 || idx >= SI_COUNT)
        return true;

    int cap = gST.siAlive[idx] + gST.siCap[idx]
        + Traitor_CountReservedClassSlots(zc);
    return gST.siSpawnedThisWave[idx]
        + SpawnAttempts_CountPendingClass(zc, true) >= cap;
}

bool SpawnAttempts_IsPendingActualClient(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && g_PendingActualSpawns[client].active
        && GetClientUserId(client) == g_PendingActualSpawns[client].userid;
}

void SpawnAttempts_ResetPendingActualSpawn(bool removeClient = true)
{
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (!g_PendingActualSpawns[slot].active)
            continue;

        ReleasePendingSpawnReservation(
            g_PendingActualSpawns[slot].reservationToken);
        g_PendingActualSpawns[slot].reservationToken = 0;

        if (removeClient)
        {
            int client = GetClientOfUserId(g_PendingActualSpawns[slot].userid);
            if (client > 0 && IsClientInGame(client))
            {
                g_bRejectedActualSpawn[client] = true;
                KickClient(client, "Cancelled pending spawn validation");
                TeleportState_ClearClient(client);
            }
        }
        g_PendingActualSpawns[slot].active = false;
        g_PendingActualSpawns[slot].userid = 0;
    }
    ClearPendingSpawnReservations();
}

static bool SpawnAttempts_ValidateActualSpawn(int client, int zc,
                                              bool teleportMode,
                                              bool &persistentUnsafe)
{
    persistentUnsafe = false;
    if (!IsInfectedBot(client) || !IsPlayerAlive(client) || IsGhost(client)
        || GetInfectedClass(client) != zc)
    {
        Debug_Print("[SPAWN REJECT ACTUAL] class=%s idx=%d reason=state",
            g_sInfectedClassNames[zc], client);
        return false;
    }

    float actual[3];
    GetClientAbsOrigin(client, actual);
    float directExclusion = FloatMax(
        NAV_CANDIDATE_TEAM_EXCLUSION, gCV.fSpawnMin);
    if (teleportMode)
        directExclusion = FloatMax(directExclusion, gCV.fTeleportSpawnMin);
    float directExclusionSq = directExclusion * directExclusion;
    if (GetMinEyeDistSquaredToAnySurvivor(actual) < directExclusionSq)
    {
        Debug_Print("[SPAWN REJECT ACTUAL] class=%s idx=%d reason=distance min=%.1f pos=(%.1f %.1f %.1f)",
            g_sInfectedClassNames[zc], client, directExclusion,
            actual[0], actual[1], actual[2]);
        return false;
    }

    // 最终提交是每只特感一次的低频路径，直接刷新当前眼位，避免同 tick
    // 内其他插件传送生还者后沿用候选阶段的旧快照。
    Visibility_RefreshEyeSnapshot();
    int rayMode = GetEffectiveVisibilityRayMode();
    // 最终提交是低频路径，强制走与独立测试探针一致的 SourcePawn
    // 射线/引擎可见性复核；扩展 native 继续负责高频候选预筛。
    AnneSpawnSafetyResult safety = Visibility_TestPointSafetyDirect(
        actual, teleportMode, rayMode);
    bool inHurt = IsSpawnPointInHurtTrigger(actual);
    if (safety != AnneSpawnSafety_Safe || inHurt)
    {
        persistentUnsafe = inHurt || safety == AnneSpawnSafety_Stuck;
        Debug_Print("[SPAWN REJECT ACTUAL] class=%s idx=%d reason=%s pos=(%.1f %.1f %.1f)",
            g_sInfectedClassNames[zc], client,
            inHurt ? "hurt" : (safety == AnneSpawnSafety_Visible ? "visible" : "stuck"),
            actual[0], actual[1], actual[2]);
        return false;
    }

    // The engine may settle a spawned infected far below the requested Nav
    // point. Recheck dispersion at the actual origin so two distinct requests
    // cannot commit onto the same landing spot.
    if (!PassMinSeparation(actual))
    {
        Debug_Print("[SPAWN REJECT ACTUAL] class=%s idx=%d reason=separation pos=(%.1f %.1f %.1f)",
            g_sInfectedClassNames[zc], client,
            actual[0], actual[1], actual[2]);
        return false;
    }

    return true;
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
        Debug_Print("[SPAWN CREATED] %s idx=%d pending actual validation at (%.1f %.1f %.1f)",
            g_sInfectedClassNames[zc], idx, pos[0], pos[1], pos[2]);
        return idx;
    }

    Debug_Print("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d", g_sInfectedClassNames[zc], pos[0], pos[1], pos[2], idx);
    return 0;
}

static void SpawnAttempts_BeginPending(
    int client, int zc, bool teleportMode, bool fallback,
    WaveSpawnMode mode, float spawnCallMs, const float requestedPos[3],
    int targetSurvivor, float minRange, float maxRange, int areaIdx, int band,
    float graphScanMinRange, SpawnScoreDbg score)
{
    if (client <= 0 || client > MaxClients)
        return;

    if (g_PendingActualSpawns[client].active)
    {
        LogError("[IC] pending spawn slot reused before cleanup: client=%d oldUserId=%d oldClass=%d",
            client, g_PendingActualSpawns[client].userid,
            g_PendingActualSpawns[client].zc);
        int oldZc = g_PendingActualSpawns[client].zc;
        bool oldTeleportMode = g_PendingActualSpawns[client].teleportMode;
        int oldBand = g_PendingActualSpawns[client].band;
        ReleasePendingSpawnReservation(
            g_PendingActualSpawns[client].reservationToken);
        g_PendingActualSpawns[client].reservationToken = 0;
        g_PendingActualSpawns[client].active = false;
        g_PendingActualSpawns[client].userid = 0;
        if (oldZc >= 1 && oldZc <= SI_COUNT)
        {
            if (oldTeleportMode)
            {
                TeleportQueue_Push(oldZc);
                SpawnSearch_ResetClass(oldZc, true);
                g_iTeleportSearchBand[oldZc - 1] = ClampInt(
                    oldBand + 1, 0, TACTICAL_BAND_STAGES + 1);
            }
            else
            {
                SpawnQueue_Push(oldZc);
                SpawnSearch_ResetClass(oldZc, false);
                g_iNormalSearchBand[oldZc - 1] = ClampInt(
                    oldBand + 1, 0, TACTICAL_BAND_STAGES + 1);
            }
        }
    }

    PendingActualSpawn pending;
    pending.active = true;
    pending.createdAt = GetGameTime();
    pending.hasStableSample = false;
    pending.stableSince = 0.0;
    pending.userid = GetClientUserId(client);
    pending.zc = zc;
    pending.targetSurvivor = targetSurvivor;
    pending.areaIdx = areaIdx;
    pending.navId = areaIdx >= 0 ? GetNavIDByIndex(areaIdx) : -1;
    pending.band = band;
    pending.teleportMode = teleportMode;
    pending.fallback = fallback;
    pending.mode = mode;
    pending.spawnCallMs = spawnCallMs;
    pending.minRange = minRange;
    pending.maxRange = maxRange;
    pending.graphScanMinRange = graphScanMinRange;
    pending.requestedPos = requestedPos;
    pending.reservationToken = (!fallback && areaIdx >= 0)
        ? ReservePendingSpawn(areaIdx, requestedPos) : 0;
    SpawnScore_CopyDbg(pending.score, score);
    g_PendingActualSpawns[client] = pending;
    TeleportState_StampSpawn(client, "pending_begin");

    int reserved;
    if (teleportMode)
        TeleportQueue_DropHead(reserved);
    else
        SpawnQueue_DropHead(reserved);
}

static int SpawnAttempts_ResolvePendingAreaIdx(int slot)
{
    int navId = g_PendingActualSpawns[slot].navId;
    if (navId > 0)
        return GetAreaIndexByNavID_Int(navId);
    return g_PendingActualSpawns[slot].areaIdx;
}

int SpawnAttempts_ProcessPendingActualSpawns()
{
    float now = GetGameTime();
    int processed = 0;
    for (int slot = 1; slot <= MaxClients; slot++)
    {
        if (!g_PendingActualSpawns[slot].active
            || now - g_PendingActualSpawns[slot].createdAt
                < ACTUAL_SPAWN_VALIDATION_MIN_AGE)
        {
            continue;
        }

        int client = GetClientOfUserId(g_PendingActualSpawns[slot].userid);
        int zc = g_PendingActualSpawns[slot].zc;
        float age = now - g_PendingActualSpawns[slot].createdAt;
        bool stable = false;
        if (IsInfectedBot(client) && IsPlayerAlive(client) && !IsGhost(client)
            && GetInfectedClass(client) == zc)
        {
            float actual[3];
            GetClientAbsOrigin(client, actual);
            if (!g_PendingActualSpawns[slot].hasStableSample
                || GetVectorDistance(
                    actual, g_PendingActualSpawns[slot].stablePos) >
                    ACTUAL_SPAWN_STABLE_RADIUS)
            {
                g_PendingActualSpawns[slot].hasStableSample = true;
                g_PendingActualSpawns[slot].stableSince = now;
                g_PendingActualSpawns[slot].stablePos = actual;
            }
            else if (now - g_PendingActualSpawns[slot].stableSince
                >= ACTUAL_SPAWN_STABLE_CONFIRM_SECONDS)
            {
                stable = true;
            }
        }

        if (!stable && age < ACTUAL_SPAWN_VALIDATION_MAX_AGE)
            continue;

        float validationStart = GetEngineTime();
        bool persistentUnsafe = false;
        bool directorDistanceValid = true;
        if (stable && g_PendingActualSpawns[slot].fallback)
        {
            float actual[3];
            float teamMinDistance;
            GetClientAbsOrigin(client, actual);
            directorDistanceValid = DirectorFallback_IsWithinTeamDistance(
                actual, teamMinDistance);
            if (!directorDistanceValid)
            {
                SpawnPerf_Log(
                    "[SpawnPerf][DirectorCap] stage=actual class=%s result=rejected teamMinDistance=%.1f cap=%.1f request=(%.1f %.1f %.1f) actual=(%.1f %.1f %.1f) client=%d mode=%d",
                    g_sInfectedClassNames[zc], teamMinDistance,
                    DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE,
                    g_PendingActualSpawns[slot].requestedPos[0],
                    g_PendingActualSpawns[slot].requestedPos[1],
                    g_PendingActualSpawns[slot].requestedPos[2],
                    actual[0], actual[1], actual[2], client,
                    view_as<int>(g_PendingActualSpawns[slot].mode));
                Debug_Print(
                    "[SPAWN REJECT ACTUAL] class=%s idx=%d reason=director_distance teamMinDistance=%.1f cap=%.1f",
                    g_sInfectedClassNames[zc], client, teamMinDistance,
                    DIRECTOR_FALLBACK_MAX_TEAM_DISTANCE);
            }
        }
        // Director API points keep their legacy visibility/path policy, but
        // request and settled positions must remain within the team hard cap.
        bool valid = stable && (g_PendingActualSpawns[slot].fallback
            ? directorDistanceValid
            : SpawnAttempts_ValidateActualSpawn(
                client, zc, g_PendingActualSpawns[slot].teleportMode,
                persistentUnsafe));
        if (!stable)
        {
            Debug_Print("[SPAWN REJECT ACTUAL] class=%s idx=%d reason=unstable ageMs=%.1f",
                g_sInfectedClassNames[zc], client, age * 1000.0);
        }
        float validationMs = (GetEngineTime() - validationStart) * 1000.0;
        SpawnPerf_Log("[SpawnPerf][ActualValidation] class=%s result=%s ms=%.3f client=%d mode=%d ageMs=%.1f",
            g_sInfectedClassNames[zc], valid ? "accepted" : "rejected",
            validationMs, client, view_as<int>(g_PendingActualSpawns[slot].mode),
            age * 1000.0);

        int currentAreaIdx = g_PendingActualSpawns[slot].fallback
            ? -1 : SpawnAttempts_ResolvePendingAreaIdx(slot);

        if (!valid)
        {
            if (g_PendingActualSpawns[slot].fallback)
            {
                WaveSpawnReport_RecordFallback(
                    zc, 0, g_PendingActualSpawns[slot].mode,
                    g_PendingActualSpawns[slot].spawnCallMs,
                    g_PendingActualSpawns[slot].requestedPos,
                    g_PendingActualSpawns[slot].minRange,
                    g_PendingActualSpawns[slot].maxRange,
                    g_PendingActualSpawns[slot].targetSurvivor);
                RecordDirectorSpawnResult(
                    g_PendingActualSpawns[slot].requestedPos, false);
            }
            else
            {
                WaveSpawnReport_RecordScored(
                    zc, 0, g_PendingActualSpawns[slot].mode,
                    g_PendingActualSpawns[slot].spawnCallMs,
                    g_PendingActualSpawns[slot].requestedPos,
                    g_PendingActualSpawns[slot].minRange,
                    g_PendingActualSpawns[slot].maxRange,
                    g_PendingActualSpawns[slot].score,
                    g_PendingActualSpawns[slot].targetSurvivor);
                if (currentAreaIdx >= 0)
                {
                    float cooldown = persistentUnsafe
                        ? NAV_UNSAFE_GEOMETRY_CD_SECS : NAV_CD_SECS;
                    TouchNavCooldown(
                        currentAreaIdx, now, cooldown);
                    if (persistentUnsafe)
                    {
                        Debug_Print("[SPAWN ACTUAL] persistent unsafe area=%d cooldown=%.1fs",
                            currentAreaIdx, cooldown);
                    }
                }
            }
            if (client > 0 && IsClientInGame(client))
            {
                g_bRejectedActualSpawn[client] = true;
                KickClient(client, "Rejected unsafe actual spawn position");
                TeleportState_ClearClient(client);
            }
            if (g_PendingActualSpawns[slot].teleportMode)
            {
                TeleportQueue_Push(zc);
                SpawnSearch_ResetClass(zc, true);
                g_iTeleportSearchBand[zc - 1] = ClampInt(
                    g_PendingActualSpawns[slot].band + 1,
                    0, TACTICAL_BAND_STAGES + 1);
            }
            else
            {
                SpawnQueue_Push(zc);
                SpawnSearch_ResetClass(zc, false);
                g_iNormalSearchBand[zc - 1] = ClampInt(
                    g_PendingActualSpawns[slot].band + 1,
                    0, TACTICAL_BAND_STAGES + 1);
            }
            Debug_Print("[SPAWN ACTUAL] rejected class=%s; class returned to queue nextBand=%d",
                g_sInfectedClassNames[zc],
                g_PendingActualSpawns[slot].teleportMode
                    ? g_iTeleportSearchBand[zc - 1]
                    : g_iNormalSearchBand[zc - 1]);
        }
        else
        {
            if (g_PendingActualSpawns[slot].fallback)
            {
                WaveSpawnReport_RecordFallback(
                    zc, client, g_PendingActualSpawns[slot].mode,
                    g_PendingActualSpawns[slot].spawnCallMs,
                    g_PendingActualSpawns[slot].requestedPos,
                    g_PendingActualSpawns[slot].minRange,
                    g_PendingActualSpawns[slot].maxRange,
                    g_PendingActualSpawns[slot].targetSurvivor);
                RecordDirectorSpawnResult(
                    g_PendingActualSpawns[slot].requestedPos, true);
            }
            else
            {
                WaveSpawnReport_RecordScored(
                    zc, client, g_PendingActualSpawns[slot].mode,
                    g_PendingActualSpawns[slot].spawnCallMs,
                    g_PendingActualSpawns[slot].requestedPos,
                    g_PendingActualSpawns[slot].minRange,
                    g_PendingActualSpawns[slot].maxRange,
                    g_PendingActualSpawns[slot].score,
                    g_PendingActualSpawns[slot].targetSurvivor);
                LogChosenSpawnScore(zc, g_PendingActualSpawns[slot].score);
                if (currentAreaIdx >= 0)
                    TouchNavCooldown(
                        currentAreaIdx, now, NAV_CD_SECS);
            }

            SpawnAttempts_RememberActualSpawn(
                client, g_PendingActualSpawns[slot].requestedPos,
                g_PendingActualSpawns[slot].targetSurvivor);
            TeleportState_StampSpawn(client, "pending_commit");
            g_LastSpawnOkTime = now;
            InvalidateBucketShareCache();
            gST.siAlive[zc - 1]++;
            gST.totalSI++;
            if (g_PendingActualSpawns[slot].teleportMode)
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
            Debug_Print("[SPAWN OK] %s idx=%d actual validated after %.1fms",
                g_sInfectedClassNames[zc], client,
                (now - g_PendingActualSpawns[slot].createdAt) * 1000.0);
            if (gCV.iDebugMode > 0)
                CreateTimer(0.15, Timer_LogSpawnedSIState,
                    GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        }

        int committedUserid = valid ? GetClientUserId(client) : 0;
        ReleasePendingSpawnReservation(
            g_PendingActualSpawns[slot].reservationToken);
        g_PendingActualSpawns[slot].reservationToken = 0;
        g_PendingActualSpawns[slot].active = false;
        g_PendingActualSpawns[slot].userid = 0;
        if (valid && committedUserid > 0
            && g_hSpawnCommittedForward != INVALID_HANDLE)
        {
            Call_StartForward(g_hSpawnCommittedForward);
            Call_PushCell(committedUserid);
            Call_Finish();
        }
        processed++;
    }
    return processed;
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

    if (SpawnAttempts_HasReachedAliveLimitWithPending(want))
    {
        Debug_Print("[SPAWN DROP] class=%s reached alive-cap, drop head", g_sInfectedClassNames[want]);
        SpawnQueue_DropHead(want);
        gST.normalFallbackCycles[want - 1] = 0;
        SpawnAttempts_ResetNormalProgress(want);
        return;
    }
    if (SpawnAttempts_HasReachedWaveLimitWithPending(want))
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
            graphScanMinRange, false, pos, areaIdx, bestDbg);
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
        SpawnAttempts_BeginPending(
            spawnedClient, want, false, false,
            WaveSpawn_NormalNav, spawnCallMs, pos,
            searchTarget, minRange, maxRange, areaIdx, band,
            graphScanMinRange, bestDbg);
        return;
    }

    minRange = gCV.fSpawnMin;
    maxRange = gCV.fSpawnMax;
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
        // The second fallback widens only the far edge. It never lowers the
        // configured minimum, avoiding the old near/full-range explosion.
        maxRange = FloatMin(
            gCV.fSpawnMax * EXTENDED_DIRECTOR_MAX_SCALE,
            gCV.fSpawnMax * NAV_PATH_DISTANCE_SCALE);
        fallbackFound = FallbackDirectorPos(
            want, searchTarget, EXTENDED_DIRECTOR_TRIES, pt);
    }
    else
        fallbackFound = FallbackDirectorPos(
            want, searchTarget, DIRECTOR_BASE_API_TRIES, pt);
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
            SpawnAttempts_BeginPending(
                fallbackClient, want, false, true,
                reportMode, spawnCallMs, pt,
                searchTarget, minRange, maxRange,
                -1, g_iNormalSearchBand[searchIdx], 0.0, fallbackScore);
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
        RecordDirectorSpawnResult(pt, fallbackSpawned);

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
    if (gST.totalSI + SpawnAttempts_CountPendingActualSpawns() >= gCV.iSiLimit)
        return;
    if (SpawnAttempts_HasReachedAliveLimitWithPending(want))
    {
        RecalcSiCapFromAlive(false);
        if (gST.totalSI >= gCV.iSiLimit)
            return;

        if (SpawnAttempts_HasReachedAliveLimitWithPending(want))
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
            graphScanMinRange, true, pos, areaIdx, bestDbg);
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
        SpawnAttempts_BeginPending(
            spawnedClient, want, true, false,
            WaveSpawn_TeleportNav, spawnCallMs, pos,
            teleportTarget, minRange, maxRange, areaIdx, band,
            graphScanMinRange, bestDbg);
        return;
    }

    minRange = FloatMax(gCV.fSpawnMin, gCV.fTeleportSpawnMin);
    maxRange = gCV.fSpawnMax;
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
            want, teleportTarget, EXTENDED_DIRECTOR_TRIES, pt);
    else
        fallbackFound = FallbackDirectorPos(
            want, teleportTarget, DIRECTOR_BASE_API_TRIES, pt);
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
            SpawnAttempts_BeginPending(
                fallbackClient, want, true, true,
                reportMode, spawnCallMs, pt,
                teleportTarget, minRange, maxRange,
                -1, g_iTeleportSearchBand[searchIdx], 0.0, fallbackScore);
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
        RecordDirectorSpawnResult(pt, fallbackSpawned);

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
