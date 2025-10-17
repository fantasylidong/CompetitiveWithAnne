// l4d2_dirspawn.sp
//
// Left 4 Dead 2 - Director Special Infected Spawner (Anne-style, VScript-only)
// + MaxSpecial Unlock (sourcescramble + gamedata)
// - Control total SI count, respawn interval, and per-class limits via SessionOptions.
// - Read per-count class caps from KeyValues (cfg/sourcemod/dirspawn_si_limits.cfg).
// - "better_mutations4" style fixes via SessionOptions.
// - Optional auto-scaling by human player count.
// - Announce ONCE when the first survivor leaves start area (difficulty + count + interval).
// - Cull: kick dead SI bots (except Spitter) to free slot.
//
// Requirements:
//   - SourceMod 1.11+
//   - Left4DHooks extension
//   - sourcescramble extension (for MaxSpecial unlock)
//   - gamedata/infected_control.txt  (must contain key "CDirector::GetMaxPlayerZombies")
//
// Quickstart (server.cfg):
//   sm_cvar dirspawn_enable 1
//   sm_cvar dirspawn_count 12
//   sm_cvar dirspawn_interval 15
//   sm_cvar dirspawn_apply_on_roundstart 1
//   sm_cvar dirspawn_kv_enable 1
//   sm_cvar dirspawn_kv_path "cfg/sourcemod/dirspawn_si_limits.cfg"
//   sm_cvar dirspawn_unlock_maxspecial 1      <-- 解锁COOP 3特上限需要这个
//   sm_dirspawn_apply
//
// Generate KV (balanced split) for 1..30 (optional):
//   sm_dirspawn_genkv 1 30
//
// Auto scaling (optional example):
//   sm_cvar dirspawn_auto_enable 1
//   sm_cvar dirspawn_auto_base_count 6
//   sm_cvar dirspawn_auto_per_player_add 1
//   sm_cvar dirspawn_auto_base_interval 25
//   sm_cvar dirspawn_auto_per_player_decay 2
//
// © 2025 morzlee

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <sourcescramble>   // MaxSpecial 解锁需要

#define PLUGIN_NAME        "L4D2 Director SI Spawner (VScript-only) + MaxSpecial Unlock"
#define PLUGIN_VERSION     "1.4.0"
#define PLUGIN_AUTHOR      "morzlee"
#define PLUGIN_URL         "https://github.com/fantasylidong/CompetitiveWithAnne"

// ---------------------------- ConVars ----------------------------------
ConVar gCvarEnable;
ConVar gCvarCount;
ConVar gCvarInterval;
ConVar gCvarDomLimit;
ConVar gCvarApplyOnRoundStart;
ConVar gCvarApplyDelay;
ConVar gCvarKvEnable;
ConVar gCvarKvPath;
ConVar gCvarVerbose;
ConVar gCvarActiveChallenge;

ConVar gCvarUnlockMaxSpecial;  // NEW: 解锁 MaxSpecial（COOP 3 特上限）

// better_mutations4 style (VScript)
ConVar gCvarAllowSIWithTank;   // ShouldAllowSpecialsWithTank (0/1)
ConVar gCvarRelaxMin;          // RelaxMinInterval (sec)
ConVar gCvarRelaxMax;          // RelaxMaxInterval (sec)
ConVar gCvarLockTempo;         // LockTempo (0/1)

// Auto scaling
ConVar gCvarAutoEnable;        // 0/1
ConVar gCvarAutoCountMode;     // 0=all humans 1=survivor humans 2=non-spectating humans
ConVar gCvarAutoBaseCount;     // base total at 4 humans
ConVar gCvarAutoPerAdd;        // per extra human +count
ConVar gCvarAutoBaseInterval;  // base interval at 4 humans
ConVar gCvarAutoPerDecay;      // per extra human -seconds
ConVar gCvarAutoMinCount;      // clamp
ConVar gCvarAutoMaxCount;      // clamp
ConVar gCvarAutoMinInterval;   // clamp
ConVar gCvarAutoMaxInterval;   // clamp
ConVar gCvarAutoAnnounce;      // 0/1

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

// Anne-like remainder distribution priority
static const SIClass g_DefaultDistributeOrder[SI_Count] =
{
    SI_Hunter, SI_Charger, SI_Smoker, SI_Jockey, SI_Spitter, SI_Boomer
};

// L4D2 ZombieClass
#define ZC_SMOKER   1
#define ZC_BOOMER   2
#define ZC_HUNTER   3
#define ZC_SPITTER  4
#define ZC_JOCKEY   5
#define ZC_CHARGER  6

// ---------------------------- State ------------------------------------
Handle g_hApplyTimer = null;
Handle g_hAutoTimer  = null;
bool   g_bInternalSet = false;        // suppress change bounce when we set cvars in code
bool   g_bAnnouncedThisRound = false; // announced once when first survivor leaves start area
bool   g_bTriedUnlock = false;        // 避免重复尝试打补丁

// ---------------------------- Plugin Info ------------------------------
public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "Control SI max count & respawn interval with Anne-style per-class caps (VScript-only) + M4-fixes + Auto scaling + MaxSpecial Unlock",
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

// Balanced split (fallback if no KV entry)
stock void ComputeBalancedSplit(int total, int outCaps[SI_Count])
{
    for (int i = 0; i < kSIClassCount; i++)
        outCaps[i] = 0;

    if (total <= 0)
        return;

    int base = total / kSIClassCount;
    int rem  = total % kSIClassCount;

    for (int i = 0; i < kSIClassCount; i++)
        outCaps[i] = base;

    for (int i = 0; i < rem; i++)
    {
        SIClass cls = g_DefaultDistributeOrder[i % kSIClassCount];
        outCaps[cls]++;
    }
}

// Load from KV "cfg/sourcemod/dirspawn_si_limits.cfg"
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

    outCaps[SI_Smoker]  = kv.GetNum("Smoker",  0);
    outCaps[SI_Boomer]  = kv.GetNum("Boomer",  0);
    outCaps[SI_Hunter]  = kv.GetNum("Hunter",  0);
    outCaps[SI_Spitter] = kv.GetNum("Spitter", 0);
    outCaps[SI_Jockey]  = kv.GetNum("Jockey",  0);
    outCaps[SI_Charger] = kv.GetNum("Charger", 0);
    delete kv;
    return true;
}

// better_mutations4 style VS keys
stock void ApplyM4FixesByVScript()
{
    int allow = gCvarAllowSIWithTank.IntValue; // 0/1
    int rmin  = gCvarRelaxMin.IntValue;        // sec
    int rmax  = gCvarRelaxMax.IntValue;        // sec
    int lockt = gCvarLockTempo.IntValue;       // 0/1

    if (rmax < rmin) rmax = rmin; // clamp

    VS_RawSetInt("ShouldAllowSpecialsWithTank", allow);
    VS_RawSetInt("RelaxMinInterval", rmin);
    VS_RawSetInt("RelaxMaxInterval", rmax);
    VS_RawSetInt("LockTempo", lockt);
}

// Main apply (VScript-only)
stock void ApplyByVScript(int total, int interval)
{
    VS_EnsureBaseFlags();

    // max & dominator
    VS_RawSetInt("cm_MaxSpecials", total);

    int dom = gCvarDomLimit.IntValue;
    if (dom < 0) dom = total;
    VS_RawSetInt("DominatorLimit", dom);

    // respawn interval
    VS_RawSetInt("cm_SpecialRespawnInterval", interval);

    // per-class caps
    int caps[SI_Count];
    bool haveKV = (gCvarKvEnable.BoolValue && LoadCapsFromKV(total, caps));
    if (!haveKV)
        ComputeBalancedSplit(total, caps);

    for (int i = 0; i < kSIClassCount; i++)
        VS_RawSetInt(g_SIKeys[i], caps[i]);

    // m4-fixes
    ApplyM4FixesByVScript();

    LogMsg("Applied: total=%d, dom=%d, interval=%d, KV=%s | M4: allow=%d relax=[%d..%d] lock=%d",
           total, dom, interval, haveKV ? "yes":"no",
           gCvarAllowSIWithTank.IntValue, gCvarRelaxMin.IntValue, gCvarRelaxMax.IntValue, gCvarLockTempo.IntValue);
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
        char msg[160];
        Format(msg, sizeof(msg),
            "导演刷特：总数=%d，间隔=%d 秒 | 坦克并存=%d Relax[%d..%d] 锁节奏=%d",
            total, interval,
            gCvarAllowSIWithTank.IntValue, gCvarRelaxMin.IntValue, gCvarRelaxMax.IntValue, gCvarLockTempo.IntValue);
        PrintToChatAll("[DirSpawn] %s", msg);
    }
}

// Cleanup VS keys
stock void ShutdownVScript()
{
    VS_RawDelete("cm_MaxSpecials");
    VS_RawDelete("DominatorLimit");
    VS_RawDelete("cm_SpecialRespawnInterval");
    for (int i = 0; i < kSIClassCount; i++)
        VS_RawDelete(g_SIKeys[i]);

    VS_RawDelete("ShouldAllowSpecialsWithTank");
    VS_RawDelete("RelaxMinInterval");
    VS_RawDelete("RelaxMaxInterval");
    VS_RawDelete("LockTempo");

    if (gCvarActiveChallenge.BoolValue)
    {
        VS_RawDelete("ActiveChallenge");
        VS_RawDelete("cm_AggressiveSpecials");
        VS_RawDelete("SpecialInfectedAssault");
    }
    LogMsg("VScript session options cleared.");
}

// ---------------------------- MaxSpecial Unlock ------------------------
// 仅在需要时打补丁，避免重复尝试
static void InitSDK_FromGamedata()
{
    char sBuffer[128];

    strcopy(sBuffer, sizeof(sBuffer), "infected_control");
    GameData hGameData = new GameData(sBuffer);
    if (hGameData == null)
        SetFailState("Failed to load \"%s.txt\" gamedata.", sBuffer);

    // Unlock Max SI limit - 这是唯一需要保留的 gamedata patch
    strcopy(sBuffer, sizeof(sBuffer), "CDirector::GetMaxPlayerZombies");
    MemoryPatch mPatch = MemoryPatch.CreateFromConf(hGameData, sBuffer);
    if (!mPatch.Validate())
        SetFailState("Failed to verify patch: %s", sBuffer);
    if (!mPatch.Enable())
        SetFailState("Failed to Enable patch: %s", sBuffer);

    delete hGameData;
}

static void MaybeApplyUnlock()
{
    if (g_bTriedUnlock) return;
    g_bTriedUnlock = true;

    if (!gCvarUnlockMaxSpecial.BoolValue)
    {
        PrintToServer("[DirSpawn] MaxSpecial unlock is disabled (dirspawn_unlock_maxspecial=0).");
        return;
    }

    // sourcescramble 必须存在
    InitSDK_FromGamedata();
    PrintToServer("[DirSpawn] MaxSpecial unlock applied (patched CDirector::GetMaxPlayerZombies).");
}

// ---------------------------- Auto scaling -----------------------------
// Count humans by mode
int CountHumansByMode(int mode)
{
    int cnt = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        int team = GetClientTeam(i);
        if (mode == 0) // all humans (exclude team 0)
        {
            if (team != 0) cnt++;
        }
        else if (mode == 1) // survivor humans only
        {
            if (team == 2) cnt++;
        }
        else // 2: non-spectating humans (survivor + infected)
        {
            if (team == 2 || team == 3) cnt++;
        }
    }
    return cnt;
}

void AutoRecomputeAndApply(bool announce)
{
    if (!gCvarAutoEnable.BoolValue) return;

    int mode     = gCvarAutoCountMode.IntValue;
    int humans   = CountHumansByMode(mode);
    int over4    = humans - 4;
    if (over4 < 0) over4 = 0;

    int baseCnt  = gCvarAutoBaseCount.IntValue;
    int perAdd   = gCvarAutoPerAdd.IntValue;
    int baseIntv = gCvarAutoBaseInterval.IntValue;
    int perDec   = gCvarAutoPerDecay.IntValue;

    int minCnt   = gCvarAutoMinCount.IntValue;
    int maxCnt   = gCvarAutoMaxCount.IntValue;
    int minIntv  = gCvarAutoMinInterval.IntValue;
    int maxIntv  = gCvarAutoMaxInterval.IntValue;

    int newCnt   = baseCnt + perAdd * over4;
    int newIntv  = baseIntv - perDec * over4;

    if (newCnt   < minCnt)   newCnt   = minCnt;
    if (newCnt   > maxCnt)   newCnt   = maxCnt;
    if (newIntv  < minIntv)  newIntv  = minIntv;
    if (newIntv  > maxIntv)  newIntv  = maxIntv;

    g_bInternalSet = true;
    gCvarCount.SetInt(newCnt);
    gCvarInterval.SetInt(newIntv);
    g_bInternalSet = false;

    ApplyDirectorSettings(announce && gCvarAutoAnnounce.BoolValue);
    LogMsg("AutoScale: humans=%d mode=%d -> count=%d interval=%d",
           humans, mode, newCnt, newIntv);
}

public Action TMR_AutoOnce(Handle timer, any data)
{
    g_hAutoTimer = null;
    AutoRecomputeAndApply(true);
    return Plugin_Stop;
}

void ScheduleAuto(float delay=0.25)
{
    if (!gCvarAutoEnable.BoolValue) return;
    if (g_hAutoTimer != null)
    {
        KillTimer(g_hAutoTimer);
        g_hAutoTimer = null;
    }
    g_hAutoTimer = CreateTimer(delay, TMR_AutoOnce, _, TIMER_FLAG_NO_MAPCHANGE);
}

// ---------------------------- Commands ---------------------------------
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
    g_bAnnouncedThisRound = false; // reset announce flag per round

    if (gCvarAutoEnable.BoolValue) ScheduleAuto(0.6);

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
    // 这里也试一次，以防 sourcescramble 晚于本插件加载
    MaybeApplyUnlock();

    if (gCvarAutoEnable.BoolValue) ScheduleAuto(1.0);

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

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;
    ScheduleAuto(0.5);
}
public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;
    ScheduleAuto(0.5);
}
public Action EVT_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    ScheduleAuto(0.5);
    return Plugin_Continue;
}
public void OnAllPluginsLoaded()
{
    HookEvent("player_team", EVT_PlayerTeam, EventHookMode_Post);

    // 插件与扩展均加载后，优先尝试解锁
    MaybeApplyUnlock();
}

// ---------- Announce ONCE when first survivor leaves start area ----------
void GetDifficultyString(char[] out, int maxlen)
{
    char diff[32]; diff[0] = '\0';
    ConVar c = FindConVar("z_difficulty");
    if (c != null) c.GetString(diff, sizeof(diff));

    if (StrEqual(diff, "easy", false))        strcopy(out, maxlen, "简单");
    else if (StrEqual(diff, "normal", false)) strcopy(out, maxlen, "普通");
    else if (StrEqual(diff, "hard", false))   strcopy(out, maxlen, "高级");
    else if (StrEqual(diff, "impossible", false) || StrEqual(diff, "expert", false))
        strcopy(out, maxlen, "专家");
    else if (diff[0] != '\0')
        strcopy(out, maxlen, diff);
    else
        strcopy(out, maxlen, "未知");
}

void AnnounceNow()
{
    char diffcn[32];
    GetDifficultyString(diffcn, sizeof(diffcn));

    int total    = gCvarCount.IntValue;
    int interval = gCvarInterval.IntValue;

    PrintToChatAll("[导演] 难度：%s ｜ %d特 ｜ 目标间隔：%d秒", diffcn, total, interval);
}

public Action EVT_PlayerLeftStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bAnnouncedThisRound)
    {
        AnnounceNow();
        g_bAnnouncedThisRound = true;
    }
    return Plugin_Continue;
}

// ---------- Cull: kick dead SI bots except Spitter ----------
public Action TMR_KickDeadSIBot(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Stop;

    if (GetClientTeam(client) != 3) return Plugin_Stop;  // only infected team
    if (!IsFakeClient(client)) return Plugin_Stop;       // only bots

    int zc = L4D2_GetPlayerZombieClass(client);
    if (zc == ZC_SPITTER) return Plugin_Stop;            // exclude spitter

    KickClient(client, "free SI slot");
    return Plugin_Stop;
}

public Action EVT_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    CreateTimer(0.05, TMR_KickDeadSIBot, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

// ---------------------------- ConVar Changed ---------------------------
public void CvarChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    if (!gCvarEnable.BoolValue) return;
    if (g_bInternalSet) return;

    if (cvar == gCvarCount || cvar == gCvarInterval || cvar == gCvarDomLimit
     || cvar == gCvarKvEnable || cvar == gCvarKvPath
     || cvar == gCvarAllowSIWithTank || cvar == gCvarRelaxMin || cvar == gCvarRelaxMax || cvar == gCvarLockTempo)
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
    gCvarCount             = CreateConVar("dirspawn_count", "8", "Total concurrent SI (cm_MaxSpecials)", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarInterval          = CreateConVar("dirspawn_interval", "35", "cm_SpecialRespawnInterval (seconds)", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarDomLimit          = CreateConVar("dirspawn_dominator_limit", "-1", "DominatorLimit (-1=auto=dirspawn_count)", FCVAR_NOTIFY, true, -1.0, true, 30.0);
    gCvarApplyOnRoundStart = CreateConVar("dirspawn_apply_on_roundstart", "1", "Apply automatically at round_start", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarApplyDelay        = CreateConVar("dirspawn_apply_delay", "1.0", "Delay (sec) before apply at round_start/OnConfigsExecuted", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    gCvarKvEnable          = CreateConVar("dirspawn_kv_enable", "1", "Use KV file to set per-class caps (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarKvPath            = CreateConVar("dirspawn_kv_path", "cfg/sourcemod/dirspawn_si_limits.cfg", "KeyValues file path for per-class caps", FCVAR_NOTIFY);
    gCvarVerbose           = CreateConVar("dirspawn_verbose", "1", "Verbose logs (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarActiveChallenge   = CreateConVar("dirspawn_active_challenge", "1", "Set ActiveChallenge/Aggressive/Assault flags (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // NEW: 解锁 MaxSpecial
    gCvarUnlockMaxSpecial  = CreateConVar("dirspawn_unlock_maxspecial", "1", "Unlock max SI cap by patching CDirector::GetMaxPlayerZombies (requires sourcescramble + gamedata)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // better_mutations4 fixes via SessionOptions
    gCvarAllowSIWithTank   = CreateConVar("dirspawn_allow_si_with_tank", "1", "ShouldAllowSpecialsWithTank (0=disallow SI when Tank alive)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarRelaxMin          = CreateConVar("dirspawn_relax_min", "15",  "RelaxMinInterval (seconds)", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarRelaxMax          = CreateConVar("dirspawn_relax_max", "60",  "RelaxMaxInterval (seconds)", FCVAR_NOTIFY, true, 0.0, true, 180.0);
    gCvarLockTempo         = CreateConVar("dirspawn_lock_tempo", "0",  "LockTempo (0=unlocked)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // Auto scaling
    gCvarAutoEnable        = CreateConVar("dirspawn_auto_enable", "0", "Enable auto scaling by human players (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarAutoCountMode     = CreateConVar("dirspawn_auto_count_mode", "0", "Count: 0=all humans, 1=survivor humans, 2=non-spectating humans", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    gCvarAutoBaseCount     = CreateConVar("dirspawn_auto_base_count", "6",  "Base SI total at 4 humans", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoPerAdd        = CreateConVar("dirspawn_auto_per_player_add", "1", "Per extra human (+count)", FCVAR_NOTIFY, true, 0.0, true, 6.0);
    gCvarAutoBaseInterval  = CreateConVar("dirspawn_auto_base_interval", "25", "Base interval at 4 humans (seconds)", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarAutoPerDecay      = CreateConVar("dirspawn_auto_per_player_decay", "2", "Per extra human (-seconds)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    gCvarAutoMinCount      = CreateConVar("dirspawn_auto_min_count", "1",  "Min SI total clamp", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoMaxCount      = CreateConVar("dirspawn_auto_max_count", "30", "Max SI total clamp", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoMinInterval   = CreateConVar("dirspawn_auto_min_interval", "5",  "Min interval clamp (sec)", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarAutoMaxInterval   = CreateConVar("dirspawn_auto_max_interval", "60", "Max interval clamp (sec)", FCVAR_NOTIFY, true, 0.0, true, 300.0);
    gCvarAutoAnnounce      = CreateConVar("dirspawn_auto_announce", "1", "Announce autoscaled values to chat (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookConVarChange(gCvarCount,             CvarChanged);
    HookConVarChange(gCvarInterval,          CvarChanged);
    HookConVarChange(gCvarDomLimit,          CvarChanged);
    HookConVarChange(gCvarKvEnable,          CvarChanged);
    HookConVarChange(gCvarKvPath,            CvarChanged);
    HookConVarChange(gCvarAllowSIWithTank,   CvarChanged);
    HookConVarChange(gCvarRelaxMin,          CvarChanged);
    HookConVarChange(gCvarRelaxMax,          CvarChanged);
    HookConVarChange(gCvarLockTempo,         CvarChanged);

    RegAdminCmd("sm_dirspawn_apply",  Cmd_Apply, ADMFLAG_GENERIC, "sm_dirspawn_apply [count] [interval] - apply settings now");
    RegAdminCmd("sm_dirspawn_genkv",  Cmd_GenKV, ADMFLAG_ROOT,    "sm_dirspawn_genkv [min] [max] - generate KV (balanced) to dirspawn_kv_path");

    HookEvent("round_start",             EVT_RoundStart,       EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area",  EVT_PlayerLeftStart,  EventHookMode_PostNoCopy);
    HookEvent("player_death",            EVT_PlayerDeath,      EventHookMode_Post);

    LogMsg("%s v%s loaded.", PLUGIN_NAME, PLUGIN_VERSION);
}

public void OnPluginEnd()
{
    ShutdownVScript();
}
