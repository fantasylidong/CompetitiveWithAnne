#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

/*
 * =====================================================
 *  Anne 系列：服务器名动态更新
 *  规则：
 *  - 服务器名（房间名）：{hostname}{gamemode}
 *      => hostname设置的名字[<模式>][AI:<难度>][缺人][无mod][<几特><几秒>]
 *      * [AI:<难度>]：动态难度插件已加载且 ah_ai_dynamic_current_level 已定档时显示
 *        插件未加载时不读取残留 ConVar，并清掉已写进房间名的 [AI:...] 标签
 *      * [缺人]：未满员显示（Anne 系列只看幸存者位）
 *      * [无mod]：l4d2_addons_eclipse == 0 时显示
 *  - A2S_INFO GameDescription 由 a2s-proxy-go 按服务器名标签重写
 * =====================================================
 */

public Plugin myinfo =
{
    name        = "Anne ServerName",
    author      = "东",
    description = "动态服务器名",
    version     = "1.4.8",
    url         = ""
};

// -----------------------------
// ConVars
// -----------------------------
ConVar
    cvarServerNameFormatCase1,   // 用于生成服务器名后缀（{Confogl}{AIDifficulty}{Full}{MOD}{AnneHappy}）
    cvarMpGameMode,              // 实际是 l4d_ready_cfg_name
    cvarSI,                      // l4d_infected_limit
    cvarMpGameMin,               // versus_special_respawn_interval
    cvarHostName,                // hostname
    cvarMainName,                // sn_main_name（默认“电信服”）
    cvarMod,                     // l4d2_addons_eclipse
    cvarHostPort,                // hostport
    cvarDirCount,                // dirspawn_count
    cvarDirInterval,             // dirspawn_interval
    cvarAIDifficulty;            // ah_ai_dynamic_current_level（插件未加载时不得使用残留值）

// -----------------------------
// 其它全局
// -----------------------------
Handle HostName = INVALID_HANDLE; // KeyValues: 端口 → servername 映射

char SavePath[256];
char g_sDefaultN[68];

ConVar g_hHostNameFormat;        // sn_hostname_format（默认 "{hostname}{gamemode}"）

#define AI_DIFFICULTY_LIBRARY "annehappy_dynamic_ai_difficulty"
#define AI_DIFFICULTY_PLUGIN_FILE "optional/AnneHappy/annehappy_dynamic_ai_difficulty.smx"
#define AI_DIFFICULTY_PLUGIN_SHORT "annehappy_dynamic_ai_difficulty.smx"

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

    // 默认主名按你的要求设为“电信服”
    cvarMainName = CreateConVar("sn_main_name", "电信服");

    // {hostname}{gamemode}：{gamemode} 会被我们构造的后缀替换
    g_hHostNameFormat = CreateConVar("sn_hostname_format", "{hostname}{gamemode}");

    // 用于生成服务器名后缀的模板
    cvarServerNameFormatCase1 = CreateConVar("sn_hostname_format1", "{Confogl}{AIDifficulty}{Full}{MOD}{AnneHappy}");

    cvarMod = FindConVar("l4d2_addons_eclipse");

    // 人数变化时刷新服务器名
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("player_bot_replace", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("bot_player_replace", Event_PlayerTeam, EventHookMode_Post);
}

public void OnAllPluginsLoaded()
{
    cvarSI          = FindConVar("l4d_infected_limit");
    cvarMpGameMin   = FindConVar("versus_special_respawn_interval");
    cvarMpGameMode  = FindConVar("l4d_ready_cfg_name");
    cvarMod         = FindConVar("l4d2_addons_eclipse");

    cvarDirCount    = FindConVar("dirspawn_count");
    cvarDirInterval = FindConVar("dirspawn_interval");
    RefreshAIDifficultyCvar();
}

public void OnConfigsExecuted()
{
    if (cvarSI == null)                cvarSI = FindConVar("l4d_infected_limit");
    if (cvarMpGameMin == null)         cvarMpGameMin = FindConVar("versus_special_respawn_interval");
    if (cvarMpGameMode == null)        cvarMpGameMode = FindConVar("l4d_ready_cfg_name");
    if (cvarMod == null)               cvarMod = FindConVar("l4d2_addons_eclipse");
    if (cvarDirCount == null)          cvarDirCount = FindConVar("dirspawn_count");
    if (cvarDirInterval == null)       cvarDirInterval = FindConVar("dirspawn_interval");
    RefreshAIDifficultyCvar();

    // 关心的 ConVar 用于“服务器名”即时刷新
    if (cvarSI != null)                cvarSI.AddChangeHook(OnCvarChanged);
    if (cvarMpGameMin != null)         cvarMpGameMin.AddChangeHook(OnCvarChanged);
    if (cvarMpGameMode != null)        cvarMpGameMode.AddChangeHook(OnCvarChanged);
    if (cvarMod != null)               cvarMod.AddChangeHook(OnCvarChanged);
    if (cvarDirCount != null)          cvarDirCount.AddChangeHook(OnCvarChanged);
    if (cvarDirInterval != null)       cvarDirInterval.AddChangeHook(OnCvarChanged);

    // 刷新服务器名（房间名）
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

    Update();
}

public void OnPluginEnd()
{
    if (HostName != INVALID_HANDLE) {
        CloseHandle(HostName);
        HostName = INVALID_HANDLE;
    }

    cvarMpGameMode   = null;
    cvarMpGameMin    = null;
    cvarSI           = null;
    cvarMod          = null;
    cvarDirCount     = null;
    cvarDirInterval  = null;
    ReleaseAIDifficultyCvar();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, AI_DIFFICULTY_LIBRARY))
        Update();
}

public void OnLibraryRemoved(const char[] name)
{
    if (!StrEqual(name, AI_DIFFICULTY_LIBRARY))
        return;

    ReleaseAIDifficultyCvar();
    Update();
}

public void Event_PlayerTeam(Event hEvent, const char[] sName, bool bDontBroadcast)
{
    // 人员变化：只更新服务器名
    Update();
}

public void OnCvarChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
    // ConVar 变化：只更新服务器名
    Update();
}

// -----------------------------
// 主更新入口（仅服务器名）
// -----------------------------
public void Update()
{
    if (cvarMpGameMode == null) {
        ChangeServerName();
    } else {
        UpdateServerName();
    }
}

// -----------------------------
// 服务器名构建（hostname设置的名字[<模式>][AI:<难度>][缺人][无mod][<几特><几秒>]）
// -----------------------------
public void UpdateServerName()
{
    char sReadyUpCfgName[128], FinalHostname[128], buffer[128];
    bool IsAnne = false;

    RefreshAIDifficultyCvar();
    GetConVarString(cvarServerNameFormatCase1, FinalHostname, sizeof(FinalHostname));

    if (cvarMpGameMode != null)
        GetConVarString(cvarMpGameMode, sReadyUpCfgName, sizeof(sReadyUpCfgName));
    else
        sReadyUpCfgName[0] = '\0';

    // 模式判定
    bool isAnneHappy    = (StrContains(sReadyUpCfgName, "AnneHappy",   false) != -1);
    bool isHardCore     = (StrContains(sReadyUpCfgName, "HardCore",    false) != -1);
    bool isShotgun      = (StrContains(sReadyUpCfgName, "Shotgun",     false) != -1);
    bool isAnneCoop      = (StrContains(sReadyUpCfgName, "AnneCoop",      false) != -1);
    bool isAnneRealism   = (StrContains(sReadyUpCfgName, "AnneRealism",   false) != -1);
    bool isAnneMutation4 = (StrContains(sReadyUpCfgName, "AnneMutation4", false) != -1);
    bool isAllCharger   = (StrContains(sReadyUpCfgName, "AllCharger",  false) != -1);
    bool is1vHunters    = (StrContains(sReadyUpCfgName, "1vHunters",   false) != -1);
    bool isWitchParty   = (StrContains(sReadyUpCfgName, "WitchParty",  false) != -1);
    bool isAlone        = (StrContains(sReadyUpCfgName, "Alone",       false) != -1);

    if (isAnneHappy) {
        if (isShotgun) {
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[喷子药役]");
        } else {
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", isHardCore ? "[硬核药役]" : "[普通药役]");
        }
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
    else if (isAnneMutation4) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[Anne绝境]");
        IsAnne = true;
    }
    else if (isAllCharger) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[牛牛冲刺]");
        IsAnne = true;
    }
    else if (is1vHunters) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[HT训练]");
        IsAnne = true;
    }
    else if (isWitchParty) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[女巫派对]");
        IsAnne = true;
    }
    else if (isAlone) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "[单人装逼]");
        IsAnne = true;
    }
    else {
        // 未识别：显示原 cfg 值，避免留空
        if (sReadyUpCfgName[0] != '\0') {
            Format(buffer, sizeof(buffer), "[%s]", sReadyUpCfgName);
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", buffer);
        } else {
            ReplaceString(FinalHostname, sizeof(FinalHostname), "{Confogl}", "");
        }
        IsAnne = false;
    }

    // [缺人]
    if (IsTeamFull(IsAnne)) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "");
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{Full}", "[缺人]");
    }

    // [无MOD]
    if (cvarMod == null || GetConVarInt(cvarMod) != 0) {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "");
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{MOD}", "[无MOD]");
    }

    // 统一拼接“[几特几秒]”
    int siCount = 0;
    int siInterval = -1;

    if (isAnneCoop || isAnneRealism || isAnneMutation4) {
        if (cvarDirCount != null)        siCount = GetConVarInt(cvarDirCount);
        else if (cvarSI != null)         siCount = GetConVarInt(cvarSI);

        if (cvarDirInterval != null)     siInterval = RoundToNearest(GetConVarFloat(cvarDirInterval));
        else if (cvarMpGameMin != null)  siInterval = GetConVarInt(cvarMpGameMin);
    } else if (IsAnne) {
        if (cvarSI != null)              siCount = GetConVarInt(cvarSI);
        if (cvarMpGameMin != null)       siInterval = GetConVarInt(cvarMpGameMin);
    }

    if (IsAnne && siCount > 0 && siInterval >= 0) {
        Format(buffer, sizeof(buffer), "[%d特%d秒]", siCount, siInterval);
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}", buffer);
    } else {
        ReplaceString(FinalHostname, sizeof(FinalHostname), "{AnneHappy}", "");
    }

    AddAIDifficultyTag(FinalHostname, sizeof(FinalHostname));

    // 注入为 {gamemode}，与 {hostname} 拼合
    ChangeServerName(FinalHostname);
}

bool IsAIDifficultyPluginRunning()
{
    if (LibraryExists(AI_DIFFICULTY_LIBRARY))
        return true;

    Handle plugin = FindPluginByFile(AI_DIFFICULTY_PLUGIN_FILE);
    if (plugin == null)
        plugin = FindPluginByFile(AI_DIFFICULTY_PLUGIN_SHORT);

    return plugin != null && GetPluginStatus(plugin) == Plugin_Running;
}

void ReleaseAIDifficultyCvar()
{
    if (cvarAIDifficulty == null)
        return;

    cvarAIDifficulty.RemoveChangeHook(OnCvarChanged);
    cvarAIDifficulty = null;
}

void RefreshAIDifficultyCvar()
{
    if (!IsAIDifficultyPluginRunning())
    {
        ReleaseAIDifficultyCvar();
        return;
    }

    if (cvarAIDifficulty != null)
        return;

    cvarAIDifficulty = FindConVar("ah_ai_dynamic_current_level");
    if (cvarAIDifficulty != null)
        cvarAIDifficulty.AddChangeHook(OnCvarChanged);
}

void AddAIDifficultyTag(char[] hostname, int maxlen)
{
    char tag[32];
    tag[0] = '\0';

    if (cvarAIDifficulty != null && cvarAIDifficulty.IntValue >= 1 && cvarAIDifficulty.IntValue <= 6)
    {
        char difficulty[16];
        GetAIDifficultyName(cvarAIDifficulty.IntValue, difficulty, sizeof(difficulty));
        FormatEx(tag, sizeof(tag), "[AI:%s]", difficulty);
    }

    // 旧的自定义模板没有该占位符时，仍自动把 AI 难度追加到末尾。
    if (ReplaceString(hostname, maxlen, "{AIDifficulty}", tag) == 0 && tag[0] != '\0')
        StrCat(hostname, maxlen, tag);
}

void StripStaleAIDifficultyTag(char[] hostname, int maxlen)
{
    static const char tags[][] = {
        "[AI:简单]", "[AI:普通]", "[AI:困难]", "[AI:专家]", "[AI:极限]", "[AI:音理]"
    };

    for (int i = 0; i < sizeof(tags); i++)
        ReplaceString(hostname, maxlen, tags[i], "");
}

void GetAIDifficultyName(int level, char[] buffer, int maxlen)
{
    switch (level)
    {
        case 1: strcopy(buffer, maxlen, "简单");
        case 2: strcopy(buffer, maxlen, "普通");
        case 3: strcopy(buffer, maxlen, "困难");
        case 4: strcopy(buffer, maxlen, "专家");
        case 5: strcopy(buffer, maxlen, "极限");
        case 6: strcopy(buffer, maxlen, "音理");
        default: buffer[0] = '\0';
    }
}

// 是否满员（Anne：只看幸存者；其他：幸存者+特感玩家）
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
// {hostname}{gamemode}：gamemode 即我们构造的“[<模式>][缺人][无mod][<几特><几秒>]”
// -----------------------------
void ChangeServerName(const char[] suffix = "")
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
        GetConVarString(g_hHostNameFormat, sNewName, sizeof(sNewName)); // 默认 "{hostname}{gamemode}"
        ReplaceString(sNewName, sizeof(sNewName), "{hostname}", sPath);
        ReplaceString(sNewName, sizeof(sNewName), "{gamemode}", suffix);
    }

    if (!IsAIDifficultyPluginRunning())
        StripStaleAIDifficultyTag(sNewName, sizeof(sNewName));

    SetConVarString(cvarHostName, sNewName);
    SetConVarString(cvarMainName, sNewName);
    strcopy(g_sDefaultN, sizeof(g_sDefaultN), sNewName);
}
