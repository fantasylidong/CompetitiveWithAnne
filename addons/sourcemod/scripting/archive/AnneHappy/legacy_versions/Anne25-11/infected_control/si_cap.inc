#if defined _infected_control_si_cap_included
    #endinput
#endif
#define _infected_control_si_cap_included

// 按当前在场特感和 Anne 内部职业上限刷新剩余额度。
void ResetMatchState()
{
    gST.totalSI = 0;
    for (int i = 0; i < SI_COUNT; i++) gST.siAlive[i] = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsInfectedBot(i) && IsPlayerAlive(i))
        {
            gST.teleCount[i] = 0;
            int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
            if (zc >= 1 && zc <= SI_COUNT)
            {
                gST.siAlive[zc - 1]++;
                gST.totalSI++;
            }
        }
        if (IsValidSurvivor(i) && !IsPlayerAlive(i))
            L4D_RespawnPlayer(i);
    }

    ResetDeathState();
}

static int AnneMainClassCap(int siLimit)
{
    if (siLimit < 1)
        siLimit = 1;

    return ClampInt(RoundToCeil(float(siLimit) / 4.0), 1, 6);
}

static int AnneSpitterClassCap()
{
    int survivorLimit = (gCV.SurvivorLimit != null) ? gCV.SurvivorLimit.IntValue : 4;
    return (survivorLimit >= 7) ? 2 : 1;
}

static void BuildAnneClassCaps(int siLimit, int caps[SI_COUNT])
{
    for (int i = 0; i < SI_COUNT; i++)
        caps[i] = 0;

    if (siLimit <= 0)
        return;

    int mainCap = AnneMainClassCap(siLimit);

    caps[view_as<int>(SI_Smoker)  - 1] = (siLimit <= 6) ? 1 : mainCap;
    caps[view_as<int>(SI_Boomer)  - 1] = 1;
    caps[view_as<int>(SI_Hunter)  - 1] = mainCap;
    caps[view_as<int>(SI_Spitter) - 1] = AnneSpitterClassCap();
    caps[view_as<int>(SI_Jockey)  - 1] = (siLimit <= 5) ? 1 : mainCap;
    caps[view_as<int>(SI_Charger) - 1] = mainCap;
}

static void ApplyForcedClassMode()
{
    int forced = 0;
    if (gCV.AllHunter.BoolValue)  forced = view_as<int>(SI_Hunter);
    if (gCV.AllCharger.BoolValue) forced = view_as<int>(SI_Charger);
    if (forced == 0) return;

    for (int i = 0; i < SI_COUNT; i++) gST.siCap[i] = 0;
    int idx = forced - 1;
    int want = gCV.iSiLimit - gST.siAlive[idx];
    if (want < 0) want = 0;
    gST.siCap[idx] = want;
}

void RecalcSiCapFromAlive(bool log = false)
{
    for (int i = 0; i < SI_COUNT; i++) gST.siAlive[i] = 0;
    gST.totalSI = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (IsInfectedBot(c) && IsPlayerAlive(c))
        {
            int zc = GetEntProp(c, Prop_Send, "m_zombieClass");
            if (1 <= zc && zc <= SI_COUNT)
            {
                gST.siAlive[zc - 1]++;
                gST.totalSI++;
            }
        }
    }

    int baseCap[SI_COUNT];
    BuildAnneClassCaps(gCV.iSiLimit, baseCap);

    for (int i = 0; i < SI_COUNT; i++)
    {
        int remain = baseCap[i] - gST.siAlive[i];
        if (remain < 0) remain = 0;
        gST.siCap[i] = remain;
    }

    ApplyForcedClassMode();

    if (log) Debug_Print("[CAP] remain S=%d B=%d H=%d P=%d J=%d C=%d | alive S=%d B=%d H=%d P=%d J=%d C=%d | total=%d",
        gST.siCap[0], gST.siCap[1], gST.siCap[2], gST.siCap[3], gST.siCap[4], gST.siCap[5],
        gST.siAlive[0], gST.siAlive[1], gST.siAlive[2], gST.siAlive[3], gST.siAlive[4], gST.siAlive[5],
        gST.totalSI);
}

void ReadSiCap()
{
    BuildAnneClassCaps(gCV.iSiLimit, gST.siCap);

    ApplyForcedClassMode();

    Debug_Print("[CAP] caps S=%d B=%d H=%d P=%d J=%d C=%d",
        gST.siCap[0], gST.siCap[1], gST.siCap[2], gST.siCap[3], gST.siCap[4], gST.siCap[5]);
}
