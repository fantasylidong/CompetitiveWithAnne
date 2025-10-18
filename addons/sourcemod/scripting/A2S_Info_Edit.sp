#pragma semicolon 1 
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>               // https://forums.alliedmods.net/showthread.php?t=321696
#include <sourcescramble>            // https://github.com/nosoop/SMExt-SourceScramble
#include <localizer>                 // https://github.com/dragokas/SM-Localizer
#include <l4d2_source_keyvalues>     // https://github.com/fdxx/l4d2_source_keyvalues

/*
    部分代码来源:
    fdxx => l4d2_source_keyvalues
    umlka => map_changer
    dragokas => SM-Localizer
*/

#define GAMEDATA                "A2S_Info_Edit"

#define PLUGIN_NAME             "A2S_INFO Edit | A2S_INFO 信息修改"
#define PLUGIN_AUTHOR           "yuzumi"
#define PLUGIN_VERSION          "1.1.3"
#define PLUGIN_DESCRIPTION      "DIY Server A2S_INFO Information | 定义自己服务器的A2S_INFO信息"
#define PLUGIN_URL              "https://github.com/joyrhyme/L4D2-Plugins/tree/main/A2S_Info_Edit"
#define CVAR_FLAGS              FCVAR_NOTIFY

#define DEBUG                   0
#define BENCHMARK               0
#if BENCHMARK
    #include <profiler>
    Profiler g_profiler;
#endif

#define TRANSLATION_MISSIONS    "a2s_missions.phrases.txt"
#define TRANSLATION_CHAPTERS    "a2s_chapters.phrases.txt"
#define A2S_SETTING             "a2s_info_edit.cfg"

// 预声明
void CacheMissionInfo();

// 游戏本地化文本
Localizer loc;

// 记录内存修补数据
MemoryPatch
    g_mMapNamePatch,
    g_mGameDesPatch;

// SDKCall地址
Address
    g_pSteam3Server,
    g_pDirector,
    g_pMatchExtL4D;

// SDKCall句柄
Handle
    g_hSDK_GetSteam3Server,
    g_hSDK_SendServerInfo,
    g_hSDK_GetAllMissions;

// 各初始化状态
bool
    g_bLocInit,
    g_bIsFinalMap,
    g_bMissionCached,
    g_bFinaleStarted,
    g_bisAllBotGame;

// ConVars
ConVar
    g_hMPGameMode,
    g_hMapNameLang,
    g_hMapNameType,
    g_hAllBotGame,

    // —— 动态描述 ——
    g_hDescDynamic,
    g_hDescFormat,
    g_hReadyCfgName,
    g_hInfectedLimit,
    g_hVsSIRespawn,
    g_hAddonsEclipse,
    g_hSurvivorLimit,
    g_hMaxPZ,

    // —— OnGameFrame 节流 ——
    g_hFrameUpdate,
    g_hFrameInterval;

// 存放修改后地图名称/游戏描述/模式名的变量
char
    g_cMap[64],
    g_cMode[64],
    g_cLanguage[5],
    g_cGameDes[64],
    g_cInFinale[32],
    g_cNotInFinale[32],
    g_cMapName[64],
    g_cCampaignName[64],
    g_cChapterName[64],
    g_cGameDesBase[64];

// 最近一次已推送到 A2S 的值（用于去重）
char
    g_cLastPushedDesc[128],
    g_cLastPushedMap[64];

// 存放数值的变量
int
    g_iMapNameOS,
    g_iGameDesOS,
    g_iChapterNum,
    g_iChapterMaxNum,
    g_iMapNameType;

StringMap
    g_smExclude,
    g_smMissionMap;

enum struct esPhrase 
{ 
	char key[64]; 
	char val[64]; 
	int official; 
}

public Plugin myinfo = {
    name = PLUGIN_NAME,
    author = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version = PLUGIN_VERSION,
    url = PLUGIN_URL
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
    EngineVersion iEngineVersion = GetEngineVersion();
    if(iEngineVersion != Engine_Left4Dead2 && !IsDedicatedServer()) {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2 Dedicated Server!");
        return APLRes_SilentFailure;
    }
    return APLRes_Success;
}

public void OnPluginStart() {
    g_smMissionMap = new StringMap();

    // 初始化GameData和Kv文件
    InitKvFile();
    InitGameData();

    // 创建Cvars
    g_hMapNameType = CreateConVar("a2s_info_mapname_type", "5", "A2S_INFO MapName DisplayType. 1.Mission, 2.Mission&Chapter, 3.Mission&FinaleType, 4.Mission&Chapter&FinaleType, 5.Mission&[ChapterNum|MaxChapter]", CVAR_FLAGS, true, 1.0, true, 5.0);
    g_hMapNameLang = CreateConVar("a2s_info_mapname_language", "chi", "What language is used in the generated PhraseFile to replace the TranslatedText of en? (Please Delete All A2S_Edit PhraseFile After Change This Cvar to Regenerate)", CVAR_FLAGS);
    
    g_hMPGameMode = FindConVar("mp_gamemode");
    g_hAllBotGame = FindConVar("sb_all_bot_game");
    if (g_hAllBotGame.IntValue == 1) g_bisAllBotGame = true; else g_hAllBotGame.IntValue = 1;

    // 动态描述
    g_hDescDynamic   = CreateConVar("a2s_info_desc_dynamic", "1", "是否根据 cfg/人数/MOD 动态生成 A2S 描述（0=关，1=开）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hDescFormat    = CreateConVar("a2s_info_desc_format", "{Base}{AnneHappy}{Full}{MOD}{Confogl}", "A2S 描述格式：{Base}{AnneHappy}{Full}{MOD}{Confogl}", CVAR_FLAGS);
    g_hReadyCfgName  = FindConVar("l4d_ready_cfg_name");
    g_hInfectedLimit = FindConVar("l4d_infected_limit");
    g_hVsSIRespawn   = FindConVar("versus_special_respawn_interval");
    g_hAddonsEclipse = FindConVar("l4d2_addons_eclipse");
    g_hSurvivorLimit = FindConVar("survivor_limit");
    g_hMaxPZ         = FindConVar("z_max_player_zombies");

    // OnGameFrame 节流
    g_hFrameUpdate   = CreateConVar("a2s_info_frame_update", "1", "是否在 OnGameFrame 节流发送 A2S（0=关，1=开）", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hFrameInterval = CreateConVar("a2s_info_frame_interval", "0.7", "OnGameFrame 轮询间隔（秒）", CVAR_FLAGS, true, 0.1, true, 10.0);

    // 初始化Cvars
    GetCvars_Mode();
    GetCvars_Lang();
    GetCvars();
    
    g_hMapNameLang.AddChangeHook(ConVarChanged_Lang);
    g_hMPGameMode.AddChangeHook(ConVarChanged_Mode);
    g_hMapNameType.AddChangeHook(ConVarChanged_Cvars);

    // 动态描述变动仅重建，不推送
    g_hDescDynamic.AddChangeHook(ConVarChanged_Cvars);
    g_hDescFormat.AddChangeHook(ConVarChanged_Cvars);
    if (g_hReadyCfgName)  g_hReadyCfgName.AddChangeHook(ConVarChanged_Cvars);
    if (g_hInfectedLimit) g_hInfectedLimit.AddChangeHook(ConVarChanged_Cvars);
    if (g_hVsSIRespawn)   g_hVsSIRespawn.AddChangeHook(ConVarChanged_Cvars);
    if (g_hAddonsEclipse) g_hAddonsEclipse.AddChangeHook(ConVarChanged_Cvars);
    if (g_hSurvivorLimit) g_hSurvivorLimit.AddChangeHook(ConVarChanged_Cvars);
    if (g_hMaxPZ)         g_hMaxPZ.AddChangeHook(ConVarChanged_Cvars);

    //AutoExecConfig(true, "A2S_Edit");

    // 事件：只更新内部状态/地图名，不推送
    HookEvent("round_end",    Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("finale_start", Event_FinaleStart,EventHookMode_PostNoCopy);
    #if DEBUG
        HookEvent("finale_radio_start",        Event_finale_radio,      EventHookMode_PostNoCopy);
        HookEvent("gauntlet_finale_start",     Event_gauntlet_finale,   EventHookMode_PostNoCopy);
        HookEvent("explain_stage_finale_start",Event_explain_stage_finale, EventHookMode_PostNoCopy);
    #else
        HookEvent("finale_radio_start",        Event_FinaleStart,       EventHookMode_PostNoCopy);
        HookEvent("gauntlet_finale_start",     Event_FinaleStart,       EventHookMode_PostNoCopy);
    #endif

    // 命令
    RegAdminCmd("sm_a2s_edit_reload", cmdReload, ADMFLAG_ROOT, "Reload A2S_EDIT Setting");

    // 本地化
    loc = new Localizer();
    loc.Delegate_InitCompleted(OnPhrasesReady);
}

void ConVarChanged_Mode(ConVar convar, const char[] oldValue, const char[] newValue) {
    GetCvars_Mode();
    // 模式变 → 任务映射与名称都要重建
    g_bMissionCached = false;
    CacheMissionInfo();
    ChangeMapName(); // 先按当前可用信息重算一次（下一帧推送）
}
void ConVarChanged_Cvars(ConVar convar, const char[] oldValue, const char[] newValue) {
    GetCvars();
    ChangeMapName(); // 格式/显示类型变化也立刻重算
}
void ConVarChanged_Lang(ConVar convar, const char[] oldValue, const char[] newValue) {
    GetCvars_Lang();
}

void GetCvars_Mode() {
    g_hMPGameMode.GetString(g_cMode, sizeof(g_cMode));
}
void GetCvars_Lang() {
    g_hMapNameLang.GetString(g_cLanguage, sizeof(g_cLanguage));
    if (GetLanguageByCode(g_cLanguage) == -1) {
        LogError("SourceMod unsupport this language: %s , Please chcek language setting. A2S_Edit change to use chi generate phrases files!", g_cLanguage);
        Format(g_cLanguage, sizeof(g_cLanguage), "chi");
    }
}
void GetCvars() {
    g_iMapNameType = g_hMapNameType.IntValue;
}

public void OnConfigsExecuted() {
    GetCvars();
    GetCvars_Mode();
    if(!g_bMissionCached) CacheMissionInfo();
    ChangeMapName(); // 配置执行后重算一次
}

// 重载配置
Action cmdReload(int client, int args) {
    if (!InitKvFile()) {
        PrintToServer("[A2S_Edit] Reload a2s_edit.cfg failed!");
        return Plugin_Handled;
    }
    PrintToServer("[A2S_Edit] a2s_edit.cfg is reloaded");
    ChangeMapName();
    return Plugin_Handled;
}

// 地图开始
public void OnMapStart() {
    ChangeMapName(); // 开图先算一次（可能是英文兜底）
    if (GetFeatureStatus(FeatureType_Native, "Left4DHooks_Version") != FeatureStatus_Available || Left4DHooks_Version() < 1135 || !L4D_HasMapStarted()) {
        RequestFrame(OnMapStartedPost);
    } else {
        OnMapStartedPost();
    }
}

// 地图结束
public void OnMapEnd() { g_bFinaleStarted = false; }

#if DEBUG
void Event_finale_radio(Event hEvent, const char[] name, bool dontBroadcast) {
    if (!g_bFinaleStarted) { g_bFinaleStarted = true; ChangeMapName(); }
}
void Event_gauntlet_finale(Event hEvent, const char[] name, bool dontBroadcast) {
    if (!g_bFinaleStarted) { g_bFinaleStarted = true; ChangeMapName(); }
}
void Event_explain_stage_finale(Event hEvent, const char[] name, bool dontBroadcast) {
    if (!g_bFinaleStarted) { g_bFinaleStarted = true; ChangeMapName(); }
}
#endif

void Event_FinaleStart(Event hEvent, const char[] name, bool dontBroadcast) {
    if (!g_bFinaleStarted) { g_bFinaleStarted = true; ChangeMapName(); }
}

void Event_RoundEnd(Event hEvent, const char[] name, bool dontBroadcast) {
    OnMapEnd();
    ChangeMapName();
}

// 首开时等就绪的定时器
Action tChangeMapName(Handle timer) {
    ChangeMapName();
    if (g_bLocInit && g_bMissionCached) {
        if (!g_bisAllBotGame) g_hAllBotGame.IntValue = 0;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

void OnMapStartedPost() {
    g_bIsFinalMap   = L4D_IsMissionFinalMap();
    g_iChapterMaxNum= L4D_GetMaxChapters();
    g_iChapterNum   = L4D_GetCurrentChapter();
    ChangeMapName();
    if (!g_bLocInit || !g_bMissionCached) {
        CreateTimer(1.0, tChangeMapName, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    }
}

// —— 名字重算（只更新字符串；不推送）——
void ChangeMapName() {
    GetCurrentMap(g_cMap, sizeof(g_cMap));

    // 任务码映射（没命中则为空）
    g_smMissionMap.GetString(g_cMap, g_cCampaignName, sizeof(g_cCampaignName));

    // 任务中文：未映射时，用地图文件名兜底
    fmt_Translate(g_cCampaignName, g_cCampaignName, sizeof(g_cCampaignName), 0, g_cMap);

    // 章节中文：不存在则空串
    fmt_Translate(g_cMap, g_cChapterName, sizeof(g_cChapterName), 0, "");

    switch (g_iMapNameType) {
        case 1: FormatEx(g_cMapName, sizeof(g_cMapName), "%s", g_cCampaignName);
        case 2: FormatEx(g_cMapName, sizeof(g_cMapName), "%s [%s]", g_cCampaignName, g_cChapterName);
        case 3:
        {
            if (g_bIsFinalMap) {
                if (g_bFinaleStarted) FormatEx(g_cMapName, sizeof(g_cMapName), "%s - %s", g_cCampaignName, g_cInFinale);
                else                   FormatEx(g_cMapName, sizeof(g_cMapName), "%s - %s", g_cCampaignName, g_cNotInFinale);
            } else FormatEx(g_cMapName, sizeof(g_cMapName), "%s", g_cCampaignName);
        }
        case 4:
        {
            if (g_bIsFinalMap) {
                if (g_bFinaleStarted) FormatEx(g_cMapName, sizeof(g_cMapName), "%s [%s] - %s", g_cCampaignName, g_cChapterName, g_cInFinale);
                else                   FormatEx(g_cMapName, sizeof(g_cMapName), "%s [%s] - %s", g_cCampaignName, g_cChapterName, g_cNotInFinale);
            } else FormatEx(g_cMapName, sizeof(g_cMapName), "%s [%s]", g_cCampaignName, g_cChapterName);
        }
        case 5: FormatEx(g_cMapName, sizeof(g_cMapName), "%s [%d/%d]", g_cCampaignName, g_iChapterNum, g_iChapterMaxNum);
        default:FormatEx(g_cMapName, sizeof(g_cMapName), "%s", g_cCampaignName);
    }

    // 标记：下一帧推送
    g_cLastPushedMap[0] = '\0';
}

void InitGameData() {
    char sPath[PLATFORM_MAX_PATH];
    Format(g_cMapName, sizeof(g_cMapName), "服务器初始化中");

    BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
    if (!FileExists(sPath)) SetFailState("[A2S_EDIT] Missing required file: \"%s\" .", sPath);
    GameData hGameData = new GameData(GAMEDATA);
    if (!hGameData) SetFailState("[A2S_EDIT] Failed to load \"%s.txt\" gamedata.", GAMEDATA);
    
    // SDKCall
    g_pDirector = hGameData.GetAddress("CDirector");
    if (!g_pDirector) SetFailState("[A2S_EDIT] Failed to find address: \"CDirector\"");
    g_pMatchExtL4D = hGameData.GetAddress("g_pMatchExtL4D");
    if (!g_pMatchExtL4D) SetFailState("[A2S_EDIT] Failed to find address: \"g_pMatchExtL4D\"");

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetVirtual(0);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    if (!(g_hSDK_GetAllMissions = EndPrepSDKCall()))
        SetFailState("[A2S_EDIT] Failed to create SDKCall: \"MatchExtL4D::GetAllMissions\"");

    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "GetSteam3Server");
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    if (!(g_hSDK_GetSteam3Server = EndPrepSDKCall()))
        SetFailState("[A2S_EDIT] Failed to create SDKCall: \"GetSteamServer\"");

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SendUpdatedServerDetails");
    if (!(g_hSDK_SendServerInfo = EndPrepSDKCall()))
        SetFailState("[A2S_EDIT] Failed to create SDKCall: \"SendServerInfo\"");

    // MemoryPatch
    g_iMapNameOS = hGameData.GetOffset("OS") ? 4 : 1;
    g_mMapNamePatch = MemoryPatch.CreateFromConf(hGameData, "RebuildInfo_MapName");
    if (!g_mMapNamePatch.Validate())
        SetFailState("[A2S_EDIT] Failed to verify patch: \"RebuildInfo_MapName\"");
    else if (g_mMapNamePatch.Enable()) {
        StoreToAddress(g_mMapNamePatch.Address + view_as<Address>(g_iMapNameOS), view_as<int>(GetAddressOfString(g_cMapName)), NumberType_Int32);
        PrintToServer("[A2S_EDIT] Enabled patch: \"RebuildInfo_MapName\"");
    }

    g_iGameDesOS = hGameData.GetOffset("OS") ? 4 : 1;
    g_mGameDesPatch = MemoryPatch.CreateFromConf(hGameData, "GameDescription");
    if (!g_mGameDesPatch.Validate())
        SetFailState("Failed to verify patch: \"GameDescription\"");
    else if (g_mGameDesPatch.Enable()) {
        StoreToAddress(g_mGameDesPatch.Address + view_as<Address>(g_iGameDesOS), view_as<int>(GetAddressOfString(g_cGameDes)), NumberType_Int32);
        PrintToServer("[A2S_EDIT] Enabled patch: \"GameDescription\"");
    }

    delete hGameData;

    // 排除不生成翻译的地图
    g_smExclude = new StringMap();
    g_smExclude.SetValue("credits", 1);
    g_smExclude.SetValue("HoldoutChallenge", 1);
    g_smExclude.SetValue("HoldoutTraining", 1);
    g_smExclude.SetValue("parishdash", 1);
    g_smExclude.SetValue("shootzones", 1);
}

// 初始化插件的Kv文件
bool InitKvFile() {
    char kvPath[PLATFORM_MAX_PATH];
    KeyValues kv;
    File file;
    BuildPath(Path_SM, kvPath, sizeof(kvPath), "data/%s", A2S_SETTING);

    kv = new KeyValues("a2s_edit");
    if (!FileExists(kvPath)) {
        file = OpenFile(kvPath, "w");
        if (!file) { LogError("Cannot open file: \"%s\"", kvPath); return false; }
        if (!file.WriteLine("")) { LogError("Cannot write file line: \"%s\"", kvPath); delete file; return false; }
        delete file;

        kv.SetString("description", "Anne电信服");
        kv.SetString("inFinale", "救援正进行");
        kv.SetString("notInFinale", "救援未进行");

        kv.Rewind();
        kv.ExportToFile(kvPath);
    } else if (!kv.ImportFromFile(kvPath)) {
        return false;
    }

    kv.GetString("description", g_cGameDes,     sizeof(g_cGameDes),     "Anne电信服");
    kv.GetString("description", g_cGameDesBase, sizeof(g_cGameDesBase), "Anne电信服");
    kv.GetString("inFinale",    g_cInFinale,    sizeof(g_cInFinale),    "救援正进行");
    kv.GetString("notInFinale", g_cNotInFinale, sizeof(g_cNotInFinale), "救援未进行");

    delete kv;
    return true;
}

// 地图是否存在
stock bool IsMapValidEx(const char[] map) {
    if (!map[0]) return false;
    char foundmap[1];
    return FindMap(map, foundmap, sizeof foundmap) == FindMap_Found;
}

// 获取本地化后文本
void fmt_Translate(const char[] phrase, char[] buffer, int maxlength, int client, const char[] defvalue="") {
    if (!TranslationPhraseExists(phrase))
        strcopy(buffer, maxlength, defvalue);
    else
        Format(buffer, maxlength, "%T", phrase, client);
}

// 本地化完成 → 写短语文件、加载、重算名字
void OnPhrasesReady() {
    g_bLocInit = false;
    PrintToServer("[A2S_Edit] Localizer Init...");

    #if BENCHMARK
        g_profiler = new Profiler();
        g_profiler.Start();
    #endif

    esPhrase esp;
    ArrayList al_missions = new ArrayList(sizeof esPhrase);
    ArrayList al_chapters = new ArrayList(sizeof esPhrase);

    int value;
    char phrase[64];
    char translation[64];

    SourceKeyValues kvModes;
    SourceKeyValues kvChapters;
    SourceKeyValues kvMissions = SDKCall(g_hSDK_GetAllMissions, g_pMatchExtL4D);
    for (kvMissions = kvMissions.GetFirstTrueSubKey(); !kvMissions.IsNull(); kvMissions = kvMissions.GetNextTrueSubKey()) {
        kvMissions.GetName(phrase, sizeof(phrase));
        if (g_smExclude.GetValue(phrase, value)) continue;

        kvModes = kvMissions.FindKey("modes");
        if (kvModes.IsNull()) continue;

        value = kvMissions.GetInt("builtin");
        if (al_missions.FindString(phrase) == -1) {
            kvMissions.GetString("DisplayTitle", translation, sizeof(translation), "N/A");
            strcopy(esp.key, sizeof(esp.key), phrase);
            strcopy(esp.val, sizeof(esp.val), !strcmp(translation, "N/A") ? phrase : translation);
            esp.official = value;
            al_missions.PushArray(esp);
        }

        for (kvModes = kvModes.GetFirstTrueSubKey(); !kvModes.IsNull(); kvModes = kvModes.GetNextTrueSubKey()) {
            for (kvChapters = kvModes.GetFirstTrueSubKey(); !kvChapters.IsNull(); kvChapters = kvChapters.GetNextTrueSubKey()) {
                kvChapters.GetString("Map", phrase, sizeof(phrase), "N/A");
                if (!strcmp(phrase, "N/A") || FindCharInString(phrase, '/') != -1) continue;
                if (al_chapters.FindString(phrase) == -1) {
                    kvChapters.GetString("DisplayName", translation, sizeof(translation), "N/A");
                    strcopy(esp.key, sizeof(esp.key), phrase);
                    strcopy(esp.val, sizeof(esp.val), !strcmp(translation, "N/A") ? phrase : translation);
                    esp.official = value;
                    al_chapters.PushArray(esp);
                }
            }
        }
    }

    char FilePath[PLATFORM_MAX_PATH];
    BuildPhrasePath(FilePath, sizeof(FilePath), TRANSLATION_MISSIONS, "en");
    BuildPhraseFile(FilePath, al_missions, esp);

    BuildPhrasePath(FilePath, sizeof(FilePath), TRANSLATION_CHAPTERS, "en");
    BuildPhraseFile(FilePath, al_chapters, esp);

    loc.Close();
    delete al_missions;
    delete al_chapters;

    value = 0;
    BuildPhrasePath(FilePath, sizeof(FilePath), TRANSLATION_MISSIONS, "en");
    if (FileExists(FilePath)) { value = 1; LoadTranslations("a2s_missions.phrases"); }
    BuildPhrasePath(FilePath, sizeof(FilePath), TRANSLATION_CHAPTERS, "en");
    if (FileExists(FilePath)) { value = 1; LoadTranslations("a2s_chapters.phrases"); }
    if (value) { InsertServerCommand("sm_reload_translations"); ServerExecute(); }

    #if BENCHMARK
        g_profiler.Stop();
        LogError("Export Phrases Time: %f", g_profiler.Time);
    #endif

    g_bLocInit = true;

    // 本地化就绪后立刻重算一次（从英文兜底切到中文）
    ChangeMapName();

    PrintToServer("[A2S_Edit] Localizer Init Complete...");
}

// 根据地图信息生成翻译文件（修正版：在各自区块下写 en 与 g_cLanguage）
void BuildPhraseFile(char[] FilePath, ArrayList array, esPhrase esp)
{
    KeyValues kv = new KeyValues("Phrases");

    // 如果已存在就读入，否则先创建一个空文件壳
    if (FileExists(FilePath)) {
        if (!kv.ImportFromFile(FilePath)) {
            LogError("Cannot import file: \"%s\"", FilePath);
            delete kv;
            return;
        }
    } else {
        File f = OpenFile(FilePath, "w");
        if (!f) { LogError("Cannot open file: \"%s\"", FilePath); delete kv; return; }
        f.WriteLine("");
        delete f;
    }

    char enbuf[64], langbuf[64], tmp[2];
    int len = array.Length;

    for (int i = 0; i < len; i++) {
        array.GetArray(i, esp);

        // 计算 en 与目标语言文本
        enbuf[0] = '\0';
        langbuf[0] = '\0';

        if (esp.official) {
            // 官方图：从 Localizer 拿英文与目标语言
            loc.PhraseTranslateToLang(esp.val, enbuf,  sizeof(enbuf),  _, _, "en", esp.val);
            if (strcmp(g_cLanguage, "en") != 0) {
                loc.PhraseTranslateToLang(esp.val, langbuf, sizeof(langbuf), _, _, g_cLanguage, enbuf);
            }
        } else {
            // 第三方图：用原值当英文
            strcopy(enbuf, sizeof(enbuf), esp.val);

            // 想要没有中文资源时也写同样文本到 chi，可打开下面这行
            // if (strcmp(g_cLanguage, "en") != 0) strcopy(langbuf, sizeof(langbuf), esp.val);
        }

        // 进入该地图/任务的块
        if (!kv.JumpToKey(esp.key, true)) {
            // 正常不会失败，保险返回
            continue;
        }

        // 写 en（若已经存在，则保留用户手改的值）
        kv.GetString("en", tmp, sizeof(tmp), "");
        if (!tmp[0]) {
            kv.SetString("en", enbuf[0] ? enbuf : esp.val);
        }

        // 写指定语言（例如 chi），同样只在不存在时写入
        if (strcmp(g_cLanguage, "en") != 0 && langbuf[0]) {
            kv.GetString(g_cLanguage, tmp, sizeof(tmp), "");
            if (!tmp[0]) {
                kv.SetString(g_cLanguage, langbuf);
            }
        }

        // 退回到根（不是退回到父层级后继续下潜，避免把语言键写到顶层）
        kv.Rewind();
    }

    // 统一落盘一次，保证结构整洁
    kv.ExportToFile(FilePath);
    delete kv;
}

// 短语路径
void BuildPhrasePath(char[] buffer, int maxlength, const char[] fliename, const char[] lang_code) {
    strcopy(buffer, maxlength, "translations/");
    int len;
    if (strcmp(lang_code, "en")) { len = strlen(buffer); FormatEx(buffer[len], maxlength - len, "%s/", lang_code); }
    len = strlen(buffer);
    FormatEx(buffer[len], maxlength - len, "%s", fliename);
    BuildPath(Path_SM, buffer, maxlength, "%s", buffer);
}

/* =========================================================
   动态 description + OnGameFrame 节流发送（唯一发送点）
   ========================================================= */

// 是否有效真人(队伍2/3)
bool IsHumanOnTeam23(int client) {
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client)
        && !IsFakeClient(client) && (GetClientTeam(client) == 2 || GetClientTeam(client) == 3));
}

// 是否满员（Anne系只比survivor_limit；否则比survivor_limit+z_max_player_zombies；空房=满）
bool IsTeamFull(bool isAnne) {
    int sum = 0;
    for (int i = 1; i <= MaxClients; i++) if (IsHumanOnTeam23(i)) sum++;
    if (sum == 0) return true;
    int surv = g_hSurvivorLimit ? g_hSurvivorLimit.IntValue : 4;
    int pz   = g_hMaxPZ         ? g_hMaxPZ.IntValue         : 4;
    return isAnne ? (sum >= surv) : (sum >= (surv + pz));
}

void BuildConfoglLabel(const char[] cfg, char[] out, int maxlen, bool &isAnne) {
    isAnne = false;
    if (StrContains(cfg, "AnneHappy", false) != -1) { strcopy(out, maxlen, StrContains(cfg,"HardCore",false)!=-1 ? "[硬核药役]" : "[普通药役]"); isAnne = true; return; }
    if (StrContains(cfg, "AllCharger", false) != -1) { strcopy(out, maxlen, "[牛牛冲刺]"); isAnne = true; return; }
    if (StrContains(cfg, "1vHunters", false) != -1)  { strcopy(out, maxlen, "[HT训练]");   isAnne = true; return; }
    if (StrContains(cfg, "WitchParty", false) != -1) { strcopy(out, maxlen, "[女巫派对]"); isAnne = true; return; }
    if (StrContains(cfg, "Alone", false) != -1)      { strcopy(out, maxlen, "[单人装逼]"); isAnne = true; return; }
	if (StrContains(cfg, "AnneCoop", false) != -1)      { strcopy(out, maxlen, "[Anne战役]"); isAnne = true; return; }
	if (StrContains(cfg, "AnneRealism", false) != -1)      { strcopy(out, maxlen, "[Anne写实]"); isAnne = true; return; }
    FormatEx(out, maxlen, "[%s]", cfg);
}
void BuildAnneChunk(bool isAnne, char[] out, int maxlen) {
    out[0]='\0'; if (!isAnne || !g_hInfectedLimit) return;
    int si=g_hInfectedLimit.IntValue; int sec=g_hVsSIRespawn?g_hVsSIRespawn.IntValue:0; if (si<=0) return;
    if (sec>0) FormatEx(out,maxlen,"[%d特%d秒]",si,sec); else FormatEx(out,maxlen,"[%d特]",si);
}
void BuildFullChunk(bool isAnne, char[] out, int maxlen) { out[0]='\0'; if (!IsTeamFull(isAnne)) strcopy(out,maxlen,"[缺人]"); }
void BuildModChunk(char[] out, int maxlen) { out[0]='\0'; if (g_hAddonsEclipse && g_hAddonsEclipse.IntValue==0) strcopy(out,maxlen,"[无MOD]"); }

void GetCfgName(char[] out, int maxlen) {
    out[0]='\0';
    if (g_hReadyCfgName) { g_hReadyCfgName.GetString(out,maxlen); if (out[0]) return; }
    if (g_hMPGameMode) g_hMPGameMode.GetString(out,maxlen);
}

void RebuildGameDescription() {
    if (!g_hDescDynamic || g_hDescDynamic.IntValue == 0) { strcopy(g_cGameDes,sizeof(g_cGameDes),g_cGameDesBase); return; }
    char fmt[96]; g_hDescFormat.GetString(fmt,sizeof(fmt)); if (!fmt[0]) strcopy(fmt,sizeof(fmt),"{Base}{AnneHappy}{Full}{MOD}{Confogl}");
    char cfg[64]; GetCfgName(cfg,sizeof(cfg));
    char confogl[48], anne[32], full[16], mod[16]; bool isAnne=false;
    BuildConfoglLabel(cfg,confogl,sizeof(confogl),isAnne);
    BuildAnneChunk(isAnne,anne,sizeof(anne));
    BuildFullChunk(isAnne,full,sizeof(full));
    BuildModChunk(mod,sizeof(mod));
    char final[96]; strcopy(final,sizeof(final),fmt);
    ReplaceString(final,sizeof(final),"{Base}",g_cGameDesBase,false);
    ReplaceString(final,sizeof(final),"{AnneHappy}",anne,false);
    ReplaceString(final,sizeof(final),"{Full}",full,false);
    ReplaceString(final,sizeof(final),"{MOD}",mod,false);
    ReplaceString(final,sizeof(final),"{Confogl}",confogl,false);
    strcopy(g_cGameDes,sizeof(g_cGameDes),final);
}

void PushA2S() {
    g_pSteam3Server = SDKCall(g_hSDK_GetSteam3Server);
    if (g_pSteam3Server && LoadFromAddress(g_pSteam3Server + view_as<Address>(4), NumberType_Int32))
        SDKCall(g_hSDK_SendServerInfo, g_pSteam3Server);
    else
        LogError("[A2S_Edit] Failed to get Steam3Server, PushA2S Failed!");
}

// 仅用于展示/防篡改：节流 + 去重推送（不做改名）
public void OnGameFrame()
{
    if (!g_hFrameUpdate || g_hFrameUpdate.IntValue == 0) return;

    static float nextTime = 0.0;
    float now  = GetGameTime();
    float step = g_hFrameInterval ? g_hFrameInterval.FloatValue : 1.0;
    if (now < nextTime) return;
    nextTime = now + step;

    // 按最新状态重建描述
    RebuildGameDescription();

    // 去重比较
    bool changed = false;
    if (!StrEqual(g_cGameDes, g_cLastPushedDesc, false)) { strcopy(g_cLastPushedDesc, sizeof(g_cLastPushedDesc), g_cGameDes); changed = true; }
    if (!StrEqual(g_cMapName, g_cLastPushedMap,  false)) { strcopy(g_cLastPushedMap,  sizeof(g_cLastPushedMap),  g_cMapName); changed = true; }

    if (changed) PushA2S();
}

/* ---------- Missions Cache & Gamedata ---------- */

public void CacheMissionInfo() {
    g_bMissionCached = false;
    PrintToServer("[A2S_Edit] MissionInfo Cacheing...");
    g_smMissionMap.Clear();
    char key[64], mission[64], map[128];
    int i = 1; bool have = true;

    SourceKeyValues kvMissions = SDKCall(g_hSDK_GetAllMissions, g_pMatchExtL4D);
    for (SourceKeyValues kvSub = kvMissions.GetFirstTrueSubKey(); !kvSub.IsNull(); kvSub = kvSub.GetNextTrueSubKey()) {
        i = 1; have = true;
        do {
            FormatEx(key, sizeof(key), "modes/%s/%d/Map", g_cMode, i);
            SourceKeyValues kvMap = kvSub.FindKey(key);
            if (kvMap.IsNull()) {
                have = false;
            } else {
                kvSub.GetName(mission, sizeof(mission)); // ex. L4D2C1
                kvMap.GetString(NULL_STRING, map, sizeof(map)); // ex. c1m1_hotel
                g_smMissionMap.SetString(map, mission); // c1m1_hotel => L4D2C1
                #if DEBUG
                    PrintToServer("[A2S_Edit] %s => %s", map, mission);
                #endif
                ++i;
            }
        } while (have);
    }
    PrintToServer("[A2S_Edit] MissionInfo Cached...");
    g_bMissionCached = true;

    // 任务映射就绪后立刻重算（从文件名切到任务名，再由翻译控制中文）
    ChangeMapName();
}
