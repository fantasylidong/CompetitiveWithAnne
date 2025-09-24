#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <clientprefs>
#include <colors>

#define PLUGIN_VERSION  "2.1-mysql-cookie"
#define SPRITE_MATERIAL "materials/sprites/laserbeam.vmt"
#define DMG_HEADSHOT    (1 << 30)
#define L4D2_MAXPLAYERS 32
#define ZC_BOOMER       2
#define ZC_TANK         8
#define UPDATE_INTERVAL 0.10 // 累加帧间隔（不要低于 0.05）

// ====== 数据层：MySQL + Cookie ======
#define DB_CONF_NAME "rpg"        // databases.cfg 中的配置名
#define COOKIE_NAME  "l4d2_dmgshow_v2"

// rpgdamage 表结构（注意：share_scope 仅 0/1；默认全关，防首次覆盖）
/*
CREATE TABLE IF NOT EXISTS `rpgdamage` (
  `steamid`      VARCHAR(255) NOT NULL PRIMARY KEY,
  `enable`       TINYINT      NOT NULL DEFAULT 0,      -- 默认不开启显示
  `see_others`   TINYINT      NOT NULL DEFAULT 1,      -- 默认：允许看到他人（用于看“管理员分享”的）
  `share_scope`  TINYINT      NOT NULL DEFAULT 0,      -- 0=仅自己,1=仅队友（无“所有人”选项）
  `size`         FLOAT        NOT NULL DEFAULT 5.0,
  `gap`          FLOAT        NOT NULL DEFAULT 5.0,
  `alpha`        INT          NOT NULL DEFAULT 70,
  `xoff`         FLOAT        NOT NULL DEFAULT 20.0,
  `yoff`         FLOAT        NOT NULL DEFAULT 10.0,
  `showdist`     FLOAT        NOT NULL DEFAULT 1500.0,
  `summode`      TINYINT      NOT NULL DEFAULT 1,
  `sg_merge`     TINYINT      NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
*/

// ============ 结构体 ============

enum struct PlayerSetData
{
    // 运行期缓存
    int   wpn_id;
    int   wpn_type; // 0狙 1步冲 2近战 3其它 4火焰 5投掷类
    bool  show_other;    // “允许别人看到我的数字”（仅管理员可真）
    float last_set_time;

    // 可持久化 per-client 样式
    bool  enable;        // 伤害显示开关（默认 false）
    bool  see_others;    // 我是否能看到“他人分享”的数字（默认 true，便于看到管理员分享）
    int   share_scope;   // 我把伤害分享给谁：0仅自己/1队友（仅管理员有效）
    float size;          // 字号
    float gap;           // 字距
    int   alpha;         // 透明度 0-255
    float xoff;          // X 偏移
    float yoff;          // Y 偏移
    float showdist;      // 显示距离上限
    bool  summode;       // 累加模式
    bool  sgmerge;       // 霰弹合并
}

enum struct ReturnTwoFloat
{
    float startPt[3];
    float endPt[3];
}

enum struct ShotgunDamageData
{
    int   victim;
    int   attacker;
    int   totalDamage;
    float damagePosition[3];
    int   damageType;
    int   weapon;
    bool  isHeadshot;
    bool  isCreated;
}

enum struct SumShowMode
{
    bool  needShow;
    int   totalDamage;
    int   damageType;
    int   weapon;
    bool  isHeadshot;
    float damagePosition[3];
    float lastShowTime;
    float lastHitTime;
}

enum struct DamageTrans
{
    bool forceHeadshot;
    int  damage;
}

// ============ 全局 ============

PlayerSetData      g_Plr[L4D2_MAXPLAYERS + 1];
ShotgunDamageData  g_SGbuf[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1]; // [attacker][victim]
SumShowMode        g_Sum[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];
DamageTrans        g_AttackCache[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];

ConVar g_hMaxTE;

bool  g_bNeverFire[L4D2_MAXPLAYERS + 1];
int   g_sprite;
int   g_iVitcimHealth[L4D2_MAXPLAYERS + 1][L4D2_MAXPLAYERS + 1];
float g_fTankIncap[L4D2_MAXPLAYERS + 1];

// === 旁观管理员：查看所有人开关（默认关） ===
bool  g_bAdminObsViewAll[MAXPLAYERS + 1];

// === 防止“加载前保存覆盖”的标记 ===
bool  g_bSettingsLoaded[MAXPLAYERS + 1];

static const int color[][3] = {
    {  0,255,  0}, // 绿：友伤
    {255,255,  0}, // 黄：未用
    {255,255,255}, // 白：打 SI/CI
    {  0,255,255}, // 蓝
    {255,  0,  0}  // 红：爆头
};

// ============ 数据持久化 ============
Handle g_DB = INVALID_HANDLE;
bool   g_UseMySQL = false;
Cookie g_ck = null;

// ============ 菜单（分两层） ============
#define MENU_TIME 20

// --------- 工具函数 ----------
static bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientInGame(client));
}

static bool IsAdminOrRoot(int client) {
    return CheckCommandAccess(client, "dmg_admin_gate", ADMFLAG_GENERIC, true);
}

static void ClampStyle(int client)
{
    if (g_Plr[client].size < 0.0)     g_Plr[client].size = 0.0;
    if (g_Plr[client].size > 100.0)   g_Plr[client].size = 100.0;
    if (g_Plr[client].gap < 0.0)      g_Plr[client].gap = 0.0;
    if (g_Plr[client].gap > 100.0)    g_Plr[client].gap = 100.0;
    if (g_Plr[client].alpha < 0)      g_Plr[client].alpha = 0;
    if (g_Plr[client].alpha > 255)    g_Plr[client].alpha = 255;
    if (g_Plr[client].xoff < -100.0)  g_Plr[client].xoff = -100.0;
    if (g_Plr[client].xoff >  100.0)  g_Plr[client].xoff =  100.0;
    if (g_Plr[client].yoff < -100.0)  g_Plr[client].yoff = -100.0;
    if (g_Plr[client].yoff >  100.0)  g_Plr[client].yoff =  100.0;
    if (g_Plr[client].showdist < 0.0) g_Plr[client].showdist = 0.0;
    if (g_Plr[client].showdist > 8192.0) g_Plr[client].showdist = 8192.0;

    if (g_Plr[client].share_scope < 0) g_Plr[client].share_scope = 0;
    if (g_Plr[client].share_scope > 1) g_Plr[client].share_scope = 1;

    // 非管理员：强制不对外分享（仅自己）
    if (!IsAdminOrRoot(client)) {
        g_Plr[client].show_other = false;
        g_Plr[client].share_scope = 0;
    }
}

// --------- MySQL / Cookie ----------
static void DB_TryConnect()
{
    if (g_DB != INVALID_HANDLE) return;

    if (!SQL_CheckConfig(DB_CONF_NAME))
    {
        g_UseMySQL = false;
        return;
    }

    char err[256];
    g_DB = SQL_Connect(DB_CONF_NAME, true, err, sizeof err);
    if (g_DB == INVALID_HANDLE)
    {
        LogError("[DMGSHOW] DB connect failed: %s", err);
        g_UseMySQL = false;
        return;
    }
    SQL_SetCharset(g_DB, "utf8mb4");
    g_UseMySQL = true;

    // 建表（单行 SQL）
    char q[1024];
    Format(q, sizeof q,
        "CREATE TABLE IF NOT EXISTS `rpgdamage` (`steamid` VARCHAR(255) NOT NULL PRIMARY KEY,`enable` TINYINT NOT NULL DEFAULT 0,`see_others` TINYINT NOT NULL DEFAULT 1,`share_scope` TINYINT NOT NULL DEFAULT 0,`size` FLOAT NOT NULL DEFAULT 5.0,`gap` FLOAT NOT NULL DEFAULT 5.0,`alpha` INT NOT NULL DEFAULT 70,`xoff` FLOAT NOT NULL DEFAULT 20.0,`yoff` FLOAT NOT NULL DEFAULT 10.0,`showdist` FLOAT NOT NULL DEFAULT 1500.0,`summode` TINYINT NOT NULL DEFAULT 1,`sg_merge` TINYINT NOT NULL DEFAULT 1) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;"
    );
    SQL_TQuery(g_DB, SQLCB_Nop, q);
}

public void SQLCB_Nop(Handle owner, Handle hndl, const char[] error, any data)
{
    if (error[0] != '\0')
        LogError("[DMGSHOW] SQL Error: %s", error);
}

static void Settings_Default(int client)
{
    g_Plr[client].enable        = false;  // 默认不开
    g_Plr[client].see_others    = true;   // 允许看“管理员分享”
    g_Plr[client].share_scope   = 0;      // 仅自己
    g_Plr[client].size          = 5.0;
    g_Plr[client].gap           = 5.0;
    g_Plr[client].alpha         = 70;
    g_Plr[client].xoff          = 20.0;
    g_Plr[client].yoff          = 10.0;
    g_Plr[client].showdist      = 1500.0;
    g_Plr[client].summode       = true;
    g_Plr[client].sgmerge       = true;
    g_Plr[client].show_other    = false; // 非管理员默认 false
}

static void Cookie_Save(int client)
{
    if (g_ck == null || IsFakeClient(client)) return;
    if (!g_bSettingsLoaded[client]) return; // 未加载前不保存，防覆盖

    char buf[256];
    Format(buf, sizeof buf, "%d|%d|%d|%.1f|%.1f|%d|%.1f|%.1f|%.1f|%d|%d",
        g_Plr[client].enable ? 1:0,
        g_Plr[client].see_others ? 1:0,
        g_Plr[client].share_scope,
        g_Plr[client].size,
        g_Plr[client].gap,
        g_Plr[client].alpha,
        g_Plr[client].xoff,
        g_Plr[client].yoff,
        g_Plr[client].showdist,
        g_Plr[client].summode ? 1:0,
        g_Plr[client].sgmerge ? 1:0
    );
    g_ck.Set(client, buf);
}

static void Cookie_Load(int client)
{
    Settings_Default(client);
    if (g_ck == null || IsFakeClient(client)) { g_bSettingsLoaded[client] = true; return; }

    char buf[256];
    g_ck.Get(client, buf, sizeof buf);
    if (!buf[0]) { g_bSettingsLoaded[client] = true; return; }

    char part[11][32];
    int n = ExplodeString(buf, "|", part, sizeof(part), sizeof(part[]));
    if (n < 11) { g_bSettingsLoaded[client] = true; return; }

    g_Plr[client].enable      = (StringToInt(part[0]) != 0);
    g_Plr[client].see_others  = (StringToInt(part[1]) != 0);
    g_Plr[client].share_scope = StringToInt(part[2]);
    g_Plr[client].size        = StringToFloat(part[3]);
    g_Plr[client].gap         = StringToFloat(part[4]);
    g_Plr[client].alpha       = StringToInt(part[5]);
    g_Plr[client].xoff        = StringToFloat(part[6]);
    g_Plr[client].yoff        = StringToFloat(part[7]);
    g_Plr[client].showdist    = StringToFloat(part[8]);
    g_Plr[client].summode     = (StringToInt(part[9]) != 0);
    g_Plr[client].sgmerge     = (StringToInt(part[10]) != 0);

    g_Plr[client].show_other = false; // cookie 模式非管理员也不允许开放
    ClampStyle(client);
    g_bSettingsLoaded[client] = true;
}

static void DB_Load(int client)
{
    if (!g_UseMySQL || IsFakeClient(client)) { Cookie_Load(client); return; }

    char sid[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sid, sizeof sid) || StrEqual(sid, "BOT")) {
        Cookie_Load(client);
        return;
    }

    char q[512];
    Format(q, sizeof q, "SELECT enable,see_others,share_scope,size,gap,alpha,xoff,yoff,showdist,summode,sg_merge FROM rpgdamage WHERE steamid='%s' LIMIT 1", sid);
    SQL_TQuery(g_DB, SQLCB_Load, q, GetClientUserId(client));
}

public void SQLCB_Load(Handle owner, Handle hndl, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (error[0] != '\0') { LogError("[DMGSHOW] SQL Load error: %s", error); if (IsValidClient(client)) Cookie_Load(client); return; }
    if (!IsValidClient(client)) return;

    if (hndl != INVALID_HANDLE && SQL_FetchRow(hndl))
    {
        g_Plr[client].enable      = (SQL_FetchInt(hndl, 0) != 0);
        g_Plr[client].see_others  = (SQL_FetchInt(hndl, 1) != 0);
        g_Plr[client].share_scope = SQL_FetchInt(hndl, 2);
        g_Plr[client].size        = SQL_FetchFloat(hndl, 3);
        g_Plr[client].gap         = SQL_FetchFloat(hndl, 4);
        g_Plr[client].alpha       = SQL_FetchInt(hndl, 5);
        g_Plr[client].xoff        = SQL_FetchFloat(hndl, 6);
        g_Plr[client].yoff        = SQL_FetchFloat(hndl, 7);
        g_Plr[client].showdist    = SQL_FetchFloat(hndl, 8);
        g_Plr[client].summode     = (SQL_FetchInt(hndl, 9) != 0);
        g_Plr[client].sgmerge     = (SQL_FetchInt(hndl,10) != 0);
    }
    else
    {
        // 不存在则按默认插入（默认不开启）
        Settings_Default(client);
        char sid[64];
        GetClientAuthId(client, AuthId_Steam2, sid, sizeof sid);
        char iq[512];
        Format(iq, sizeof iq, "INSERT INTO rpgdamage (steamid,enable,see_others,share_scope,size,gap,alpha,xoff,yoff,showdist,summode,sg_merge) VALUES ('%s',%d,%d,%d,%.1f,%.1f,%d,%.1f,%.1f,%.1f,%d,%d)",
            sid,
            g_Plr[client].enable?1:0,
            g_Plr[client].see_others?1:0,
            g_Plr[client].share_scope,
            g_Plr[client].size,
            g_Plr[client].gap,
            g_Plr[client].alpha,
            g_Plr[client].xoff,
            g_Plr[client].yoff,
            g_Plr[client].showdist,
            g_Plr[client].summode?1:0,
            g_Plr[client].sgmerge?1:0
        );
        SQL_TQuery(g_DB, SQLCB_Nop, iq);
    }

    // 设置加载完成，防止未加载状态的保存覆盖
    g_bSettingsLoaded[client] = true;

    // 非管理员不能开放 show_other
    if (!IsAdminOrRoot(client)) g_Plr[client].show_other = false;
    else                        g_Plr[client].show_other = (g_Plr[client].share_scope > 0); // 给管理员一个同步
    ClampStyle(client);
}

static void DB_Save(int client)
{
    if (!g_bSettingsLoaded[client]) return; // 未加载前不保存
    ClampStyle(client);

    if (!g_UseMySQL || IsFakeClient(client)) {
        Cookie_Save(client);
        return;
    }
    char sid[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sid, sizeof sid) || StrEqual(sid, "BOT")) {
        Cookie_Save(client);
        return;
    }
    char q[768];
    Format(q, sizeof q, "INSERT INTO rpgdamage (steamid,enable,see_others,share_scope,size,gap,alpha,xoff,yoff,showdist,summode,sg_merge) VALUES ('%s',%d,%d,%d,%.1f,%.1f,%d,%.1f,%.1f,%.1f,%d,%d) ON DUPLICATE KEY UPDATE enable=VALUES(enable),see_others=VALUES(see_others),share_scope=VALUES(share_scope),size=VALUES(size),gap=VALUES(gap),alpha=VALUES(alpha),xoff=VALUES(xoff),yoff=VALUES(yoff),showdist=VALUES(showdist),summode=VALUES(summode),sg_merge=VALUES(sg_merge)",
        sid,
        g_Plr[client].enable?1:0,
        g_Plr[client].see_others?1:0,
        g_Plr[client].share_scope,
        g_Plr[client].size,
        g_Plr[client].gap,
        g_Plr[client].alpha,
        g_Plr[client].xoff,
        g_Plr[client].yoff,
        g_Plr[client].showdist,
        g_Plr[client].summode?1:0,
        g_Plr[client].sgmerge?1:0
    );
    SQL_TQuery(g_DB, SQLCB_Nop, q);
}

// ============ 插件信息 ============
public Plugin myinfo =
{
    name        = "[L4D2] Damage HUD (MySQL+Cookie)",
    author      = "Loqi + you (mod by ChatGPT)",
    description = "Per-client damage digits with DB/Cookie + menus + admin sharing gate",
    version     = PLUGIN_VERSION,
    url         = "https://"
};

// ============ 生命周期 ============
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    RegPluginLibrary("damage_show");
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "仅支持 L4D2");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart()
{
    g_hMaxTE = FindConVar("sv_multiplayer_maxtempentities");
    if (g_hMaxTE != null) g_hMaxTE.SetInt(512);

    // Cookie
    g_ck = new Cookie(COOKIE_NAME, "damage hud per-client", CookieAccess_Protected);

    // DB
    DB_TryConnect();

    // 命令
    RegConsoleCmd("sm_dmgmenu", Cmd_Menu, "打开伤害数字设置菜单");

    // 事件/钩子
    HookEvent("player_left_safe_area", E_LeftSafe, EventHookMode_PostNoCopy);
    HookEvent("player_hurt", E_PlayerHurt);
    for (int i=1;i<=MaxClients;i++)
        if (IsClientInGame(i)) SDKHook(i, SDKHook_OnTakeDamagePost, SDK_OnTakeDamagePost);
}

public void OnClientPutInServer(int client)
{
    g_bAdminObsViewAll[client] = false;
    g_bSettingsLoaded[client]  = false;
    SDKHook(client, SDKHook_OnTakeDamagePost, SDK_OnTakeDamagePost);
}

public void OnClientCookiesCached(int client)
{
    if (IsFakeClient(client)) return;
    Settings_Default(client);
    DB_Load(client); // 加载完成前不做任何保存
}

public void OnMapStart()
{
    g_sprite = PrecacheModel(SPRITE_MATERIAL, true);

    for (int i=1;i<=L4D2_MAXPLAYERS;i++)
    {
        g_Plr[i].wpn_id   = -1;
        g_Plr[i].wpn_type = -1;
        g_Plr[i].last_set_time = 0.0;
        g_bNeverFire[i] = true;
        g_fTankIncap[i] = 0.0;

        for (int j=1;j<=L4D2_MAXPLAYERS;j++)
        {
            g_SGbuf[i][j].victim = 0;
            g_SGbuf[i][j].attacker = 0;
            g_SGbuf[i][j].totalDamage = 0;
            g_SGbuf[i][j].isHeadshot = false;
            g_SGbuf[i][j].isCreated = false;

            g_Sum[i][j].needShow = false;
            g_Sum[i][j].totalDamage = 0;
            g_Sum[i][j].lastShowTime = 0.0;

            g_iVitcimHealth[i][j] = 0;
        }
    }
}

public void OnClientDisconnect(int client)
{
    if (IsClientConnected(client) && !IsFakeClient(client))
        DB_Save(client); // 仅在已加载后才会真正保存
}

// ============ 菜单（分面板） ============

public Action Cmd_Menu(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;
    OpenRootMenu(client);
    return Plugin_Handled;
}

// 根菜单：分为【显示样式】与【分享/可见性】
static void OpenRootMenu(int client)
{
    Menu m = new Menu(Menu_Root);
    m.SetTitle("伤害数字设置（根）\n请选择一个分面板：");

    m.AddItem("style", "① 显示样式 / 字体 / 偏移");
    m.AddItem("share", "② 分享 / 可见性 / 管理功能");
    m.AddItem("save",  "保存当前设置");

    m.Display(client, MENU_TIME);
}

public int Menu_Root(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End) { delete menu; return 0; }
    if (action != MenuAction_Select) return 0;

    char key[16];
    menu.GetItem(param2, key, sizeof key);

    if (StrEqual(key, "style")) OpenStyleMenu(client);
    else if (StrEqual(key, "share")) OpenShareMenu(client);
    else if (StrEqual(key, "save"))
    {
        ClampStyle(client);
        DB_Save(client);
        CPrintToChat(client, "{olive}[HUD]{default} 设置已保存。");
        OpenRootMenu(client);
    }
    return 0;
}

// 样式面板：只放与字体/偏移相关项，避免一屏过长
static void OpenStyleMenu(int client)
{
    Menu m = new Menu(Menu_Style);
    char title[256];
    Format(title, sizeof title,
        "① 显示样式 / 字体 / 偏移\n开关: %s\n字号: %.1f  间距: %.1f  透明度: %d\nX偏移: %.1f  Y偏移: %.1f  最大距离: %.0f\n累加模式: %s  霰弹合并: %s",
        g_Plr[client].enable ? "开" : "关",
        g_Plr[client].size, g_Plr[client].gap, g_Plr[client].alpha,
        g_Plr[client].xoff, g_Plr[client].yoff, g_Plr[client].showdist,
        g_Plr[client].summode ? "开" : "关",
        g_Plr[client].sgmerge ? "开" : "关"
    );
    m.SetTitle(title);

    m.AddItem("toggle_enable", "切换：显示开关");
    m.AddItem("size+", "字号 +0.5");
    m.AddItem("size-", "字号 -0.5");
    m.AddItem("gap+",  "间距 +0.5");
    m.AddItem("gap-",  "间距 -0.5");
    m.AddItem("alpha+", "透明度 +10");
    m.AddItem("alpha-", "透明度 -10");
    m.AddItem("x+", "X偏移 +2");
    m.AddItem("x-", "X偏移 -2");
    m.AddItem("y+", "Y偏移 +2");
    m.AddItem("y-", "Y偏移 -2");
    m.AddItem("dist+", "最大距离 +250");
    m.AddItem("dist-", "最大距离 -250");
    m.AddItem("sum", "切换：累加模式");
    m.AddItem("sg",  "切换：霰弹合并");
    m.AddItem("back", "返回：根菜单");

    m.Display(client, MENU_TIME);
}
public int Menu_Style(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End) { delete menu; return 0; }
    if (action != MenuAction_Select) return 0;

    char key[32];
    menu.GetItem(param2, key, sizeof key);

    if (StrEqual(key, "toggle_enable")) g_Plr[client].enable = !g_Plr[client].enable;
    else if (StrEqual(key, "size+")) g_Plr[client].size += 0.5;
    else if (StrEqual(key, "size-")) g_Plr[client].size -= 0.5;
    else if (StrEqual(key, "gap+"))  g_Plr[client].gap  += 0.5;
    else if (StrEqual(key, "gap-"))  g_Plr[client].gap  -= 0.5;
    else if (StrEqual(key, "alpha+")) g_Plr[client].alpha += 10;
    else if (StrEqual(key, "alpha-")) g_Plr[client].alpha -= 10;
    else if (StrEqual(key, "x+")) g_Plr[client].xoff += 2.0;
    else if (StrEqual(key, "x-")) g_Plr[client].xoff -= 2.0;
    else if (StrEqual(key, "y+")) g_Plr[client].yoff += 2.0;
    else if (StrEqual(key, "y-")) g_Plr[client].yoff -= 2.0;
    else if (StrEqual(key, "dist+")) g_Plr[client].showdist += 250.0;
    else if (StrEqual(key, "dist-")) g_Plr[client].showdist -= 250.0;
    else if (StrEqual(key, "sum")) g_Plr[client].summode = !g_Plr[client].summode;
    else if (StrEqual(key, "sg"))  g_Plr[client].sgmerge = !g_Plr[client].sgmerge;
    else if (StrEqual(key, "back")) { OpenRootMenu(client); return 0; }

    ClampStyle(client);
    OpenStyleMenu(client);
    return 0;
}

// 分享/可见性面板：只放“看他人/分享给谁/管理员选项”
static void OpenShareMenu(int client)
{
    Menu m = new Menu(Menu_Share);
    char title[256];
    char scopeText[16];
    strcopy(scopeText, sizeof scopeText, g_Plr[client].share_scope == 0 ? "仅自己" : "队友");
    Format(title, sizeof title,
        "② 分享 / 可见性 / 管理功能\n看他人（用于接收分享）: %s\n分享范围（只对管理员有效）: %s\n管理员对外分享权限: %s\n%s",
        g_Plr[client].see_others ? "开" : "关",
        scopeText,
        (IsAdminOrRoot(client) && g_Plr[client].show_other) ? "开启" : "关闭",
        (GetClientTeam(client) == 1 && IsAdminOrRoot(client)) ?
        (g_bAdminObsViewAll[client] ? "旁观：查看所有人生还者伤害【开】" : "旁观：查看所有人生还者伤害【关】") : ""
    );
    m.SetTitle(title);

    m.AddItem("toggle_see",    "切换：看他人（接收分享）");

    // 分享范围：仅管理员可调；普通玩家灰
    if (IsAdminOrRoot(client)) m.AddItem("scope", "切换：分享范围（仅自己/队友）");
    else                       m.AddItem("scope", "切换：分享范围（仅管理员可设）", ITEMDRAW_DISABLED);

    // 管理员开启“允许别人看到我的数字”
    if (IsAdminOrRoot(client))
        m.AddItem("admin_showother", "切换：管理员对外分享权限");
    else
        m.AddItem("admin_showother", "管理员对外分享权限（需要管理员）", ITEMDRAW_DISABLED);

    // 旁观管理员全览
    if (GetClientTeam(client) == 1 && IsAdminOrRoot(client))
        m.AddItem("spec_view_all", "旁观：切换“查看所有人生还者伤害”");

    m.AddItem("back", "返回：根菜单");
    m.Display(client, MENU_TIME);
}

public int Menu_Share(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End) { delete menu; return 0; }
    if (action != MenuAction_Select) return 0;

    char key[32];
    menu.GetItem(param2, key, sizeof key);

    if (StrEqual(key, "toggle_see"))
        g_Plr[client].see_others = !g_Plr[client].see_others;
    else if (StrEqual(key, "scope"))
    {
        if (IsAdminOrRoot(client))
            g_Plr[client].share_scope = (g_Plr[client].share_scope + 1) % 2; // 0/1 轮换
        else
            CPrintToChat(client, "{olive}[HUD]{default} 只有管理员可以修改分享范围。");
    }
    else if (StrEqual(key, "admin_showother"))
    {
        if (IsAdminOrRoot(client))
        {
            g_Plr[client].show_other = !g_Plr[client].show_other;
            CPrintToChat(client, "{olive}[HUD]{default} 管理员对外分享已%s。", g_Plr[client].show_other ? "开启" : "关闭");
        }
        else CPrintToChat(client, "{olive}[HUD]{default} 只有管理员可开启该选项。");
    }
    else if (StrEqual(key, "spec_view_all"))
    {
        if (GetClientTeam(client) == 1 && IsAdminOrRoot(client))
        {
            g_bAdminObsViewAll[client] = !g_bAdminObsViewAll[client];
            PrintToChat(client, "\x04旁观显示\x01已切换：\x05%s",
                g_bAdminObsViewAll[client] ? "查看所有人生还者伤害【开】" : "查看所有人生还者伤害【关】");
        }
        else
        {
            PrintToChat(client, "\x03只有旁观中的管理员可以使用该开关。");
        }
    }
    else if (StrEqual(key, "back")) { OpenRootMenu(client); return 0; }

    ClampStyle(client);
    OpenShareMenu(client);
    return 0;
}

// ============ 提示 ============
void E_LeftSafe(Event event, const char[] name, bool dontBroadcast)
{
    // PrintToChatAll("\x04[伤害显示]\x05 输入 !dmgmenu 打开设置菜单。");
}

// ============ 事件/绘制 ============
public void E_PlayerHurt(Event hEvent, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(hEvent.GetInt("attacker"));
    int victim   = GetClientOfUserId(hEvent.GetInt("userid"));

    if (!IsValidClient(attacker) || !IsValidClient(victim)) return;
    if (GetClientTeam(attacker) != 2 || IsFakeClient(attacker)) return;

    // 自己的功能开关（默认 false）
    if (!g_Plr[attacker].enable) return;

    int remain = hEvent.GetInt("health");
    int damage = hEvent.GetInt("dmg_health");
    bool forceHS = false;

    if (remain > 1) {
        g_iVitcimHealth[attacker][victim] = remain;
    } else {
        if (g_iVitcimHealth[attacker][victim] == 0)
            damage = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
        else
            damage = g_iVitcimHealth[attacker][victim];
        g_iVitcimHealth[attacker][victim] = 0;
        forceHS = true;
    }
    g_AttackCache[attacker][victim].damage = damage;
    g_AttackCache[attacker][victim].forceHeadshot = forceHS;
}

public void SDK_OnTakeDamagePost(int victim, int attacker, int inflictor, float fdamage, int damagetype, int weapon, const float damageForce[3], const float damagePosition[3])
{
    if (!IsValidClient(attacker) || !IsValidClient(victim)) return;
    if (GetClientTeam(attacker) != 2 || IsFakeClient(attacker)) return;
    if (!g_Plr[attacker].enable) return;

    int wpn = (weapon == -1) ? inflictor : weapon;
    int dval = g_AttackCache[attacker][victim].damage;
    bool forceHS = g_AttackCache[attacker][victim].forceHeadshot;

    if (g_Plr[attacker].sgmerge && (damagetype & DMG_BUCKSHOT))
        Handle_Shotgun(attacker, victim, wpn, dval, damagetype, damagePosition, forceHS);
    else
        DisplayDamage(victim, attacker, wpn, dval, damagetype, damagePosition, forceHS);

    g_AttackCache[attacker][victim].damage = 0;
    g_AttackCache[attacker][victim].forceHeadshot = false;
}

static void Handle_Shotgun(int attacker, int victim, int weapon, int damage, int damagetype, const float pos[3], bool forceHS)
{
    if (g_SGbuf[attacker][victim].isCreated)
    {
        g_SGbuf[attacker][victim].totalDamage += damage;
        if (forceHS) g_SGbuf[attacker][victim].isHeadshot = true;
    }
    else
    {
        g_SGbuf[attacker][victim].victim = victim;
        g_SGbuf[attacker][victim].attacker = attacker;
        g_SGbuf[attacker][victim].totalDamage = damage;
        g_SGbuf[attacker][victim].damageType = damagetype;
        g_SGbuf[attacker][victim].weapon     = weapon;
        g_SGbuf[attacker][victim].isHeadshot = forceHS;
        g_SGbuf[attacker][victim].damagePosition[0] = pos[0];
        g_SGbuf[attacker][victim].damagePosition[1] = pos[1];
        g_SGbuf[attacker][victim].damagePosition[2] = pos[2];

        DataPack pack = new DataPack();
        pack.WriteCell(attacker);
        pack.WriteCell(victim);
        g_SGbuf[attacker][victim].isCreated = true;
        RequestFrame(NextFrame_SG, pack);
    }
}
public void NextFrame_SG(DataPack pack)
{
    pack.Reset();
    int attacker = pack.ReadCell();
    int victim   = pack.ReadCell();
    delete pack;

    if (!IsValidClient(attacker) || !IsValidClient(victim)) {
        g_SGbuf[attacker][victim].isCreated = false;
        return;
    }

    if (g_SGbuf[attacker][victim].totalDamage > 0)
    {
        float tmp[3];
        tmp[0]=g_SGbuf[attacker][victim].damagePosition[0];
        tmp[1]=g_SGbuf[attacker][victim].damagePosition[1];
        tmp[2]=g_SGbuf[attacker][victim].damagePosition[2];

        DisplayDamage(
            victim, attacker,
            g_SGbuf[attacker][victim].weapon,
            g_SGbuf[attacker][victim].totalDamage,
            g_SGbuf[attacker][victim].damageType,
            tmp, g_SGbuf[attacker][victim].isHeadshot
        );
        g_SGbuf[attacker][victim].totalDamage = 0;
        g_SGbuf[attacker][victim].isHeadshot = false;
    }
    g_SGbuf[attacker][victim].isCreated = false;
}

static int PrintDigitsInOrder(int number)
{
    if (number < 0) return 0;
    if (number == 0) return 1;
    int cnt=0, t=number;
    while (t!=0) { cnt++; t/=10; }
    return cnt;
}

static int GetWpnType(int weapon)
{
    char s[64];
    if (!IsValidEdict(weapon)) return 3;
    GetEdictClassname(weapon, s, sizeof s);

    if (StrContains(s, "inferno", false) != -1 || StrContains(s, "entityflame", false) != -1) return 4;
    if (StrContains(s, "hunting", false) != -1 || StrContains(s, "sniper", false) != -1)   return 0;
    if (StrContains(s, "rifle", false)  != -1 || StrContains(s, "smg", false) != -1)       return 1;
    if (StrContains(s, "melee", false)  != -1) return 2;
    if (StrContains(s, "projectile", false) != -1) return 5;
    return 3;
}

static ReturnTwoFloat CalculatePoint(int client, const float base[3], float x1, float y1, float z1, float x2, float y2, float z2)
{
    ReturnTwoFloat val;
    float ang[3], dir[3];
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
    NormalizeVector(dir, dir);
    NegateVector(dir);

    float up[3] = {0.0,0.0,1.0};
    float localX[3], localY[3];

    if (GetVectorDotProduct(dir, up) > 0.99)
    {
        float right[3] = {0.0,1.0,0.0};
        GetVectorCrossProduct(dir, right, localX);
    } else {
        GetVectorCrossProduct(dir, up, localX);
    }
    NormalizeVector(localX, localX);
    GetVectorCrossProduct(localX, dir, localY);
    NormalizeVector(localY, localY);

    float p1[3], p2[3], v1[3], v2[3];
    v1[0] = x1*localX[0] + y1*localY[0]; v1[1] = x1*localX[1] + y1*localY[1]; v1[2] = x1*localX[2] + y1*localY[2];
    v2[0] = x2*localX[0] + y2*localY[0]; v2[1] = x2*localX[1] + y2*localY[1]; v2[2] = x2*localX[2] + y2*localY[2];
    float n1[3], n2[3];
    n1[0] = z1*dir[0]; n1[1]=z1*dir[1]; n1[2]=z1*dir[2];
    n2[0] = z2*dir[0]; n2[1]=z2*dir[1]; n2[2]=z2*dir[2];

    p1[0] = base[0] + v1[0] + n1[0];
    p1[1] = base[1] + v1[1] + n1[1];
    p1[2] = base[2] + v1[2] + n1[2];

    p2[0] = base[0] + v2[0] + n2[0];
    p2[1] = base[1] + v2[1] + n2[1];
    p2[2] = base[2] + v2[2] + n2[2];

    val.startPt = p1;
    val.endPt   = p2;
    return val;
}

static void DrawNumber(const float StartPos[3], const float EndPos[3], int number, const int[] clients, int totals, float life, const int rgba[4], int speed, float width, float size)
{
    int Ptid[18], totalPt=0;
    switch (number)
    {
        case 0: { int tmp[]={1,5, 0,4, 0,1, 4,5}; for (int i=0;i<8;i++) Ptid[totalPt++]=tmp[i]; }
        case 1: { int tmp[]={1,5}; for (int i=0;i<2;i++) Ptid[totalPt++]=tmp[i]; }
        case 2: { int tmp[]={0,1, 1,3, 3,2, 2,4, 4,5}; for (int i=0;i<10;i++) Ptid[totalPt++]=tmp[i]; }
        case 3: { int tmp[]={0,1, 1,5, 5,4, 2,3}; for (int i=0;i<8;i++) Ptid[totalPt++]=tmp[i]; }
        case 4: { int tmp[]={0,2, 2,3, 1,5}; for (int i=0;i<6;i++) Ptid[totalPt++]=tmp[i]; }
        case 5: { int tmp[]={0,1, 0,2, 3,2, 3,5, 4,5}; for (int i=0;i<10;i++) Ptid[totalPt++]=tmp[i]; }
        case 6: { int tmp[]={0,1, 0,4, 3,2, 3,5, 4,5}; for (int i=0;i<10;i++) Ptid[totalPt++]=tmp[i]; }
        case 7: { int tmp[]={0,1, 1,5}; for (int i=0;i<4;i++) Ptid[totalPt++]=tmp[i]; }
        case 8: { int tmp[]={0,1, 1,5, 3,2, 4,0, 4,5}; for (int i=0;i<10;i++) Ptid[totalPt++]=tmp[i]; }
        case 9: { int tmp[]={0,1, 1,5, 3,2, 2,0, 4,5}; for (int i=0;i<10;i++) Ptid[totalPt++]=tmp[i]; }
    }

    float pt[6][3];
    pt[1] = EndPos; pt[1][2] = StartPos[2];
    pt[2] = StartPos; pt[2][2] = StartPos[2] - size;
    pt[3] = EndPos; pt[3][2] = EndPos[2] + size;
    pt[4] = StartPos; pt[4][2] = EndPos[2];
    pt[0] = StartPos; pt[5] = EndPos;

    for (int k=0;k<9;k++)
    {
        if (2*k+1 > totalPt) break;
        TE_SetupBeamPoints(pt[Ptid[2*k]], pt[Ptid[2*k+1]], g_sprite, 0, 0, 0, life, width, width, 1, 0.0, rgba, speed);
        TE_Send(clients, totals, 0.0);
    }
}

public void OnGameFrame()
{
    // 累加模式帧驱动
    for (int i=1;i<=L4D2_MAXPLAYERS;i++)
    {
        if (g_bNeverFire[i]) continue;
        if (!IsValidClient(i) || !IsPlayerAlive(i) || g_Sum[i][0].lastHitTime + 0.5 < GetGameTime())
        {
            g_bNeverFire[i] = true;
            g_Sum[i][0].needShow = false;
            continue;
        }
        for (int j=1;j<=L4D2_MAXPLAYERS;j++)
        {
            if (!g_Sum[i][j].needShow) continue;
            if (g_Sum[i][j].lastShowTime + UPDATE_INTERVAL >= GetGameTime()) continue;

            if (g_Sum[i][j].lastHitTime + 0.5 < GetGameTime())
            {
                g_Sum[i][j].needShow = false;
                g_Sum[i][j].totalDamage = 0;
                continue;
            }
            DisplayDamage(
                j, i,
                g_Sum[i][j].weapon,
                g_Sum[i][j].totalDamage,
                g_Sum[i][j].damageType,
                g_Sum[i][j].damagePosition,
                g_Sum[i][j].isHeadshot,
                true
            );
            g_Sum[i][j].lastShowTime = GetGameTime();
        }
    }
}

// —— 可见性/分享规则要点 ——
// 1) 自己永远能看见自己的数字（只要 enable=true）。
// 2) “看他人”仅决定我是否接收他人分享（默认 true 便于看管理员分享）。
// 3) 只有管理员可分享（show_other=true）并按 share_scope=0/1（仅自己/队友）分发；普通玩家强制仅自己，不对外分享。
// 4) 旁观管理员可选“查看所有人生还者伤害”。

static void BuildReceivers(int attacker, int victim, int recv[MAXPLAYERS], int &total)
{
    total = 0;
    for (int i=1;i<=MaxClients;i++)
    {
        if (!IsValidClient(i)) continue;

        // 1) 攻击者本人：始终接收
        if (i == attacker) { recv[total++]=i; continue; }

        // 2) 旁观者
        if (GetClientTeam(i) == 1)
        {
            if (IsAdminOrRoot(i) && g_bAdminObsViewAll[i])
                recv[total++] = i; // 旁观管理员“全览”
            continue;
        }

        // 3) 非旁观玩家：只有在攻击者“允许分享+管理员”时才有资格接收
        if (!(IsAdminOrRoot(attacker) && g_Plr[attacker].show_other)) continue;

        // 分享范围：仅自己/队友
        if (g_Plr[attacker].share_scope == 1) // 队友
        {
            if (GetClientTeam(i) != GetClientTeam(attacker)) continue;
        }
        else // 仅自己
        {
            continue; // 不向他人发
        }

        // 对方还需开启“看他人”
        if (!g_Plr[i].see_others) continue;

        recv[total++] = i;
    }
}

static void DisplayDamage(int victim, int attacker, int weapon, int damage, int damagetype, const float damagePosition[3], bool forceHeadshot=false, bool UpdateFrame=false)
{
    if (!IsValidClient(attacker) || !IsValidClient(victim)) return;
    if (!g_Plr[attacker].enable) return;

    if (g_Plr[attacker].wpn_id != weapon && weapon != -1 && IsValidEdict(weapon))
    {
        g_Plr[attacker].wpn_id   = weapon;
        g_Plr[attacker].wpn_type = GetWpnType(weapon);
    }

    int recv[MAXPLAYERS], total;
    BuildReceivers(attacker, victim, recv, total);
    if (total <= 0) return;

    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zombieClass == ZC_TANK && (GetEntProp(victim, Prop_Send, "m_isIncapacitated") == 1 || g_fTankIncap[victim] + 1.0 > GetGameTime()))
    {
        g_fTankIncap[victim] = GetGameTime();
        return;
    }

    int val = damage;
    if (val < 2 && g_Plr[attacker].wpn_type == 5) return;

    int rgba[4];
    int colorIndex;
    if ((damagetype & DMG_HEADSHOT) || forceHeadshot) colorIndex = 4;
    else if (GetClientTeam(victim) == 2) colorIndex = 0;
    else colorIndex = 2;
    rgba[0] = color[colorIndex][0];
    rgba[1] = color[colorIndex][1];
    rgba[2] = color[colorIndex][2];
    rgba[3] = g_Plr[attacker].alpha;

    float life;
    switch (g_Plr[attacker].wpn_type)
    {
        case 0: life = 0.8;
        case 1: life = 0.2;
        case 2: life = 0.6;
        case 3: life = 0.75;
        case 4: life = 0.1;
        case 5: life = 1.5;
        default: life = 0.6;
    }
    if (zombieClass == ZC_BOOMER) if (life < 0.5) life = 0.5;
    if (UpdateFrame) life = UPDATE_INTERVAL;
    if (forceHeadshot)
    {
        g_Sum[attacker][victim].needShow = false;
        float temp_life = g_Sum[attacker][victim].lastHitTime + 0.5 - GetGameTime();
        life = (temp_life > 0.5) ? temp_life : 0.5;
    }

    float z_distance = 40.0, distance, gap, size, width=0.8, vecPos[3], vecOrg[3];
    GetEntPropVector(attacker, Prop_Send, "m_vecOrigin", vecPos);
    GetEntPropVector(victim,   Prop_Send, "m_vecOrigin", vecOrg);

    gap    = g_Plr[attacker].gap;
    size   = g_Plr[attacker].size;

    distance = GetVectorDistance(vecPos, vecOrg, true);
    if (distance > g_Plr[attacker].showdist * g_Plr[attacker].showdist && GetEntProp(attacker, Prop_Send, "m_hZoomOwner") == -1)
        return;

    bool is_near = false;
    if (distance <= 120.0 * 120.0)
    {
        float scale = (120.0 * 120.0) / distance;
        if (scale > 4.0) scale = 4.0;
        gap   /= scale;
        size  /= scale;
        z_distance = 1.0;
        width /= scale;
        is_near = true;
    }
    else if (distance > 70.0 * 70.0 * 100.0)
    {
        float scale = distance / (70.0 * 70.0 * 100.0);
        if (scale > 2.0) scale = 2.0;
        gap   *= scale;
        size  *= scale;
        width *= scale;
    }

    float dmgpos[3];
    dmgpos = damagePosition;
    if (dmgpos[0] == 0.0 || g_Plr[attacker].wpn_type == 2 || g_Plr[attacker].wpn_type == 5)
    {
        dmgpos = vecOrg;
        if (!is_near)
        {
            dmgpos[0] += GetRandomFloat(-20.0, 20.0);
            dmgpos[1] += GetRandomFloat(-20.0, 20.0);
        }
        dmgpos[2] += 56.0;
    }

    int count = PrintDigitsInOrder(val);
    int divisor = 1;
    for (int i=1;i<count;i++) divisor *= 10;

    float half_width = size * float(count) / 2.0;
    float x_start = half_width;
    float scale = (damagePosition[0] < vecOrg[0]) ? -1.0 : 1.0;
    if (is_near) scale = 0.0;

    // 累加模式缓存
    if (g_Plr[attacker].summode && !UpdateFrame)
    {
        if (!g_Sum[attacker][victim].needShow || !g_Sum[attacker][0].needShow)
        {
            g_Sum[attacker][victim].needShow = true;
            g_Sum[attacker][0].needShow = true;
            g_Sum[attacker][victim].lastShowTime = 0.0;
            g_Sum[attacker][victim].totalDamage = val;
            g_bNeverFire[attacker] = false;
        }
        else g_Sum[attacker][victim].totalDamage += val;

        g_Sum[attacker][victim].damagePosition = dmgpos;
        g_Sum[attacker][victim].damageType = damagetype;
        g_Sum[attacker][victim].weapon = weapon;
        g_Sum[attacker][victim].isHeadshot = forceHeadshot;

        float now = GetGameTime();
        if (IsPlayerAlive(victim))
        {
            int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
            if (zc == ZC_TANK) now += 3.0;
            else if (g_Plr[attacker].wpn_type == 3) now += 0.5;
        }
        g_Sum[attacker][victim].lastHitTime = now;
        g_Sum[attacker][0].lastHitTime = now;
        return;
    }

    int rgbaFull[4] ;
    rgbaFull[0] = rgba[0];
    rgbaFull[1] = rgba[1];
    rgbaFull[2] = rgba[2];
    rgbaFull[3] = rgba[3];

    int v = val;
    for (int i=0;i<count;i++)
    {
        float x_end = x_start - size;
        int digit = v / divisor;
        ReturnTwoFloat fval;
        fval = CalculatePoint(attacker,
            dmgpos,
            x_start + scale * g_Plr[attacker].xoff, g_Plr[attacker].yoff + size, z_distance,
            x_end   + scale * g_Plr[attacker].xoff, g_Plr[attacker].yoff - size, z_distance
        );
        DrawNumber(fval.startPt, fval.endPt, digit, recv, total, life, rgbaFull, 1, 0.8, size);
        v %= divisor;
        divisor /= 10;
        x_start = x_start - size - g_Plr[attacker].gap;
    }
}
