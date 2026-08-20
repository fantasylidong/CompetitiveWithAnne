#if defined _infected_control_anti_baiter_included
    #endinput
#endif
#define _infected_control_anti_baiter_included

enum AntiBaitState
{
    AB_Off = 0,
    AB_Grace,
    AB_Observe,
    AB_Pressure,
    AB_Recover,
    AB_Paused
}

enum struct AntiBaitRuntime
{
    AntiBaitState state;
    int baselineAvgPct;
    int baselineMaxPct;
    int baselineMedianPct;
    float baselineCenter[3];
    int lastAvgPct;
    int lastMaxPct;
    int lastMedianPct;
    int runner;
    int holdingTarget;
    int activeCount;
    int vulnerableCount;
    int isolatedCount;
    int groupCount;
    float stateSince;
    float lastProgressTime;
    float pressureSince;
    float spreadSince;         // Pressure 中散开候选的起始时间；0=无候选
    float blockedSince;
    float lastSpreadDist;
    float lastAvgNearestDist;
    bool baselineCenterValid;  // 位置基线是否已建立（防止从原点误判位移推进）
    bool teamHolding;
    bool attackableSpread;
    bool allPinned;
    bool spreadStallPressure;
    bool eventSuppressed;
    AntiBaitState resumeState;

    void Reset()
    {
        this.state = AB_Off;
        this.baselineAvgPct = -1;
        this.baselineMaxPct = -1;
        this.baselineMedianPct = -1;
        this.baselineCenter[0] = 0.0;
        this.baselineCenter[1] = 0.0;
        this.baselineCenter[2] = 0.0;
        this.lastAvgPct = -1;
        this.lastMaxPct = -1;
        this.lastMedianPct = -1;
        this.runner = -1;
        this.holdingTarget = -1;
        this.activeCount = 0;
        this.vulnerableCount = 0;
        this.isolatedCount = 0;
        this.groupCount = 0;
        this.stateSince = 0.0;
        this.lastProgressTime = 0.0;
        this.pressureSince = 0.0;
        this.spreadSince = 0.0;
        this.blockedSince = 0.0;
        this.lastSpreadDist = 0.0;
        this.lastAvgNearestDist = 0.0;
        this.baselineCenterValid = false;
        this.teamHolding = false;
        this.attackableSpread = false;
        this.allPinned = false;
        this.spreadStallPressure = false;
        this.eventSuppressed = false;
        this.resumeState = AB_Grace;
    }
}

static AntiBaitRuntime gAB;

static const char g_sAntiBaitStateName[][] =
{
    "Off",
    "Grace",
    "Observe",
    "Pressure",
    "Recover",
    "Paused"
};

static void AntiBait_Debug(const char[] fmt, any ...)
{
    if (!gCV.bAntiBaitDebug && gCV.iDebugMode <= 0)
        return;

    char msg[256];
    VFormat(msg, sizeof msg, fmt, 2);
    Debug_Print("[AB] %s", msg);
}

static void AntiBait_SetState(AntiBaitState next, float now, const char[] reason)
{
    if (gAB.state == next)
        return;

    AntiBait_Debug("%s -> %s (%s)", g_sAntiBaitStateName[view_as<int>(gAB.state)], g_sAntiBaitStateName[view_as<int>(next)], reason);
    gAB.state = next;
    gAB.stateSince = now;
    if (next == AB_Pressure)
    {
        gAB.pressureSince = now;
        gAB.spreadSince = 0.0;
    }
    else
        gAB.spreadStallPressure = false;
}

static int AntiBait_ClampPct(int pct)
{
    if (pct < 0) return 0;
    if (pct > 100) return 100;
    return pct;
}

static bool AntiBait_GetProgressSnapshot(int &avgPct,
                                         int &maxPct,
                                         int &medianPct,
                                         int &highestClient,
                                         float &spreadDist,
                                         float &avgNearestDist,
                                         int &activeCount,
                                         int &vulnerableCount,
                                         int &isolatedCount,
                                         int &groupCount,
                                         float center[3])
{
    int flowPcts[MAX_FORMATION_SLOTS];
    int n = 0;
    int flowN = 0;
    int flowSum = 0;
    avgPct = -1;
    maxPct = -1;
    medianPct = -1;
    highestClient = -1;
    spreadDist = 0.0;
    avgNearestDist = 0.0;
    activeCount = 0;
    vulnerableCount = 0;
    isolatedCount = 0;
    groupCount = 0;
    center[0] = 0.0;
    center[1] = 0.0;
    center[2] = 0.0;
    float pos[MAX_FORMATION_SLOTS][3];
    float nearest[MAX_FORMATION_SLOTS];
    bool linked[MAX_FORMATION_SLOTS][MAX_FORMATION_SLOTS];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i))
            continue;

        // 有意设计：阵亡者同样计入 vulnerableCount。AntiBait_ShouldHoldWave
        // 要求 vulnerableCount == 0，所以本局一旦有人阵亡，卡点无限延长就
        // 整局不再生效——队伍已经减员时不再追加拦波压力。这不是漏判，
        // 不要“修”成只统计存活但被控/倒地的人。
        if (!IsPlayerAlive(i) || L4D_IsPlayerIncapacitated(i)
            || IsSurvivorHangingFromLedge(i) || IsPinned(i))
        {
            vulnerableCount++;
            continue;
        }

        if (n >= MAX_FORMATION_SLOTS)
            continue;

        // 行动能力正常的成员一律参与位置/队形统计。flow 读取失败（电梯、
        // 坏 Nav 等）不算“脆弱”，只是不参与 flow 进度统计，避免短暂的
        // 进度读取故障错误地阻止或解除强化保持。
        GetClientAbsOrigin(i, pos[n]);
        center[0] += pos[n][0];
        center[1] += pos[n][1];
        center[2] += pos[n][2];
        nearest[n] = 999999.0;
        n++;
        activeCount++;

        int pct;
        if (TryGetClientFlowPercentSafe(i, pct))
        {
            pct = AntiBait_ClampPct(pct);
            flowPcts[flowN++] = pct;
            flowSum += pct;
            if (pct > maxPct)
            {
                maxPct = pct;
                highestClient = i;
            }
        }
    }

    if (n <= 0)
        return false;

    center[0] /= float(n);
    center[1] /= float(n);
    center[2] /= float(n);

    if (flowN > 0)
    {
        SortIntegers(flowPcts, flowN, Sort_Ascending);
        avgPct = RoundToNearest(float(flowSum) / float(flowN));
        medianPct = flowPcts[(flowN - 1) / 2];
    }
    // flowN == 0：avg/max/median 保持 -1，进度改由位置位移判定。

    for (int i = 0; i < n; i++)
    {
        for (int j = 0; j < n; j++)
            linked[i][j] = (i == j);
    }

    for (int i = 0; i < n; i++)
    {
        for (int j = i + 1; j < n; j++)
        {
            float dist = GetVectorDistance(pos[i], pos[j]);
            if (dist > spreadDist)
                spreadDist = dist;
            if (dist < nearest[i])
                nearest[i] = dist;
            if (dist < nearest[j])
                nearest[j] = dist;
            if (gCV.fAntiBaitPairDist > 0.0 && dist <= gCV.fAntiBaitPairDist)
            {
                linked[i][j] = true;
                linked[j][i] = true;
            }
        }
    }

    if (gCV.fAntiBaitPairDist > 0.0)
    {
        bool seen[MAX_FORMATION_SLOTS];
        int stack[MAX_FORMATION_SLOTS];
        for (int i = 0; i < n; i++)
            seen[i] = false;

        for (int i = 0; i < n; i++)
        {
            if (seen[i])
                continue;

            groupCount++;
            int top = 0;
            stack[top++] = i;
            seen[i] = true;

            while (top > 0)
            {
                int cur = stack[--top];
                for (int j = 0; j < n; j++)
                {
                    if (seen[j] || !linked[cur][j])
                        continue;

                    seen[j] = true;
                    if (top < sizeof(stack))
                        stack[top++] = j;
                }
            }
        }
    }
    else
    {
        groupCount = 1;
    }

    if (n > 1)
    {
        float nearestSum = 0.0;
        for (int i = 0; i < n; i++)
        {
            nearestSum += nearest[i];
            if (gCV.fAntiBaitIsolateDist > 0.0 && nearest[i] >= gCV.fAntiBaitIsolateDist)
                isolatedCount++;
        }
        avgNearestDist = nearestSum / float(n);
    }

    return true;
}

#define ANTI_BAIT_KIT_SLOT  3
#define ANTI_BAIT_PILL_SLOT 4

static bool AntiBait_SlotHasHealItem(int client, int slot)
{
    int item = GetPlayerWeaponSlot(client, slot);
    if (item <= MaxClients || !IsValidEntity(item))
        return false;

    char cls[32];
    GetEntityClassname(item, cls, sizeof cls);
    return StrEqual(cls, "weapon_first_aid_kit")
        || StrEqual(cls, "weapon_defibrillator")
        || StrEqual(cls, "weapon_pain_pills")
        || StrEqual(cls, "weapon_adrenaline");
}

static bool AntiBait_SurvivorHasHealItem(int client)
{
    return AntiBait_SlotHasHealItem(client, ANTI_BAIT_KIT_SLOT)
        || AntiBait_SlotHasHealItem(client, ANTI_BAIT_PILL_SLOT);
}

// 站着的人生还实血都低于阈值，且存活队员都没有药时关掉 Anti-Bait。
// 药 = 医疗包 / 电击器 / 止痛药 / 针。threshold<=0 关闭本检查。
// 倒地血不是实血，不参与阈值比较；倒地者身上的药仍算“队里有药”。
static bool AntiBait_IsTeamLowHpNoMeds()
{
    int threshold = gCV.iAntiBaitLowHp;
    if (threshold <= 0)
        return false;

    int standing = 0;
    bool anyHealItem = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        if (AntiBait_SurvivorHasHealItem(i))
            anyHealItem = true;

        if (L4D_IsPlayerIncapacitated(i) || IsSurvivorHangingFromLedge(i))
            continue;

        standing++;
        if (GetClientHealth(i) >= threshold)
            return false;
    }

    return standing > 0 && !anyHealItem;
}

static bool AntiBait_IsEventBlocked()
{
    if (!gCV.bAntiBaitEnable)
        return true;
    if (!gST.bLate)
        return true;
    if (g_bPauseLib && IsInPause())
        return true;
    // A distant Tank is not pressure yet: keep holding until it approaches or
    // the survivor formation becomes attackable.
    if (IsTankPressureActive() || AreAtLeastHalfSurvivorsDownOrDead())
        return true;
    if (gAB.allPinned)
        return true;
    // 额外一条：全员低实血且没药时也暂停。不替代 Tank / 半数倒地 / 全员被控。
    if (AntiBait_IsTeamLowHpNoMeds())
        return true;
    return false;
}

static bool AntiBait_TeamHoldingFormation(float spreadDist, float avgNearestDist,
                                          int activeCount, int isolatedCount, int groupCount)
{
    if (activeCount < 2)
        return false;

    if (groupCount > 1)
        return false;

    if (isolatedCount > 0)
        return false;

    if (gCV.fAntiBaitClusterDist > 0.0 && spreadDist <= gCV.fAntiBaitClusterDist)
        return true;

    if (gCV.fAntiBaitTeamDist > 0.0 && spreadDist > gCV.fAntiBaitTeamDist)
        return false;

    return gCV.fAntiBaitPairDist <= 0.0 || avgNearestDist <= gCV.fAntiBaitPairDist;
}

static bool AntiBait_TeamAttackableSpread(float spreadDist, int activeCount,
                                          int isolatedCount, int groupCount)
{
    if (activeCount < 2)
        return true;

    if (groupCount > 1)
        return true;

    if (isolatedCount > 0)
        return true;

    return gCV.fAntiBaitTeamDist > 0.0 && spreadDist >= gCV.fAntiBaitTeamDist;
}

// === 新增：供 WaveDecider 使用的公共接口 ===
stock bool AntiBait_IsStalled()
{
    // 检查生还者是否停滞不前
    float now = GetGameTime();
    float stalledTime = now - gAB.lastProgressTime;
    return stalledTime >= gCV.fAntiBaitWindow;
}

stock bool AntiBait_IsTeamHolding()
{
    return gAB.teamHolding;
}

stock bool AntiBait_IsAttackableSpread()
{
    return gAB.attackableSpread;
}

stock bool AntiBait_ShouldHoldWave()
{
    if (!gCV.bAntiBaitEnable || gCV.iAntiBaitAction < 1)
        return false;
    if (gAB.state != AB_Pressure || gAB.spreadStallPressure)
        return false;
    if (gAB.activeCount < 2 || gAB.vulnerableCount > 0)
        return false;
    if (!AntiBait_IsStalled())
        return false;

    // 队形语义由状态机维护：进入 Pressure 需要集结确认，离开 Pressure
    // 需要散开持续 fAntiBaitSpreadConfirm 秒。这里不再看瞬时 teamHolding，
    // 否则一两秒的假走位就能把保持骗掉。
    return (GetGameTime() - gAB.pressureSince) >= gCV.fAntiBaitHoldConfirm;
}

stock bool AntiBait_ShouldReleaseFromIntensive()
{
    return !AntiBait_ShouldHoldWave();
}

stock void AntiBait_GetHoldMetrics(int &activeCount, int &vulnerableCount,
                                   float &spreadDist, float &avgNearestDist,
                                   float &stalledSecs, float &pressureSecs)
{
    float now = GetGameTime();
    activeCount = gAB.activeCount;
    vulnerableCount = gAB.vulnerableCount;
    spreadDist = gAB.lastSpreadDist;
    avgNearestDist = gAB.lastAvgNearestDist;
    stalledSecs = FloatMax(0.0, now - gAB.lastProgressTime);
    pressureSecs = gAB.pressureSince > 0.0
        ? FloatMax(0.0, now - gAB.pressureSince)
        : 0.0;
}

static bool AntiBait_IsPreferredTargetEligible(int client)
{
    return IsEligibleSpawnTarget(client)
        && (!g_bTargetLimitLib || !IsClientReachLimit(client));
}

static int AntiBait_SelectHoldingTarget()
{
    float center[3];
    float pos[MAX_FORMATION_SLOTS][3];
    int clients[MAX_FORMATION_SLOTS];
    int count = 0;

    for (int client = 1; client <= MaxClients && count < sizeof(clients); client++)
    {
        if (!IsValidSurvivor(client) || !IsPlayerAlive(client) || L4D_IsPlayerIncapacitated(client))
            continue;

        clients[count] = client;
        GetClientAbsOrigin(client, pos[count]);
        center[0] += pos[count][0];
        center[1] += pos[count][1];
        center[2] += pos[count][2];
        count++;
    }

    if (count <= 0)
        return -1;

    center[0] /= float(count);
    center[1] /= float(count);
    center[2] /= float(count);

    int target = -1;
    float bestDistSq = -1.0;
    for (int i = 0; i < count; i++)
    {
        int client = clients[i];
        if (IsPinned(client) || !AntiBait_IsPreferredTargetEligible(client))
            continue;

        float distSq = GetVectorDistance(pos[i], center, true);
        if (target < 0 || distSq > bestDistSq)
        {
            target = client;
            bestDistSq = distSq;
        }
    }

    return target;
}

static void AntiBait_Pause(float now)
{
    if (gAB.state == AB_Paused)
        return;

    gAB.resumeState = gAB.state;
    if (gAB.resumeState == AB_Off || gAB.resumeState == AB_Paused)
        gAB.resumeState = AB_Grace;
    gAB.blockedSince = now;
    AntiBait_SetState(AB_Paused, now, "event blocked");
}

static void AntiBait_Resume(float now)
{
    float pausedFor = (gAB.blockedSince > 0.0) ? (now - gAB.blockedSince) : 0.0;
    if (pausedFor > 0.0)
    {
        gAB.lastProgressTime += pausedFor;
        gAB.stateSince += pausedFor;
        if (gAB.pressureSince > 0.0)
            gAB.pressureSince += pausedFor;
        if (gAB.spreadSince > 0.0)
            gAB.spreadSince += pausedFor;
    }

    AntiBaitState resume = gAB.resumeState;
    if (resume == AB_Off || resume == AB_Paused)
        resume = AB_Grace;
    gAB.blockedSince = 0.0;
    AntiBait_SetState(resume, now, "event block cleared");
}

static bool AntiBait_IsRunnerCandidate(int client, int maxPct, int medianPct)
{
    if (!IsValidSurvivor(client) || !IsPlayerAlive(client) || IsPinned(client) || L4D_IsPlayerIncapacitated(client))
        return false;

    if ((maxPct - medianPct) < gCV.iAntiBaitRunnerGapPct)
        return false;

    float runnerPos[3], otherPos[3];
    GetClientAbsOrigin(client, runnerPos);

    bool hasNearbySurvivor = false;
    float nearDist2 = gCV.fAntiBaitRunnerNearDist * gCV.fAntiBaitRunnerNearDist;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || !IsValidSurvivor(i) || !IsPlayerAlive(i) || L4D_IsPlayerIncapacitated(i))
            continue;

        GetClientAbsOrigin(i, otherPos);
        if (GetVectorDistance(runnerPos, otherPos, true) <= nearDist2)
        {
            hasNearbySurvivor = true;
            break;
        }
    }

    return !hasNearbySurvivor;
}

static void AntiBait_UpdateRunner(int highestClient, int maxPct, int medianPct)
{
    bool oldOn = gST.bPickRushMan;
    int oldRunner = gST.rushManIndex;

    if (AntiBait_IsRunnerCandidate(highestClient, maxPct, medianPct))
    {
        gAB.runner = highestClient;
        gST.bPickRushMan = true;
        gST.rushManIndex = highestClient;

        if (!oldOn || oldRunner != highestClient)
        {
            LogMsg("Runner state ON: %N", highestClient);
            EmitRushmanForward(highestClient);
        }
    }
    else
    {
        gAB.runner = -1;
        gST.bPickRushMan = false;
        gST.rushManIndex = -1;
        if (oldOn)
            LogMsg("Runner state OFF");
    }
}

static void AntiBait_ClearRunner()
{
    if (gST.bPickRushMan)
        LogMsg("Runner state OFF");

    gAB.runner = -1;
    gST.bPickRushMan = false;
    gST.rushManIndex = -1;
}

static void AntiBait_StartFresh(float now, const char[] reason)
{
    gAB.Reset();
    gAB.state = gCV.bAntiBaitEnable ? AB_Grace : AB_Off;
    gAB.stateSince = now;
    gAB.lastProgressTime = now;

    int avgPct, maxPct, medianPct, highest, activeCount, vulnerableCount, isolatedCount, groupCount;
    float spreadDist, avgNearestDist, center[3];
    if (AntiBait_GetProgressSnapshot(avgPct, maxPct, medianPct, highest,
        spreadDist, avgNearestDist, activeCount, vulnerableCount,
        isolatedCount, groupCount, center))
    {
        gAB.baselineAvgPct = avgPct;
        gAB.baselineMaxPct = maxPct;
        gAB.baselineMedianPct = medianPct;
        gAB.baselineCenter = center;
        gAB.baselineCenterValid = true;
        gAB.lastAvgPct = avgPct;
        gAB.lastMaxPct = maxPct;
        gAB.lastMedianPct = medianPct;
        gAB.lastSpreadDist = spreadDist;
        gAB.lastAvgNearestDist = avgNearestDist;
        gAB.activeCount = activeCount;
        gAB.vulnerableCount = vulnerableCount;
        gAB.isolatedCount = isolatedCount;
        gAB.groupCount = groupCount;
        gAB.teamHolding = AntiBait_TeamHoldingFormation(
            spreadDist, avgNearestDist, activeCount, isolatedCount, groupCount);
        gAB.attackableSpread = AntiBait_TeamAttackableSpread(
            spreadDist, activeCount, isolatedCount, groupCount);
    }

    AntiBait_Debug("fresh start state=%s reason=%s",
        g_sAntiBaitStateName[view_as<int>(gAB.state)], reason);
}

void AntiBait_OnEventPressureStarted(const char[] source)
{
    if (gAB.eventSuppressed)
        return;

    AntiBait_ClearRunner();
    gAB.Reset();
    gAB.eventSuppressed = true;
    gAB.state = AB_Off;
    gAB.stateSince = GetGameTime();
    gAB.lastProgressTime = gAB.stateSince;
    AntiBait_Debug("disabled by event pressure source=%s", source);
}

void AntiBait_OnRoundStart()
{
    gAB.Reset();
}

void AntiBait_OnPause()
{
    if (gAB.state != AB_Off && gAB.state != AB_Paused)
        AntiBait_Pause(GetGameTime());
}

void AntiBait_OnUnpause()
{
    if (gAB.state == AB_Paused)
        AntiBait_Resume(GetGameTime());
}

void AntiBait_OnWaveStart()
{
    float now = GetGameTime();
    if (EventPressure_ShouldBypassAntiBait())
    {
        AntiBait_OnEventPressureStarted("wave_start_during_event");
        return;
    }

    AntiBait_StartFresh(now, "wave start");
}

void AntiBait_Update()
{
    float now = GetGameTime();
    gAB.allPinned = Survivors_AllPinnedOrDown();

    if (EventPressure_ShouldBypassAntiBait())
    {
        AntiBait_OnEventPressureStarted("active_event");
        return;
    }

    if (gAB.eventSuppressed)
        AntiBait_StartFresh(now, "event pressure ended");

    if (!gCV.bAntiBaitEnable)
    {
        AntiBait_ClearRunner();
        AntiBait_SetState(AB_Off, now, "disabled");
        return;
    }

    if (AntiBait_IsEventBlocked())
    {
        AntiBait_ClearRunner();
        if (gAB.state != AB_Paused)
            AntiBait_Debug("blocked state=%s allPinned=%d scriptedEvent=%d tankPressure=%d lowHpNoMeds=%d",
                g_sAntiBaitStateName[view_as<int>(gAB.state)],
                gAB.allPinned,
                EventPressure_ShouldBypassAntiBait(),
                IsTankPressureActive(),
                AntiBait_IsTeamLowHpNoMeds());
        AntiBait_Pause(now);
        return;
    }

    if (gAB.state == AB_Paused)
        AntiBait_Resume(now);

    int avgPct, maxPct, medianPct, highest, activeCount, vulnerableCount, isolatedCount, groupCount;
    float spreadDist, avgNearestDist, center[3];
    if (!AntiBait_GetProgressSnapshot(avgPct, maxPct, medianPct, highest,
        spreadDist, avgNearestDist, activeCount, vulnerableCount,
        isolatedCount, groupCount, center))
    {
        gAB.activeCount = activeCount;
        gAB.vulnerableCount = vulnerableCount;
        gAB.teamHolding = false;
        gAB.attackableSpread = true;
        return;
    }

    gAB.lastAvgPct = avgPct;
    gAB.lastMaxPct = maxPct;
    gAB.lastMedianPct = medianPct;
    gAB.lastSpreadDist = spreadDist;
    gAB.lastAvgNearestDist = avgNearestDist;
    gAB.activeCount = activeCount;
    gAB.vulnerableCount = vulnerableCount;
    gAB.isolatedCount = isolatedCount;
    gAB.groupCount = groupCount;
    gAB.teamHolding = AntiBait_TeamHoldingFormation(
        spreadDist, avgNearestDist, activeCount, isolatedCount, groupCount);
    gAB.attackableSpread = AntiBait_TeamAttackableSpread(
        spreadDist, activeCount, isolatedCount, groupCount);
    gAB.holdingTarget = gAB.teamHolding ? AntiBait_SelectHoldingTarget() : -1;
    AntiBait_UpdateRunner(highest, maxPct, medianPct);

    // 位置基线：本波第一次拿到有效快照时建立（含停滞时钟起点）。
    if (!gAB.baselineCenterValid)
    {
        gAB.baselineCenter = center;
        gAB.baselineCenterValid = true;
        gAB.lastProgressTime = now;
    }

    // Flow 基线：flow 从不可读恢复为可读时补建。这不是玩家推进，
    // 不重置停滞时钟。
    if ((gAB.baselineAvgPct < 0 || gAB.baselineMaxPct < 0 || gAB.baselineMedianPct < 0)
        && medianPct >= 0)
    {
        gAB.baselineAvgPct = avgPct;
        gAB.baselineMaxPct = maxPct;
        gAB.baselineMedianPct = medianPct;
    }

    // 使用下中位数要求过半核心成员推进；单人探路不再替全队重置停滞计时。
    bool flowKnown = (medianPct >= 0 && gAB.baselineMedianPct >= 0);
    int flowDelta = flowKnown ? (medianPct - gAB.baselineMedianPct) : 0;
    float movedDist = GetVectorDistance(center, gAB.baselineCenter);
    bool progressedByFlow = flowKnown && flowDelta >= gCV.iAntiBaitProgressPct;
    bool progressedByDistance = gCV.fAntiBaitProgressDist > 0.0
        && movedDist >= gCV.fAntiBaitProgressDist;
    bool progressed = progressedByFlow || progressedByDistance;
    bool releasedBySpread = gAB.attackableSpread;

    if (gAB.state == AB_Pressure && gAB.spreadStallPressure && gAB.teamHolding)
    {
        gAB.spreadStallPressure = false;
        gAB.pressureSince = now;
        AntiBait_Debug("spread pressure became stable holding pressure");
    }

    if (progressed)
    {
        gAB.baselineAvgPct = avgPct;
        gAB.baselineMaxPct = maxPct;
        gAB.baselineMedianPct = medianPct;
        gAB.baselineCenter = center;
        gAB.lastProgressTime = now;
        gAB.spreadStallPressure = false;
        gAB.spreadSince = 0.0;

        AntiBait_Debug("progress reset flowDelta=%d threshold=%d moved=%.1f threshold=%.1f",
            flowDelta, gCV.iAntiBaitProgressPct, movedDist, gCV.fAntiBaitProgressDist);

        if (gAB.state == AB_Pressure)
            AntiBait_SetState(AB_Recover, now,
                progressedByFlow ? "flow progress" : "position progress");
        else if (gAB.state == AB_Recover && (now - gAB.stateSince) >= gCV.fAntiBaitRecover)
            AntiBait_SetState(AB_Observe, now, "recovered");
        return;
    }

    // 散开不算推进：不重置停滞时钟。Pressure 中的散开需要持续
    // fAntiBaitSpreadConfirm 秒才降级为 Recover；短暂走位马上回聚会
    // 取消散开候选，保持不被“假走位”骗掉。
    if (gAB.state == AB_Pressure && !gAB.spreadStallPressure)
    {
        if (releasedBySpread)
        {
            if (gAB.spreadSince <= 0.0)
            {
                gAB.spreadSince = now;
                AntiBait_Debug("spread candidate started (confirm=%.1fs)",
                    gCV.fAntiBaitSpreadConfirm);
            }
            else if ((now - gAB.spreadSince) >= gCV.fAntiBaitSpreadConfirm)
            {
                gAB.spreadSince = 0.0;
                AntiBait_SetState(AB_Recover, now, "spread confirmed");
                return;
            }
            // 确认期内维持 Pressure，波次拦截不解除。
        }
        else if (gAB.spreadSince > 0.0)
        {
            gAB.spreadSince = 0.0;
            AntiBait_Debug("spread candidate cancelled (regrouped)");
        }
    }

    if (gAB.state == AB_Grace)
    {
        if ((now - gAB.stateSince) >= gCV.fAntiBaitGrace)
            AntiBait_SetState(AB_Observe, now, "grace done");
        return;
    }

    if (gAB.state == AB_Recover)
    {
        // 停滞从未被真实推进打断且重新集结时，武装窗口内直接重返
        // Pressure。视作同一次保持的延续，补齐 pressureSince，避免
        // WaveDecider 的释放确认在重武装完成前先到期。
        if (WaveDecider_IsAntiBaitArmWindowOpen() && gAB.teamHolding
            && (now - gAB.lastProgressTime) >= gCV.fAntiBaitWindow)
        {
            AntiBait_SetState(AB_Pressure, now, "regrouped while still stalled");
            gAB.spreadStallPressure = false;
            gAB.pressureSince = now - gCV.fAntiBaitHoldConfirm;
            return;
        }

        if ((now - gAB.stateSince) >= gCV.fAntiBaitRecover)
            AntiBait_SetState(AB_Observe, now, "recover done");
        return;
    }

    if (gAB.state == AB_Observe)
    {
        bool stalled = (now - gAB.lastProgressTime) >= gCV.fAntiBaitWindow;

        // 倒计时前段只观察；临近到点才允许 Anti-Bait 接管刷特决策。
        if (!WaveDecider_IsAntiBaitArmWindowOpen())
            return;

        // 新增：分散但停滞，也主动施压（不推进+无卡位也打一波）
        if (stalled && !gAB.teamHolding && gAB.attackableSpread)
        {
            AntiBait_SetState(AB_Pressure, now, "spread but stalled - apply pressure");
            gAB.spreadStallPressure = true;
            return;
        }

        // 原有：密集且停滞
        if (stalled && gAB.teamHolding)
        {
            gAB.spreadStallPressure = false;
            AntiBait_SetState(AB_Pressure, now, "team holding without progress");
        }
    }
}

bool AntiBait_ShouldPrepareBreachWave()
{
    if (!gCV.bAntiBaitEnable || gCV.iAntiBaitAction < 1)
        return false;
    return gAB.state == AB_Pressure;
}

bool AntiBait_ShouldFastTeleport(int client)
{
    if (!gCV.bAntiBaitEnable || gCV.iAntiBaitAction < 2)
        return false;
    if (gAB.state != AB_Pressure)
        return false;
    if (!DifficultyStrategy_CanStartConfiguredWave())
        return false;
    if (!CanBeTeleport(client))
        return false;

    return true;
}

int AntiBait_GetPreferredTarget()
{
    if (!gCV.bAntiBaitEnable)
        return -1;
    if (gAB.runner > 0 && AntiBait_IsPreferredTargetEligible(gAB.runner))
        return gAB.runner;
    if (gAB.state == AB_Pressure && gAB.holdingTarget > 0 && AntiBait_IsPreferredTargetEligible(gAB.holdingTarget))
        return gAB.holdingTarget;

    return -1;
}
