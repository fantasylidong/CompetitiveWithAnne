#pragma semicolon 1 
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

ConVar
    cvarServerNameFormatCase1,
    cvarMpGameMode,            // 实际上是 l4d_ready_cfg_name
    cvarSI,                    // l4d_infected_limit（AnneHappy 用）
    cvarMpGameMin,             // versus_special_respawn_interval（AnneHappy 用）
    cvarHostName,
    cvarMainName,
    cvarMod,                   // l4d2_addons_eclipse
    cvarHostPort,
    cvarDirCount,              // NEW: dirspawn_count（AnneCoop/AnneRealism 用）
    cvarDirInterval;           // NEW: dirspawn_interval（AnneCoop/AnneRealism 用）

Handle
    HostName = INVALID_HANDLE;

char
    SavePath[256],
    g_sDefaultN[68];

static Handle
    g_hHostNameFormat;

public void OnPluginStart()
{
    HostName = CreateKeyValues("AnneHappy");
    BuildPath(Path_SM, SavePath, 255, "configs/hostname/hostname.txt");
    if (FileExists(SavePath))
    {
        FileToKeyValues(HostName, SavePath);
    }

    cvarHostName = FindConVar("hostname");
    cvarHostPort = FindConVar("hostport");
    cvarMainName = CreateConVar("sn_main_name", "Anne电信服");
    g_hHostNameFormat = CreateConVar("sn_hostname_format", "{hostname}{gamemode}");
    cvarServerNameFormatCase1 = CreateConVar("sn_hostname_format1", "{AnneHappy}{Full}{MOD}{Confogl}");
    cvarMod = FindConVar("l4d2_addons_eclipse");

    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("player_bot_replace", Event_PlayerTeam, EventHookMode_Post);
    HookEvent("bot_player_replace", Event_PlayerTeam, EventHookMode_Post);
}

public void OnPluginEnd()
{
    cvarMpGameMode = null;
    cvarMpGameMin = null;
    cvarSI = null;
    cvarMod = null;
    cvarDirCount = null;
    cvarDirInterval = null;
}

public void OnAllPluginsLoaded()
{
    cvarSI          = FindConVar("l4d_infected_limit");
    cvarMpGameMin   = FindConVar("versus_special_respawn_interval");
    cvarMpGameMode  = FindConVar("l4d_ready_cfg_name");
    cvarMod         = FindConVar("l4d2_addons_eclipse");

    // NEW: AnneCoop / AnneRealism
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
    } else if (FindConVar("l4d_ready_cfg_name")) {
        cvarMpGameMode = FindConVar("l4d_ready_cfg_name");
        cvarMpGameMode.AddChangeHook(OnCvarChanged);
    }

    // FIX: 原来这里误把 eclipse 赋给 cvarMpGameMode 了
    if (cvarMod != null) {
        cvarMod.AddChangeHook(OnCvarChanged);
    } else if (FindConVar("l4d2_addons_eclipse")) {
        cvarMod = FindConVar("l4d2_addons_eclipse");
        cvarMod.AddChangeHook(OnCvarChanged);
    }

    // NEW: AnneCoop / AnneRealism 相关 ConVar 监听
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
    HostName = CreateKeyValues("AnneHappy");
    BuildPath(Path_SM, SavePath, 255, "configs/hostname/hostname.txt");
    FileToKeyValues(HostName, SavePath);
}

public void Update()
{
    if (cvarMpGameMode == null) {
        ChangeServerName();
    } else {
        UpdateServerName();
    }
}

public void OnCvarChanged(ConVar cvar, const char[] oldVal, const char[] newVal)
{
    Update();
}

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
    // AnneHappy -> 用 l4d_infected_limit / versus_special_respawn_interval
    // AnneCoop/AnneRealism -> 用 dirspawn_count / dirspawn_interval（若找不到则回退到 AnneHappy 的那对）
    int siCount = 0;
    int siInterval = 0;

    if (isAnneCoop || isAnneRealism) {
        if (cvarDirCount != null) {
            siCount = GetConVarInt(cvarDirCount);
        } else if (cvarSI != null) {
            siCount = GetConVarInt(cvarSI);
        }

        if (cvarDirInterval != null) {
            // dirspawn_interval 常为浮点秒，这里取整展示（与原先风格一致）
            float f = GetConVarFloat(cvarDirInterval);
            siInterval = RoundToNearest(f);
        } else if (cvarMpGameMin != null) {
            siInterval = GetConVarInt(cvarMpGameMin);
        }
    } else if (isAnneHappy) {
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
        // Anne 系列：只看幸存者位是否满
        return sum >= (GetConVarInt(FindConVar("survivor_limit")));
    } else {
        // 其它：幸存者 + 特感玩家
        return sum >= (GetConVarInt(FindConVar("survivor_limit")) + GetConVarInt(FindConVar("z_max_player_zombies")));
    }
}

bool IsPlayer(int client)
{
    if (IsValidClient(client) && (GetClientTeam(client) == 2 || GetClientTeam(client) == 3)) {
        return true;
    } else {
        return false;
    }
}

void ChangeServerName(char[] sReadyUpCfgName = "")
{
    char sPath[128], ServerPort[128];
    GetConVarString(cvarHostPort, ServerPort, sizeof(ServerPort));
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

public bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}
