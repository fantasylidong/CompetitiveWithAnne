#include <sourcemod>
#undef REQUIRE_PLUGIN
#include <mapchooser>
#include <updater>

#pragma newdecls required
#pragma semicolon 1

#include "advertisements/chatcolors.sp"
#include "advertisements/topcolors.sp"

#define PL_VERSION	"2.2.0"
#define UPDATE_URL	"http://ErikMinekus.github.io/sm-advertisements/update.txt"
#define MAX_PHRASE_LENGTH 128

public Plugin myinfo =
{
    name        = "Advertisements",
    author      = "Tsunami",
    description = "Display advertisements",
    version     = PL_VERSION,
    url         = "http://www.tsunami-productions.nl"
};


enum struct Advertisement
{
    char center[1024];
    char centerPhrase[MAX_PHRASE_LENGTH];
    char chat[2048];
    char chatPhrase[MAX_PHRASE_LENGTH];
    char hint[1024];
    char hintPhrase[MAX_PHRASE_LENGTH];
    char menu[1024];
    char menuPhrase[MAX_PHRASE_LENGTH];
    char top[1024];
    char topPhrase[MAX_PHRASE_LENGTH];
    bool adminsOnly;
    bool hasFlags;
    int flags;
}


/**
 * Globals
 */
bool g_bMapChooser;
bool g_bSayText2;
int g_iCurrentAd;
ArrayList g_hAdvertisements;
ConVar g_hEnabled;
ConVar g_hFile;
ConVar g_hInterval;
ConVar g_hRandom;
Handle g_hTimer;


/**
 * Plugin Forwards
 */
public void OnPluginStart()
{
    LoadTranslations("advertisements.phrases");

    CreateConVar("sm_advertisements_version", PL_VERSION, "Display advertisements", FCVAR_NOTIFY);
    g_hEnabled  = CreateConVar("sm_advertisements_enabled",  "1",                  "Enable/disable displaying advertisements.");
    g_hFile     = CreateConVar("sm_advertisements_file",     "advertisements.txt", "File to read the advertisements from.");
    g_hInterval = CreateConVar("sm_advertisements_interval", "30",                 "Number of seconds between advertisements.");
    g_hRandom   = CreateConVar("sm_advertisements_random",   "0",                  "Enable/disable random advertisements.");

    g_hFile.AddChangeHook(ConVarChanged_File);
    g_hInterval.AddChangeHook(ConVarChanged_Interval);

    g_bMapChooser = LibraryExists("mapchooser");
    g_bSayText2 = GetUserMessageId("SayText2") != INVALID_MESSAGE_ID;
    g_hAdvertisements = new ArrayList(sizeof(Advertisement));

    RegServerCmd("sm_advertisements_reload", Command_ReloadAds, "Reload the advertisements");

    AddChatColors();
    AddTopColors();

    if (LibraryExists("updater")) {
        Updater_AddPlugin(UPDATE_URL);
    }
}

public void OnConfigsExecuted()
{
    ParseAds();
    RestartTimer();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "mapchooser")) {
        g_bMapChooser = true;
    }
    if (StrEqual(name, "updater")) {
        Updater_AddPlugin(UPDATE_URL);
    }
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "mapchooser")) {
        g_bMapChooser = false;
    }
}


/**
 * ConVar Changes
 */
public void ConVarChanged_File(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ParseAds();
}

public void ConVarChanged_Interval(ConVar convar, const char[] oldValue, const char[] newValue)
{
    RestartTimer();
}


/**
 * Commands
 */
public Action Command_ReloadAds(int args)
{
    ParseAds();
    return Plugin_Handled;
}


/**
 * Menu Handlers
 */
public int MenuHandler_DoNothing(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}


/**
 * Timers
 */
public Action Timer_DisplayAd(Handle timer)
{
    if (!g_hEnabled.BoolValue || g_hAdvertisements.Length == 0) {
        return Plugin_Continue;
    }

    if (g_iCurrentAd >= g_hAdvertisements.Length) {
        g_iCurrentAd = 0;
    }

    Advertisement ad;
    g_hAdvertisements.GetArray(g_iCurrentAd, ad);
    char localized[2048], message[2048];

    if (ad.center[0] || ad.centerPhrase[0]) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i, ad)) {
                GetLocalizedMessage(ad.center, ad.centerPhrase, i, localized, sizeof(localized));
                ProcessVariables(localized, message, sizeof(message), i);
                PrintCenterText(i, "%s", message);

                DataPack hCenterAd;
                CreateDataTimer(1.0, Timer_CenterAd, hCenterAd, TIMER_FLAG_NO_MAPCHANGE|TIMER_REPEAT);
                hCenterAd.WriteCell(i);
                hCenterAd.WriteString(message);
            }
        }
    }
    if (ad.chat[0] || ad.chatPhrase[0]) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i, ad)) {
                bool teamColor[10];
                char messages[10][1024];

                GetLocalizedMessage(ad.chat, ad.chatPhrase, i, localized, sizeof(localized));
                int messageCount = ExplodeString(localized, "\n", messages, sizeof(messages), sizeof(messages[]));

                for (int idx; idx < messageCount; idx++) {
                    teamColor[idx] = StrContains(messages[idx], "{teamcolor}", false) != -1;
                    if (teamColor[idx] && !g_bSayText2) {
                        SetFailState("This game does not support {teamcolor}");
                    }

                    ProcessChatColors(messages[idx], message, sizeof(message));
                    ProcessVariables(message, messages[idx], sizeof(messages[]), i);

                    if (teamColor[idx]) {
                        SayText2(i, messages[idx]);
                    } else {
                        PrintToChat(i, "%s", messages[idx]);
                    }
                }
            }
        }
    }
    if (ad.hint[0] || ad.hintPhrase[0]) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i, ad)) {
                GetLocalizedMessage(ad.hint, ad.hintPhrase, i, localized, sizeof(localized));
                ProcessVariables(localized, message, sizeof(message), i);
                PrintHintText(i, "%s", message);
            }
        }
    }
    if (ad.menu[0] || ad.menuPhrase[0]) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i, ad)) {
                GetLocalizedMessage(ad.menu, ad.menuPhrase, i, localized, sizeof(localized));
                ProcessVariables(localized, message, sizeof(message), i);

                Panel hPl = new Panel();
                hPl.DrawText(message);
                hPl.CurrentKey = 10;
                hPl.Send(i, MenuHandler_DoNothing, 10);
                delete hPl;
            }
        }
    }
    if (ad.top[0] || ad.topPhrase[0]) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i, ad)) {
                int iStart    = 0,
                    aColor[4] = {255, 255, 255, 255};

                GetLocalizedMessage(ad.top, ad.topPhrase, i, localized, sizeof(localized));
                ParseTopColor(localized, iStart, aColor);
                ProcessVariables(localized[iStart], message, sizeof(message), i);

                KeyValues hKv = new KeyValues("Stuff", "title", message);
                hKv.SetColor4("color", aColor);
                hKv.SetNum("level",    1);
                hKv.SetNum("time",     10);
                CreateDialog(i, hKv, DialogType_Msg);
                delete hKv;
            }
        }
    }

    if (++g_iCurrentAd >= g_hAdvertisements.Length) {
        g_iCurrentAd = 0;
    }
    return Plugin_Continue;
}

public Action Timer_CenterAd(Handle timer, DataPack pack)
{
    char message[1024];
    static int iCount = 0;

    pack.Reset();
    int iClient = pack.ReadCell();
    pack.ReadString(message, sizeof(message));

    if (!IsClientInGame(iClient) || ++iCount >= 5) {
        iCount = 0;
        return Plugin_Stop;
    }

    PrintCenterText(iClient, "%s", message);
    return Plugin_Continue;
}


/**
 * Functions
 */
bool IsValidClient(int client, Advertisement ad)
{
    return IsClientInGame(client) && !IsFakeClient(client)
        && ((!ad.adminsOnly && !(ad.hasFlags && (GetUserFlagBits(client) & (ad.flags|ADMFLAG_ROOT))))
            || (ad.adminsOnly && (GetUserFlagBits(client) & (ADMFLAG_GENERIC|ADMFLAG_ROOT))));
}

void ParseAds()
{
    g_iCurrentAd = 0;
    g_hAdvertisements.Clear();

    char sFile[64], sPath[PLATFORM_MAX_PATH];
    g_hFile.GetString(sFile, sizeof(sFile));
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/%s", sFile);

    if (!FileExists(sPath)) {
        SetFailState("File Not Found: %s", sPath);
    }

    KeyValues hConfig = new KeyValues("Advertisements");
    hConfig.SetEscapeSequences(true);
    if (!hConfig.ImportFromFile(sPath) || !hConfig.GotoFirstSubKey()) {
        delete hConfig;
        SetFailState("Unable to parse advertisements file: %s", sPath);
    }

    Advertisement ad;
    char flags[22], legacyType[16], legacyText[2048], legacyPhrase[MAX_PHRASE_LENGTH];
    do {
        hConfig.GetString("center", ad.center, sizeof(Advertisement::center));
        hConfig.GetString("center_phrase", ad.centerPhrase, sizeof(Advertisement::centerPhrase));
        hConfig.GetString("chat",   ad.chat,   sizeof(Advertisement::chat));
        hConfig.GetString("chat_phrase", ad.chatPhrase, sizeof(Advertisement::chatPhrase));
        hConfig.GetString("hint",   ad.hint,   sizeof(Advertisement::hint));
        hConfig.GetString("hint_phrase", ad.hintPhrase, sizeof(Advertisement::hintPhrase));
        hConfig.GetString("menu",   ad.menu,   sizeof(Advertisement::menu));
        hConfig.GetString("menu_phrase", ad.menuPhrase, sizeof(Advertisement::menuPhrase));
        hConfig.GetString("top",    ad.top,    sizeof(Advertisement::top));
        hConfig.GetString("top_phrase", ad.topPhrase, sizeof(Advertisement::topPhrase));

        // Advertisements 0.5.x used a shared text/phrase selected by one or more type letters.
        hConfig.GetString("type", legacyType, sizeof(legacyType), "S");
        hConfig.GetString("text", legacyText, sizeof(legacyText));
        hConfig.GetString("phrase", legacyPhrase, sizeof(legacyPhrase));
        ApplyLegacyField(legacyType, "C", legacyText, legacyPhrase, ad.center, sizeof(Advertisement::center), ad.centerPhrase, sizeof(Advertisement::centerPhrase));
        ApplyLegacyField(legacyType, "S", legacyText, legacyPhrase, ad.chat, sizeof(Advertisement::chat), ad.chatPhrase, sizeof(Advertisement::chatPhrase));
        ApplyLegacyField(legacyType, "H", legacyText, legacyPhrase, ad.hint, sizeof(Advertisement::hint), ad.hintPhrase, sizeof(Advertisement::hintPhrase));
        ApplyLegacyField(legacyType, "M", legacyText, legacyPhrase, ad.menu, sizeof(Advertisement::menu), ad.menuPhrase, sizeof(Advertisement::menuPhrase));
        ApplyLegacyField(legacyType, "T", legacyText, legacyPhrase, ad.top, sizeof(Advertisement::top), ad.topPhrase, sizeof(Advertisement::topPhrase));

        hConfig.GetString("flags",  flags,     sizeof(flags), "none");
        ad.adminsOnly = StrEqual(flags, "");
        ad.hasFlags   = !StrEqual(flags, "none");
        ad.flags      = ReadFlagString(flags);

        g_hAdvertisements.PushArray(ad);
    } while (hConfig.GotoNextKey());

    if (g_hRandom.BoolValue) {
        g_hAdvertisements.Sort(Sort_Random, Sort_Integer);
    }

    delete hConfig;
}

void ApplyLegacyField(const char[] types, const char[] type, const char[] text, const char[] phrase,
    char[] output, int outputLength, char[] outputPhrase, int phraseLength)
{
    if (StrContains(types, type, false) == -1) {
        return;
    }

    if (!output[0]) {
        strcopy(output, outputLength, text);
    }
    if (!outputPhrase[0]) {
        strcopy(outputPhrase, phraseLength, phrase);
    }
}

void GetLocalizedMessage(const char[] fallback, const char[] phrase, int client, char[] buffer, int maxlength)
{
    if (phrase[0] && TranslationPhraseExists(phrase)) {
        FormatEx(buffer, maxlength, "%T", phrase, client);
    } else {
        strcopy(buffer, maxlength, fallback);
    }
}

void ProcessVariables(const char[] message, char[] buffer, int maxlength, int client)
{
    char name[64], value[256];
    int buf_idx, i, name_len;
    ConVar hConVar;

    while (message[i] && buf_idx < maxlength - 1) {
        if (message[i] != '{' || (name_len = FindCharInString(message[i + 1], '}')) == -1) {
            buffer[buf_idx++] = message[i++];
            continue;
        }

        strcopy(name, name_len + 1, message[i + 1]);

        if (StrEqual(name, "currentmap", false)) {
            GetCurrentMap(value, sizeof(value));
            GetMapDisplayName(value, value, sizeof(value));
            buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
        }
        else if (StrEqual(name, "nextmap", false)) {
            if (g_bMapChooser && EndOfMapVoteEnabled() && !HasEndOfMapVoteFinished()) {
                FormatEx(value, sizeof(value), "%T", "Advertisement_PendingVote", client);
                buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
            } else {
                GetNextMap(value, sizeof(value));
                GetMapDisplayName(value, value, sizeof(value));
                buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
            }
        }
        else if (StrEqual(name, "date", false)) {
            FormatTime(value, sizeof(value), "%m/%d/%Y");
            buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
        }
        else if (StrEqual(name, "time", false)) {
            FormatTime(value, sizeof(value), "%I:%M:%S%p");
            buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
        }
        else if (StrEqual(name, "time24", false)) {
            FormatTime(value, sizeof(value), "%H:%M:%S");
            buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
        }
        else if (StrEqual(name, "timeleft", false)) {
            int mins, secs, timeleft;
            if (GetMapTimeLeft(timeleft) && timeleft > 0) {
                mins = timeleft / 60;
                secs = timeleft % 60;
            }

            buf_idx += FormatEx(buffer[buf_idx], maxlength - buf_idx, "%d:%02d", mins, secs);
        }
        else if ((hConVar = FindConVar(name))) {
            hConVar.GetString(value, sizeof(value));
            buf_idx += strcopy(buffer[buf_idx], maxlength - buf_idx, value);
        }
        else {
            buf_idx += FormatEx(buffer[buf_idx], maxlength - buf_idx, "{%s}", name);
        }

        i += name_len + 2;
    }

    buffer[buf_idx] = '\0';
}

void RestartTimer()
{
    delete g_hTimer;
    g_hTimer = CreateTimer(float(g_hInterval.IntValue), Timer_DisplayAd, _, TIMER_REPEAT);
}
