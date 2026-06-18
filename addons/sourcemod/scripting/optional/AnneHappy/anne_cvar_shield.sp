// anne_cvar_shield.sp
//
// Keeps legacy SI class limit cvars aligned with Anne's internal class caps.
// This is intentionally a small whitelist shield, not a blanket gamemodes.txt
// blocker.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_NAME    "Anne CVar Shield"
#define PLUGIN_VERSION "1.0.0"
#define CLASS_COUNT    6

enum
{
    CLASS_SMOKER = 0,
    CLASS_BOOMER,
    CLASS_HUNTER,
    CLASS_SPITTER,
    CLASS_JOCKEY,
    CLASS_CHARGER
};

static const char g_sClassLimitCvars[CLASS_COUNT][] =
{
    "z_smoker_limit",
    "z_boomer_limit",
    "z_hunter_limit",
    "z_spitter_limit",
    "z_jockey_limit",
    "z_charger_limit"
};

ConVar g_hEnable;
ConVar g_hDebug;
ConVar g_hClassLimit[CLASS_COUNT];
ConVar g_hSiLimit;
ConVar g_hSurvivorLimit;
ConVar g_hEnableMask;
ConVar g_hAllCharger;
ConVar g_hAllHunter;

bool g_bClassHooked[CLASS_COUNT];
bool g_bSiLimitHooked;
bool g_bSurvivorLimitHooked;
bool g_bEnableMaskHooked;
bool g_bAllChargerHooked;
bool g_bAllHunterHooked;
bool g_bApplying;

Handle g_hDebounceTimer;

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "morzlee / Codex",
    description = "Restores Anne-managed SI class limit cvars after mode defaults change them.",
    version = PLUGIN_VERSION,
    url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
    g_hEnable = CreateConVar(
        "anne_cvar_shield_enable", "1",
        "Enable Anne SI class limit cvar shield.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_hDebug = CreateConVar(
        "anne_cvar_shield_debug", "0",
        "Log Anne CVar Shield actions.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_hEnable.AddChangeHook(OnSourceCvarChanged);
    g_hDebug.AddChangeHook(OnSourceCvarChanged);

    BindConVars();
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
    StartGuardBurst();
}

public void OnConfigsExecuted()
{
    StartGuardBurst();
}

public void OnPluginEnd()
{
    if (g_hDebounceTimer != null)
    {
        KillTimer(g_hDebounceTimer);
        g_hDebounceTimer = null;
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StartGuardBurst();
}

public void OnProtectedCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplying || g_hEnable == null || !g_hEnable.BoolValue)
        return;

    ScheduleEnforce(0.05);
}

public void OnSourceCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplying || g_hEnable == null || !g_hEnable.BoolValue)
        return;

    StartGuardBurst();
}

public Action Timer_Enforce(Handle timer, any data)
{
    if (timer == g_hDebounceTimer)
        g_hDebounceTimer = null;

    EnforceClassLimits();
    return Plugin_Stop;
}

static void BindConVars()
{
    for (int i = 0; i < CLASS_COUNT; i++)
    {
        if (g_hClassLimit[i] == null)
            g_hClassLimit[i] = FindConVar(g_sClassLimitCvars[i]);

        if (g_hClassLimit[i] != null && !g_bClassHooked[i])
        {
            g_hClassLimit[i].AddChangeHook(OnProtectedCvarChanged);
            g_bClassHooked[i] = true;
        }
    }

    BindSourceConVar(g_hSiLimit, "l4d_infected_limit", g_bSiLimitHooked);
    BindSourceConVar(g_hSurvivorLimit, "survivor_limit", g_bSurvivorLimitHooked);
    BindSourceConVar(g_hEnableMask, "inf_EnableSIoption", g_bEnableMaskHooked);
    BindSourceConVar(g_hAllCharger, "inf_AllChargerMode", g_bAllChargerHooked);
    BindSourceConVar(g_hAllHunter, "inf_AllHunterMode", g_bAllHunterHooked);
}

static void BindSourceConVar(ConVar &handle, const char[] name, bool &hooked)
{
    if (handle == null)
        handle = FindConVar(name);

    if (handle != null && !hooked)
    {
        handle.AddChangeHook(OnSourceCvarChanged);
        hooked = true;
    }
}

static void StartGuardBurst()
{
    BindConVars();
    EnforceClassLimits();
    CreateTimer(0.2, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(3.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void ScheduleEnforce(float delay)
{
    if (g_hDebounceTimer != null)
    {
        KillTimer(g_hDebounceTimer);
        g_hDebounceTimer = null;
    }

    g_hDebounceTimer = CreateTimer(delay, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
}

static int ClampIntValue(int value, int minValue, int maxValue)
{
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
}

static int AnneMainClassCap(int total)
{
    if (total < 1)
        total = 1;

    return ClampIntValue(RoundToCeil(float(total) / 4.0), 1, 6);
}

static int AnneSpitterClassCap()
{
    int survivorLimit = (g_hSurvivorLimit != null) ? g_hSurvivorLimit.IntValue : 4;
    return (survivorLimit >= 7) ? 2 : 1;
}

static bool BuildExpectedCaps(int caps[CLASS_COUNT])
{
    for (int i = 0; i < CLASS_COUNT; i++)
        caps[i] = 0;

    if (g_hSiLimit == null)
        return false;

    int total = g_hSiLimit.IntValue;
    if (total <= 0)
        return true;

    int mainCap = AnneMainClassCap(total);

    caps[CLASS_SMOKER]  = (total <= 6) ? 1 : mainCap;
    caps[CLASS_BOOMER]  = 1;
    caps[CLASS_HUNTER]  = mainCap;
    caps[CLASS_SPITTER] = AnneSpitterClassCap();
    caps[CLASS_JOCKEY]  = (total <= 5) ? 1 : mainCap;
    caps[CLASS_CHARGER] = mainCap;

    ApplyEnabledMask(caps);
    ApplyForcedMode(total, caps);
    return true;
}

static void ApplyEnabledMask(int caps[CLASS_COUNT])
{
    int mask = (g_hEnableMask != null) ? g_hEnableMask.IntValue : 63;

    for (int i = 0; i < CLASS_COUNT; i++)
    {
        if ((mask & (1 << i)) == 0)
            caps[i] = 0;
    }
}

static void ApplyForcedMode(int total, int caps[CLASS_COUNT])
{
    int forced = -1;
    if (g_hAllHunter != null && g_hAllHunter.BoolValue)
        forced = CLASS_HUNTER;
    if (g_hAllCharger != null && g_hAllCharger.BoolValue)
        forced = CLASS_CHARGER;

    if (forced < 0)
        return;

    for (int i = 0; i < CLASS_COUNT; i++)
        caps[i] = 0;
    caps[forced] = total;
}

static void EnforceClassLimits()
{
    if (g_hEnable == null || !g_hEnable.BoolValue)
        return;

    BindConVars();

    int caps[CLASS_COUNT];
    if (!BuildExpectedCaps(caps))
        return;

    g_bApplying = true;

    for (int i = 0; i < CLASS_COUNT; i++)
    {
        if (g_hClassLimit[i] == null)
            continue;

        if (g_hClassLimit[i].IntValue != caps[i])
        {
            ShieldLog("%s: %d -> %d", g_sClassLimitCvars[i], g_hClassLimit[i].IntValue, caps[i]);
            g_hClassLimit[i].SetInt(caps[i]);
        }
    }

    g_bApplying = false;
}

static void ShieldLog(const char[] format, any ...)
{
    if (g_hDebug == null || !g_hDebug.BoolValue)
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    PrintToServer("[AnneCvarShield] %s", buffer);
}
