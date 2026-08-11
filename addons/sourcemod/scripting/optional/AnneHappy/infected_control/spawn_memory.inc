#if defined _infected_control_spawn_memory_included
    #endinput
#endif
#define _infected_control_spawn_memory_included

enum PendingSpawnReservationField
{
    PendingReservation_Token = 0,
    PendingReservation_NavId,
    PendingReservation_AreaIdx,
    PendingReservation_PosX,
    PendingReservation_PosY,
    PendingReservation_PosZ,
    PendingReservation_ExpiresAt,
    PendingReservation_FieldCount
}

static ArrayList g_PendingSpawnReservations = null;
static int g_iNextPendingSpawnReservationToken = 1;

static void CleanupPendingSpawnReservations(float now)
{
    if (g_PendingSpawnReservations == null)
        return;

    for (int i = g_PendingSpawnReservations.Length - 1; i >= 0; i--)
    {
        float expiresAt = view_as<float>(g_PendingSpawnReservations.Get(
            i, PendingReservation_ExpiresAt));
        if (now >= expiresAt)
            g_PendingSpawnReservations.Erase(i);
    }
}

stock int ReservePendingSpawn(int areaIdx, const float pos[3])
{
    if (g_PendingSpawnReservations == null)
    {
        g_PendingSpawnReservations = new ArrayList(
            view_as<int>(PendingReservation_FieldCount));
    }

    float now = GetGameTime();
    CleanupPendingSpawnReservations(now);

    int token = g_iNextPendingSpawnReservationToken++;
    if (g_iNextPendingSpawnReservationToken <= 0)
        g_iNextPendingSpawnReservationToken = 1;

    int reservation[PendingReservation_FieldCount];
    reservation[PendingReservation_Token] = token;
    reservation[PendingReservation_NavId] = GetNavIDByIndex(areaIdx);
    reservation[PendingReservation_AreaIdx] = areaIdx;
    reservation[PendingReservation_PosX] = view_as<int>(pos[0]);
    reservation[PendingReservation_PosY] = view_as<int>(pos[1]);
    reservation[PendingReservation_PosZ] = view_as<int>(pos[2]);
    reservation[PendingReservation_ExpiresAt] = view_as<int>(
        now + PENDING_RESERVATION_TTL);
    g_PendingSpawnReservations.PushArray(reservation);
    return token;
}

stock void ReleasePendingSpawnReservation(int token)
{
    if (token <= 0 || g_PendingSpawnReservations == null)
        return;

    for (int i = g_PendingSpawnReservations.Length - 1; i >= 0; i--)
    {
        if (g_PendingSpawnReservations.Get(i, PendingReservation_Token) == token)
        {
            g_PendingSpawnReservations.Erase(i);
            return;
        }
    }
}

stock void ClearPendingSpawnReservations()
{
    if (g_PendingSpawnReservations != null)
        g_PendingSpawnReservations.Clear();
}

static float PendingSpawnLimitScale()
{
    // 复用现有 SI 上限缩放趋势，但 pending 只从 1.0 缓降至 0.8，
    // 避免 12 特时直接落到正式刷点记忆的约 0.63 倍。
    return 0.60 + 0.40 * PenLimitScale();
}

stock bool PassPendingSpawnSeparation(int areaIdx, const float pos[3],
                                      bool &sameNavBlocked)
{
    sameNavBlocked = false;
    if (g_PendingSpawnReservations == null
        || g_PendingSpawnReservations.Length == 0)
    {
        return true;
    }

    CleanupPendingSpawnReservations(GetGameTime());
    int navId = GetNavIDByIndex(areaIdx);
    float limitScale = PendingSpawnLimitScale();
    float nearbyRadius = PENDING_SEP_RADIUS * limitScale;
    float sameNavRadius = PENDING_SAME_NAV_RADIUS;
    for (int i = g_PendingSpawnReservations.Length - 1; i >= 0; i--)
    {
        int reservedNavId = g_PendingSpawnReservations.Get(
            i, PendingReservation_NavId);
        bool sameNav = (navId > 0 && reservedNavId == navId)
            || (navId <= 0 && reservedNavId <= 0
                && g_PendingSpawnReservations.Get(
                    i, PendingReservation_AreaIdx) == areaIdx);
        float minDistance = sameNav ? sameNavRadius : nearbyRadius;
        float reservedPos[3];
        reservedPos[0] = view_as<float>(g_PendingSpawnReservations.Get(
            i, PendingReservation_PosX));
        reservedPos[1] = view_as<float>(g_PendingSpawnReservations.Get(
            i, PendingReservation_PosY));
        reservedPos[2] = view_as<float>(g_PendingSpawnReservations.Get(
            i, PendingReservation_PosZ));
        if (GetVectorDistance(pos, reservedPos, true)
            < minDistance * minDistance)
        {
            sameNavBlocked = sameNav;
            return false;
        }
    }
    return true;
}

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
        if (now - rec[3] > SEP_TTL)
            lastSpawns.Erase(i);
    }

    int cap = GetSepMax();
    while (lastSpawns.Length > cap)
        lastSpawns.Erase(0);
}

stock bool PassMinSeparation(const float pos[3])
{
    if (lastSpawns == null || lastSpawns.Length == 0) return true;

    float now = GetGameTime();
    float k = PenLimitScale();
    float sepRadiusEff = SEP_RADIUS * k;
    float sep2 = sepRadiusEff * sepRadiusEff;

    for (int i = lastSpawns.Length - 1; i >= 0; i--)
    {
        float rec[4];
        lastSpawns.GetArray(i, rec);

        if (now - rec[3] > SEP_TTL)
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

stock int ComputeSectorIndex(const float center[3], const float pt[3], int sectors)
{
    float dx = pt[0] - center[0];
    float dy = pt[1] - center[1];
    float ang = ArcTangent2(dy, dx);
    if (ang < 0.0) ang += 2.0 * FLOAT_PI;

    float w = (2.0 * FLOAT_PI) / float(sectors);
    int idx = RoundToFloor(ang / w);
    if (idx < 0) idx = 0;
    if (idx >= sectors) idx = sectors - 1;
    return idx;
}

stock void GetSectorCenter(float outCenter[3], int targetSur)
{
    if (IsValidSurvivor(targetSur))
    {
        GetClientAbsOrigin(targetSur, outCenter);
        return;
    }

    int fb = GetHighestFlowSurvivorSafe();
    if (IsValidSurvivor(fb))
    {
        GetClientAbsOrigin(fb, outCenter);
        return;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidSurvivor(i) && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, outCenter);
            return;
        }
    }

    outCenter[0] = outCenter[1] = outCenter[2] = 0.0;
}

stock void RememberSpawn(const float pos[3], const float center[3])
{
    float now = GetGameTime();
    CleanupLastSpawns(now);

    float rec[4];
    rec[0] = pos[0];
    rec[1] = pos[1];
    rec[2] = pos[2];
    rec[3] = now;
    lastSpawns.PushArray(rec);

    int sectors = GetCurrentSectors();
    int s = ComputeSectorIndex(center, pos, sectors);
    recentSectors[2] = recentSectors[1];
    recentSectors[1] = recentSectors[0];
    recentSectors[0] = s;
}

int GetCurrentSectors()
{
    int T = gCV.iSiLimit;
    int n = (T <= 2) ? 2 : (RoundToCeil(float(T) / 2.0) + 1);
    if (n < DYN_SECTORS_MIN) n = DYN_SECTORS_MIN;
    if (n > SECTORS_MAX)     n = SECTORS_MAX;
    return n;
}

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
