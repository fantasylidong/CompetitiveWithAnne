#if defined _infected_control_path_cache_included
    #endinput
#endif
#define _infected_control_path_cache_included

#define PATH_NO_BUILD_PENALTY     1999.0

static StringMap g_PathCacheRes = null;  // key -> int(0/1)

void PathCache_Init()
{
    if (g_PathCacheRes == null)
        g_PathCacheRes = new StringMap();
}

// 生成缓存 Key（NavAreaID + 量化后的 limitCost）
static void PathCache_BuildKey(Address navGoal, Address navStart, float limitCost, char[] outKey, int maxlen)
{
    int idG = (navGoal  != Address_Null) ? L4D_GetNavAreaID(navGoal)  : -1;
    int idS = (navStart != Address_Null) ? L4D_GetNavAreaID(navStart) : -1;
    int q   = RoundToNearest(limitCost / gCV.fPathCacheQuantize); // 量化，避免 key 激增
    Format(outKey, maxlen, "%d|%d|%d", idG, idS, q);
}

// 简单读写（无 TTL）
static bool PathCache_TryGetSimple(const char[] key, bool &okOut)
{
    if (g_PathCacheRes == null) return false;
    any resAny;
    if (!g_PathCacheRes.GetValue(key, resAny)) return false;
    okOut = (view_as<int>(resAny) != 0);
    return true;
}

static void PathCache_PutSimple(const char[] key, bool ok)
{
    if (g_PathCacheRes == null) return;
    g_PathCacheRes.SetValue(key, view_as<any>(ok ? 1 : 0));
}

// 仅清结果表。
void ClearPathCache()
{
    if (g_bSpawnAccel)
        AnneSpawn_ClearPathCache();
    if (g_PathCacheRes != null) g_PathCacheRes.Clear();
}

// 使用搜索会话缓存的生还者 Nav 起点，避免每个候选重复查询同一个 NavArea。
stock float PathPenalty_NoBuildFromStart(const float candPos[3], Address navStart, float ring, float spawnmax)
{
    if (navStart == Address_Null)
        return PATH_NO_BUILD_PENALTY;

    // 随机点可能位于区域边缘、重叠层或断层，目标 Nav 仍按最终坐标精确查询。
    Address navGoal = L4D_GetNearestNavArea(candPos, 120.0, false, false, false, TEAM_INFECTED);
    if (navGoal == Address_Null)
        return PATH_NO_BUILD_PENALTY;

    float limitCost = FloatMin(ring * 3.0, spawnmax * 1.5);

    if (g_bSpawnAccel)
    {
        // Nav 图查询始终需要稳定 ID；量化长度仍只用于可选的 BuildPath 兜底缓存。
        int idGoal = L4D_GetNavAreaID(navGoal);
        int idStart = L4D_GetNavAreaID(navStart);
        int quantizedLength = 0;
        if (gCV.bPathCacheEnable)
        {
            quantizedLength = RoundToNearest(limitCost / gCV.fPathCacheQuantize);
        }

        bool ok = AnneSpawn_PathExists(navGoal, idGoal, navStart, idStart,
                                       limitCost, quantizedLength,
                                       TEAM_INFECTED, false,
                                       gCV.bPathCacheEnable);
        return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
    }

    if (gCV.bPathCacheEnable)
    {
        char key[64];
        PathCache_BuildKey(navGoal, navStart, limitCost, key, sizeof key);

        bool okCached;
        if (PathCache_TryGetSimple(key, okCached))
            return okCached ? 0.0 : PATH_NO_BUILD_PENALTY;

        bool ok = L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false);
        PathCache_PutSimple(key, ok);
        return ok ? 0.0 : PATH_NO_BUILD_PENALTY;
    }

    return L4D2_NavAreaBuildPath(navGoal, navStart, limitCost, TEAM_INFECTED, false)
        ? 0.0
        : PATH_NO_BUILD_PENALTY;
}

// 兼容调试和非会话调用：先解析一次目标生还者，再走同一套路径判定。
stock float PathPenalty_NoBuild(const float candPos[3], int targetSur, float ring, float spawnmax)
{
    // 选目标幸存者：优先 targetSur，其次任意存活
    int surv = -1;
    if (IsValidSurvivor(targetSur) && IsPlayerAlive(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        surv = targetSur;
    }
    else
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsValidSurvivor(i) && IsPlayerAlive(i) && !L4D_IsPlayerIncapacitated(i))
            { surv = i; break; }
        }
    }
    if (surv == -1) return PATH_NO_BUILD_PENALTY; // 没有可用幸存者，按“不可达”

    // 生还者位置（与你 SpawnInfected 的口径一致）
    float survPos[3];
    GetClientEyePosition(surv, survPos);
    survPos[2] -= 60.0;

    // 必须用最终随机坐标重新找最近 NavArea。
    // 只信任扫描中的 areaAddr 会放过边缘/重叠/断层上的坏落点。
    Address navStart = L4D_GetNearestNavArea(survPos, 120.0, false, false, false, TEAM_INFECTED);
    return PathPenalty_NoBuildFromStart(candPos, navStart, ring, spawnmax);
}
