#pragma semicolon 1
#pragma newdecls required

/**
 * Infected Control (Flow-Buckets + Bounded Sampling + Director Fallback)
 *  - 主找点：按 NavArea 的 Flow 分桶，只在“目标 flow 窗 + 距离窗”里随机抽样（可控扫描上限）
 *  - 过滤：不可见、不卡壳、无救援柜/车旗、终局区域限制等
 *  - 扩圈：从 SpawnMin 向上扩，至 SpawnMax 后启用导演兜底（GetRandomPZSpawnPosition）
 *  - 保留：传送监督、跑男检测、上限/间隔、全牛/全猎、SI 掩码、Smoker 能力、pause 联动
 *  - 日志：记录失败原因计数，便于定位“刷不出来”的瓶颈
 *
 * 依赖：SourceMod 1.10+ / Left4DHooks
 */

#include <sourcemod>
#include <sdktools>
#include <sdktools_tempents>
#include <left4dhooks>

// 可选插件头（若缺失也可编过，功能自动降级）
#undef REQUIRE_PLUGIN
#include <si_target_limit>
#include <pause>
#include <ai_smoker_new>

// ============ 常量/宏 ============
#define TEAM_SURVIVOR   2
#define TEAM_INFECTED   3

// Hull 尺寸（玩家）
static const float HULL_MIN[3] = { -16.0, -16.0,  0.0 };
static const float HULL_MAX[3] = {  16.0,  16.0, 71.0 };

// Runner（跑男）半径
#define RUNNER_NEAR_RADIUS    1200.0

// ——— 可见性检测：传给 L4D2_IsVisibleToPlayer 的 team 值（和官方保持一致）
#define VIS_TEAM_CLIENT       2
#define VIS_TEAM_TARGET       3

// NavArea 旗子（只用到几个）
#define TERROR_NAV_FINALE         (1 << 6)
#define TERROR_NAV_RESCUE_VEHICLE (1 << 15)
#define TERROR_NAV_RESCUE_CLOSET  (1 << 16)

// ============ 配置 CVars ============
ConVar g_cvSpawnMin, g_cvSpawnMax;
ConVar g_cvTeleportEnable, g_cvTeleportCheckTime, g_cvIgnoreIncapSight;
ConVar g_cvEnableMask, g_cvAllCharger, g_cvAllHunter;
ConVar g_cvAutoSpawn, g_cvAddDmgSmoker;
ConVar g_cvSiLimit, g_cvSiInterval, g_cvDebugMode;

// 找点相关（本方案特有）
ConVar g_cvBucketFlowSize;         // Flow 分桶粒度（越小越精细）
ConVar g_cvMaxScanPerCall;         // 每次找点最多检查多少候选（控制 CPU）
ConVar g_cvMaxNeighborsPerRing;    // 单次扩圈最多尝试多少个桶（防止桶太多时爆量）

// 只读/派生值
float g_fSpawnMin, g_fSpawnMax;
bool  g_bTeleport, g_bIgnoreIncapSight, g_bAutoSpawn, g_bAddDmgSmoker;
int   g_iSiLimit;
float g_fSiInterval;
int   g_iDebugMode;

// 可选库检测
bool g_bLibPause = false;
bool g_bLibSmoker = false;
bool g_bLibTargetLimit = false;
// ============ Tick：每秒一次（传送监督/波节奏） ============
float g_flSpit[MAXPLAYERS+1]; // 记录 spitter 上次吐痰时间，防止吐后立刻传送

// ============ 日志 ============
static char g_sLogFile[PLATFORM_MAX_PATH] = "addons/sourcemod/logs/infected_control_fdxxnav.txt";
stock void LogDbg(const char[] fmt, any ...)
{
    if (g_iDebugMode <= 0) return;
    char b[512]; VFormat(b, sizeof b, fmt, 2);
    LogToFile(g_sLogFile, "%s", b);
    if (g_iDebugMode >= 2) PrintToServer("[IC] %s", b);
}

// ============ 运行状态 ============
enum SIClass { SI_None=0, SI_Smoker=1, SI_Boomer, SI_Hunter, SI_Spitter, SI_Jockey, SI_Charger };

static const char SIName[10][] = {
    "none","smoker","boomer","hunter","spitter","jockey","charger","witch","tank","survivor"
};

enum struct State
{
    Handle hTick;       // 1s Tick（校验/传送/波节奏）
    float  lastWaveStart;
    int    waveAgeSec;

    int    totalSI;
    int    aliveOf[7];  // 1..6

    // 传送计数器（每个 bot 连续不可见秒数）
    int    teleCount[MAXPLAYERS+1];

    // 目标/runner
    bool   pickRunner;
    int    runnerIdx;

    // 找点扩圈
    float  ringSpawn;
    float  ringTeleport;

    // 队列
    ArrayList qSpawn;     // 待刷新
    ArrayList qTeleport;  // 待传送重生
}
static State ST;

// ============ Nav/Flow 分桶缓存 ============
#define MAX_BUCKETS 4096

ArrayList g_aAreas;    // Address
ArrayList g_aAreaID;   // int
ArrayList g_aFlow;     // float
float     g_fFlowMax = 0.0;
ArrayList g_hBucket[MAX_BUCKETS];  // 每个桶是 ArrayList<int>，存放“索引”（指向 g_aAreas 的下标）
int       g_nBucketCount = 0;

float     g_fBucketSize = 200.0;

// ============ 辅助 ============
static bool IsValidClient(int c)  { return (c >= 1 && c <= MaxClients) && IsClientInGame(c); }
static bool IsSurvivor(int c)     { return IsValidClient(c) && GetClientTeam(c)==TEAM_SURVIVOR; }
static bool IsAliveSur(int c)     { return IsSurvivor(c) && IsPlayerAlive(c); }
static bool IsInfectedBot(int c)
{
    if (!IsValidClient(c) || GetClientTeam(c)!=TEAM_INFECTED || !IsFakeClient(c) || !IsPlayerAlive(c))
        return false;
    int zc = GetEntProp(c, Prop_Send, "m_zombieClass");
    return zc>=1 && zc<=6;
}

// ============ 插件信息 ============
public Plugin myinfo =
{
    name        = "Infected Control (Flow-Buckets)",
    author      = "Caibiii, 夜羽真白, 东, Paimon-Kawaii, ChatGPT",
    description = "特感刷新控制（Flow 分桶 + 有界抽样 + 导演兜底），含传送/跑男/掩码/全牛全猎等",
    version     = "2025.09.03",
    url         = "https://github.com/fantasylidong/CompetitiveWithAnne"
};

// ============ 前置库 ============
public void OnAllPluginsLoaded()
{
    g_bLibPause       = LibraryExists("pause");
    g_bLibSmoker      = LibraryExists("ai_smoker_new");
    g_bLibTargetLimit = LibraryExists("SI_Target_limit");
}
public void OnLibraryAdded(const char[] n)
{
    if (StrEqual(n,"pause"))           g_bLibPause = true;
    if (StrEqual(n,"ai_smoker_new"))   g_bLibSmoker = true;
    if (StrEqual(n,"SI_Target_limit")) g_bLibTargetLimit = true;
}
public void OnLibraryRemoved(const char[] n)
{
    if (StrEqual(n,"pause"))           g_bLibPause = false;
    if (StrEqual(n,"ai_smoker_new"))   g_bLibSmoker = false;
    if (StrEqual(n,"SI_Target_limit")) g_bLibTargetLimit = false;
}

// ============ 配置 ============
public void OnPluginStart()
{
    // 你要的 CVar
    g_cvSpawnMin          = CreateConVar("inf_SpawnDistanceMin", "250.0",  "特感刷新最小距离", FCVAR_NOTIFY, true, 0.0);
    g_cvSpawnMax          = CreateConVar("inf_SpawnDistanceMax", "1500.0", "特感刷新最大距离", FCVAR_NOTIFY, true, 1.0);
    g_cvTeleportEnable    = CreateConVar("inf_TeleportSi", "1", "是否开启特感超时传送", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTeleportCheckTime = CreateConVar("inf_TeleportCheckTime", "5", "特感几秒后没被看到开始传送", FCVAR_NOTIFY, true, 0.0);
    g_cvEnableMask        = CreateConVar("inf_EnableSIoption", "63", "启用的特感位掩码(1~63)", FCVAR_NOTIFY, true, 1.0, true, 63.0);
    g_cvAllCharger        = CreateConVar("inf_AllChargerMode", "0", "全牛模式", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAllHunter         = CreateConVar("inf_AllHunterMode", "0", "全猎模式", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAutoSpawn         = CreateConVar("inf_EnableAutoSpawnTime", "1", "是否开启自动增时", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvIgnoreIncapSight  = CreateConVar("inf_IgnoreIncappedSurvivorSight", "1", "传送检测是否忽略倒地/挂边视线", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAddDmgSmoker      = CreateConVar("inf_AddDamageToSmoker", "0", "单人时Smoker拉人对Smoker增伤5x", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSiLimit           = CreateConVar("l4d_infected_limit", "6", "一次刷出多少特感", FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_cvSiInterval        = CreateConVar("versus_special_respawn_interval", "16.0", "对抗刷新间隔", FCVAR_NOTIFY, true, 1.0);
    g_cvDebugMode         = CreateConVar("inf_DebugMode", "1","0=off,1=logfile,2=console+log,3=预留beam", FCVAR_NOTIFY, true, 0.0, true, 3.0);

    // 找点参数
    g_cvBucketFlowSize    = CreateConVar("inf_BucketFlowSize", "200.0", "Flow 分桶粒度(单位: flow 距离)", FCVAR_NOTIFY, true, 50.0, true, 2000.0);
    g_cvMaxScanPerCall    = CreateConVar("inf_MaxScanPerCall", "240", "单次找点最多检查候选数", FCVAR_NOTIFY, true, 50.0, true, 1000.0);
    g_cvMaxNeighborsPerRing = CreateConVar("inf_MaxBucketsPerRing", "32", "单次扩圈最多尝试多少个桶（防爆量）", FCVAR_NOTIFY, true, 4.0, true, float(MAX_BUCKETS));

    // 初值
    RefreshCVars();

    // 队列
    ST.qSpawn    = new ArrayList();
    ST.qTeleport = new ArrayList();

    HookEvent("round_start",     Evt_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("map_transition",  Evt_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("mission_lost",    Evt_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("finale_win",      Evt_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("player_spawn",    Evt_PlayerSpawn);
    HookEvent("player_death",    Evt_PlayerDeath);
    HookEvent("ability_use",     Evt_AbilityUse);
    HookEvent("player_hurt",     Evt_PlayerHurt);

    RegAdminCmd("sm_startspawn", Cmd_Start, ADMFLAG_ROOT);
    RegAdminCmd("sm_stopspawn",  Cmd_Stop,  ADMFLAG_ROOT);
}
public void OnMapStart()
{
    BuildNavBuckets();  // Flow 分桶预处理（O(N)）
}
public void OnMapEnd()
{
    ClearBuckets();
}
public void OnConfigsExecuted() { RefreshCVars(); }
public void OnPause()   { PauseWaveTimer(); }
public void OnUnpause() { ResumeWaveTimer(); }

// ============ 事件 ============
public Action Cmd_Start(int client, int args)
{
    ResetAll();
    StartWave();
    ReplyToCommand(client, "[IC] start.");
    return Plugin_Handled;
}
public Action Cmd_Stop(int client, int args)
{
    StopAll();
    ReplyToCommand(client, "[IC] stop.");
    return Plugin_Handled;
}
public void Evt_RoundStart(Event e, const char[] n, bool db)
{
    ResetAll();
    BuildNavBuckets();
    // 开启 Tick
    if (ST.hTick == INVALID_HANDLE) ST.hTick = CreateTimer(1.0, Timer_Tick, _, TIMER_REPEAT);
}
public void Evt_RoundEnd(Event e, const char[] n, bool db)
{
    StopAll();
}
public void Evt_PlayerSpawn(Event e, const char[] n, bool db)
{
    int c = GetClientOfUserId(e.GetInt("userid"));
    if (IsInfectedBot(c) && GetEntProp(c, Prop_Send, "m_zombieClass")==view_as<int>(SI_Spitter))
        g_flSpit[c] = GetGameTime();
}
public void Evt_AbilityUse(Event e, const char[] n, bool db)
{
    int c = GetClientOfUserId(e.GetInt("userid"));
    if (!IsInfectedBot(c)) return;
    char ability[32]; e.GetString("ability", ability, sizeof ability);
    if (StrEqual(ability, "ability_spit"))
        g_flSpit[c] = GetGameTime();
}
public void Evt_PlayerDeath(Event e, const char[] n, bool db)
{
    int c = GetClientOfUserId(e.GetInt("userid"));
    if (!IsInfectedBot(c)) return;
    int zc = GetEntProp(c, Prop_Send, "m_zombieClass");
    if (zc != view_as<int>(SI_Spitter))
        CreateTimer(0.3, Timer_KickBot, c);

    if (1<=zc && zc<=6) {
        if (ST.aliveOf[zc] > 0) ST.aliveOf[zc]--;
        if (ST.totalSI > 0) ST.totalSI--;
    }
    ST.teleCount[c] = 0;
}
static Action Timer_KickBot(Handle t, int c)
{
    if (IsInfectedBot(c) && !IsClientInKickQueue(c)) KickClient(c, "cleanup");
    return Plugin_Stop;
}

// ============ CVars ============
static void RefreshCVars()
{
    g_fSpawnMin        = g_cvSpawnMin.FloatValue;
    g_fSpawnMax        = g_cvSpawnMax.FloatValue;
    g_bTeleport        = g_cvTeleportEnable.BoolValue;
    g_bIgnoreIncapSight= g_cvIgnoreIncapSight.BoolValue;
    g_bAutoSpawn       = g_cvAutoSpawn.BoolValue;
    g_bAddDmgSmoker    = g_cvAddDmgSmoker.BoolValue;
    g_iSiLimit         = g_cvSiLimit.IntValue;
    g_fSiInterval      = g_cvSiInterval.FloatValue;
    g_iDebugMode       = g_cvDebugMode.IntValue;

    g_fBucketSize      = g_cvBucketFlowSize.FloatValue;
}

static Action Timer_Tick(Handle timer)
{
    if (g_bLibPause && IsInPause()) return Plugin_Continue;

    // 传送监督
    if (g_bTeleport) TeleportSupervisor();

    // 波节奏（自动增时/开新波）
    WaveRhythm();

    return Plugin_Continue;
}

// ============ 传送监督 ============
static void TeleportSupervisor()
{
    int teleSec = g_cvTeleportCheckTime.IntValue;

    for (int c=1; c<=MaxClients; c++)
    {
        if (!IsInfectedBot(c)) continue;
        if (GetEntProp(c, Prop_Send, "m_isGhost")) continue;

        // 距离太近不传
        if (GetMinDistToSur(c) < g_fSpawnMin) { ST.teleCount[c]=0; continue; }

        // Spitter 刚吐痰 N 秒内不传
        if (GetEntProp(c, Prop_Send, "m_zombieClass")==view_as<int>(SI_Spitter))
        {
            if (GetGameTime() - g_flSpit[c] < 2.0) { ST.teleCount[c]=0; continue; }
        }

        // Smoker 能力没好时不传（避免白传）
        if (g_bLibSmoker && GetEntProp(c, Prop_Send, "m_zombieClass")==view_as<int>(SI_Smoker))
        {
            if (!IsSmokerCanUseAbility(c)) { ST.teleCount[c]=0; continue; }
        }

        bool visible = IsClientVisibleToAnySur(c);
        if (!visible)
        {
            ST.teleCount[c]++;

            if (ST.teleCount[c] >= teleSec)
            {
                int zc = GetEntProp(c, Prop_Send, "m_zombieClass");
                ST.teleCount[c] = 0;

                // 入队传送重生
                ST.qTeleport.Push(zc);
                if (ST.aliveOf[zc] > 0) ST.aliveOf[zc]--;
                if (ST.totalSI > 0) ST.totalSI--;

                LogDbg("[TP] %N (%s) invisible %d sec -> teleport respawn",
                    c, SIName[zc], teleSec);
                KickClient(c, "teleport respawn");
            }
        }
        else
        {
            if (ST.teleCount[c] > 0 && (ST.teleCount[c] % 5)==0)
                LogDbg("[TP] %N visible again -> reset", c);
            ST.teleCount[c]=0;
        }
    }
}

// ============ 波节奏/队列维护 ============
static void ResetAll()
{
    if (ST.hTick != INVALID_HANDLE) { delete ST.hTick; ST.hTick=INVALID_HANDLE; }

    ST.lastWaveStart = GetGameTime();
    ST.waveAgeSec    = 0;
    ST.totalSI       = 0;
    ST.pickRunner    = false; ST.runnerIdx=-1;
    ST.ringSpawn     = g_fSpawnMin;
    ST.ringTeleport  = g_fSpawnMin;

    for (int i=0;i<7;i++) ST.aliveOf[i]=0;
    for (int c=1;c<=MaxClients;c++) { ST.teleCount[c]=0; g_flSpit[c]=0.0; }

    ST.qSpawn.Clear();
    ST.qTeleport.Clear();
}
static void StopAll()
{
    ResetAll();
    ClearBuckets();
}
static void StartWave()
{
    ST.lastWaveStart = GetGameTime();
    ST.waveAgeSec    = 0;

    // 根据当前限制/掩码填充生成队列
    RefillSpawnQueue();
    LogDbg("Wave start: queue=%d", ST.qSpawn.Length);
}
static void PauseWaveTimer()
{
    // 这里只做标记/不新开表，Tick 会停在 IsInPause() 判断
    LogDbg("Pause requested.");
}
static void ResumeWaveTimer()
{
    LogDbg("Resume.");
}
static void WaveRhythm()
{
    ST.waveAgeSec++;

    // runner 检测
    UpdateRunner();

    // 队列补充：保持队列里有货
    if (ST.qSpawn.Length < g_iSiLimit) RefillSpawnQueue();

    // 先处理传送队列（优先）
    if (ST.qTeleport.Length > 0 && ST.totalSI < g_iSiLimit)
    {
        TryTeleportOnce();
        return;
    }

    // 常规生成
    if (ST.totalSI < g_iSiLimit && ST.qSpawn.Length > 0)
    {
        // 简单节流：按间隔开新波或老波“剩余不足 + 自动增时”
        bool timeOk = (GetGameTime()-ST.lastWaveStart) >= g_fSiInterval
                   || (g_bAutoSpawn && (ST.totalSI <= (g_iSiLimit/2)));

        if (timeOk)
            TrySpawnOnce();
    }
}
static int g_iEnableMask() { return g_cvEnableMask.IntValue; }
static bool IsClassEnabled(int zc) { return ( (1 << (zc-1)) & g_iEnableMask() ) != 0; }
static bool ReachCap(int zc)
{
    int alive = ST.aliveOf[zc];
    int queued = 0;
    for (int i=0;i<ST.qSpawn.Length;i++) if (ST.qSpawn.Get(i)==zc) queued++;
    for (int i=0;i<ST.qTeleport.Length;i++) if (ST.qTeleport.Get(i)==zc) queued++;
    // 读 z_xxx_limit（SP 不用 char*）
    static const char cvarNames[][] = {
    "", "z_smoker_limit","z_boomer_limit","z_hunter_limit","z_spitter_limit","z_jockey_limit","z_charger_limit"};
    ConVar h = FindConVar(cvarNames[zc]);
    int cap = (h != null) ? h.IntValue : 0;
    return (alive + queued) >= cap;
}
// 让 Boomer / Spitter 靠后生成：开波先出控制位（Smoker/Hunter/Jockey/Charger）
// - 支援在开波 5 秒内不刷
// - 支援需要至少 1 个控制位（存活或已在待刷队列）后才放行
static bool MeetRequirement(int zc)
{
    // 非支援：直接允许
    if (zc == view_as<int>(SI_Smoker) ||
        zc == view_as<int>(SI_Hunter) ||
        zc == view_as<int>(SI_Jockey) ||
        zc == view_as<int>(SI_Charger))
    {
        return true;
    }

    // 支援（Boomer / Spitter）
    const int kSupportDelaySec = 2; // 想调就改这个数

    // 开波前 N 秒不放支援
    if (ST.waveAgeSec < kSupportDelaySec)
        return false;

    // 统计现有/队列中的控制位数量，至少需要 1 个
    int killersAlive =
        ST.aliveOf[view_as<int>(SI_Smoker)] +
        ST.aliveOf[view_as<int>(SI_Hunter)] +
        ST.aliveOf[view_as<int>(SI_Jockey)] +
        ST.aliveOf[view_as<int>(SI_Charger)];

    int killersQueued = 0;
    for (int i = 0; i < ST.qSpawn.Length; i++)
    {
        int t = ST.qSpawn.Get(i);
        if (t == view_as<int>(SI_Smoker) ||
            t == view_as<int>(SI_Hunter) ||
            t == view_as<int>(SI_Jockey) ||
            t == view_as<int>(SI_Charger))
        {
            killersQueued++;
        }
    }

    return (killersAlive + killersQueued) >= 1;
}

static void RefillSpawnQueue()
{
    int want = g_iSiLimit - ST.qSpawn.Length - ST.totalSI;
    if (want <= 0) return;

    for (int i=0;i<want;i++)
    {
        int zc = 0;
        if (g_cvAllCharger.BoolValue) zc = view_as<int>(SI_Charger);
        else if (g_cvAllHunter.BoolValue) zc = view_as<int>(SI_Hunter);
        else
        {
            for (int tries=0; tries<8; tries++)
            {
                int pick = GetRandomInt(1,6);
                if (IsClassEnabled(pick) && !ReachCap(pick) && MeetRequirement(pick))
                { zc = pick; break; }
            }
        }
        if (zc!=0) ST.qSpawn.Push(zc);
    }
}

// ============ Runner & Target ============
static bool IsPinned(int s)
{
    if (!IsSurvivor(s) || !IsPlayerAlive(s)) return false;
    return GetEntPropEnt(s, Prop_Send, "m_tongueOwner")>0
        || GetEntPropEnt(s, Prop_Send, "m_carryAttacker")>0
        || GetEntPropEnt(s, Prop_Send, "m_jockeyAttacker")>0
        || GetEntPropEnt(s, Prop_Send, "m_pounceAttacker")>0
        || GetEntPropEnt(s, Prop_Send, "m_pummelAttacker")>0;
}
static void UpdateRunner()
{
    // 所有人都倒/挂则不判跑男
    int surv=0, down=0;
    for (int i=1;i<=MaxClients;i++)
    {
        if (IsSurvivor(i))
        {
            surv++;
            if (!IsPlayerAlive(i) || L4D_IsPlayerIncapacitated(i)) down++;
        }
    }
    if (surv==0 || down>=surv) { ST.pickRunner=false; ST.runnerIdx=-1; return; }

    int target = L4D_GetHighestFlowSurvivor();
    if (!IsSurvivor(target) || !IsPlayerAlive(target)) { ST.pickRunner=false; ST.runnerIdx=-1; return; }

    float t[3]; GetClientAbsOrigin(target, t);
    bool nearMate = false;
    for (int i=1;i<=MaxClients;i++)
    {
        if (i==target || !IsAliveSur(i)) continue;
        float p[3]; GetClientAbsOrigin(i, p);
        if (GetVectorDistance(t,p) <= RUNNER_NEAR_RADIUS) { nearMate = true; break; }
    }
    if (!nearMate) { ST.pickRunner=false; ST.runnerIdx=-1; return; }

    // 附近若已有感染者或被控，也取消 runner
    for (int i=1;i<=MaxClients;i++)
    {
        if (IsInfectedBot(i))
        {
            float p[3]; GetClientAbsOrigin(i,p);
            if (GetVectorDistance(t,p) <= RUNNER_NEAR_RADIUS*1.3) { ST.pickRunner=false; ST.runnerIdx=-1; return; }
        }
        if (IsPinned(target) || L4D_IsPlayerIncapacitated(target)) { ST.pickRunner=false; ST.runnerIdx=-1; return; }
    }

    ST.pickRunner = true;
    ST.runnerIdx  = target;
}

// ============ 伤害事件（可选：单人增伤 smoker） ============
public void Evt_PlayerHurt(Event e, const char[] n, bool db)
{
    if (!g_bAddDmgSmoker) return;
    int victim   = GetClientOfUserId(e.GetInt("userid"));
    int attacker = GetClientOfUserId(e.GetInt("attacker"));
    if (!IsInfectedBot(victim) || !IsSurvivor(attacker)) return;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass")!=view_as<int>(SI_Smoker)) return;

    int dmg    = e.GetInt("dmg_health");
    int health = e.GetInt("health");
    if (GetEntPropEnt(victim, Prop_Send, "m_tongueVictim") > 0)
    {
        int bonus = dmg*5;
        int hp = health - bonus;
        if (hp<0) hp=0;
        SetEntityHealth(victim, hp);
        e.SetInt("health", hp);
    }
}

// ============ Spawn 尝试（常规/传送） ============
static void TrySpawnOnce()
{
    int zc = ST.qSpawn.Get(0);
    int target = ChooseTarget();

    float pos[3];
    bool ok = FindSpawnPos_Buckets(zc, target, ST.ringSpawn, /*tele=*/false, pos);

    if (!ok) { ST.ringSpawn = FloatMin(g_fSpawnMax, ST.ringSpawn + 50.0); }
    else if (DoSpawnAt(pos, zc))
    {
        ST.qSpawn.Erase(0);
        ST.aliveOf[zc]++; ST.totalSI++;
        ST.ringSpawn = FloatMax(g_fSpawnMin, ST.ringSpawn * 0.6);
        ST.lastWaveStart = GetGameTime();
    }
    else
    {
        ST.ringSpawn = FloatMin(g_fSpawnMax, ST.ringSpawn + 50.0);
    }

    // 到顶兜底
    if (ST.ringSpawn >= g_fSpawnMax - 1.0)
    {
        if (DirectorFallbackAtMax(zc, target, false, pos) && DoSpawnAt(pos, zc))
        {
            ST.qSpawn.Erase(0);
            ST.aliveOf[zc]++; ST.totalSI++;
            ST.ringSpawn = g_fSpawnMin;
        }
        else
        {
            LogDbg("[SPAWN FAIL] director fallback failed (%s)", SIName[zc]);
        }
    }
}
static void TryTeleportOnce()
{
    int zc = ST.qTeleport.Get(0);
    int target = ChooseTarget();

    float pos[3];
    bool ok = FindSpawnPos_Buckets(zc, target, ST.ringTeleport, /*tele=*/true, pos);

    if (!ok) { ST.ringTeleport = FloatMin(g_fSpawnMax, ST.ringTeleport + 50.0); }
    else if (DoSpawnAt(pos, zc))
    {
        ST.qTeleport.Erase(0);
        ST.aliveOf[zc]++; ST.totalSI++;
        ST.ringTeleport = FloatMax(g_fSpawnMin, ST.ringTeleport * 0.7);
    }
    else
    {
        ST.ringTeleport = FloatMin(g_fSpawnMax, ST.ringTeleport + 50.0);
    }

    if (ST.ringTeleport >= g_fSpawnMax - 1.0)
    {
        if (DirectorFallbackAtMax(zc, target, true, pos) && DoSpawnAt(pos, zc))
        {
            ST.qTeleport.Erase(0);
            ST.aliveOf[zc]++; ST.totalSI++;
            ST.ringTeleport = FloatMax(g_fSpawnMin, ST.ringTeleport * 0.7);
        }
        else LogDbg("[TP FAIL] director fallback failed (%s)", SIName[zc]);
    }
}
static int ChooseTarget()
{
    if (ST.pickRunner && IsAliveSur(ST.runnerIdx) && !IsPinned(ST.runnerIdx))
        return ST.runnerIdx;

    // 目标限制库
    int cand[8]; int n=0;
    for (int i=1;i<=MaxClients;i++)
    {
        if (!IsAliveSur(i)) continue;
        if (g_bLibTargetLimit && IsClientReachLimit(i)) continue;
        cand[n++] = i; if (n>=8) break;
    }
    if (n>0) return cand[GetRandomInt(0, n-1)];
    return L4D_GetHighestFlowSurvivor();
}

// ============ 可见/卡壳 ============
static bool IsClientVisibleToAnySur(int client)
{
    float pEye[3]; GetClientEyePosition(client, pEye);

    Address area = L4D_GetNearestNavArea(pEye);
    int areaID = (area != Address_Null) ? L4D_GetNavAreaID(area) : 0;

    for (int s=1;s<=MaxClients;s++)
    {
        if (!IsAliveSur(s)) continue;

        if (L4D2_IsVisibleToPlayer(s, VIS_TEAM_CLIENT, VIS_TEAM_TARGET, areaID, pEye))
            return true;

        if (g_bIgnoreIncapSight && L4D_IsPlayerIncapacitated(s))
            continue;
    }
    return false;
}
static bool WillStuck(const float at[3])
{
    Handle tr = TR_TraceHullFilterEx(at, at, HULL_MIN, HULL_MAX, MASK_PLAYERSOLID, TraceFilter_Stuck);
    bool hit = TR_DidHit(tr);
    delete tr;
    return hit;
}
public bool TraceFilter_Stuck(int ent, int mask)
{
    if (ent<=MaxClients || !IsValidEntity(ent)) return false;
    return true;
}

// ============ 距离/Flow ============
static float GetMinDistToSur(int entityOrZeroPos)
{
    float p[3];
    if (entityOrZeroPos > 0) GetClientAbsOrigin(entityOrZeroPos, p);
    else { p[0]=p[1]=p[2]=0.0; }
    float best = 999999.0, s[3];
    for (int i=1;i<=MaxClients;i++)
    {
        if (!IsAliveSur(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d<best) best=d;
    }
    return best;
}

// ============ 导演兜底（到达最大半径时） ============
static bool DirectorFallbackAtMax(int zc, int target, bool teleportMode, float outPos[3])
{
    const int kTries = 48;
    bool have=false; float best[3]; float bestDelta=999999.0;

    for (int i=0;i<kTries;i++)
    {
        float pt[3];
        if (!L4D_GetRandomPZSpawnPosition(target, zc, 7, pt))
            continue;

        float minD = GetMinDistToAnySurPos(pt);
        if (minD < g_fSpawnMin || minD > g_fSpawnMax + 200.0)
            continue;

        // 可见/卡壳
        if (IsPosVisibleToAnySur(pt, teleportMode)) continue;
        if (WillStuck(pt)) continue;

        float delta = FloatAbs(g_fSpawnMax - minD);
        if (!have || delta < bestDelta) { have=true; best=pt; bestDelta=delta; }
    }

    if (!have) return false;
    outPos[0]=best[0]; outPos[1]=best[1]; outPos[2]=best[2];
    return true;
}
static float GetMinDistToAnySurPos(const float p[3])
{
    float best = 999999.0, s[3];
    for (int i=1;i<=MaxClients;i++)
    {
        if (!IsAliveSur(i)) continue;
        GetClientAbsOrigin(i, s);
        float d = GetVectorDistance(p, s);
        if (d<best) best=d;
    }
    return best;
}
static bool IsPosVisibleToAnySur(float pos[3], bool teleportMode)
{
    float eye[3];
    eye[0] = pos[0];
    eye[1] = pos[1];
    eye[2] = pos[2] + 62.0;
    Address area = L4D_GetNearestNavArea(pos);
    int areaID = (area != Address_Null) ? L4D_GetNavAreaID(area) : 0;

    for (int s=1;s<=MaxClients;s++)
    {
        if (!IsAliveSur(s)) continue;
        if (teleportMode && g_bIgnoreIncapSight && L4D_IsPlayerIncapacitated(s)) continue;

        if (L4D2_IsVisibleToPlayer(s, VIS_TEAM_CLIENT, VIS_TEAM_TARGET, areaID, pos)) return true;
        if (L4D2_IsVisibleToPlayer(s, VIS_TEAM_CLIENT, VIS_TEAM_TARGET, areaID, eye)) return true;
    }
    return false;
}

// ============ Flow 分桶预处理 ============
static void ClearBuckets()
{
    if (g_aAreas)  { delete g_aAreas;  g_aAreas=null; }
    if (g_aAreaID){ delete g_aAreaID; g_aAreaID=null; }
    if (g_aFlow)   { delete g_aFlow;   g_aFlow=null;  }
    for (int i=0;i<g_nBucketCount;i++)
        if (g_hBucket[i]!=null) { delete g_hBucket[i]; g_hBucket[i]=null; }
    g_nBucketCount=0; g_fFlowMax=0.0;
}
static void BuildNavBuckets()
{
    ClearBuckets();

    g_aAreas  = new ArrayList();
    g_aAreaID = new ArrayList();
    g_aFlow   = new ArrayList();

    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);

    g_fFlowMax = L4D2Direct_GetMapMaxFlowDistance();
    g_fBucketSize = g_cvBucketFlowSize.FloatValue;
    g_nBucketCount = RoundToCeil(g_fFlowMax / g_fBucketSize) + 2;
    if (g_nBucketCount > MAX_BUCKETS) g_nBucketCount = MAX_BUCKETS;

    for (int i=0;i<g_nBucketCount;i++)
        g_hBucket[i] = new ArrayList();

    for (int i=0;i<all.Length;i++)
    {
        Address area = all.Get(i);
        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        int id = L4D_GetNavAreaID(area);

        int idx = g_aAreas.Length;
        g_aAreas.Push(area);
        g_aAreaID.Push(id);
        g_aFlow.Push(flow);

        int b = (flow <= 0.0) ? 0 : RoundToFloor(flow / g_fBucketSize);
        if (b<0) b=0; if (b>=g_nBucketCount) b=g_nBucketCount-1;
        g_hBucket[b].Push(idx);
    }

    delete all;
    LogDbg("BuildNavBuckets: areas=%d, buckets=%d (size=%.1f, flowmax=%.1f)",
        g_aAreas.Length, g_nBucketCount, g_fBucketSize, g_fFlowMax);
}

// ============ 主找点（Flow 分桶 + 有界抽样） ============
// 统计失败原因
enum FailR { F_Flags=0, F_FlowWin, F_Near, F_Vis, F_Stuck, F_Count };

static bool FindSpawnPos_Buckets(int zc, int targetSur, float ring, bool teleportMode, float outPos[3])
{
    if (g_aAreas==null || g_aAreas.Length==0) { LogDbg("[FIND FAIL] no nav cached"); return false; }

    // 在函数开头加入这段（紧接着 if (g_aAreas==null ...) 之后）：
    // ---- 使用 targetSur 作为第一参考对象（若有效），避免编译警告也有一点点偏置效果
    float surFlow[8]; float surPos[8][3]; int ns=0;

    if (IsAliveSur(targetSur) && !L4D_IsPlayerIncapacitated(targetSur))
    {
        surFlow[ns] = L4D2Direct_GetFlowDistance(targetSur);
        GetClientEyePosition(targetSur, surPos[ns]);
        ns++;
    }

    // ---- 收集其它幸存者（跳过 targetSur，避免重复）
    for (int i=1;i<=MaxClients;i++)
    {
        if (i == targetSur) continue;
        if (!IsAliveSur(i) || L4D_IsPlayerIncapacitated(i)) continue;
        if (ns >= 8) break;
        surFlow[ns] = L4D2Direct_GetFlowDistance(i);
        GetClientEyePosition(i, surPos[ns]);
        ns++;
    }

    if (ns==0) return false;

    // ---- zc 当前没有用于筛选，保留接口（no-op 消警告，不改变行为）
    if (zc) { /* no-op */ }

    // 选择满足“flow 窗口”的桶集合（去重）
    bool useBucket[MAX_BUCKETS]; for (int i=0;i<g_nBucketCount;i++) useBucket[i]=false;

    int spanLimit = g_cvMaxNeighborsPerRing.IntValue;
    int pickedBuckets = 0;

    for (int k=0;k<ns;k++)
    {
        float f = surFlow[k];
        int b1 = RoundToFloor( FloatMax(0.0,  (f-ring) / g_fBucketSize) );
        int b2 = RoundToCeil ( FloatMin(g_fFlowMax, (f+ring)) / g_fBucketSize );

        if (b1<0) b1=0; if (b2>=g_nBucketCount) b2=g_nBucketCount-1;

        for (int b=b1; b<=b2; b++)
        {
            if (!useBucket[b]) { useBucket[b]=true; pickedBuckets++; if (pickedBuckets>=spanLimit) break; }
        }
        if (pickedBuckets>=spanLimit) break;
    }
    if (pickedBuckets==0) return false;

    int maxScan = g_cvMaxScanPerCall.IntValue;
    int fail[view_as<int>(F_Count)];
    for (int i = 0; i < view_as<int>(F_Count); i++)
        fail[i] = 0;

    // 在被选中的桶集合里随机抽样候选
    for (int tries=0; tries<maxScan; tries++)
    {
        int b = PickRandomBucket(useBucket);
        if (b<0) break;
        if (g_hBucket[b].Length==0) { useBucket[b]=false; continue; }

        int arrIdx = g_hBucket[b].Get( GetRandomInt(0, g_hBucket[b].Length-1) );

        Address area = g_aAreas.Get(arrIdx);
        int     id   = g_aAreaID.Get(arrIdx);
        float   flow = g_aFlow.Get(arrIdx);

        // 旗子过滤（救援柜/车；终局区域）
        int flags = L4D_GetNavArea_SpawnAttributes(area);
        bool finaleNow = L4D_IsMissionFinalMap(true) && (L4D2_GetCurrentFinaleStage() < 18);
        if ( (flags & (TERROR_NAV_RESCUE_CLOSET|TERROR_NAV_RESCUE_VEHICLE)) != 0
          || (finaleNow && (flags & TERROR_NAV_FINALE)==0) )
        { fail[F_Flags]++; continue; }

        // Flow 窗（冗余保险：即便选桶也再对 flow 做一次校验）
        bool okFlow=false;
        for (int k=0;k<ns;k++) {
            if (FloatAbs(flow - surFlow[k]) < ring) { okFlow=true; break; }
        }
        if (!okFlow) { fail[F_FlowWin]++; continue; }

        // 在该 Area 取一个随机点
        float p[3]; L4D_FindRandomSpot(id, p);

        // 距离窗：到任意生还者的最小距离
        float dmin = 1.0e9; // 或者 1000000000.0

        for (int k=0;k<ns;k++) {
            float d = GetVectorDistance(p, surPos[k]);
            if (d<dmin) dmin=d;
        }
        if (dmin < g_fSpawnMin || dmin > ring) { fail[F_Near]++; continue; }

        // 可见/卡壳
        if (IsPosVisibleToAnySur(p, teleportMode)) { fail[F_Vis]++; continue; }
        if (WillStuck(p))                            { fail[F_Stuck]++; continue; }

        // OK
        outPos[0]=p[0]; outPos[1]=p[1]; outPos[2]=p[2];
        return true;
    }

    LogDbg("[FIND FAIL] ring=%.1f scan=%d | flags=%d flow=%d near=%d vis=%d stuck=%d",
        ring, g_cvMaxScanPerCall.IntValue, fail[F_Flags], fail[F_FlowWin], fail[F_Near], fail[F_Vis], fail[F_Stuck]);
    return false;
}
static int PickRandomBucket(bool mark[MAX_BUCKETS])
{
    // 简易随机：随机起点线性找
    int start = GetRandomInt(0, g_nBucketCount-1);
    for (int i=0;i<g_nBucketCount;i++)
    {
        int b = (start + i) % g_nBucketCount;
        if (mark[b] && g_hBucket[b].Length>0) return b;
    }
    return -1;
}

// ============ 实际生成 ============
static bool DoSpawnAt(const float pos[3], int zc)
{
    int idx = L4D2_SpawnSpecial(zc, pos, NULL_VECTOR);
    if (idx>0)
    {
        LogDbg("[SPAWN OK] %s idx=%d at (%.1f %.1f %.1f)", SIName[zc], idx, pos[0],pos[1],pos[2]);
        // 小优化：促使 SI 前压
        ServerCommand("nb_assault");
        return true;
    }
    LogDbg("[SPAWN FAIL] %s at (%.1f %.1f %.1f) -> idx=%d", SIName[zc], pos[0],pos[1],pos[2], idx);
    return false;
}
stock float FloatMax(float a, float b) { return (a > b) ? a : b; }
stock float FloatMin(float a, float b) { return (a < b) ? a : b; }