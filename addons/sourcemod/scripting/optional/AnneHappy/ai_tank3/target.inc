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

// 在 (lower, upper] 里二分：upper 已确认走得通，lower 已确认走不通（第一档时是直线距离下界），返回剩下区间的中点
float Target_RefineTravel(Address from, Address to, float lower, float upper)
{
    for (int step = 0; step < TARGET_TRAVEL_REFINE_STEPS && upper - lower > TARGET_TRAVEL_PRECISION; step++)
    {
        float mid = (lower + upper) * 0.5;
        if (L4D2_NavAreaBuildPath(from, to, mid, TEAM_INFECTED, false))
            upper = mid;
        else
            lower = mid;
    }
    return (lower + upper) * 0.5;
}

// 估算“寻路距离 / 直线距离”的绕路系数：用有长度上限的 NavAreaBuildPath 依次试直线距离的若干倍（封顶
// TARGET_TRAVEL_MAX_SEARCH），第一档走得通后再二分细化。原来直接拿命中档的上限当距离，1.15 倍档和 1.5 倍档之间
// 一跳就差 30%，只能靠很大的换目标门槛压住这个噪声。
// 不用 L4D2_NavAreaTravelDistance：目标走不到、或脚下位置没被任何 nav 包含时，它的 A* 没有长度上限，会把整张 nav 翻一遍
float Target_EstimateRatio(int tank, int survivor, float straight)
{
    Address tankArea = view_as<Address>(L4D_GetLastKnownArea(tank));
    Address survivorArea = view_as<Address>(L4D_GetLastKnownArea(survivor));
    if (tankArea == Address_Null || survivorArea == Address_Null)
        return TARGET_TRAVEL_UNKNOWN;
    if (tankArea == survivorArea || straight < 1.0)
        return 1.0;

    // 路径长度不会明显短于直线距离，第一档的下界取直线距离
    float lower = straight;
    int buckets = sizeof(g_fTravelBucketRatios);
    for (int i = 0; i <= buckets; i++)
    {
        float limit = i < buckets ? straight * g_fTravelBucketRatios[i] : TARGET_TRAVEL_MAX_SEARCH;
        if (limit > TARGET_TRAVEL_MAX_SEARCH)
            limit = TARGET_TRAVEL_MAX_SEARCH;
        if (limit <= lower)
            continue;

        if (L4D2_NavAreaBuildPath(tankArea, survivorArea, limit, TEAM_INFECTED, false))
            return Target_RefineTravel(tankArea, survivorArea, lower, limit) / straight;
        lower = limit;
    }
    return TARGET_TRAVEL_UNREACHABLE;
}

// 每 tick 由 OnPlayerRunCmd 调用，给这只 Tank 最久没更新的一个生还者重算绕路系数，全插件每 tick 最多算一个人。
// 原来只在游戏调用 ChooseVictim 时顺带刷新、每次只刷一个人，四个人轮一圈要调用四次：走近的人顶着旧的、更远的估距，
// 看上去比实际远，换目标就更难。现在刷新频率和 ChooseVictim 脱钩。
// 人在空中/梯子上时最后所在的 nav 不代表现在的位置，跳过，保留上一次结果
void Target_RefreshTravel(int tank, const float tankPos[3])
{
    float now = GetEngineTime();
    int stalest = 0;
    float stalestAge = 0.0;
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        if (!IsValidSurvivor(survivor) || !IsPlayerAlive(survivor) || IsClientHanging(survivor))
            continue;
        if (!IsClientOnGround(survivor) || GetEntityMoveType(survivor) == MOVETYPE_LADDER)
            continue;

        float age = 1.0e9;
        if (g_Tank[tank].travelUser[survivor] == GetClientUserId(survivor))
        {
            age = now - g_Tank[tank].travelTime[survivor];
            float interval = g_Tank[tank].travelRatio[survivor] < 0.0 ? TARGET_TRAVEL_UNREACHABLE_RETRY : TARGET_TRAVEL_CACHE_TIME;
            if (age < interval)
                continue;
        }
        if (stalest == 0 || age > stalestAge)
        {
            stalest = survivor;
            stalestAge = age;
        }
    }
    if (stalest == 0 || !Target_AcquireTravelBudget())
        return;

    float survivorPos[3];
    GetClientAbsOrigin(stalest, survivorPos);
    g_Tank[tank].travelRatio[stalest] = Target_EstimateRatio(tank, stalest, GetVectorDistance(tankPos, survivorPos));
    g_Tank[tank].travelUser[stalest] = GetClientUserId(stalest);
    g_Tank[tank].travelTime[stalest] = now;
}

// 得分 = 当前直线距离 × 绕路系数。绕路系数反映路线弯不弯，隔 0.5 秒重算；两次重算之间得分跟着直线距离实时变化，
// 不会拿旧距离去比。还没有估距结果时按直线距离，走不到的人加罚分
float Target_GetScore(int tank, int survivor, const float tankPos[3])
{
    float survivorPos[3];
    GetClientAbsOrigin(survivor, survivorPos);
    float straight = GetVectorDistance(tankPos, survivorPos);

    float score = straight;
    if (g_Tank[tank].travelUser[survivor] == GetClientUserId(survivor))
    {
        float ratio = g_Tank[tank].travelRatio[survivor];
        if (ratio == TARGET_TRAVEL_UNREACHABLE)
            score = straight + TARGET_UNREACHABLE_PENALTY;
        else if (ratio > 1.0)
            score = straight * ratio;
    }
    // 估距相近时直线近的优先
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
    for (int survivor = 1; survivor <= MaxClients; survivor++)
    {
        int tier = Target_Classify(tank, survivor, pinnedMask, incapMode, skipSaferoom);
        if (tier == TARGET_TIER_NONE)
            continue;

        float score = Target_GetScore(tank, survivor, tankPos);
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
        // 新目标得分不到当前目标的一定比例（默认一半）：明显更好打，不等换目标间隔
        bool decisive = bestScore <= currentScore * g_cvTargetDecisiveRatio.FloatValue;
        if (!decisive && now - g_Tank[tank].victimSince < g_cvTargetCommitTime.FloatValue)
            return current;
        if (bestScore > currentScore * g_cvTargetSwitchRatio.FloatValue || currentScore - bestScore < g_cvTargetSwitchGain.FloatValue)
            return current;
    }

    if (best != current)
    {
        g_Tank[tank].victimSince = now;
        if (log != null)
            log.debugAll("%N victim -> %N (score %.0f, previous %.0f, tier %d)", tank, best, bestScore, currentScore, bestTier);
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
