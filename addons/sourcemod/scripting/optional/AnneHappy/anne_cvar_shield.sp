// anne_cvar_shield.sp
//
// Owns Anne's selected SI limit cvars and restores them after gamemode/default
// resets. Config commands are treated as the authority; later unknown writes are
// considered pollution and rolled back to the last authorized target.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_NAME                   "Anne CVar Shield"
#define PLUGIN_VERSION                "2.1.0"

#define PROTECTED_COUNT               14
#define INDEX_SI_LIMIT                0
#define INDEX_CLASS_BASE_START        1
#define INDEX_CLASS_VERSUS_START      7
#define SI_CLASS_COUNT                6

#define AUTHORIZE_WINDOW              0.35
#define CAPTURE_DELAY                 1.0
#define ENFORCE_DELAY                 0.05

static const char g_sProtectedCvars[PROTECTED_COUNT][] =
{
    "l4d_infected_limit",
    "z_smoker_limit",
    "z_boomer_limit",
    "z_hunter_limit",
    "z_spitter_limit",
    "z_jockey_limit",
    "z_charger_limit",
    "z_versus_smoker_limit",
    "z_versus_boomer_limit",
    "z_versus_hunter_limit",
    "z_versus_spitter_limit",
    "z_versus_jockey_limit",
    "z_versus_charger_limit",
    "versus_special_respawn_interval"
};

ConVar g_hEnable;
ConVar g_hDebug;
ConVar g_hSyncVersus;
ConVar g_hProtected[PROTECTED_COUNT];
ConVar g_hGameMode;

bool g_bProtectedHooked[PROTECTED_COUNT];
bool g_bTargetReady[PROTECTED_COUNT];
bool g_bAuthorizedPending[PROTECTED_COUNT];
bool g_bApplying;
bool g_bGameModeHooked;

int g_iTarget[PROTECTED_COUNT];
int g_iAuthorizedValue[PROTECTED_COUNT];

float g_fAuthorizedUntil[PROTECTED_COUNT];

Handle g_hCaptureTimer;
Handle g_hEnforceTimer;

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "morzlee / Codex",
    description = "Keeps Anne vote-selected SI limit cvars authoritative.",
    version = PLUGIN_VERSION,
    url = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    RegPluginLibrary("anne_cvar_shield");
    CreateNative("AnneCvarShield_AuthorizeTarget", Native_AuthorizeTarget);
    return APLRes_Success;
}

public any Native_AuthorizeTarget(Handle plugin, int numParams)
{
    char cvarName[64];
    GetNativeString(1, cvarName, sizeof(cvarName));
    int value = GetNativeCell(2);

    return AuthorizeTargetByName(cvarName, value, "native");
}

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
    g_hSyncVersus = CreateConVar(
        "anne_cvar_shield_sync_versus_limits", "1",
        "Mirror z_*_limit and z_versus_*_limit targets for each SI class.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_hEnable.AddChangeHook(OnControlCvarChanged);
    g_hDebug.AddChangeHook(OnControlCvarChanged);
    g_hSyncVersus.AddChangeHook(OnControlCvarChanged);

    RegServerCmd(
        "anne_cvar_shield_capture",
        Command_CaptureTargets,
        "Capture current Anne SI limit cvars as shield targets."
    );
    AddCommandListener(OnAuthorityCommand, "sm_cvar");
    AddCommandListener(OnAnyAuthorityCommand);

    for (int i = 0; i < PROTECTED_COUNT; i++)
        AddCommandListener(OnDirectProtectedCommand, g_sProtectedCvars[i]);

    BindConVars();
    BindGameModeCvar();
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    ScheduleCapture(CAPTURE_DELAY);
}

public void OnMapStart()
{
    ClearAuthorizationWindows();
    BindConVars();
    BindGameModeCvar();
    StartGuardBurst();
    ScheduleCapture(3.0);
}

public void OnConfigsExecuted()
{
    CaptureMissingTargets();
    StartGuardBurst();
}

public void OnPluginEnd()
{
    ClearTimer(g_hCaptureTimer);
    ClearTimer(g_hEnforceTimer);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    CaptureMissingTargets();
    StartGuardBurst();
}

public Action Command_CaptureTargets(int args)
{
    if (!IsShieldEnabled())
        return Plugin_Handled;

    CaptureCurrentTargets();
    StartGuardBurst();
    return Plugin_Handled;
}

public Action OnAuthorityCommand(int client, const char[] command, int argc)
{
    if (!IsShieldEnabled() || argc < 2)
        return Plugin_Continue;

    char cvarName[64];
    GetCmdArg(1, cvarName, sizeof(cvarName));

    int index = FindProtectedNameIndex(cvarName);
    if (index < 0)
        return Plugin_Continue;

    int value;
    if (!ReadCommandIntArg(2, value))
        return Plugin_Continue;

    AuthorizeTargetFromCommand(index, value, command);
    return Plugin_Continue;
}

public Action OnAnyAuthorityCommand(int client, const char[] command, int argc)
{
    if (!StrEqual(command, "confogl_addcvar", false))
        return Plugin_Continue;

    return OnAuthorityCommand(client, command, argc);
}

public Action OnDirectProtectedCommand(int client, const char[] command, int argc)
{
    if (!IsShieldEnabled() || argc < 1)
        return Plugin_Continue;

    int index = FindProtectedNameIndex(command);
    if (index < 0)
        return Plugin_Continue;

    int value;
    if (!ReadCommandIntArg(1, value))
        return Plugin_Continue;

    AuthorizeTargetFromCommand(index, value, command);
    return Plugin_Continue;
}

public void OnProtectedCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (g_bApplying || !IsShieldEnabled())
        return;

    int index = FindProtectedIndex(convar);
    if (index < 0)
        return;

    int newInt = StringToInt(newValue);

    if (IsAuthorizedChange(index, newInt))
    {
        AcceptAuthorizedChange(index, newInt);
        SyncClassPair(index);
        StartGuardBurst();
        return;
    }

    if (g_bTargetReady[index] && newInt == g_iTarget[index])
        return;

    if (!g_bTargetReady[index])
    {
        CaptureTarget(index, newInt, "first-observed change");
        SyncClassPair(index);
        StartGuardBurst();
        return;
    }

    ShieldLog(
        "reject %s %d -> %d, restoring target %d",
        g_sProtectedCvars[index],
        StringToInt(oldValue),
        newInt,
        g_iTarget[index]
    );
    ScheduleEnforceBurst();
}

public void OnControlCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!IsShieldEnabled())
        return;

    NormalizeAllClassPairTargets();
    StartGuardBurst();
}

public void OnGameModeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!IsShieldEnabled())
        return;

    ShieldLog("mp_gamemode changed %s -> %s, guarding SI limits", oldValue, newValue);
    StartGuardBurst();
}

public Action Timer_CaptureMissing(Handle timer, any data)
{
    if (timer == g_hCaptureTimer)
        g_hCaptureTimer = null;

    CaptureMissingTargets();
    StartGuardBurst();
    return Plugin_Stop;
}

public Action Timer_Enforce(Handle timer, any data)
{
    if (timer == g_hEnforceTimer)
        g_hEnforceTimer = null;

    EnforceTargets();
    return Plugin_Stop;
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

static void BindGameModeCvar()
{
    if (g_hGameMode == null)
        g_hGameMode = FindConVar("mp_gamemode");

    if (g_hGameMode != null && !g_bGameModeHooked)
    {
        g_hGameMode.AddChangeHook(OnGameModeChanged);
        g_bGameModeHooked = true;
    }
}

static void AuthorizeTargetFromCommand(int index, int value, const char[] reason)
{
    SetTarget(index, value, reason);
    ArmAuthorization(index, value);

    int pair = GetPairIndex(index);
    if (ShouldSyncClassPairs() && pair >= 0)
    {
        SetTarget(pair, value, reason);
        ArmAuthorization(pair, value);
    }

    ShieldLog("authorize %s=%d via %s", g_sProtectedCvars[index], value, reason);
    StartGuardBurst();
}

static bool AuthorizeTargetByName(const char[] cvarName, int value, const char[] reason)
{
    if (!IsShieldEnabled())
        return false;

    int index = FindProtectedNameIndex(cvarName);
    if (index < 0)
        return false;

    AuthorizeTargetFromCommand(index, value, reason);
    return true;
}

static bool IsAuthorizedChange(int index, int value)
{
    if (!g_bAuthorizedPending[index])
        return false;

    if (g_iAuthorizedValue[index] != value)
        return false;

    if (GetEngineTime() > g_fAuthorizedUntil[index])
    {
        g_bAuthorizedPending[index] = false;
        return false;
    }

    return true;
}

static void AcceptAuthorizedChange(int index, int value)
{
    SetTarget(index, value, "authorized change");
    g_bAuthorizedPending[index] = false;
    ShieldLog("accept %s=%d", g_sProtectedCvars[index], value);
}

static void ArmAuthorization(int index, int value)
{
    g_bAuthorizedPending[index] = true;
    g_iAuthorizedValue[index] = value;
    g_fAuthorizedUntil[index] = GetEngineTime() + AUTHORIZE_WINDOW;
}

static void ClearAuthorizationWindows()
{
    for (int i = 0; i < PROTECTED_COUNT; i++)
        g_bAuthorizedPending[i] = false;
}

static void CaptureCurrentTargets()
{
    if (!IsShieldEnabled())
        return;

    BindConVars();

    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (g_hProtected[i] == null)
        {
            ShieldLog("capture skipped, missing %s", g_sProtectedCvars[i]);
            continue;
        }

        CaptureTarget(i, g_hProtected[i].IntValue, "manual capture");
    }

    NormalizeAllClassPairTargets();
}

static void CaptureMissingTargets()
{
    if (!IsShieldEnabled())
        return;

    BindConVars();

    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (g_bTargetReady[i])
            continue;

        if (g_hProtected[i] == null)
        {
            ShieldLog("capture postponed, missing %s", g_sProtectedCvars[i]);
            continue;
        }

        CaptureTarget(i, g_hProtected[i].IntValue, "initial capture");
    }

    NormalizeAllClassPairTargets();
}

static void CaptureTarget(int index, int value, const char[] reason)
{
    SetTarget(index, value, reason);
}

static void SetTarget(int index, int value, const char[] reason)
{
    g_iTarget[index] = value;
    g_bTargetReady[index] = true;
    ShieldLog("target %s=%d (%s)", g_sProtectedCvars[index], value, reason);
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
    if (!IsShieldEnabled())
        return;

    BindConVars();
    NormalizeAllClassPairTargets();

    g_bApplying = true;

    for (int i = 0; i < PROTECTED_COUNT; i++)
    {
        if (!g_bTargetReady[i] || g_hProtected[i] == null)
            continue;

        if (g_hProtected[i].IntValue == g_iTarget[i])
            continue;

        ShieldLog("%s: %d -> %d", g_sProtectedCvars[i], g_hProtected[i].IntValue, g_iTarget[i]);
        g_hProtected[i].SetInt(g_iTarget[i]);
    }

    g_bApplying = false;
}

static void SyncClassPair(int index)
{
    if (!ShouldSyncClassPairs())
        return;

    int pair = GetPairIndex(index);
    if (pair < 0 || !g_bTargetReady[index])
        return;

    SetTarget(pair, g_iTarget[index], "class pair sync");

    if (g_hProtected[pair] == null || g_hProtected[pair].IntValue == g_iTarget[pair])
        return;

    g_bApplying = true;
    ShieldLog("%s sync: %d -> %d", g_sProtectedCvars[pair], g_hProtected[pair].IntValue, g_iTarget[pair]);
    g_hProtected[pair].SetInt(g_iTarget[pair]);
    g_bApplying = false;
}

static void NormalizeAllClassPairTargets()
{
    if (!ShouldSyncClassPairs())
        return;

    for (int offset = 0; offset < SI_CLASS_COUNT; offset++)
    {
        int base = INDEX_CLASS_BASE_START + offset;
        int versus = INDEX_CLASS_VERSUS_START + offset;

        if (g_bTargetReady[base])
        {
            if (!g_bTargetReady[versus] || g_iTarget[versus] != g_iTarget[base])
                SetTarget(versus, g_iTarget[base], "base class pair target");
        }
        else if (g_bTargetReady[versus])
        {
            SetTarget(base, g_iTarget[versus], "versus class pair target");
        }
    }
}

static int GetPairIndex(int index)
{
    if (index >= INDEX_CLASS_BASE_START && index < INDEX_CLASS_BASE_START + SI_CLASS_COUNT)
        return INDEX_CLASS_VERSUS_START + (index - INDEX_CLASS_BASE_START);

    if (index >= INDEX_CLASS_VERSUS_START && index < INDEX_CLASS_VERSUS_START + SI_CLASS_COUNT)
        return INDEX_CLASS_BASE_START + (index - INDEX_CLASS_VERSUS_START);

    return -1;
}

static void ScheduleCapture(float delay)
{
    ClearTimer(g_hCaptureTimer);
    g_hCaptureTimer = CreateTimer(delay, Timer_CaptureMissing, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void ScheduleEnforce(float delay)
{
    ClearTimer(g_hEnforceTimer);
    g_hEnforceTimer = CreateTimer(delay, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
}

static void ScheduleEnforceBurst()
{
    ScheduleEnforce(ENFORCE_DELAY);
    CreateTimer(0.2, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(1.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(3.0, Timer_Enforce, _, TIMER_FLAG_NO_MAPCHANGE);
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

static bool ReadCommandIntArg(int arg, int &value)
{
    char valueText[32];
    GetCmdArg(arg, valueText, sizeof(valueText));
    StripQuotes(valueText);
    TrimString(valueText);

    if (valueText[0] == '\0')
        return false;

    value = StringToInt(valueText);
    return true;
}

static bool ShouldSyncClassPairs()
{
    return (g_hSyncVersus == null || g_hSyncVersus.BoolValue);
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
