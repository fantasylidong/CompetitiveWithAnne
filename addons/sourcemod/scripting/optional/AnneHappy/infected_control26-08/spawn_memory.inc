#if defined _infected_control_spawn_memory_included
    #endinput
#endif
#define _infected_control_spawn_memory_included

void EnsureNavCooldownSlots()
{
    EnsureNavAreasCache();
    if (g_NavCooldownUntil != null && g_NavCooldownUntil.Length == g_NavAreasCacheCount)
        return;

    if (g_NavCooldownUntil != null)
        delete g_NavCooldownUntil;
    g_NavCooldownUntil = new ArrayList();
    for (int i = 0; i < g_NavAreasCacheCount; i++)
        g_NavCooldownUntil.Push(0.0);
}

stock bool IsNavOnCooldown(int areaIdx, float now)
{
    EnsureNavCooldownSlots();
    if (areaIdx < 0 || areaIdx >= g_NavCooldownUntil.Length)
        return false;
    return now < view_as<float>(g_NavCooldownUntil.Get(areaIdx));
}

stock void TouchNavCooldown(int areaIdx, float now, float cooldown = NAV_CD_SECS)
{
    EnsureNavCooldownSlots();
    if (areaIdx < 0 || areaIdx >= g_NavCooldownUntil.Length)
        return;
    g_NavCooldownUntil.Set(areaIdx, now + cooldown);
}

stock void CleanupLastSpawns(float now)
{
    if (lastSpawns == null) return;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);
        if (now - rec[3] > gCV.fSepTtl)
            lastSpawns.Erase(i);
    }

    int cap = GetSepMax();
    while (lastSpawns.Length > cap)
        lastSpawns.Erase(0);
}

// 硬防叠：固定半径，不再叠特感上限缩放和波内占用放宽。
// 这一条只回答"能不能刷在这"，方向和聚集程度交给核密度评分。
stock float SpawnMemory_GetEffectiveSepRadius()
{
    return (gCV.fSepRadius <= 0.0) ? 0.0 : gCV.fSepRadius;
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;
    if (gCV.fSepRadius <= 0.0) return true;

    float now = GetGameTime();
    CleanupLastSpawns(now);
    if (lastSpawns.Length == 0) return true;

    float sepRadiusEff = SpawnMemory_GetEffectiveSepRadius();
    float sep2 = sepRadiusEff * sepRadiusEff;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);

        if (now - rec[3] > gCV.fSepTtl)
        {
            lastSpawns.Erase(i);
            continue;
        }

        float rec3[3];
        rec3[0] = rec[0];
        rec3[1] = rec[1];
        rec3[2] = rec[2];

        if (GetVectorDistance(pos, rec3, true) < sep2)
            return false;
    }
    return true;
}

// —— 分散度核惩罚：对仍在接近途中的特感与最近刷点做距离衰减累加 —— //
// 已贴脸交战的存活特感不计入：他们挤在生还者身边，若当核源会把后半波往外推。
// 快照按 game tick 节流，一个 tick 内多次刷特尝试共用同一份来源列表。
#define KERNEL_SOURCE_MAX 64
#define KERNEL_SPAWN_MEMORY_WEIGHT 0.5

static float g_KernelSources[KERNEL_SOURCE_MAX][4]; // x,y,z,weight
static int g_KernelSourceCount = 0;
static float g_KernelSnapshotTime = -1.0;

void SpawnMemory_RefreshKernelSnapshot()
{
    if (gCV.fKernelRadius <= 0.0 || gCV.fKernelPoints <= 0.0)
    {
        g_KernelSourceCount = 0;
        g_KernelSnapshotTime = GetGameTime();
        return;
    }

    float now = GetGameTime();
    if (now == g_KernelSnapshotTime)
        return;
    g_KernelSnapshotTime = now;
    g_KernelSourceCount = 0;

    float pos[3];
    for (int i = 1; i <= MaxClients && g_KernelSourceCount < KERNEL_SOURCE_MAX; i++)
    {
        if (!IsInfectedBot(i) || !IsPlayerAlive(i) || IsGhost(i))
            continue;

        GetClientAbsOrigin(i, pos);
        if (GetMinDistToAnySurvivor(pos) < KERNEL_LIVE_COMBAT_EXCLUDE)
            continue;

        g_KernelSources[g_KernelSourceCount][0] = pos[0];
        g_KernelSources[g_KernelSourceCount][1] = pos[1];
        g_KernelSources[g_KernelSourceCount][2] = pos[2];
        g_KernelSources[g_KernelSourceCount][3] = 1.0;
        g_KernelSourceCount++;
    }

    if (lastSpawns == null)
        return;
    for (int i = lastSpawns.Length - 1;
         i >= 0 && g_KernelSourceCount < KERNEL_SOURCE_MAX; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);
        if (now - rec[3] > gCV.fSepTtl)
            continue;

        g_KernelSources[g_KernelSourceCount][0] = rec[0];
        g_KernelSources[g_KernelSourceCount][1] = rec[1];
        g_KernelSources[g_KernelSourceCount][2] = rec[2];
        g_KernelSources[g_KernelSourceCount][3] = KERNEL_SPAWN_MEMORY_WEIGHT;
        g_KernelSourceCount++;
    }
}

// 核半径随特感上限收缩：低特时推得开（分散），高特时只防叠（允许成团）。
// 上限缩放放在半径而不是强度上，否则高特时整条曲线一起变平、失去区分度。
stock float SpawnMemory_GetEffectiveKernelRadius()
{
    if (gCV.fKernelRadius <= 0.0)
        return 0.0;
    return gCV.fKernelRadius * ComputePenScaleByLimit(gCV.iSiLimit);
}

// 返回候选点周边的核密度和（Σ weight*exp(-d/r)），仅用于评分排序。
float SpawnMemory_GetKernelProximity(const float pos[3])
{
    if (gCV.fKernelRadius <= 0.0 || gCV.fKernelPoints <= 0.0
        || g_KernelSourceCount <= 0)
    {
        return 0.0;
    }

    float kernelRadiusEff = SpawnMemory_GetEffectiveKernelRadius();
    if (kernelRadiusEff <= 0.0)
        return 0.0;

    float sum = 0.0;
    float src[3];
    for (int i = 0; i < g_KernelSourceCount; i++)
    {
        src[0] = g_KernelSources[i][0];
        src[1] = g_KernelSources[i][1];
        src[2] = g_KernelSources[i][2];
        float d = GetVectorDistance(pos, src);
        sum += g_KernelSources[i][3] * Pow(FLOAT_EULER, -d / kernelRadiusEff);
    }
    return sum;
}

stock bool PassRealPositionCheck(float candPos[3], int targetSur)
{
    int candPercent = GetPositionBucketPercent(candPos);
    return PassRealBucketPositionCheck(candPercent, targetSur);
}

stock bool PassRealBucketPositionCheckCached(int candPercent, int surPercent)
{
    if (candPercent < 0 || surPercent < 0)
        return true;

    // 多层地图的上下楼 Nav 可能只有少量 Flow 差值。楼层高度交给有向可达、
    // path、可见性和评分处理；这里仅阻止明显落后于生还者的回头刷点。
    return candPercent >= surPercent - 6;
}

stock bool PassRealBucketPositionCheck(int candPercent, int targetSur)
{
    if (candPercent < 0)
        return true;

    int surPercent = -1;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur))
    {
        if (!TryGetClientFlowPercentSafe(targetSur, surPercent))
            surPercent = -1;
    }
    else
    {
        int fb = GetHighestFlowSurvivorSafe();
        if (!IsValidSurvivor(fb) || !TryGetClientFlowPercentSafe(fb, surPercent))
            surPercent = -1;
    }

    if (surPercent < 0)
    {
        int fpct;
        if (GetFallbackSurPct(fpct))
            surPercent = fpct;
    }

    // 所有进度获取方式均失败：无法判断身前/身后，放行以避免卡住刷特
    if (surPercent < 0)
        return true;

    return PassRealBucketPositionCheckCached(candPercent, surPercent);
}

stock bool TryGetLowestSurvivorFootZ(float &outMinZ)
{
    bool found = false;
    float bestZ = 0.0;
    float s[3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidSurvivor(i) || !IsPlayerAlive(i))
            continue;

        GetClientAbsOrigin(i, s);
        if (!found || s[2] < bestZ)
        {
            bestZ = s[2];
            found = true;
        }
    }

    if (found) outMinZ = bestZ;
    return found;
}

stock int GetNavIDByIndex(int idx)
{
    EnsureNavAreasCache();

    if (idx < 0 || idx >= g_NavAreasCacheCount)
        return -1;

    if (g_AreaNavIds != null && idx < g_AreaNavIds.Length)
        return g_AreaNavIds.Get(idx);

    Address area = g_AllNavAreasCache.Get(idx);
    return L4D_GetNavAreaID(area);
}

// 目标锚点：优先目标生还者，其次最高进度生还者，最后任意存活生还者。
// 用作目标不可用时的 targetPoint / targetFootZ 兜底。
stock void GetTargetAnchorPos(float outPos[3], int targetSur)
{
    if (IsValidSurvivor(targetSur))
    {
        GetClientAbsOrigin(targetSur, outPos);
        return;
    }

    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(fb))
    {
        GetClientAbsOrigin(fb, outPos);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, outPos);
            return;
        }
    }

    outPos[0] = outPos[1] = outPos[2] = 0.0;
}

stock void RememberSpawn(const float pos[3])
{
    float now = GetGameTime();
    CleanupLastSpawns(now);

    float rec[4];
    rec[0] = pos[0];
    rec[1] = pos[1];
    rec[2] = pos[2];
    rec[3] = now;
    lastSpawns.PushArray(rec);
}

// 注意这里的顺序是有意的，不是漏判：绝大多数 NavArea 完全没有属性位，
// 救援关卡如果要求必须带 TERROR_NAV_FINALE 才能刷，整张图（含通往终局的
// 路线）都会被拒绝。所以“无属性”一律放行，finale 限制只用来剔除那些
// 带了别的属性、但明确不属于终局区域的 Nav。改这里等于改整个救援关卡的
// 可刷范围，先确认这一点再动。
bool IsValidFlags(int iFlags, bool bFinaleArea)
{
    if (!iFlags)
        return true;

    if (bFinaleArea && (iFlags & TERROR_NAV_FINALE) == 0)
        return false;

    return (iFlags & (TERROR_NAV_RESCUE_CLOSET | TERROR_NAV_RESCUE_VEHICLE | TERROR_NAV_CHECKPOINT)) == 0;
}

stock void ShuffleArrayList(ArrayList L)
{
    int n = L.Length;
    for (int i = n - 1; i > 0; i--)
    {
        int j = GetRandomInt(0, i);
        if (j == i) continue;
        int ai = L.Get(i), aj = L.Get(j);
        L.Set(i, aj);
        L.Set(j, ai);
    }
}
