/**
 * l4d2_hitsound_plus.sp
 *
 * - 多套音效配置（configs/hitsound_sets.cfg）支持 builtin=1 跳过 FastDL
 * - 覆盖图标“套装”由全局 CVar 控制（configs/hiticon_sets.cfg），0=全局禁用覆盖图标
 * - 玩家可单独：选择音效套装 + 开/关覆盖图标；仅这两项写入 RPG 表（两列）
 * - DB 失败时回退到 KeyValues 文件 data/SoundSelect.txt（键：Snd, Overlay）
 * - FastDL 自动登记（音频=sound/…；图标=materials/…），builtin=1 时跳过
 * - RegPluginLibrary 供其他插件检测：l4d2_hitsound_plus（兼容别名 l4d2_hitsound）
 * - SQL_TConnect 固定用：SQL_TConnect(SQL_OnConnect, confName, 0);
 *
 * SQL（示例，仅两列，确保 steamid 唯一）:
 *   ALTER TABLE `rpg_player`
 *     ADD COLUMN `hitsound_cfg` TINYINT NOT NULL DEFAULT 0,
 *     ADD COLUMN `hitsound_overlay` TINYINT(1) NOT NULL DEFAULT 1,
 *     ADD UNIQUE KEY `uniq_steamid` (`steamid`);
 *
 * commands:
 *   !snd    -> 打开菜单（开关覆盖图标、选择音效套装）
 *   !hitui  -> 快捷开关个人覆盖图标
 */

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <adminmenu>

#define PLUGIN_VERSION "1.3.0"
#define CVAR_FLAGS     FCVAR_NOTIFY
#define IsValidClient(%1) (1 <= %1 && %1 <= MaxClients && IsClientInGame(%1))

// --------------------- Library expose ---------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("l4d2_hitsound_plus");
    RegPluginLibrary("l4d2_hitsound"); // 兼容别名
    return APLRes_Success;
}

// --------------------- ConVars ---------------------
ConVar cv_enable;
ConVar cv_sound_enable;
ConVar cv_pic_enable;
ConVar cv_blast;
ConVar cv_showtime;
ConVar cv_overlay_default; // 新玩家默认是否显示覆盖图标
ConVar cv_db_enable;
ConVar cv_db_conf;
// 全局选择：覆盖图标套装（0=禁用，>=1 使用 hiticon_sets.cfg 对应编号）
ConVar cv_overlay_set;

// --------------------- State ---------------------
int  g_SoundSelect[MAXPLAYERS + 1] = {0, ...};   // 0=禁用音效，>=1 用 hitsound_sets.cfg 的编号
bool g_OverlayEnable[MAXPLAYERS + 1] = {true, ...}; // 个人是否显示覆盖图标

Handle g_hDB = INVALID_HANDLE;

Handle g_taskClean[MAXPLAYERS + 1] = { INVALID_HANDLE, ... };
bool   g_IsVictimDeadPlayer[MAXPLAYERS + 1] = { false, ... };

// Fallback KV
Handle g_SoundStore = INVALID_HANDLE;
char   g_SavePath[256];

// --------------------- Sound sets ---------------------
Handle g_SetNames    = INVALID_HANDLE;
Handle g_SetHeadshot = INVALID_HANDLE;
Handle g_SetHit      = INVALID_HANDLE;
Handle g_SetKill     = INVALID_HANDLE;
int    g_SetCount    = 0;

// --------------------- Overlay icon sets (全局 CVar 选择) ---------------------
Handle g_OvNames = INVALID_HANDLE;
Handle g_OvHead  = INVALID_HANDLE; // materials 基名（不含扩展名）
Handle g_OvHit   = INVALID_HANDLE;
Handle g_OvKill  = INVALID_HANDLE;
int    g_OvCount = 0;

// --------------------- Enums ---------------------
enum OverlayType
{
    KILL_HEADSHOT = 0,
    HIT_ARMOR,
    KILL_NORMAL
};

// --------------------- Plugin Info ---------------------
public Plugin myinfo =
{
    name = "L4D2 Hit/Kill Feedback Plus",
    author = "TsukasaSato , Hesh233 (branch) , merged/updated by ChatGPT",
    description = "音效套装 + 覆盖图标全局套装(0禁用) + RPG两列存取 + FDL",
    version = PLUGIN_VERSION
};

// ========================================================
// Init
// ========================================================
public void OnPluginStart()
{
    char game[64];
    GetGameFolderName(game, sizeof(game));
    if (!StrEqual(game, "left4dead2", false))
    {
        SetFailState("本插件仅支持 L4D2!");
    }

    CreateConVar("l4d2_hitsound_plus_ver", PLUGIN_VERSION, "Plugin version", 0);

    cv_enable          = CreateConVar("sm_hitsound_enable", "1", "是否开启本插件(0关,1开)", CVAR_FLAGS);
    cv_sound_enable    = CreateConVar("sm_hitsound_sound_enable", "1", "是否开启音效(0关,1开)", CVAR_FLAGS);
    cv_pic_enable      = CreateConVar("sm_hitsound_pic_enable", "1", "是否开启覆盖图标(0关,1开)", CVAR_FLAGS);
    cv_blast           = CreateConVar("sm_blast_damage_enable", "0", "是否开启爆炸反馈提示(0关,1开 建议关)", CVAR_FLAGS);
    cv_showtime        = CreateConVar("sm_hitsound_showtime", "0.3", "覆盖图标显示时长(秒)", CVAR_FLAGS);

    cv_overlay_default = CreateConVar("sm_hitsound_overlay_default", "1", "新玩家默认是否显示覆盖图标(1显示,0隐藏)", CVAR_FLAGS);
    cv_overlay_set     = CreateConVar("sm_hitsound_overlay_set", "0", "覆盖图标套装编号(0=全局禁用,>=1 使用 hiticon_sets.cfg)", CVAR_FLAGS);

    cv_db_enable       = CreateConVar("sm_hitsound_db_enable", "1", "是否启用 RPG 表存储(1启用,0禁用)", CVAR_FLAGS);
    cv_db_conf         = CreateConVar("sm_hitsound_db_conf", "rpg", "databases.cfg 中的连接名", CVAR_FLAGS);

    // Fallback KV
    g_SoundStore = CreateKeyValues("SoundSelect");
    BuildPath(Path_SM, g_SavePath, sizeof(g_SavePath), "data/SoundSelect.txt");
    if (FileExists(g_SavePath)) FileToKeyValues(g_SoundStore, g_SavePath);
    else KeyValuesToFile(g_SoundStore, g_SavePath);

    // Arrays
    g_SetNames    = CreateArray(64);
    g_SetHeadshot = CreateArray(PLATFORM_MAX_PATH);
    g_SetHit      = CreateArray(PLATFORM_MAX_PATH);
    g_SetKill     = CreateArray(PLATFORM_MAX_PATH);

    g_OvNames = CreateArray(64);
    g_OvHead  = CreateArray(PLATFORM_MAX_PATH);
    g_OvHit   = CreateArray(PLATFORM_MAX_PATH);
    g_OvKill  = CreateArray(PLATFORM_MAX_PATH);

    // Load configs
    LoadHitSoundSets();
    LoadHitIconSets();

    // DB
    if (GetConVarBool(cv_db_enable))
    {
        char confName[32];
        GetConVarString(cv_db_conf, confName, sizeof(confName));
        SQL_TConnect(SQL_OnConnect, confName, 0); // 按你的签名使用
    }

    RegConsoleCmd("sm_snd",   Cmd_MenuSnd,   "设置音效套装/覆盖图标开关");
    RegConsoleCmd("sm_hitui", Cmd_ToggleUI,  "开关自己的覆盖图标");

    AutoExecConfig(true, "l4d2_hitsound_plus");

    if (GetConVarInt(cv_enable) == 1)
    {
        HookEvent("infected_hurt",       Event_InfectedHurt,  EventHookMode_Pre);
        HookEvent("infected_death",      Event_InfectedDeath);
        HookEvent("player_death",        Event_PlayerDeath);
        HookEvent("player_hurt",         Event_PlayerHurt,    EventHookMode_Pre);
        HookEvent("tank_spawn",          Event_TankSpawn);
        HookEvent("player_spawn",        Event_PlayerSpawn);
        HookEvent("round_start",         Event_RoundStart,    EventHookMode_Post);
        HookEvent("player_incapacitated",Event_PlayerIncap);
    }
}

// ========================================================
// DB Connect callback
// ========================================================
public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE)
    {
        LogError("[hitsound] 数据库连接失败: %s", error);
        return;
    }
    g_hDB = hndl;
    LogMessage("[hitsound] 数据库连接成功。");
}

// ========================================================
// Config loading
// ========================================================
void LoadHitSoundSets()
{
    ClearArray(g_SetNames);
    ClearArray(g_SetHeadshot);
    ClearArray(g_SetHit);
    ClearArray(g_SetKill);
    g_SetCount = 0;

    Handle kv = CreateKeyValues("HitSoundSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hitsound_sets.cfg"))
    {
        // 至少提供 0 号（禁用）
        PushArrayString(g_SetNames, "禁用击中/击杀音效");
        PushArrayString(g_SetHeadshot, "");
        PushArrayString(g_SetHit, "");
        PushArrayString(g_SetKill, "");
        g_SetCount = 1;
        CloseHandle(kv);
        LogError("[hitsound] 未找到 hitsound_sets.cfg，仅提供禁用选项 (0)。");
        return;
    }

    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char name[64];
            char sh[PLATFORM_MAX_PATH], hi[PLATFORM_MAX_PATH], ki[PLATFORM_MAX_PATH];
            int  isbuiltin = 0;

            KvGetString(kv, "name", name, sizeof(name), "未命名音效套装");
            KvGetString(kv, "headshot", sh, sizeof(sh), "");
            KvGetString(kv, "hit",      hi, sizeof(hi), "");
            KvGetString(kv, "kill",     ki, sizeof(ki), "");
            isbuiltin = KvGetNum(kv, "builtin", 0);

            PushArrayString(g_SetNames, name);
            PushArrayString(g_SetHeadshot, sh);
            PushArrayString(g_SetHit, hi);
            PushArrayString(g_SetKill, ki);
            g_SetCount++;

            if (!isbuiltin)
            {
                if (sh[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", sh); AddFileToDownloadsTable(p); }
                if (hi[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", hi); AddFileToDownloadsTable(p); }
                if (ki[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", ki); AddFileToDownloadsTable(p); }
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 套音效配置（含 0 号禁用项时总数会更大）。", g_SetCount);
}

void LoadHitIconSets()
{
    ClearArray(g_OvNames);
    ClearArray(g_OvHead);
    ClearArray(g_OvHit);
    ClearArray(g_OvKill);
    g_OvCount = 0;

    Handle kv = CreateKeyValues("HitIconSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hiticon_sets.cfg"))
    {
        LogMessage("[hitsound] 未找到 hiticon_sets.cfg，overlay_set=0 将禁用覆盖图。");
        CloseHandle(kv);
        return;
    }

    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char name[64];
            char head[PLATFORM_MAX_PATH], hit[PLATFORM_MAX_PATH], kill[PLATFORM_MAX_PATH];
            int  isbuiltin = 0;

            KvGetString(kv, "name", name, sizeof(name), "未命名图标套装");
            // 兼容你的配置：键名 headshot/head/hit/kill
            KvGetString(kv, "head", head, sizeof(head), "");
            if (head[0] == '\0') KvGetString(kv, "headshot", head, sizeof(head), "");
            KvGetString(kv, "hit",  hit,  sizeof(hit),  "");
            KvGetString(kv, "kill", kill, sizeof(kill), "");

            isbuiltin = KvGetNum(kv, "builtin", 0);

            PushArrayString(g_OvNames, name);
            PushArrayString(g_OvHead, head);
            PushArrayString(g_OvHit, hit);
            PushArrayString(g_OvKill, kill);
            g_OvCount++;

            if (!isbuiltin)
            {
                if (head[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", head); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", head); AddFileToDownloadsTable(p2);
                }
                if (hit[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", hit); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", hit); AddFileToDownloadsTable(p2);
                }
                if (kill[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", kill); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", kill); AddFileToDownloadsTable(p2);
                }
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 套图标覆盖主题（0=禁用，>=1 有效）。", g_OvCount);
}

// ========================================================
// Persistence: DB + Fallback
// ========================================================
public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;

    g_SoundSelect[client]   = 0;
    g_OverlayEnable[client] = GetConVarBool(cv_overlay_default);

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
    {
        char sid[64];
        GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);

        char q[256];
        Format(q, sizeof(q),
            "SELECT hitsound_cfg, hitsound_overlay FROM rpg_player WHERE steamid='%s' LIMIT 1;", sid);
        SQL_TQuery(g_hDB, SQL_OnLoadPrefs, q, GetClientUserId(client));
    }
    else
    {
        KV_LoadPlayer(client);
    }
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
        DB_SavePlayerPrefs(client);
    else
        KV_SavePlayer(client);

    if (g_taskClean[client] != INVALID_HANDLE)
    {
        KillTimer(g_taskClean[client]);
        g_taskClean[client] = INVALID_HANDLE;
    }
}

public void SQL_OnLoadPrefs(Handle owner, Handle hndl, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;

    if (hndl == INVALID_HANDLE)
    {
        LogError("[hitsound] 加载玩家配置失败: %s", error);
        KV_LoadPlayer(client);
        return;
    }

    if (SQL_GetRowCount(hndl) > 0 && SQL_FetchRow(hndl))
    {
        int cfg = SQL_FetchInt(hndl, 0);
        int ov  = SQL_FetchInt(hndl, 1);
        g_SoundSelect[client]   = (cfg >= 0 && cfg < g_SetCount) ? cfg : 0;
        g_OverlayEnable[client] = (ov != 0);
    }
    else
    {
        DB_SavePlayerPrefs(client); // 首次：写入默认
    }
}

void DB_SavePlayerPrefs(int client)
{
    if (g_hDB == INVALID_HANDLE) return;

    char sid[64];
    GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);

    int cfg = g_SoundSelect[client];
    int ov  = g_OverlayEnable[client] ? 1 : 0;

    char q[384];
    Format(q, sizeof(q),
        "INSERT INTO RPG (steamid, hitsound_cfg, hitsound_overlay) VALUES ('%s', %d, %d) ON DUPLICATE KEY UPDATE hitsound_cfg=VALUES(hitsound_cfg), hitsound_overlay=VALUES(hitsound_overlay);",
        sid, cfg, ov);

    SQL_TQuery(g_hDB, SQL_OnSavePrefs, q);
}

public void SQL_OnSavePrefs(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE)
        LogError("[hitsound] 保存玩家配置失败: %s", error);
}

// KeyValues fallback
void KV_SavePlayer(int client)
{
    char uid[128] = "";
    GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true);

    KvJumpToKey(g_SoundStore, uid, true);
    KvSetNum(g_SoundStore, "Snd", g_SoundSelect[client]);
    KvSetNum(g_SoundStore, "Overlay", g_OverlayEnable[client] ? 1 : 0);
    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
    KeyValuesToFile(g_SoundStore, g_SavePath);
}

void KV_LoadPlayer(int client)
{
    char uid[128] = "";
    GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true);

    KvJumpToKey(g_SoundStore, uid, true);
    g_SoundSelect[client]   = KvGetNum(g_SoundStore, "Snd", 0);
    g_OverlayEnable[client] = KvGetNum(g_SoundStore, "Overlay", GetConVarBool(cv_overlay_default) ? 1 : 0) != 0;
    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
}

// ========================================================
// Helpers
// ========================================================
bool GetSoundPath(int setId, int which, char[] out, int maxlen)
{
    // which: 0=headshot, 1=hit, 2=kill
    if (setId <= 0 || setId >= g_SetCount) { out[0] = '\0'; return false; }

    if (which == 0)      GetArrayString(g_SetHeadshot, setId, out, maxlen);
    else if (which == 1) GetArrayString(g_SetHit, setId, out, maxlen);
    else                 GetArrayString(g_SetKill, setId, out, maxlen);

    return (out[0] != '\0');
}

// which: 0=head, 1=hit, 2=kill ; 返回 false 表示“全局禁用/缺失”
static bool GetOverlayBase_Global(int which, char[] out, int maxlen)
{
    new set = GetConVarInt(cv_overlay_set); // 0=禁用
    if (set <= 0) { out[0] = 0; return false; }

    new idx = set - 1;
    if (idx < 0 || idx >= g_OvCount) { out[0] = 0; return false; }

    if (which == 0)      GetArrayString(g_OvHead, idx, out, maxlen);
    else if (which == 1) GetArrayString(g_OvHit,  idx, out, maxlen);
    else                 GetArrayString(g_OvKill, idx, out, maxlen);

    return (out[0] != 0);
}

// ========================================================
// Commands & Menu
// ========================================================
public Action Cmd_ToggleUI(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;
    g_OverlayEnable[client] = !g_OverlayEnable[client];
    PrintToChat(client, "覆盖图标: %s", g_OverlayEnable[client] ? "开启" : "关闭");

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE) DB_SavePlayerPrefs(client);
    else KV_SavePlayer(client);

    return Plugin_Handled;
}

public Action Cmd_MenuSnd(int client, int args)
{
    Handle menu = CreateMenu(MenuHandler_Main);
    char title[128];
    Format(title, sizeof(title), "命中反馈设置 | 当前音效套装: %d", g_SoundSelect[client]);
    SetMenuTitle(menu, title);

    // 覆盖图标个人开关
    char overlayLabel[64];
    Format(overlayLabel, sizeof(overlayLabel), "覆盖图标: %s (点击切换)",
        g_OverlayEnable[client] ? "开启" : "关闭");
    AddMenuItem(menu, "overlay_toggle", overlayLabel);

    // 显示全局图标套装信息（只读）
    if (g_OvCount > 0)
    {
        char ovname[64] = "禁用";
        int ovset = GetConVarInt(cv_overlay_set);
        if (ovset >= 1 && ovset <= g_OvCount)
            GetArrayString(g_OvNames, ovset-1, ovname, sizeof(ovname));
        char info[96]; Format(info, sizeof(info), "全局图标套装: %d - %s", ovset, ovname);
        AddMenuItem(menu, "ov_info", info, ITEMDRAW_DISABLED);
    }

    AddMenuItem(menu, "sep", "----------------", ITEMDRAW_DISABLED);

    // 音效套装列表（0..g_SetCount-1）
    for (int i = 0; i < g_SetCount; i++)
    {
        char idx[8]; IntToString(i, idx, sizeof(idx));
        char name[64]; GetArrayString(g_SetNames, i, name, sizeof(name));
        AddMenuItem(menu, idx, name);
    }

    SetMenuExitButton(menu, true);
    DisplayMenu(menu, client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Main(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }

    if (action == MenuAction_Select)
    {
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));

        if (StrEqual(info, "overlay_toggle"))
        {
            g_OverlayEnable[client] = !g_OverlayEnable[client];
            PrintToChat(client, "覆盖图标: %s", g_OverlayEnable[client] ? "开启" : "关闭");

            if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE) DB_SavePlayerPrefs(client);
            else KV_SavePlayer(client);

            // 重新显示菜单
            Cmd_MenuSnd(client, 0);
            return 0;
        }

        int choice = StringToInt(info);
        if (choice < 0 || choice >= g_SetCount) choice = 0;

        g_SoundSelect[client] = choice;
        PrintToChat(client, "已选择音效套装: %d", g_SoundSelect[client]);

        if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE) DB_SavePlayerPrefs(client);
        else KV_SavePlayer(client);
    }
    return 0;
}

// ========================================================
// Events
// ========================================================
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0 && client <= MaxClients)
        g_IsVictimDeadPlayer[client] = false;
}

public Action Event_PlayerIncap(Handle event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(victim) && GetClientTeam(victim) == 3 && GetEntProp(victim, Prop_Send, "m_zombieClass") == 8)
        g_IsVictimDeadPlayer[victim] = true;
    return Plugin_Continue;
}

public Action Event_TankSpawn(Handle event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(tank))
        g_IsVictimDeadPlayer[tank] = false;
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
    int victim     = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    bool headshot  = GetEventBool(event, "headshot");
    int  damagetype= GetEventInt(event, "type");

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && GetClientTeam(victim) == 3 &&
        IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        // 覆盖图（受三层控制：全局开关、全局套装非0、个人开关）
        if (GetConVarInt(cv_pic_enable) == 1 && GetConVarInt(cv_overlay_set) >= 1 && g_OverlayEnable[attacker])
        {
            ShowOverlay(attacker, headshot ? KILL_HEADSHOT : KILL_NORMAL);
        }

        // 音效
        if (GetConVarInt(cv_sound_enable) == 1)
        {
            char s[PLATFORM_MAX_PATH];
            if (headshot)
            {
                if (GetSoundPath(g_SoundSelect[attacker], 0, s, sizeof(s)))
                {
                    PrecacheSound(s, true);
                    EmitSoundToClient(attacker, s, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
            else
            {
                if (GetSoundPath(g_SoundSelect[attacker], 2, s, sizeof(s)))
                {
                    PrecacheSound(s, true);
                    EmitSoundToClient(attacker, s, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
        }
    }

    return Plugin_Continue;
}

public Action Event_PlayerHurt(Handle event, const char[] name, bool dontBroadcast)
{
    int victim     = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    int dmg        = GetEventInt(event, "dmg_health");
    int health     = GetEventInt(event, "health");
    int damagetype = GetEventInt(event, "type");

    char weapon[64]; GetEventString(event, "weapon", weapon, sizeof(weapon));
    bool inferno = (StrEqual(weapon, "entityflame", false) || StrEqual(weapon, "inferno", false));

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && IsValidClient(attacker) && !IsFakeClient(attacker) && GetClientTeam(victim) == 3)
    {
        float AddDamage = 0.0;
        if (RoundToNearest(float(health - dmg) - AddDamage) <= 0.0)
            g_IsVictimDeadPlayer[victim] = true;

        if (!g_IsVictimDeadPlayer[victim])
        {
            if (GetConVarInt(cv_pic_enable) == 1 && GetConVarInt(cv_overlay_set) >= 1 && g_OverlayEnable[attacker])
            {
                ShowOverlay(attacker, HIT_ARMOR);
            }

            if (GetConVarInt(cv_sound_enable) == 1 && !inferno)
            {
                char s2[PLATFORM_MAX_PATH];
                if (GetSoundPath(g_SoundSelect[attacker], 1, s2, sizeof(s2)))
                {
                    PrecacheSound(s2, true);
                    EmitSoundToClient(attacker, s2, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
        }
    }
    return Plugin_Changed;
}

public Action Event_InfectedDeath(Handle event, const char[] name, bool dontBroadcast)
{
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    bool headshot  = GetEventBool(event, "headshot");
    bool blast     = GetEventBool(event, "blast");
    int  weaponID  = GetEventInt(event, "weapon_id");

    if (weaponID == 0) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && blast) return Plugin_Changed;

    if (IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        if (GetConVarInt(cv_pic_enable) == 1 && GetConVarInt(cv_overlay_set) >= 1 && g_OverlayEnable[attacker])
        {
            ShowOverlay(attacker, headshot ? KILL_HEADSHOT : KILL_NORMAL);
        }

        if (GetConVarInt(cv_sound_enable) == 1)
        {
            char s[PLATFORM_MAX_PATH];
            if (headshot)
            {
                if (GetSoundPath(g_SoundSelect[attacker], 0, s, sizeof(s)))
                {
                    PrecacheSound(s, true);
                    EmitSoundToClient(attacker, s, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
            else
            {
                if (GetSoundPath(g_SoundSelect[attacker], 2, s, sizeof(s)))
                {
                    PrecacheSound(s, true);
                    EmitSoundToClient(attacker, s, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
        }
    }
    return Plugin_Continue;
}

public Action Event_InfectedHurt(Handle event, const char[] name, bool dontBroadcast)
{
    int victim     = GetEventInt(event, "entityid");
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    int dmg        = GetEventInt(event, "amount");
    int hp         = GetEntProp(victim, Prop_Data, "m_iHealth");
    int damagetype = GetEventInt(event, "type");

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(cv_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(attacker) && !IsFakeClient(attacker))
    {
        bool dead = ((hp - dmg) <= 0);

        if (!dead)
        {
            if (GetConVarInt(cv_pic_enable) == 1 && GetConVarInt(cv_overlay_set) >= 1 && g_OverlayEnable[attacker])
            {
                ShowOverlay(attacker, HIT_ARMOR);
            }

            if (GetConVarInt(cv_sound_enable) == 1)
            {
                char s2[PLATFORM_MAX_PATH];
                if (GetSoundPath(g_SoundSelect[attacker], 1, s2, sizeof(s2)))
                {
                    PrecacheSound(s2, true);
                    EmitSoundToClient(attacker, s2, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }
        }
    }
    return Plugin_Changed;
}

public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    // 清理残留计时器
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_taskClean[i] != INVALID_HANDLE)
        {
            KillTimer(g_taskClean[i]);
            g_taskClean[i] = INVALID_HANDLE;
        }
    }
}

// ========================================================
// Overlay show/clean
// ========================================================
public ShowOverlay(int client, OverlayType type)
{
    // 全局禁用直接返回
    if (GetConVarInt(cv_overlay_set) <= 0)
        return;

    // 取三张贴图基名
    char head[PLATFORM_MAX_PATH];
    char hit [PLATFORM_MAX_PATH];
    char kill[PLATFORM_MAX_PATH];
    if (!GetOverlayBase_Global(0, head, sizeof(head))) return;
    if (!GetOverlayBase_Global(1, hit,  sizeof(hit ))) return;
    if (!GetOverlayBase_Global(2, kill, sizeof(kill))) return;

    // 预缓存
    char path[PLATFORM_MAX_PATH];
    Format(path, sizeof(path), "%s.vtf", head); PrecacheDecal(path, true);
    Format(path, sizeof(path), "%s.vtf", hit ); PrecacheDecal(path, true);
    Format(path, sizeof(path), "%s.vtf", kill); PrecacheDecal(path, true);
    Format(path, sizeof(path), "%s.vmt", head); PrecacheDecal(path, true);
    Format(path, sizeof(path), "%s.vmt", hit ); PrecacheDecal(path, true);
    Format(path, sizeof(path), "%s.vmt", kill); PrecacheDecal(path, true);

    // 解除 cheat 标志并应用
    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);

    char useBase[PLATFORM_MAX_PATH];
    if (type == KILL_HEADSHOT)
        strcopy(useBase, sizeof(useBase), head);
    else if (type == KILL_NORMAL)
        strcopy(useBase, sizeof(useBase), kill);
    else
        strcopy(useBase, sizeof(useBase), hit);

    ClientCommand(client, "r_screenoverlay \"%s\"", useBase);

    // 只在显示时创建清理定时器
    if (g_taskClean[client] != INVALID_HANDLE)
    {
        KillTimer(g_taskClean[client]);
        g_taskClean[client] = INVALID_HANDLE;
    }
    float t = GetConVarFloat(cv_showtime);
    g_taskClean[client] = CreateTimer(t, Timer_CleanOverlay, client);
}

public Action Timer_CleanOverlay(Handle timer, int client)
{
    g_taskClean[client] = INVALID_HANDLE;

    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);
    ClientCommand(client, "r_screenoverlay \"\"");

    return Plugin_Stop;
}