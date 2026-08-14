/**
// ====================================================================================================
Change Log:

1.0.2 (01-May-2021)
    - Added support to special characters in static HUD texts through a data file. (thanks "Voevoda" for requesting)
    - Added a required file at data folder.

1.0.1 (13-March-2021)
    - Added cvars to make the next animated. (thanks "Source" for requesting)
    - Increased some cvars min/max bounds to fit more screen resolutions.

1.0.0 (10-March-2021)
    - Initial release.

// ====================================================================================================
*/

/**
// ====================================================================================================
More info about HUD can be found here:
https://developer.valvesoftware.com/wiki/L4D2_EMS/Appendix:_HUD
// ====================================================================================================
*/

// ====================================================================================================
// Plugin Info - define
// ====================================================================================================
#define PLUGIN_NAME                   "[L4D2] Scripted HUD"
#define PLUGIN_AUTHOR                 "Mart"
#define PLUGIN_DESCRIPTION            "Display text for all 15 scripted HUD slots on the screen"
#define PLUGIN_VERSION                "1.4.1"
#define PLUGIN_URL                    "https://forums.alliedmods.net/showthread.php?t=331212"

// ====================================================================================================
// Plugin Info
// ====================================================================================================
public Plugin myinfo =
{
    name        = PLUGIN_NAME,
    author      = PLUGIN_AUTHOR,
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION,
    url         = PLUGIN_URL
}

// ====================================================================================================
// Includes
// ====================================================================================================
#include <sourcemod>
#include <colors>
#include <sdktools>
#include <sdkhooks>
#include <basecomm>
#include <clientprefs>
#include <left4dhooks>
#include <l4d2_ems_hud>
#include <sendproxy>
#include <sourcescramble>
#include <l4d2_scripted_hud_proxies>

//#define REQUIRE_PLUGIN
#undef REQUIRE_PLUGIN
#include <witch_and_tankifier>
#include <infected_control>

// ====================================================================================================
// Pragmas
// ====================================================================================================
#pragma semicolon 1
#pragma newdecls required

// ====================================================================================================
// Cvar Flags
// ====================================================================================================
#define CVAR_FLAGS                    FCVAR_NOTIFY
#define CVAR_FLAGS_PLUGIN_VERSION     FCVAR_NOTIFY|FCVAR_DONTRECORD|FCVAR_SPONLY

// ====================================================================================================
// Filenames
// ====================================================================================================
#define CONFIG_FILENAME               "l4d2_scripted_hud"
#define DATA_FILENAME                 "l4d2_scripted_hud"
#define GAMERULES_PROXY_CLASS         "terror_gamerules"

// ====================================================================================================
// Defines
// ====================================================================================================
#define HUD1                          0
#define HUD2                          1
#define HUD3                          2
#define HUD4                          3

#define HUD_SLOT_COUNT                MAX_SIZE_HUD
#define HUD_EXTRA_FIRST               HUD_RIGHT_TOP
#define HUD_KILL_SHARE_FIRST          HUD_FAR_RIGHT
#define HUD_SLOT_DEFAULT_MASK         ((1 << HUD1) | (1 << HUD2))
#define HUD_SLOT_ALL_MASK             ((1 << HUD_SLOT_COUNT) - 1)
#define HUD_EXTRA_LINE_HEIGHT         0.026
#define HUD_PREFS_COOKIE_SIZE         100
#define HUD_PREFS_MIGRATIONS          4

#define HUD2_PART_SERVER_NAME         (1 << 0)
#define HUD2_PART_MODE                (1 << 1)
#define HUD2_PART_AI_DIFFICULTY       (1 << 2)
#define HUD2_PART_MISSING_PLAYERS     (1 << 3)
#define HUD2_PART_MOD                 (1 << 4)
#define HUD2_PART_INFECTED_TIMING     (1 << 5)
#define HUD2_PART_PLAYER_COUNT        (1 << 6)
#define HUD2_PART_WIPE_COUNT          (1 << 7)
#define HUD2_PART_COUNT               8
#define HUD2_PART_ALL_MASK            ((1 << HUD2_PART_COUNT) - 1)

#define HUD_PREFS_DB_CONFIG           "rpg"
#define HUD_PREFS_DB_TABLE            "scripted_hud_prefs"
#define HUD_PREFS_COOKIE              "l4d2_scripted_hud_prefs_v1"

// Player-selectable content sources for HUD3/HUD4
#define HUD_CONTENT_DEFAULT           0
#define HUD_CONTENT_SURVIVORS         1
#define HUD_CONTENT_SPECIALS          2
#define HUD_CONTENT_KILLS             3
#define HUD_CONTENT_PING              4
#define HUD_CONTENT_TANK_DMG          5
#define HUD_CONTENT_ITEMS             6
#define HUD_CONTENT_WAVE              7
#define HUD_CONTENT_SPEED             8
#define HUD_CONTENT_ROUND             9
#define HUD_CONTENT_WITCH            10
#define HUD_CONTENT_PROGRESS         11
#define HUD_CONTENT_SERVER           12
#define HUD_CONTENT_MAX               HUD_CONTENT_SERVER

#define HUD_PANIC_WINDOW              60.0
#define HUD_WITCH_NEAR_UNITS          600.0
#define HUD_BHOP_RESET_SPEED          230.0
#define HUD_BHOP_RESET_HOLD           0.25

#define HUD_LAYOUT_STANDARD           0
#define HUD_LAYOUT_4_3                1
#define HUD_LAYOUT_ULTRAWIDE          2
#define HUD_LAYOUT_16_10              3
#define HUD_LAYOUT_MAX                HUD_LAYOUT_16_10
#define HUD_LAYOUT_COUNT              (HUD_LAYOUT_MAX + 1)

#define HUD_PROXY_FLAGS               0
#define HUD_PROXY_STRING              1
#define HUD_PROXY_POS_X               2
#define HUD_PROXY_WIDTH               3
#define HUD_PROXY_HEIGHT              4
#define HUD_PROXY_POS_Y               5
#define HUD_PROXY_COUNT               6

#define HUD_TEAM_ALL                  0
#define HUD_TEAM_SURVIVOR             1
#define HUD_TEAM_INFECTED             2

#define HUD_TEXT_ALIGN_LEFT           1
#define HUD_TEXT_ALIGN_CENTER         2
#define HUD_TEXT_ALIGN_RIGHT          3

#define HUD_X_LEFT_TO_RIGHT           0
#define HUD_X_RIGHT_TO_LEFT           1

#define HUD_Y_TOP_TO_BOTTOM           0
#define HUD_Y_BOTTOM_TO_TOP           1

#define TEAM_SURVIVOR                 2
#define TEAM_INFECTED                 3

#define L4D2_ZOMBIECLASS_SMOKER       1
#define L4D2_ZOMBIECLASS_BOOMER       2
#define L4D2_ZOMBIECLASS_HUNTER       3
#define L4D2_ZOMBIECLASS_SPITTER      4
#define L4D2_ZOMBIECLASS_JOCKEY       5
#define L4D2_ZOMBIECLASS_CHARGER      6
#define L4D2_ZOMBIECLASS_TANK         8

// ====================================================================================================
// Native Cvars
// ====================================================================================================
static ConVar g_hCvar_pain_pills_decay_rate;

// ====================================================================================================
// Plugin Cvars
// ====================================================================================================
static ConVar g_hCvar_Enabled;
static ConVar g_hCvar_UpdateInterval;
ConVar g_hVsBossBuffer;
static ConVar g_hCvar_HUD1_Text;
static ConVar g_hCvar_HUD1_TextAlign;
static ConVar g_hCvar_HUD1_BlinkTank;
static ConVar g_hCvar_HUD1_Blink;
static ConVar g_hCvar_HUD1_Beep;
static ConVar g_hCvar_HUD1_Visible;
static ConVar g_hCvar_HUD1_Background;
static ConVar g_hCvar_HUD1_Team;
static ConVar g_hCvar_HUD1_Flag_Debug;
static ConVar g_hCvar_HUD1_X;
static ConVar g_hCvar_HUD1_Y;
static ConVar g_hCvar_HUD1_X_Speed;
static ConVar g_hCvar_HUD1_Y_Speed;
static ConVar g_hCvar_HUD1_X_Direction;
static ConVar g_hCvar_HUD1_Y_Direction;
static ConVar g_hCvar_HUD1_X_Min;
static ConVar g_hCvar_HUD1_Y_Min;
static ConVar g_hCvar_HUD1_X_Max;
static ConVar g_hCvar_HUD1_Y_Max;
static ConVar g_hCvar_HUD1_Width;
static ConVar g_hCvar_HUD1_Height;

static ConVar g_hCvar_HUD2_Text;
static ConVar g_hCvar_HUD2_TextAlign;
static ConVar g_hCvar_HUD2_BlinkTank;
static ConVar g_hCvar_HUD2_Blink;
static ConVar g_hCvar_HUD2_Beep;
static ConVar g_hCvar_HUD2_Visible;
static ConVar g_hCvar_HUD2_Background;
static ConVar g_hCvar_HUD2_Team;
static ConVar g_hCvar_HUD2_Flag_Debug;
static ConVar g_hCvar_HUD2_X;
static ConVar g_hCvar_HUD2_Y;
static ConVar g_hCvar_HUD2_X_Speed;
static ConVar g_hCvar_HUD2_Y_Speed;
static ConVar g_hCvar_HUD2_X_Direction;
static ConVar g_hCvar_HUD2_Y_Direction;
static ConVar g_hCvar_HUD2_X_Min;
static ConVar g_hCvar_HUD2_Y_Min;
static ConVar g_hCvar_HUD2_X_Max;
static ConVar g_hCvar_HUD2_Y_Max;
static ConVar g_hCvar_HUD2_Width;
static ConVar g_hCvar_HUD2_Height;

static ConVar g_hCvar_HUD3_Text;
static ConVar g_hCvar_HUD3_TextAlign;
static ConVar g_hCvar_HUD3_BlinkTank;
static ConVar g_hCvar_HUD3_Blink;
static ConVar g_hCvar_HUD3_Beep;
static ConVar g_hCvar_HUD3_Visible;
static ConVar g_hCvar_HUD3_Background;
static ConVar g_hCvar_HUD3_Team;
static ConVar g_hCvar_HUD3_Flag_Debug;
static ConVar g_hCvar_HUD3_X;
static ConVar g_hCvar_HUD3_Y;
static ConVar g_hCvar_HUD3_X_Speed;
static ConVar g_hCvar_HUD3_Y_Speed;
static ConVar g_hCvar_HUD3_X_Direction;
static ConVar g_hCvar_HUD3_Y_Direction;
static ConVar g_hCvar_HUD3_X_Min;
static ConVar g_hCvar_HUD3_Y_Min;
static ConVar g_hCvar_HUD3_X_Max;
static ConVar g_hCvar_HUD3_Y_Max;
static ConVar g_hCvar_HUD3_Width;
static ConVar g_hCvar_HUD3_Height;

static ConVar g_hCvar_HUD4_Text;
static ConVar g_hCvar_HUD4_TextAlign;
static ConVar g_hCvar_HUD4_BlinkTank;
static ConVar g_hCvar_HUD4_Blink;
static ConVar g_hCvar_HUD4_Beep;
static ConVar g_hCvar_HUD4_Visible;
static ConVar g_hCvar_HUD4_Background;
static ConVar g_hCvar_HUD4_Team;
static ConVar g_hCvar_HUD4_Flag_Debug;
static ConVar g_hCvar_HUD4_X;
static ConVar g_hCvar_HUD4_Y;
static ConVar g_hCvar_HUD4_X_Speed;
static ConVar g_hCvar_HUD4_Y_Speed;
static ConVar g_hCvar_HUD4_X_Direction;
static ConVar g_hCvar_HUD4_Y_Direction;
static ConVar g_hCvar_HUD4_X_Min;
static ConVar g_hCvar_HUD4_Y_Min;
static ConVar g_hCvar_HUD4_X_Max;
static ConVar g_hCvar_HUD4_Y_Max;
static ConVar g_hCvar_HUD4_Width;
static ConVar g_hCvar_HUD4_Height;

// ====================================================================================================
// bool - Plugin Variables
// ====================================================================================================
static bool   g_bEventsHooked;
static bool   g_bAliveTank;
static bool   g_bCvar_Enabled;
static bool   g_bCvar_HUD1_BlinkTank;
static bool   g_bCvar_HUD1_Blink;
static bool   g_bCvar_HUD1_Beep;
static bool   g_bCvar_HUD1_Visible;
static bool   g_bCvar_HUD1_Background;
static bool   g_bCvar_HUD1_Flag_Debug;
static bool   g_bCvar_HUD1_X_Speed;
static bool   g_bCvar_HUD1_Y_Speed;
static bool   g_bCvar_HUD2_BlinkTank;
static bool   g_bCvar_HUD2_Blink;
static bool   g_bCvar_HUD2_Beep;
static bool   g_bCvar_HUD2_Visible;
static bool   g_bCvar_HUD2_Background;
static bool   g_bCvar_HUD2_Flag_Debug;
static bool   g_bCvar_HUD2_X_Speed;
static bool   g_bCvar_HUD2_Y_Speed;
static bool   g_bCvar_HUD3_BlinkTank;
static bool   g_bCvar_HUD3_Blink;
static bool   g_bCvar_HUD3_Beep;
static bool   g_bCvar_HUD3_Visible;
static bool   g_bCvar_HUD3_Background;
static bool   g_bCvar_HUD3_Flag_Debug;
static bool   g_bCvar_HUD3_X_Speed;
static bool   g_bCvar_HUD3_Y_Speed;
static bool   g_bCvar_HUD4_BlinkTank;
static bool   g_bCvar_HUD4_Blink;
static bool   g_bCvar_HUD4_Beep;
static bool   g_bCvar_HUD4_Visible;
static bool   g_bCvar_HUD4_Background;
static bool   g_bCvar_HUD4_Flag_Debug;
static bool   g_bCvar_HUD4_X_Speed;
static bool   g_bCvar_HUD4_Y_Speed;
static bool   g_bCvar_HUD1_Text;
static bool   g_bCvar_HUD2_Text;
static bool   g_bCvar_HUD3_Text;
static bool   g_bCvar_HUD4_Text;
static bool   g_bCvar_BlinkTank;
static bool   g_bData_HUD1_Text;
static bool   g_bData_HUD2_Text;
static bool   g_bData_HUD3_Text;
static bool   g_bData_HUD4_Text;
bool g_bWitchAndTankSystemAvailable = false;
static bool g_bInfectedControlAvailable;
static bool g_bLateLoad;
static bool g_bTankBoardFrozen;
static bool g_bPanicActive;
static bool g_bHUDProxyHooked[HUD_SLOT_COUNT][HUD_PROXY_COUNT];
static bool g_bHUDResetPending[HUD_SLOT_COUNT];
static bool g_bHUDPrefsDatabaseReady;
static bool g_bHUDPrefsDatabaseConnecting;
static bool g_bClientHasCookie[MAXPLAYERS + 1];

// ====================================================================================================
// int - Plugin Variables
// ====================================================================================================
static int    g_iCvar_HUD1_TextAlign;
static int    g_iCvar_HUD1_Team;
static int    g_iCvar_HUD1_X_Direction;
static int    g_iCvar_HUD1_Y_Direction;
static int    g_iCvar_HUD1_Flag_Debug;
static int    g_iCvar_HUD2_TextAlign;
static int    g_iCvar_HUD2_Team;
static int    g_iCvar_HUD2_Flag_Debug;
static int    g_iCvar_HUD2_X_Direction;
static int    g_iCvar_HUD2_Y_Direction;
static int    g_iCvar_HUD3_TextAlign;
static int    g_iCvar_HUD3_Team;
static int    g_iCvar_HUD3_Flag_Debug;
static int    g_iCvar_HUD3_X_Direction;
static int    g_iCvar_HUD3_Y_Direction;
static int    g_iCvar_HUD4_TextAlign;
static int    g_iCvar_HUD4_Team;
static int    g_iCvar_HUD4_Flag_Debug;
static int    g_iCvar_HUD4_X_Direction;
static int    g_iCvar_HUD4_Y_Direction;
static int    g_iHUD1Flags;
static int    g_iHUD2Flags;
static int    g_iHUD3Flags;
static int    g_iHUD4Flags;
static int    g_iClientHUDMask[MAXPLAYERS + 1];
static int    g_iClientHUD2Mask[MAXPLAYERS + 1];
static int    g_iClientHUDLayout[MAXPLAYERS + 1];
static int    g_iClientHUDRevision[MAXPLAYERS + 1];
static int    g_iClientHUDSource[MAXPLAYERS + 1][HUD_SLOT_COUNT];
static int    g_iHUDMenuSlot[MAXPLAYERS + 1];
static int    g_iHUDPrefsMigrationsLeft;
static int    g_iExtraHUDFlags = HUD_FLAG_TEXT | HUD_FLAG_NOBG | HUD_FLAG_ALIGN_LEFT;
static int    g_iClientSpecialKills[MAXPLAYERS + 1];
static int    g_iClientCommonKills[MAXPLAYERS + 1];
static int    g_iHUD2WipeCount;
static int    g_iTankDamage[MAXPLAYERS + 1];
static int    g_iTankMaxHealth;
static int    g_iTankLastHealth;

// ====================================================================================================
// float - Plugin Variables
// ====================================================================================================
static float  g_fCvar_pain_pills_decay_rate;
static float  g_fCvar_UpdateInterval;
static float  g_fCvar_HUD1_X;
static float  g_fCvar_HUD1_Y;
static float  g_fCvar_HUD1_X_Speed;
static float  g_fCvar_HUD1_Y_Speed;
static float  g_fCvar_HUD1_X_Min;
static float  g_fCvar_HUD1_Y_Min;
static float  g_fCvar_HUD1_X_Max;
static float  g_fCvar_HUD1_Y_Max;
static float  g_fCvar_HUD1_Width;
static float  g_fCvar_HUD1_Height;
static float  g_fCvar_HUD2_X;
static float  g_fCvar_HUD2_Y;
static float  g_fCvar_HUD2_X_Speed;
static float  g_fCvar_HUD2_Y_Speed;
static float  g_fCvar_HUD2_X_Min;
static float  g_fCvar_HUD2_Y_Min;
static float  g_fCvar_HUD2_X_Max;
static float  g_fCvar_HUD2_Y_Max;
static float  g_fCvar_HUD2_Width;
static float  g_fCvar_HUD2_Height;
static float  g_fCvar_HUD3_X;
static float  g_fCvar_HUD3_Y;
static float  g_fCvar_HUD3_X_Speed;
static float  g_fCvar_HUD3_Y_Speed;
static float  g_fCvar_HUD3_X_Min;
static float  g_fCvar_HUD3_Y_Min;
static float  g_fCvar_HUD3_X_Max;
static float  g_fCvar_HUD3_Y_Max;
static float  g_fCvar_HUD3_Width;
static float  g_fCvar_HUD3_Height;
static float  g_fCvar_HUD4_X;
static float  g_fCvar_HUD4_Y;
static float  g_fCvar_HUD4_X_Speed;
static float  g_fCvar_HUD4_Y_Speed;
static float  g_fCvar_HUD4_X_Min;
static float  g_fCvar_HUD4_Y_Min;
static float  g_fCvar_HUD4_X_Max;
static float  g_fCvar_HUD4_Y_Max;
static float  g_fCvar_HUD4_Width;
static float  g_fCvar_HUD4_Height;
static float  g_fHUD1_X;
static float  g_fHUD1_Y;
static float  g_fHUD2_X;
static float  g_fHUD2_Y;
static float  g_fHUD3_X;
static float  g_fHUD3_Y;
static float  g_fHUD4_X;
static float  g_fHUD4_Y;
static float  g_fRoundStartTime;
static float  g_fPanicUntil;
static float  g_fClientBhopPeak[MAXPLAYERS + 1];
static float  g_fClientGroundedSince[MAXPLAYERS + 1];

// ====================================================================================================
// string - Plugin Variables
// ====================================================================================================
static char   g_sCvar_HUD1_Text[128];
static char   g_sCvar_HUD2_Text[128];
static char   g_sCvar_HUD3_Text[128];
static char   g_sCvar_HUD4_Text[128];
static char   g_sData_HUD1_Text[128];
static char   g_sData_HUD2_Text[128];
static char   g_sData_HUD3_Text[128];
static char   g_sData_HUD4_Text[128];
static char   g_sHUD1_Text[128];
static char   g_sHUD2_Text[128];
static char   g_sHUD3_Text[128];
static char   g_sHUD4_Text[128];
static char   g_sHUD_TextArray[4][128];
static char   g_sBuffer[128];
static char   g_sSpaces[128] = "                                                                                                                               ";
static char   g_sClientHUDText[MAXPLAYERS + 1][HUD_SLOT_COUNT][128];
static char   g_sClientHUDCookie[MAXPLAYERS + 1][HUD_PREFS_COOKIE_SIZE];
static char   g_sHUD2Fragments[7][64];
static char   g_sBaseServerName[64];

static const char g_sHUDSourcePhrases[][] =
{
    "L4D2ScriptedHUD_SourceDefault",
    "L4D2ScriptedHUD_SourceSurvivors",
    "L4D2ScriptedHUD_SourceSpecials",
    "L4D2ScriptedHUD_SourceKills",
    "L4D2ScriptedHUD_SourcePing",
    "L4D2ScriptedHUD_SourceTankDmg",
    "L4D2ScriptedHUD_SourceItems",
    "L4D2ScriptedHUD_SourceWave",
    "L4D2ScriptedHUD_SourceSpeed",
    "L4D2ScriptedHUD_SourceRound",
    "L4D2ScriptedHUD_SourceWitch",
    "L4D2ScriptedHUD_SourceProgress",
    "L4D2ScriptedHUD_SourceServer"
};

static const char g_sHUDEngineNamePhrases[][] =
{
    "L4D2ScriptedHUD_SlotLeftTop",
    "L4D2ScriptedHUD_SlotLeftBot",
    "L4D2ScriptedHUD_SlotMidTop",
    "L4D2ScriptedHUD_SlotMidBot",
    "L4D2ScriptedHUD_SlotRightTop",
    "L4D2ScriptedHUD_SlotRightBot",
    "L4D2ScriptedHUD_SlotTicker",
    "L4D2ScriptedHUD_SlotFarLeft",
    "L4D2ScriptedHUD_SlotFarRight",
    "L4D2ScriptedHUD_SlotMidBox",
    "L4D2ScriptedHUD_SlotScoreTitle",
    "L4D2ScriptedHUD_SlotScore1",
    "L4D2ScriptedHUD_SlotScore2",
    "L4D2ScriptedHUD_SlotScore3",
    "L4D2ScriptedHUD_SlotScore4"
};

// Per-layout extra-slot geometry. HUD 1-4 keep their cvars as a 16:9 baseline
// and are remapped with origin/scale so 4:3 does not clip and 21:9 stays in the
// center safe area. Extra slots 4-9 are a left column under HUD1; 10-14 are a
// right column below HUD4 / the kill feed, above the weapon HUD.
static const float g_fLayoutOriginX[HUD_LAYOUT_COUNT] =
{
    0.00,  // 16:9
    0.00,  // 4:3
    0.13,  // 21:9
    0.00   // 16:10
};

static const float g_fLayoutScaleX[HUD_LAYOUT_COUNT] =
{
    1.00,
    0.88,
    0.74,
    0.94
};

static const float g_fLayoutExtraW[HUD_LAYOUT_COUNT] =
{
    0.220,
    0.198,
    0.162,
    0.208
};

static const float g_fLayoutExtraLeftX[HUD_LAYOUT_COUNT] =
{
    0.012,
    0.010,
    0.138,
    0.012
};

static const float g_fLayoutExtraLeftY0[HUD_LAYOUT_COUNT] =
{
    0.085,
    0.080,
    0.085,
    0.085
};

static const float g_fLayoutExtraLeftStep[HUD_LAYOUT_COUNT] =
{
    0.110,
    0.108,
    0.110,
    0.110
};

static const float g_fLayoutExtraRightX[HUD_LAYOUT_COUNT] =
{
    0.778,
    0.688,
    0.698,
    0.752
};

static const float g_fLayoutExtraRightY0[HUD_LAYOUT_COUNT] =
{
    0.520,
    0.500,
    0.520,
    0.520
};

static const float g_fLayoutExtraRightStep[HUD_LAYOUT_COUNT] =
{
    0.078,
    0.076,
    0.078,
    0.078
};

enum HUDPrefsLoadState
{
    HUDPrefs_None = 0,
    HUDPrefs_WaitingForCookie,
    HUDPrefs_WaitingForDatabase,
    HUDPrefs_DatabasePending,
    HUDPrefs_Ready
};

static HUDPrefsLoadState g_eHUDPrefsLoadState[MAXPLAYERS + 1];
static Cookie g_hHUDPrefsCookie;
static Handle g_hHUDPrefsDatabase = INVALID_HANDLE;
static MemoryPatch g_hEMSHUDPatch1;
static MemoryPatch g_hEMSHUDPatch2;

static ConVar g_hCvar_HostPort;
static ConVar g_hCvar_Hostname;
static ConVar g_hCvar_ReadyCfgName;
static ConVar g_hCvar_AddonsEclipse;
static ConVar g_hCvar_AIDifficulty;
static ConVar g_hCvar_InfectedLimit;
static ConVar g_hCvar_RespawnInterval;
static ConVar g_hCvar_DirSpawnCount;
static ConVar g_hCvar_DirSpawnInterval;
static ConVar g_hCvar_SurvivorLimit;
static ConVar g_hCvar_InfectedPlayerLimit;
static ConVar g_hCvar_MaxPlayers;
static ConVar g_hCvar_RoundWipeCount;

// ====================================================================================================
// Timer - Plugin Variables
// ====================================================================================================
Handle g_tUpdateInterval;

/****************************************************************************************************/

// ====================================================================================================
// VoiceHook extension - uncomment if you have SM1.10 and the extension and want to show up who is speaking at the hud.
// You can download it here: https://github.com/Accelerator74/VoiceHook/releases
// Requires MetaMod 1.11: https://www.sourcemm.net/downloads.php/?branch=1.11-dev&all=1
// For SM1.11+ is not necessary, cause its already a native.
// Note: Don't forget to uncomment the inner code too on GetHUD4_Text method.
// ====================================================================================================
// public Extension __ext_voice =
// {
    // name = "voicehook",
    // file = "voicehook.ext",
    // autoload = 1,
    // required = 1
// }

// native bool IsClientSpeaking(int client);

// ====================================================================================================
// Plugin Start
// ====================================================================================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_bLateLoad = late;
    EngineVersion engine = GetEngineVersion();

    if (engine != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead 2\" game");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

/****************************************************************************************************/

public void OnPluginStart()
{
		LoadTranslations("l4d2_scripted_hud.phrases");
    LoadPluginData();
    ApplyEMSHUDPatches();

    g_hHUDPrefsCookie = new Cookie(HUD_PREFS_COOKIE, "Scripted HUD per-client preferences", CookieAccess_Protected);
    ConnectHUDPrefsDatabase();

    g_hCvar_pain_pills_decay_rate = FindConVar("pain_pills_decay_rate");

    CreateConVar("l4d2_scripted_hud_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, CVAR_FLAGS_PLUGIN_VERSION);
    g_hCvar_Enabled          = CreateConVar("l4d2_scripted_hud_enable", "1", "Enable/Disable the plugin.\n0 = Disable, 1 = Enable.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_UpdateInterval   = CreateConVar("l4d2_scripted_hud_update_interval", "0.1", "Interval in seconds to update the HUD.", CVAR_FLAGS, true, 0.1);
    g_hCvar_HUD1_Text        = CreateConVar("l4d2_scripted_hud_hud1_text", "", "The text you want to display in the HUD.\nNote: When cvar is empty \"\", plugin will use the predefined HUD text set in the code, check GetHUD*_Text functions.", CVAR_FLAGS);
    g_hCvar_HUD1_TextAlign   = CreateConVar("l4d2_scripted_hud_hud1_text_align", "1", "Aligns the text horizontally.\n1 = LEFT, 2 = CENTER, 3 = RIGHT.", CVAR_FLAGS, true, 1.0, true, 3.0);
    g_hCvar_HUD1_BlinkTank   = CreateConVar("l4d2_scripted_hud_hud1_blink_tank", "1", "Makes the text blink from white to red while a tank is alive.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Blink       = CreateConVar("l4d2_scripted_hud_hud1_blink", "0", "Makes the text blink from white to red.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Beep        = CreateConVar("l4d2_scripted_hud_hud1_beep", "0", "Makes the text play a beep sound while blinking.\n0 = OFF, 1 = ON. Note: the blink cvar must be \"1\" to play the beep sound.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Visible     = CreateConVar("l4d2_scripted_hud_hud1_visible", "1", "Makes the text visible.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Background  = CreateConVar("l4d2_scripted_hud_hud1_background", "0", "Shows the text inside a black transparent background.\nNote: the background may not draw properly when initialized as \"0\", start the map with \"1\" to render properly.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Team        = CreateConVar("l4d2_scripted_hud_hud1_team", "0", "Which team should see the text.\n0 = ALL, 1 = SURVIVOR, 2 = INFECTED.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD1_Flag_Debug  = CreateConVar("l4d2_scripted_hud_hud1_flag_debug", "0", "Overwrite the HUD flag.\nFor debug purposes only.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 32767.0);
    g_hCvar_HUD1_X           = CreateConVar("l4d2_scripted_hud_hud1_x", "0.05", "X (horizontal) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_Y           = CreateConVar("l4d2_scripted_hud_hud1_y", "0.0", "Y (vertical) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_X_Speed     = CreateConVar("l4d2_scripted_hud_hud1_x_speed", "0.0", "Animated X (horizontal) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD1_Y_Speed     = CreateConVar("l4d2_scripted_hud_hud1_y_speed", "0.0", "Animated Y (vertical) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD1_X_Direction = CreateConVar("l4d2_scripted_hud_hud1_x_direction", "0", "Animated X (horizontal) direction that the text will move.\n0 = Right to Left, 1 = Left to Right.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_Y_Direction = CreateConVar("l4d2_scripted_hud_hud1_y_direction", "0", "Animated Y (vertical) direction that the text will move.\n0 = Top to Bottom, 1 = Bottom to Top.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD1_X_Min       = CreateConVar("l4d2_scripted_hud_hud1_x_min", "0.0", "Animated X (horizontal) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_Y_Min       = CreateConVar("l4d2_scripted_hud_hud1_y_min", "0.0", "Animated Y (vertical) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_X_Max       = CreateConVar("l4d2_scripted_hud_hud1_x_max", "1.0", "Animated X (horizontal) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_Y_Max       = CreateConVar("l4d2_scripted_hud_hud1_y_max", "1.0", "Animated Y (vertical) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD1_Width       = CreateConVar("l4d2_scripted_hud_hud1_width", "1.0", "Text area Width.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD1_Height      = CreateConVar("l4d2_scripted_hud_hud1_height", "0.026", "Text area Height.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD2_Text        = CreateConVar("l4d2_scripted_hud_hud2_text", "", "The text you want to display in the HUD.\nNote: When cvar is empty \"\", plugin will use the predefined HUD text set in the code, check GetHUD*_Text functions.", CVAR_FLAGS);
    g_hCvar_HUD2_TextAlign   = CreateConVar("l4d2_scripted_hud_hud2_text_align", "1", "Aligns the text horizontally.\n1 = LEFT, 2 = CENTER, 3 = RIGHT.", CVAR_FLAGS, true, 1.0, true, 3.0);
    g_hCvar_HUD2_BlinkTank   = CreateConVar("l4d2_scripted_hud_hud2_blink_tank", "0", "Makes the text blink from white to red while a tank is alive.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Blink       = CreateConVar("l4d2_scripted_hud_hud2_blink", "0", "Makes the text blink from white to red.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Beep        = CreateConVar("l4d2_scripted_hud_hud2_beep", "0", "Makes the text play a beep sound while blinking.\n0 = OFF, 1 = ON. Note: the blink cvar must be \"1\" to play the beep sound.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Visible     = CreateConVar("l4d2_scripted_hud_hud2_visible", "1", "Makes the text visible.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Background  = CreateConVar("l4d2_scripted_hud_hud2_background", "0", "Shows the text inside a black transparent background.\nNote: the background may not draw properly when initialized as \"0\", start the map with \"1\" to render properly.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Team        = CreateConVar("l4d2_scripted_hud_hud2_team", "0", "Which team should see the text.\n0 = ALL, 1 = SURVIVOR, 2 = INFECTED.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD2_Flag_Debug  = CreateConVar("l4d2_scripted_hud_hud2_flag_debug", "0", "Overwrite the HUD flag.\nFor debug purposes only.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 32767.0);
    g_hCvar_HUD2_X           = CreateConVar("l4d2_scripted_hud_hud2_x", "0.65", "X (horizontal) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_Y           = CreateConVar("l4d2_scripted_hud_hud2_y", "0.00", "Y (vertical) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_X_Speed     = CreateConVar("l4d2_scripted_hud_hud2_x_speed", "0.0", "Animated X (horizontal) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD2_Y_Speed     = CreateConVar("l4d2_scripted_hud_hud2_y_speed", "0.0", "Animated Y (vertical) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD2_X_Direction = CreateConVar("l4d2_scripted_hud_hud2_x_direction", "0", "Animated X (horizontal) direction that the text will move.\n0 = Left to Right, 1 = Right to Left.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_Y_Direction = CreateConVar("l4d2_scripted_hud_hud2_y_direction", "0", "Animated Y (vertical) direction that the text will move.\n0 = Top to Bottom, 1 = Bottom to Top.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD2_X_Min       = CreateConVar("l4d2_scripted_hud_hud2_x_min", "0.0", "Animated X (horizontal) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_Y_Min       = CreateConVar("l4d2_scripted_hud_hud2_y_min", "0.0", "Animated Y (vertical) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_X_Max       = CreateConVar("l4d2_scripted_hud_hud2_x_max", "1.0", "Animated X (horizontal) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_Y_Max       = CreateConVar("l4d2_scripted_hud_hud2_y_max", "1.0", "Animated Y (vertical) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD2_Width       = CreateConVar("l4d2_scripted_hud_hud2_width", "1.0", "Text area Width.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD2_Height      = CreateConVar("l4d2_scripted_hud_hud2_height", "0.026", "Text area Height.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD3_Text        = CreateConVar("l4d2_scripted_hud_hud3_text", "", "The text you want to display in the HUD.\nNote: When cvar is empty \"\", plugin will use the predefined HUD text set in the code, check GetHUD*_Text functions.", CVAR_FLAGS);
    g_hCvar_HUD3_TextAlign   = CreateConVar("l4d2_scripted_hud_hud3_text_align", "1", "Aligns the text horizontally.\n1 = LEFT, 2 = CENTER, 3 = RIGHT.", CVAR_FLAGS, true, 1.0, true, 3.0);
    g_hCvar_HUD3_BlinkTank   = CreateConVar("l4d2_scripted_hud_hud3_blink_tank", "0", "Makes the text blink from white to red while a tank is alive.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Blink       = CreateConVar("l4d2_scripted_hud_hud3_blink", "0", "Makes the text blink from white to red.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Beep        = CreateConVar("l4d2_scripted_hud_hud3_beep", "0", "Makes the text play a beep sound while blinking.\n0 = OFF, 1 = ON. Note: the blink cvar must be \"1\" to play the beep sound.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Visible     = CreateConVar("l4d2_scripted_hud_hud3_visible", "1", "Allows players to display this HUD slot.\n0 = Globally disabled, 1 = Player preference.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Background  = CreateConVar("l4d2_scripted_hud_hud3_background", "0", "Shows the text inside a black transparent background.\nNote: the background may not draw properly when initialized as \"0\", start the map with \"1\" to render properly.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Team        = CreateConVar("l4d2_scripted_hud_hud3_team", "0", "Which team should see the text.\n0 = ALL, 1 = SURVIVOR, 2 = INFECTED.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD3_Flag_Debug  = CreateConVar("l4d2_scripted_hud_hud3_flag_debug", "0", "Overwrite the HUD flag.\nFor debug purposes only.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 32767.0);
    g_hCvar_HUD3_X           = CreateConVar("l4d2_scripted_hud_hud3_x", "0.8", "X (horizontal) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_Y           = CreateConVar("l4d2_scripted_hud_hud3_y", "0.11", "Y (vertical) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_X_Speed     = CreateConVar("l4d2_scripted_hud_hud3_x_speed", "0.0", "Animated X (horizontal) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD3_Y_Speed     = CreateConVar("l4d2_scripted_hud_hud3_y_speed", "0.0", "Animated Y (vertical) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD3_X_Direction = CreateConVar("l4d2_scripted_hud_hud3_x_direction", "0", "Animated X (horizontal) direction that the text will move.\n0 = Left to Right, 1 = Right to Left.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_Y_Direction = CreateConVar("l4d2_scripted_hud_hud3_y_direction", "0", "Animated Y (vertical) direction that the text will move.\n0 = Top to Bottom, 1 = Bottom to Top.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD3_X_Min       = CreateConVar("l4d2_scripted_hud_hud3_x_min", "0.0", "Animated X (horizontal) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_Y_Min       = CreateConVar("l4d2_scripted_hud_hud3_y_min", "0.0", "Animated Y (vertical) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_X_Max       = CreateConVar("l4d2_scripted_hud_hud3_x_max", "1.0", "Animated X (horizontal) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_Y_Max       = CreateConVar("l4d2_scripted_hud_hud3_y_max", "1.0", "Animated Y (vertical) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD3_Width       = CreateConVar("l4d2_scripted_hud_hud3_width", "1.5", "Text area Width.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD3_Height      = CreateConVar("l4d2_scripted_hud_hud3_height", "0.026", "Text area Height.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD4_Text        = CreateConVar("l4d2_scripted_hud_hud4_text", "", "The text you want to display in the HUD.\nNote: When cvar is empty \"\", plugin will use the predefined HUD text set in the code, check GetHUD*_Text functions.", CVAR_FLAGS);
    g_hCvar_HUD4_TextAlign   = CreateConVar("l4d2_scripted_hud_hud4_text_align", "1", "Aligns the text horizontally.\n1 = LEFT, 2 = CENTER, 3 = RIGHT.", CVAR_FLAGS, true, 1.0, true, 3.0);
    g_hCvar_HUD4_BlinkTank   = CreateConVar("l4d2_scripted_hud_hud4_blink_tank", "1", "Makes the text blink from white to red while a tank is alive.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Blink       = CreateConVar("l4d2_scripted_hud_hud4_blink", "0", "Makes the text blink from white to red.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Beep        = CreateConVar("l4d2_scripted_hud_hud4_beep", "0", "Makes the text play a beep sound while blinking.\n0 = OFF, 1 = ON. Note: the blink cvar must be \"1\" to play the beep sound.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Visible     = CreateConVar("l4d2_scripted_hud_hud4_visible", "1", "Allows players to display this HUD slot.\n0 = Globally disabled, 1 = Player preference.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Background  = CreateConVar("l4d2_scripted_hud_hud4_background", "0", "Shows the text inside a black transparent background.\nNote: the background may not draw properly when initialized as \"0\", start the map with \"1\" to render properly.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Team        = CreateConVar("l4d2_scripted_hud_hud4_team", "0", "Which team should see the text.\n0 = ALL, 1 = SURVIVOR, 2 = INFECTED.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD4_Flag_Debug  = CreateConVar("l4d2_scripted_hud_hud4_flag_debug", "0", "Overwrite the HUD flag.\nFor debug purposes only.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 32767.0);
    g_hCvar_HUD4_X           = CreateConVar("l4d2_scripted_hud_hud4_x", "0.75", "X (horizontal) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_Y           = CreateConVar("l4d2_scripted_hud_hud4_y", "0.35", "Y (vertical) position of the text.\nNote: setting it to less than 0.0 may cut/hide the text at screen.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_X_Speed     = CreateConVar("l4d2_scripted_hud_hud4_x_speed", "0.0", "Animated X (horizontal) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD4_Y_Speed     = CreateConVar("l4d2_scripted_hud_hud4_y_speed", "0.0", "Animated Y (vertical) movement speed of the text.\n0 = OFF.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD4_X_Direction = CreateConVar("l4d2_scripted_hud_hud4_x_direction", "0", "Animated X (horizontal) direction that the text will move.\n0 = Left to Right, 1 = Right to Left.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_Y_Direction = CreateConVar("l4d2_scripted_hud_hud4_y_direction", "0", "Animated Y (vertical) direction that the text will move.\n0 = Top to Bottom, 1 = Bottom to Top.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_HUD4_X_Min       = CreateConVar("l4d2_scripted_hud_hud4_x_min", "0.0", "Animated X (horizontal) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_Y_Min       = CreateConVar("l4d2_scripted_hud_hud4_y_min", "0.0", "Animated Y (vertical) minimum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_X_Max       = CreateConVar("l4d2_scripted_hud_hud4_x_max", "1.0", "Animated X (horizontal) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_Y_Max       = CreateConVar("l4d2_scripted_hud_hud4_y_max", "1.0", "Animated Y (vertical) maximum position that the HUD can reach.", CVAR_FLAGS, true, -1.0, true, 1.0);
    g_hCvar_HUD4_Width       = CreateConVar("l4d2_scripted_hud_hud4_width", "1.5", "Text area Width.", CVAR_FLAGS, true, 0.0, true, 2.0);
    g_hCvar_HUD4_Height      = CreateConVar("l4d2_scripted_hud_hud4_height", "0.026", "Text area Height.", CVAR_FLAGS, true, 0.0, true, 2.0);	
    g_hVsBossBuffer 		 = FindConVar("versus_boss_buffer");
    
    // Hook plugin ConVars change
    g_hCvar_pain_pills_decay_rate.AddChangeHook(Event_ConVarChanged);
    g_hCvar_Enabled.AddChangeHook(Event_ConVarChanged);
    g_hCvar_UpdateInterval.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Text.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_TextAlign.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_BlinkTank.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Blink.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Beep.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Visible.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Background.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Team.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Flag_Debug.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_X.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Y.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_X_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Y_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_X_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Y_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_X_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Y_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_X_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Y_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Width.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD1_Height.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Text.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_TextAlign.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_BlinkTank.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Blink.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Beep.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Visible.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Background.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Team.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Flag_Debug.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_X.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Y.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_X_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Y_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_X_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Y_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_X_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Y_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_X_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Y_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Width.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD2_Height.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Text.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_TextAlign.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_BlinkTank.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Blink.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Beep.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Visible.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Background.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Team.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Flag_Debug.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_X.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Y.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_X_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Y_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_X_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Y_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_X_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Y_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_X_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Y_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Width.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD3_Height.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Text.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_TextAlign.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_BlinkTank.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Blink.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Beep.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Visible.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Background.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Team.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Flag_Debug.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_X.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Y.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_X_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Y_Speed.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_X_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Y_Direction.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_X_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Y_Min.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_X_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Y_Max.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Width.AddChangeHook(Event_ConVarChanged);
    g_hCvar_HUD4_Height.AddChangeHook(Event_ConVarChanged);

    // Load plugin configs from .cfg
    //AutoExecConfig(true, CONFIG_FILENAME);

    // Admin Commands
    RegAdminCmd("sm_l4d2_scripted_hud_reload_data", CmdReloadData, ADMFLAG_ROOT, "Reload the HUD texts set in the data file.");
    RegAdminCmd("sm_print_cvars_l4d2_scripted_hud", CmdPrintCvars, ADMFLAG_ROOT, "Print the plugin related cvars and their respective values to the console.");
    RegConsoleCmd("sm_spechudon", ShowSpecHud, "打开spechud");
    RegConsoleCmd("sm_spechudoff", offSpecHud, "打开spechud");
    RegConsoleCmd("sm_hudmenu", CmdHUDMenu, "Open the scripted HUD settings menu.");
    RegConsoleCmd("sm_hud", CmdHUDMenu, "Open the scripted HUD settings menu.");

    if (g_bLateLoad)
    {
        EnableHUD();
        RefreshHUDStatusCvars();
        LoadBaseServerName();
        GetCvars();
        LateLoad();
        HookEvents();
        HookHUDSendProxies();
        delete g_tUpdateInterval;
        g_tUpdateInterval = CreateTimer(g_fCvar_UpdateInterval, TimerUpdateHUD, _, TIMER_REPEAT);

        for (int client = 1; client <= MaxClients; client++)
        {
            if (IsClientInGame(client))
                InitializeHUDPrefsClient(client);
        }
    }
}

public void OnMapStart()
{
    EnableHUD();
    ClearUnusedHUDSlots();
    LoadBaseServerName();
}

// Slots 4-7 are owned by this plugin. Initialize them as TEXT|NOBG|NOTVISIBLE so
// the EMS HUDFrameUpdate patches cannot leave stale/uninitialized data that
// renders as empty white-outlined boxes. Slots 8-14 stay untouched so the CS
// kill HUD can keep driving them until a player assigns custom content.
void ClearUnusedHUDSlots()
{
    PlaceOwnedExtraHUDSlots();
}

void PlaceOwnedExtraHUDSlots()
{
    float x, y, w;
    for (int slot = HUD_EXTRA_FIRST; slot < HUD_KILL_SHARE_FIRST; slot++)
    {
        int flags = g_iExtraHUDFlags | HUD_FLAG_NOTVISIBLE;
        if (IsExtraSlotUsedByAnyone(slot))
            flags = g_iExtraHUDFlags;

        GetLayoutExtraSlotRect(HUD_LAYOUT_STANDARD, slot, x, y, w);
        HUDSetLayout(slot, flags, " ");
        HUDPlace(slot, x, y, w, HUD_EXTRA_LINE_HEIGHT * 4.0);
    }
}

int GetHUDLayoutIndex(int client)
{
    int layout = g_iClientHUDLayout[client];
    if (layout < HUD_LAYOUT_STANDARD || layout > HUD_LAYOUT_MAX)
        return HUD_LAYOUT_STANDARD;
    return layout;
}

void GetLayoutExtraSlotRect(int layout, int hud, float &x, float &y, float &w)
{
    if (layout < HUD_LAYOUT_STANDARD || layout > HUD_LAYOUT_MAX)
        layout = HUD_LAYOUT_STANDARD;

    w = g_fLayoutExtraW[layout];
    if (hud <= HUD_MID_BOX)
    {
        int index = hud - HUD_EXTRA_FIRST;
        x = g_fLayoutExtraLeftX[layout];
        y = g_fLayoutExtraLeftY0[layout] + float(index) * g_fLayoutExtraLeftStep[layout];
        return;
    }

    int index = hud - HUD_SCORE_TITLE;
    x = g_fLayoutExtraRightX[layout];
    y = g_fLayoutExtraRightY0[layout] + float(index) * g_fLayoutExtraRightStep[layout];
}

void GetClientHUDSlotRect(int client, int hud, float &x, float &y, float &w)
{
    int layout = GetHUDLayoutIndex(client);

    if (hud >= HUD_EXTRA_FIRST)
    {
        GetLayoutExtraSlotRect(layout, hud, x, y, w);
        return;
    }

    switch (hud)
    {
        case HUD1:
        {
            x = g_fHUD1_X;
            y = g_fHUD1_Y;
            w = g_fCvar_HUD1_Width;
        }
        case HUD2:
        {
            x = g_fHUD2_X;
            y = g_fHUD2_Y;
            w = g_fCvar_HUD2_Width;
        }
        case HUD3:
        {
            x = g_fHUD3_X;
            y = g_fHUD3_Y;
            w = g_fCvar_HUD3_Width;
        }
        default:
        {
            x = g_fHUD4_X;
            y = g_fHUD4_Y;
            w = g_fCvar_HUD4_Width;
        }
    }

    x = g_fLayoutOriginX[layout] + x * g_fLayoutScaleX[layout];
    w *= g_fLayoutScaleX[layout];
    if (x < 0.0)
        x = 0.0;
    if (x > 0.98)
        x = 0.98;
}

bool IsKillHudSharedSlot(int hud)
{
    return hud >= HUD_KILL_SHARE_FIRST;
}

bool IsSlotGloballyAllowed(int hud)
{
    switch (hud)
    {
        case HUD1: return g_bCvar_HUD1_Visible;
        case HUD2: return g_bCvar_HUD2_Visible;
        case HUD3: return g_bCvar_HUD3_Visible;
        case HUD4: return g_bCvar_HUD4_Visible;
    }

    return true;
}

int GetClientHUDSource(int client, int hud)
{
    if (hud < HUD1 || hud >= HUD_SLOT_COUNT)
        return HUD_CONTENT_DEFAULT;

    return g_iClientHUDSource[client][hud];
}

bool IsClientSlotVisible(int client, int hud)
{
    if (!g_bCvar_Enabled || !IsValidClient(client) || IsFakeClient(client))
        return false;

    if (!IsSlotGloballyAllowed(hud))
        return false;

    if ((g_iClientHUDMask[client] & (1 << hud)) == 0)
        return false;

    if (hud >= HUD_EXTRA_FIRST && GetClientHUDSource(client, hud) == HUD_CONTENT_DEFAULT)
        return false;

    return true;
}

bool IsExtraSlotUsedByAnyone(int hud)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsClientSlotVisible(client, hud))
            return true;
    }

    return false;
}

float GetHUDSlotLineHeight(int hud)
{
    switch (hud)
    {
        case HUD1: return g_fCvar_HUD1_Height;
        case HUD2: return g_fCvar_HUD2_Height;
        case HUD3: return g_fCvar_HUD3_Height;
        case HUD4: return g_fCvar_HUD4_Height;
    }

    return HUD_EXTRA_LINE_HEIGHT;
}

int GetHUDSlotBaseFlags(int hud)
{
    switch (hud)
    {
        case HUD1: return g_iHUD1Flags;
        case HUD2: return g_iHUD2Flags;
        case HUD3: return g_iHUD3Flags;
        case HUD4: return g_iHUD4Flags;
    }

    return g_iExtraHUDFlags;
}

bool GetHUDSlotBlinkTank(int hud)
{
    switch (hud)
    {
        case HUD1: return g_bCvar_HUD1_BlinkTank;
        case HUD2: return g_bCvar_HUD2_BlinkTank;
        case HUD3: return g_bCvar_HUD3_BlinkTank;
        case HUD4: return g_bCvar_HUD4_BlinkTank;
    }

    return false;
}

public void OnMapEnd()
{
    ResetHUDSendProxyState();
}

public void OnPluginEnd()
{
    UnhookHUDSendProxies();
    delete g_hEMSHUDPatch1;
    delete g_hEMSHUDPatch2;

    if (g_hHUDPrefsDatabase != INVALID_HANDLE)
    {
        CloseHandle(g_hHUDPrefsDatabase);
        g_hHUDPrefsDatabase = INVALID_HANDLE;
    }
}

void ApplyEMSHUDPatches()
{
    GameData gameData = new GameData("l4d2_ems_hud_sig");
    if (gameData == null)
        SetFailState("[Scripted HUD] Missing gamedata: l4d2_ems_hud_sig.txt");

    g_hEMSHUDPatch1 = MemoryPatch.CreateFromConf(gameData, "CScriptHud::HUDFrameUpdate::Ptach1");
    g_hEMSHUDPatch2 = MemoryPatch.CreateFromConf(gameData, "CScriptHud::HUDFrameUpdate::Ptach2");
    delete gameData;

    if (g_hEMSHUDPatch1 == null || !g_hEMSHUDPatch1.Validate() || !g_hEMSHUDPatch1.Enable())
        SetFailState("[Scripted HUD] Failed to enable EMS HUD patch 1.");
    if (g_hEMSHUDPatch2 == null || !g_hEMSHUDPatch2.Validate() || !g_hEMSHUDPatch2.Enable())
        SetFailState("[Scripted HUD] Failed to enable EMS HUD patch 2.");
}

/****************************************************************************************************/

public void LoadPluginData()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, PLATFORM_MAX_PATH, "data/%s.cfg", DATA_FILENAME);

    if (!FileExists(path))
    {
        SetFailState("Missing required data file on \"data/%s.cfg\", please re-download.", DATA_FILENAME);
        return;
    }

    KeyValues kv = new KeyValues("l4d2_scripted_hud");
    kv.ImportFromFile(path);
    kv.JumpToKey("HUD_Texts");

    kv.GetString("HUD1", g_sData_HUD1_Text, sizeof(g_sData_HUD1_Text));
    TrimString(g_sData_HUD1_Text);
    g_bData_HUD1_Text = (g_sData_HUD1_Text[0] != 0);

    kv.GetString("HUD2", g_sData_HUD2_Text, sizeof(g_sData_HUD2_Text));
    TrimString(g_sData_HUD2_Text);
    g_bData_HUD2_Text = (g_sData_HUD2_Text[0] != 0);

    kv.GetString("HUD3", g_sData_HUD3_Text, sizeof(g_sData_HUD3_Text));
    TrimString(g_sData_HUD3_Text);
    g_bData_HUD3_Text = (g_sData_HUD3_Text[0] != 0);

    kv.GetString("HUD4", g_sData_HUD4_Text, sizeof(g_sData_HUD4_Text));
    TrimString(g_sData_HUD4_Text);
    g_bData_HUD4_Text = (g_sData_HUD4_Text[0] != 0);

    delete kv;
}

public void OnAllPluginsLoaded()
{
    g_bWitchAndTankSystemAvailable = LibraryExists("witch_and_tankifier");
    g_bInfectedControlAvailable = LibraryExists("infected_control");
    HookHUDSendProxies();
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = true;
    else if (StrEqual(name, "infected_control"))
        g_bInfectedControlAvailable = true;
    else if (StrEqual(name, SENDPROXY_LIB))
        HookHUDSendProxies();
}

public void OnLibraryRemoved(const char[] name)
{
    if (StrEqual(name, "witch_and_tankifier"))
        g_bWitchAndTankSystemAvailable = false;
    else if (StrEqual(name, "infected_control"))
        g_bInfectedControlAvailable = false;
    else if (StrEqual(name, SENDPROXY_LIB))
        ResetHUDSendProxyState();
}

/****************************************************************************************************/

public void OnConfigsExecuted()
{
    EnableHUD();
    RefreshHUDStatusCvars();
    LoadBaseServerName();

    GetCvars();

    LateLoad();

    HookEvents();

    delete g_tUpdateInterval;
    g_tUpdateInterval = CreateTimer(g_fCvar_UpdateInterval, TimerUpdateHUD, _, TIMER_REPEAT);
}

/****************************************************************************************************/

public void Event_ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (convar == g_hCvar_HUD1_Background)
        RequestFrame(OnNextFrameHUDBackground, HUD1);
    else if (convar == g_hCvar_HUD2_Background)
        RequestFrame(OnNextFrameHUDBackground, HUD2);
    else if (convar == g_hCvar_HUD3_Background)
        RequestFrame(OnNextFrameHUDBackground, HUD3);
    else if (convar == g_hCvar_HUD4_Background)
        RequestFrame(OnNextFrameHUDBackground, HUD4);

    GetCvars();

    HookEvents();

    if (convar == g_hCvar_Enabled && g_bCvar_Enabled)
        HookHUDSendProxies();

    delete g_tUpdateInterval;
    g_tUpdateInterval = CreateTimer(g_fCvar_UpdateInterval, TimerUpdateHUD, _, TIMER_REPEAT);
}

/****************************************************************************************************/

public void OnNextFrameHUDBackground(int hudid)
{
    if (!g_bCvar_Enabled)
        return;

    // if the background has been changed we need to set it invisible first to refresh the changes
    g_bHUDResetPending[hudid] = true;
    ResetHUD(hudid);
}

/****************************************************************************************************/

public void LateLoad()
{
    if (g_bCvar_BlinkTank)
        g_bAliveTank = HasAnyTankAlive();
    if (g_fRoundStartTime <= 0.0)
        g_fRoundStartTime = GetGameTime();
    g_bInfectedControlAvailable = LibraryExists("infected_control");
}

/****************************************************************************************************/

void GetCvars()
{
    g_fCvar_pain_pills_decay_rate = g_hCvar_pain_pills_decay_rate.FloatValue;

    g_bCvar_Enabled = g_hCvar_Enabled.BoolValue;
    g_fCvar_UpdateInterval = g_hCvar_UpdateInterval.FloatValue;

    g_hCvar_HUD1_Text.GetString(g_sCvar_HUD1_Text, sizeof(g_sCvar_HUD1_Text));
    g_bCvar_HUD1_Text = (g_sCvar_HUD1_Text[0] != 0);
    g_iCvar_HUD1_TextAlign = g_hCvar_HUD1_TextAlign.IntValue;
    g_bCvar_HUD1_BlinkTank = g_hCvar_HUD1_BlinkTank.BoolValue;
    g_bCvar_HUD1_Blink = g_hCvar_HUD1_Blink.BoolValue;
    g_bCvar_HUD1_Beep = g_hCvar_HUD1_Beep.BoolValue;
    g_bCvar_HUD1_Visible = g_hCvar_HUD1_Visible.BoolValue;
    g_bCvar_HUD1_Background = g_hCvar_HUD1_Background.BoolValue;
    g_iCvar_HUD1_Team = g_hCvar_HUD1_Team.IntValue;
    g_iCvar_HUD1_Flag_Debug = g_hCvar_HUD1_Flag_Debug.IntValue;
    g_bCvar_HUD1_Flag_Debug = (g_iCvar_HUD1_Flag_Debug > 0);
    g_fCvar_HUD1_X = g_hCvar_HUD1_X.FloatValue;
    g_fHUD1_X = g_fCvar_HUD1_X;
    g_fCvar_HUD1_Y = g_hCvar_HUD1_Y.FloatValue;
    g_fHUD1_Y = g_fCvar_HUD1_Y;
    g_fCvar_HUD1_X_Speed = g_hCvar_HUD1_X_Speed.FloatValue;
    g_bCvar_HUD1_X_Speed = (g_fCvar_HUD1_X_Speed > 0.0);
    g_fCvar_HUD1_Y_Speed = g_hCvar_HUD1_Y_Speed.FloatValue;
    g_bCvar_HUD1_Y_Speed = (g_fCvar_HUD1_Y_Speed > 0.0);
    g_iCvar_HUD1_X_Direction = g_hCvar_HUD1_X_Direction.IntValue;
    g_iCvar_HUD1_Y_Direction = g_hCvar_HUD1_Y_Direction.IntValue;
    g_fCvar_HUD1_X_Min = g_hCvar_HUD1_X_Min.FloatValue;
    g_fCvar_HUD1_Y_Min = g_hCvar_HUD1_Y_Min.FloatValue;
    g_fCvar_HUD1_X_Max = g_hCvar_HUD1_X_Max.FloatValue;
    g_fCvar_HUD1_Y_Max = g_hCvar_HUD1_Y_Max.FloatValue;
    g_fCvar_HUD1_Width = g_hCvar_HUD1_Width.FloatValue;
    g_fCvar_HUD1_Height = g_hCvar_HUD1_Height.FloatValue;

    g_hCvar_HUD2_Text.GetString(g_sCvar_HUD2_Text, sizeof(g_sCvar_HUD2_Text));
    g_bCvar_HUD2_Text = (g_sCvar_HUD2_Text[0] != 0);
    g_iCvar_HUD2_TextAlign = g_hCvar_HUD2_TextAlign.IntValue;
    g_bCvar_HUD2_BlinkTank = g_hCvar_HUD2_BlinkTank.BoolValue;
    g_bCvar_HUD2_Blink = g_hCvar_HUD2_Blink.BoolValue;
    g_bCvar_HUD2_Beep = g_hCvar_HUD2_Beep.BoolValue;
    g_bCvar_HUD2_Visible = g_hCvar_HUD2_Visible.BoolValue;
    g_bCvar_HUD2_Background = g_hCvar_HUD2_Background.BoolValue;
    g_iCvar_HUD2_Team = g_hCvar_HUD2_Team.IntValue;
    g_iCvar_HUD2_Flag_Debug = g_hCvar_HUD2_Flag_Debug.IntValue;
    g_bCvar_HUD2_Flag_Debug = (g_iCvar_HUD2_Flag_Debug > 0);
    g_fCvar_HUD2_X = g_hCvar_HUD2_X.FloatValue;
    g_fHUD2_X = g_fCvar_HUD2_X;
    g_fCvar_HUD2_Y = g_hCvar_HUD2_Y.FloatValue;
    g_fHUD2_Y = g_fCvar_HUD2_Y;
    g_fCvar_HUD2_X_Speed = g_hCvar_HUD2_X_Speed.FloatValue;
    g_bCvar_HUD2_X_Speed = (g_fCvar_HUD2_X_Speed > 0.0);
    g_fCvar_HUD2_Y_Speed = g_hCvar_HUD2_Y_Speed.FloatValue;
    g_bCvar_HUD2_Y_Speed = (g_fCvar_HUD2_Y_Speed > 0.0);
    g_iCvar_HUD2_X_Direction = g_hCvar_HUD2_X_Direction.IntValue;
    g_iCvar_HUD2_Y_Direction = g_hCvar_HUD2_Y_Direction.IntValue;
    g_fCvar_HUD2_X_Min = g_hCvar_HUD2_X_Min.FloatValue;
    g_fCvar_HUD2_Y_Min = g_hCvar_HUD2_Y_Min.FloatValue;
    g_fCvar_HUD2_X_Max = g_hCvar_HUD2_X_Max.FloatValue;
    g_fCvar_HUD2_Y_Max = g_hCvar_HUD2_Y_Max.FloatValue;
    g_fCvar_HUD2_Width = g_hCvar_HUD2_Width.FloatValue;
    g_fCvar_HUD2_Height = g_hCvar_HUD2_Height.FloatValue;

    g_hCvar_HUD3_Text.GetString(g_sCvar_HUD3_Text, sizeof(g_sCvar_HUD3_Text));
    g_bCvar_HUD3_Text = (g_sCvar_HUD3_Text[0] != 0);
    g_iCvar_HUD3_TextAlign = g_hCvar_HUD3_TextAlign.IntValue;
    g_bCvar_HUD3_BlinkTank = g_hCvar_HUD3_BlinkTank.BoolValue;
    g_bCvar_HUD3_Blink = g_hCvar_HUD3_Blink.BoolValue;
    g_bCvar_HUD3_Beep = g_hCvar_HUD3_Beep.BoolValue;
    g_bCvar_HUD3_Visible = g_hCvar_HUD3_Visible.BoolValue;
    g_bCvar_HUD3_Background = g_hCvar_HUD3_Background.BoolValue;
    g_iCvar_HUD3_Team = g_hCvar_HUD3_Team.IntValue;
    g_iCvar_HUD3_Flag_Debug = g_hCvar_HUD3_Flag_Debug.IntValue;
    g_bCvar_HUD3_Flag_Debug = (g_iCvar_HUD3_Flag_Debug > 0);
    g_fCvar_HUD3_X = g_hCvar_HUD3_X.FloatValue;
    g_fHUD3_X = g_fCvar_HUD3_X;
    g_fCvar_HUD3_Y = g_hCvar_HUD3_Y.FloatValue;
    g_fHUD3_Y = g_fCvar_HUD3_Y;
    g_fCvar_HUD3_X_Speed = g_hCvar_HUD3_X_Speed.FloatValue;
    g_bCvar_HUD3_X_Speed = (g_fCvar_HUD3_X_Speed > 0.0);
    g_fCvar_HUD3_Y_Speed = g_hCvar_HUD3_Y_Speed.FloatValue;
    g_bCvar_HUD3_Y_Speed = (g_fCvar_HUD3_Y_Speed > 0.0);
    g_iCvar_HUD3_X_Direction = g_hCvar_HUD3_X_Direction.IntValue;
    g_iCvar_HUD3_Y_Direction = g_hCvar_HUD3_Y_Direction.IntValue;
    g_fCvar_HUD3_X_Min = g_hCvar_HUD3_X_Min.FloatValue;
    g_fCvar_HUD3_Y_Min = g_hCvar_HUD3_Y_Min.FloatValue;
    g_fCvar_HUD3_X_Max = g_hCvar_HUD3_X_Max.FloatValue;
    g_fCvar_HUD3_Y_Max = g_hCvar_HUD3_Y_Max.FloatValue;
    g_fCvar_HUD3_Width = g_hCvar_HUD3_Width.FloatValue;
    g_fCvar_HUD3_Height = g_hCvar_HUD3_Height.FloatValue;

    g_hCvar_HUD4_Text.GetString(g_sCvar_HUD4_Text, sizeof(g_sCvar_HUD4_Text));
    g_bCvar_HUD4_Text = (g_sCvar_HUD4_Text[0] != 0);
    g_iCvar_HUD4_TextAlign = g_hCvar_HUD4_TextAlign.IntValue;
    g_bCvar_HUD4_BlinkTank = g_hCvar_HUD4_BlinkTank.BoolValue;
    g_bCvar_HUD4_Blink = g_hCvar_HUD4_Blink.BoolValue;
    g_bCvar_HUD4_Beep = g_hCvar_HUD4_Beep.BoolValue;
    g_bCvar_HUD4_Visible = g_hCvar_HUD4_Visible.BoolValue;
    g_bCvar_HUD4_Background = g_hCvar_HUD4_Background.BoolValue;
    g_iCvar_HUD4_Team = g_hCvar_HUD4_Team.IntValue;
    g_iCvar_HUD4_Flag_Debug = g_hCvar_HUD4_Flag_Debug.IntValue;
    g_bCvar_HUD4_Flag_Debug = (g_iCvar_HUD4_Flag_Debug > 0);
    g_fCvar_HUD4_X = g_hCvar_HUD4_X.FloatValue;
    g_fHUD4_X = g_fCvar_HUD4_X;
    g_fCvar_HUD4_Y = g_hCvar_HUD4_Y.FloatValue;
    g_fHUD4_Y = g_fCvar_HUD4_Y;
    g_fCvar_HUD4_X_Speed = g_hCvar_HUD4_X_Speed.FloatValue;
    g_bCvar_HUD4_X_Speed = (g_fCvar_HUD4_X_Speed > 0.0);
    g_fCvar_HUD4_Y_Speed = g_hCvar_HUD4_Y_Speed.FloatValue;
    g_bCvar_HUD4_Y_Speed = (g_fCvar_HUD4_Y_Speed > 0.0);
    g_iCvar_HUD4_X_Direction = g_hCvar_HUD4_X_Direction.IntValue;
    g_iCvar_HUD4_Y_Direction = g_hCvar_HUD4_Y_Direction.IntValue;
    g_fCvar_HUD4_X_Min = g_hCvar_HUD4_X_Min.FloatValue;
    g_fCvar_HUD4_Y_Min = g_hCvar_HUD4_Y_Min.FloatValue;
    g_fCvar_HUD4_X_Max = g_hCvar_HUD4_X_Max.FloatValue;
    g_fCvar_HUD4_Y_Max = g_hCvar_HUD4_Y_Max.FloatValue;
    g_fCvar_HUD4_Width = g_hCvar_HUD4_Width.FloatValue;
    g_fCvar_HUD4_Height = g_hCvar_HUD4_Height.FloatValue;

    g_bCvar_BlinkTank = (g_bCvar_HUD1_BlinkTank || g_bCvar_HUD2_BlinkTank || g_bCvar_HUD3_BlinkTank || g_bCvar_HUD4_BlinkTank);

    GetHUD_Flags();
}

/****************************************************************************************************/

void GetHUD_Flags()
{
    if (g_bCvar_HUD1_Flag_Debug)
    {
        g_iHUD1Flags = g_iCvar_HUD1_Flag_Debug;
    }
    else
    {
        g_iHUD1Flags = HUD_FLAG_TEXT;

        switch (g_iCvar_HUD1_TextAlign)
        {
            case 1: g_iHUD1Flags |= HUD_FLAG_ALIGN_LEFT;
            case 2: g_iHUD1Flags |= HUD_FLAG_ALIGN_CENTER;
            case 3: g_iHUD1Flags |= HUD_FLAG_ALIGN_RIGHT;
        }

        switch (g_iCvar_HUD1_Team)
        {
            case 1: g_iHUD1Flags |= HUD_FLAG_TEAM_SURVIVORS;
            case 2: g_iHUD1Flags |= HUD_FLAG_TEAM_INFECTED;
        }

        if (!g_bCvar_HUD1_Visible)
            g_iHUD1Flags |= HUD_FLAG_NOTVISIBLE;

        if (!g_bCvar_HUD1_Background)
            g_iHUD1Flags |= HUD_FLAG_NOBG;

        if (g_bCvar_HUD1_Blink)
            g_iHUD1Flags |= HUD_FLAG_BLINK;

        if (g_bCvar_HUD1_Beep)
            g_iHUD1Flags |= HUD_FLAG_BEEP;
    }

    if (g_bCvar_HUD2_Flag_Debug)
    {
        g_iHUD2Flags = g_iCvar_HUD2_Flag_Debug;
    }
    else
    {
        g_iHUD2Flags = HUD_FLAG_TEXT;

        switch (g_iCvar_HUD2_TextAlign)
        {
            case 1: g_iHUD2Flags |= HUD_FLAG_ALIGN_LEFT;
            case 2: g_iHUD2Flags |= HUD_FLAG_ALIGN_CENTER;
            case 3: g_iHUD2Flags |= HUD_FLAG_ALIGN_RIGHT;
        }

        switch (g_iCvar_HUD2_Team)
        {
            case 1: g_iHUD2Flags |= HUD_FLAG_TEAM_SURVIVORS;
            case 2: g_iHUD2Flags |= HUD_FLAG_TEAM_INFECTED;
        }

        if (!g_bCvar_HUD2_Visible)
            g_iHUD2Flags |= HUD_FLAG_NOTVISIBLE;

        if (!g_bCvar_HUD2_Background)
            g_iHUD2Flags |= HUD_FLAG_NOBG;

        if (g_bCvar_HUD2_Blink)
            g_iHUD2Flags |= HUD_FLAG_BLINK;

        if (g_bCvar_HUD2_Beep)
            g_iHUD2Flags |= HUD_FLAG_BEEP;
    }

    if (g_bCvar_HUD3_Flag_Debug)
    {
        g_iHUD3Flags = g_iCvar_HUD3_Flag_Debug;
    }
    else
    {
        g_iHUD3Flags = HUD_FLAG_TEXT;

        switch (g_iCvar_HUD3_TextAlign)
        {
            case 1: g_iHUD3Flags |= HUD_FLAG_ALIGN_LEFT;
            case 2: g_iHUD3Flags |= HUD_FLAG_ALIGN_CENTER;
            case 3: g_iHUD3Flags |= HUD_FLAG_ALIGN_RIGHT;
        }

        switch (g_iCvar_HUD3_Team)
        {
            case 1: g_iHUD3Flags |= HUD_FLAG_TEAM_SURVIVORS;
            case 2: g_iHUD3Flags |= HUD_FLAG_TEAM_INFECTED;
        }

        if (!g_bCvar_HUD3_Visible)
            g_iHUD3Flags |= HUD_FLAG_NOTVISIBLE;

        if (!g_bCvar_HUD3_Background)
            g_iHUD3Flags |= HUD_FLAG_NOBG;

        if (g_bCvar_HUD3_Blink)
            g_iHUD3Flags |= HUD_FLAG_BLINK;

        if (g_bCvar_HUD3_Beep)
            g_iHUD3Flags |= HUD_FLAG_BEEP;
    }

    if (g_bCvar_HUD4_Flag_Debug)
    {
        g_iHUD4Flags = g_iCvar_HUD4_Flag_Debug;
    }
    else
    {
        g_iHUD4Flags = HUD_FLAG_TEXT;

        switch (g_iCvar_HUD4_TextAlign)
        {
            case 1: g_iHUD4Flags |= HUD_FLAG_ALIGN_LEFT;
            case 2: g_iHUD4Flags |= HUD_FLAG_ALIGN_CENTER;
            case 3: g_iHUD4Flags |= HUD_FLAG_ALIGN_RIGHT;
        }

        switch (g_iCvar_HUD4_Team)
        {
            case 1: g_iHUD4Flags |= HUD_FLAG_TEAM_SURVIVORS;
            case 2: g_iHUD4Flags |= HUD_FLAG_TEAM_INFECTED;
        }

        if (!g_bCvar_HUD4_Visible)
            g_iHUD4Flags |= HUD_FLAG_NOTVISIBLE;

        if (!g_bCvar_HUD4_Background)
            g_iHUD4Flags |= HUD_FLAG_NOBG;

        if (g_bCvar_HUD4_Blink)
            g_iHUD4Flags |= HUD_FLAG_BLINK;

        if (g_bCvar_HUD4_Beep)
            g_iHUD4Flags |= HUD_FLAG_BEEP;
    }

    g_iExtraHUDFlags = HUD_FLAG_TEXT | HUD_FLAG_NOBG | HUD_FLAG_ALIGN_LEFT;
}

/****************************************************************************************************/

public void HookEvents()
{
    if (g_bCvar_Enabled && !g_bEventsHooked)
    {
        g_bEventsHooked = true;

        HookEvent("tank_spawn", Event_TankSpawn);
        HookEvent("player_death", Event_PlayerDeath);
        HookEvent("player_hurt", Event_PlayerHurt);
        HookEvent("infected_death", Event_InfectedDeath);
        HookEvent("round_start", Event_RoundStart);
        HookEvent("create_panic_event", Event_PanicStart, EventHookMode_PostNoCopy);
        HookEvent("panic_event_finished", Event_PanicEnd, EventHookMode_PostNoCopy);
        return;
    }

    if (!g_bCvar_Enabled && g_bEventsHooked)
    {
        g_bEventsHooked = false;

        UnhookEvent("tank_spawn", Event_TankSpawn);
        UnhookEvent("player_death", Event_PlayerDeath);
        UnhookEvent("player_hurt", Event_PlayerHurt);
        UnhookEvent("infected_death", Event_InfectedDeath);
        UnhookEvent("round_start", Event_RoundStart);
        UnhookEvent("create_panic_event", Event_PanicStart, EventHookMode_PostNoCopy);
        UnhookEvent("panic_event_finished", Event_PanicEnd, EventHookMode_PostNoCopy);
        return;
    }
}

/****************************************************************************************************/

public void Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));

	// Kill stats for the per-client HUD content sources
	if (IsValidClient(victim) && GetClientTeam(victim) == TEAM_INFECTED)
	{
		int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
		if (IsValidClient(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
			g_iClientSpecialKills[attacker]++;

		if (GetZombieClass(victim) == L4D2_ZOMBIECLASS_TANK)
		{
			if (IsValidClient(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR && g_iTankLastHealth > 0)
				g_iTankDamage[attacker] += g_iTankLastHealth;
			g_bTankBoardFrozen = true;
			g_iTankLastHealth = 0;
		}
	}

	if (!g_bAliveTank) return; // No tank in play; no damage to record

	if(IsAiTank(victim))
    {
        g_bAliveTank = false;
    }
}

public void Event_InfectedDeath(Handle event, const char[] name, bool dontBroadcast)
{
    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (IsValidClient(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR)
        g_iClientCommonKills[attacker]++;
}

public void Event_PlayerHurt(Handle event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidClient(victim) || GetClientTeam(victim) != TEAM_INFECTED || GetZombieClass(victim) != L4D2_ZOMBIECLASS_TANK)
        return;

    if (!IsPlayerAlive(victim) || IsPlayerIncapacitated(victim))
        return;

    int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
    int damage = GetEventInt(event, "dmg_health");
    int remain = GetEventInt(event, "health");
    if (IsValidClient(attacker) && GetClientTeam(attacker) == TEAM_SURVIVOR && damage > 0)
        g_iTankDamage[attacker] += damage;

    g_iTankLastHealth = remain;
    int maxHP = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (maxHP > g_iTankMaxHealth)
        g_iTankMaxHealth = maxHP;
}

public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    g_bAliveTank = false;
    g_fRoundStartTime = GetGameTime();
    g_fPanicUntil = 0.0;
    g_bPanicActive = false;
    ResetHUDKillStats();
    ResetTankDamageBoard();
    HookHUDSendProxies();
}

public void Event_PanicStart(Handle event, const char[] name, bool dontBroadcast)
{
    g_bPanicActive = true;
    g_fPanicUntil = GetGameTime() + HUD_PANIC_WINDOW;
}

public void Event_PanicEnd(Handle event, const char[] name, bool dontBroadcast)
{
    g_bPanicActive = false;
    g_fPanicUntil = 0.0;
}

void ResetHUDKillStats()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iClientSpecialKills[client] = 0;
        g_iClientCommonKills[client] = 0;
        g_fClientBhopPeak[client] = 0.0;
        g_fClientGroundedSince[client] = 0.0;
    }
}

void ResetTankDamageBoard()
{
    for (int client = 1; client <= MaxClients; client++)
        g_iTankDamage[client] = 0;
    g_iTankMaxHealth = 0;
    g_iTankLastHealth = 0;
    g_bTankBoardFrozen = false;
}

bool IsAiTank(int tank)
{
	if (tank != 0 && GetClientTeam(tank) == 3 && GetEntProp(tank, Prop_Send, "m_zombieClass") == 8)
	{
		return true;
	}
	return false;
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bCvar_BlinkTank)
        g_bAliveTank = true;

    int tank = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(tank))
        return;

    // A new tank fight starts a fresh board; extra tanks in the same fight keep accumulating.
    if (g_bTankBoardFrozen || !HasAnyTankDamage())
        ResetTankDamageBoard();

    int maxHP = GetEntProp(tank, Prop_Data, "m_iMaxHealth");
    int health = GetClientHealth(tank);
    if (maxHP < health)
        maxHP = health;
    if (maxHP > g_iTankMaxHealth)
        g_iTankMaxHealth = maxHP;
}

bool HasAnyTankDamage()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_iTankDamage[client] > 0)
            return true;
    }
    return false;
}

/****************************************************************************************************/

public Action TimerUpdateHUD(Handle timer)
{
    if (g_bCvar_Enabled)
    {
        if (!AreAllHUDSendProxiesHooked())
            HookHUDSendProxies(false);
        UpdateClientSpeeds();
        UpdateHUD();
    }

    return Plugin_Continue;
}

/****************************************************************************************************/

public void UpdateHUD()
{
    GetHUD_Texts();
    GetHUD_Pos();

    int flags;

    if (g_bHUDResetPending[HUD1])
        g_bHUDResetPending[HUD1] = false;
    else
    {
        if (g_bCvar_HUD1_BlinkTank && g_bAliveTank)
            flags = g_iHUD1Flags | HUD_FLAG_BLINK;
        else
            flags = g_iHUD1Flags;
        HUDSetLayout(HUD1, flags, "%s", g_sHUD_TextArray[HUD1]);
        HUDPlace(HUD1, g_fHUD1_X, g_fHUD1_Y, g_fCvar_HUD1_Width, g_fCvar_HUD1_Height * (CountCharInString(g_sHUD_TextArray[HUD1], '\n') + 1));
    }

    if (g_bHUDResetPending[HUD2])
        g_bHUDResetPending[HUD2] = false;
    else
    {
        if (g_bCvar_HUD2_BlinkTank && g_bAliveTank)
            flags = g_iHUD2Flags | HUD_FLAG_BLINK;
        else
            flags = g_iHUD2Flags;
        HUDSetLayout(HUD2, flags, "%s", g_sHUD_TextArray[HUD2]);
        HUDPlace(HUD2, g_fHUD2_X, g_fHUD2_Y, g_fCvar_HUD2_Width, g_fCvar_HUD2_Height * (CountCharInString(g_sHUD_TextArray[HUD2], '\n') + 1));
    }

    if (g_bHUDResetPending[HUD3])
        g_bHUDResetPending[HUD3] = false;
    else
    {
        if (g_bCvar_HUD3_BlinkTank && g_bAliveTank)
            flags = g_iHUD3Flags | HUD_FLAG_BLINK;
        else
            flags = g_iHUD3Flags;
        HUDSetLayout(HUD3, flags, "%s", g_sHUD_TextArray[HUD3]);
        HUDPlace(HUD3, g_fHUD3_X, g_fHUD3_Y, g_fCvar_HUD3_Width, g_fCvar_HUD3_Height * (CountCharInString(g_sHUD_TextArray[HUD3], '\n') + 1));
    }

    if (g_bHUDResetPending[HUD4])
        g_bHUDResetPending[HUD4] = false;
    else
    {
        if (g_bCvar_HUD4_BlinkTank && g_bAliveTank)
            flags = g_iHUD4Flags | HUD_FLAG_BLINK;
        else
            flags = g_iHUD4Flags;
        HUDSetLayout(HUD4, flags, "%s", g_sHUD_TextArray[HUD4]);
        HUDPlace(HUD4, g_fHUD4_X, g_fHUD4_Y, g_fCvar_HUD4_Width, g_fCvar_HUD4_Height * (CountCharInString(g_sHUD_TextArray[HUD4], '\n') + 1));
    }

    // Own slots 4-7 globally. Slots 8-14 are SendProxy-only so the kill HUD
    // keeps its netprops; opted-in clients see our content through the proxy.
    PlaceOwnedExtraHUDSlots();
}

/****************************************************************************************************/

void GetHUD_Pos()
{
    if (g_bCvar_HUD1_X_Speed)
    {
        switch (g_iCvar_HUD1_X_Direction)
        {
            case HUD_X_LEFT_TO_RIGHT:
            {
                g_fHUD1_X += g_fCvar_HUD1_X_Speed;

                if (g_fHUD1_X > g_fCvar_HUD1_X_Max)
                    g_fHUD1_X = g_fCvar_HUD1_X_Min;
            }
            case HUD_X_RIGHT_TO_LEFT:
            {
                g_fHUD1_X -= g_fCvar_HUD1_X_Speed;

                if (g_fHUD1_X < g_fCvar_HUD1_X_Min)
                    g_fHUD1_X = g_fCvar_HUD1_X_Max;
            }
        }
    }

    if (g_bCvar_HUD1_Y_Speed)
    {
        switch (g_iCvar_HUD1_Y_Direction)
        {
            case HUD_Y_TOP_TO_BOTTOM:
            {
                g_fHUD1_Y += g_fCvar_HUD1_Y_Speed;

                if (g_fHUD1_Y > g_fCvar_HUD1_Y_Max)
                    g_fHUD1_Y = g_fCvar_HUD1_Y_Min;
            }
            case HUD_Y_BOTTOM_TO_TOP:
            {
                g_fHUD1_Y -= g_fCvar_HUD1_Y_Speed;

                if (g_fHUD1_Y < g_fCvar_HUD1_Y_Min)
                    g_fHUD1_Y = g_fCvar_HUD1_X_Max;
            }
        }
    }

    if (g_bCvar_HUD2_X_Speed)
    {
        switch (g_iCvar_HUD2_X_Direction)
        {
            case HUD_X_LEFT_TO_RIGHT:
            {
                g_fHUD2_X += g_fCvar_HUD2_X_Speed;

                if (g_fHUD2_X > g_fCvar_HUD2_X_Max)
                    g_fHUD2_X = g_fCvar_HUD2_X_Min;
            }
            case HUD_X_RIGHT_TO_LEFT:
            {
                g_fHUD2_X -= g_fCvar_HUD2_X_Speed;

                if (g_fHUD2_X < g_fCvar_HUD2_X_Min)
                    g_fHUD2_X = g_fCvar_HUD2_X_Max;
            }
        }
    }

    if (g_bCvar_HUD2_Y_Speed)
    {
        switch (g_iCvar_HUD2_Y_Direction)
        {
            case HUD_Y_TOP_TO_BOTTOM:
            {
                g_fHUD2_Y += g_fCvar_HUD2_Y_Speed;

                if (g_fHUD2_Y > g_fCvar_HUD2_Y_Max)
                    g_fHUD2_Y = g_fCvar_HUD2_Y_Min;
            }
            case HUD_Y_BOTTOM_TO_TOP:
            {
                g_fHUD2_Y -= g_fCvar_HUD2_Y_Speed;

                if (g_fHUD2_Y < g_fCvar_HUD2_Y_Min)
                    g_fHUD2_Y = g_fCvar_HUD2_X_Max;
            }
        }
    }

    if (g_bCvar_HUD3_X_Speed)
    {
        switch (g_iCvar_HUD3_X_Direction)
        {
            case HUD_X_LEFT_TO_RIGHT:
            {
                g_fHUD3_X += g_fCvar_HUD3_X_Speed;

                if (g_fHUD3_X > g_fCvar_HUD3_X_Max)
                    g_fHUD3_X = g_fCvar_HUD3_X_Min;
            }
            case HUD_X_RIGHT_TO_LEFT:
            {
                g_fHUD3_X -= g_fCvar_HUD3_X_Speed;

                if (g_fHUD3_X < g_fCvar_HUD3_X_Min)
                    g_fHUD3_X = g_fCvar_HUD3_X_Max;
            }
        }
    }

    if (g_bCvar_HUD3_Y_Speed)
    {
        switch (g_iCvar_HUD3_Y_Direction)
        {
            case HUD_Y_TOP_TO_BOTTOM:
            {
                g_fHUD3_Y += g_fCvar_HUD3_Y_Speed;

                if (g_fHUD3_Y > g_fCvar_HUD3_Y_Max)
                    g_fHUD3_Y = g_fCvar_HUD3_Y_Min;
            }
            case HUD_Y_BOTTOM_TO_TOP:
            {
                g_fHUD3_Y -= g_fCvar_HUD3_Y_Speed;

                if (g_fHUD3_Y < g_fCvar_HUD3_Y_Min)
                    g_fHUD3_Y = g_fCvar_HUD3_X_Max;
            }
        }
    }

    if (g_bCvar_HUD4_X_Speed)
    {
        switch (g_iCvar_HUD4_X_Direction)
        {
            case HUD_X_LEFT_TO_RIGHT:
            {
                g_fHUD4_X += g_fCvar_HUD4_X_Speed;

                if (g_fHUD4_X > g_fCvar_HUD4_X_Max)
                    g_fHUD4_X = g_fCvar_HUD4_X_Min;
            }
            case HUD_X_RIGHT_TO_LEFT:
            {
                g_fHUD4_X -= g_fCvar_HUD4_X_Speed;

                if (g_fHUD4_X < g_fCvar_HUD4_X_Min)
                    g_fHUD4_X = g_fCvar_HUD4_X_Max;
            }
        }
    }

    if (g_bCvar_HUD4_Y_Speed)
    {
        switch (g_iCvar_HUD4_Y_Direction)
        {
            case HUD_Y_TOP_TO_BOTTOM:
            {
                g_fHUD4_Y += g_fCvar_HUD4_Y_Speed;

                if (g_fHUD4_Y > g_fCvar_HUD4_Y_Max)
                    g_fHUD4_Y = g_fCvar_HUD4_Y_Min;
            }
            case HUD_Y_BOTTOM_TO_TOP:
            {
                g_fHUD4_Y -= g_fCvar_HUD4_Y_Speed;

                if (g_fHUD4_Y < g_fCvar_HUD4_Y_Min)
                    g_fHUD4_Y = g_fCvar_HUD4_X_Max;
            }
        }
    }
}

/****************************************************************************************************/

void GetHUD_Texts()
{
    RefreshHUD2Fragments();

    g_sBuffer = "\0";
    if (g_bData_HUD1_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sData_HUD1_Text, g_sSpaces);
    }
    else if (g_bCvar_HUD1_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sCvar_HUD1_Text, g_sSpaces);
    }
    else
    {
        GetHUD1_Text(g_sHUD1_Text, sizeof(g_sHUD1_Text));
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sHUD1_Text, g_sSpaces);
    }
    g_sHUD_TextArray[HUD1] = g_sBuffer;

    g_sBuffer = "\0";
    if (g_bData_HUD2_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sData_HUD2_Text, g_sSpaces);
    }
    else if (g_bCvar_HUD2_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sCvar_HUD2_Text, g_sSpaces);
    }
    else
    {
        GetHUD2_Text(g_sHUD2_Text, sizeof(g_sHUD2_Text));
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sHUD2_Text, g_sSpaces);
    }
    g_sHUD_TextArray[HUD2] = g_sBuffer;

    g_sBuffer = "\0";
    if (g_bData_HUD3_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sData_HUD3_Text, g_sSpaces);
    }
    else if (g_bCvar_HUD3_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sCvar_HUD3_Text, g_sSpaces);
    }
    else
    {
        GetHUD3_Text(g_sHUD3_Text, sizeof(g_sHUD3_Text));
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sHUD3_Text, g_sSpaces);
    }
    g_sHUD_TextArray[HUD3] = g_sBuffer;

    g_sBuffer = "\0";
    if (g_bData_HUD4_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sData_HUD4_Text, g_sSpaces);
    }
    else if (g_bCvar_HUD4_Text)
    {
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sCvar_HUD4_Text, g_sSpaces);
    }
    else
    {
        GetHUD4_Text(g_sHUD4_Text, sizeof(g_sHUD4_Text));
        FormatEx(g_sBuffer, sizeof(g_sBuffer), "%s%s", g_sHUD4_Text, g_sSpaces);
    }
    g_sHUD_TextArray[HUD4] = g_sBuffer;

    BuildClientHUDTexts();
}

/****************************************************************************************************/
/*
void GetHUD1_Text(char[] output, int size)
{
   	FormatEx(output, size, "\0");
	int boss_proximity = RoundToNearest(GetBossProximity() * 100.0);
	int g_fWitchPercent, g_fTankPercent;
	if(GetWitchFlow(0))
	{
		g_fWitchPercent = RoundToNearest(GetWitchFlow(0) * 100.0);
	}
	else
	{
		g_fWitchPercent = 0;
	}
	if(GetTankFlow(0))
	{
		g_fTankPercent = RoundToNearest(GetTankFlow(0) * 100.0);
	}
	else
	{
		g_fTankPercent = 0;
	}
	if(g_fTankPercent)
	{
		if(g_fWitchPercent)
		{
			FormatEx(output, size, "当前: [%d] 坦克: [%d] 女巫: [%d]", boss_proximity, g_fTankPercent, g_fWitchPercent);
		}
		else
		{
			FormatEx(output, size, "当前: [%d] 坦克: [%d] 女巫: [Null]", boss_proximity, g_fTankPercent);
		}
	} 
	else if(g_fWitchPercent)
	{
		FormatEx(output, size, "当前: [%d] 坦克: [Null] 女巫: [%d]", boss_proximity, g_fWitchPercent);
	}
	else
	{
		FormatEx(output, size, "当前: [%d] 坦克: [Null] 女巫: [Null]", boss_proximity);
	}
}
*/


void GetHUD1_Text(char[] output, int size)
{
	int IsStaticTank = 0, IsStaticWitch = 0;
	ConVar cv;
	if(g_bWitchAndTankSystemAvailable){
		cv = FindConVar("sm_tank_can_spawn");
		if(cv.IntValue){
			if(IsStaticTankMap()){
				IsStaticTank = 2;
			}else{
				IsStaticTank = 1;
			}
	        
	    }
		cv = FindConVar("sm_witch_can_spawn");
		if(cv.IntValue){
			if(IsStaticWitchMap())
			{
				IsStaticWitch = 2;
			}else
			{
				IsStaticWitch = 1;
			}	    
		}
	}	
	
	FormatEx(output, size, "\0");
	int boss_proximity = RoundToNearest(GetBossProximity() * 100.0);
	int g_fWitchPercent, g_fTankPercent;
	g_fTankPercent = RoundToNearest(GetTankFlow(0)* 100.0);
	g_fWitchPercent = RoundToNearest(GetWitchFlow(0) * 100.0);
	//int max_dist = GetConVarInt(FindConVar("inf_SpawnDistanceMin"));
	FormatEx(output, size, "进度: [ %d%% ]", boss_proximity);
	if(IsStaticTank == 1 || (!g_bWitchAndTankSystemAvailable && g_fTankPercent))
	{
		
		FormatEx(output, size, "%s    坦克: [ %d%% ]", output, g_fTankPercent);
	}else if(IsStaticTank == 2)
	{
		FormatEx(output, size, "%s    坦克: [ 固定 ]", output);
	}
	if(IsStaticWitch == 1 || (!g_bWitchAndTankSystemAvailable && g_fWitchPercent))
	{
		
		FormatEx(output, size, "%s    女巫: [ %d%% ]", output, g_fWitchPercent);
	}
	else if(IsStaticWitch == 2)
	{
		FormatEx(output, size, "%s    女巫: [ 固定 ]", output);
	}
	//PrintToConsoleAll("tank: %d witch: %d", IsStaticTank, IsStaticTank);
}

/****************************************************************************************************/
float GetBossProximity()
{
	float proximity = GetMaxSurvivorCompletion() + g_hVsBossBuffer.FloatValue / L4D2Direct_GetMapMaxFlowDistance();

	return (proximity > 1.0) ? 1.0 : proximity;
}

float GetMaxSurvivorCompletion()
{
	float flow = 0.0, tmp_flow = 0.0, origin[3];
	Address pNavArea;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			GetClientAbsOrigin(i, origin);
			pNavArea = L4D2Direct_GetTerrorNavArea(origin);
			if (pNavArea == Address_Null) 
			{
				pNavArea = L4D_GetNearestNavArea(origin, 300.0, false, false, false, 2);
			}
			if (pNavArea != Address_Null) {
				tmp_flow = L4D2Direct_GetTerrorNavAreaFlow(pNavArea);
				flow = (flow > tmp_flow) ? flow : tmp_flow;
			}
		}
	}

	return (flow / L4D2Direct_GetMapMaxFlowDistance());
}

// This method will return the Tank flow for a specified round
stock float GetTankFlow(int round)
{
	return L4D2Direct_GetVSTankFlowPercent(round);
}

stock float GetWitchFlow(int round)
{
	return L4D2Direct_GetVSWitchFlowPercent(round);
}
stock int GetPlayerNumber()
{
	int number = 0;
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && IsClientInGame(i) && !IsFakeClient(i))
			number ++;
	}
	return number;
}
void GetHUD2_Text(char[] output, int size)
{
		ComposeHUD2Text(output, size, HUD2_PART_ALL_MASK);
}

/****************************************************************************************************/

bool HavePills(int client)
{
	char weapon[32];
	int KidSlot=GetPlayerWeaponSlot(client, 4);
 
	if(KidSlot !=-1)
	{
		GetEdictClassname(KidSlot, weapon, 32);
		if(StrEqual(weapon, "weapon_pain_pills"))
		{
			return true;
		}
 	}
	return false;
}

void GetHUD3_Text(char[] output, int size)
{
	FormatEx(output, size, "\0");
		
	int num = 0;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
		    continue;

		if (GetClientTeam(client) != TEAM_SURVIVOR)
		    continue;
		num += 1;
		if (num > 4)
			continue;
		char health[64];
		if (!IsPlayerAlive(client))
		    FormatEx(health, sizeof(health), "☠");
		else if(L4D_IsPlayerIncapacitated(client))
			FormatEx(health, sizeof(health), "(%dHP)",GetClientHealth(client) + GetClientTempHealth(client));
		else
		    FormatEx(health, sizeof(health), "%dHP", GetClientHealth(client) + GetClientTempHealth(client));
		char name[12];
		GetClientName(client,name,sizeof(name));
		if (output[0] == 0)
			FormatEx(output, size, "玩家状态[药][倒地]\n%s: %s", name, health);
		else
			Format(output, size, "%s\n%s: %s", output, name, health);
		if(HavePills(client)&&IsPlayerAlive(client))
			Format(output, size, "%s[%s][%d]", output, "有",L4D_GetPlayerReviveCount(client));  
		else if(!HavePills(client)&&IsPlayerAlive(client))
			Format(output, size, "%s[%s][%d]", output, "无",L4D_GetPlayerReviveCount(client));	
    }
}

/****************************************************************************************************/

void GetHUD4_Text(char[] output, int size)
{
    FormatEx(output, size, "\0");

    // for (int client = 1; client <= MaxClients; client++)
    // {
        // if (!IsClientInGame(client))
            // continue;

        // if (IsFakeClient(client))
            // continue;

        // if (BaseComm_IsClientMuted(client))
            // continue;

        // if (!IsClientSpeaking(client))
            // continue;

        // if (output[0] == 0)
            // FormatEx(output, size, "Players Speaking:\n%N", client);
        // else
            // Format(output, size, "%s\n%N", output, client);
    // }
}

public Action ShowSpecHud(int client, int args)
{
    if (!IsValidClient(client))
    {
        g_hCvar_HUD3_Visible.SetInt(1);
        return Plugin_Handled;
    }

    if (g_eHUDPrefsLoadState[client] != HUDPrefs_Ready)
        return Plugin_Handled;

    g_iClientHUDMask[client] |= (1 << HUD3);
    SaveHUDPrefs(client);
    return Plugin_Handled;
}

public Action offSpecHud(int client, int args)
{
    if (!IsValidClient(client))
    {
        g_hCvar_HUD3_Visible.SetInt(0);
        return Plugin_Handled;
    }

    if (g_eHUDPrefsLoadState[client] != HUDPrefs_Ready)
        return Plugin_Handled;

    g_iClientHUDMask[client] &= ~(1 << HUD3);
    SaveHUDPrefs(client);
    return Plugin_Handled;
}

bool AreAllHUDSendProxiesHooked()
{
    for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
    {
        for (int proxy = 0; proxy < HUD_PROXY_COUNT; proxy++)
        {
            if (!g_bHUDProxyHooked[hud][proxy])
                return false;
        }
    }

    return true;
}

void HookHUDSendProxies(bool logFailures = true)
{
    if (!LibraryExists(SENDPROXY_LIB) || FindEntityByClassname(-1, GAMERULES_PROXY_CLASS) == -1)
        return;

    for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
    {
        HookHUDSendProxySlot(hud);

        if (logFailures && (!g_bHUDProxyHooked[hud][HUD_PROXY_FLAGS]
            || !g_bHUDProxyHooked[hud][HUD_PROXY_STRING]
            || !g_bHUDProxyHooked[hud][HUD_PROXY_POS_X]
            || !g_bHUDProxyHooked[hud][HUD_PROXY_POS_Y]
            || !g_bHUDProxyHooked[hud][HUD_PROXY_WIDTH]
            || !g_bHUDProxyHooked[hud][HUD_PROXY_HEIGHT]))
            LogError("[Scripted HUD] Failed to hook SendProxy for HUD slot %d.", hud);
    }
}

void HookHUDSendProxySlot(int hud)
{
    HOOK_HUD_SLOT(0)
    HOOK_HUD_SLOT(1)
    HOOK_HUD_SLOT(2)
    HOOK_HUD_SLOT(3)
    HOOK_HUD_SLOT(4)
    HOOK_HUD_SLOT(5)
    HOOK_HUD_SLOT(6)
    HOOK_HUD_SLOT(7)
    HOOK_HUD_SLOT(8)
    HOOK_HUD_SLOT(9)
    HOOK_HUD_SLOT(10)
    HOOK_HUD_SLOT(11)
    HOOK_HUD_SLOT(12)
    HOOK_HUD_SLOT(13)
    HOOK_HUD_SLOT(14)
}

void UnhookHUDSendProxies()
{
    bool canUnhook = LibraryExists(SENDPROXY_LIB) && FindEntityByClassname(-1, GAMERULES_PROXY_CLASS) != -1;

    for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
    {
        if (canUnhook)
            UnhookHUDSendProxySlot(hud);
    }

    ResetHUDSendProxyState();
}

void UnhookHUDSendProxySlot(int hud)
{
    UNHOOK_HUD_SLOT(0)
    UNHOOK_HUD_SLOT(1)
    UNHOOK_HUD_SLOT(2)
    UNHOOK_HUD_SLOT(3)
    UNHOOK_HUD_SLOT(4)
    UNHOOK_HUD_SLOT(5)
    UNHOOK_HUD_SLOT(6)
    UNHOOK_HUD_SLOT(7)
    UNHOOK_HUD_SLOT(8)
    UNHOOK_HUD_SLOT(9)
    UNHOOK_HUD_SLOT(10)
    UNHOOK_HUD_SLOT(11)
    UNHOOK_HUD_SLOT(12)
    UNHOOK_HUD_SLOT(13)
    UNHOOK_HUD_SLOT(14)
}

void ResetHUDSendProxyState()
{
    for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
    {
        for (int proxy = 0; proxy < HUD_PROXY_COUNT; proxy++)
            g_bHUDProxyHooked[hud][proxy] = false;
    }
}

Action ProxyHUDFlags(int &value, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    int baseFlags = GetHUDSlotBaseFlags(hud);
    bool blinkTank = GetHUDSlotBlinkTank(hud);

    if (IsClientSlotVisible(client, hud) && !g_bHUDResetPending[hud])
    {
        // Rebuild from the authoritative configured flags instead of patching the raw
        // netprop value. This guarantees a client can never receive a transient
        // "visible but neither NOBG nor TEXT" state (rendered as an empty
        // white-outlined background box), e.g. during the ResetHUD refresh window.
        if (blinkTank && g_bAliveTank)
            baseFlags |= HUD_FLAG_BLINK;
        value = baseFlags & ~HUD_FLAG_NOTVISIBLE;

        // A player who explicitly selected a personal content source should see it
        // regardless of the slot's global team restriction.
        if (GetClientHUDSource(client, hud) != HUD_CONTENT_DEFAULT)
            value &= ~HUD_FLAG_TEAM_MASK;
    }
    else
        value = (baseFlags | HUD_FLAG_NOTVISIBLE | HUD_FLAG_TEXT | HUD_FLAG_NOBG);

    return Plugin_Changed;
}

Action ProxyHUDString(char[] value, int maxlength, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    strcopy(value, maxlength, g_sClientHUDText[client][hud]);
    return Plugin_Changed;
}

Action ProxyHUDPosX(float &value, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    if (hud >= HUD_EXTRA_FIRST && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    float x, y, w;
    GetClientHUDSlotRect(client, hud, x, y, w);
    value = x;
    return Plugin_Changed;
}

Action ProxyHUDPosY(float &value, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    if (hud < HUD_EXTRA_FIRST || !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    float x, y, w;
    GetClientHUDSlotRect(client, hud, x, y, w);
    value = y;
    return Plugin_Changed;
}

Action ProxyHUDWidth(float &value, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    if (hud >= HUD_EXTRA_FIRST && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    float x, y, w;
    GetClientHUDSlotRect(client, hud, x, y, w);
    value = w;
    return Plugin_Changed;
}

Action ProxyHUDHeight(float &value, int hud, int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Continue;

    if (IsKillHudSharedSlot(hud) && !IsClientSlotVisible(client, hud))
        return Plugin_Continue;

    if (g_sClientHUDText[client][hud][0] == '\0')
        return Plugin_Continue;

    value = GetHUDSlotLineHeight(hud) * float(CountCharInString(g_sClientHUDText[client][hud], '\n') + 1);
    return Plugin_Changed;
}

void BuildClientHUDTexts()
{
    char personalized[128];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
            g_sClientHUDText[client][hud][0] = '\0';

        for (int hud = HUD1; hud <= HUD4; hud++)
            strcopy(g_sClientHUDText[client][hud], sizeof(g_sClientHUDText[][]), g_sHUD_TextArray[hud]);

        if (!g_bData_HUD2_Text && !g_bCvar_HUD2_Text)
        {
            ComposeHUD2Text(personalized, sizeof(personalized), g_iClientHUD2Mask[client], client);
            FormatEx(g_sClientHUDText[client][HUD2], sizeof(g_sClientHUDText[][]), "%s%s", personalized, g_sSpaces);
        }

        for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
        {
            int source = GetClientHUDSource(client, hud);
            if (source == HUD_CONTENT_DEFAULT)
                continue;

            if ((g_iClientHUDMask[client] & (1 << hud)) == 0)
                continue;

            BuildHUDSourceText(client, source, personalized, sizeof(personalized));
            FormatEx(g_sClientHUDText[client][hud], sizeof(g_sClientHUDText[][]), "%s%s", personalized, g_sSpaces);
        }
    }
}

// ====================================================================================================
// Player-selectable HUD content sources (HUD3/HUD4)
// ====================================================================================================
void BuildHUDSourceText(int client, int source, char[] output, int size)
{
    switch (source)
    {
        case HUD_CONTENT_SURVIVORS: BuildSurvivorStatusText(client, output, size);
        case HUD_CONTENT_SPECIALS:  BuildSpecialInfectedText(client, output, size);
        case HUD_CONTENT_KILLS:     BuildKillStatsText(client, output, size);
        case HUD_CONTENT_PING:      BuildPingText(client, output, size);
        case HUD_CONTENT_TANK_DMG:  BuildTankDamageText(client, output, size);
        case HUD_CONTENT_ITEMS:     BuildTeamItemsText(client, output, size);
        case HUD_CONTENT_WAVE:      BuildWaveCountdownText(client, output, size);
        case HUD_CONTENT_SPEED:     BuildSpeedText(client, output, size);
        case HUD_CONTENT_ROUND:     BuildRoundStatusText(client, output, size);
        case HUD_CONTENT_WITCH:     BuildWitchWarnText(client, output, size);
        case HUD_CONTENT_PROGRESS:  GetHUD1_Text(output, size);
        case HUD_CONTENT_SERVER:    ComposeHUD2Text(output, size, g_iClientHUD2Mask[client], client);
        default: output[0] = '\0';
    }
}

void BuildSurvivorStatusText(int client, char[] output, int size)
{
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_SurvHeader", client);

    int num = 0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target))
            continue;

        if (GetClientTeam(target) != TEAM_SURVIVOR)
            continue;

        num++;
        if (num > 4)
            continue;

        char health[32];
        if (!IsPlayerAlive(target))
            FormatEx(health, sizeof(health), "☠");
        else if (L4D_IsPlayerIncapacitated(target))
            FormatEx(health, sizeof(health), "(%dHP)", GetClientHealth(target) + GetClientTempHealth(target));
        else
            FormatEx(health, sizeof(health), "%dHP", GetClientHealth(target) + GetClientTempHealth(target));

        char name[12];
        GetClientName(target, name, sizeof(name));
        Format(output, size, "%s\n%s: %s", output, name, health);

        if (IsPlayerAlive(target))
        {
            char pills[16];
            FormatEx(pills, sizeof(pills), "%T", HavePills(target) ? "L4D2ScriptedHUD_PillsYes" : "L4D2ScriptedHUD_PillsNo", client);
            Format(output, size, "%s[%s][%d]", output, pills, L4D_GetPlayerReviveCount(target));
        }
    }
}

void BuildSpecialInfectedText(int client, char[] output, int size)
{
    int aliveSpecials;
    int shownSpecials;
    int tankCount;
    char entries[96];
    char tanks[40];

    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || GetClientTeam(target) != TEAM_INFECTED)
            continue;

        if (!IsPlayerAlive(target) || IsPlayerGhost(target))
            continue;

        int zclass = GetZombieClass(target);
        if (zclass == L4D2_ZOMBIECLASS_TANK)
        {
            tankCount++;
            if (tankCount <= 2)
            {
                if (tanks[0] != 0)
                    StrCat(tanks, sizeof(tanks), " ");
                Format(tanks, sizeof(tanks), "%s%d/%d", tanks, GetClientHealth(target), GetEntProp(target, Prop_Data, "m_iMaxHealth"));
            }
            continue;
        }

        if (zclass < L4D2_ZOMBIECLASS_SMOKER || zclass > L4D2_ZOMBIECLASS_CHARGER)
            continue;

        aliveSpecials++;
        if (shownSpecials >= 6)
            continue;

        shownSpecials++;
        char abbrev[16];
        FormatEx(abbrev, sizeof(abbrev), "%T", GetZombieClassPhrase(zclass), client);
        if (entries[0] != 0)
            StrCat(entries, sizeof(entries), " ");
        Format(entries, sizeof(entries), "%s%s%d", entries, abbrev, GetClientHealth(target));
    }

    int witchCount;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        if (GetEntProp(entity, Prop_Data, "m_iHealth") > 0)
            witchCount++;
    }

    int siLimit = (g_hCvar_InfectedLimit == null) ? 0 : g_hCvar_InfectedLimit.IntValue;
    if (siLimit > 0)
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_SpecialsHeader", client, aliveSpecials, siLimit);
    else
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_SpecialsHeaderNoLimit", client, aliveSpecials);

    if (witchCount > 0)
    {
        char witches[24];
        FormatEx(witches, sizeof(witches), "%T", "L4D2ScriptedHUD_WitchCount", client, witchCount);
        Format(output, size, "%s  %s", output, witches);
    }

    if (entries[0] != 0)
    {
        Format(output, size, "%s\n%s", output, entries);
        if (aliveSpecials > shownSpecials)
            Format(output, size, "%s +%d", output, aliveSpecials - shownSpecials);
    }

    if (tanks[0] != 0)
    {
        char tankLine[64];
        FormatEx(tankLine, sizeof(tankLine), "%T", "L4D2ScriptedHUD_TankLine", client, tanks);
        Format(output, size, "%s\n%s", output, tankLine);
        if (tankCount > 2)
            Format(output, size, "%s +%d", output, tankCount - 2);
    }
}

void BuildKillStatsText(int client, char[] output, int size)
{
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_KillsHeader", client);

    int num = 0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || GetClientTeam(target) != TEAM_SURVIVOR)
            continue;

        num++;
        if (num > 4)
            continue;

        char name[12];
        GetClientName(target, name, sizeof(name));
        Format(output, size, "%s\n%s: %d|%d", output, name, g_iClientSpecialKills[target], g_iClientCommonKills[target]);
    }
}

void BuildPingText(int client, char[] output, int size)
{
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_PingHeader", client);

    int shown = 0;
    // Survivors first, then everyone else, capped to keep within the 127-byte HUD limit.
    for (int pass = 0; pass < 2 && shown < 6; pass++)
    {
        for (int target = 1; target <= MaxClients && shown < 6; target++)
        {
            if (!IsClientInGame(target) || IsFakeClient(target))
                continue;

            bool isSurvivor = (GetClientTeam(target) == TEAM_SURVIVOR);
            if ((pass == 0) != isSurvivor)
                continue;

            char name[12];
            GetClientName(target, name, sizeof(name));
            Format(output, size, "%s\n%s: %d", output, name, RoundToNearest(GetClientAvgLatency(target, NetFlow_Both) * 1000.0));
            shown++;
        }
    }
}

void BuildTankDamageText(int client, char[] output, int size)
{
    if (!HasAnyTankDamage())
    {
        FormatEx(output, size, "%T", g_bAliveTank ? "L4D2ScriptedHUD_TankDmgEmpty" : "L4D2ScriptedHUD_TankDmgNone", client);
        return;
    }

    FormatEx(output, size, "%T", g_bTankBoardFrozen ? "L4D2ScriptedHUD_TankDmgDead" : "L4D2ScriptedHUD_TankDmgHeader", client);

    int topClients[4];
    int topDamage[4];
    for (int target = 1; target <= MaxClients; target++)
    {
        if (g_iTankDamage[target] <= 0)
            continue;
        if (!IsClientInGame(target) && !IsClientConnected(target))
            continue;

        for (int slot = 0; slot < 4; slot++)
        {
            if (g_iTankDamage[target] > topDamage[slot])
            {
                for (int shift = 3; shift > slot; shift--)
                {
                    topClients[shift] = topClients[shift - 1];
                    topDamage[shift] = topDamage[shift - 1];
                }
                topClients[slot] = target;
                topDamage[slot] = g_iTankDamage[target];
                break;
            }
        }
    }

    int maxHP = g_iTankMaxHealth;
    for (int slot = 0; slot < 4; slot++)
    {
        if (topClients[slot] == 0)
            break;

        char name[12];
        if (IsClientInGame(topClients[slot]))
            GetClientName(topClients[slot], name, sizeof(name));
        else
            FormatEx(name, sizeof(name), "#%d", topClients[slot]);

        if (maxHP > 0)
            Format(output, size, "%s\n%s %d %d%%", output, name, topDamage[slot], RoundToNearest(float(topDamage[slot]) * 100.0 / float(maxHP)));
        else
            Format(output, size, "%s\n%s %d", output, name, topDamage[slot]);
    }
}

void BuildTeamItemsText(int client, char[] output, int size)
{
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_ItemsHeader", client);

    int num = 0;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || GetClientTeam(target) != TEAM_SURVIVOR)
            continue;

        num++;
        if (num > 4)
            continue;

        char name[12];
        char items[24];
        GetClientName(target, name, sizeof(name));
        FormatSurvivorItems(target, client, items, sizeof(items));
        Format(output, size, "%s\n%s %s", output, name, items);
    }
}

void FormatSurvivorItems(int target, int lang, char[] output, int size)
{
    char throwable[8];
    char heal[8];
    char temp[8];
    GetWeaponSlotAbbrev(target, 2, lang, throwable, sizeof(throwable));
    GetWeaponSlotAbbrev(target, 3, lang, heal, sizeof(heal));
    GetWeaponSlotAbbrev(target, 4, lang, temp, sizeof(temp));
    FormatEx(output, size, "%s%s%s", throwable, heal, temp);
}

void GetWeaponSlotAbbrev(int target, int slot, int lang, char[] output, int size)
{
    int weapon = GetPlayerWeaponSlot(target, slot);
    if (weapon <= MaxClients || !IsValidEdict(weapon))
    {
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_ItemEmpty", lang);
        return;
    }

    char classname[32];
    GetEdictClassname(weapon, classname, sizeof(classname));

    char phrase[40];
    if (StrEqual(classname, "weapon_molotov"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemMolotov");
    else if (StrEqual(classname, "weapon_pipe_bomb"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemPipe");
    else if (StrEqual(classname, "weapon_vomitjar"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemBile");
    else if (StrEqual(classname, "weapon_first_aid_kit"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemKit");
    else if (StrEqual(classname, "weapon_defibrillator"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemDefib");
    else if (StrEqual(classname, "weapon_upgradepack_incendiary"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemIncendiary");
    else if (StrEqual(classname, "weapon_upgradepack_explosive"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemExplosive");
    else if (StrEqual(classname, "weapon_pain_pills"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemPills");
    else if (StrEqual(classname, "weapon_adrenaline"))
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemAdrenaline");
    else
        strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ItemEmpty");

    FormatEx(output, size, "%T", phrase, lang);
}

void BuildWaveCountdownText(int client, char[] output, int size)
{
    char eta[24];
    if (g_bInfectedControlAvailable && GetFeatureStatus(FeatureType_Native, "GetNextSpawnTime") == FeatureStatus_Available)
    {
        float remaining = GetNextSpawnTime();
        if (remaining < 0.0)
            FormatEx(eta, sizeof(eta), "--");
        else
            FormatEx(eta, sizeof(eta), "%.1fs", remaining);
    }
    else
        FormatEx(eta, sizeof(eta), "--");

    int aliveSpecials;
    int siLimit = (g_hCvar_InfectedLimit == null) ? 0 : g_hCvar_InfectedLimit.IntValue;
    for (int target = 1; target <= MaxClients; target++)
    {
        if (!IsClientInGame(target) || GetClientTeam(target) != TEAM_INFECTED)
            continue;
        if (!IsPlayerAlive(target) || IsPlayerGhost(target))
            continue;
        int zclass = GetZombieClass(target);
        if (zclass >= L4D2_ZOMBIECLASS_SMOKER && zclass <= L4D2_ZOMBIECLASS_CHARGER)
            aliveSpecials++;
    }

    FormatEx(output, size, "%T", "L4D2ScriptedHUD_WaveHeader", client, eta);
    if (siLimit > 0)
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_WaveAlive", client, aliveSpecials, siLimit);
    else
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_WaveAliveNoLimit", client, aliveSpecials);
}

void BuildSpeedText(int client, char[] output, int size)
{
    int subject = GetHUDSpeedSubject(client);
    if (subject <= 0)
    {
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_SpeedNone", client);
        return;
    }

    int current = RoundToNearest(GetHorizontalSpeed(subject));
    int peak = RoundToNearest(g_fClientBhopPeak[subject]);
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_SpeedLine", client, current);
    if (peak > 0)
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_BhopLine", client, peak);
    else
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_BhopNone", client);
}

void BuildRoundStatusText(int client, char[] output, int size)
{
    int elapsed = 0;
    if (g_fRoundStartTime > 0.0)
        elapsed = RoundToFloor(GetGameTime() - g_fRoundStartTime);
    if (elapsed < 0)
        elapsed = 0;

    char clock[16];
    FormatEx(clock, sizeof(clock), "%d:%02d", elapsed / 60, elapsed % 60);
    FormatEx(output, size, "%T", "L4D2ScriptedHUD_RoundTimer", client, clock);

    if (g_bPanicActive || (g_fPanicUntil > 0.0 && GetGameTime() < g_fPanicUntil))
    {
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_HordeActive", client);
        return;
    }

    float remaining = -1.0;
    if (GetFeatureStatus(FeatureType_Native, "L4D2_CTimerGetRemainingTime") == FeatureStatus_Available
        && GetFeatureStatus(FeatureType_Native, "L4D2_CTimerHasStarted") == FeatureStatus_Available)
    {
        if (L4D2_CTimerHasStarted(L4D2CT_MobSpawnTimer) && !L4D2_CTimerIsElapsed(L4D2CT_MobSpawnTimer))
            remaining = L4D2_CTimerGetRemainingTime(L4D2CT_MobSpawnTimer);
    }

    if (remaining >= 0.0 && remaining < 180.0)
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_HordeSoon", client, RoundToCeil(remaining));
    else
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_HordeIdle", client);
}

void BuildWitchWarnText(int client, char[] output, int size)
{
    int subject = GetHUDSpeedSubject(client);
    float origin[3];
    bool hasOrigin;
    if (subject > 0)
    {
        GetClientAbsOrigin(subject, origin);
        hasOrigin = true;
    }

    int nearest = -1;
    float nearestDist = 0.0;
    int witchCount;
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "witch")) != -1)
    {
        if (GetEntProp(entity, Prop_Data, "m_iHealth") <= 0)
            continue;
        witchCount++;
        if (!hasOrigin)
            continue;

        float witchPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", witchPos);
        float dist = GetVectorDistance(origin, witchPos);
        if (nearest == -1 || dist < nearestDist)
        {
            nearest = entity;
            nearestDist = dist;
        }
    }

    if (witchCount <= 0)
    {
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_WitchNone", client);
        return;
    }

    if (nearest == -1)
    {
        FormatEx(output, size, "%T", "L4D2ScriptedHUD_WitchCount", client, witchCount);
        return;
    }

    float meters = nearestDist / 39.37;
    char state[32];
    float rage;
    if (HasEntProp(nearest, Prop_Send, "m_rage"))
        rage = GetEntPropFloat(nearest, Prop_Send, "m_rage");

    if (rage >= 1.0)
        FormatEx(state, sizeof(state), "%T", "L4D2ScriptedHUD_WitchEnraged", client);
    else if (nearestDist <= HUD_WITCH_NEAR_UNITS)
        FormatEx(state, sizeof(state), "%T", "L4D2ScriptedHUD_WitchNear", client);
    else if (rage > 0.15)
        FormatEx(state, sizeof(state), "%T", "L4D2ScriptedHUD_WitchAlert", client);
    else
        FormatEx(state, sizeof(state), "%T", "L4D2ScriptedHUD_WitchCalm", client);

    FormatEx(output, size, "%T", "L4D2ScriptedHUD_WitchLine", client, meters, state);
    if (witchCount > 1)
        Format(output, size, "%s\n%T", output, "L4D2ScriptedHUD_WitchExtra", client, witchCount - 1);
}

void UpdateClientSpeeds()
{
    float now = GetGameTime();
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
            continue;

        float speed = GetHorizontalSpeed(client);
        bool onGround = (GetEntPropEnt(client, Prop_Send, "m_hGroundEntity") != -1);
        if (!onGround)
        {
            if (speed > g_fClientBhopPeak[client])
                g_fClientBhopPeak[client] = speed;
            g_fClientGroundedSince[client] = 0.0;
            continue;
        }

        if (speed >= HUD_BHOP_RESET_SPEED)
        {
            if (speed > g_fClientBhopPeak[client])
                g_fClientBhopPeak[client] = speed;
            g_fClientGroundedSince[client] = 0.0;
            continue;
        }

        if (g_fClientGroundedSince[client] <= 0.0)
            g_fClientGroundedSince[client] = now;
        else if (now - g_fClientGroundedSince[client] >= HUD_BHOP_RESET_HOLD)
            g_fClientBhopPeak[client] = 0.0;
    }
}

float GetHorizontalSpeed(int client)
{
    float vel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
    return SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
}

int GetHUDSpeedSubject(int client)
{
    if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
        return client;

    int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
    if (IsValidClient(target) && GetClientTeam(target) == TEAM_SURVIVOR && IsPlayerAlive(target))
        return target;

    return 0;
}

char[] GetZombieClassPhrase(int zclass)
{
    char phrase[32];
    switch (zclass)
    {
        case L4D2_ZOMBIECLASS_SMOKER:  strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsSmoker");
        case L4D2_ZOMBIECLASS_BOOMER:  strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsBoomer");
        case L4D2_ZOMBIECLASS_HUNTER:  strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsHunter");
        case L4D2_ZOMBIECLASS_SPITTER: strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsSpitter");
        case L4D2_ZOMBIECLASS_JOCKEY:  strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsJockey");
        case L4D2_ZOMBIECLASS_CHARGER: strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsCharger");
        default: strcopy(phrase, sizeof(phrase), "L4D2ScriptedHUD_ClsSmoker");
    }
    return phrase;
}

void RefreshHUDStatusCvars()
{
    if (g_hCvar_HostPort == null)             g_hCvar_HostPort = FindConVar("hostport");
    if (g_hCvar_Hostname == null)             g_hCvar_Hostname = FindConVar("hostname");
    if (g_hCvar_ReadyCfgName == null)          g_hCvar_ReadyCfgName = FindConVar("l4d_ready_cfg_name");
    if (g_hCvar_AddonsEclipse == null)         g_hCvar_AddonsEclipse = FindConVar("l4d2_addons_eclipse");
    if (g_hCvar_AIDifficulty == null)          g_hCvar_AIDifficulty = FindConVar("ah_ai_dynamic_current_level");
    if (g_hCvar_InfectedLimit == null)         g_hCvar_InfectedLimit = FindConVar("l4d_infected_limit");
    if (g_hCvar_RespawnInterval == null)       g_hCvar_RespawnInterval = FindConVar("versus_special_respawn_interval");
    if (g_hCvar_DirSpawnCount == null)         g_hCvar_DirSpawnCount = FindConVar("dirspawn_count");
    if (g_hCvar_DirSpawnInterval == null)      g_hCvar_DirSpawnInterval = FindConVar("dirspawn_interval");
    if (g_hCvar_SurvivorLimit == null)         g_hCvar_SurvivorLimit = FindConVar("survivor_limit");
    if (g_hCvar_InfectedPlayerLimit == null)   g_hCvar_InfectedPlayerLimit = FindConVar("z_max_player_zombies");
    if (g_hCvar_MaxPlayers == null)            g_hCvar_MaxPlayers = FindConVar("sv_maxplayers");
    if (g_hCvar_RoundWipeCount == null)        g_hCvar_RoundWipeCount = FindConVar("anne_round_wipe_count");
}

void LoadBaseServerName()
{
    RefreshHUDStatusCvars();
    g_sBaseServerName[0] = '\0';

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/hostname/hostname.txt");

    KeyValues kv = new KeyValues("AnneHappy");
    if (kv.ImportFromFile(path) && g_hCvar_HostPort != null)
    {
        char port[16];
        g_hCvar_HostPort.GetString(port, sizeof(port));
        if (kv.JumpToKey(port, false))
            kv.GetString("servername", g_sBaseServerName, sizeof(g_sBaseServerName));
    }
    delete kv;

    if (g_sBaseServerName[0] == '\0' && g_hCvar_Hostname != null)
        g_hCvar_Hostname.GetString(g_sBaseServerName, sizeof(g_sBaseServerName));
}

void RefreshHUD2Fragments()
{
    RefreshHUDStatusCvars();

    for (int i = 0; i < sizeof(g_sHUD2Fragments); i++)
        g_sHUD2Fragments[i][0] = '\0';

    strcopy(g_sHUD2Fragments[0], sizeof(g_sHUD2Fragments[]), g_sBaseServerName);

    char cfgName[128];
    if (g_hCvar_ReadyCfgName != null)
        g_hCvar_ReadyCfgName.GetString(cfgName, sizeof(cfgName));

    bool isAnne;
    bool usesDirectorSpawn;
    GetHUDModeTag(cfgName, g_sHUD2Fragments[1], sizeof(g_sHUD2Fragments[]), isAnne, usesDirectorSpawn);

    if (g_hCvar_AIDifficulty != null)
    {
        char difficulty[16];
        GetHUDAIDifficultyName(g_hCvar_AIDifficulty.IntValue, difficulty, sizeof(difficulty));
        if (difficulty[0] != '\0')
            FormatEx(g_sHUD2Fragments[2], sizeof(g_sHUD2Fragments[]), "[AI:%s]", difficulty);
    }

    if (!IsHUDTeamFull(isAnne))
        strcopy(g_sHUD2Fragments[3], sizeof(g_sHUD2Fragments[]), "[缺人]");

    if (g_hCvar_AddonsEclipse != null && g_hCvar_AddonsEclipse.IntValue == 0)
        strcopy(g_sHUD2Fragments[4], sizeof(g_sHUD2Fragments[]), "[无MOD]");

    if (isAnne)
    {
        int infectedCount;
        int spawnInterval = -1;

        if (usesDirectorSpawn)
        {
            if (g_hCvar_DirSpawnCount != null)
                infectedCount = g_hCvar_DirSpawnCount.IntValue;
            else if (g_hCvar_InfectedLimit != null)
                infectedCount = g_hCvar_InfectedLimit.IntValue;

            if (g_hCvar_DirSpawnInterval != null)
                spawnInterval = RoundToNearest(g_hCvar_DirSpawnInterval.FloatValue);
            else if (g_hCvar_RespawnInterval != null)
                spawnInterval = g_hCvar_RespawnInterval.IntValue;
        }
        else
        {
            if (g_hCvar_InfectedLimit != null)
                infectedCount = g_hCvar_InfectedLimit.IntValue;
            if (g_hCvar_RespawnInterval != null)
                spawnInterval = g_hCvar_RespawnInterval.IntValue;
        }

        if (infectedCount > 0 && spawnInterval >= 0)
            FormatEx(g_sHUD2Fragments[5], sizeof(g_sHUD2Fragments[]), "[%d特%d秒]", infectedCount, spawnInterval);
    }

    int playerLimit = (g_hCvar_MaxPlayers == null) ? MaxClients : g_hCvar_MaxPlayers.IntValue;
    FormatEx(g_sHUD2Fragments[6], sizeof(g_sHUD2Fragments[]), "(%d/%d)", GetPlayerNumber(), playerLimit);

    // Published by optional/AnneHappy/server.smx; gate on the Anne mode tag so a
    // stale value from an unloaded plugin is not displayed after a mode switch.
    g_iHUD2WipeCount = (isAnne && g_hCvar_RoundWipeCount != null) ? g_hCvar_RoundWipeCount.IntValue : 0;
}

void GetHUDModeTag(const char[] cfgName, char[] output, int size, bool &isAnne, bool &usesDirectorSpawn)
{
    output[0] = '\0';
    isAnne = false;
    usesDirectorSpawn = false;

    if (StrContains(cfgName, "AnneHappy", false) != -1)
    {
        if (StrContains(cfgName, "Shotgun", false) != -1)
            strcopy(output, size, "[喷子药役]");
        else if (StrContains(cfgName, "HardCore", false) != -1)
            strcopy(output, size, "[硬核药役]");
        else
            strcopy(output, size, "[普通药役]");
        isAnne = true;
    }
    else if (StrContains(cfgName, "AnneCoop", false) != -1)
    {
        strcopy(output, size, "[Anne战役]");
        isAnne = true;
        usesDirectorSpawn = true;
    }
    else if (StrContains(cfgName, "AnneRealism", false) != -1)
    {
        strcopy(output, size, "[Anne写实]");
        isAnne = true;
        usesDirectorSpawn = true;
    }
    else if (StrContains(cfgName, "AnneMutation4", false) != -1)
    {
        strcopy(output, size, "[Anne绝境]");
        isAnne = true;
        usesDirectorSpawn = true;
    }
    else if (StrContains(cfgName, "AllCharger", false) != -1)
    {
        strcopy(output, size, "[牛牛冲刺]");
        isAnne = true;
    }
    else if (StrContains(cfgName, "1vHunters", false) != -1)
    {
        strcopy(output, size, "[HT训练]");
        isAnne = true;
    }
    else if (StrContains(cfgName, "WitchParty", false) != -1)
    {
        strcopy(output, size, "[女巫派对]");
        isAnne = true;
    }
    else if (StrContains(cfgName, "Alone", false) != -1)
    {
        strcopy(output, size, "[单人装逼]");
        isAnne = true;
    }
    else if (cfgName[0] != '\0')
    {
        FormatEx(output, size, "[%s]", cfgName);
    }
}

void GetHUDAIDifficultyName(int level, char[] output, int size)
{
    switch (level)
    {
        case 1: strcopy(output, size, "简单");
        case 2: strcopy(output, size, "普通");
        case 3: strcopy(output, size, "困难");
        case 4: strcopy(output, size, "专家");
        case 5: strcopy(output, size, "极限");
        case 6: strcopy(output, size, "音理");
        default: output[0] = '\0';
    }
}

bool IsHUDTeamFull(bool isAnne)
{
    int players;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && (GetClientTeam(client) == TEAM_SURVIVOR || GetClientTeam(client) == TEAM_INFECTED))
            players++;
    }

    if (players == 0)
        return true;

    int requiredPlayers = (g_hCvar_SurvivorLimit == null) ? 4 : g_hCvar_SurvivorLimit.IntValue;
    if (!isAnne && g_hCvar_InfectedPlayerLimit != null)
        requiredPlayers += g_hCvar_InfectedPlayerLimit.IntValue;

    return players >= requiredPlayers;
}

void ComposeHUD2Text(char[] output, int size, int mask, int langTarget = LANG_SERVER)
{
    output[0] = '\0';
    for (int i = 0; i < sizeof(g_sHUD2Fragments); i++)
    {
        if ((mask & (1 << i)) != 0 && g_sHUD2Fragments[i][0] != '\0')
            StrCat(output, size, g_sHUD2Fragments[i]);
    }

    if ((mask & HUD2_PART_WIPE_COUNT) != 0 && g_iHUD2WipeCount > 0)
    {
        char wipes[32];
        FormatEx(wipes, sizeof(wipes), "%T", "L4D2ScriptedHUD_WipeCount", langTarget, g_iHUD2WipeCount);
        StrCat(output, size, wipes);
    }
}

void ResetHUDPrefsClient(int client)
{
    g_iClientHUDMask[client] = HUD_SLOT_DEFAULT_MASK;
    g_iClientHUD2Mask[client] = HUD2_PART_ALL_MASK;
    g_iClientHUDLayout[client] = HUD_LAYOUT_STANDARD;
    g_iClientHUDRevision[client] = 0;
    g_eHUDPrefsLoadState[client] = HUDPrefs_None;
    g_bClientHasCookie[client] = false;
    g_sClientHUDCookie[client][0] = '\0';
    g_iClientSpecialKills[client] = 0;
    g_iClientCommonKills[client] = 0;
    g_iTankDamage[client] = 0;
    g_fClientBhopPeak[client] = 0.0;
    g_fClientGroundedSince[client] = 0.0;
    g_iHUDMenuSlot[client] = HUD3;

    for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
    {
        g_iClientHUDSource[client][slot] = HUD_CONTENT_DEFAULT;
        g_sClientHUDText[client][slot][0] = '\0';
    }
}

void InitializeHUDPrefsClient(int client)
{
    ResetHUDPrefsClient(client);

    if (IsFakeClient(client))
    {
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
        return;
    }

    if (g_hHUDPrefsCookie != null && AreClientCookiesCached(client))
    {
        ReadHUDPrefsCookie(client);
        LoadHUDPrefs(client);
    }
    else
    {
        g_eHUDPrefsLoadState[client] = HUDPrefs_WaitingForCookie;
    }
}

public void OnClientConnected(int client)
{
    ResetHUDPrefsClient(client);
}

public void OnClientPostAdminCheck(int client)
{
    InitializeHUDPrefsClient(client);
}

public void OnClientCookiesCached(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    ReadHUDPrefsCookie(client);
    if (g_eHUDPrefsLoadState[client] == HUDPrefs_WaitingForCookie)
        LoadHUDPrefs(client);
    else if (!g_bHUDPrefsDatabaseReady && g_eHUDPrefsLoadState[client] == HUDPrefs_Ready)
        ApplyHUDPrefsCookie(client);
}

public void OnClientDisconnect(int client)
{
    ResetHUDPrefsClient(client);
}

void ReadHUDPrefsCookie(int client)
{
    if (g_hHUDPrefsCookie == null)
        return;

    g_hHUDPrefsCookie.Get(client, g_sClientHUDCookie[client], sizeof(g_sClientHUDCookie[]));
    g_bClientHasCookie[client] = (g_sClientHUDCookie[client][0] != '\0');
}

void ClearHUDSources(int sources[HUD_SLOT_COUNT])
{
    for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
        sources[slot] = HUD_CONTENT_DEFAULT;
}

void CopyHUDSources(int dest[HUD_SLOT_COUNT], const int src[HUD_SLOT_COUNT])
{
    for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
        dest[slot] = src[slot];
}

void ApplyHUDSources(int client, const int sources[HUD_SLOT_COUNT])
{
    CopyHUDSources(g_iClientHUDSource[client], sources);
}

void PackSlotSources(const int sources[HUD_SLOT_COUNT], char[] output, int size)
{
    output[0] = '\0';
    for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
    {
        char piece[8];
        FormatEx(piece, sizeof(piece), "%s%d", (slot == 0) ? "" : ",", sources[slot]);
        StrCat(output, size, piece);
    }
}

void ParsePackedSlotSources(const char[] packed, int sources[HUD_SLOT_COUNT])
{
    ClearHUDSources(sources);
    if (packed[0] == '\0')
        return;

    char bits[HUD_SLOT_COUNT][8];
    int count = ExplodeString(packed, ",", bits, sizeof(bits), sizeof(bits[]));
    for (int slot = 0; slot < count && slot < HUD_SLOT_COUNT; slot++)
    {
        int source = StringToInt(bits[slot]);
        if (source < HUD_CONTENT_DEFAULT || source > HUD_CONTENT_MAX)
            source = HUD_CONTENT_DEFAULT;
        sources[slot] = source;
    }
}

bool ParseHUDPrefsCookie(int client, int &hudMask, int &hud2Mask, int &revision, int &layout, int sources[HUD_SLOT_COUNT])
{
    ClearHUDSources(sources);
    if (!g_bClientHasCookie[client])
        return false;

    char parts[7][80];
    int count = ExplodeString(g_sClientHUDCookie[client], "|", parts, sizeof(parts), sizeof(parts[]));
    if ((count < 2 || count > 6) || parts[0][0] == '\0' || parts[1][0] == '\0')
        return false;

    int consumed = StringToIntEx(parts[0], hudMask);
    if (consumed <= 0 || consumed != strlen(parts[0]) || hudMask < 0 || hudMask > HUD_SLOT_ALL_MASK)
        return false;

    consumed = StringToIntEx(parts[1], hud2Mask);
    if (consumed <= 0 || consumed != strlen(parts[1]) || hud2Mask < 0 || hud2Mask > HUD2_PART_ALL_MASK)
        return false;

    revision = 0;
    if (count >= 3)
    {
        if (parts[2][0] == '\0')
            return false;
        consumed = StringToIntEx(parts[2], revision);
        if (consumed <= 0 || consumed != strlen(parts[2]) || revision < 0)
            return false;
    }

    layout = HUD_LAYOUT_STANDARD;
    if (count >= 4)
    {
        if (parts[3][0] == '\0')
            return false;
        consumed = StringToIntEx(parts[3], layout);
        if (consumed <= 0 || consumed != strlen(parts[3]) || layout < HUD_LAYOUT_STANDARD || layout > HUD_LAYOUT_MAX)
            return false;
    }

    if (count == 5 && StrContains(parts[4], ",") != -1)
        ParsePackedSlotSources(parts[4], sources);
    else if (count >= 5)
    {
        int source;
        consumed = StringToIntEx(parts[4], source);
        if (consumed <= 0 || consumed != strlen(parts[4]) || source < HUD_CONTENT_DEFAULT || source > HUD_CONTENT_MAX)
            return false;
        sources[HUD3] = source;

        if (count >= 6)
        {
            consumed = StringToIntEx(parts[5], source);
            if (consumed <= 0 || consumed != strlen(parts[5]) || source < HUD_CONTENT_DEFAULT || source > HUD_CONTENT_MAX)
                return false;
            sources[HUD4] = source;
        }
    }

    return true;
}

bool ApplyHUDPrefsCookie(int client)
{
    int hudMask;
    int hud2Mask;
    int revision;
    int layout;
    int sources[HUD_SLOT_COUNT];
    if (!ParseHUDPrefsCookie(client, hudMask, hud2Mask, revision, layout, sources))
        return false;

    g_iClientHUDMask[client] = hudMask;
    g_iClientHUD2Mask[client] = hud2Mask;
    g_iClientHUDLayout[client] = layout;
    g_iClientHUDRevision[client] = revision;
    ApplyHUDSources(client, sources);
    return true;
}

void SaveHUDPrefsCookie(int client)
{
    if (g_hHUDPrefsCookie == null || IsFakeClient(client))
        return;

    char packed[80];
    char value[HUD_PREFS_COOKIE_SIZE];
    PackSlotSources(g_iClientHUDSource[client], packed, sizeof(packed));
    FormatEx(value, sizeof(value), "%d|%d|%d|%d|%s", g_iClientHUDMask[client], g_iClientHUD2Mask[client], g_iClientHUDRevision[client], g_iClientHUDLayout[client], packed);
    g_hHUDPrefsCookie.Set(client, value);
}

void ConnectHUDPrefsDatabase()
{
    if (g_bHUDPrefsDatabaseConnecting || g_bHUDPrefsDatabaseReady)
        return;

    if (!SQL_CheckConfig(HUD_PREFS_DB_CONFIG))
    {
        LogError("[Scripted HUD] Database config '%s' is unavailable; using ClientPrefs only.", HUD_PREFS_DB_CONFIG);
        return;
    }

    g_bHUDPrefsDatabaseConnecting = true;
    SQL_TConnect(SQLCB_ConnectHUDPrefsDatabase, HUD_PREFS_DB_CONFIG);
}

public void SQLCB_ConnectHUDPrefsDatabase(Handle owner, Handle database, const char[] error, any data)
{
    g_bHUDPrefsDatabaseConnecting = false;
    if (database == INVALID_HANDLE)
    {
        LogError("[Scripted HUD] Database connection failed; using ClientPrefs only: %s", error);
        FinalizeWaitingHUDPrefsWithoutDatabase();
        return;
    }

    g_hHUDPrefsDatabase = database;
    SQL_SetCharset(g_hHUDPrefsDatabase, "utf8mb4");

    char query[1024];
    FormatEx(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `%s` ("
        ... "`steamid` varchar(64) NOT NULL,"
        ... "`hud_mask` smallint unsigned NOT NULL DEFAULT 3,"
        ... "`hud2_mask` tinyint unsigned NOT NULL DEFAULT 255,"
        ... "`layout_preset` tinyint unsigned NOT NULL DEFAULT 0,"
        ... "`hud3_source` tinyint unsigned NOT NULL DEFAULT 0,"
        ... "`hud4_source` tinyint unsigned NOT NULL DEFAULT 0,"
        ... "`slot_sources` varchar(80) NOT NULL DEFAULT '',"
        ... "`revision` int unsigned NOT NULL DEFAULT 0,"
        ... "`updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,"
        ... "PRIMARY KEY (`steamid`)"
        ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4", HUD_PREFS_DB_TABLE);

    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_CreateHUDPrefsTable, query);
}

public void SQLCB_CreateHUDPrefsTable(Handle owner, Handle results, const char[] error, any data)
{
    if (error[0] != '\0')
    {
        LogError("[Scripted HUD] Failed to create preferences table; using ClientPrefs only: %s", error);
        CloseHandle(g_hHUDPrefsDatabase);
        g_hHUDPrefsDatabase = INVALID_HANDLE;
        FinalizeWaitingHUDPrefsWithoutDatabase();
        return;
    }

    // Migrate older tables: 1.2.0 added hud3/hud4 sources, 1.4.0 widens the
    // slot mask and stores all 15 content sources. Duplicate-column errors are
    // expected on already-migrated tables.
    g_iHUDPrefsMigrationsLeft = HUD_PREFS_MIGRATIONS;
    char query[256];
    FormatEx(query, sizeof(query), "ALTER TABLE `%s` ADD COLUMN `hud3_source` tinyint unsigned NOT NULL DEFAULT 0", HUD_PREFS_DB_TABLE);
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_MigrateHUDPrefsColumn, query);
    FormatEx(query, sizeof(query), "ALTER TABLE `%s` ADD COLUMN `hud4_source` tinyint unsigned NOT NULL DEFAULT 0", HUD_PREFS_DB_TABLE);
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_MigrateHUDPrefsColumn, query);
    FormatEx(query, sizeof(query), "ALTER TABLE `%s` MODIFY COLUMN `hud_mask` smallint unsigned NOT NULL DEFAULT 3", HUD_PREFS_DB_TABLE);
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_MigrateHUDPrefsColumn, query);
    FormatEx(query, sizeof(query), "ALTER TABLE `%s` ADD COLUMN `slot_sources` varchar(80) NOT NULL DEFAULT ''", HUD_PREFS_DB_TABLE);
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_MigrateHUDPrefsColumn, query);
}

public void SQLCB_MigrateHUDPrefsColumn(Handle owner, Handle results, const char[] error, any data)
{
    if (error[0] != '\0'
        && StrContains(error, "Duplicate column", false) == -1
        && StrContains(error, "duplicate column", false) == -1)
        LogError("[Scripted HUD] Failed to migrate preferences table column: %s", error);

    if (g_iHUDPrefsMigrationsLeft > 0)
        g_iHUDPrefsMigrationsLeft--;

    if (g_iHUDPrefsMigrationsLeft != 0 || g_hHUDPrefsDatabase == INVALID_HANDLE)
        return;

    g_bHUDPrefsDatabaseReady = true;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && g_eHUDPrefsLoadState[client] == HUDPrefs_WaitingForDatabase)
            LoadHUDPrefs(client);
    }
}

void FinalizeWaitingHUDPrefsWithoutDatabase()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || g_eHUDPrefsLoadState[client] != HUDPrefs_WaitingForDatabase)
            continue;

        ApplyHUDPrefsCookie(client);
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
    }
}

void LoadHUDPrefs(int client)
{
    if (!g_bHUDPrefsDatabaseReady || g_hHUDPrefsDatabase == INVALID_HANDLE)
    {
        if (g_bHUDPrefsDatabaseConnecting || g_hHUDPrefsDatabase != INVALID_HANDLE)
        {
            g_eHUDPrefsLoadState[client] = HUDPrefs_WaitingForDatabase;
            return;
        }

        ApplyHUDPrefsCookie(client);
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
        return;
    }

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)) || StrEqual(steamId, "BOT"))
    {
        ApplyHUDPrefsCookie(client);
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
        return;
    }

    char query[400];
    SQL_FormatQuery(g_hHUDPrefsDatabase, query, sizeof(query),
        "SELECT `hud_mask`,`hud2_mask`,`layout_preset`,`revision`,`hud3_source`,`hud4_source`,`slot_sources` FROM `%s` WHERE `steamid`='%s' LIMIT 1", HUD_PREFS_DB_TABLE, steamId);
    g_eHUDPrefsLoadState[client] = HUDPrefs_DatabasePending;
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_LoadHUDPrefs, query, GetClientUserId(client));
}

public void SQLCB_LoadHUDPrefs(Handle owner, Handle results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    if (error[0] != '\0')
    {
        LogError("[Scripted HUD] Failed to load HUD preferences: %s", error);
        ApplyHUDPrefsCookie(client);
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
        return;
    }

    if (results != INVALID_HANDLE && SQL_FetchRow(results))
    {
        int databaseHUDMask = SQL_FetchInt(results, 0) & HUD_SLOT_ALL_MASK;
        int databaseHUD2Mask = SQL_FetchInt(results, 1) & HUD2_PART_ALL_MASK;
        int databaseLayout = SQL_FetchInt(results, 2);
        if (databaseLayout < HUD_LAYOUT_STANDARD || databaseLayout > HUD_LAYOUT_MAX)
            databaseLayout = HUD_LAYOUT_STANDARD;
        int databaseRevision = SQL_FetchInt(results, 3);
        int databaseSources[HUD_SLOT_COUNT];
        ClearHUDSources(databaseSources);
        databaseSources[HUD3] = SQL_FetchInt(results, 4);
        databaseSources[HUD4] = SQL_FetchInt(results, 5);
        if (SQL_GetFieldCount(results) > 6)
        {
            char packed[80];
            SQL_FetchString(results, 6, packed, sizeof(packed));
            if (packed[0] != '\0')
                ParsePackedSlotSources(packed, databaseSources);
        }
        for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
        {
            if (databaseSources[slot] < HUD_CONTENT_DEFAULT || databaseSources[slot] > HUD_CONTENT_MAX)
                databaseSources[slot] = HUD_CONTENT_DEFAULT;
        }
        int cookieHUDMask;
        int cookieHUD2Mask;
        int cookieRevision;
        int cookieLayout;
        int cookieSources[HUD_SLOT_COUNT];

        if (ParseHUDPrefsCookie(client, cookieHUDMask, cookieHUD2Mask, cookieRevision, cookieLayout, cookieSources) && cookieRevision > databaseRevision)
        {
            g_iClientHUDMask[client] = cookieHUDMask;
            g_iClientHUD2Mask[client] = cookieHUD2Mask;
            g_iClientHUDLayout[client] = cookieLayout;
            g_iClientHUDRevision[client] = cookieRevision;
            ApplyHUDSources(client, cookieSources);
            g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
            SaveHUDPrefs(client, false);
            return;
        }

        g_iClientHUDMask[client] = databaseHUDMask;
        g_iClientHUD2Mask[client] = databaseHUD2Mask;
        g_iClientHUDLayout[client] = databaseLayout;
        g_iClientHUDRevision[client] = databaseRevision;
        ApplyHUDSources(client, databaseSources);
        g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
        SaveHUDPrefsCookie(client);
        return;
    }

    ApplyHUDPrefsCookie(client);
    g_eHUDPrefsLoadState[client] = HUDPrefs_Ready;
    SaveHUDPrefs(client, false);
}

void SaveHUDPrefs(int client, bool bumpRevision = true)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    g_iClientHUDMask[client] &= HUD_SLOT_ALL_MASK;
    g_iClientHUD2Mask[client] &= HUD2_PART_ALL_MASK;
    if (g_iClientHUDLayout[client] < HUD_LAYOUT_STANDARD || g_iClientHUDLayout[client] > HUD_LAYOUT_MAX)
        g_iClientHUDLayout[client] = HUD_LAYOUT_STANDARD;
    for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
    {
        if (g_iClientHUDSource[client][slot] < HUD_CONTENT_DEFAULT || g_iClientHUDSource[client][slot] > HUD_CONTENT_MAX)
            g_iClientHUDSource[client][slot] = HUD_CONTENT_DEFAULT;
    }
    if (bumpRevision && g_iClientHUDRevision[client] < 2147483647)
        g_iClientHUDRevision[client]++;
    SaveHUDPrefsCookie(client);

    if (!g_bHUDPrefsDatabaseReady || g_hHUDPrefsDatabase == INVALID_HANDLE || g_eHUDPrefsLoadState[client] != HUDPrefs_Ready)
        return;

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)) || StrEqual(steamId, "BOT"))
        return;

    char packed[80];
    PackSlotSources(g_iClientHUDSource[client], packed, sizeof(packed));

    char query[1400];
    SQL_FormatQuery(g_hHUDPrefsDatabase, query, sizeof(query),
        "INSERT INTO `%s` (`steamid`,`hud_mask`,`hud2_mask`,`layout_preset`,`hud3_source`,`hud4_source`,`slot_sources`,`revision`) VALUES ('%s',%d,%d,%d,%d,%d,'%s',%d) "
        ... "ON DUPLICATE KEY UPDATE "
        ... "`hud_mask`=IF(VALUES(`revision`)>=`revision`,VALUES(`hud_mask`),`hud_mask`),"
        ... "`hud2_mask`=IF(VALUES(`revision`)>=`revision`,VALUES(`hud2_mask`),`hud2_mask`),"
        ... "`layout_preset`=IF(VALUES(`revision`)>=`revision`,VALUES(`layout_preset`),`layout_preset`),"
        ... "`hud3_source`=IF(VALUES(`revision`)>=`revision`,VALUES(`hud3_source`),`hud3_source`),"
        ... "`hud4_source`=IF(VALUES(`revision`)>=`revision`,VALUES(`hud4_source`),`hud4_source`),"
        ... "`slot_sources`=IF(VALUES(`revision`)>=`revision`,VALUES(`slot_sources`),`slot_sources`),"
        ... "`revision`=GREATEST(`revision`,VALUES(`revision`))",
        HUD_PREFS_DB_TABLE, steamId, g_iClientHUDMask[client], g_iClientHUD2Mask[client], g_iClientHUDLayout[client], g_iClientHUDSource[client][HUD3], g_iClientHUDSource[client][HUD4], packed, g_iClientHUDRevision[client]);
    SQL_TQuery(g_hHUDPrefsDatabase, SQLCB_SaveHUDPrefs, query);
}

public void SQLCB_SaveHUDPrefs(Handle owner, Handle results, const char[] error, any data)
{
    if (error[0] != '\0')
        LogError("[Scripted HUD] Failed to save HUD preferences: %s", error);
}

public Action CmdHUDMenu(int client, int args)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Handled;

    OpenHUDPrefsMenu(client);
    return Plugin_Handled;
}

void AddHUDToggleItem(Menu menu, int client, const char[] key, const char[] phrase, bool enabled)
{
    char name[96];
    char item[112];
    FormatEx(name, sizeof(name), "%T", phrase, client);
    FormatEx(item, sizeof(item), "[%s] %s", enabled ? "X" : " ", name);
    menu.AddItem(key, item);
}

void OpenHUDPrefsMenu(int client)
{
    Menu menu = new Menu(MenuHandler_HUDPrefs);
    char text[128];
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_PrefsTitle", client);
    menu.SetTitle(text);

    if (g_eHUDPrefsLoadState[client] != HUDPrefs_Ready)
    {
        FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_PrefsLoading", client);
        menu.AddItem("loading", text, ITEMDRAW_DISABLED);
        menu.Display(client, MENU_TIME_FOREVER);
        return;
    }

    AddHUDToggleItem(menu, client, "hud1", "L4D2ScriptedHUD_HUD1", (g_iClientHUDMask[client] & (1 << HUD1)) != 0);
    AddHUDToggleItem(menu, client, "hud2", "L4D2ScriptedHUD_HUD2", (g_iClientHUDMask[client] & (1 << HUD2)) != 0);
    AddHUDToggleItem(menu, client, "hud3", "L4D2ScriptedHUD_HUD3", (g_iClientHUDMask[client] & (1 << HUD3)) != 0);
    AddHUDToggleItem(menu, client, "hud4", "L4D2ScriptedHUD_HUD4", (g_iClientHUDMask[client] & (1 << HUD4)) != 0);

    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_LayoutPreset", client);
    menu.AddItem("layout", text);
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_HUD2Parts", client);
    menu.AddItem("hud2_parts", text);
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_SlotsMenu", client);
    menu.AddItem("slots", text);
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_Reset", client);
    menu.AddItem("reset", text);
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUDPrefs(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action != MenuAction_Select || !IsValidClient(client))
        return 0;

    char key[32];
    menu.GetItem(item, key, sizeof(key));

    if (StrEqual(key, "layout"))
    {
        OpenHUDLayoutMenu(client);
        return 0;
    }
    if (StrEqual(key, "hud2_parts"))
    {
        OpenHUD2PartsMenu(client);
        return 0;
    }
    if (StrEqual(key, "slots"))
    {
        OpenHUDSlotListMenu(client);
        return 0;
    }
    if (StrEqual(key, "reset"))
    {
        g_iClientHUDMask[client] = HUD_SLOT_DEFAULT_MASK;
        g_iClientHUD2Mask[client] = HUD2_PART_ALL_MASK;
        g_iClientHUDLayout[client] = HUD_LAYOUT_STANDARD;
        for (int slot = 0; slot < HUD_SLOT_COUNT; slot++)
            g_iClientHUDSource[client][slot] = HUD_CONTENT_DEFAULT;
    }
    else if (strncmp(key, "hud", 3) == 0)
    {
        int hud = StringToInt(key[3]) - 1;
        if (hud >= HUD1 && hud <= HUD4)
            g_iClientHUDMask[client] ^= (1 << hud);
    }

    SaveHUDPrefs(client);
    OpenHUDPrefsMenu(client);
    return 0;
}

void GetHUDSourcePhrase(int hud, int source, char[] phrase, int size)
{
    if (source == HUD_CONTENT_DEFAULT && hud >= HUD_EXTRA_FIRST)
        strcopy(phrase, size, "L4D2ScriptedHUD_SourceOff");
    else if (source >= HUD_CONTENT_DEFAULT && source <= HUD_CONTENT_MAX)
        strcopy(phrase, size, g_sHUDSourcePhrases[source]);
    else
        strcopy(phrase, size, "L4D2ScriptedHUD_SourceOff");
}

void OpenHUDSlotListMenu(int client)
{
    Menu menu = new Menu(MenuHandler_HUDSlotList);
    char text[128];
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_SlotsTitle", client);
    menu.SetTitle(text);
    menu.ExitBackButton = true;

    for (int hud = HUD1; hud < HUD_SLOT_COUNT; hud++)
    {
        char key[16];
        char engineName[32];
        char sourceName[64];
        char sourcePhrase[64];
        char item[192];
        FormatEx(key, sizeof(key), "slot%d", hud);
        FormatEx(engineName, sizeof(engineName), "%T", g_sHUDEngineNamePhrases[hud], client);
        GetHUDSourcePhrase(hud, GetClientHUDSource(client, hud), sourcePhrase, sizeof(sourcePhrase));
        FormatEx(sourceName, sizeof(sourceName), "%T", sourcePhrase, client);
        FormatEx(item, sizeof(item), "[%s] %T", IsClientSlotVisible(client, hud) ? "X" : " ", "L4D2ScriptedHUD_SlotItem", client, hud + 1, engineName, sourceName);
        menu.AddItem(key, item);
    }

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUDSlotList(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && IsValidClient(client))
    {
        OpenHUDPrefsMenu(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsValidClient(client))
        return 0;

    char key[16];
    menu.GetItem(item, key, sizeof(key));
    if (strncmp(key, "slot", 4) == 0)
    {
        int hud = StringToInt(key[4]);
        if (hud >= HUD1 && hud < HUD_SLOT_COUNT)
            OpenHUDContentMenu(client, hud);
    }
    return 0;
}

void OpenHUDContentMenu(int client, int hud)
{
    g_iHUDMenuSlot[client] = hud;
    Menu menu = new Menu(MenuHandler_HUDContent);
    char text[192];
    if (IsKillHudSharedSlot(hud))
        FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_ContentTitleKillHud", client, hud + 1);
    else
        FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_ContentTitle", client, hud + 1);
    menu.SetTitle(text);
    menu.ExitBackButton = true;

    int current = GetClientHUDSource(client, hud);
    char key[16];
    for (int source = HUD_CONTENT_DEFAULT; source <= HUD_CONTENT_MAX; source++)
    {
        FormatEx(key, sizeof(key), "src%d", source);
        char phrase[64];
        GetHUDSourcePhrase(hud, source, phrase, sizeof(phrase));
        AddHUDToggleItem(menu, client, key, phrase, current == source);
    }
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUDContent(Menu menu, MenuAction action, int client, int item)
{
    int hud = HUD3;
    if (action != MenuAction_End && client >= 1 && client <= MaxClients)
        hud = g_iHUDMenuSlot[client];
    return HandleHUDContentMenu(menu, action, client, item, hud);
}

int HandleHUDContentMenu(Menu menu, MenuAction action, int client, int item, int hud)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && IsValidClient(client))
    {
        OpenHUDSlotListMenu(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsValidClient(client))
        return 0;

    if (hud < HUD1 || hud >= HUD_SLOT_COUNT)
        hud = HUD3;

    char key[16];
    menu.GetItem(item, key, sizeof(key));
    if (strncmp(key, "src", 3) == 0)
    {
        int source = StringToInt(key[3]);
        if (source >= HUD_CONTENT_DEFAULT && source <= HUD_CONTENT_MAX)
        {
            g_iClientHUDSource[client][hud] = source;
            if (source != HUD_CONTENT_DEFAULT)
                g_iClientHUDMask[client] |= (1 << hud);
            else if (hud >= HUD_EXTRA_FIRST)
                g_iClientHUDMask[client] &= ~(1 << hud);
        }
    }

    SaveHUDPrefs(client);
    OpenHUDContentMenu(client, hud);
    return 0;
}

void OpenHUDLayoutMenu(int client)
{
    Menu menu = new Menu(MenuHandler_HUDLayout);
    char text[128];
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_LayoutPresetTitle", client);
    menu.SetTitle(text);
    menu.ExitBackButton = true;

    AddHUDToggleItem(menu, client, "layout0", "L4D2ScriptedHUD_LayoutStandard", g_iClientHUDLayout[client] == HUD_LAYOUT_STANDARD);
    AddHUDToggleItem(menu, client, "layout3", "L4D2ScriptedHUD_Layout16x10", g_iClientHUDLayout[client] == HUD_LAYOUT_16_10);
    AddHUDToggleItem(menu, client, "layout1", "L4D2ScriptedHUD_Layout4x3", g_iClientHUDLayout[client] == HUD_LAYOUT_4_3);
    AddHUDToggleItem(menu, client, "layout2", "L4D2ScriptedHUD_LayoutUltrawide", g_iClientHUDLayout[client] == HUD_LAYOUT_ULTRAWIDE);
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUDLayout(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && IsValidClient(client))
    {
        OpenHUDPrefsMenu(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsValidClient(client))
        return 0;

    char key[16];
    menu.GetItem(item, key, sizeof(key));
    if (strncmp(key, "layout", 6) == 0)
    {
        int layout = StringToInt(key[6]);
        if (layout >= HUD_LAYOUT_STANDARD && layout <= HUD_LAYOUT_MAX)
            g_iClientHUDLayout[client] = layout;
    }

    SaveHUDPrefs(client);
    OpenHUDLayoutMenu(client);
    return 0;
}

void OpenHUD2PartsMenu(int client)
{
    Menu menu = new Menu(MenuHandler_HUD2Parts);
    char text[128];
    FormatEx(text, sizeof(text), "%T", "L4D2ScriptedHUD_HUD2PartsTitle", client);
    menu.SetTitle(text);
    menu.ExitBackButton = true;

    AddHUDToggleItem(menu, client, "part0", "L4D2ScriptedHUD_PartServerName", (g_iClientHUD2Mask[client] & HUD2_PART_SERVER_NAME) != 0);
    AddHUDToggleItem(menu, client, "part1", "L4D2ScriptedHUD_PartMode", (g_iClientHUD2Mask[client] & HUD2_PART_MODE) != 0);
    AddHUDToggleItem(menu, client, "part2", "L4D2ScriptedHUD_PartAIDifficulty", (g_iClientHUD2Mask[client] & HUD2_PART_AI_DIFFICULTY) != 0);
    AddHUDToggleItem(menu, client, "part3", "L4D2ScriptedHUD_PartMissingPlayers", (g_iClientHUD2Mask[client] & HUD2_PART_MISSING_PLAYERS) != 0);
    AddHUDToggleItem(menu, client, "part4", "L4D2ScriptedHUD_PartMod", (g_iClientHUD2Mask[client] & HUD2_PART_MOD) != 0);
    AddHUDToggleItem(menu, client, "part5", "L4D2ScriptedHUD_PartInfectedTiming", (g_iClientHUD2Mask[client] & HUD2_PART_INFECTED_TIMING) != 0);
    AddHUDToggleItem(menu, client, "part6", "L4D2ScriptedHUD_PartPlayerCount", (g_iClientHUD2Mask[client] & HUD2_PART_PLAYER_COUNT) != 0);
    AddHUDToggleItem(menu, client, "part7", "L4D2ScriptedHUD_PartWipeCount", (g_iClientHUD2Mask[client] & HUD2_PART_WIPE_COUNT) != 0);
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_HUD2Parts(Menu menu, MenuAction action, int client, int item)
{
    if (action == MenuAction_End)
    {
        delete menu;
        return 0;
    }
    if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && IsValidClient(client))
    {
        OpenHUDPrefsMenu(client);
        return 0;
    }
    if (action != MenuAction_Select || !IsValidClient(client))
        return 0;

    char key[16];
    menu.GetItem(item, key, sizeof(key));
    if (strncmp(key, "part", 4) == 0)
    {
        int part = StringToInt(key[4]);
        if (part >= 0 && part < HUD2_PART_COUNT)
            g_iClientHUD2Mask[client] ^= (1 << part);
    }

    SaveHUDPrefs(client);
    OpenHUD2PartsMenu(client);
    return 0;
}

// ====================================================================================================
// Admin Commands
// ====================================================================================================
public Action CmdReloadData(int client, int args)
{
    LoadPluginData();

    if (IsValidClient(client))
        CPrintToChat(client, "%t", "L4D2ScriptedHUD_HUDTextsDataFileReloaded");

    return Plugin_Handled;
}

/****************************************************************************************************/

public Action CmdPrintCvars(int client, int args)
{
    PrintToConsole(client, "");
    PrintToConsole(client, "======================================================================");
    PrintToConsole(client, "");
    PrintToConsole(client, "------------------ Plugin Cvars (l4d2_scripted_hud) ------------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "l4d2_scripted_hud_version : %s", PLUGIN_VERSION);
    PrintToConsole(client, "l4d2_scripted_hud_enable : %b (%s)", g_bCvar_Enabled, g_bCvar_Enabled ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_update_interval : %.1f", g_fCvar_UpdateInterval);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_text : \"%s\"", g_sCvar_HUD1_Text);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_text_align : %i (%s)", g_iCvar_HUD1_TextAlign, g_iCvar_HUD1_TextAlign == HUD_TEXT_ALIGN_LEFT ? "LEFT" : g_iCvar_HUD1_TextAlign == HUD_TEXT_ALIGN_CENTER ? "CENTER" : "RIGHT");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_blink_tank : %b (%s)", g_bCvar_HUD1_BlinkTank, g_bCvar_HUD1_BlinkTank ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_blink : %b (%s)", g_bCvar_HUD1_Blink, g_bCvar_HUD1_Blink ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_beep : %b (%s)", g_bCvar_HUD1_Beep, g_bCvar_HUD1_Beep ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_visible : %b (%s)", g_bCvar_HUD1_Visible, g_bCvar_HUD1_Visible ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_background : %i (%s)", g_bCvar_HUD1_Background, g_bCvar_HUD1_Background ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_team : %i (%s)", g_iCvar_HUD1_Team, g_iCvar_HUD1_Team == HUD_TEAM_ALL ? "ALL" : g_iCvar_HUD1_Team == HUD_TEAM_SURVIVOR ? "SURVIVOR" : "INFECTED");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_flag_debug : %i (%s)", g_iCvar_HUD1_Flag_Debug, g_bCvar_HUD1_Flag_Debug ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_x : %.4f", g_fCvar_HUD1_X);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_y : %.4f", g_fCvar_HUD1_Y);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_x_speed : %.4f", g_fCvar_HUD1_X_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_y_speed : %.4f", g_fCvar_HUD1_Y_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_x_direction : %i (%s)", g_iCvar_HUD1_X_Direction, g_iCvar_HUD1_X_Direction == HUD_X_LEFT_TO_RIGHT ? "Left to Right" : "Right to Left");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_y_direction : %i (%s)", g_iCvar_HUD1_Y_Direction, g_iCvar_HUD1_Y_Direction == HUD_Y_TOP_TO_BOTTOM ? "Top to Bottom" : "Bottom to Top");
    PrintToConsole(client, "l4d2_scripted_hud_hud1_x_min : %.4f", g_fCvar_HUD1_X_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_y_min : %.4f", g_fCvar_HUD1_Y_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_x_max : %.4f", g_fCvar_HUD1_X_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_y_max : %.4f", g_fCvar_HUD1_Y_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_width : %.4f", g_fCvar_HUD1_Width);
    PrintToConsole(client, "l4d2_scripted_hud_hud1_height : %.4f", g_fCvar_HUD1_Height);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_text : \"%s\"", g_sCvar_HUD2_Text);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_text_align : %i (%s)", g_iCvar_HUD2_TextAlign, g_iCvar_HUD2_TextAlign == HUD_TEXT_ALIGN_LEFT ? "LEFT" : g_iCvar_HUD2_TextAlign == HUD_TEXT_ALIGN_CENTER ? "CENTER" : "RIGHT");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_blink_tank : %b (%s)", g_bCvar_HUD2_BlinkTank, g_bCvar_HUD2_BlinkTank ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_blink : %b (%s)", g_bCvar_HUD2_Blink, g_bCvar_HUD2_Blink ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_beep : %b (%s)", g_bCvar_HUD2_Beep, g_bCvar_HUD2_Beep ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_visible : %b (%s)", g_bCvar_HUD2_Visible, g_bCvar_HUD2_Visible ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_background : %i (%s)", g_bCvar_HUD2_Background, g_bCvar_HUD2_Background ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_team : %i (%s)", g_iCvar_HUD2_Team, g_iCvar_HUD2_Team == HUD_TEAM_ALL ? "ALL" : g_iCvar_HUD2_Team == HUD_TEAM_SURVIVOR ? "SURVIVOR" : "INFECTED");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_flag_debug : %i (%s)", g_iCvar_HUD2_Flag_Debug, g_bCvar_HUD2_Flag_Debug ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_x : %.4f", g_fCvar_HUD2_X);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_y : %.4f", g_fCvar_HUD2_Y);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_x_speed : %.4f", g_fCvar_HUD2_X_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_y_speed : %.4f", g_fCvar_HUD2_Y_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_x_direction : %i (%s)", g_iCvar_HUD2_X_Direction, g_iCvar_HUD2_X_Direction == HUD_X_LEFT_TO_RIGHT ? "Left to Right" : "Right to Left");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_y_direction : %i (%s)", g_iCvar_HUD2_Y_Direction, g_iCvar_HUD2_Y_Direction == HUD_Y_TOP_TO_BOTTOM ? "Top to Bottom" : "Bottom to Top");
    PrintToConsole(client, "l4d2_scripted_hud_hud2_x_min : %.4f", g_fCvar_HUD2_X_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_y_min : %.4f", g_fCvar_HUD2_Y_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_x_max : %.4f", g_fCvar_HUD2_X_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_y_max : %.4f", g_fCvar_HUD2_Y_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_width : %.4f", g_fCvar_HUD2_Width);
    PrintToConsole(client, "l4d2_scripted_hud_hud2_height : %.4f", g_fCvar_HUD2_Height);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_text : \"%s\"", g_sCvar_HUD3_Text);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_text_align : %i (%s)", g_iCvar_HUD3_TextAlign, g_iCvar_HUD3_TextAlign == HUD_TEXT_ALIGN_LEFT ? "LEFT" : g_iCvar_HUD3_TextAlign == HUD_TEXT_ALIGN_CENTER ? "CENTER" : "RIGHT");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_blink_tank : %b (%s)", g_bCvar_HUD3_BlinkTank, g_bCvar_HUD3_BlinkTank ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_blink : %b (%s)", g_bCvar_HUD3_Blink, g_bCvar_HUD3_Blink ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_beep : %b (%s)", g_bCvar_HUD3_Beep, g_bCvar_HUD3_Beep ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_visible : %b (%s)", g_bCvar_HUD3_Visible, g_bCvar_HUD3_Visible ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_background : %i (%s)", g_bCvar_HUD3_Background, g_bCvar_HUD3_Background ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_team : %i (%s)", g_iCvar_HUD3_Team, g_iCvar_HUD3_Team == HUD_TEAM_ALL ? "ALL" : g_iCvar_HUD3_Team == HUD_TEAM_SURVIVOR ? "SURVIVOR" : "INFECTED");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_flag_debug : %i (%s)", g_iCvar_HUD3_Flag_Debug, g_bCvar_HUD3_Flag_Debug ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_x : %.4f", g_fCvar_HUD3_X);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_y : %.4f", g_fCvar_HUD3_Y);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_x_speed : %.4f", g_fCvar_HUD3_X_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_y_speed : %.4f", g_fCvar_HUD3_Y_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_x_direction : %i (%s)", g_iCvar_HUD3_X_Direction, g_iCvar_HUD3_X_Direction == HUD_X_LEFT_TO_RIGHT ? "Left to Right" : "Right to Left");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_y_direction : %i (%s)", g_iCvar_HUD3_Y_Direction, g_iCvar_HUD3_Y_Direction == HUD_Y_TOP_TO_BOTTOM ? "Top to Bottom" : "Bottom to Top");
    PrintToConsole(client, "l4d2_scripted_hud_hud3_x_min : %.4f", g_fCvar_HUD3_X_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_y_min : %.4f", g_fCvar_HUD3_Y_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_x_max : %.4f", g_fCvar_HUD3_X_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_y_max : %.4f", g_fCvar_HUD3_Y_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_width : %.4f", g_fCvar_HUD3_Width);
    PrintToConsole(client, "l4d2_scripted_hud_hud3_height : %.4f", g_fCvar_HUD3_Height);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_text : \"%s\"", g_sCvar_HUD4_Text);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_text_align : %i (%s)", g_iCvar_HUD4_TextAlign, g_iCvar_HUD4_TextAlign == HUD_TEXT_ALIGN_LEFT ? "LEFT" : g_iCvar_HUD4_TextAlign == HUD_TEXT_ALIGN_CENTER ? "CENTER" : "RIGHT");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_blink_tank : %b (%s)", g_bCvar_HUD4_BlinkTank, g_bCvar_HUD4_BlinkTank ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_blink : %b (%s)", g_bCvar_HUD4_Blink, g_bCvar_HUD4_Blink ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_beep : %b (%s)", g_bCvar_HUD4_Beep, g_bCvar_HUD4_Beep ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_visible : %b (%s)", g_bCvar_HUD4_Visible, g_bCvar_HUD4_Visible ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_background : %i (%s)", g_bCvar_HUD4_Background, g_bCvar_HUD4_Background ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_team : %i (%s)", g_iCvar_HUD4_Team, g_iCvar_HUD4_Team == HUD_TEAM_ALL ? "ALL" : g_iCvar_HUD4_Team == HUD_TEAM_SURVIVOR ? "SURVIVOR" : "INFECTED");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_flag_debug : %i (%s)", g_iCvar_HUD4_Flag_Debug, g_bCvar_HUD4_Flag_Debug ? "true" : "false");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_x : %.4f", g_fCvar_HUD4_X);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_y : %.4f", g_fCvar_HUD4_Y);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_x_speed : %.4f", g_fCvar_HUD4_X_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_y_speed : %.4f", g_fCvar_HUD4_Y_Speed);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_x_direction : %i (%s)", g_iCvar_HUD4_X_Direction, g_iCvar_HUD4_X_Direction == HUD_X_LEFT_TO_RIGHT ? "Left to Right" : "Right to Left");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_y_direction : %i (%s)", g_iCvar_HUD4_Y_Direction, g_iCvar_HUD4_Y_Direction == HUD_Y_TOP_TO_BOTTOM ? "Top to Bottom" : "Bottom to Top");
    PrintToConsole(client, "l4d2_scripted_hud_hud4_x_min : %.4f", g_fCvar_HUD4_X_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_y_min : %.4f", g_fCvar_HUD4_Y_Min);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_x_max : %.4f", g_fCvar_HUD4_X_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_y_max : %.4f", g_fCvar_HUD4_Y_Max);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_width : %.4f", g_fCvar_HUD4_Width);
    PrintToConsole(client, "l4d2_scripted_hud_hud4_height : %.4f", g_fCvar_HUD4_Height);
    PrintToConsole(client, "");
    PrintToConsole(client, "-------------------------- HUD Texts (data)---------------------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "HUD1 : \"%s\"", g_sData_HUD1_Text);
    PrintToConsole(client, "HUD2 : \"%s\"", g_sData_HUD2_Text);
    PrintToConsole(client, "HUD3 : \"%s\"", g_sData_HUD3_Text);
    PrintToConsole(client, "HUD4 : \"%s\"", g_sData_HUD4_Text);
    PrintToConsole(client, "");
    PrintToConsole(client, "----------------------------------------------------------------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "HUD 1 Flags : %i", g_iHUD1Flags);
    PrintToConsole(client, "HUD 2 Flags : %i", g_iHUD2Flags);
    PrintToConsole(client, "HUD 3 Flags : %i", g_iHUD3Flags);
    PrintToConsole(client, "HUD 4 Flags : %i", g_iHUD4Flags);
    PrintToConsole(client, "");
    PrintToConsole(client, "======================================================================");
    PrintToConsole(client, "");

    return Plugin_Handled;
}

// ====================================================================================================
// Helpers
// ====================================================================================================
/**
 * Validates if is a valid client index.
 *
 * @param client        Client index.
 * @return              True if client index is valid, false otherwise.
 */
bool IsValidClientIndex(int client)
{
    return (1 <= client <= MaxClients);
}

/****************************************************************************************************/

/**
 * Validates if is a valid client.
 *
 * @param client        Client index.
 * @return              True if client index is valid and client is in game, false otherwise.
 */
bool IsValidClient(int client)
{
    return (IsValidClientIndex(client) && IsClientInGame(client));
}

/****************************************************************************************************/

/**
 * Gets the client L4D1/L4D2 zombie class id.
 *
 * @param client     Client index.
 * @return L4D1      1=SMOKER, 2=BOOMER, 3=HUNTER, 4=WITCH, 5=TANK, 6=NOT INFECTED
 * @return L4D2      1=SMOKER, 2=BOOMER, 3=HUNTER, 4=SPITTER, 5=JOCKEY, 6=CHARGER, 7=WITCH, 8=TANK, 9=NOT INFECTED
 */
int GetZombieClass(int client)
{
    return (GetEntProp(client, Prop_Send, "m_zombieClass"));
}

/****************************************************************************************************/

/**
 * Returns if the client is in ghost state.
 *
 * @param client        Client index.
 * @return              True if client is in ghost state, false otherwise.
 */
bool IsPlayerGhost(int client)
{
    return (GetEntProp(client, Prop_Send, "m_isGhost") == 1);
}

/****************************************************************************************************/

/**
 * Validates if the client is incapacitated.
 *
 * @param client        Client index.
 * @return              True if the client is incapacitated, false otherwise.
 */
bool IsPlayerIncapacitated(int client)
{
    return (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 1);
}

/****************************************************************************************************/

/**
 * Returns if the client is a valid tank.
 *
 * @param client        Client index.
 * @return              True if client is a tank, false otherwise.
 */
bool IsPlayerTank(int client)
{
    if (GetClientTeam(client) != TEAM_INFECTED)
        return false;

    if (GetZombieClass(client) != L4D2_ZOMBIECLASS_TANK)
        return false;

    if (!IsPlayerAlive(client))
        return false;

    if (IsPlayerGhost(client))
        return false;

    return true;
}

/****************************************************************************************************/

/**
 * Returns if any tank is alive.
 *
 * @return              True if any tank is alive, false otherwise.
 */
bool HasAnyTankAlive()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        if (!IsPlayerTank(client))
            continue;

        if (IsPlayerIncapacitated(client))
            continue;

        return true;
    }

    return false;
}

/****************************************************************************************************/

/**
 * Counts the number of occurences of a character in a string.
 *
 * @param str           String.
 * @param c             Character to count.
 * @return              The number of occurences of the character in the string.
 */
int CountCharInString(const char[] str, char c)
{
    int i;
    int count;

    while (str[i] != 0)
    {
        if (str[i++] == c)
            count++;
    }

    return count;
}

/****************************************************************************************************/

// ====================================================================================================
// Thanks to Silvers
// ====================================================================================================
/**
 * Returns the client temporary health.
 *
 * @param client        Client index.
 * @return              Client temporary health.
 */
int GetClientTempHealth(int client)
{
    int tempHealth = RoundToCeil(GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * g_fCvar_pain_pills_decay_rate));
    return tempHealth < 0 ? 0 : tempHealth;
}
