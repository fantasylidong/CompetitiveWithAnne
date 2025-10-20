#pragma semicolon 1 
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <SteamWorks>

// =====================================================
//  Anne 系列：服务器名 + GameDescription 动态更新
//  - 服务器名支持端口映射、多模式标签、缺人/无MOD 标签
//  - GameDescription 显示（已按你的需求调整）：<模式>-电信服[<几特><几秒>]
//    * Anne战役 / Anne写实：用 dirspawn_count / dirspawn_interval
//    * 其它 Anne 系列（普通/硬核、牛牛冲刺、HT 训练、女巫派对、单人装逼）：
//      用 l4d_infected_limit / versus_special_respawn_interval
//  - 若尚未载入模式（cvar 为空或未就绪），GameDescription = “Anne电信服”
//  - 轻量节流：配置变化即刻推一次，OnGameFrame 每 2 秒检查差异后再更新
// =====================================================

public Plugin myinfo =
{
    name        = "Anne ServerName & GameDescription",
    author      = "东",
    description = "动态服务器名 + GameDescription [几特几秒]",
    version     = "1.2.1",
    url         = ""
};

// -----------------------------
// ConVars
// -----------------------------
ConVar
    cvarServerNameFormatCase1,
    cvarMpGameMode,            // 实际上是 l4d_ready_cfg_name
    cvarSI,                    // l4d_infected_limit（AnneHappy 用）
    cvarMpGameMin,             // versus_special_respawn_interval（AnneHappy 用）
    cvarHostName,
    cvarMainName,
    cvarMod,                   // l4d2_addons_eclipse
    cvarHostPort,
    cvarDirCount,              // AnneCoop/AnneRealism → dirspawn_count
    cvarDirInterval;           // AnneCoop/AnneRealism → dirspawn_interval

// -----------------------------
// 其它全局
// -----------------------------
Handle HostName = INVALID_HANDLE; // KeyValues: 端口 → servername 映射

char SavePath[256];
char g_sDefaultN[68];

ConVar g_hHostNameFormat;        // sn_hostname_format

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
    {
        FileToKeyValues(HostName, SavePath);
    }

    cvarHostName = FindConVar("hostname");
    cvarHostPort = FindConVar("hostport");
    cvarMainName = CreateConVar("sn_main_name", "Anne电信服");
    g_hHostNameFormat = CreateConVar("sn_hostname_format", "{hostname}{gamemode}");
    cvarServerNameFormatCase1 = CreateConVar("sn_hostname_format1", "{Confogl}{Full}{MOD}{AnneHappy}");
    cvarMod = FindConVar("l4d2_addons_eclipse");

    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("player_bot_replace", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("bot_player_replace", Event_PlayerTeam, EventHookMode_Post);
}

public void OnPluginEnd()
{
    cvarMpGameMode   = null;
    cvarMpGameMin    = null;
    cvarSI           = null;
    cvarMod          = null;
    cvarDirCount     = null;
    cvarDirInterval  = null;
}

public void OnAllPluginsLoaded()
{
    cvarSI          = FindConVar("l4d_infected_limit");
    cvarMpGameMin   = FindConVar("versus_special_respawn_interval");
    cvarMpGameMode  = FindConVar("l4d_ready_cfg_name");
    cvarMod         = FindConVar("l4d2_addons_eclipse");

    // AnneCoop / AnneRealism
    cvarDirCount    = FindConVar("dirspawn_count");
    cvarDirInterval = FindConVar("dirspawn_interval");
}

public void OnConfigsExecuted()
{
    if (cvarSI != null) {
        cvarSI.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("l4d_infected_limit") != null) {
        cvarSI = FindConVar("l4d_infected_limit");
        cvarSI.AddChangeHook(OnCvarChanged);
    }

    if (cvarMpGameMin != null) {
        cvarMpGameMin.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("versus_special_respawn_interval") != null) {
        cvarMpGameMin = FindConVar("versus_special_respawn_interval");
        cvarMpGameMin.AddChangeHook(OnCvarChanged);
    }

    if (cvarMpGameMode != null) {
        cvarMpGameMode.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("l4d_ready_cfg_name") != null) {
        cvarMpGameMode = FindConVar("l4d_ready_cfg_name");
        cvarMpGameMode.AddChangeHook(OnCvarChanged);
    }

    // FIX: 防止误把 eclipse 赋给 cvarMpGameMode
    if (cvarMod != null) {
        cvarMod.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("l4d2_addons_eclipse") != null) {
        cvarMod = FindConVar("l4d2_addons_eclipse");
        cvarMod.AddChangeHook(OnCvarChanged);
    }

    // AnneCoop / AnneRealism 相关 ConVar 监听
    if (cvarDirCount != null) {
        cvarDirCount.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("dirspawn_count") != null) {
        cvarDirCount = FindConVar("dirspawn_count");
        cvarDirCount.AddChangeHook(OnCvarChanged);
    }

    if (cvarDirInterval != null) {
        cvarDirInterval.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("dirspawn_interval") != null) {
        cvarDirInterval = FindConVar("dirspawn_interval");
        cvarDirInterval.AddChangeHook(OnCvarChanged);
    }

    Update();
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
    {
        FileToKeyValues(HostName, SavePath);
    }
}

public void OnCvarChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
    Update();
}

// -----------------------------
// 主更新入口
// -----------------------------
public void Update()
{
    if (cvarMpGameMode == null) {
        ChangeServerName();
    } else {
        UpdateServerName();
    }

    // GameDescription 立即推一次，保证快速生效
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

    if (!StrEqual(g_sLastDesc, desc)) {
        SteamWorks_SetGameDescription(desc);
        strcopy(g_sLastDesc, sizeof(g_sLastDesc), desc);
    }
}

// -----------------------------
// 构造 GameDescription 文本
// 需求落实：
// 1) “模式在前，几特几秒在后” → "%s-电信服[%d特%d秒]"
// 2) 如未载入模式（cvar 不存在或取值为空）→ "Anne电信服"
// -----------------------------
void BuildGameDescription(char[] out, int maxlen)
{
    // 读取模式 cvar
    char cfg[128];
    cfg[0] = '\0';
    if (cvarMpGameMode != null) {
        GetConVarString(cvarMpGameMode, cfg, sizeof(cfg));
    }

    // 若模式尚未载入（cvar 不存在或值为空），按要求给默认值
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

    // 标签文本
    char mode[32];
    if (isAnneHappy) {
        strcopy(mode, sizeof(mode), isHardCore ? "硬核药役" : "普通药役");
    } else if (isAnneCoop) {
        strcopy(mode, sizeof(mode), "Anne战役");
    } else if (isAnneRealism) {
        strcopy(mode, sizeof(mode), "Anne写实");
    } else if (isAllCharger) {
        strcopy(mode, sizeof(mode), "牛牛冲刺");
    } else if (is1vHunters) {
        strcopy(mode, sizeof(mode), "HT训练");
    } else if (isWitchParty) {
        strcopy(mode, sizeof(mode), "女巫派对");
    } else if (isAlone) {
        strcopy(mode, sizeof(mode), "单人装逼");
    } else {
        // 未识别到 Anne 系列就直接显示原 cfg 值
        strcopy(mode, sizeof(mode), cfg);
    }

    // 分组：用哪个“几特几秒”
    bool usesDirSpawn      = (isAnneCoop || isAnneRealism);
    bool usesAnneHappyPair = (isAnneHappy || isAllCharger || is1vHunters || isWitchParty || isAlone);

    int   siCount    = 0;
    int   siInterval = -1;

    if (usesDirSpawn) {
        if (cvarDirCount != null)    siCount = GetConVarInt(cvarDirCount);
        else if (cvarSI != null)     siCount = GetConVarInt(cvarSI);

        if (cvarDirInterval != null) {
            siInterval = RoundToNearest(GetConVarFloat(cvarDirInterval));
        } else if (cvarMpGameMin != null) {
            siInterval = GetConVarInt(cvarMpGameMin);
        }
    } else if (usesAnneHappyPair) {
        if (cvarSI != null)          siCount = GetConVarInt(cvarSI);
        if (cvarMpGameMin != null)   siInterval = GetConVarInt(cvarMpGameMin);
    }

    // 最终格式（已调整顺序）：<模式>-电信服[<几特><几秒>]
    if (siCount > 0 && siInterval >= 0) {
        Format(out, maxlen, "%s-电信服[%d特%d秒]", mode, siCount, siInterval);
    } else {
        Format(out, maxlen, "%s-电信服", mode);
    }
}

// -----------------------------
// 服务器名构建（原有逻辑，补全模式标签）
// -----------------------------
public void UpdateServerName()
{
    char sReadyUpCfgName[128], FinalHostname[128], buffer[128];
    bool IsAnne = false;

    GetConVarString(cvarServerNameFormatCase1, FinalHostname, sizeof(FinalHostname));
    GetConVarString(cvarMpGameMode, sReadyUpCfgName, sizeof(sReadyUpCfgName));

    // 模式判定
    bool isAnneHappy    = (StrContains(sReadyUpCfgName, "AnneHappy", false)    != -1);
    bool isAnneCoop     = (StrContains(sReadyUpCfgName, "AnneCoop", false)     != -1);
    bool isAnneRealism  = (StrContains(sReadyUpCfgName, "AnneRealism", false)  != -1);

    if (isAnneHappy) {
        if (StrContains(sReadyUpCfgName, "HardCore", false) != -1)
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[硬核药役]");
        else
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[普通药役]");
        IsAnne = true;
    }
    else if (isAnneCoop) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[Anne战役]");
        IsAnne = true;
    }
    else if (isAnneRealism) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[Anne写实]");
        IsAnne = true;
    }
    else if (StrContains(sReadyUpCfgName, "AllCharger", false) != -1) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[牛牛冲刺]");
        IsAnne = true;
    }
    else if (StrContains(sReadyUpCfgName, "1vHunters", false) != -1) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[HT训练]");
        IsAnne = true;
    }
    else if (StrContains(sReadyUpCfgName, "WitchParty", false) != -1) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[女巫派对]");
        IsAnne = true;
    }
    else if (StrContains(sReadyUpCfgName, "Alone", false) != -1) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[单人装逼]");
        IsAnne = true;
    }
    else {
        GetConVarString(cvarMpGameMode, buffer, sizeof(buffer));
        Format(buffer, sizeof(buffer), "[%s]", buffer);
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", buffer);
        IsAnne = false;
    }

    // 统一拼接“[X特Y秒]”
    int siCount = 0;
    int siInterval = 0;

    if (StrContains(sReadyUpCfgName, "AnneCoop", false) != -1 || StrContains(sReadyUpCfgName, "AnneRealism", false) != -1) {
        if (cvarDirCount != null) {
            siCount = GetConVarInt(cvarDirCount);
        } else if (cvarSI != null) {
            siCount = GetConVarInt(cvarSI);
        }

        if (cvarDirInterval != null) {
            float f = GetConVarFloat(cvarDirInterval);
            siInterval = RoundToNearest(f);
        } else if (cvarMpGameMin != null) {
            siInterval = GetConVarInt(cvarMpGameMin);
        }
    } else if (IsAnne) {
        if (cvarSI != null) {
            siCount = GetConVarInt(cvarSI);
        }
        if (cvarMpGameMin != null) {
            siInterval = GetConVarInt(cvarMpGameMin);
        }
    }

    if (IsAnne && siCount > 0 && siInterval >= 0) {
        Format(buffer, sizeof(buffer), "[%d特%d秒]", siCount, siInterval);
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}", buffer);
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}", "");
    }

    if (IsTeamFull(IsAnne)) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "");
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "[缺人]");
    }

    if (cvarMod == null || (cvarMod != null && GetConVarInt(cvarMod) != 0)) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "");
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "[无MOD]");
    }

    ChangeServerName(FinalHostname);
}

// 是否满员（Anne 系列：只看幸存者位；其它：幸存者 + 特感玩家）
bool IsTeamFull(bool IsAnne = false)
{
    int sum = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && !IsFakeClient(i)) {
            sum++;
        }
    }
    if (sum == 0) {
        return true;
    }
    if (IsAnne) {
        return sum >= GetConVarInt(FindConVar("survivor_limit"));
    } else {
        return sum >= (GetConVarInt(FindConVar("survivor_limit")) + GetConVarInt(FindConVar("z_max_player_zombies")));
    }
}

bool IsPlayer(int client)
{
    return (IsValidClient(client) && (GetClientTeam(client) == 2 || GetClientTeam(client) == 3));
}

public bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}

// -----------------------------
// 应用最终服务器名（支持端口映射）
// -----------------------------
void ChangeServerName(char[] sReadyUpCfgName = "")
{
    char sPath[128], ServerPort[128];
    GetConVarString(cvarHostPort, ServerPort, sizeof(ServerPort));

    if (HostName == INVALID_HANDLE)
        HostName = CreateKeyValues("AnneHappy");

    KvJumpToKey(HostName, ServerPort, false);
    KvGetString(HostName, "servername", sPath, sizeof(sPath));
    KvGoBack(HostName);

    char sNewName[128];
    if (strlen(sPath) == 0)
    {
        GetConVarString(cvarMainName, sNewName, sizeof(sNewName));
    }
    else
    {
        GetConVarString(g_hHostNameFormat, sNewName, sizeof(sNewName));
        ReplaceString(sNewName, sizeof(sNewName), "{hostname}", sPath);
        ReplaceString(sNewName, sizeof(sNewName), "{gamemode}", sReadyUpCfgName);
    }

    SetConVarString(cvarHostName, sNewName);
    SetConVarString(cvarMainName, sNewName);
    Format(g_sDefaultN, sizeof(g_sDefaultN), "%s", sNewName);
}
