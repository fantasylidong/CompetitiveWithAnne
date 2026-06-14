#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>
#include <clientprefs>
#include <hextags>

#undef REQUIRE_PLUGIN
#include <l4dstats>
#include <rpg>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "1.0.0"

// ===== 全局变量 =====
CustomTags g_PlayerTags[MAXPLAYERS + 1];
// Handle g_hTagCookie;  // 暂未使用
Handle g_hVisibilityCookie;
bool g_bHideTag[MAXPLAYERS + 1];
bool g_bL4DStatsAvailable;
bool g_bRPGAvailable;
char g_sConfigPath[PLATFORM_MAX_PATH];

// ===== Forwards =====
Handle g_fTagsUpdated;

// ===== 插件信息 =====
public Plugin myinfo = {
    name = "HexTags Lite",
    author = "东 (Simplified)",
    description = "轻量级称号插件 - 适配veterans和rpg",
    version = PLUGIN_VERSION,
    url = ""
};

// ===== API =====
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    RegPluginLibrary("hextags");

    CreateNative("HexTags_SetClientTag", Native_SetClientTag);
    CreateNative("HexTags_ResetClientTag", Native_ResetClientTag);

    g_fTagsUpdated = new GlobalForward("HexTags_OnTagsUpdated", ET_Ignore, Param_Cell);

    return APLRes_Success;
}

// ===== 插件加载 =====
public void OnPluginStart() {
    LoadTranslations("common.phrases");

    // Cookie
    // g_hTagCookie = RegClientCookie("HexTags_Lite_SelectedTag", "Selected Tag ID", CookieAccess_Private);
    g_hVisibilityCookie = RegClientCookie("HexTags_Lite_Visibility", "Show or hide tags", CookieAccess_Private);

    // 命令
    RegAdminCmd("sm_reloadtags", Cmd_ReloadTags, ADMFLAG_GENERIC, "重新加载称号配置");
    RegConsoleCmd("sm_tagslist", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_chenghao", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_ch", Cmd_TagsList, "选择称号");
    RegConsoleCmd("sm_toggletags", Cmd_ToggleTags, "切换称号显示");

    // 聊天监听
    AddCommandListener(Listener_Say, "say");
    AddCommandListener(Listener_Say, "say_team");

    // 配置路径
    BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), "configs/hextags_lite.cfg");

    // 加载配置
    LoadConfig();
}

public void OnAllPluginsLoaded() {
    g_bL4DStatsAvailable = LibraryExists("l4d_stats");
    g_bRPGAvailable = LibraryExists("rpg");
}

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "l4d_stats")) {
        g_bL4DStatsAvailable = true;
    } else if (StrEqual(name, "rpg")) {
        g_bRPGAvailable = true;
    }
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "l4d_stats")) {
        g_bL4DStatsAvailable = false;
    } else if (StrEqual(name, "rpg")) {
        g_bRPGAvailable = false;
    }
}

// ===== 客户端事件 =====
public void OnClientPutInServer(int client) {
    ResetClientTags(client);
}

public void OnClientPostAdminCheck(int client) {
    if (!IsFakeClient(client)) {
        LoadClientTags(client);
    }
}

public void OnClientCookiesCached(int client) {
    if (!IsValidClient(client)) return;

    char sValue[32];
    GetClientCookie(client, g_hVisibilityCookie, sValue, sizeof(sValue));
    g_bHideTag[client] = (sValue[0] != '\0' && StringToInt(sValue) == 0);

    LoadClientTags(client);
}

public void OnClientDisconnect(int client) {
    ResetClientTags(client);
}

// ===== 命令处理 =====
public Action Cmd_ReloadTags(int client, int args) {
    LoadConfig();

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            LoadClientTags(i);
        }
    }

    ReplyToCommand(client, "[HexTags] 配置重新加载完成！");
    return Plugin_Handled;
}

public Action Cmd_TagsList(int client, int args) {
    if (!client) {
        ReplyToCommand(client, "[HexTags] 该命令只能在游戏中使用。");
        return Plugin_Handled;
    }

    ShowTagsMenu(client);
    return Plugin_Handled;
}

public Action Cmd_ToggleTags(int client, int args) {
    if (!IsValidClient(client)) return Plugin_Handled;

    g_bHideTag[client] = !g_bHideTag[client];
    SetClientCookie(client, g_hVisibilityCookie, g_bHideTag[client] ? "0" : "1");

    if (g_bHideTag[client]) {
        ReplyToCommand(client, "[HexTags] 称号已隐藏");
    } else {
        ReplyToCommand(client, "[HexTags] 称号已显示");
        LoadClientTags(client);
    }

    return Plugin_Handled;
}

// ===== 聊天处理 =====
public Action Listener_Say(int client, const char[] command, int argc) {
    if (!IsValidClient(client) || g_bHideTag[client]) {
        return Plugin_Continue;
    }

    char sMessage[MAXLENGTH_MESSAGE];
    GetCmdArgString(sMessage, sizeof(sMessage));
    StripQuotes(sMessage);

    if (strlen(sMessage) == 0) {
        return Plugin_Continue;
    }

    // 构建带称号的消息
    char sName[MAXLENGTH_NAME];
    GetClientName(client, sName, sizeof(sName));

    char sFullName[MAXLENGTH_NAME];
    FormatEx(sFullName, sizeof(sFullName), "%s%s%s",
        g_PlayerTags[client].ChatTag,
        g_PlayerTags[client].NameColor,
        sName);

    char sFullMessage[MAXLENGTH_MESSAGE];
    FormatEx(sFullMessage, sizeof(sFullMessage), "%s%s",
        g_PlayerTags[client].ChatColor,
        sMessage);

    // 发送消息
    int team = GetClientTeam(client);
    bool teamChat = StrEqual(command, "say_team");

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsClientInGame(i)) continue;
        if (teamChat && GetClientTeam(i) != team) continue;

        CPrintToChat(i, "{default}%s{default} : %s", sFullName, sFullMessage);
    }

    return Plugin_Handled;
}

// ===== 配置加载 =====
void LoadConfig() {
    KeyValues kv = new KeyValues("HexTags");

    if (!kv.ImportFromFile(g_sConfigPath)) {
        LogError("[HexTags] 无法加载配置文件: %s", g_sConfigPath);
        delete kv;
        return;
    }

    delete kv;
}

void LoadClientTags(int client) {
    if (!IsValidClient(client) || g_bHideTag[client]) return;

    ResetClientTags(client);

    KeyValues kv = new KeyValues("HexTags");
    if (!kv.ImportFromFile(g_sConfigPath)) {
        delete kv;
        return;
    }

    // 解析配置
    if (kv.GotoFirstSubKey()) {
        do {
            char sSectionName[64];
            kv.GetSectionName(sSectionName, sizeof(sSectionName));

            if (CheckSelector(client, sSectionName, kv)) {
                // 读取称号数据
                kv.GetString("TagName", g_PlayerTags[client].TagName, 32, sSectionName);
                kv.GetString("ScoreTag", g_PlayerTags[client].ScoreTag, 32, "");
                kv.GetString("ChatTag", g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "");
                kv.GetString("ChatColor", g_PlayerTags[client].ChatColor, 32, "{default}");
                kv.GetString("NameColor", g_PlayerTags[client].NameColor, 32, "{teamcolor}");
                g_PlayerTags[client].ForceTag = (kv.GetNum("ForceTag", 1) == 1);

                // 处理变量替换
                ProcessTagVariables(client);

                break; // 只应用第一个匹配的
            }
        } while (kv.GotoNextKey());
    }

    delete kv;

    // 触发Forward
    Call_StartForward(g_fTagsUpdated);
    Call_PushCell(client);
    Call_Finish();
}

bool CheckSelector(int client, const char[] selector, KeyValues kv) {
    // 注意：kv参数保留用于未来扩展
    #pragma unused kv

    // 默认选择器
    if (StrEqual(selector, "default", false)) {
        return true;
    }

    // 人类玩家
    if (StrEqual(selector, "human", false) && !IsFakeClient(client)) {
        return true;
    }

    // Bot
    if (StrEqual(selector, "bot", false) && IsFakeClient(client)) {
        return true;
    }

    // SteamID
    if (strlen(selector) > 11 && StrContains(selector, "STEAM_", false) == 0) {
        char steamid[32];
        if (!GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid))) {
            return false;
        }

        if (StrEqual(steamid, selector)) {
            return true;
        }

        // 尝试反转 STEAM_0/STEAM_1
        steamid[6] = (steamid[6] == '1') ? '0' : '1';
        if (StrEqual(steamid, selector)) {
            return true;
        }
    }

    // 管理员标志 (单个字符)
    if (strlen(selector) == 1) {
        AdminId admin = GetUserAdmin(client);
        if (admin != INVALID_ADMIN_ID) {
            AdminFlag flag;
            if (FindFlagByChar(selector[0], flag) && admin.HasFlag(flag)) {
                return true;
            }
        }
    }

    // 管理员组 (@开头)
    if (selector[0] == '@') {
        AdminId admin = GetUserAdmin(client);
        if (admin != INVALID_ADMIN_ID) {
            char sGroup[32];
            GroupId group = admin.GetGroup(0, sGroup, sizeof(sGroup));
            if (group != INVALID_GROUP_ID && StrEqual(selector[1], sGroup)) {
                return true;
            }
        }
    }

    // 积分等级 (#开头) - 使用l4dstats或rpg的积分
    if (selector[0] == '#') {
        int requiredScore = StringToInt(selector[1]);
        int clientScore = 0;

        // 优先使用l4dstats
        if (g_bL4DStatsAvailable) {
            clientScore = l4dstats_GetClientScore(client);
        }
        // 如果没有l4dstats，尝试使用rpg的积分
        else if (g_bRPGAvailable) {
            clientScore = L4D_RPG_GetValue(client, INDEX_POINTS);
        }

        if (clientScore >= requiredScore) {
            return true;
        }
    }

    return false;
}

void ProcessTagVariables(int client) {
    // 时间
    char sTime[16];
    FormatTime(sTime, sizeof(sTime), "%H:%M");
    ReplaceString(g_PlayerTags[client].ScoreTag, 32, "{time}", sTime);
    ReplaceString(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "{time}", sTime);

    // 积分
    if (g_bL4DStatsAvailable) {
        char sScore[16];
        IntToString(l4dstats_GetClientScore(client), sScore, sizeof(sScore));
        ReplaceString(g_PlayerTags[client].ScoreTag, 32, "{score}", sScore);
        ReplaceString(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "{score}", sScore);
    } else if (g_bRPGAvailable) {
        char sScore[16];
        IntToString(L4D_RPG_GetValue(client, INDEX_POINTS), sScore, sizeof(sScore));
        ReplaceString(g_PlayerTags[client].ScoreTag, 32, "{score}", sScore);
        ReplaceString(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, "{score}", sScore);
    }
}

void ResetClientTags(int client) {
    g_PlayerTags[client].ScoreTag[0] = '\0';
    g_PlayerTags[client].ChatTag[0] = '\0';
    strcopy(g_PlayerTags[client].ChatColor, 32, "{default}");
    strcopy(g_PlayerTags[client].NameColor, 32, "{teamcolor}");
    g_PlayerTags[client].ForceTag = true;
    g_PlayerTags[client].TagName[0] = '\0';
    g_PlayerTags[client].SectionId = 0;
    g_bHideTag[client] = false;
}

// ===== 菜单 =====
void ShowTagsMenu(int client) {
    Menu menu = new Menu(TagsMenuHandler);
    menu.SetTitle("选择你的称号:");

    KeyValues kv = new KeyValues("HexTags");
    if (!kv.ImportFromFile(g_sConfigPath)) {
        delete kv;
        CPrintToChat(client, "{red}[HexTags] {default}配置文件加载失败");
        return;
    }

    int count = 0;
    if (kv.GotoFirstSubKey()) {
        do {
            char sSectionName[64];
            kv.GetSectionName(sSectionName, sizeof(sSectionName));

            if (CheckSelector(client, sSectionName, kv)) {
                char sTagName[64];
                kv.GetString("TagName", sTagName, sizeof(sTagName), sSectionName);

                char sInfo[8];
                IntToString(count, sInfo, sizeof(sInfo));
                menu.AddItem(sInfo, sTagName);
                count++;
            }
        } while (kv.GotoNextKey());
    }

    delete kv;

    if (count == 0) {
        CPrintToChat(client, "{red}[HexTags] {default}没有可用的称号");
        delete menu;
        return;
    }

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int TagsMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        LoadClientTags(param1);
        CPrintToChat(param1, "{green}[HexTags] {default}称号已更新！");
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

// ===== Native实现 =====
public int Native_SetClientTag(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsValidClient(client)) {
        return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client %d", client);
    }

    int tagType = GetNativeCell(2);
    char sTag[MAXLENGTH_NAME];
    GetNativeString(3, sTag, sizeof(sTag));

    switch (tagType) {
        case 0: strcopy(g_PlayerTags[client].ScoreTag, 32, sTag);           // ScoreTag
        case 1: strcopy(g_PlayerTags[client].ChatTag, MAXLENGTH_NAME, sTag); // ChatTag
        case 2: strcopy(g_PlayerTags[client].ChatColor, 32, sTag);          // ChatColor
        case 3: strcopy(g_PlayerTags[client].NameColor, 32, sTag);          // NameColor
    }

    return 0;
}

public int Native_ResetClientTag(Handle plugin, int numParams) {
    int client = GetNativeCell(1);
    if (!IsValidClient(client)) {
        return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client %d", client);
    }

    LoadClientTags(client);
    return 0;
}

// ===== 辅助函数 =====
bool IsValidClient(int client) {
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}
