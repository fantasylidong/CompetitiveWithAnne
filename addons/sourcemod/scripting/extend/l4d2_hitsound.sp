/**
 * l4d2_hitsound_plus.sp
 *
 * Features:
 * - Multi SOUND sets from configs/hitsound_sets.cfg (0 = disabled).
 * - Overlay ICON sets from configs/hiticon_sets.cfg with DIRECT IDs:
 *     0 = disabled (no overlay)
 *     1..N = the same numeric keys in hiticon_sets.cfg
 * - Save/Load from RPG DB (hitsound_cfg, hitsound_overlay_set), fallback to KeyValues file.
 * - Auto FastDL registration for sound files (hitsound_sets) and materials (hiticon_sets).
 * - Commands: !snd (menu), !hitui (toggle overlay between 0 and last non-zero).
 * - Library registration via RegPluginLibrary; optional native for version.
 *
 * -------------------------------------------------------------------
 * SQL (MySQL) migration (SINGLE-COLUMN overlay):
 * -------------------------------------------------------------------
 * -- If not present yet:
 * ALTER TABLE `rpg`
 *   ADD COLUMN `hitsound_cfg` TINYINT NOT NULL DEFAULT 0,
 *   ADD COLUMN `hitsound_overlay_set` TINYINT NOT NULL DEFAULT 0;
 *
 *
 */

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <adminmenu>

#define PLUGIN_VERSION "1.3.0"
#define CVAR_FLAGS     FCVAR_NOTIFY

#define IsValidClient(%1) (1 <= %1 <= MaxClients && IsClientInGame(%1))

// -----------------------------------------------------------
// Library registration (so RPG can detect us early)
// -----------------------------------------------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("l4d2_hitsound"); // compatibility alias (optional)
    CreateNative("HitsoundPlus_Version", Native_HitsoundPlus_Version);
    return APLRes_Success;
}
public any Native_HitsoundPlus_Version(Handle plugin, int numParams) { return 10300; }

// -----------------------------------------------------------
// Globals: ConVars & handles
// -----------------------------------------------------------
Handle SoundStore = INVALID_HANDLE; // KV fallback
ConVar plugin_enable;
ConVar sound_enable;
ConVar pic_enable;
ConVar g_blast;
ConVar g_cvDBEnabled;          // sm_hitsound_db_enable
ConVar g_cvDBConf;             // sm_hitsound_db_conf
ConVar Time;                   // sm_hitsound_showtime

// Per-player selection/state
int  SoundSelect[MAXPLAYERS + 1];     // SOUND set id (0 = disabled per sounds cfg)
int  g_OverlayTheme[MAXPLAYERS + 1];  // ICON set id (0 = disabled, 1..N = direct IDs)
int  g_LastNonZeroOv[MAXPLAYERS + 1]; // ephemeral: for !hitui quick toggle

// Old save file path (fallback)
char SavePath[256];

// Timers & helper per player
Handle g_taskCountdown[MAXPLAYERS + 1] = { INVALID_HANDLE, ... };
Handle g_taskClean[MAXPLAYERS + 1]     = { INVALID_HANDLE, ... };
int    g_killCount[MAXPLAYERS + 1]     = { 0, ... };
bool   g_bShowAuthor[MAXPLAYERS + 1]   = { false, ... };
bool   IsVictimDeadPlayer[MAXPLAYERS + 1] = { false, ... };

// SQL
Handle g_hDB = INVALID_HANDLE;

// SOUND sets (hitsound_sets.cfg) — using lists indexed by their numeric keys order.
// We'll also record their numeric IDs if you want strict mapping; but for sounds
// we allow 0..g_SetCount-1 compact indexing like before (0=disabled).
Handle g_SetNames    = INVALID_HANDLE;
Handle g_SetHeadshot = INVALID_HANDLE;
Handle g_SetHit      = INVALID_HANDLE;
Handle g_SetKill     = INVALID_HANDLE;
Handle g_SetIsBuiltin = INVALID_HANDLE; // 每套装一个 0/1
int    g_SetCount    = 0;

// ICON sets (hiticon_sets.cfg) — DIRECT numeric IDs mapping
Handle g_OvIds      = INVALID_HANDLE; // ArrayList<int> as string storage
Handle g_OvNames    = INVALID_HANDLE;
Handle g_OvHeadshot = INVALID_HANDLE; // materials base, no extension
Handle g_OvHit      = INVALID_HANDLE;
Handle g_OvKill     = INVALID_HANDLE;
int    g_OvCount    = 0;

// overlay enums for choosing which icon to show
enum { KILL_HEADSHOT = 0, HIT_ARMOR, KILL_NORMAL };

// -----------------------------------------------------------
// Plugin info
// -----------------------------------------------------------
public Plugin:myinfo =
{
    name = "L4D2 Hit/Kill Feedback Plus",
    author = "TsukasaSato , Hesh233 (branch) , merged by ChatGPT",
    description = "多套音效 + 图标套装(0=禁用,1..N直连配置) + RPG存取 + 文件回退",
    version = PLUGIN_VERSION
};

// -----------------------------------------------------------
// Lifecycle
// -----------------------------------------------------------
public void OnPluginStart()
{
    // Check game
    char Game_Name[64];
    GetGameFolderName(Game_Name, sizeof(Game_Name));
    if (!StrEqual(Game_Name, "left4dead2", false))
        SetFailState("本插件仅支持 L4D2!");

    CreateConVar("l4d2_hitsound_plus_ver", PLUGIN_VERSION, "Plugin version", 0);

    // Core ConVars
    plugin_enable = CreateConVar("sm_hitsound_enable", "1", "是否开启本插件(0-关, 1-开)", CVAR_FLAGS);
    sound_enable  = CreateConVar("sm_hitsound_sound_enable", "1", "是否开启音效(0-关, 1-开)", CVAR_FLAGS);
    pic_enable    = CreateConVar("sm_hitsound_pic_enable", "1", "是否开启击中/击杀图标(0-关, 1-开)", CVAR_FLAGS);
    g_blast       = CreateConVar("sm_blast_damage_enable", "0", "是否开启爆炸反馈提示(0-关, 1-开 建议关闭)", CVAR_FLAGS);
    Time          = CreateConVar("sm_hitsound_showtime", "0.3", "图标存在的时长(秒, 默认0.3)");

    // DB
    g_cvDBEnabled = CreateConVar("sm_hitsound_db_enable", "1", "是否启用 RPG 表存储（1=启用，0=禁用）", CVAR_FLAGS);
    g_cvDBConf    = CreateConVar("sm_hitsound_db_conf", "rpg", "databases.cfg 中的连接名", CVAR_FLAGS);

    // KV fallback file
    LoadSndData();

    // SOUND set arrays
    g_SetNames    = CreateArray(64);
    g_SetHeadshot = CreateArray(PLATFORM_MAX_PATH);
    g_SetHit      = CreateArray(PLATFORM_MAX_PATH);
    g_SetKill     = CreateArray(PLATFORM_MAX_PATH);
    g_SetIsBuiltin = CreateArray(1);
    LoadHitSoundSets();

    // ICON set arrays (direct ID mapping)
    g_OvIds      = CreateArray(16); // store IDs as strings we can convert; or store int via SetArrayCell
    g_OvNames    = CreateArray(64);
    g_OvHeadshot = CreateArray(PLATFORM_MAX_PATH);
    g_OvHit      = CreateArray(PLATFORM_MAX_PATH);
    g_OvKill     = CreateArray(PLATFORM_MAX_PATH);
    LoadHitIconSets();

    // DB connect (old-style signature)
    DB_InitIfEnabled();

    // Commands
    RegConsoleCmd("sm_snd",   MenuFunc_Snd, "设置音效/图标套装");

    AutoExecConfig(true, "l4d2_hitsound_plus");

    // Hooks
    if (GetConVarInt(plugin_enable) == 1)
    {
        HookEvent("infected_hurt",       Event_InfectedHurt,  EventHookMode_Pre);
        HookEvent("infected_death",      Event_InfectedDeath);
        HookEvent("player_death",        Event_PlayerDeath);
        HookEvent("player_hurt",         Event_PlayerHurt,    EventHookMode_Pre);
        HookEvent("tank_spawn",          Event_TankSpawn);
        HookEvent("player_spawn",        Event_Spawn);
        HookEvent("round_start",         Event_RoundStart,    EventHookMode_Post);
        HookEvent("player_incapacitated",PlayerIncap);
    }
}

public void OnMapEnd()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_taskCountdown[i] != INVALID_HANDLE) { KillTimer(g_taskCountdown[i]); g_taskCountdown[i] = INVALID_HANDLE; }
        if (g_taskClean[i]     != INVALID_HANDLE) { KillTimer(g_taskClean[i]);     g_taskClean[i]     = INVALID_HANDLE; }
    }
}

// -----------------------------------------------------------
// KV fallback
// -----------------------------------------------------------
void LoadSndData()
{
    SoundStore = CreateKeyValues("SoundSelect");
    BuildPath(Path_SM, SavePath, sizeof(SavePath), "data/SoundSelect.txt");
    if (FileExists(SavePath)) FileToKeyValues(SoundStore, SavePath);
    else KeyValuesToFile(SoundStore, SavePath);
}

// -----------------------------------------------------------
// DB init (OLD-STYLE order): SQL_TConnect(callback, confname, data)
// -----------------------------------------------------------
void DB_InitIfEnabled()
{
    if (!GetConVarBool(g_cvDBEnabled)) return;
    char conf[32]; GetConVarString(g_cvDBConf, conf, sizeof(conf));
    SQL_TConnect(SQL_OnConnect, conf, 0);
}
public void SQL_OnConnect(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE) { LogError("[hitsound] 数据库连接失败: %s", error); return; }
    g_hDB = hndl;
    LogMessage("[hitsound] 数据库连接成功。");
}

// -----------------------------------------------------------
// SOUND sets from hitsound_sets.cfg (keys: name/headshot/hit/kill)
// -----------------------------------------------------------
void LoadHitSoundSets()
{
    Handle kv = CreateKeyValues("HitSoundSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hitsound_sets.cfg"))
    {
        LogError("[hitsound] 无法读取 hitsound_sets.cfg，创建仅禁用选项");
        ClearArray(g_SetNames); ClearArray(g_SetHeadshot); ClearArray(g_SetHit); ClearArray(g_SetKill);
        if (g_SetIsBuiltin != INVALID_HANDLE) ClearArray(g_SetIsBuiltin);
        PushArrayString(g_SetNames, "禁用击中/击杀音效");
        PushArrayString(g_SetHeadshot, ""); PushArrayString(g_SetHit, ""); PushArrayString(g_SetKill, "");
        if (g_SetIsBuiltin != INVALID_HANDLE) PushArrayCell(g_SetIsBuiltin, 1);
        g_SetCount = 1; CloseHandle(kv); return;
    }

    ClearArray(g_SetNames); ClearArray(g_SetHeadshot); ClearArray(g_SetHit); ClearArray(g_SetKill);
    if (g_SetIsBuiltin != INVALID_HANDLE) ClearArray(g_SetIsBuiltin);

    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            char name[64], sh[PLATFORM_MAX_PATH], hi[PLATFORM_MAX_PATH], ki[PLATFORM_MAX_PATH];
            int isbuiltin = KvGetNum(kv, "builtin", 0);

            KvGetString(kv, "name",     name, sizeof(name), "未命名");
            KvGetString(kv, "headshot", sh,   sizeof(sh),   "");
            KvGetString(kv, "hit",      hi,   sizeof(hi),   "");
            KvGetString(kv, "kill",     ki,   sizeof(ki),   "");

            PushArrayString(g_SetNames,    name);
            PushArrayString(g_SetHeadshot, sh);
            PushArrayString(g_SetHit,      hi);
            PushArrayString(g_SetKill,     ki);
            if (g_SetIsBuiltin != INVALID_HANDLE) PushArrayCell(g_SetIsBuiltin, isbuiltin);

            // 只有“非内置 & 文件确实在服务器磁盘上”才加入 FastDL
            if (!isbuiltin && sh[0] != '\0') {
                char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", sh);
                if (FileExists(p)) AddFileToDownloadsTable(p);
            }
            if (!isbuiltin && hi[0] != '\0') {
                char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", hi);
                if (FileExists(p)) AddFileToDownloadsTable(p);
            }
            if (!isbuiltin && ki[0] != '\0') {
                char p[PLATFORM_MAX_PATH]; Format(p, sizeof(p), "sound/%s", ki);
                if (FileExists(p)) AddFileToDownloadsTable(p);
            }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    g_SetCount = GetArraySize(g_SetNames);
    if (g_SetCount == 0)
    {
        PushArrayString(g_SetNames, "禁用击中/击杀音效");
        PushArrayString(g_SetHeadshot, ""); PushArrayString(g_SetHit, ""); PushArrayString(g_SetKill, "");
        if (g_SetIsBuiltin != INVALID_HANDLE) PushArrayCell(g_SetIsBuiltin, 1);
        g_SetCount = 1;
    }
    LogMessage("[hitsound] 已加载 %d 套音效配置（0..%d）", g_SetCount, g_SetCount - 1);
}

// -----------------------------------------------------------
// ICON sets from hiticon_sets.cfg (DIRECT IDs, keys: headshot/hit/kill)
// -----------------------------------------------------------
void LoadHitIconSets()
{
    ClearArray(g_OvIds); ClearArray(g_OvNames);
    ClearArray(g_OvHeadshot); ClearArray(g_OvHit); ClearArray(g_OvKill);
    g_OvCount = 0;

    Handle kv = CreateKeyValues("HitIconSets");
    if (!FileToKeyValues(kv, "addons/sourcemod/configs/hiticon_sets.cfg"))
    {
        LogMessage("[hitsound] 未找到 hiticon_sets.cfg，图标将只受 0=禁用 / 其它=无可用 配置影响");
        CloseHandle(kv);
        return;
    }

    KvRewind(kv);
    if (KvGotoFirstSubKey(kv))
    {
        do {
            // 读取该子节的名称（即数字ID）
            char sec[16]; KvGetSectionName(kv, sec, sizeof(sec));
            // 只接受非负整数 ID
            int id = StringToInt(sec);
            if (id < 0) continue;

            char name[64], hs[PLATFORM_MAX_PATH], hi[PLATFORM_MAX_PATH], ki[PLATFORM_MAX_PATH];
            KvGetString(kv, "name", name, sizeof(name), "未命名图标套装");
            KvGetString(kv, "headshot", hs, sizeof(hs), "");
            KvGetString(kv, "hit",      hi, sizeof(hi), "");
            KvGetString(kv, "kill",     ki, sizeof(ki), "");

            PushArrayString(g_OvIds, sec);          // 保存成字符串，使用时再转 int
            PushArrayString(g_OvNames, name);
            PushArrayString(g_OvHeadshot, hs);
            PushArrayString(g_OvHit,      hi);
            PushArrayString(g_OvKill,     ki);
            g_OvCount++;

            // FastDL: 注册 VMT/VTF（非空才注册）
            if (hs[0] != '\0') { char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", hs); AddFileToDownloadsTable(p1);
                                 char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", hs); AddFileToDownloadsTable(p2); }
            if (hi[0] != '\0') { char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", hi); AddFileToDownloadsTable(p1);
                                 char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", hi); AddFileToDownloadsTable(p2); }
            if (ki[0] != '\0') { char p1[PLATFORM_MAX_PATH]; Format(p1, sizeof(p1), "materials/%s.vmt", ki); AddFileToDownloadsTable(p1);
                                 char p2[PLATFORM_MAX_PATH]; Format(p2, sizeof(p2), "materials/%s.vtf", ki); AddFileToDownloadsTable(p2); }
        } while (KvGotoNextKey(kv));
    }
    CloseHandle(kv);

    LogMessage("[hitsound] 已加载 %d 个图标套装（使用直接ID，包含0=禁用时也算一个）", g_OvCount);
}

// -----------------------------------------------------------
// Per-player persistence: DB + Fallback
// -----------------------------------------------------------
public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client)) return;

    SoundSelect[client]    = 0;
    g_OverlayTheme[client] = 0; // 默认禁用；你也可以改成 1=某默认主题
    g_LastNonZeroOv[client]= 1; // 记录上次非0的选择，初始给1（若不存在，会在菜单里被覆盖）

    if (GetConVarBool(g_cvDBEnabled) && g_hDB != INVALID_HANDLE)
    {
        char sid[64]; GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);
        char q[256];
        Format(q, sizeof(q),
            "SELECT hitsound_cfg, hitsound_overlay_set FROM rpg_player WHERE steamid='%s' LIMIT 1;", sid);
        SQL_TQuery(g_hDB, SQL_OnLoadPrefs, q, GetClientUserId(client));
    }
    else
    {
        ClientSaveToFileLoad(client);
    }
}

public void OnClientDisconnect(int client)
{
    if (IsFakeClient(client)) return;

    if (GetConVarBool(g_cvDBEnabled) && g_hDB != INVALID_HANDLE)
        DB_SavePlayerPrefs(client);
    else
        ClientSaveToFileSave(client);

    if (g_taskCountdown[client] != INVALID_HANDLE) { KillTimer(g_taskCountdown[client]); g_taskCountdown[client] = INVALID_HANDLE; }
    if (g_taskClean[client]     != INVALID_HANDLE) { KillTimer(g_taskClean[client]);     g_taskClean[client]     = INVALID_HANDLE; }
}

public void SQL_OnLoadPrefs(Handle owner, Handle hndl, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return;

    if (hndl == INVALID_HANDLE)
    {
        LogError("[hitsound] 加载玩家配置失败: %s", error);
        ClientSaveToFileLoad(client);
        return;
    }

    if (SQL_GetRowCount(hndl) > 0 && SQL_FetchRow(hndl))
    {
        int cfg   = SQL_FetchInt(hndl, 0);
        int ovset = SQL_FetchInt(hndl, 1);

        SoundSelect[client]    = (cfg >= 0 && cfg < g_SetCount) ? cfg : 0;
        g_OverlayTheme[client] = (ovset >= 0) ? ovset : 0;
        if (g_OverlayTheme[client] != 0) g_LastNonZeroOv[client] = g_OverlayTheme[client];
    }
    else
    {
        DB_SavePlayerPrefs(client); // write defaults
    }
}

void DB_SavePlayerPrefs(int client)
{
    if (g_hDB == INVALID_HANDLE) return;

    char sid[64]; GetClientAuthId(client, AuthId_Steam2, sid, sizeof(sid), true);
    int cfg  = SoundSelect[client];
    int ovst = g_OverlayTheme[client];

    char q[512];
    Format(q, sizeof(q),
        "INSERT INTO rpg_player (steamid, hitsound_cfg, hitsound_overlay_set) VALUES ('%s', %d, %d) ON DUPLICATE KEY UPDATE  hitsound_cfg=VALUES(hitsound_cfg), hitsound_overlay_set=VALUES(hitsound_overlay_set);",
        sid, cfg, ovst);

    SQL_TQuery(g_hDB, SQL_OnSavePrefs, q);
}
public void SQL_OnSavePrefs(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == INVALID_HANDLE) LogError("[hitsound] 保存玩家配置失败: %s", error);
}

// -----------------------------------------------------------
// Fallback to KeyValues file (only OverlaySet now)
// -----------------------------------------------------------
public void ClientSaveToFileSave(int client)
{
    char user_id[128] = "";
    GetClientAuthId(client, AuthId_Engine, user_id, sizeof(user_id), true);

    KvJumpToKey(SoundStore, user_id, true);
    KvSetNum(SoundStore, "Snd", SoundSelect[client]);
    KvSetNum(SoundStore, "OverlaySet", g_OverlayTheme[client]); // 0=禁用,1..N=直连ID
    KvGoBack(SoundStore);
    KvRewind(SoundStore);
    KeyValuesToFile(SoundStore, SavePath);
}
public void ClientSaveToFileLoad(int client)
{
    char user_id[128] = "";
    GetClientAuthId(client, AuthId_Engine, user_id, sizeof(user_id), true);

    KvJumpToKey(SoundStore, user_id, true);
    SoundSelect[client]    = KvGetNum(SoundStore, "Snd", 0);
    g_OverlayTheme[client] = KvGetNum(SoundStore, "OverlaySet", 0);
    if (g_OverlayTheme[client] != 0) g_LastNonZeroOv[client] = g_OverlayTheme[client];
    KvGoBack(SoundStore);
    KvRewind(SoundStore);
}

// -----------------------------------------------------------
// Commands & Menus
// -----------------------------------------------------------
public Action MenuFunc_Snd(int client, int args)
{
    Handle menu = CreateMenu(MenuHandler_MainMenu);
    char title[128];
    Format(title, sizeof(title), "选择音效/图标 | 当前音效套装: %d", SoundSelect[client]);
    SetMenuTitle(menu, title);

    char ovCurName[64] = "禁用";
    int idCount = GetArraySize(g_OvIds);
    for (int i=0; i<idCount; i++)
    {
        char sec[16]; GetArrayString(g_OvIds, i, sec, sizeof(sec));
        int id = StringToInt(sec);
        if (id == g_OverlayTheme[client])
        {
            GetArrayString(g_OvNames, i, ovCurName, sizeof(ovCurName));
            break;
        }
    }
    char ovsetLabel[96];
    Format(ovsetLabel, sizeof(ovsetLabel), "图标套装: %d - %s (点击选择)", g_OverlayTheme[client], ovCurName);
    AddMenuItem(menu, "overlay_set_open", ovsetLabel);

    AddMenuItem(menu, "sep", "----------------", ITEMDRAW_DISABLED);

    // list SOUND sets (0..g_SetCount-1)
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

public int MenuHandler_MainMenu(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Select)
    {
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));

        if (StrEqual(info, "overlay_set_open"))
        {
            OpenOverlaySetMenu(client);
            return 0;
        }

        int choice = StringToInt(info);
        if (choice < 0 || choice >= g_SetCount) choice = 0;
        SoundSelect[client] = choice;
        PrintToChat(client, "已选择音效套装: %d", SoundSelect[client]);

        if (GetConVarBool(g_cvDBEnabled) && g_hDB != INVALID_HANDLE) DB_SavePlayerPrefs(client);
        else ClientSaveToFileSave(client);
    }
    return 0;
}

Action OpenOverlaySetMenu(int client)
{
    Handle m = CreateMenu(MenuHandler_OvMenu);
    char title[96];
    Format(title, sizeof(title), "选择图标套装 (当前: %d)", g_OverlayTheme[client]);
    SetMenuTitle(m, title);

    // Always provide "0 - 禁用"
    AddMenuItem(m, "ov_0", "0 - 禁用");

    int idCount = GetArraySize(g_OvIds);
    for (int i=0; i<idCount; i++)
    {
        char sec[16]; GetArrayString(g_OvIds, i, sec, sizeof(sec));
        int id = StringToInt(sec);
        if (id == 0) continue; // 0 already provided
        char name[64]; GetArrayString(g_OvNames, i, name, sizeof(name));

        char key[16];  Format(key, sizeof(key), "ov_%d", id);
        char label[96]; Format(label, sizeof(label), "%d - %s", id, name);
        AddMenuItem(m, key, label);
    }

    SetMenuExitBackButton(m, true);
    DisplayMenu(m, client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public int MenuHandler_OvMenu(Handle menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End) { CloseHandle(menu); }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
    {
        MenuFunc_Snd(client, 0);
        return 0;
    }
    if (action == MenuAction_Select)
    {
        char info[16]; GetMenuItem(menu, item, info, sizeof(info));
        if (StrContains(info, "ov_", false) == 0)
        {
            ReplaceString(info, sizeof(info), "ov_", "");
            int val = StringToInt(info); // direct ID
            if (val < 0) val = 0;

            g_OverlayTheme[client] = val;
            if (val != 0) g_LastNonZeroOv[client] = val;

            PrintToChat(client, "已选择图标套装: %d", g_OverlayTheme[client]);

            if (GetConVarBool(g_cvDBEnabled) && g_hDB != INVALID_HANDLE) DB_SavePlayerPrefs(client);
            else ClientSaveToFileSave(client);

            MenuFunc_Snd(client, 0);
        }
    }
    return 0;
}

// -----------------------------------------------------------
// SOUND helpers: which: 0=headshot, 1=hit, 2=kill
// -----------------------------------------------------------
bool GetSetPath(int setIdx, int which, char[] out, int maxlen)
{
    if (setIdx < 0 || setIdx >= g_SetCount) { out[0]='\0'; return false; }
    if (which == 0)      GetArrayString(g_SetHeadshot, setIdx, out, maxlen);
    else if (which == 1) GetArrayString(g_SetHit,      setIdx, out, maxlen);
    else                 GetArrayString(g_SetKill,     setIdx, out, maxlen);
    return (out[0] != '\0');
}

// ICON helpers: direct ID lookup by scanning parallel arrays
bool GetIconPathById(int id, int which, char[] out, int maxlen)
{
    out[0] = '\0';
    int n = GetArraySize(g_OvIds);
    for (int i=0; i<n; i++)
    {
        char sec[16]; GetArrayString(g_OvIds, i, sec, sizeof(sec));
        if (StringToInt(sec) != id) continue;

        if (which == 0)      GetArrayString(g_OvHeadshot, i, out, maxlen);
        else if (which == 1) GetArrayString(g_OvHit,      i, out, maxlen);
        else                 GetArrayString(g_OvKill,     i, out, maxlen);
        return (out[0] != '\0');
    }
    return false;
}

// -----------------------------------------------------------
// Events
// -----------------------------------------------------------
public void Event_Spawn(Event event, const char[] name, bool dontBroadcast)
{
    int Client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (Client > 0 && Client <= MaxClients) IsVictimDeadPlayer[Client] = false;
}
public Action PlayerIncap(Handle event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(victim) && GetClientTeam(victim) == 3 && GetEntProp(victim, Prop_Send, "m_zombieClass") == 8)
        IsVictimDeadPlayer[victim] = true;
    return Plugin_Continue;
}
public Action Event_TankSpawn(Handle event, const char[] name, bool dontBroadcast)
{
    int tank = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsValidClient(tank)) IsVictimDeadPlayer[tank] = false;
    return Plugin_Continue;
}

public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
    int victim     = GetClientOfUserId(GetEventInt(event, "userid"));
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    bool headshot  = GetEventBool(event, "headshot");
    int damagetype = GetEventInt(event, "type");

    if (damagetype & (DMG_BURN | DMG_SLOWBURN))  // 新增：燃烧击杀就不播提示/覆盖
        return Plugin_Changed;

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(g_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && GetClientTeam(victim) == 3 && IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        // ICON
        if (GetConVarInt(pic_enable) == 1 && g_OverlayTheme[attacker] != 0)
        {
            ShowKillMessage(attacker, headshot ? KILL_HEADSHOT : KILL_NORMAL);
        }

        // SOUND
        if (GetConVarInt(sound_enable) == 1)
        {
            char snd[PLATFORM_MAX_PATH];
            int which = headshot ? 0 : 2;
            if (GetSetPath(SoundSelect[attacker], which, snd, sizeof(snd)))
            {
                PrecacheSound(snd, true);
                EmitSoundToClient(attacker, snd, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
            }
        }

        if (g_taskClean[attacker] != INVALID_HANDLE) { KillTimer(g_taskClean[attacker]); g_taskClean[attacker] = INVALID_HANDLE; }
        float showtime = GetConVarFloat(Time);
        g_taskClean[attacker] = CreateTimer(showtime, task_Clean, attacker);
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
    bool Isinferno = (StrEqual(weapon, "entityflame", false) || StrEqual(weapon, "inferno", false));

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(g_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(victim) && IsValidClient(attacker) && !IsFakeClient(attacker) && GetClientTeam(victim) == 3)
    {
        float AddDamage = 0.0;
        if (RoundToNearest(float(health - dmg) - AddDamage) <= 0.0) IsVictimDeadPlayer[victim] = true;

        if (!IsVictimDeadPlayer[victim])
        {
            if (GetConVarInt(pic_enable) == 1 && g_OverlayTheme[attacker] != 0)
                ShowKillMessage(attacker, HIT_ARMOR);

            if (GetConVarInt(sound_enable) == 1 && !Isinferno)
            {
                char snd[PLATFORM_MAX_PATH];
                if (GetSetPath(SoundSelect[attacker], 1, snd, sizeof(snd)))
                {
                    PrecacheSound(snd, true);
                    EmitSoundToClient(attacker, snd, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }

            if (g_taskClean[attacker] != INVALID_HANDLE) { KillTimer(g_taskClean[attacker]); g_taskClean[attacker] = INVALID_HANDLE; }
            float showtime = GetConVarFloat(Time);
            g_taskClean[attacker] = CreateTimer(showtime, task_Clean, attacker);
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
    if (GetConVarInt(g_blast) == 0 && blast) return Plugin_Changed;

    if (IsValidClient(attacker) && GetClientTeam(attacker) == 2 && !IsFakeClient(attacker))
    {
        if (GetConVarInt(pic_enable) == 1 && g_OverlayTheme[attacker] != 0)
            ShowKillMessage(attacker, headshot ? KILL_HEADSHOT : KILL_NORMAL);

        if (GetConVarInt(sound_enable) == 1)
        {
            char snd[PLATFORM_MAX_PATH];
            int which = headshot ? 0 : 2;
            if (GetSetPath(SoundSelect[attacker], which, snd, sizeof(snd)))
            {
                PrecacheSound(snd, true);
                EmitSoundToClient(attacker, snd, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
            }
        }

        if (g_taskClean[attacker] != INVALID_HANDLE) { KillTimer(g_taskClean[attacker]); g_taskClean[attacker] = INVALID_HANDLE; }
        float showtime = GetConVarFloat(Time);
        g_taskClean[attacker] = CreateTimer(showtime, task_Clean, attacker);
    }
    return Plugin_Continue;
}

public void OnMapStart()
{
    // 预缓存 SOUND 套装
    int nS = GetArraySize(g_SetNames);
    char path[PLATFORM_MAX_PATH];
    for (int i = 0; i < nS; i++)
    {
        GetArrayString(g_SetHeadshot, i, path, sizeof(path));
        if (path[0] != '\0') PrecacheSound(path, true);
        GetArrayString(g_SetHit, i, path, sizeof(path));
        if (path[0] != '\0') PrecacheSound(path, true);
        GetArrayString(g_SetKill, i, path, sizeof(path));
        if (path[0] != '\0') PrecacheSound(path, true);
    }

    // 预缓存 ICON 套装（VTF/VMT）
    int nI = GetArraySize(g_OvIds);
    char base[PLATFORM_MAX_PATH], file[PLATFORM_MAX_PATH];

    for (int i = 0; i < nI; i++)
    {
        GetArrayString(g_OvHeadshot, i, base, sizeof(base));
        if (base[0] != '\0') {
            Format(file, sizeof(file), "%s.vtf", base); PrecacheDecal(file, true);
            Format(file, sizeof(file), "%s.vmt", base); PrecacheDecal(file, true);
        }
        GetArrayString(g_OvHit, i, base, sizeof(base));
        if (base[0] != '\0') {
            Format(file, sizeof(file), "%s.vtf", base); PrecacheDecal(file, true);
            Format(file, sizeof(file), "%s.vmt", base); PrecacheDecal(file, true);
        }
        GetArrayString(g_OvKill, i, base, sizeof(base));
        if (base[0] != '\0') {
            Format(file, sizeof(file), "%s.vtf", base); PrecacheDecal(file, true);
            Format(file, sizeof(file), "%s.vmt", base); PrecacheDecal(file, true);
        }
    }
}


public Action Event_InfectedHurt(Handle event, const char[] name, bool dontBroadcast)
{
    int victim     = GetEventInt(event, "entityid");
    int attacker   = GetClientOfUserId(GetEventInt(event, "attacker"));
    int dmg        = GetEventInt(event, "amount");
    int eventhealth= GetEntProp(victim, Prop_Data, "m_iHealth");
    int damagetype = GetEventInt(event, "type");

    if (!IsValidEntity(victim) || !IsValidEdict(victim)) 
        return Plugin_Changed;

    if (damagetype & DMG_DIRECT) return Plugin_Changed;
    if (GetConVarInt(g_blast) == 0 && (damagetype & DMG_BLAST)) return Plugin_Changed;

    if (IsValidClient(attacker) && !IsFakeClient(attacker))
    {
        bool IsVictimDead = ((eventhealth - dmg) <= 0);
        if (!IsVictimDead)
        {
            if (GetConVarInt(pic_enable) == 1 && g_OverlayTheme[attacker] != 0)
                ShowKillMessage(attacker, HIT_ARMOR);

            if (GetConVarInt(sound_enable) == 1)
            {
                char snd[PLATFORM_MAX_PATH];
                if (GetSetPath(SoundSelect[attacker], 1, snd, sizeof(snd)))
                {
                    PrecacheSound(snd, true);
                    EmitSoundToClient(attacker, snd, SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NORMAL);
                }
            }

            if (g_taskClean[attacker] != INVALID_HANDLE) { KillTimer(g_taskClean[attacker]); g_taskClean[attacker] = INVALID_HANDLE; }
            float showtime = GetConVarFloat(Time);
            g_taskClean[attacker] = CreateTimer(showtime, task_Clean, attacker);
        }
    }
    return Plugin_Changed;
}

public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_killCount[client] = 0;
        if (g_taskCountdown[client] != INVALID_HANDLE) { KillTimer(g_taskCountdown[client]); g_taskCountdown[client] = INVALID_HANDLE; }
        g_bShowAuthor[client] = GetRandomInt(1,3) == 1;
    }
}

// -----------------------------------------------------------
// Timers & overlay
// -----------------------------------------------------------
public Action task_Countdown(Handle timer, any client)
{
    g_killCount[client]--;
    if (!IsPlayerAlive(client) || g_killCount[client] == 0)
    {
        KillTimer(timer); g_taskCountdown[client] = INVALID_HANDLE;
    }
    return Plugin_Stop;
}
public Action task_Clean(Handle timer, any client)
{
    KillTimer(timer); 
    g_taskClean[client] = INVALID_HANDLE;

    if (client <= 0 || !IsClientInGame(client)) 
        return Plugin_Stop;

    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);
    ClientCommand(client, "r_screenoverlay \"\"");
    return Plugin_Stop;
}

public void ShowKillMessage(int client, int type)
{
    // 0 = disabled by direct ID
    if (g_OverlayTheme[client] == 0) return;

    // Lookup exact icon base by current ID
    char baseHead[PLATFORM_MAX_PATH], baseHit[PLATFORM_MAX_PATH], baseKill[PLATFORM_MAX_PATH];
    bool okH = GetIconPathById(g_OverlayTheme[client], 0, baseHead, sizeof(baseHead));
    bool okB = GetIconPathById(g_OverlayTheme[client], 1, baseHit,  sizeof(baseHit));
    bool okK = GetIconPathById(g_OverlayTheme[client], 2, baseKill, sizeof(baseKill));

    // 如果当前套装缺某项，就不显示该类覆盖（不回退 CVar）
    char overlays_file[PLATFORM_MAX_PATH];

    // Precache only those present
    if (okH) { Format(overlays_file, sizeof(overlays_file), "%s.vtf", baseHead); PrecacheDecal(overlays_file, true);
               Format(overlays_file, sizeof(overlays_file), "%s.vmt", baseHead); PrecacheDecal(overlays_file, true); }
    if (okB) { Format(overlays_file, sizeof(overlays_file), "%s.vtf", baseHit ); PrecacheDecal(overlays_file, true);
               Format(overlays_file, sizeof(overlays_file), "%s.vmt", baseHit ); PrecacheDecal(overlays_file, true); }
    if (okK) { Format(overlays_file, sizeof(overlays_file), "%s.vtf", baseKill); PrecacheDecal(overlays_file, true);
               Format(overlays_file, sizeof(overlays_file), "%s.vmt", baseKill); PrecacheDecal(overlays_file, true); }

    int iFlags = GetCommandFlags("r_screenoverlay") & (~FCVAR_CHEAT);
    SetCommandFlags("r_screenoverlay", iFlags);

    switch (type)
    {
        case KILL_HEADSHOT:
        {
            if (okH) ClientCommand(client, "r_screenoverlay \"%s\"", baseHead);
            else return;
        }
        case KILL_NORMAL:
        {
            if (okK) ClientCommand(client, "r_screenoverlay \"%s\"", baseKill);
            else return;
        }
        case HIT_ARMOR:
        {
            if (okB) ClientCommand(client, "r_screenoverlay \"%s\"", baseHit);
            else return;
        }
    }

    if (g_bShowAuthor[client])
    {
        g_bShowAuthor[client] = false;
        SendTopLeftText(client, 225,225,64,192, 1,2, " ");
    }
}

public void SendTopLeftText(int client, int r, int g, int b, int a, int level, int time, const char[] message)
{
    Handle kv = CreateKeyValues("Stuff", "title", message);
    if (kv == INVALID_HANDLE) return;
    KvSetColor(kv, "color", r, g, b, a);
    KvSetNum(kv, "level", level);
    KvSetNum(kv, "time", time);
    CreateDialog(client, kv, DialogType_Msg);
    CloseHandle(kv);
}
