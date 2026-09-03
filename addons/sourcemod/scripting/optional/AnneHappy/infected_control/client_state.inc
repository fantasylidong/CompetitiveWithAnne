#if defined _infected_control_client_state_included
    #endinput
#endif
#define _infected_control_client_state_included

bool IsInfectedBot(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && IsFakeClient(client)
           && GetClientTeam(client) == TEAM_INFECTED && (GetEntProp(client, Prop_Send, "m_zombieClass") >= 1 && GetEntProp(client, Prop_Send, "m_zombieClass") <= 6);
}

void TeleportState_ClearClient(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    g_LastSpawnTime[client] = 0.0;
    gST.teleInvisibleSeconds[client] = 0.0;
    gST.teleLastSampleTime[client] = 0.0;
    gST.spitterSpitTime[client] = 0.0;
    SpawnTarget_ReleaseReservation(client);
}

void TeleportState_StampSpawn(int client, const char[] source)
{
    if (client <= 0 || client > MaxClients)
        return;

    float now = GetGameTime();
    g_LastSpawnTime[client] = now;
    gST.teleInvisibleSeconds[client] = 0.0;
    gST.teleLastSampleTime[client] = 0.0;
    if (IsClientInGame(client) && IsInfectedBot(client)
        && GetInfectedClass(client) == view_as<int>(SI_Spitter))
    {
        gST.spitterSpitTime[client] = now;
    }
    Debug_Print(
        "[TP GRACE] event=stamp source=%s client=%d userid=%d gameTime=%.3f grace=%.2f",
        source, client, IsClientInGame(client) ? GetClientUserId(client) : 0,
        now, gCV.fTeleportSpawnGrace);
}

bool TeleportState_IsInSpawnGrace(int client, float now)
{
    if (gCV.fTeleportSpawnGrace <= 0.0)
        return false;
    if (client <= 0 || client > MaxClients)
        return true;

    // born<=0 表示出生时间未知（如硬恢复清空后未重新盖章）。未知视为
    // “早已出生”，否则这些特感会永久停留在宽限期内、无法被传送监督处理。
    float born = g_LastSpawnTime[client];
    if (born <= 0.0)
        return false;
    return (now - born) < gCV.fTeleportSpawnGrace;
}

stock bool IsSmokerReadyToAttack(int client)
{
    if (!IsAiSmoker(client))
        return false;

    static int ability;
    ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (!IsValidEdict(ability))
        return false;

    static char clsName[32];
    GetEntityClassname(ability, clsName, sizeof(clsName));
    if (strcmp(clsName, "ability_tongue", false) != 0)
        return false;

    static float timestamp;
    timestamp = GetEntPropFloat(ability, Prop_Send, "m_timestamp");
    return GetGameTime() >= timestamp;
}

bool IsValidClient(int c)
{
    return c > 0 && c <= MaxClients && IsClientInGame(c);
}

bool IsValidSurvivor(int c)
{
    return IsValidClient(c) && GetClientTeam(c) == TEAM_SURVIVOR;
}

bool IsSpitter(int client)
{
    return IsInfectedBot(client) && IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_zombieClass") == view_as<int>(SI_Spitter);
}

int GetInfectedClass(int client)
{
    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

bool IsGhost(int client)
{
    return IsValidClient(client) && view_as<bool>(GetEntProp(client, Prop_Send, "m_isGhost"));
}

bool IsAiSmoker(int c)
{
    return c && c <= MaxClients && IsClientInGame(c) && IsPlayerAlive(c) && IsFakeClient(c)
        && GetClientTeam(c) == TEAM_INFECTED && GetEntProp(c, Prop_Send, "m_zombieClass") == view_as<int>(SI_Smoker) && !IsGhost(c);
}

bool IsActiveTank(int c)
{
    return c > 0 && c <= MaxClients && IsClientInGame(c) && IsPlayerAlive(c)
        && GetClientTeam(c) == TEAM_INFECTED
        && GetEntProp(c, Prop_Send, "m_zombieClass") == ZC_TANK
        && !IsGhost(c);
}

bool IsSurvivorHangingFromLedge(int client)
{
    return IsValidSurvivor(client) && IsPlayerAlive(client)
        && (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") != 0
            || GetEntProp(client, Prop_Send, "m_isFallingFromLedge") != 0);
}

bool IsPinned(int client)
{
    if (!(IsValidSurvivor(client) && IsPlayerAlive(client))) return false;
    return GetEntPropEnt(client, Prop_Send, "m_tongueOwner")    > 0
        || GetEntPropEnt(client, Prop_Send, "m_carryAttacker")  > 0
        || GetEntPropEnt(client, Prop_Send, "m_jockeyAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_pounceAttacker") > 0
        || GetEntPropEnt(client, Prop_Send, "m_pummelAttacker") > 0;
}

bool IsEligibleSpawnTarget(int client)
{
    return IsValidSurvivor(client)
        && IsPlayerAlive(client)
        && !IsPinned(client)
        && !L4D_IsPlayerIncapacitated(client);
}

// 容量判断在候选热路径上逐行调用。native 可用性与逐人结果按 tick 缓存，
// 避免每个候选都做字符串查找和跨插件调用；刷出成功时显式失效。
// 队首 ×2 / 跑男放开的有效上限由 SI_Target_limit 的 GetClientTargetLimit 直接返回。
#define SPAWN_TARGET_HEADROOM_UNLIMITED   -1
#define SPAWN_TARGET_HEADROOM_UNCOMPUTED  -2
// 刚刷出的特感要等 ChooseVictim 跑过才进 l4d_target_override 的账本；同一帧
// burst 内后续刷出的特感看到的容量与第一只完全一样。这里按“导向目标”记一笔
// 短期预留：账本里出现该特感、或超时、或该特感消失后自动释放。
#define SPAWN_TARGET_RESERVE_TTL           2.5

static float g_TargetCapCacheTime = -1.0;
static bool g_TargetCapNativeOk = false;
static bool g_TargetLedgerNativeOk = false;
static int g_TargetCapState[MAXPLAYERS + 1];
static int g_iPendingReserveTarget[MAXPLAYERS + 1];   // 按特感 client 索引：导向的生还者
static float g_fPendingReserveUntil[MAXPLAYERS + 1];

void SpawnTarget_InvalidateCapacityCache()
{
    g_TargetCapCacheTime = -1.0;
}

void SpawnTarget_ReserveFor(int siClient, int target)
{
    if (siClient <= 0 || siClient > MaxClients)
        return;
    if (target <= 0 || target > MaxClients)
    {
        SpawnTarget_ReleaseReservation(siClient);
        return;
    }

    g_iPendingReserveTarget[siClient] = target;
    g_fPendingReserveUntil[siClient] = GetGameTime() + SPAWN_TARGET_RESERVE_TTL;
}

void SpawnTarget_ReleaseReservation(int siClient)
{
    if (siClient <= 0 || siClient > MaxClients)
        return;

    g_iPendingReserveTarget[siClient] = 0;
    g_fPendingReserveUntil[siClient] = 0.0;
}

void SpawnTarget_ClearPendingReservations()
{
    for (int i = 0; i <= MAXPLAYERS; i++)
    {
        g_iPendingReserveTarget[i] = 0;
        g_fPendingReserveUntil[i] = 0.0;
    }
    SpawnTarget_InvalidateCapacityCache();
}

static void SpawnTarget_EnsureCapacityCache()
{
    float now = GetGameTime();
    if (g_TargetCapCacheTime == now)
        return;
    g_TargetCapCacheTime = now;
    g_TargetCapNativeOk = GetFeatureStatus(FeatureType_Native, "GetClientTargetLimit")
        == FeatureStatus_Available;
    g_TargetLedgerNativeOk = GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_GetValue")
        == FeatureStatus_Available;
    for (int i = 0; i <= MaxClients; i++)
        g_TargetCapState[i] = SPAWN_TARGET_HEADROOM_UNCOMPUTED;
}

// 账本已经登记（无论登记到谁）就不再算预留，避免和 GetClientTargetNum 重复计数。
static bool SpawnTarget_IsReservationSettled(int siClient)
{
    if (!g_TargetLedgerNativeOk)
        return false;
    return L4D_TargetOverride_GetValue(siClient, VALUE_INDEX_VICTIM) > 0;
}

static int SpawnTarget_CountPending(int target, float now)
{
    int pending = 0;
    for (int si = 1; si <= MaxClients; si++)
    {
        if (g_iPendingReserveTarget[si] != target)
            continue;

        if (now >= g_fPendingReserveUntil[si]
            || !IsClientInGame(si) || !IsPlayerAlive(si)
            || SpawnTarget_IsReservationSettled(si))
        {
            g_iPendingReserveTarget[si] = 0;
            g_fPendingReserveUntil[si] = 0.0;
            continue;
        }
        pending++;
    }
    return pending;
}

// 剩余可锁定名额：SPAWN_TARGET_HEADROOM_UNLIMITED = 无上限/不可用；0 = 已满；
// >0 = 还能再导向几只控制类特感（含待锁定预留）。
int SpawnTarget_GetHeadroom(int client)
{
    if (!g_bTargetLimitLib || !IsValidSurvivor(client))
        return SPAWN_TARGET_HEADROOM_UNLIMITED;

    SpawnTarget_EnsureCapacityCache();
    if (g_TargetCapState[client] == SPAWN_TARGET_HEADROOM_UNCOMPUTED)
    {
        int headroom = SPAWN_TARGET_HEADROOM_UNLIMITED;
        if (g_TargetCapNativeOk)
        {
            int limit = GetClientTargetLimit(client);
            if (limit > 0)
            {
                int used = GetClientTargetNum(client)
                    + SpawnTarget_CountPending(client, g_TargetCapCacheTime);
                headroom = limit - used;
                if (headroom < 0)
                    headroom = 0;
            }
        }
        else if (IsClientReachLimit(client) != 0)
        {
            headroom = 0;
        }
        g_TargetCapState[client] = headroom;
    }
    return g_TargetCapState[client];
}

stock bool SpawnTarget_IsAtCapacity(int client)
{
    return SpawnTarget_GetHeadroom(client) == 0;
}

bool IsPinningSomeone(int client)
{
    if (!IsInfectedBot(client)) return false;
    return GetEntPropEnt(client, Prop_Send, "m_tongueVictim")  > 0
        || GetEntPropEnt(client, Prop_Send, "m_jockeyVictim")  > 0
        || GetEntPropEnt(client, Prop_Send, "m_pounceVictim")  > 0
        || GetEntPropEnt(client, Prop_Send, "m_pummelVictim")  > 0
        || GetEntPropEnt(client, Prop_Send, "m_carryVictim")   > 0;
}

float GetClosestSurvivorDistance(int client)
{
    float p[3];
    GetClientAbsOrigin(client, p);

    float best = 999999.0;
    float s[3];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d < best) best = d;
    }
    return best;
}

bool CanBeTeleport(int client)
{
    if (!IsInfectedBot(client) || !IsClientInGame(client) || !IsPlayerAlive(client))
        return false;
    if (IsGhost(client) || IsClientInKickQueue(client))
        return false;
    if (GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK)
        return false;
    if (IsPinningSomeone(client))
        return false;

    if (TeleportState_IsInSpawnGrace(client, GetGameTime()))
        return false;

    if (IsSpitter(client) && (GetGameTime() - gST.spitterSpitTime[client]) < SPIT_INTERVAL)
        return false;

    if (GetClosestSurvivorDistance(client) < gCV.fSpawnMin)
        return false;

    // Smoker 技能是否就绪由 Timer_TeleportTick 处理：未就绪只累计隐身
    // 计时、不踢出。在这里直接拒绝会让监督内的该分支永远走不到，导致
    // Smoker 必须“技能就绪后再重新攒满隐身秒数”才能传送。

    float p[3];
    GetClientAbsOrigin(client, p);
    if (IsPosAheadOfHighest(p))
        return false;

    return true;
}

bool Survivors_AllPinnedOrDown()
{
    int ns = 0;
    int pinned = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsValidSurvivor(c) && IsPlayerAlive(c))
        {
            ns++;
            if (IsPinned(c) || L4D_IsPlayerIncapacitated(c))
                pinned++;
        }
    }

    return (ns > 0 && pinned == ns);
}

bool IsAnyTankOrAboveHalfSurvivorDownOrDied(int limit = 0)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsActiveTank(i))
            return true;
    }

    return AreAtLeastHalfSurvivorsDownOrDead(limit);
}

bool IsTankPressureActive()
{
    float pressureDist = gCV.fAntiBaitTankPressureDist;
    float pressureDistSq = pressureDist * pressureDist;
    float tankPos[3], survivorPos[3];

    for (int tank = 1; tank <= MaxClients; tank++)
    {
        if (!IsActiveTank(tank))
            continue;

        if (pressureDist <= 0.0)
            return true;

        GetClientAbsOrigin(tank, tankPos);
        for (int survivor = 1; survivor <= MaxClients; survivor++)
        {
            if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor))
                continue;

            GetClientAbsOrigin(survivor, survivorPos);
            if (GetVectorDistance(tankPos, survivorPos, true) <= pressureDistSq)
                return true;
        }
    }

    return false;
}

bool AreAtLeastHalfSurvivorsDownOrDead(int limit = 0)
{
    int down = 0;
    int survMax = (gCV.SurvivorLimit != null) ? gCV.SurvivorLimit.IntValue : 4;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i)
            && (L4D_IsPlayerIncapacitated(i) || IsSurvivorHangingFromLedge(i)
                || !IsPlayerAlive(i)))
        {
            down++;
        }
    }

    if (limit == 0)
        return down >= RoundToCeil(float(survMax) / 2.0);
    return down >= limit;
}

void EmitRushmanForward(int survivor)
{
    if (g_hRushManNotifyForward != INVALID_HANDLE)
    {
        Call_StartForward(g_hRushManNotifyForward);
        Call_PushCell(survivor);
        Call_Finish();
    }
}
