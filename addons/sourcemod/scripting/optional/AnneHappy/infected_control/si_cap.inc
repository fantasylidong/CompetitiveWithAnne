#if defined _infected_control_si_cap_included
    #endinput
#endif
#define _infected_control_si_cap_included

#define CLASS_LIMIT_MIRROR_UNSET -1

static const char g_sEngineClassLimitCvars[SI_COUNT][] =
{
    "z_smoker_limit",
    "z_boomer_limit",
    "z_hunter_limit",
    "z_spitter_limit",
    "z_jockey_limit",
    "z_charger_limit"
};

static const char g_sInfClassLimitCvars[SI_COUNT][] =
{
    "inf_smoker_limit",
    "inf_boomer_limit",
    "inf_hunter_limit",
    "inf_spitter_limit",
    "inf_jockey_limit",
    "inf_charger_limit"
};

ConVar g_hInfClassLimit[SI_COUNT];
bool g_bInfClassLimitApplying;

void ClassCapMirrors_Create()
{
    char desc[160];
    for (int i = 0; i < SI_COUNT; i++)
    {
        if (g_hInfClassLimit[i] != null)
            continue;

        Format(
            desc, sizeof(desc),
            "infected_control class cap mirror for %s. -1 = use the engine cvar.",
            g_sEngineClassLimitCvars[i]
        );
        g_hInfClassLimit[i] = CreateConVar(
            g_sInfClassLimitCvars[i],
            "-1",
            desc,
            CVAR_FLAG,
            true, -1.0
        );
        g_hInfClassLimit[i].AddChangeHook(OnClassLimitMirrorChanged);
    }

    AddCommandListener(InfectedControl_OnSmCvarCommand, "sm_cvar");
}

public Action InfectedControl_OnSmCvarCommand(int client, const char[] command, int argc)
{
    if (argc < 2)
        return Plugin_Continue;

    char cvarName[64];
    GetCmdArg(1, cvarName, sizeof(cvarName));

    int index = FindEngineClassLimitNameIndex(cvarName);
    if (index < 0)
        return Plugin_Continue;

    char value[32];
    GetCmdArg(2, value, sizeof(value));
    MirrorClassLimitCommand(index, StringToInt(value));

    return Plugin_Continue;
}

public void OnClassLimitMirrorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bInfClassLimitApplying)
        return;

    RecalcSiCapFromAlive(false);
}

static int FindEngineClassLimitNameIndex(const char[] cvarName)
{
    for (int i = 0; i < SI_COUNT; i++)
    {
        if (StrEqual(cvarName, g_sEngineClassLimitCvars[i], false))
            return i;
    }

    return -1;
}

static void MirrorClassLimitCommand(int index, int value)
{
    if (index < 0 || index >= SI_COUNT)
        return;

    if (value < 0)
        value = 0;

    if (g_hInfClassLimit[index] == null)
        return;

    g_bInfClassLimitApplying = true;
    g_hInfClassLimit[index].SetInt(value);
    g_bInfClassLimitApplying = false;

    RecalcSiCapFromAlive(false);
}

// 按当前在场特感和 vote/cvar 职业上限刷新剩余额度。
void ResetMatchState()
{
    gST.totalSI = 0;
    for (int i = 0; i < SI_COUNT; i++) gST.siAlive[i] = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsCountedSpecial(i) && IsPlayerAlive(i) && !IsGhost(i))
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

static void RefreshClassLimitCvars()
{
    if (gCV.ZSmokerLimit == null)  gCV.ZSmokerLimit = FindConVar("z_smoker_limit");
    if (gCV.ZBoomerLimit == null)  gCV.ZBoomerLimit = FindConVar("z_boomer_limit");
    if (gCV.ZHunterLimit == null)  gCV.ZHunterLimit = FindConVar("z_hunter_limit");
    if (gCV.ZSpitterLimit == null) gCV.ZSpitterLimit = FindConVar("z_spitter_limit");
    if (gCV.ZJockeyLimit == null)  gCV.ZJockeyLimit = FindConVar("z_jockey_limit");
    if (gCV.ZChargerLimit == null) gCV.ZChargerLimit = FindConVar("z_charger_limit");
}

static int ReadClassLimit(ConVar mirrorConvar, ConVar engineConvar)
{
    if (mirrorConvar != null && mirrorConvar.IntValue >= 0)
        return mirrorConvar.IntValue;

    return (engineConvar != null) ? engineConvar.IntValue : 0;
}

static void ReadBaseClassCaps(int caps[SI_COUNT])
{
    RefreshClassLimitCvars();

    caps[view_as<int>(SI_Smoker)  - 1] = ReadClassLimit(g_hInfClassLimit[0], gCV.ZSmokerLimit);
    caps[view_as<int>(SI_Boomer)  - 1] = ReadClassLimit(g_hInfClassLimit[1], gCV.ZBoomerLimit);
    caps[view_as<int>(SI_Hunter)  - 1] = ReadClassLimit(g_hInfClassLimit[2], gCV.ZHunterLimit);
    caps[view_as<int>(SI_Spitter) - 1] = ReadClassLimit(g_hInfClassLimit[3], gCV.ZSpitterLimit);
    caps[view_as<int>(SI_Jockey)  - 1] = ReadClassLimit(g_hInfClassLimit[4], gCV.ZJockeyLimit);
    caps[view_as<int>(SI_Charger) - 1] = ReadClassLimit(g_hInfClassLimit[5], gCV.ZChargerLimit);
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
        if (IsCountedSpecial(c) && IsPlayerAlive(c) && !IsGhost(c))
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
    ReadBaseClassCaps(baseCap);

    for (int i = 0; i < SI_COUNT; i++)
    {
        int remain = baseCap[i] - gST.siAlive[i] - Traitor_CountReservedClassSlots(i + 1);
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
    ReadBaseClassCaps(gST.siCap);

    ApplyForcedClassMode();

    Debug_Print("[CAP] caps S=%d B=%d H=%d P=%d J=%d C=%d",
        gST.siCap[0], gST.siCap[1], gST.siCap[2], gST.siCap[3], gST.siCap[4], gST.siCap[5]);
}
