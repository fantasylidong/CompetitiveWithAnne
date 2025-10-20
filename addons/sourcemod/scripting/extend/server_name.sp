#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <SteamWorks>

// =====================================================
// Anne：动态 GameDescription + 主机名(hostname)
// - GameDescription: 电信服-<模式>[<几特><几秒>]
// - Hostname: 使用 hostname.txt 模板 {AnneHappy}{Full}{MOD}{Confogl}
//   例如: [普通药役][缺人][无mod][几特几秒]
// - 若 hostname.txt 未配置，则回退 ConVar: sn_hostname_format1
// - 轻量节流: 配置变更即时推送；OnGameFrame 每 2 秒对比变化再写
// =====================================================

public Plugin myinfo =
{
    name        = "Anne ServerName & GameDescription",
    author      = "东",
    description = "动态服务器名 + GameDescription [几特几秒]",
    version     = "1.2.4",
    url         = ""
};

// -----------------------------
// ConVars
// -----------------------------
ConVar
    cvarMpGameMode,            // l4d_ready_cfg_name
    cvarSI,                    // l4d_infected_limit
    cvarMpGameMin,             // versus_special_respawn_interval
    cvarHostName,              // hostname
    cvarMainName,              // 兜底记录（不影响逻辑）
    cvarMod,                   // l4d2_addons_eclipse (0=无mod)
    cvarHostPort,              // hostport
    cvarDirCount,              // dirspawn_count
    cvarDirInterval,           // dirspawn_interval
    cvarServerNameFormatCase1; // sn_hostname_format1 (默认模板回退)

// -----------------------------
// 其它全局
// -----------------------------
Handle HostName = INVALID_HANDLE; // KeyValues: 端口 → "servername" 模板

char SavePath[256];

// ======= GameDescription 缓存与节流 =======
static char  g_sLastDesc[128];
static float g_fNextDescUpdate = 0.0;

// -----------------------------
// Lifecycle
// -----------------------------
public void OnPluginStart()
{
    HostName = CreateKeyValues("AnneHappy");
    BuildPath(Path_SM, SavePath, sizeof(SavePath) - 1, "configs/hostname/hostname.txt");
    if (FileExists(SavePath))
        FileToKeyValues(HostName, SavePath);

    cvarHostName = FindConVar("hostname");
    cvarHostPort = FindConVar("hostport");
    cvarMainName = CreateConVar("sn_main_name", "Anne电信服"); // 兜底
    cvarServerNameFormatCase1 = CreateConVar("sn_hostname_format1", "{AnneHappy}{Full}{MOD}{Confogl}");
    cvarMod = FindConVar("l4d2_addons_eclipse");

    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("player_bot_replace", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("bot_player_replace", Event_PlayerTeam, EventHookMode_Post);
}

public void OnPluginEnd()
{
    if (HostName != INVALID_HANDLE) CloseHandle(HostName);
    cvarMpGameMode   = null;
    cvarMpGameMin    = null;
    cvarSI           = null;
    cvarMod          = null;
    cvarDirCount     = null;
    cvarDirInterval  = null;
    cvarServerNameFormatCase1 = null;
}

public void OnAllPluginsLoaded()
{
    cvarSI          = FindConVar("l4d_infected_limit");
    cvarMpGameMin   = FindConVar("versus_special_respawn_interval");
    cvarMpGameMode  = FindConVar("l4d_ready_cfg_name");
    cvarMod         = FindConVar("l4d2_addons_eclipse");

    // Anne战役 / Anne写实
    cvarDirCount    = FindConVar("dirspawn_count");
    cvarDirInterval = FindConVar("dirspawn_interval");
}

public void OnConfigsExecuted()
{
    HookIfPresent("l4d_infected_limit", cvarSI, OnCvarChanged);
    HookIfPresent("versus_special_respawn_interval", cvarMpGameMin, OnCvarChanged);
    HookIfPresent("l4d_ready_cfg_name", cvarMpGameMode, OnCvarChanged);
    HookIfPresent("l4d2_addons_eclipse", cvarMod, OnCvarChanged);
    HookIfPresent("dirspawn_count", cvarDirCount, OnCvarChanged);
    HookIfPresent("dirspawn_interval", cvarDirInterval, OnCvarChanged);

    Update();
}

static void HookIfPresent(const char[] name, ConVar &cv, ConVarChanged callback)
{
    if (cv != null) { cv.AddChangeHook(callback); return; }
    ConVar found = FindConVar(name);
    if (found != null) { cv = found; cv.AddChangeHook(callback); }
}

public void Event_PlayerTeam(Event hEvent, const char[] sName, bool bDontBroadcast)
{
    Update();
}

public void OnMapStart()
{
    if (HostName != INVALID_HANDLE)
        CloseHandle(HostName);

    HostName = CreateKeyValues("AnneHappy");
    BuildPath(Path_SM, SavePath, sizeof(SavePath) - 1, "configs/hostname/hostname.txt");
    if (FileExists(SavePath))
        FileToKeyValues(HostName, SavePath);
}

public void OnCvarChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
    Update();
}

// -----------------------------
// 主更新入口：hostname + description
// -----------------------------
public void Update()
{
    UpdateServerName(); // hostname
    // GameDescription 立即推一次，保证快速可见
    char desc[128];
    BuildGameDescription(desc, sizeof(desc));
    SteamWorks_SetGameDescription(desc);
    strcopy(g_sLastDesc, sizeof(g_sLastDesc), desc);
}

// 每 2 秒检查一次差异，有变化才写，避免刷爆
public void OnGameFrame()
{
    float now = GetEngineTime();
    if (now < g_fNextDescUpdate)
        return;

    g_fNextDescUpdate = now + 2.0; // 节流

    char desc[128];
    BuildGameDescription(desc, sizeof(desc));
    if (!StrEqual(g_sLastDesc, desc))
    {
        SteamWorks_SetGameDescription(desc);
        strcopy(g_sLastDesc, sizeof(g_sLastDesc), desc);
    }
}

// -----------------------------
// GameDescription：电信服-<模式>[几特几秒]
// 若模式 cvar 未就绪/为空：返回 "Anne电信服"
// -----------------------------
void BuildGameDescription(char[] out, int maxlen)
{
    char cfg[128];
    cfg[0] = '\0';
    if (cvarMpGameMode != null)
        GetConVarString(cvarMpGameMode, cfg, sizeof(cfg));

    if (cfg[0] == '\0') {
        Format(out, maxlen, "Anne电信服");
        return;
    }

    // 模式识别
    bool isAnneHappy    = (StrContains(cfg, "AnneHappy",   false) != -1);
    bool isHardCore     = (StrContains(cfg, "HardCore",    false) != -1);
    bool isAnneCoop     = (StrContains(cfg, "AnneCoop",    false) != -1);
    bool isAnneRealism  = (StrContains(cfg, "AnneRealism", false) != -1);
    bool isAllCharger   = (StrContains(cfg, "AllCharger",  false) != -1);
    bool is1vHunters    = (StrContains(cfg, "1vHunters",   false) != -1);
    bool isWitchParty   = (StrContains(cfg, "WitchParty",  false) != -1);
    bool isAlone        = (StrContains(cfg, "Alone",       false) != -1);

    char mode[32];
    if (isAnneHappy)         strcopy(mode, sizeof(mode), isHardCore ? "硬核药役" : "普通药役");
    else if (isAnneCoop)     strcopy(mode, sizeof(mode), "Anne战役");
    else if (isAnneRealism)  strcopy(mode, sizeof(mode), "Anne写实");
    else if (isAllCharger)   strcopy(mode, sizeof(mode), "牛牛冲刺");
    else if (is1vHunters)    strcopy(mode, sizeof(mode), "HT训练");
    else if (isWitchParty)   strcopy(mode, sizeof(mode), "女巫派对");
    else if (isAlone)        strcopy(mode, sizeof(mode), "单人装逼");
    else                     strcopy(mode, sizeof(mode), cfg);

    // 计算“几特几秒”
    bool usesDirSpawn      = (isAnneCoop || isAnneRealism);
    bool usesAnneHappyPair = (isAnneHappy || isAllCharger || is1vHunters || isWitchParty || isAlone);

    int siCount = 0;
    int siInterval = -1;

    if (usesDirSpawn) {
        if (cvarDirCount != null)        siCount = GetConVarInt(cvarDirCount);
        else if (cvarSI != null)         siCount = GetConVarInt(cvarSI);

        if (cvarDirInterval != null)     siInterval = RoundToNearest(GetConVarFloat(cvarDirInterval));
        else if (cvarMpGameMin != null)  siInterval = GetConVarInt(cvarMpGameMin);
    } else if (usesAnneHappyPair) {
        if (cvarSI != null)              siCount = GetConVarInt(cvarSI);
        if (cvarMpGameMin != null)       siInterval = GetConVarInt(cvarMpGameMin);
    }

    if (siCount > 0 && siInterval >= 0)
        Format(out, maxlen, "电信服-%s[%d特%d秒]", mode, siCount, siInterval);
    else
        Format(out, maxlen, "电信服-%s", mode);
}

// -----------------------------
// Hostname 渲染：{AnneHappy}{Full}{MOD}{Confogl}
// - {AnneHappy}: 模式标签（例：[普通药役] / [Anne战役] …）
// - {Full}: 不满→[缺人]；满→空
// - {MOD}: eclipse==0 → [无mod]；否则空
// - {Confogl}: [几特几秒]（无数据则空）
// -----------------------------
public void UpdateServerName()
{
    // 读取模式字符串
    char cfg[128];
    cfg[0] = '\0';
    if (cvarMpGameMode != null)
        GetConVarString(cvarMpGameMode, cfg, sizeof(cfg));

    bool isAnneHappy    = (StrContains(cfg, "AnneHappy",   false) != -1);
    bool isHardCore     = (StrContains(cfg, "HardCore",    false) != -1);
    bool isAnneCoop     = (StrContains(cfg, "AnneCoop",    false) != -1);
    bool isAnneRealism  = (StrContains(cfg, "AnneRealism", false) != -1);
    bool isAllCharger   = (StrContains(cfg, "AllCharger",  false) != -1);
    bool is1vHunters    = (StrContains(cfg, "1vHunters",   false) != -1);
    bool isWitchParty   = (StrContains(cfg, "WitchParty",  false) != -1);
    bool isAlone        = (StrContains(cfg, "Alone",       false) != -1);

    bool isAnneFamily = (isAnneHappy || isAnneCoop || isAnneRealism || isAllCharger || is1vHunters || isWitchParty || isAlone);

    // {AnneHappy} → 模式标签
    char tagMode[32] = "";
    if (isAnneHappy)         strcopy(tagMode, sizeof(tagMode), isHardCore ? "[硬核药役]" : "[普通药役]");
    else if (isAnneCoop)     strcopy(tagMode, sizeof(tagMode), "[Anne战役]");
    else if (isAnneRealism)  strcopy(tagMode, sizeof(tagMode), "[Anne写实]");
    else if (isAllCharger)   strcopy(tagMode, sizeof(tagMode), "[牛牛冲刺]");
    else if (is1vHunters)    strcopy(tagMode, sizeof(tagMode), "[HT训练]");
    else if (isWitchParty)   strcopy(tagMode, sizeof(tagMode), "[女巫派对]");
    else if (isAlone)        strcopy(tagMode, sizeof(tagMode), "[单人装逼]");
    else if (cfg[0] != '\0') { Format(tagMode, sizeof(tagMode), "[%s]", cfg); }

    // 计算“几特几秒” → {Confogl}
    int siCount = 0, siInterval = -1;
    if (isAnneCoop || isAnneRealism) {
        if (cvarDirCount != null)        siCount = GetConVarInt(cvarDirCount);
        else if (cvarSI != null)         siCount = GetConVarInt(cvarSI);

        if (cvarDirInterval != null)     siInterval = RoundToNearest(GetConVarFloat(cvarDirInterval));
        else if (cvarMpGameMin != null)  siInterval = GetConVarInt(cvarMpGameMin);
    } else if (isAnneFamily) {
        if (cvarSI != null)              siCount = GetConVarInt(cvarSI);
        if (cvarMpGameMin != null)       siInterval = GetConVarInt(cvarMpGameMin);
    }

    char tagFew[32] = "";
    if (siCount > 0 && siInterval >= 0)
        Format(tagFew, sizeof(tagFew), "[%d特%d秒]", siCount, siInterval);

    // {Full}：不满员→[缺人]；满员→空
    char tagFull[16] = "";
    if (!IsTeamFull(isAnneFamily))
        strcopy(tagFull, sizeof(tagFull), "[缺人]");

    // {MOD}：0→[无mod]
    char tagMod[16] = "";
    if (cvarMod != null && GetConVarInt(cvarMod) == 0)
        strcopy(tagMod, sizeof(tagMod), "[无mod]");

    // 读取 hostname.txt 模板；为空则回退 sn_hostname_format1
    char templateStr[256];
    GetHostnameTemplateForPort(templateStr, sizeof(templateStr));
    if (templateStr[0] == '\0')
        GetConVarString(cvarServerNameFormatCase1, templateStr, sizeof(templateStr));

    // 渲染占位（注意：已对调为 {AnneHappy}=模式, {Confogl}=[几特几秒]）
    ReplaceString(templateStr, sizeof(templateStr), "{AnneHappy}", tagMode);
    ReplaceString(templateStr, sizeof(templateStr), "{Full}",      tagFull);
    ReplaceString(templateStr, sizeof(templateStr), "{MOD}",       tagMod);
    ReplaceString(templateStr, sizeof(templateStr), "{Confogl}",   tagFew);

    // 应用
    if (cvarHostName != null) SetConVarString(cvarHostName, templateStr);
    if (cvarMainName != null) SetConVarString(cvarMainName, templateStr);
}

// 端口 → hostname.txt 模板
void GetHostnameTemplateForPort(char[] out, int maxlen)
{
    out[0] = '\0';
    if (HostName == INVALID_HANDLE) return;

    char port[32];
    if (cvarHostPort != null)
        GetConVarString(cvarHostPort, port, sizeof(port));
    else
        strcopy(port, sizeof(port), "0");

    KvJumpToKey(HostName, port, false);
    KvGetString(HostName, "servername", out, maxlen);
    KvGoBack(HostName);
}

// 是否满员（Anne 系列：只看幸存者位；其它：幸存者 + 特感玩家）
bool IsTeamFull(bool IsAnne = false)
{
    int sum = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && (GetClientTeam(i) == 2 || GetClientTeam(i) == 3) && !IsFakeClient(i))
            sum++;
    }
    if (sum == 0)
        return true;

    int surv = GetConVarInt(FindConVar("survivor_limit"));
    if (IsAnne) {
        return sum >= surv;
    } else {
        int zm = GetConVarInt(FindConVar("z_max_player_zombies"));
        return sum >= (surv + zm);
    }
}

public bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}
