// anne_cvar_shield.sp
//
// Keeps Anne's selected SI limit cvars stable after gamemode/default resets.
// The protected values are captured from the active vote/config values instead
// of being derived from l4d_infected_limit.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_NAME       "Anne CVar Shield"
#define PLUGIN_VERSION    "1.1.0"
#define PROTECTED_COUNT   7
#define INDEX_SI_LIMIT    0

#define CAPTURE_DELAY     0.25
#define ENFORCE_DELAY     0.05

static const char g_sProtectedCvars[PROTECTED_COUNT][] =
{
    "l4d_infected_limit",
    "z_smoker_limit",
    "z_boomer_limit",
    "z_hunter_limit",
    "z_spitter_limit",
    "z_jockey_limit",
    "z_charger_limit"
};

ConVar g_hEnable;
ConVar g_hDebug;
ConVar g_hProtected[PROTECTED_COUNT];

bool g_bProtectedHooked[PROTECTED_COUNT];
bool g_bApplying;
bool g_bTargetReady;
bool g_bSmCvarBatchActive;

int g_iTarget[PROTECTED_COUNT];

Handle g_hCaptureTimer;
Handle g_hEnforceTimer;

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "morzlee / Codex",
    description = "Restores Anne vote-selected SI limit cvars after default resets.",
    version = PLUGIN_VERSION,
    url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public void OnPluginStart()
{
    g_hEnable = CreateConVar(
        "anne_cvar_shield_enable", "1",
        "Enable Anne SI limit cvar shield.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );
    g_hDebug = CreateConVar(
        "anne_cvar_shield_debug", "0",
        "Log Anne CVar Shield actions.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_hEnable.AddChangeHook(OnControlCvarChanged);
    g_hDebug.AddChangeHook(OnControlCvarChanged);

    RegServerCmd(
        "anne_cvar_shield_capture",
        Command_CaptureTargets,
        "Capture current Anne SI limit cvars as shield targets."
    );
    AddCommandListener(OnSmCvarCommand, "sm_cvar");

    BindConVars();
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    ScheduleCapture(1.0);
}

public void OnMapStart()
{
    ResetRuntimeState();
    BindConVars();
    ScheduleCapture(3.0);
}

public void OnConfigsExecuted()
{
    if (CaptureCurrentTargets())
        StartGuardBurst();
}

public void OnPluginEnd()
{
    ClearTimer(g_hCaptureTimer);
    ClearTimer(g_hEnforceTimer);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bTargetReady)
        CaptureCurrentTargets();

    StartGuardBurst();
}

public Action Command_CaptureTargets(int args)
{
    if (!IsShieldEnabled())
        return Plugin_Handled;

    if (CaptureCurrentTargets())
        StartGuardBurst();

    return Plugin_Handled;
}

public Action OnSmCvarCommand(int client, const char[] command, int argc)
{
    if (!IsShieldEnabled() || argc < 1)
        return Plugin_Continue;

    char cvarName[64];
    GetCmdArg(1, cvarName, sizeof(cvarName));

    if (FindProtectedNameIndex(cvarName) < 0)
        return Plugin_Continue;

    MarkConfigBatch();
    return Plugin_Continue;
}

public void OnProtectedCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplying || !IsShieldEnabled())
        return;

    int index = FindProtectedIndex(convar);
    if (index < 0)
        return;

    if (g_bSmCvarBatchActive)
    {
        ScheduleCapture(CAPTURE_DELAY);
        return;
    }

    if (g_bTargetReady)
    {
        ScheduleEnforce(ENFORCE_DELAY);
        return;
    }

    ScheduleCapture(CAPTURE_DELAY);
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!IsShieldEnabled())
        return;

    if (g_bTargetReady)
        ScheduleEnforce(ENFORCE_DELAY);
    else
        ScheduleCapture(CAPTURE_DELAY);
}

public Action Timer_Capture(Handle timer, any data)
{
    if (timer == g_hCaptureTimer)
        g_hCaptureTimer = null;

    if (CaptureCurrentTargets())
        StartGuardBurst();

    g_bSmCvarBatchActive = false;
    return Plugin_Stop;
}

public Action Timer_Enforce(Handle timer, any data)
{
    if (timer == g_hEnforceTimer)
        g_hEnforceTimer = null;

    EnforceTargets();
    return Plugin_Stop;
}

static void ResetRuntimeState()
{
    g_bApplying = false;
    g_bTargetReady = false;
    g_bSmCvarBatchActive = false;

    ClearTimer(g_hCaptureTimer);
    ClearTimer(g_hEnforceTimer);
}

static void BindConVars()
{
    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (g_hProtected[i] == null)
            g_hProtected[i] = FindConVar(g_sProtectedCvars[i]);

        if (g_hProtected[i] != null && !g_bProtectedHooked[i])
        {
            g_hProtected[i].AddChangeHook(OnProtectedCvarChanged);
            g_bProtectedHooked[i] = true;
        }
    }
}

static bool CaptureCurrentTargets()
{
    if (!IsShieldEnabled())
        return false;

    BindConVars();

    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (g_hProtected[i] == null)
        {
            ShieldLog("capture postponed, missing %s", g_sProtectedCvars[i]);
            return false;
        }
    }

    for (int i = 0; i < PROTECTED_COUNT; i++)
        g_iTarget[i] = g_hProtected[i].IntValue;

    g_bTargetReady = true;
    ShieldLog(
        "captured total=%d smoker=%d boomer=%d hunter=%d spitter=%d jockey=%d charger=%d",
        g_iTarget[INDEX_SI_LIMIT],
        g_iTarget[1],
        g_iTarget[2],
        g_iTarget[3],
        g_iTarget[4],
        g_iTarget[5],
        g_iTarget[6]
    );
    return true;
}

static void StartGuardBurst()
{
    EnforceTargets();
    CreateTimer(0.2, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(3.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void EnforceTargets()
{
    if (!IsShieldEnabled() || !g_bTargetReady)
        return;

    BindConVars();

    g_bApplying = true;

    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (g_hProtected[i] == null)
            continue;

        if (g_hProtected[i].IntValue != g_iTarget[i])
        {
            ShieldLog("%s: %d -> %d", g_sProtectedCvars[i], g_hProtected[i].IntValue, g_iTarget[i]);
            g_hProtected[i].SetInt(g_iTarget[i]);
        }
    }

    g_bApplying = false;
}

static void MarkConfigBatch()
{
    g_bSmCvarBatchActive = true;
    ScheduleCapture(CAPTURE_DELAY);
}

static void ScheduleCapture(float delay)
{
    ClearTimer(g_hCaptureTimer);
    g_hCaptureTimer = CreateTimer(delay, Timer_Capture, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void ScheduleEnforce(float delay)
{
    ClearTimer(g_hEnforceTimer);
    g_hEnforceTimer = CreateTimer(delay, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
}

static int FindProtectedIndex(ConVar convar)
{
    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (convar == g_hProtected[i])
            return i;
    }

    return -1;
}

static int FindProtectedNameIndex(const char[] cvarName)
{
    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (StrEqual(cvarName, g_sProtectedCvars[i], false))
            return i;
    }

    return -1;
}

static bool IsShieldEnabled()
{
    return (g_hEnable == null || g_hEnable.BoolValue);
}

static void ClearTimer(Handle &timer)
{
    if (timer == null)
        return;

    KillTimer(timer);
    timer = null;
}

static void ShieldLog(const char[] format, any ...)
{
    if (g_hDebug == null || !g_hDebug.BoolValue)
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), format, 2);
    PrintToServer("[AnneCvarShield] %s", buffer);
}
