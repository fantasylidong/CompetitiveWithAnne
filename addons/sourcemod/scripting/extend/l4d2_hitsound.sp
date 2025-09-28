/** 
 * l4d2_hitsound_plus.sp
 *
 * - 多套音效配置（configs/hitsound_sets.cfg）支持 builtin=1 跳过 FastDL
 * - 覆盖图标“套装”按玩家各自选择（configs/hiticon_sets.cfg），0=禁用
 * - 仅两列写库：hitsound_cfg（音效套装编号）、hitsound_overlay（图标套装编号，0=禁用）
 * - DB 失败时回退到 KeyValues 文件 data/SoundSelect.txt（键：Snd, Overlay）
 * - FastDL 自动登记（音频=sound/…；图标=materials/…），builtin=1 时跳过
 * - RegPluginLibrary 供其他插件检测：l4d2_hitsound_plus（兼容别名 l4d2_hitsound）
 * - SQL_TConnect 固定用：SQL_TConnect(SQL_OnConnect, confName, 0);
 *
 * SQL（示例，仅两列，确保 steamid 唯一）:
 *   ALTER TABLE `rpg`
 *     ADD COLUMN `hitsound_cfg` TINYINT NOT NULL DEFAULT 0,
 *     ADD COLUMN `hitsound_overlay` TINYINT NOT NULL DEFAULT 0,
 *     ADD UNIQUE KEY `uniq_steamid` (`steamid`);
 *
 * commands:
 *   !snd    -> 主菜单（音效套装（玩家） / 图标套装（玩家） / 覆盖图开关）
 *   !hitui  -> 快速在“禁用/套装1”之间切换覆盖图
 *   sm_hitsound_reload -> 重新从 DB/KV 读取所有在线玩家的偏好
 */

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <adminmenu>

#define PLUGIN_VERSION "1.4.2"
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
ConVar cv_debug; // 调试总开关
ConVar cv_sound_enable;
ConVar cv_pic_enable;     // 全局启/停覆盖图功能（大总开关）
ConVar cv_blast;
ConVar cv_showtime;
// 新玩家默认是否启用覆盖图：1=给默认套装1（若存在），0=默认禁用
ConVar cv_overlay_default_enable;

ConVar cv_db_enable;
ConVar cv_db_conf;
ConVar cv_db_table;       // 新增：可配置表名（默认 rpg_player）

// --------------------- State ---------------------
int  g_SoundSelect[MAXPLAYERS + 1]   = {0, ...}; // 玩家选的音效套装编号（0=禁用；>=1）
int  g_OverlaySet[MAXPLAYERS + 1]    = {0, ...}; // 玩家选的覆盖图套装（0=禁用；>=1）

// 新增：加载/脏标志，避免默认值误写库
bool g_PrefsLoaded[MAXPLAYERS + 1] = { false, ... };
bool g_PrefsDirty [MAXPLAYERS + 1] = { false, ... };

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

// --------------------- Overlay icon sets（玩家自选） ---------------------
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
    description = "音效套装(玩家) + 覆盖图标套装(玩家,0禁用) + 两列表存取 + FDL",
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

    cv_enable                 = CreateConVar("sm_hitsound_enable", "1", "是否开启本插件(0关,1开)", CVAR_FLAGS);
    cv_sound_enable           = CreateConVar("sm_hitsound_sound_enable", "1", "是否开启音效(0关,1开)", CVAR_FLAGS);
    cv_pic_enable             = CreateConVar("sm_hitsound_pic_enable", "1", "是否开启覆盖图标(0关,1开 总开关)", CVAR_FLAGS);
    cv_blast                  = CreateConVar("sm_blast_damage_enable", "0", "是否开启爆炸反馈提示(0关,1开 建议关)", CVAR_FLAGS);
    cv_showtime               = CreateConVar("sm_hitsound_showtime", "0.3", "覆盖图标显示时长(秒)", CVAR_FLAGS);
    cv_overlay_default_enable = CreateConVar("sm_hitsound_overlay_default", "1", "新玩家默认是否启用覆盖图(1给套装1,0禁用)", CVAR_FLAGS);

    cv_db_enable              = CreateConVar("sm_hitsound_db_enable", "1", "是否启用 RPG 表存储(1启用,0禁用)", CVAR_FLAGS);
    cv_db_conf                = CreateConVar("sm_hitsound_db_conf", "rpg", "databases.cfg 中的连接名", CVAR_FLAGS);
    cv_db_table               = CreateConVar("sm_hitsound_db_table", "RPG", "存储表名", CVAR_FLAGS);
    cv_debug                  = CreateConVar("sm_hitsound_debug", "1", "调试输出(0关,1开)", CVAR_FLAGS);

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
        SQL_TConnect(SQL_OnConnect, confName, 0); // 固定签名
    }

    RegConsoleCmd("sm_snd",   Cmd_MenuMain, "主菜单：音效套装（玩家）/ 图标套装（玩家）/ 覆盖图开关");
    RegConsoleCmd("sm_hitui", Cmd_ToggleUI,  "快速在禁用与套装1间切换覆盖图");
    RegAdminCmd ("sm_hitsound_reload", Cmd_ReloadAll, ADMFLAG_ROOT, "重新从 DB/KV 读取所有在线玩家的偏好");

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

// 在执行完 cfg（例如加载模式/exec zonemod/药抗）后，重新加载在线玩家的偏好
public void OnConfigsExecuted()
{
    ReloadAllPlayersPrefs();
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

    // 插件重载/晚加载时，在线玩家不会触发 OnClientPutInServer，这里主动补一次
    ReloadAllPlayersPrefs();
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
            DBG("SoundSet #%d '%s' builtin=%d hs='%s' hit='%s' kill='%s'",
                g_SetCount, name, isbuiltin, sh, hi, ki);

            PushArrayString(g_SetNames, name);
            PushArrayString(g_SetHeadshot, sh);
            PushArrayString(g_SetHit, hi);
            PushArrayString(g_SetKill, ki);
            g_SetCount++;

            if (!isbuiltin)
            {
                if (sh[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", sh); DBG("FDL add: %s", p); AddFileToDownloadsTable(p); }
                if (hi[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", hi); DBG("FDL add: %s", p); AddFileToDownloadsTable(p); }
                if (ki[0] != '\0') { char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", ki); DBG("FDL add: %s", p); AddFileToDownloadsTable(p); }
            }
            else
            {
                if (sh[0] != '\0') DBG("FDL skip(builtin): sound/%s", sh);
                if (hi[0] != '\0') DBG("FDL skip(builtin): sound/%s", hi);
                if (ki[0] != '\0') DBG("FDL skip(builtin): sound/%s", ki);
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 套音效配置。", g_SetCount);
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
        LogMessage("[hitsound] 未找到 hiticon_sets.cfg，玩家只能选择禁用(0)。");
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
            // 支持 headshot/head
            KvGetString(kv, "head", head, sizeof(head), "");
            if (head[0] == '\0') KvGetString(kv, "headshot", head, sizeof(head), "");
            KvGetString(kv, "hit",  hit,  sizeof(hit),  "");
            KvGetString(kv, "kill", kill, sizeof(kill), "");
            DBG("IconSet  #%d '%s' builtin=%d head='%s' hit='%s' kill='%s'",
                g_OvCount+1, name, isbuiltin, head, hit, kill);

            isbuiltin = KvGetNum(kv, "builtin", 0);

            PushArrayString(g_OvNames, name);
            PushArrayString(g_OvHead, head);
            PushArrayString(g_OvHit, hit);
            PushArrayString(g_OvKill, kill);
            g_OvCount++;

            if (!isbuiltin)
            {
                if (head[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", head); DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", head); DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
                if (hit[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", hit);  DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", hit);  DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
                if (kill[0] != '\0') {
                    char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", kill); DBG("FDL add: %s", p1); AddFileToDownloadsTable(p1);
                    char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", kill); DBG("FDL add: %s", p2); AddFileToDownloadsTable(p2);
                }
            }
            else
            {
                if (head[0] != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", head); DBG("FDL skip(builtin): materials/%s.vtf", head); }
                if (hit[0]  != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", hit ); DBG("FDL skip(builtin): materials/%s.vtf", hit ); }
                if (kill[0] != '\0') { DBG("FDL skip(builtin): materials/%s.vmt", kill); DBG("FDL skip(builtin): materials/%s.vtf", kill); }
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 套图标覆盖主题（玩家自选, 0=禁用）。", g_OvCount);
}

// ========================================================
// Persistence: DB + Fallback
// ========================================================
public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;

    g_SoundSelect[client] = 0;

    // 默认覆盖图：若启用且有套装，则给 1，否则 0
    if (GetConVarBool(cv_overlay_default_enable) && g_OvCount >= 1)
        g_OverlaySet[client] = 1;
    else
        g_OverlaySet[client] = 0;

    // 初始化标志
    g_PrefsLoaded[client] = false;
    g_PrefsDirty [client] = false;

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
    {
        DB_RequestLoadPlayer(client);
    }
    else
    {
        KV_LoadPlayer(client);
        g_PrefsLoaded[client] = true; // 使用 KV 路径也算已加载
        g_PrefsDirty [client] = false;
    }
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
    {
        if (g_PrefsLoaded[client] && g_PrefsDirty[client])
        {
            DB_SavePlayerPrefs(client);
        }
    }
    else
    {
        if (g_PrefsDirty[client])
        {
            KV_SavePlayer(client);
        }
    }

    if (g_taskClean[client] != INVALID_HANDLE)
    {
        KillTimer(g_taskClean[client]);
        g_taskClean[client] = INVALID_HANDLE;
    }

    g_PrefsLoaded[client] = false;
    g_PrefsDirty [client] = false;
}

// 主动为一个玩家发起 DB 读取
public void DB_RequestLoadPlayer(int client)
{
    char sid[64];
    GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);

    char table[64];
    GetConVarString(cv_db_table, table, sizeof(table));

    char q[384];
    Format(q, sizeof(q),
        "SELECT hitsound_cfg, hitsound_overlay FROM `%s` WHERE steamid='%s' LIMIT 1;",
        table, sid);
    SQL_TQuery(g_hDB, SQL_OnLoadPrefs, q, GetClientUserId(client));
}

// 为所有在线玩家重新加载偏好（插件重载 / 执行模式 cfg 后调用）
public void ReloadAllPlayersPrefs()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        g_PrefsLoaded[i] = false;
        g_PrefsDirty [i] = false;

        if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE)
        {
            DB_RequestLoadPlayer(i);
        }
        else
        {
            KV_LoadPlayer(i);
            g_PrefsLoaded[i] = true;
            g_PrefsDirty [i] = false;
        }
    }
}
public void OnMapStart()
{
    DBG("OnMapStart: rebuild downloads table (soundSets=%d, iconSets=%d)", g_SetCount, g_OvCount);
    // 只负责把需要的文件丢进下载表；这两函数内部会做 AddFileToDownloadsTable
    LoadHitSoundSets();
    LoadHitIconSets();
    // 👇 加这一行：所有资源一次性 precache
    PrecacheAllAssets();
}
public void SQL_OnLoadPrefs(Handle owner, Handle hndl, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;

    if (hndl == INVALID_HANDLE)
    {
        LogError("[hitsound] 加载玩家配置失败: %s", error);
        KV_LoadPlayer(client);
        g_PrefsLoaded[client] = true;   // 视为完成加载
        g_PrefsDirty [client] = false;
        return;
    }

    if (SQL_GetRowCount(hndl) > 0 && SQL_FetchRow(hndl))
    {
        int cfg = SQL_FetchInt(hndl, 0);
        int ov  = SQL_FetchInt(hndl, 1);
        g_SoundSelect[client] = (cfg >= 0 && cfg < g_SetCount) ? cfg : 0;

        // 覆盖图套装编号（0=禁用；>=1），仅运行期夹紧，不立刻回写
        if (ov < 0) ov = 0;
        if (ov > g_OvCount) ov = 0; // 越界则禁用
        g_OverlaySet[client] = ov;

        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = false;
    }
    else
    {
        // 无行：不立即 insert，等玩家实际改动时再写库
        g_PrefsLoaded[client] = true;
        g_PrefsDirty [client] = false;
    }
}

void DB_SavePlayerPrefs(int client)
{
    if (g_hDB == INVALID_HANDLE) return;

    char sid[64];
    GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);

    int cfg = g_SoundSelect[client];
    int ov  = g_OverlaySet[client];

    char table[64];
    GetConVarString(cv_db_table, table, sizeof(table));

    char q[512];
    Format(q, sizeof(q),
        "INSERT INTO `%s` (steamid, hitsound_cfg, hitsound_overlay) VALUES ('%s', %d, %d) ON DUPLICATE KEY UPDATE hitsound_cfg=VALUES(hitsound_cfg), hitsound_overlay=VALUES(hitsound_overlay);",
        table, sid, cfg, ov);

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
    KvSetNum(g_SoundStore, "Overlay", g_OverlaySet[client]); // 0..g_OvCount
    KvGoBack(g_SoundStore);
    KvRewind(g_SoundStore);
    KeyValuesToFile(g_SoundStore, g_SavePath);
}

void KV_LoadPlayer(int client)
{
    char uid[128] = "";
    GetClientAuthId(client, AuthId_Engine, uid, sizeof(uid), true);

    KvJumpToKey(g_SoundStore, uid, true);
    g_SoundSelect[client] = KvGetNum(g_SoundStore, "Snd", 0);

    int defOv = (GetConVarBool(cv_overlay_default_enable) && g_OvCount >= 1) ? 1 : 0;
    g_OverlaySet[client]  = KvGetNum(g_SoundStore, "Overlay", defOv);
    if (g_OverlaySet[client] < 0 || g_OverlaySet[client] > g_OvCount)
        g_OverlaySet[client] = 0;

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

stock void DBG(const char[] fmt, any ...)
{
    if (!GetConVarBool(cv_debug)) return;
    char buf[512];
    VFormat(buf, sizeof(buf), fmt, 2); // 2 = 第一个可变参数位置
    LogMessage("[hitsound-dbg] %s", buf);
}

// 玩家专属覆盖图：which 0=head 1=hit 2=kill
static bool GetOverlayBase_Player(int client, int which, char[] out, int maxlen)
{
    int set = g_OverlaySet[client]; // 0=禁用
    if (set <= 0) { out[0] = '\0'; return false; }

    int idx = set - 1;
    if (idx < 0 || idx >= g_OvCount) { out[0] = '\0'; return false; }

    if (which == 0)      GetArrayString(g_OvHead, idx, out, maxlen);
    else if (which == 1) GetArrayString(g_OvHit,  idx, out, maxlen);
    else                 GetArrayString(g_OvKill, idx, out, maxlen);

    return (out[0] != '\0');
}

// ========================================================
// Commands & Menus
// ========================================================
public Action Cmd_ToggleUI(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Handled;

    // 0 <-> 1（若有套装）
    if (g_OverlaySet[client] > 0)
        g_OverlaySet[client] = 0;
    else
        g_OverlaySet[client] = (g_OvCount >= 1) ? 1 : 0;

    PrintToChat(client, "覆盖图标: %s", (g_OverlaySet[client] > 0) ? "开启" : "关闭");

    // 标记改动并保存（仅在已加载后写库，未加载时不写库以避免默认覆盖）
    g_PrefsDirty[client] = true;
    if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE && g_PrefsLoaded[client]) {
        DB_SavePlayerPrefs(client);
        g_PrefsDirty[client] = false;
    } else {
        KV_SavePlayer(client);
    }

    return Plugin_Handled;
}

public Action Cmd_ReloadAll(int client, int args)
{
    ReloadAllPlayersPrefs();
    if (client > 0)
        ReplyToCommand(client, "[hitsound] 已尝试重新读取所有在线玩家的设置。");
    return Plugin_Handled;
}

public Action Cmd_MenuMain(int client, int args)
{
    Handle menu = CreateMenu(MenuHandler_Main);
    char title[128];

    char curSnd[64] = "禁用";
    if (g_SoundSelect[client] >= 0 && g_SoundSelect[client] < g_SetCount)
        GetArrayString(g_SetNames, g_SoundSelect[client], curSnd, sizeof(curSnd));

    char curOv[64] = "禁用";
    if (g_OverlaySet[client] >= 1 && g_OverlaySet[client] <= g_OvCount)
        GetArrayString(g_OvNames, g_OverlaySet[client]-1, curOv, sizeof(curOv));

    Format(title, sizeof(title), "命中反馈设置\n音效: %d - %s | 图标: %d - %s",g_SoundSelect[client], curSnd, g_OverlaySet[client], curOv);
    SetMenuTitle(menu, title);

    AddMenuItem(menu, "sound_sets", "音效套装（玩家）");
    AddMenuItem(menu, "icon_sets",  "图标套装（玩家）");

    char overlayLabel[64];
    Format(overlayLabel, sizeof(overlayLabel), "覆盖图标: %s (点此快速开关)",
        (g_OverlaySet[client] > 0) ? "开启" : "关闭");
    AddMenuItem(menu, "overlay_toggle", overlayLabel);

    SetMenuExitButton(menu, true);
    DisplayMenu(menu, client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_Main(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }

    if (action == MenuAction_Select)
    {
        char info[32]; GetMenuItem(menu, item, info, sizeof(info));

        if (StrEqual(info, "sound_sets"))
        {
            OpenSoundSetMenu(client);
            return 0;
        }
        if (StrEqual(info, "icon_sets"))
        {
            OpenIconSetMenu_Player(client);
            return 0;
        }
        if (StrEqual(info, "overlay_toggle"))
        {
            if (g_OverlaySet[client] > 0) g_OverlaySet[client] = 0;
            else g_OverlaySet[client] = (g_OvCount >= 1) ? 1 : 0;

            PrintToChat(client, "覆盖图标: %s", (g_OverlaySet[client] > 0) ? "开启" : "关闭");

            g_PrefsDirty[client] = true;
            if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE && g_PrefsLoaded[client]) {
                DB_SavePlayerPrefs(client);
                g_PrefsDirty[client] = false;
            } else {
                KV_SavePlayer(client);
            }

            Cmd_MenuMain(client, 0);
            return 0;
        }
    }
    return 0;
}

// 子菜单：音效套装（玩家）
static void OpenSoundSetMenu(int client)
{
    Handle m = CreateMenu(MenuHandler_SndSets);
    char title[96], curName[64] = "禁用";
    if (g_SoundSelect[client] >= 0 && g_SoundSelect[client] < g_SetCount)
        GetArrayString(g_SetNames, g_SoundSelect[client], curName, sizeof(curName));
    Format(title, sizeof(title), "选择音效套装（当前: %d - %s）", g_SoundSelect[client], curName);
    SetMenuTitle(m, title);

    for (int i = 0; i < g_SetCount; i++)
    {
        char key[8], name[64], label[96];
        IntToString(i, key, sizeof(key));
        GetArrayString(g_SetNames, i, name, sizeof(name));
        Format(label, sizeof(label), "%d - %s", i, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_SndSets(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));
        int choice = StringToInt(info);
        if (choice < 0 || choice >= g_SetCount) choice = 0;

        g_SoundSelect[client] = choice;
        PrintToChat(client, "已选择音效套装: %d", g_SoundSelect[client]);

        g_PrefsDirty[client] = true;
        if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE && g_PrefsLoaded[client]) {
            DB_SavePlayerPrefs(client);
            g_PrefsDirty[client] = false;
        } else {
            KV_SavePlayer(client);
        }

        OpenSoundSetMenu(client);
    }
    return 0;
}

// 子菜单：图标套装（玩家）
static void OpenIconSetMenu_Player(int client)
{
    Handle m = CreateMenu(MenuHandler_OvSets_Player);
    char title[96], curName[64] = "禁用";
    if (g_OverlaySet[client] >= 1 && g_OverlaySet[client] <= g_OvCount)
        GetArrayString(g_OvNames, g_OverlaySet[client]-1, curName, sizeof(curName));
    Format(title, sizeof(title), "选择图标套装（当前: %d - %s）", g_OverlaySet[client], curName);
    SetMenuTitle(m, title);

    AddMenuItem(m, "ov_0", "0 - 禁用覆盖图标");
    for (int i = 0; i < g_OvCount; i++)
    {
        char key[16], name[64], label[96];
        Format(key, sizeof(key), "ov_%d", i+1);
        GetArrayString(g_OvNames, i, name, sizeof(name));
        Format(label, sizeof(label), "%d - %s", i+1, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
}

public int MenuHandler_OvSets_Player(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        Cmd_MenuMain(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));
        if (StrContains(info, "ov_", false) == 0)
        {
            ReplaceString(info, sizeof(info), "ov_", "");
            int val = StringToInt(info); // 0..g_OvCount
            if (val < 0) val = 0;
            if (val > g_OvCount) val = 0; // 越界视为禁用

            g_OverlaySet[client] = val;

            char name[64] = "禁用";
            if (val >= 1 && val <= g_OvCount) GetArrayString(g_OvNames, val-1, name, sizeof(name));
            PrintToChat(client, "[Hitsound] 你的图标套装已设置为: %d - %s", val, name);

            g_PrefsDirty[client] = true;
            if (GetConVarBool(cv_db_enable) && g_hDB != INVALID_HANDLE && g_PrefsLoaded[client]) {
                DB_SavePlayerPrefs(client);
                g_PrefsDirty[client] = false;
            } else {
                KV_SavePlayer(client);
            }

            OpenIconSetMenu_Player(client);
        }
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
        // 覆盖图（受：全局总开关 + 玩家套装编号>0）
        if (GetConVarInt(cv_pic_enable) == 1 && g_OverlaySet[attacker] > 0)
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
            if (GetConVarInt(cv_pic_enable) == 1 && g_OverlaySet[attacker] > 0)
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
        if (GetConVarInt(cv_pic_enable) == 1 && g_OverlaySet[attacker] > 0)
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
            if (GetConVarInt(cv_pic_enable) == 1 && g_OverlaySet[attacker] > 0)
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
void ShowOverlay(int client, OverlayType type)
{
    if (GetConVarInt(cv_pic_enable) == 0) return;
    if (g_OverlaySet[client] <= 0) return;

    // 只取这次要用的那一张
    int which = (type == KILL_HEADSHOT) ? 0 : (type == HIT_ARMOR ? 1 : 2);

    char base[PLATFORM_MAX_PATH];
    if (!GetOverlayBase_Player(client, which, base, sizeof(base))) {
        DBG("Overlay missing: set=%d which=%d", g_OverlaySet[client], which);
        return;
    }

    // 预缓存仅此一张
    char vmt[PLATFORM_MAX_PATH], vtf[PLATFORM_MAX_PATH];
    Format(vmt, sizeof(vmt), "%s.vmt", base);
    Format(vtf, sizeof(vtf), "%s.vtf", base);
    PrecacheDecal(vmt, true);
    PrecacheDecal(vtf, true);

    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);
    ClientCommand(client, "r_screenoverlay \"%s\"", base);

    if (g_taskClean[client] != INVALID_HANDLE) {
        KillTimer(g_taskClean[client]);
        g_taskClean[client] = INVALID_HANDLE;
    }
    float t = GetConVarFloat(cv_showtime);
    g_taskClean[client] = CreateTimer(t, Timer_CleanOverlay, client);
}

// 在 .sp 顶部现有变量的基础上新增
static void PrecacheAllAssets()
{
    // ---- Sounds ----
    char s[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_SetCount; i++)
    {
        GetArrayString(g_SetHeadshot, i, s, sizeof(s));
        if (s[0]) PrecacheSound(s, true);

        GetArrayString(g_SetHit, i, s, sizeof(s));
        if (s[0]) PrecacheSound(s, true);

        GetArrayString(g_SetKill, i, s, sizeof(s));
        if (s[0]) PrecacheSound(s, true);
    }

    // ---- Overlays (materials) ----
    char b[PLATFORM_MAX_PATH], vmt[PLATFORM_MAX_PATH], vtf[PLATFORM_MAX_PATH];
    for (int j = 0; j < g_OvCount; j++)
    {
        GetArrayString(g_OvHead, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }

        GetArrayString(g_OvHit, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }

        GetArrayString(g_OvKill, j, b, sizeof(b));
        if (b[0]) {
            Format(vmt, sizeof(vmt), "%s.vmt", b); PrecacheDecal(vmt, true);
            Format(vtf, sizeof(vtf), "%s.vtf", b); PrecacheDecal(vtf, true);
        }
    }

    DBG("PrecacheAllAssets done: soundSets=%d, iconSets=%d", g_SetCount, g_OvCount);
}

public Action Timer_CleanOverlay(Handle timer, int client)
{
    g_taskClean[client] = INVALID_HANDLE;

    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);
    ClientCommand(client, "r_screenoverlay \"\" ");

    return Plugin_Stop;
}
