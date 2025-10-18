// l4d2_dirspawn.sp
//
// Left 4 Dead 2 - Director Special Infected Spawner (Anne-style, VScript-only)
// + MaxSpecial Unlock (sourcescramble + gamedata)
// + Auto-tune: Relax / LockTempo / InitialSpawnDelay follow dirspawn_interval
//
// - 控制总特数量、刷新间隔、每类上限（KV）
// - “better_mutations4”风格修复（VScript SessionOptions）
// - 可选按真人数量自动伸缩
// - 开局离开安全区时公告一次
// - 清理死亡特感（除Spitter）
//
// 需求：
//   - SourceMod 1.11+
//   - Left4DHooks 扩展
//   - （可选）sourcescramble 扩展（解锁 COOP 3 特上限）
//   - gamedata/infected_control.txt（包含 "CDirector::GetMaxPlayerZombies"）
//
// Quickstart (server.cfg):
//   sm_cvar dirspawn_enable 1
//   sm_cvar dirspawn_count 12
//   sm_cvar dirspawn_interval 15
//   sm_cvar dirspawn_apply_on_roundstart 1
//   sm_cvar dirspawn_kv_enable 1
//   sm_cvar dirspawn_kv_path "cfg/sourcemod/dirspawn_si_limits.cfg"
//   sm_cvar dirspawn_unlock_maxspecial 1
//   sm_dirspawn_apply
//
// © 2025 morzlee

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <colors>

// 尝试包含 sourcescramble（未安装也可编译，但无法打补丁）
#tryinclude <sourcescramble>

#define PLUGIN_NAME        "L4D2 Director SI Spawner (VScript-only) + MaxSpecial Unlock"
#define PLUGIN_VERSION     "1.5.1"
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

ConVar gCvarUnlockMaxSpecial;  // 解锁 MaxSpecial（COOP 3 特上限）

// better_mutations4 (VScript)
ConVar gCvarAllowSIWithTank;   // ShouldAllowSpecialsWithTank (0/1)
ConVar gCvarRelaxMin;          // RelaxMinInterval (sec)
ConVar gCvarRelaxMax;          // RelaxMaxInterval (sec)
ConVar gCvarLockTempo;         // LockTempo (0/1)

// 首刷延迟
ConVar gCvarInitialMin;        // SpecialInitialSpawnDelayMin
ConVar gCvarInitialMax;        // SpecialInitialSpawnDelayMax

// 自动伸缩
ConVar gCvarAutoEnable;
ConVar gCvarAutoCountMode;     // 0=all 1=survivor 2=non-spectating
ConVar gCvarAutoBaseCount;
ConVar gCvarAutoPerAdd;
ConVar gCvarAutoBaseInterval;
ConVar gCvarAutoPerDecay;
ConVar gCvarAutoMinCount;
ConVar gCvarAutoMaxCount;
ConVar gCvarAutoMinInterval;
ConVar gCvarAutoMaxInterval;
ConVar gCvarAutoAnnounce;

// interval 联动（Relax/LockTempo/Initial）
ConVar gCvarRelaxAuto;              // 1=根据 interval 自动调 Relax/Lock
ConVar gCvarRelaxKMin;              // rmin = kmin * interval
ConVar gCvarRelaxKMax;              // rmax = kmax * interval
ConVar gCvarRelaxFloor;             // rmin 下限（秒）
ConVar gCvarRelaxCeil;              // rmax 上限（秒）
ConVar gCvarTempoLockThreshold;     // interval <= 阈值时 LockTempo=1

ConVar gCvarInitAuto;               // 1=根据 interval 自动调首刷延迟
ConVar gCvarInitKMin;               // imin = ikmin * interval
ConVar gCvarInitKMax;               // imax = ikmax * interval

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
Handle g_hApplyLateTimer = null; // round_start 2秒后的兜底重写
bool   g_bInternalSet = false;        // 我们自己改 cvar 时防抖
bool   g_bAnnouncedThisRound = false; // 本回合是否已公告
bool   g_bTriedUnlock = false;        // 避免多次尝试补丁

#if defined _sourcescramble_included
MemoryPatch g_MPMaxZombies;           // 保持引用有效
#endif

// ---------------------------- Plugin Info ------------------------------
public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = "控制特感总数/间隔/每类上限（KV） + M4修复 + 人数自动伸缩 + MaxSpecial 解锁 + 间隔联动节奏",
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

// 均衡分配（无 KV 时回退）
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

// 从 KV 载入每类上限
stock bool LoadCapsFromKV(int total, int outCaps[SI_Count])
{
    char path[PLATFORM_MAX_PATH];
    gCvarKvPath.GetString(path, sizeof(path));

    KeyValues kv = new KeyValues("DirSpawnLimits");
    if (!kv.ImportFromFile(path))
    {
        LogMsg("KV 文件未找到: %s", path);
        delete kv;
        return false;
    }

    char key[16];
    IntToString(total, key, sizeof(key));

    if (!kv.JumpToKey(key, false))
    {
        LogMsg("KV: 未找到总数 %d 的条目", total);
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

// better_mutations4 风格键
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

// 首刷延迟
stock void ApplyInitialSpawnDelayByVScript()
{
    int imin = 0, imax = 0;
    if (gCvarInitialMin != null) imin = gCvarInitialMin.IntValue;
    if (gCvarInitialMax != null) imax = gCvarInitialMax.IntValue;
    if (imax < imin) imax = imin;
    VS_RawSetInt("SpecialInitialSpawnDelayMin", imin);
    VS_RawSetInt("SpecialInitialSpawnDelayMax", imax);
}

// 从 dirspawn_interval 自动推导 Relax/Lock/Initial
stock void AutoTuneTempoFromInterval(int interval)
{
    if (!gCvarRelaxAuto.BoolValue && !gCvarInitAuto.BoolValue)
        return;

    if (interval < 0) interval = 0;

    // ---- Relax + LockTempo ----
    if (gCvarRelaxAuto.BoolValue)
    {
        float kmin = gCvarRelaxKMin.FloatValue;   // 例如 0.25
        float kmax = gCvarRelaxKMax.FloatValue;   // 例如 0.90
        int   lo   = gCvarRelaxFloor.IntValue;    // 例如 0
        int   hi   = gCvarRelaxCeil.IntValue;     // 例如 120

        int rmin, rmax, lockt;

        if (interval == 0)
        {
            rmin = 0; rmax = 0; lockt = 1;
        }
        else
        {
            rmin  = RoundToFloor(kmin * float(interval));
            rmax  = RoundToCeil (kmax * float(interval));
            if (rmin < lo) rmin = lo;
            if (rmax < rmin) rmax = rmin;
            if (rmax > hi) rmax = hi;

            lockt = (interval <= gCvarTempoLockThreshold.IntValue) ? 1 : 0;
        }

        g_bInternalSet = true;
        gCvarRelaxMin.SetInt(rmin);
        gCvarRelaxMax.SetInt(rmax);
        gCvarLockTempo.SetInt(lockt);
        g_bInternalSet = false;
    }

    // ---- 首刷延迟 ----
    if (gCvarInitAuto.BoolValue && gCvarInitialMin != null && gCvarInitialMax != null)
    {
        float ikmin = gCvarInitKMin.FloatValue;   // 例如 0.0
        float ikmax = gCvarInitKMax.FloatValue;   // 例如 0.5

        int imin, imax;
        if (interval == 0)
        {
            imin = 0; imax = 0;
        }
        else
        {
            imin = RoundToFloor(ikmin * float(interval));
            imax = RoundToCeil (ikmax * float(interval));
            if (imax < imin) imax = imin;
            if (imin < 0) imin = 0;
            if (imax > 60) imax = 60;
        }

        g_bInternalSet = true;
        gCvarInitialMin.SetInt(imin);
        gCvarInitialMax.SetInt(imax);
        g_bInternalSet = false;
    }
}

// 主应用（仅 VScript）
stock void ApplyByVScript(int total, int interval)
{
    VS_EnsureBaseFlags();

    // 总上限与 Dominator
    VS_RawSetInt("cm_MaxSpecials", total);

    int dom = gCvarDomLimit.IntValue;
    if (dom < 0) dom = total;
    VS_RawSetInt("DominatorLimit", dom);

    // 刷新间隔
    VS_RawSetInt("cm_SpecialRespawnInterval", interval);

    // 每类上限
    int caps[SI_Count];
    bool haveKV = (gCvarKvEnable.BoolValue && LoadCapsFromKV(total, caps));
    if (!haveKV)
        ComputeBalancedSplit(total, caps);

    for (int i = 0; i < kSIClassCount; i++)
        VS_RawSetInt(g_SIKeys[i], caps[i]);

    // M4 修复 + 首刷
    ApplyM4FixesByVScript();
    ApplyInitialSpawnDelayByVScript();

    LogMsg("Applied: total=%d, dom=%d, interval=%d, KV=%s | M4: allow=%d relax=[%d..%d] lock=%d | init=[%d..%d]",
           total, dom, interval, haveKV ? "yes":"no",
           gCvarAllowSIWithTank.IntValue, gCvarRelaxMin.IntValue, gCvarRelaxMax.IntValue, gCvarLockTempo.IntValue,
           gCvarInitialMin.IntValue, gCvarInitialMax.IntValue);
}

stock bool ShouldAnnounceApply(int total, int interval)
{
    static int s_lastTotal = -999;
    static int s_lastIntv  = -999;
    static float s_lastTime = 0.0;

    float now = GetGameTime();

    // 如果【总数】和【间隔】都没变，就不再播报
    if (total == s_lastTotal && interval == s_lastIntv)
        return false;

    // 记录最新一次播报
    s_lastTotal = total;
    s_lastIntv  = interval;
    s_lastTime  = now;
    return true;
}

stock void ApplyDirectorSettings(bool announceToChat=false)
{
    if (!gCvarEnable.BoolValue)
    {
        LogMsg("dirspawn_enable=0: 跳过应用。");
        return;
    }

    int total    = gCvarCount.IntValue;
    int interval = gCvarInterval.IntValue;
    if (total < 0)    total = 0;
    if (interval < 0) interval = 0;

    ApplyByVScript(total, interval);

    if (announceToChat && ShouldAnnounceApply(total, interval))
    {
        CPrintToChatAll(
            "{default}[{green}DirSpawn{default}]  \
            {green}导演刷特{default}：  \
            {green}总数{default}={teamcolor}%d{default} ｜  \
            {green}间隔{default}={teamcolor}%d{default}秒 ｜  \
            {green}坦克并存{default}={teamcolor}%d{default} ｜  \
            {green}Relax{default}[{teamcolor}%d{default}..{teamcolor}%d{default}] ｜  \
            {green}锁节奏{default}={teamcolor}%d{default} ｜  \
            {green}首刷{default}[{teamcolor}%d{default}..{teamcolor}%d{default}]",
            total, interval,
            gCvarAllowSIWithTank.IntValue,
            gCvarRelaxMin.IntValue, gCvarRelaxMax.IntValue,
            gCvarLockTempo.IntValue,
            gCvarInitialMin.IntValue, gCvarInitialMax.IntValue
        );
    }
}

// 清理 SessionOptions
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

    VS_RawDelete("SpecialInitialSpawnDelayMin");
    VS_RawDelete("SpecialInitialSpawnDelayMax");

    if (gCvarActiveChallenge.BoolValue)
    {
        VS_RawDelete("ActiveChallenge");
        VS_RawDelete("cm_AggressiveSpecials");
        VS_RawDelete("SpecialInfectedAssault");
    }
    LogMsg("VScript 会话参数已清理。");
}

// ---------------------------- MaxSpecial Unlock ------------------------
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
        PrintToServer("[DirSpawn] MaxSpecial 解锁已关闭（dirspawn_unlock_maxspecial=0）。");
        return;
    }

    InitSDK_FromGamedata();
    PrintToServer("[DirSpawn] 已应用 MaxSpecial 解锁（已补丁 CDirector::GetMaxPlayerZombies）。");
}

// ---------------------------- Auto scaling -----------------------------
// 统计真人
int CountHumansByMode(int mode)
{
    int cnt = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        int team = GetClientTeam(i);
        if (mode == 0) { if (team != 0) cnt++; }       // 全部真人（排除观察）
        else if (mode == 1) { if (team == 2) cnt++; }  // 仅生还
        else { if (team == 2 || team == 3) cnt++; }    // 生还 + 感染
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

    // 联动：根据新间隔自动调节 Relax/Lock/Initial
    AutoTuneTempoFromInterval(newIntv);

    ApplyDirectorSettings(announce && gCvarAutoAnnounce.BoolValue);
    LogMsg("AutoScale: humans=%d mode=%d -> count=%d interval=%d",
           humans, mode, newCnt, newIntv);
}

public Action TMR_ApplyLate(Handle timer, any data)
{
    g_hApplyLateTimer = null;
    ApplyDirectorSettings(false); // 不刷屏
    return Plugin_Stop;
}

public Action TMR_AutoOnce(Handle timer, any data)
{
    g_hAutoTimer = null;
    AutoRecomputeAndApply(true);
    return Plugin_Stop;
}

void ScheduleAuto(float delay=0.25)
{
    // 防止在极早期/极晚期阶段 ConVar 尚未就绪
    if (gCvarAutoEnable == null || !gCvarAutoEnable.BoolValue) return;

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
        AutoTuneTempoFromInterval(interval); // 手动指定间隔时立即联动
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
            PrintToServer("[DirSpawn] KV JumpToKey 失败: %d", total);
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
        PrintToServer("[DirSpawn] 已生成 KV: %s (范围 %d..%d)", path, min, max);
        if (client > 0) PrintToChat(client, "[DirSpawn] KV 已生成: %s", path);
    }
    else
    {
        PrintToServer("[DirSpawn] 写入 KV 失败: %s", path);
        if (client > 0) PrintToChat(client, "[DirSpawn] 写入 KV 失败: %s", path);
    }
    return Plugin_Handled;
}

// ---------------------------- Events / Timers --------------------------
public Action EVT_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bAnnouncedThisRound = false;

    if (gCvarAutoEnable != null && gCvarAutoEnable.BoolValue)
        ScheduleAuto(0.6);

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
    LogMsg("已计划在 %.1f 秒后应用（round_start）。", delay);
    // 第二枪：固定在 round_start 后 2.0 秒再覆盖一次，防导演/其他脚本迟到改写
    if (g_hApplyLateTimer != null)
    {
        KillTimer(g_hApplyLateTimer);
        g_hApplyLateTimer = null;
    }
    g_hApplyLateTimer = CreateTimer(2.0, TMR_ApplyLate, _, TIMER_FLAG_NO_MAPCHANGE);
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
    // 防止扩展晚于插件加载
    MaybeApplyUnlock();

    if (gCvarAutoEnable != null && gCvarAutoEnable.BoolValue)
        ScheduleAuto(1.0);

    if (gCvarEnable != null && gCvarEnable.BoolValue && gCvarApplyOnRoundStart.BoolValue)
    {
        float delay = gCvarApplyDelay.FloatValue + 0.5;
        if (g_hApplyTimer != null)
        {
            KillTimer(g_hApplyTimer);
            g_hApplyTimer = null;
        }
        g_hApplyTimer = CreateTimer(delay, TMR_ApplyOnce, _, TIMER_FLAG_NO_MAPCHANGE);
        LogMsg("已计划在 %.1f 秒后应用（OnConfigsExecuted）。", delay);
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
    MaybeApplyUnlock();
}

// ---------- 开局离开安全区时公告一次 ----------
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

    CPrintToChatAll(
        "{default}[{green}导演{default}] \
        {green}难度：{teamcolor}%s{default} ｜  \
        {teamcolor}%d{green}特{default} ｜  \
        {green}目标间隔：{teamcolor}%d{default}秒",
        diffcn, total, interval
    );
}

public Action EVT_PlayerLeftStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bAnnouncedThisRound)
    {
        // 兜底：开跑瞬间再覆盖一次，保证设置不被迟到逻辑改没了
        ApplyDirectorSettings(false);

        // 你的难度公告（已颜色化的那句留用即可）
        AnnounceNow();
        g_bAnnouncedThisRound = true;
    }
    return Plugin_Continue;
}

// ---------- 清理：踢掉死亡的 SI bot（Spitter 例外） ----------
public Action TMR_KickDeadSIBot(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Stop;

    if (GetClientTeam(client) != 3) return Plugin_Stop;  // 仅感染者
    if (!IsFakeClient(client)) return Plugin_Stop;       // 仅 bot

    int zc = L4D2_GetPlayerZombieClass(client);
    if (zc == ZC_SPITTER) return Plugin_Stop;            // Spitter 例外

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

    // 间隔改变时先联动
    if (cvar == gCvarInterval)
    {
        AutoTuneTempoFromInterval(gCvarInterval.IntValue);
    }

    if (cvar == gCvarCount || cvar == gCvarInterval || cvar == gCvarDomLimit
     || cvar == gCvarKvEnable || cvar == gCvarKvPath
     || cvar == gCvarAllowSIWithTank || cvar == gCvarRelaxMin || cvar == gCvarRelaxMax || cvar == gCvarLockTempo
     || cvar == gCvarInitialMin || cvar == gCvarInitialMax)
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
    gCvarEnable            = CreateConVar("dirspawn_enable", "1", "启用导演特感生成（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarCount             = CreateConVar("dirspawn_count", "4", "并发特感总数（cm_MaxSpecials）", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarInterval          = CreateConVar("dirspawn_interval", "35", "特感刷新目标间隔（秒）（cm_SpecialRespawnInterval）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarDomLimit          = CreateConVar("dirspawn_dominator_limit", "-1", "压制者上限（-1=自动=跟随 dirspawn_count）", FCVAR_NOTIFY, true, -1.0, true, 30.0);
    gCvarApplyOnRoundStart = CreateConVar("dirspawn_apply_on_roundstart", "1", "回合开始自动应用（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarApplyDelay        = CreateConVar("dirspawn_apply_delay", "1.0", "回合开始/配置执行后延迟应用时间（秒）", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    gCvarKvEnable          = CreateConVar("dirspawn_kv_enable", "1", "启用 KV 文件设置每类特感上限（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarKvPath            = CreateConVar("dirspawn_kv_path", "cfg/sourcemod/dirspawn_si_limits.cfg", "每类特感上限的 KeyValues 文件路径", FCVAR_NOTIFY);
    gCvarVerbose           = CreateConVar("dirspawn_verbose", "1", "输出详细日志（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarActiveChallenge   = CreateConVar("dirspawn_active_challenge", "1", "设置 ActiveChallenge/Aggressive/Assault 标志（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // MaxSpecial 解锁开关
    gCvarUnlockMaxSpecial  = CreateConVar("dirspawn_unlock_maxspecial", "1", "解锁 MaxSpecial（需要 sourcescramble + gamedata）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // better_mutations4
    gCvarAllowSIWithTank   = CreateConVar("dirspawn_allow_si_with_tank", "1", "坦克存活时仍允许刷特（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarRelaxMin          = CreateConVar("dirspawn_relax_min", "15",  "Relax 最小间隔（秒）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarRelaxMax          = CreateConVar("dirspawn_relax_max", "35",  "Relax 最大间隔（秒）", FCVAR_NOTIFY, true, 0.0, true, 180.0);
    gCvarLockTempo         = CreateConVar("dirspawn_lock_tempo", "0",  "锁节奏（0=关闭，1=开启）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // 首刷延迟
    gCvarInitialMin        = CreateConVar("dirspawn_initial_min", "0", "首刷延迟下限（秒）", FCVAR_NOTIFY, true, 0.0, true, 60.0);
    gCvarInitialMax        = CreateConVar("dirspawn_initial_max", "0", "首刷延迟上限（秒）", FCVAR_NOTIFY, true, 0.0, true, 60.0);

    // interval 联动
    gCvarRelaxAuto          = CreateConVar("dirspawn_relax_auto", "1", "根据 dirspawn_interval 自动计算 Relax/Lock（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarRelaxKMin          = CreateConVar("dirspawn_relax_kmin", "0.25", "RelaxMin = kmin × interval", FCVAR_NOTIFY);
    gCvarRelaxKMax          = CreateConVar("dirspawn_relax_kmax", "0.90", "RelaxMax = kmax × interval", FCVAR_NOTIFY);
    gCvarRelaxFloor         = CreateConVar("dirspawn_relax_floor", "0", "RelaxMin 下限（秒）", FCVAR_NOTIFY);
    gCvarRelaxCeil          = CreateConVar("dirspawn_relax_ceil", "120", "RelaxMax 上限（秒）", FCVAR_NOTIFY);
    gCvarTempoLockThreshold = CreateConVar("dirspawn_lock_tempo_threshold", "6", "当 interval ≤ 阈值时自动开启锁节奏（秒）", FCVAR_NOTIFY);

    gCvarInitAuto           = CreateConVar("dirspawn_initial_auto", "1", "根据 dirspawn_interval 自动计算首刷延迟（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarInitKMin           = CreateConVar("dirspawn_initial_kmin", "0.00", "InitialDelayMin = ikmin × interval", FCVAR_NOTIFY);
    gCvarInitKMax           = CreateConVar("dirspawn_initial_kmax", "0.50", "InitialDelayMax = ikmax × interval", FCVAR_NOTIFY);

    // ---------------- 自动伸缩（按真人数量） ----------------
    gCvarAutoEnable        = CreateConVar("dirspawn_auto_enable", "0", "按真人数量自动伸缩（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    gCvarAutoCountMode     = CreateConVar("dirspawn_auto_count_mode", "0", "统计模式：0=全部真人（含感染、排除观察），1=仅生还，2=生还+感染", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    gCvarAutoBaseCount     = CreateConVar("dirspawn_auto_base_count", "6",  "基线总特数（以4名真人为基准）", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoPerAdd        = CreateConVar("dirspawn_auto_per_player_add", "1", "每多1名真人，额外 +特数", FCVAR_NOTIFY, true, 0.0, true, 6.0);
    gCvarAutoBaseInterval  = CreateConVar("dirspawn_auto_base_interval", "25", "基线刷新间隔（秒，4名真人时）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarAutoPerDecay      = CreateConVar("dirspawn_auto_per_player_decay", "2", "每多1名真人，间隔 -秒数", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    gCvarAutoMinCount      = CreateConVar("dirspawn_auto_min_count", "1",  "总特下限", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoMaxCount      = CreateConVar("dirspawn_auto_max_count", "30", "总特上限", FCVAR_NOTIFY, true, 0.0, true, 30.0);
    gCvarAutoMinInterval   = CreateConVar("dirspawn_auto_min_interval", "5",  "刷新间隔下限（秒）", FCVAR_NOTIFY, true, 0.0, true, 120.0);
    gCvarAutoMaxInterval   = CreateConVar("dirspawn_auto_max_interval", "60", "刷新间隔上限（秒）", FCVAR_NOTIFY, true, 0.0, true, 300.0);
    gCvarAutoAnnounce      = CreateConVar("dirspawn_auto_announce", "0", "自动伸缩时在聊天栏提示（0/1）", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // 钩子与命令
    HookConVarChange(gCvarCount,             CvarChanged);
    HookConVarChange(gCvarInterval,          CvarChanged);
    HookConVarChange(gCvarDomLimit,          CvarChanged);
    HookConVarChange(gCvarKvEnable,          CvarChanged);
    HookConVarChange(gCvarKvPath,            CvarChanged);
    HookConVarChange(gCvarAllowSIWithTank,   CvarChanged);
    HookConVarChange(gCvarRelaxMin,          CvarChanged);
    HookConVarChange(gCvarRelaxMax,          CvarChanged);
    HookConVarChange(gCvarLockTempo,         CvarChanged);
    HookConVarChange(gCvarInitialMin,        CvarChanged);
    HookConVarChange(gCvarInitialMax,        CvarChanged);

    RegAdminCmd("sm_dirspawn_apply",  Cmd_Apply, ADMFLAG_GENERIC, "sm_dirspawn_apply [总特] [间隔] —— 立即按传入参数应用一次");
    RegAdminCmd("sm_dirspawn_genkv",  Cmd_GenKV, ADMFLAG_ROOT,    "sm_dirspawn_genkv [最小] [最大] —— 生成每类上限 KV 到 dirspawn_kv_path");

    HookEvent("round_start",             EVT_RoundStart,       EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area",  EVT_PlayerLeftStart,  EventHookMode_PostNoCopy);
    HookEvent("player_death",            EVT_PlayerDeath,      EventHookMode_Post);

    LogMsg("%s v%s 已加载。", PLUGIN_NAME, PLUGIN_VERSION);
}

public void OnPluginEnd()
{
    ShutdownVScript();
}
