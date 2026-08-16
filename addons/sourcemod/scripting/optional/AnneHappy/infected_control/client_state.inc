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
