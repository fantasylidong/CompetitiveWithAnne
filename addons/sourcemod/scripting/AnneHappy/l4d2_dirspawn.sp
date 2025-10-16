// l4d2_dirspawn.sp
//
// Left 4 Dead 2 - Director Special Infected Spawner (Anne-style, VScript-only)
// - Control total SI count, respawn interval, and per-class limits via SessionOptions.
// - Reads per-count class caps from a KeyValues file (cfg/sourcemod/dirspawn_si_limits.cfg).
// - Provides an admin command to auto-generate that KV for a range (e.g., 1..30).
//
// Requirements: SourceMod 1.11+, Left4DHooks extension
//
// Build: put into addons/sourcemod/scripting/, compile with spcomp.
// Quickstart:
//   sm_cvar dirspawn_enable 1
//   sm_cvar dirspawn_count 12
//   sm_cvar dirspawn_interval 15
//   sm_cvar dirspawn_apply_on_roundstart 1
//   sm_dirspawn_apply
//
// Optional: generate KV (balanced split) for 1..30:
//   sm_dirspawn_genkv 1 30
//
// © 2025 morzlee

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_NAME        "L4D2 Director SI Spawner (VScript-only)"
#define PLUGIN_VERSION     "1.1.1"
#define PLUGIN_AUTHOR      "morzlee"
#define PLUGIN_URL         "https://github.com/fantasylidong/CompetitiveWithAnne"

// ---------------------------- ConVars ----------------------------------
ConVar gCvarEnable;
ConVar gCvarCount;
ConVar gCvarInterval;
ConVar gCvarDomLimit;
ConVar gCvarApplyOnRoundStart; // 1 = apply on round_start
ConVar gCvarApplyDelay;        // seconds to delay initial apply
ConVar gCvarKvEnable;          // 1 = use KV mapping file for per-class limits
ConVar gCvarKvPath;            // path to KV file
ConVar gCvarVerbose;           // prints
ConVar gCvarActiveChallenge;   // set aggressive flags

// ---------------------------- Constants --------------------------------
enum SIClass
{
    SI_Smoker = 0,
    SI_Boomer,
    SI_Hunter,
    SI_Spitter,
    SI_Jockey,
    SI_Charger,
    SI_Count
};

// Use an untagged constant for arithmetic to avoid tag-mismatch warnings.
const int kSIClassCount = view_as<int>(SI_Count);

static const char g_SIKeys[SI_Count][] =
{
    "SmokerLimit",
    "BoomerLimit",
    "HunterLimit",
    "SpitterLimit",
    "JockeyLimit",
    "ChargerLimit"
};

// Anne-like distribution priority for remainder share
static const SIClass g_DefaultDistributeOrder[SI_Count] =
{
    SI_Hunter, SI_Charger, SI_Smoker, SI_Jockey, SI_Spitter, SI_Boomer
};

// ---------------------------- State ------------------------------------
Handle g_hApplyTimer = null;

// ---------------------------- Plugin Info ------------------------------
public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "Control SI max count & respawn interval with Anne-style per-class caps (VScript-only)",
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

// ---------------------------- Helpers ----------------------------------
stock void LogMsg(const char[] fmt, any ...)
{
    if (gCvarVerbose != null && gCvarVerbose.BoolValue)
    {
        char buffer[256];
        VFormat(buffer, sizeof(buffer), fmt, 2);
        PrintToServer("[DirSpawn] %s", buffer);
    }
}

stock void VS_RawSetInt(const char[] key, int value)
{
    char code[96];
    Format(code, sizeof(code), "::SessionOptions.rawset(\"%s\", %d)", key, value);
    L4D2_ExecVScriptCode(code);
}

stock void VS_RawSetBool(const char[] key, bool value)
{
    char code[96];
    Format(code, sizeof(code), "::SessionOptions.rawset(\"%s\", %s)", key, value ? "true" : "false");
    L4D2_ExecVScriptCode(code);
}

stock void VS_RawDelete(const char[] key)
{
    char code[96];
    Format(code, sizeof(code), "::SessionOptions.rawdelete(\"%s\")", key);
    L4D2_ExecVScriptCode(code);
}

stock void VS_EnsureBaseFlags()
{
    if (gCvarActiveChallenge.BoolValue)
    {
        VS_RawSetInt("ActiveChallenge", 1);
        VS_RawSetInt("cm_AggressiveSpecials", 1);
        VS_RawSetInt("SpecialInfectedAssault", 1);
    }
}

// Compute a balanced per-class split when no explicit mapping is provided.
stock void ComputeBalancedSplit(int total, int outCaps[SI_Count])
{
    for (int i = 0; i < kSIClassCount; i++)
        outCaps[i] = 0;

    if (total <= 0)
        return;

    int base = total / kSIClassCount;          // even base
    int rem  = total % kSIClassCount;          // remainder

    for (int i = 0; i < kSIClassCount; i++)
        outCaps[i] = base;

    for (int i = 0; i < rem; i++)
    {
        SIClass cls = g_DefaultDistributeOrder[i % kSIClassCount];
        outCaps[cls]++;
    }
}

// Try to load caps from KV file, e.g. at "cfg/sourcemod/dirspawn_si_limits.cfg"
stock bool LoadCapsFromKV(int total, int outCaps[SI_Count])
{
    char path[PLATFORM_MAX_PATH];
    gCvarKvPath.GetString(path, sizeof(path));

    KeyValues kv = new KeyValues("DirSpawnLimits");
    if (!kv.ImportFromFile(path))
    {
        LogMsg("KV file not found: %s", path);
        delete kv;
        return false;
    }

    char key[16];
    IntToString(total, key, sizeof(key));

    if (!kv.JumpToKey(key, false))
    {
        LogMsg("KV: no section for %d", total);
        delete kv;
        return false;
    }

    outCaps[SI_Smoker] = kv.GetNum("Smoker", 0);
    outCaps[SI_Boomer] = kv.GetNum("Boomer", 0);
    outCaps[SI_Hunter] = kv.GetNum("Hunter", 0);
    outCaps[SI_Spitter]= kv.GetNum("Spitter",0);
    outCaps[SI_Jockey] = kv.GetNum("Jockey", 0);
    outCaps[SI_Charger]= kv.GetNum("Charger",0);
    delete kv;
    return true;
}

stock void ApplyByVScript(int total, int interval)
{
    VS_EnsureBaseFlags();

    // Max specials & dominators
    VS_RawSetInt("cm_MaxSpecials", total);

    int dom = gCvarDomLimit.IntValue;
    if (dom < 0) dom = total;
    VS_RawSetInt("DominatorLimit", dom);

    // Respawn interval (seconds)
    VS_RawSetInt("cm_SpecialRespawnInterval", interval);

    // Per-class caps
    int caps[SI_Count];
    bool haveKV = (gCvarKvEnable.BoolValue && LoadCapsFromKV(total, caps));
    if (!haveKV)
    {
        ComputeBalancedSplit(total, caps);
    }

    for (int i = 0; i < kSIClassCount; i++)
    {
        VS_RawSetInt(g_SIKeys[i], caps[i]);
    }

    LogMsg("Applied: total=%d, dom=%d, interval=%d, KV=%s",
           total, dom, interval, haveKV ? "yes" : "no");
}

stock void ApplyDirectorSettings(bool announceToChat=false)
{
    if (!gCvarEnable.BoolValue)
    {
        LogMsg("dirspawn_enable=0: skipped apply.");
        return;
    }

    int total    = gCvarCount.IntValue;
    int interval = gCvarInterval.IntValue;
    if (total < 0)    total = 0;
    if (interval < 0) interval = 0;

    ApplyByVScript(total, interval);

    if (announceToChat)
    {
        char msg[128];
        Format(msg, sizeof(msg), "导演刷特应用：总数=%d，间隔=%d 秒", total, interval);
        PrintToChatAll("[DirSpawn] %s", msg);
    }
}

// Undo VScript keys (optional on unload or when disabling)
stock void ShutdownVScript()
{
    VS_RawDelete("cm_MaxSpecials");
    VS_RawDelete("DominatorLimit");
    VS_RawDelete("cm_SpecialRespawnInterval");
    for (int i = 0; i < kSIClassCount; i++)
    {
        VS_RawDelete(g_SIKeys[i]);
    }
    if (gCvarActiveChallenge.BoolValue)
    {
        VS_RawDelete("ActiveChallenge");
        VS_RawDelete("cm_AggressiveSpecials");
        VS_RawDelete("SpecialInfectedAssault");
    }
    LogMsg("VScript session options cleared.");
}

// ---------------------------- Console Commands -------------------------
public Action Cmd_Apply(int client, int args)
{
    if (args >= 1)
    {
        int count = GetCmdArgInt(1);
        gCvarCount.SetInt(count);
    }
    if (args >= 2)
    {
        int interval = GetCmdArgInt(2);
        gCvarInterval.SetInt(interval);
    }
    ApplyDirectorSettings(true);
    return Plugin_Handled;
}

public Action Cmd_GenKV(int client, int args)
{
    int min = 1, max = 30;
    if (args >= 1) min = GetCmdArgInt(1);
    if (args >= 2) max = GetCmdArgInt(2);
    if (min < 0) min = 0;
    if (max < min) max = min;

    char path[PLATFORM_MAX_PATH];
    gCvarKvPath.GetString(path, sizeof(path));

    KeyValues kv = new KeyValues("DirSpawnLimits");

    int caps[SI_Count];
    char sec[16];

    for (int total = min; total <= max; total++)
    {
        ComputeBalancedSplit(total, caps);
        IntToString(total, sec, sizeof(sec));
        if (!kv.JumpToKey(sec, true))
        {
            PrintToServer("[DirSpawn] KV JumpToKey failed for %d", total);
            continue;
        }
        kv.SetNum("Smoker",  caps[SI_Smoker]);
        kv.SetNum("Boomer",  caps[SI_Boomer]);
        kv.SetNum("Hunter",  caps[SI_Hunter]);
        kv.SetNum("Spitter", caps[SI_Spitter]);
        kv.SetNum("Jockey",  caps[SI_Jockey]);
        kv.SetNum("Charger", caps[SI_Charger]);
        kv.GoBack();
    }

    bool ok = kv.ExportToFile(path);
    delete kv;
    if (ok)
    {
        PrintToServer("[DirSpawn] Generated KV to: %s (range %d..%d)", path, min, max);
        if (client > 0) PrintToChat(client, "[DirSpawn] KV generated: %s", path);
    }
    else
    {
        PrintToServer("[DirSpawn] Failed to write KV: %s", path);
        if (client > 0) PrintToChat(client, "[DirSpawn] Failed to write KV: %s", path);
    }
    return Plugin_Handled;
}

// ---------------------------- Events / Timers --------------------------
public Action EVT_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!gCvarEnable.BoolValue || !gCvarApplyOnRoundStart.BoolValue)
        return Plugin_Continue;

    float delay = gCvarApplyDelay.FloatValue;
    if (delay < 0.1) delay = 0.1;

    if (g_hApplyTimer != null)
    {
        KillTimer(g_hApplyTimer);
        g_hApplyTimer = null;
    }
    g_hApplyTimer = CreateTimer(delay, TMR_ApplyOnce, _, TIMER_FLAG_NO_MAPCHANGE);
    LogMsg("Scheduled apply in %.1f sec (round_start).", delay);
    return Plugin_Continue;
}

public Action TMR_ApplyOnce(Handle timer, any data)
{
    g_hApplyTimer = null;
    ApplyDirectorSettings(false);
    return Plugin_Stop;
}

public void OnConfigsExecuted()
{
    if (gCvarEnable != null && gCvarEnable.BoolValue && gCvarApplyOnRoundStart.BoolValue)
    {
        float delay = gCvarApplyDelay.FloatValue + 0.5;
        if (g_hApplyTimer != null)
        {
            KillTimer(g_hApplyTimer);
            g_hApplyTimer = null;
        }
        g_hApplyTimer = CreateTimer(delay, TMR_ApplyOnce, _, TIMER_FLAG_NO_MAPCHANGE);
        LogMsg("Scheduled apply in %.1f sec (OnConfigsExecuted).", delay);
    }
}

// ---------------------------- ConVar Changed ---------------------------
public void CvarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    if (!gCvarEnable.BoolValue) return;

    if (cvar == gCvarCount || cvar == gCvarInterval || cvar == gCvarDomLimit || cvar == gCvarKvEnable || cvar == gCvarKvPath)
    {
        if (g_hApplyTimer != null)
        {
            KillTimer(g_hApplyTimer);
            g_hApplyTimer = null;
        }
        g_hApplyTimer = CreateTimer(0.25, TMR_ApplyOnce, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ---------------------------- Lifecycle --------------------------------
public void OnPluginStart()
{
    gCvarEnable            = CreateConVar("dirspawn_enable", "1", "Enable Director SI Spawner (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarCount             = CreateConVar("dirspawn_count", "12", "Total concurrent SI (cm_MaxSpecials)", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarInterval          = CreateConVar("dirspawn_interval", "15", "cm_SpecialRespawnInterval (seconds)", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarDomLimit          = CreateConVar("dirspawn_dominator_limit", "-1", "DominatorLimit (-1=auto=dirspawn_count)", FCVAR_NOTIFY, true, -1.0, true, 30.0);
    gCvarApplyOnRoundStart = CreateConVar("dirspawn_apply_on_roundstart", "1", "Apply automatically at round_start", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarApplyDelay        = CreateConVar("dirspawn_apply_delay", "1.0", "Delay (sec) before apply at round_start/OnConfigsExecuted", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    gCvarKvEnable          = CreateConVar("dirspawn_kv_enable", "1", "Use KV file to set per-class caps (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarKvPath            = CreateConVar("dirspawn_kv_path", "cfg/sourcemod/dirspawn_si_limits.cfg", "KeyValues file path for per-class caps", FCVAR_NOTIFY);
    gCvarVerbose           = CreateConVar("dirspawn_verbose", "1", "Verbose logs (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarActiveChallenge   = CreateConVar("dirspawn_active_challenge", "1", "Set ActiveChallenge/Aggressive/Assault flags (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(gCvarCount,             CvarChanged);
    HookConVarChange(gCvarInterval,          CvarChanged);
    HookConVarChange(gCvarDomLimit,          CvarChanged);
    HookConVarChange(gCvarKvEnable,          CvarChanged);
    HookConVarChange(gCvarKvPath,            CvarChanged);

    RegAdminCmd("sm_dirspawn_apply", Cmd_Apply, ADMFLAG_GENERIC, "sm_dirspawn_apply [count] [interval] - apply settings now");
    RegAdminCmd("sm_dirspawn_genkv", Cmd_GenKV, ADMFLAG_ROOT,    "sm_dirspawn_genkv [min] [max] - generate KV (balanced) to dirspawn_kv_path");

    HookEvent("round_start", EVT_RoundStart, EventHookMode_PostNoCopy);

    LogMsg("%s v%s loaded.", PLUGIN_NAME, PLUGIN_VERSION);
}

public void OnPluginEnd()
{
    ShutdownVScript();
}
