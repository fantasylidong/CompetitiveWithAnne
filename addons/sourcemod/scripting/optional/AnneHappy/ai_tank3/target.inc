#if defined _ai_tank3_target_included
    #endinput
#endif
#define _ai_tank3_target_included

// =========================================================================
// 目标选择
// l4d_target_override 的前置 detour 会替游戏给 Tank 选目标：候选是 PVS 里的生还者，按到 Tank 眼睛的直线距离排序，
// Tank 条目 wait 为 0、dist 为 150，150 单位外每次调用都重新比一次。高台/梯子附近直线最近的人往往要绕梯子才走得到，
// 站位稍一变目标就在两个人之间来回跳，ChasePath 每换一次就重算路线，Tank 就在梯子口原地转圈。
// left4dhooks 的 L4D2_OnChooseVictim 是 post detour，在 target_override 之后执行，这里拿最终决定权：
// 过滤口径沿用 target_override 的 pinned / incap / safe，排序改成寻路距离，并加换目标粘滞与爬梯冻结。
// =========================================================================

public Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)
{
    if (!g_cvEnable.BoolValue || !isAiTank(specialInfected))
        return Plugin_Continue;

    int tank = specialInfected;
    State_EnsureOwner(tank);

    int chosen = g_cvTargetSelect.BoolValue ? Target_Choose(tank) : Target_ChooseInsteadOfIgnored(tank, curTarget);
    if (chosen <= 0)
    {
        if (IsValidSurvivor(curTarget) && IsPlayerAlive(curTarget))
            g_Tank[tank].victim = GetClientUserId(curTarget);
        return Plugin_Continue;
    }

    g_Tank[tank].victim = GetClientUserId(chosen);
    if (chosen == curTarget)
        return Plugin_Continue;

    curTarget = chosen;
    SITL_CommitVictim(tank, chosen);
    return Plugin_Changed;
}

int Target_GetCurrent(int tank)
{
    int victim = GetClientOfUserId(g_Tank[tank].victim);
    if (!IsValidSurvivor(victim) || !IsPlayerAlive(victim))
        return 0;
    return victim;
}

bool Target_IsIgnored(int tank, int survivor)
{
    if (!g_cvHeadBlockEnable.BoolValue || survivor < 1 || survivor > MaxClients || !IsClientInGame(survivor))
        return false;
    return g_Tank[tank].ignoreUser[survivor] == GetClientUserId(survivor) && g_Tank[tank].ignoreUntil[survivor] > GetEngineTime();
}

void Target_Ignore(int tank, int survivor, float until)
{
    g_Tank[tank].ignoreUser[survivor] = GetClientUserId(survivor);
    g_Tank[tank].ignoreUntil[survivor] = until;
}

void Target_FreezeVictim(int tank, float now)
{
    g_Tank[tank].victimFreezeUntil = now + LADDER_VICTIM_FREEZE;
}

void Target_ReadOverrideOptions(int &pinnedMask, int &incapMode, bool &skipSaferoom)
{
    pinnedMask = TARGET_PINNED_MASK_DEFAULT;
    incapMode = TARGET_INCAP_MODE_DEFAULT;
    skipSaferoom = true;
    if (GetFeatureStatus(FeatureType_Native, "L4D_TargetOverride_GetOption") != FeatureStatus_Available)
        return;

    pinnedMask = view_as<int>(L4D_TargetOverride_GetOption(SI_TANK, INDEX_PINNED));
    incapMode = view_as<int>(L4D_TargetOverride_GetOption(SI_TANK, INDEX_INCAP));
    skipSaferoom = view_as<int>(L4D_TargetOverride_GetOption(SI_TANK, INDEX_SAFE)) != 0;
}

// pinned 位：1=舌头 2=猎人 4=猴子 8=牛，与 target_override 一致
bool Target_IsPinnedByMask(int survivor, int mask)
{
    if ((mask & 1) && GetEntPropEnt(survivor, Prop_Send, "m_tongueOwner") > 0)
        return true;
    if ((mask & 2) && GetEntPropEnt(survivor, Prop_Send, "m_pounceAttacker") > 0)
        return true;
    if ((mask & 4) && GetEntPropEnt(survivor, Prop_Send, "m_jockeyAttacker") > 0)
        return true;
    if ((mask & 8) && (GetEntPropEnt(survivor, Prop_Send, "m_carryAttacker") > 0 || GetEntPropEnt(survivor, Prop_Send, "m_pummelAttacker") > 0))
        return true;
    return false;
}

bool Target_IsVomited(int survivor)
{
    static ConVar fadeDuration;
    if (fadeDuration == null)
        fadeDuration = FindConVar("z_vomit_fade_duration");

    if (GetEntProp(survivor, Prop_Send, "m_glowColorOverride") == -4713783)
        return true;
    float fadeStart = GetEntPropFloat(survivor, Prop_Send, "m_vomitFadeStart");
    return fadeStart != 0.0 && fadeDuration != null && fadeStart + fadeDuration.FloatValue > GetGameTime();
}

int Target_Classify(int tank, int survivor, int pinnedMask, int incapMode, bool skipSaferoom)
{
    if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || IsClientHanging(survivor) || Target_IsIgnored(tank, survivor))
        return TARGET_TIER_NONE;
    if (skipSaferoom && (L4D_IsInLastCheckpoint(survivor) || L4D_IsInFirstCheckpoint(survivor)))
        return TARGET_TIER_NONE;
    if (pinnedMask != 0 && Target_IsPinnedByMask(survivor, pinnedMask))
        return TARGET_TIER_NONE;
    if (!IsClientIncapped(survivor))
        return TARGET_TIER_REGULAR;
    if (incapMode == 1 || (incapMode == 2 && Target_IsVomited(survivor)))
        return TARGET_TIER_REGULAR;
    // incap 0/3：倒地的人只在没有站着的候选时兜底，避免 Tank 没有目标原地发呆
    return TARGET_TIER_FALLBACK;
}

bool Target_AcquireTravelBudget()
{
    int tick = GetGameTickCount();
    if (g_iTravelBudgetTick == tick)
        return false;
    g_iTravelBudgetTick = tick;
    return true;
}

// 用有长度上限的 NavAreaBuildPath 分档估算寻路距离：依次试直线距离的若干倍（封顶 TARGET_TRAVEL_MAX_SEARCH），
// 第一档走得通就按该档长度计分。不用 L4D2_NavAreaTravelDistance：目标走不到、或脚下位置没被任何 nav 包含时，
// 它的 A* 没有长度上限，会把整张 nav 翻一遍
float Target_EstimateTravel(int tank, int survivor, float straight)
{
    Address tankArea = view_as<Address>(L4D_GetLastKnownArea(tank));
    Address survivorArea = view_as<Address>(L4D_GetLastKnownArea(survivor));
    if (tankArea == Address_Null || survivorArea == Address_Null)
        return TARGET_TRAVEL_UNKNOWN;
    if (tankArea == survivorArea)
        return straight;

    float tested = 0.0;
    for (int i = 0; i < sizeof(g_fTravelBucketRatios); i++)
    {
        float limit = straight * g_fTravelBucketRatios[i];
        if (limit > TARGET_TRAVEL_MAX_SEARCH)
            limit = TARGET_TRAVEL_MAX_SEARCH;
        if (limit <= tested)
            continue;

        tested = limit;
        if (L4D2_NavAreaBuildPath(tankArea, survivorArea, limit, TEAM_INFECTED, false))
            return limit;
    }
    if (tested < TARGET_TRAVEL_MAX_SEARCH && L4D2_NavAreaBuildPath(tankArea, survivorArea, TARGET_TRAVEL_MAX_SEARCH, TEAM_INFECTED, false))
        return TARGET_TRAVEL_MAX_SEARCH;
    return TARGET_TRAVEL_UNREACHABLE;
}

// 寻路距离评分：每个生还者每秒最多刷新一次，全插件每 tick 最多刷新一个人，没有结果时用直线距离
float Target_GetScore(int tank, int survivor, const float tankPos[3], bool &refreshed)
{
    float survivorPos[3];
    GetClientAbsOrigin(survivor, survivorPos);
    float straight = GetVectorDistance(tankPos, survivorPos);

    int userId = GetClientUserId(survivor);
    float now = GetEngineTime();
    bool cached = g_Tank[tank].travelUser[survivor] == userId;
    // 人在空中/梯子上时最后所在的 nav 不代表现在的位置，保留上一次结果
    bool grounded = IsClientOnGround(survivor) && GetEntityMoveType(survivor) != MOVETYPE_LADDER;
    if (grounded && !refreshed && (!cached || now - g_Tank[tank].travelTime[survivor] >= TARGET_TRAVEL_CACHE_TIME) && Target_AcquireTravelBudget())
    {
        refreshed = true;
        g_Tank[tank].travelDist[survivor] = Target_EstimateTravel(tank, survivor, straight);
        g_Tank[tank].travelUser[survivor] = userId;
        g_Tank[tank].travelTime[survivor] = now;
        cached = true;
    }

    float score = straight;
    if (cached)
    {
        float travel = g_Tank[tank].travelDist[survivor];
        if (travel == TARGET_TRAVEL_UNREACHABLE)
            score = straight + TARGET_UNREACHABLE_PENALTY;
        else if (travel > straight)
            score = travel;
    }
    // 分档估距经常打平，按直线距离微调，同一档里近的优先
    score += straight * 0.01;
    if (Target_IsVomited(survivor))
        score *= TARGET_VOMIT_SCORE_MULT;
    return score;
}

int Target_Choose(int tank)
{
    int pinnedMask, incapMode;
    bool skipSaferoom;
    Target_ReadOverrideOptions(pinnedMask, incapMode, skipSaferoom);

    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);
    float now = GetEngineTime();

    int current = Target_GetCurrent(tank);
    int currentTier = TARGET_TIER_NONE;
    float currentScore = 0.0;
    int best = -1;
    int bestTier = TARGET_TIER_NONE;
    float bestScore = 0.0;
    bool refreshed = false;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        int tier = Target_Classify(tank, survivor, pinnedMask, incapMode, skipSaferoom);
        if (tier == TARGET_TIER_NONE)
            continue;

        float score = Target_GetScore(tank, survivor, tankPos, refreshed);
        if (survivor == current)
        {
            currentTier = tier;
            currentScore = score;
        }
        if (best == -1 || tier < bestTier || (tier == bestTier && score < bestScore))
        {
            best = survivor;
            bestTier = tier;
            bestScore = score;
        }
    }

    if (best == -1)
        return -1;

    // 当前目标仍然有效且与最优候选同一层时才考虑粘滞；当前目标失效或降为倒地兜底层时立即换
    if (currentTier != TARGET_TIER_NONE && currentTier == bestTier)
    {
        if (current == best || now < g_Tank[tank].victimFreezeUntil)
            return current;
        if (now - g_Tank[tank].victimSince < g_cvTargetCommitTime.FloatValue)
            return current;
        if (bestScore > currentScore * g_cvTargetSwitchRatio.FloatValue || currentScore - bestScore < TARGET_MIN_SWITCH_GAIN)
            return current;
    }

    if (best != current)
    {
        g_Tank[tank].victimSince = now;
        if (log != null)
            log.debugAll("%N victim -> %N (score %.0f, tier %d)", tank, best, bestScore, bestTier);
    }
    return best;
}

// ai_tank3_target_select 0：排序交给 target_override/原生，只保证被反头顶卡屏蔽的人会被换掉
int Target_ChooseInsteadOfIgnored(int tank, int gameChoice)
{
    if (!IsValidSurvivor(gameChoice) || !IsPlayerAlive(gameChoice) || !Target_IsIgnored(tank, gameChoice))
        return -1;

    int pinnedMask, incapMode;
    bool skipSaferoom;
    Target_ReadOverrideOptions(pinnedMask, incapMode, skipSaferoom);

    float tankPos[3];
    GetClientAbsOrigin(tank, tankPos);
    int best = -1;
    int bestTier = TARGET_TIER_NONE;
    float bestDist = 0.0;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        int tier = Target_Classify(tank, survivor, pinnedMask, incapMode, skipSaferoom);
        if (tier == TARGET_TIER_NONE)
            continue;

        float survivorPos[3];
        GetClientAbsOrigin(survivor, survivorPos);
        float dist = GetVectorDistance(tankPos, survivorPos);
        if (best == -1 || tier < bestTier || (tier == bestTier && dist < bestDist))
        {
            best = survivor;
            bestTier = tier;
            bestDist = dist;
        }
    }
    return best;
}

bool Target_HasAlternative(int tank, int blocked)
{
    int pinnedMask, incapMode;
    bool skipSaferoom;
    Target_ReadOverrideOptions(pinnedMask, incapMode, skipSaferoom);
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (survivor != blocked && Target_Classify(tank, survivor, pinnedMask, incapMode, skipSaferoom) != TARGET_TIER_NONE)
            return true;
    }
    return false;
}

bool Target_IsVisible(int tank, int target, const float targetPos[3])
{
    float now = GetEngineTime();
    int userId = GetClientUserId(target);
    if (g_Tank[tank].visUser == userId && now - g_Tank[tank].visTime < VISIBILITY_CACHE_TIME)
        return g_Tank[tank].visResult;

    float point[3];
    point = targetPos;
    bool visible = L4D2_IsVisibleToPlayer(tank, TEAM_INFECTED, 0, 0, point);
    g_Tank[tank].visUser = userId;
    g_Tank[tank].visTime = now;
    g_Tank[tank].visResult = visible;
    return visible;
}
