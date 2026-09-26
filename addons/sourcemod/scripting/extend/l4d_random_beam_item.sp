/**
// ====================================================================================================
Change Log:

1.1.0 (25-September-2026) [Anne]
    - The data file now defines a "standard" beam that every item inherits, and groups the items for the player menu.
    - Added per-player beam settings through the SendProxy extension: players open !beam to change the length and width
      (as a percentage of the standard), color, halo and visibility, for all items or for each item group.
    - Players can show beams on items that are hidden by default; those beams are only created while someone asks for them.
    - Player settings are saved in MySQL (databases.cfg "rpg").

1.0.3 (29-May-2022)
    - Improved performance.
    - Fixed logic running twice on plugin load.
    - Fixed glow color not being applied.
    - Fixed some beams not being removed. (thanks "AsphyxiaJLSA" and "VladimirTk" for reporting and testing)
    - Removed targetname support.

1.0.2 (04-October-2021)
    - Fixed carryable items not restoring beam on drop after being picked up.

1.0.1 (12-September-2021)
    - Added new commands to manually add/remove beam.
    - Added support to model-based config in the data file.
    - Halo changed to disabled by default.

1.0.0 (29-August-2021)
    - Initial release.

// ====================================================================================================
*/

// ====================================================================================================
// Plugin Info - define
// ====================================================================================================
#define PLUGIN_NAME                   "[L4D1 & L4D2] Random Beam Item"
#define PLUGIN_AUTHOR                 "Mart"
#define PLUGIN_DESCRIPTION            "Gives a random beam to items on the map"
#define PLUGIN_VERSION                "1.1.0"
#define PLUGIN_URL                    "https://forums.alliedmods.net/showthread.php?t=334110"

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
#include <anne_db>
#undef REQUIRE_EXTENSIONS
#include <sendproxy>
#define REQUIRE_EXTENSIONS

// ====================================================================================================
// Pragmas
// ====================================================================================================
#pragma semicolon 1
#pragma newdecls required
#pragma dynamic 32768

// ====================================================================================================
// Cvar Flags
// ====================================================================================================
#define CVAR_FLAGS                    FCVAR_NONE
#define CVAR_FLAGS_PLUGIN_VERSION     FCVAR_NONE|FCVAR_DONTRECORD|FCVAR_SPONLY

// ====================================================================================================
// Filenames
// ====================================================================================================
#define CONFIG_FILENAME               "l4d_random_beam_item"
#define DATA_FILENAME                 "l4d_random_beam_item"

// ====================================================================================================
// Database
// ====================================================================================================
#define DB_CONFIG                     "rpg"
#define DB_TABLE                      "beam_item_prefs"

// ====================================================================================================
// Defines
// ====================================================================================================
#define MODEL_HALO_SPRITE_DEFAULT     "sprites/light_glow03.vmt"
#define MODEL_BEAM_SPRITE_DEFAULT     "sprites/glow_test02.vmt"
#define MODEL_HALO_SPRITE_PLUGIN      "sprites/light_glow02_add_noz.vmt"

#define MODEL_MELEE_FIREAXE           "models/weapons/melee/w_fireaxe.mdl"
#define MODEL_MELEE_FRYING_PAN        "models/weapons/melee/w_frying_pan.mdl"
#define MODEL_MELEE_MACHETE           "models/weapons/melee/w_machete.mdl"
#define MODEL_MELEE_BASEBALL_BAT      "models/weapons/melee/w_bat.mdl"
#define MODEL_MELEE_CROWBAR           "models/weapons/melee/w_crowbar.mdl"
#define MODEL_MELEE_CRICKET_BAT       "models/weapons/melee/w_cricket_bat.mdl"
#define MODEL_MELEE_TONFA             "models/weapons/melee/w_tonfa.mdl"
#define MODEL_MELEE_KATANA            "models/weapons/melee/w_katana.mdl"
#define MODEL_MELEE_ELECTRIC_GUITAR   "models/weapons/melee/w_electric_guitar.mdl"
#define MODEL_MELEE_KNIFE             "models/w_models/weapons/w_knife_t.mdl"
#define MODEL_MELEE_GOLFCLUB          "models/weapons/melee/w_golfclub.mdl"
#define MODEL_MELEE_PITCHFORK         "models/weapons/melee/w_pitchfork.mdl"
#define MODEL_MELEE_SHOVEL            "models/weapons/melee/w_shovel.mdl"
#define MODEL_MELEE_RIOTSHIELD        "models/weapons/melee/w_riotshield.mdl"

#define MODEL_GNOME                   "models/props_junk/gnome.mdl"
#define MODEL_COLA                    "models/w_models/weapons/w_cola.mdl"

#define MODEL_GASCAN                  "models/props_junk/gascan001a.mdl"
#define MODEL_PROPANECANISTER         "models/props_junk/propanecanister001a.mdl"
#define MODEL_OXYGENTANK              "models/props_equipment/oxygentank01.mdl"
#define MODEL_FIREWORKS_CRATE         "models/props_junk/explosive_box001.mdl"

#define L4D2_WEPID_PISTOL                     "1"
#define L4D2_WEPID_SMG                        "2"
#define L4D2_WEPID_PUMPSHOTGUN                "3"
#define L4D2_WEPID_AUTOSHOTGUN                "4"
#define L4D2_WEPID_RIFLE                      "5"
#define L4D2_WEPID_HUNTING_RIFLE              "6"
#define L4D2_WEPID_SMG_SILENCED               "7"
#define L4D2_WEPID_SHOTGUN_CHROME             "8"
#define L4D2_WEPID_RIFLE_DESERT               "9"
#define L4D2_WEPID_SNIPER_MILITARY            "10"
#define L4D2_WEPID_SHOTGUN_SPAS               "11"
#define L4D2_WEPID_FIRST_AID_KIT              "12"
#define L4D2_WEPID_MOLOTOV                    "13"
#define L4D2_WEPID_PIPE_BOMB                  "14"
#define L4D2_WEPID_PAIN_PILLS                 "15"
#define L4D2_WEPID_GASCAN                     "16"
#define L4D2_WEPID_PROPANETANK                "17"
#define L4D2_WEPID_OXYGENTANK                 "18"
#define L4D2_WEPID_CHAINSAW                   "20"
#define L4D2_WEPID_GRENADE_LAUNCHER           "21"
#define L4D2_WEPID_ADRENALINE                 "23"
#define L4D2_WEPID_DEFIBRILLATOR              "24"
#define L4D2_WEPID_VOMITJAR                   "25"
#define L4D2_WEPID_RIFLE_AK47                 "26"
#define L4D2_WEPID_GNOME                      "27"
#define L4D2_WEPID_COLA_BOTTLES               "28"
#define L4D2_WEPID_FIREWORKCRATE              "29"
#define L4D2_WEPID_UPGRADEPACK_INCENDIARY     "30"
#define L4D2_WEPID_UPGRADEPACK_EXPLOSIVE      "31"
#define L4D2_WEPID_PISTOL_MAGNUM              "32"
#define L4D2_WEPID_SMG_MP5                    "33"
#define L4D2_WEPID_RIFLE_SG552                "34"
#define L4D2_WEPID_SNIPER_AWP                 "35"
#define L4D2_WEPID_SNIPER_SCOUT               "36"
#define L4D2_WEPID_RIFLE_M60                  "37"

#define CONFIG_ENABLE                 0
#define CONFIG_RANDOM                 1
#define CONFIG_R                      2
#define CONFIG_G                      3
#define CONFIG_B                      4
#define CONFIG_LENGTH                 5
#define CONFIG_WIDTH                  6
#define CONFIG_HDR                    7
#define CONFIG_HALO                   8
#define CONFIG_GROUP                  9
#define CONFIG_PLAYER                 10
#define CONFIG_ARRAYSIZE              11

#define MAXENTITIES                   2048

#define MAX_BEAM_WIDTH                102.3

// Item groups shown in the player menu. Beams without a group (e.g. sm_beamadd) only follow the "all items" settings,
// which are stored in the extra slot after the groups.
#define MAX_GROUPS                    32
#define GROUP_NONE                    MAX_GROUPS
#define SCOPE_GLOBAL                  MAX_GROUPS

#define PREF_VISIBLE                  0
#define PREF_LENGTH                   1
#define PREF_WIDTH                    2
#define PREF_COLOR                    3
#define PREF_HALO                     4
#define PREF_COUNT                    5
#define PREF_FOLLOW                   -1

#define PREFS_MAX_LENGTH              2048

#define PRESET_BRIGHT                 0
#define PRESET_SUBTLE                 1
#define PRESET_COUNT                  2

#define PREFS_NONE                    0
#define PREFS_LOADING                 1
#define PREFS_READY                   2
#define PREFS_FAILED                  3

// Halo, HDR scale and color are only read when the client creates the beam, so a settings change
// hides the beams from that client for this long to make the client rebuild them.
#define REFRESH_DELAY                 0.3
#define SAVE_DELAY                    3.0

// ====================================================================================================
// Plugin Cvars
// ====================================================================================================
ConVar g_hCvar_Enabled;
ConVar g_hCvar_RemoveSpawner;
ConVar g_hCvar_MinBrightness;
ConVar g_hCvar_UseGlowColor;
ConVar g_hCvar_PlayerEdictLimit;

// ====================================================================================================
// bool - Plugin Variables
// ====================================================================================================
bool g_bL4D2;
bool g_bEventsHooked;
bool g_bCvar_Enabled;
bool g_bCvar_RemoveSpawner;
bool g_bCvar_UseGlowColor;
bool g_bSendProxy;
bool g_bDatabaseReady;
bool g_bGroupSelectable[MAX_GROUPS];

// ====================================================================================================
// int - Plugin Variables
// ====================================================================================================
int g_iHalo = -1;
int g_iDefaultConfig[CONFIG_ARRAYSIZE];
int g_iCvar_PlayerEdictLimit;
int g_iGroupCount;
int g_iGroupDemand[MAX_GROUPS];
int g_iPresetLength[PRESET_COUNT];
int g_iPresetWidth[PRESET_COUNT];
int g_iPresetHalo[PRESET_COUNT];

// Length and width choices, in percent of the item's standard beam
int g_iScaleLevels[] = { 50, 75, 100, 150, 200, 300 };
int g_iPaletteColor[] = { 0xFFFFFF, 0xFF0000, 0xFF8000, 0xFFFF00, 0x00FF00, 0x00FFFF, 0x0080FF, 0x9B30FF, 0xFF40C0 };

// ====================================================================================================
// float - Plugin Variables
// ====================================================================================================
float g_vAngles[3] = { 270.0 , 0.0 , 0.0 };
float g_fExtraPosZ = 0.25;
float g_fCvar_MinBrightness;

// ====================================================================================================
// string - Plugin Variables
// ====================================================================================================
char g_sGroupKey[MAX_GROUPS][32];
char g_sPalettePhrase[][] = { "L4DRandomBeamItem_ColorWhite", "L4DRandomBeamItem_ColorRed", "L4DRandomBeamItem_ColorOrange", "L4DRandomBeamItem_ColorYellow", "L4DRandomBeamItem_ColorGreen", "L4DRandomBeamItem_ColorCyan", "L4DRandomBeamItem_ColorBlue", "L4DRandomBeamItem_ColorPurple", "L4DRandomBeamItem_ColorPink" };
char g_sFieldPhrase[PREF_COUNT][] = { "L4DRandomBeamItem_FieldVisible", "L4DRandomBeamItem_FieldLength", "L4DRandomBeamItem_FieldWidth", "L4DRandomBeamItem_FieldColor", "L4DRandomBeamItem_FieldHalo" };

// ====================================================================================================
// Database - Plugin Variables
// ====================================================================================================
Database g_hDatabase;

// ====================================================================================================
// client - Plugin Variables
// ====================================================================================================
bool gc_bWeaponEquipPostHooked[MAXPLAYERS+1];
bool gc_bBeamRefresh[MAXPLAYERS+1];
bool gc_bPrefsDirty[MAXPLAYERS+1];
bool gc_bNotSavedWarned[MAXPLAYERS+1];
int gc_iPrefsState[MAXPLAYERS+1];
int gc_iMenuScope[MAXPLAYERS+1];
int gc_iMenuField[MAXPLAYERS+1];
int gc_iGroupMenuPosition[MAXPLAYERS+1];
// Player settings per scope (item groups, then "all items"); PREF_FOLLOW = not set
int gc_iPref[MAXPLAYERS+1][MAX_GROUPS+1][PREF_COUNT];
// Settings in effect per group: the group's own setting, or else the "all items" setting
int gc_iResolved[MAXPLAYERS+1][MAX_GROUPS+1][PREF_COUNT];
char gc_sAuthId[MAXPLAYERS+1][32];
Handle gc_hRefreshTimer[MAXPLAYERS+1];
Handle gc_hSaveTimer[MAXPLAYERS+1];

// ====================================================================================================
// entity - Plugin Variables
// ====================================================================================================
bool ge_bUsePostHooked[MAXENTITIES+1];
bool ge_bVPhysicsUpdatePostHooked[MAXENTITIES+1];
bool ge_bTurnOn[MAXENTITIES+1];
bool ge_bBeamDefault[MAXENTITIES+1];
int ge_iBeamGroup[MAXENTITIES+1] = { GROUP_NONE, ... };
int ge_iParentEntRef[MAXENTITIES+1] = { INVALID_ENT_REFERENCE, ... };
int ge_iChildEntRef[MAXENTITIES+1] = { INVALID_ENT_REFERENCE, ... };

// ====================================================================================================
// ArrayList - Plugin Variables
// ====================================================================================================
ArrayList g_alPluginEntities;

// ====================================================================================================
// StringMap - Plugin Variables
// ====================================================================================================
StringMap g_smWeaponIdToClassname;
StringMap g_smMeleeModelToName;
StringMap g_smPropModelToClassname;
StringMap g_smClassnameConfig;
StringMap g_smMeleeConfig;
StringMap g_smModelConfig;

// ====================================================================================================
// Plugin Start
// ====================================================================================================
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    EngineVersion engine = GetEngineVersion();

    if (engine != Engine_Left4Dead && engine != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "This plugin only runs in \"Left 4 Dead\" and \"Left 4 Dead 2\" game");
        return APLRes_SilentFailure;
    }

    g_bL4D2 = (engine == Engine_Left4Dead2);

    RegPluginLibrary("l4d_random_beam_item"); // rpg.smx shows the !beam entry when this is loaded

    return APLRes_Success;
}

/****************************************************************************************************/

public void OnPluginStart()
{
	LoadTranslations("l4d_random_beam_item.phrases");
    g_alPluginEntities = new ArrayList();
    g_smWeaponIdToClassname = new StringMap();
    g_smMeleeModelToName = new StringMap();
    g_smPropModelToClassname = new StringMap();
    g_smClassnameConfig = new StringMap();
    g_smMeleeConfig = new StringMap();
    g_smModelConfig = new StringMap();

    for (int client = 0; client <= MAXPLAYERS; client++)
        ResetClientPrefs(client);

    BuildMaps();

    LoadConfigs();

    CreateConVar("l4d_random_beam_item_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, CVAR_FLAGS_PLUGIN_VERSION);
    g_hCvar_Enabled          = CreateConVar("l4d_random_beam_item_enable", "1", "Enable/Disable the plugin.\n0 = Disable, 1 = Enable.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_RemoveSpawner    = CreateConVar("l4d_random_beam_item_remove_spawner", "1", "Delete *_spawn entities when its count reaches 0.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_MinBrightness    = CreateConVar("l4d_random_beam_item_min_brightness", "0.5", "Algorithm value to detect the beam minimum brightness for a random color (not accurate).", CVAR_FLAGS, true, 0.0, true, 1.0);
    if (g_bL4D2)
        g_hCvar_UseGlowColor = CreateConVar("l4d_random_beam_item_use_glow_color", "1", "(L4D2 only) Apply the same color from glow.\n0 = OFF, 1 = ON.", CVAR_FLAGS, true, 0.0, true, 1.0);
    g_hCvar_PlayerEdictLimit = CreateConVar("l4d_random_beam_item_player_edict_limit", "1900", "Beams that players turn on for items hidden by default are not created once the server uses this many edicts.\n0 = Players can't turn on beams for hidden items.", CVAR_FLAGS, true, 0.0, true, 2048.0);

    // Hook plugin ConVars change
    g_hCvar_Enabled.AddChangeHook(Event_ConVarChanged);
    g_hCvar_RemoveSpawner.AddChangeHook(Event_ConVarChanged);
    g_hCvar_MinBrightness.AddChangeHook(Event_ConVarChanged);
    if (g_bL4D2)
        g_hCvar_UseGlowColor.AddChangeHook(Event_ConVarChanged);
    g_hCvar_PlayerEdictLimit.AddChangeHook(Event_ConVarChanged);

    // Load plugin configs from .cfg
    AutoExecConfig(true, CONFIG_FILENAME);

    // Admin Commands
    RegAdminCmd("sm_beaminfo", CmdInfo, ADMFLAG_ROOT, "Outputs to the chat the beam info about the entity at your crosshair.");
    RegAdminCmd("sm_beamreload", CmdReload, ADMFLAG_ROOT, "Reload the beam configs.");
    RegAdminCmd("sm_beamremove", CmdRemove, ADMFLAG_ROOT, "Remove plugin beam from entity at crosshair.");
    RegAdminCmd("sm_beamremoveall", CmdRemoveAll, ADMFLAG_ROOT, "Remove all beams created by the plugin.");
    RegAdminCmd("sm_beamadd", CmdAdd, ADMFLAG_ROOT, "Add a beam (with default config) to entity at crosshair.");
    RegAdminCmd("sm_print_cvars_l4d_random_beam_item", CmdPrintCvars, ADMFLAG_ROOT, "Print the plugin related cvars and their respective values to the console.");

    // Public Commands
    RegConsoleCmd("sm_beam", CmdBeam, "Item beam settings. Usage: sm_beam [bright|subtle|off|default|reset]");
}

/****************************************************************************************************/

public void OnAllPluginsLoaded()
{
    g_bSendProxy = LibraryExists(SENDPROXY_LIB);
    HookAllBeamSendProxies();

    // 等 anne_db 连接中心加载完再连库，开服自动加载时顺序不固定。
    if (g_hDatabase == null)
        ConnectDatabase();
}

/****************************************************************************************************/

public void OnLibraryAdded(const char[] name)
{
    if (!StrEqual(name, SENDPROXY_LIB))
        return;

    g_bSendProxy = true;
    HookAllBeamSendProxies();
    CreateDemandedBeams(0);
}

/****************************************************************************************************/

public void OnLibraryRemoved(const char[] name)
{
    if (!StrEqual(name, SENDPROXY_LIB))
        return;

    // Nobody can hide the beams that were turned on for single players anymore
    g_bSendProxy = false;
    RemoveUndemandedBeams();
}

/****************************************************************************************************/

void BuildMaps()
{
    if (g_bL4D2)
    {
        g_smWeaponIdToClassname.Clear();
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PISTOL, "weapon_pistol");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SMG, "weapon_smg");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PUMPSHOTGUN, "weapon_pumpshotgun");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_AUTOSHOTGUN, "weapon_autoshotgun");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_RIFLE, "weapon_rifle");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_HUNTING_RIFLE, "weapon_hunting_rifle");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SMG_SILENCED, "weapon_smg_silenced");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SHOTGUN_CHROME, "weapon_shotgun_chrome");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_RIFLE_DESERT, "weapon_rifle_desert");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SNIPER_MILITARY, "weapon_sniper_military");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SHOTGUN_SPAS, "weapon_shotgun_spas");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_FIRST_AID_KIT, "weapon_first_aid_kit");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_MOLOTOV, "weapon_molotov");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PIPE_BOMB, "weapon_pipe_bomb");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PAIN_PILLS, "weapon_pain_pills");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_GASCAN, "weapon_gascan");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PROPANETANK, "weapon_propanetank");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_OXYGENTANK, "weapon_oxygentank");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_CHAINSAW, "weapon_chainsaw");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_GRENADE_LAUNCHER, "weapon_grenade_launcher");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_ADRENALINE, "weapon_adrenaline");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_DEFIBRILLATOR, "weapon_defibrillator");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_VOMITJAR, "weapon_vomitjar");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_RIFLE_AK47, "weapon_rifle_ak47");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_GNOME, "weapon_gnome");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_COLA_BOTTLES, "weapon_cola_bottles");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_FIREWORKCRATE, "weapon_fireworkcrate");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_UPGRADEPACK_INCENDIARY, "weapon_upgradepack_incendiary");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_UPGRADEPACK_EXPLOSIVE, "weapon_upgradepack_explosive");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_PISTOL_MAGNUM, "weapon_pistol_magnum");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SMG_MP5, "weapon_smg_mp5");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_RIFLE_SG552, "weapon_rifle_sg552");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SNIPER_AWP, "weapon_sniper_awp");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_SNIPER_SCOUT, "weapon_sniper_scout");
        g_smWeaponIdToClassname.SetString(L4D2_WEPID_RIFLE_M60, "weapon_rifle_m60");

        g_smMeleeModelToName.Clear();
        g_smMeleeModelToName.SetString(MODEL_MELEE_FIREAXE, "fireaxe");
        g_smMeleeModelToName.SetString(MODEL_MELEE_FRYING_PAN, "frying_pan");
        g_smMeleeModelToName.SetString(MODEL_MELEE_MACHETE, "machete");
        g_smMeleeModelToName.SetString(MODEL_MELEE_BASEBALL_BAT, "baseball_bat");
        g_smMeleeModelToName.SetString(MODEL_MELEE_CROWBAR, "crowbar");
        g_smMeleeModelToName.SetString(MODEL_MELEE_CRICKET_BAT, "cricket_bat");
        g_smMeleeModelToName.SetString(MODEL_MELEE_TONFA, "tonfa");
        g_smMeleeModelToName.SetString(MODEL_MELEE_KATANA, "katana");
        g_smMeleeModelToName.SetString(MODEL_MELEE_ELECTRIC_GUITAR, "electric_guitar");
        g_smMeleeModelToName.SetString(MODEL_MELEE_KNIFE, "knife");
        g_smMeleeModelToName.SetString(MODEL_MELEE_GOLFCLUB, "golfclub");
        g_smMeleeModelToName.SetString(MODEL_MELEE_PITCHFORK, "pitchfork");
        g_smMeleeModelToName.SetString(MODEL_MELEE_SHOVEL, "shovel");
        g_smMeleeModelToName.SetString(MODEL_MELEE_RIOTSHIELD, "riotshield");

        g_smPropModelToClassname.Clear();
        g_smPropModelToClassname.SetString(MODEL_GNOME, "weapon_gnome");
        g_smPropModelToClassname.SetString(MODEL_COLA, "weapon_cola_bottles");
        g_smPropModelToClassname.SetString(MODEL_GASCAN, "weapon_gascan");
        g_smPropModelToClassname.SetString(MODEL_PROPANECANISTER, "weapon_propanetank");
        g_smPropModelToClassname.SetString(MODEL_OXYGENTANK, "weapon_oxygentank");
        g_smPropModelToClassname.SetString(MODEL_FIREWORKS_CRATE, "weapon_fireworkcrate");
    }
    else
    {
        g_smPropModelToClassname.Clear();
        g_smPropModelToClassname.SetString(MODEL_GASCAN, "weapon_gascan");
        g_smPropModelToClassname.SetString(MODEL_PROPANECANISTER, "weapon_propanetank");
        g_smPropModelToClassname.SetString(MODEL_OXYGENTANK, "weapon_oxygentank");
    }
}

/****************************************************************************************************/

public void OnMapStart()
{
    g_iHalo = PrecacheModel(MODEL_HALO_SPRITE_PLUGIN, true);
    PrecacheModel(MODEL_HALO_SPRITE_DEFAULT, true); // Will late precache anyway
    PrecacheModel(MODEL_BEAM_SPRITE_DEFAULT, true); // Will late precache anyway
}

/****************************************************************************************************/

public void OnConfigsExecuted()
{
    GetCvars();

    HookEvents();

    LateLoad();
}

/****************************************************************************************************/

void Event_ConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    GetCvars();

    HookEvents();

    RemoveAll();

    LateLoad();
}

/****************************************************************************************************/

void GetCvars()
{
    g_bCvar_Enabled = g_hCvar_Enabled.BoolValue;
    g_bCvar_RemoveSpawner = g_hCvar_RemoveSpawner.BoolValue;
    g_fCvar_MinBrightness = g_hCvar_MinBrightness.FloatValue;
    if (g_bL4D2)
        g_bCvar_UseGlowColor = g_hCvar_UseGlowColor.BoolValue;
    g_iCvar_PlayerEdictLimit = g_hCvar_PlayerEdictLimit.IntValue;
}

/****************************************************************************************************/

void LoadConfigs()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "data/%s.cfg", DATA_FILENAME);

    if (!FileExists(path))
    {
        SetFailState("Missing required data file on \"data/%s.cfg\", please re-download.", DATA_FILENAME);
        return;
    }

    KeyValues kv = new KeyValues(DATA_FILENAME);
    kv.ImportFromFile(path);

    g_smClassnameConfig.Clear();
    g_smMeleeConfig.Clear();
    g_smModelConfig.Clear();

    LoadGroups(kv);

    // The standard beam: every item inherits the values it doesn't set itself
    int fallback[CONFIG_ARRAYSIZE] = { 0, 0, 255, 255, 255, 0, 0, 0, 0, GROUP_NONE, 1 };
    CopyConfig(fallback, g_iDefaultConfig);
    if (kv.JumpToKey("standard") || kv.JumpToKey("default"))
        ReadItemConfig(kv, fallback, g_iDefaultConfig, "");

    LoadItemSection(kv, "classnames", g_smClassnameConfig, "other");
    LoadItemSection(kv, "melees", g_smMeleeConfig, "melee");
    LoadItemSection(kv, "models", g_smModelConfig, "other");

    LoadPresets(kv);

    delete kv;
}

/****************************************************************************************************/

void LoadGroups(KeyValues kv)
{
    g_iGroupCount = 0;
    for (int group = 0; group < MAX_GROUPS; group++)
        g_bGroupSelectable[group] = false;

    kv.Rewind();

    char order[1024];
    kv.GetString("groups", order, sizeof(order));

    char keys[MAX_GROUPS][32];
    int count = ExplodeString(order, " ", keys, sizeof(keys), sizeof(keys[]));
    for (int i = 0; i < count; i++)
        AddGroup(keys[i]);
}

/****************************************************************************************************/

void LoadItemSection(KeyValues kv, const char[] name, StringMap map, const char[] defaultGroup)
{
    kv.Rewind();

    if (!kv.JumpToKey(name) || !kv.GotoFirstSubKey())
        return;

    char section[PLATFORM_MAX_PATH];
    int config[CONFIG_ARRAYSIZE];

    do
    {
        ReadItemConfig(kv, g_iDefaultConfig, config, defaultGroup);

        // Hidden by default and players can't turn it on either
        if (config[CONFIG_ENABLE] == 0 && config[CONFIG_PLAYER] == 0)
            continue;

        if (config[CONFIG_GROUP] != GROUP_NONE)
            g_bGroupSelectable[config[CONFIG_GROUP]] = true;

        kv.GetSectionName(section, sizeof(section));
        TrimString(section);
        StringToLowerCase(section);

        map.SetArray(section, config, sizeof(config));
    } while (kv.GotoNextKey());
}

/****************************************************************************************************/

void ReadItemConfig(KeyValues kv, const int[] base, int[] config, const char[] defaultGroup)
{
    config[CONFIG_ENABLE] = kv.GetNum("enable", base[CONFIG_ENABLE]);
    config[CONFIG_RANDOM] = kv.GetNum("random", base[CONFIG_RANDOM]);

    char color[16];
    kv.GetString("color", color, sizeof(color));
    if (color[0] == '\0')
    {
        config[CONFIG_R] = base[CONFIG_R];
        config[CONFIG_G] = base[CONFIG_G];
        config[CONFIG_B] = base[CONFIG_B];
    }
    else
    {
        int iColor[3];
        iColor = ConvertRGBToIntArray(color);
        config[CONFIG_R] = iColor[0];
        config[CONFIG_G] = iColor[1];
        config[CONFIG_B] = iColor[2];
    }

    config[CONFIG_LENGTH] = kv.GetNum("length", base[CONFIG_LENGTH]);

    int width = kv.GetNum("width", base[CONFIG_WIDTH]);
    if (width > MAX_BEAM_WIDTH) // prevent clamping warning message
        width = 102;
    config[CONFIG_WIDTH] = width;

    config[CONFIG_HDR] = kv.GetNum("hdr", base[CONFIG_HDR]);
    config[CONFIG_HALO] = kv.GetNum("halo", base[CONFIG_HALO]);
    config[CONFIG_PLAYER] = kv.GetNum("player", base[CONFIG_PLAYER]);

    char group[32];
    kv.GetString("group", group, sizeof(group), defaultGroup);
    config[CONFIG_GROUP] = AddGroup(group);
}

/****************************************************************************************************/

void LoadPresets(KeyValues kv)
{
    SetPreset(PRESET_BRIGHT, 150, 150, 1);
    SetPreset(PRESET_SUBTLE, 50, 75, 0);

    kv.Rewind();

    if (!kv.JumpToKey("styles"))
        return;

    char keys[PRESET_COUNT][] = { "bright", "subtle" };
    for (int preset = 0; preset < PRESET_COUNT; preset++)
    {
        if (!kv.JumpToKey(keys[preset]))
            continue;

        SetPreset(preset, kv.GetNum("length", g_iPresetLength[preset]), kv.GetNum("width", g_iPresetWidth[preset]), kv.GetNum("halo", g_iPresetHalo[preset]));
        kv.GoBack();
    }
}

/****************************************************************************************************/

void SetPreset(int preset, int length, int width, int halo)
{
    g_iPresetLength[preset] = SanitizePref(SCOPE_GLOBAL, PREF_LENGTH, length);
    g_iPresetWidth[preset] = SanitizePref(SCOPE_GLOBAL, PREF_WIDTH, width);
    g_iPresetHalo[preset] = SanitizePref(SCOPE_GLOBAL, PREF_HALO, halo);
}

/****************************************************************************************************/

// Returns the group index of the key, adding it if it's new. Empty or overflowing keys get GROUP_NONE.
int AddGroup(const char[] key)
{
    if (key[0] == '\0')
        return GROUP_NONE;

    int group = FindGroup(key);
    if (group != -1)
        return group;

    if (g_iGroupCount >= MAX_GROUPS)
    {
        LogError("Too many beam item groups (max %i), \"%s\" only follows the \"all items\" settings.", MAX_GROUPS, key);
        return GROUP_NONE;
    }

    strcopy(g_sGroupKey[g_iGroupCount], sizeof(g_sGroupKey[]), key);
    StringToLowerCase(g_sGroupKey[g_iGroupCount]);
    return g_iGroupCount++;
}

/****************************************************************************************************/

int FindGroup(const char[] key)
{
    for (int group = 0; group < g_iGroupCount; group++)
    {
        if (StrEqual(g_sGroupKey[group], key, false))
            return group;
    }

    return -1;
}

/****************************************************************************************************/

void CopyConfig(const int[] source, int[] dest)
{
    for (int i = 0; i < CONFIG_ARRAYSIZE; i++)
        dest[i] = source[i];
}

/****************************************************************************************************/

void HookEvents()
{
    if (g_bCvar_Enabled && !g_bEventsHooked)
    {
        g_bEventsHooked = true;

        if (g_bL4D2)
            HookEvent("weapon_drop", Event_WeaponDrop);

        return;
    }

    if (!g_bCvar_Enabled && g_bEventsHooked)
    {
        g_bEventsHooked = false;

        if (g_bL4D2)
            UnhookEvent("weapon_drop", Event_WeaponDrop);

        return;
    }
}

/****************************************************************************************************/

void LateLoad()
{
    if (g_bL4D2)
    {
        for (int client = 1; client <= MaxClients; client++)
        {
            if (!IsClientInGame(client))
                continue;

            OnClientPutInServer(client);
        }
    }

    int entity;
    char classname[36];

    entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
    {
        if (entity < 0)
            continue;

        GetEntityClassname(entity, classname, sizeof(classname));
        OnEntityCreated(entity, classname);
    }
}

/****************************************************************************************************/

public void OnClientDisconnect(int client)
{
    gc_bWeaponEquipPostHooked[client] = false;

    if (IsFakeClient(client))
        return;

    if (gc_iPrefsState[client] == PREFS_READY)
        SaveClientPrefs(client);

    ResetClientPrefs(client);
    UpdateGroupDemand(0);
}

/****************************************************************************************************/

public void OnClientPutInServer(int client)
{
    if (!g_bL4D2)
        return;

    if (gc_bWeaponEquipPostHooked[client])
        return;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    OnWeaponEquipPost(client, weapon);

    gc_bWeaponEquipPostHooked[client] = true;
    SDKHook(client, SDKHook_WeaponEquipPost, OnWeaponEquipPost);
}

/****************************************************************************************************/

public void OnClientPostAdminCheck(int client)
{
    LoadClientPrefs(client);
}

/****************************************************************************************************/

void OnWeaponEquipPost(int client, int weapon)
{
    if (!g_bCvar_Enabled)
        return;

    if (!IsValidEntity(weapon))
        return;

    if (ge_iChildEntRef[weapon] != INVALID_ENT_REFERENCE)
    {
        int beam = EntRefToEntIndex(ge_iChildEntRef[weapon]);
        if (beam != INVALID_ENT_REFERENCE)
            AcceptEntityInput(beam, "Kill");

        ge_iChildEntRef[weapon] = INVALID_ENT_REFERENCE;
    }

    int find = g_alPluginEntities.FindValue(EntIndexToEntRef(weapon));
    if (find != -1)
        g_alPluginEntities.Erase(find);
}

/****************************************************************************************************/

void Event_WeaponDrop(Event event, const char[] name, bool dontBroadcast)
{
    int entity = event.GetInt("propid");
    char classname[36];
    GetEntityClassname(entity, classname, sizeof(classname));
    OnEntityCreated(entity, classname);
}

/****************************************************************************************************/

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_bCvar_Enabled)
        return;

    if (entity < 0)
        return;

    if (StrEqual(classname, "beam_spotlight")) // prevent loops
        return;

    if (g_bCvar_UseGlowColor && HasEntProp(entity, Prop_Send, "m_glowColorOverride"))
        RequestFrame(OnNextFrameGlow, EntIndexToEntRef(entity));
    else
        RequestFrame(OnNextFrame, EntIndexToEntRef(entity));
}

/****************************************************************************************************/

public void OnEntityDestroyed(int entity)
{
    if (entity < 0)
        return;

    ge_bUsePostHooked[entity] = false;
    ge_bVPhysicsUpdatePostHooked[entity] = false;
    ge_bTurnOn[entity] = false;
    ge_bBeamDefault[entity] = false;
    ge_iBeamGroup[entity] = GROUP_NONE;

    if (ge_iParentEntRef[entity] != INVALID_ENT_REFERENCE)
    {
        int parent = EntRefToEntIndex(ge_iParentEntRef[entity]);
        if (parent != INVALID_ENT_REFERENCE)
            ge_iChildEntRef[parent] = INVALID_ENT_REFERENCE;
    }
    ge_iParentEntRef[entity] = INVALID_ENT_REFERENCE;

    if (ge_iChildEntRef[entity] != INVALID_ENT_REFERENCE)
    {
        int beam = EntRefToEntIndex(ge_iChildEntRef[entity]);
        if (beam != INVALID_ENT_REFERENCE)
            AcceptEntityInput(beam, "Kill");
    }
    ge_iChildEntRef[entity] = INVALID_ENT_REFERENCE;

    int find = g_alPluginEntities.FindValue(EntIndexToEntRef(entity));
    if (find != -1)
        g_alPluginEntities.Erase(find);
}

/****************************************************************************************************/

void OnNextFrameGlow(int entityRef)
{
    RequestFrame(OnNextFrame, entityRef);
}

/****************************************************************************************************/

void OnNextFrame(int entityRef)
{
    int entity = EntRefToEntIndex(entityRef);

    if (entity == INVALID_ENT_REFERENCE)
        return;

    bool blocked;
    TryCreateBeam(entity, false, blocked);
}

/****************************************************************************************************/

/**
 * Creates the beam of an item that should have one.
 *
 * @param entity          Item entity.
 * @param demandOnly      Only create beams of items hidden by default that a player turned on.
 * @param blocked         Set to true if such a beam was skipped because of the edict limit.
 */
void TryCreateBeam(int entity, bool demandOnly, bool &blocked)
{
    if (ge_iChildEntRef[entity] != INVALID_ENT_REFERENCE)
        return;

    if (g_bL4D2)
    {
        if (!HasEntProp(entity, Prop_Send, "m_isCarryable")) // CPhysicsProp
        {
            if (HasEntProp(entity, Prop_Send, "m_hOwnerEntity") && GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity") != -1)
                return;
        }
    }

    char modelname[PLATFORM_MAX_PATH];
    GetEntPropString(entity, Prop_Data, "m_ModelName", modelname, sizeof(modelname));
    StringToLowerCase(modelname);

    char classname[36];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (HasEntProp(entity, Prop_Send, "m_isCarryable")) // CPhysicsProp
        g_smPropModelToClassname.GetString(modelname, classname, sizeof(classname));

    char melee[16];

    if (StrContains(classname, "weapon_melee") == 0)
    {
        if (StrEqual(classname, "weapon_melee"))
            GetEntPropString(entity, Prop_Data, "m_strMapSetScriptName", melee, sizeof(melee));
        else //weapon_melee_spawn
            g_smMeleeModelToName.GetString(modelname, melee, sizeof(melee));
    }

    if (StrEqual(classname, "weapon_spawn"))
    {
        int weaponId = GetEntProp(entity, Prop_Data, "m_weaponID");
        char sWeaponId[3];
        IntToString(weaponId, sWeaponId, sizeof(sWeaponId));

        if (!g_smWeaponIdToClassname.GetString(sWeaponId, classname, sizeof(classname)))
            return;
    }

    if (classname[0] == 'w')
        ReplaceString(classname, sizeof(classname), "_spawn", "");

    int config[CONFIG_ARRAYSIZE];
    if (!GetItemConfig(modelname, melee, classname, config))
        return;

    bool defaultVisible = (config[CONFIG_ENABLE] != 0);
    if (defaultVisible)
    {
        if (demandOnly)
            return;
    }
    else
    {
        if (config[CONFIG_PLAYER] == 0 || !IsGroupDemanded(config[CONFIG_GROUP]))
            return;

        if (GetEntityCount() >= g_iCvar_PlayerEdictLimit)
        {
            blocked = true;
            return;
        }
    }

    if (g_bCvar_UseGlowColor && HasEntProp(entity, Prop_Send, "m_glowColorOverride") && GetEntProp(entity, Prop_Send, "m_glowColorOverride") != 0)
    {
        int glowColor = GetEntProp(entity, Prop_Send, "m_glowColorOverride");
        config[CONFIG_R] = ((glowColor >> 00) & 0xFF);
        config[CONFIG_G] = ((glowColor >> 08) & 0xFF);
        config[CONFIG_B] = ((glowColor >> 16) & 0xFF);
    }
    else if (config[CONFIG_RANDOM] == 1)
    {
        int colorRandom[3];
        do
        {
            colorRandom[0] = GetRandomInt(0, 255);
            colorRandom[1] = GetRandomInt(0, 255);
            colorRandom[2] = GetRandomInt(0, 255);
        }
        while (GetRGB_Brightness(colorRandom) < g_fCvar_MinBrightness);

        config[CONFIG_R] = colorRandom[0];
        config[CONFIG_G] = colorRandom[1];
        config[CONFIG_B] = colorRandom[2];
    }

    if (HasEntProp(entity, Prop_Data, "m_itemCount")) // *_spawn entities
    {
        if (!ge_bUsePostHooked[entity])
        {
            ge_bUsePostHooked[entity] = true;
            SDKHook(entity, SDKHook_UsePost, OnUsePostSpawner);
        }
    }

    CreateBeam(entity, config, defaultVisible);
}

/****************************************************************************************************/

/**
 * Looks up the item config by model, melee name and classname, in that order.
 * The first entry shown by default wins; otherwise the first entry found is used for players who turn it on.
 *
 * @return                True if any entry was found.
 */
bool GetItemConfig(const char[] modelname, const char[] melee, const char[] classname, int[] config)
{
    int candidate[CONFIG_ARRAYSIZE];
    bool found;

    if (g_smModelConfig.GetArray(modelname, candidate, sizeof(candidate)) && PickItemConfig(candidate, config, found))
        return true;

    if (melee[0] != '\0' && g_smMeleeConfig.GetArray(melee, candidate, sizeof(candidate)) && PickItemConfig(candidate, config, found))
        return true;

    if (g_smClassnameConfig.GetArray(classname, candidate, sizeof(candidate)) && PickItemConfig(candidate, config, found))
        return true;

    return found;
}

/****************************************************************************************************/

bool PickItemConfig(const int[] candidate, int[] config, bool &found)
{
    bool enabled = (candidate[CONFIG_ENABLE] != 0);

    if (!found || enabled)
    {
        CopyConfig(candidate, config);
        found = true;
    }

    return enabled;
}

/****************************************************************************************************/

void CreateBeam(int target, int[] config, bool defaultVisible)
{
    char rendercolor[12];
    FormatEx(rendercolor, sizeof(rendercolor), "%i %i %i", config[CONFIG_R], config[CONFIG_G], config[CONFIG_B]);

    float vPos[3];
    GetEntPropVector(target, Prop_Data, "m_vecAbsOrigin", vPos);
    vPos[2] += g_fExtraPosZ;

    int entity = CreateEntityByName("beam_spotlight");
    DispatchKeyValue(entity, "targetname", "l4d_random_beam_item");
    // 1 = Start on, 2 = No dynamic light. Beams hidden by default stay off and are only turned on for the players who asked.
    DispatchKeyValue(entity, "spawnflags", defaultVisible ? "3" : "2");
    DispatchKeyValue(entity, "rendercolor", rendercolor);
    DispatchKeyValueFloat(entity, "SpotlightLength", float(config[CONFIG_LENGTH]));
    DispatchKeyValueFloat(entity, "SpotlightWidth", float(config[CONFIG_WIDTH]));
    DispatchKeyValueFloat(entity, "HDRColorScale", config[CONFIG_HDR]/10.0);
    DispatchKeyValueVector(entity, "origin", vPos);
    DispatchKeyValueVector(entity, "angles", g_vAngles);
    DispatchSpawn(entity);

    g_alPluginEntities.Push(EntIndexToEntRef(entity));

    SetEntProp(entity, Prop_Send, "m_nHaloIndex", config[CONFIG_HALO] == 1 ? g_iHalo : -1); // After dispatch spawn otherwise won't work

    ge_bTurnOn[entity] = true;
    ge_bBeamDefault[entity] = defaultVisible;
    ge_iBeamGroup[entity] = config[CONFIG_GROUP];
    ge_iParentEntRef[entity] = EntIndexToEntRef(target);
    ge_iChildEntRef[target] = EntIndexToEntRef(entity);

    HookBeamSendProxy(entity);

    if (!ge_bVPhysicsUpdatePostHooked[target])
    {
        ge_bVPhysicsUpdatePostHooked[target] = true;
        SDKHook(target, SDKHook_VPhysicsUpdatePost, OnVPhysicsUpdatePost);
    }
}

/****************************************************************************************************/

void OnVPhysicsUpdatePost(int entity)
{
    if (ge_iChildEntRef[entity] == INVALID_ENT_REFERENCE)
        return;

    int beam = EntRefToEntIndex(ge_iChildEntRef[entity]);
    if (beam == INVALID_ENT_REFERENCE)
    {
        ge_iChildEntRef[entity] = INVALID_ENT_REFERENCE;
        return;
    }

    float vPos[3];
    GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vPos);
    vPos[2] += g_fExtraPosZ;

    TeleportEntity(beam, vPos, g_vAngles, NULL_VECTOR);
}

/****************************************************************************************************/

void OnUsePostSpawner(int entity, int activator, int caller, UseType type, float value)
{
    if (!g_bCvar_Enabled)
        return;

    if (!g_bCvar_RemoveSpawner)
        return;

    if (GetEntProp(entity, Prop_Data, "m_itemCount") == 0)
        AcceptEntityInput(entity, "Kill");
}

/****************************************************************************************************/

public void OnGameFrame()
{
    if (g_bL4D2)
        return;

    if (!g_bCvar_Enabled)
        return;

    int entity;
    int parent;

    bool turnOff;
    bool turnOn;

    for (int i = 0; i < g_alPluginEntities.Length; i++)
    {
        entity = EntRefToEntIndex(g_alPluginEntities.Get(i));

        if (entity == INVALID_ENT_REFERENCE)
            continue;

        parent = EntRefToEntIndex(ge_iParentEntRef[entity]);

        if (parent == INVALID_ENT_REFERENCE)
            continue;

        if (HasEntProp(entity, Prop_Send, "m_isCarryable")) // CPhysicsProp
            continue;

        // Fixes L4D1 picked up/dropped weapons
        if (ge_bTurnOn[entity])
        {
            turnOff = (HasEntProp(parent, Prop_Send, "m_hOwnerEntity") && GetEntPropEnt(parent, Prop_Send, "m_hOwnerEntity") != -1);

            if (turnOff)
            {
                ge_bTurnOn[entity] = false;
                SetBeamTurnedOn(entity, false);
            }
        }
        else
        {
            turnOn = (HasEntProp(parent, Prop_Send, "m_hOwnerEntity") && GetEntPropEnt(parent, Prop_Send, "m_hOwnerEntity") == -1);

            if (turnOn)
            {
                ge_bTurnOn[entity] = true;
                SetBeamTurnedOn(entity, true);
            }
        }
    }
}

/****************************************************************************************************/

void SetBeamTurnedOn(int beam, bool turnOn)
{
    // Beams hidden by default stay off on the server; the send proxy reads ge_bTurnOn instead
    if (ge_bBeamDefault[beam])
        AcceptEntityInput(beam, turnOn ? "LightOn" : "LightOff");
    else
        ChangeEdictState(beam);
}

/****************************************************************************************************/

public void OnPluginEnd()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) && gc_iPrefsState[client] == PREFS_READY)
            SaveClientPrefs(client);
    }

    RemoveAll();
}

/****************************************************************************************************/

void RemoveAll()
{
    if (g_alPluginEntities.Length > 0)
    {
        int entity;

        ArrayList g_alPluginEntitiesClone = g_alPluginEntities.Clone();

        for (int i = 0; i < g_alPluginEntitiesClone.Length; i++)
        {
            entity = EntRefToEntIndex(g_alPluginEntitiesClone.Get(i));

            if (entity == INVALID_ENT_REFERENCE)
                continue;

            AcceptEntityInput(entity, "Kill");
        }

        delete g_alPluginEntitiesClone;

        g_alPluginEntities.Clear();
    }
}

// ====================================================================================================
// Per-player beam settings (SendProxy)
// ====================================================================================================
void HookAllBeamSendProxies()
{
    int beam;
    for (int i = 0; i < g_alPluginEntities.Length; i++)
    {
        beam = EntRefToEntIndex(g_alPluginEntities.Get(i));
        if (beam != INVALID_ENT_REFERENCE)
            HookBeamSendProxy(beam);
    }
}

/****************************************************************************************************/

// Hooking twice is a no-op, and the extension drops the hooks itself when the entity is destroyed or the map ends.
void HookBeamSendProxy(int beam)
{
    if (!g_bSendProxy)
        return;

    SendProxy_HookEntity(beam, "m_bSpotlightOn", Prop_Int, ProxySpotlightOn);
    SendProxy_HookEntity(beam, "m_nHaloIndex", Prop_Int, ProxyHaloIndex);
    SendProxy_HookEntity(beam, "m_clrRender", Prop_Int, ProxyRenderColor);
    SendProxy_HookEntity(beam, "m_flSpotlightMaxLength", Prop_Float, ProxySpotlightLength);
    SendProxy_HookEntity(beam, "m_flSpotlightGoalWidth", Prop_Float, ProxySpotlightWidth);
}

/****************************************************************************************************/

bool IsBeamVisibleTo(int client, int beam)
{
    if (gc_bBeamRefresh[client] || !ge_bTurnOn[beam])
        return false;

    int visible = gc_iResolved[client][ge_iBeamGroup[beam]][PREF_VISIBLE];
    if (visible == PREF_FOLLOW)
        return ge_bBeamDefault[beam];

    return (visible == 1);
}

/****************************************************************************************************/

// Each proxy only returns Plugin_Changed when the client should see something else than the server value,
// so players on default settings don't make the beams repack every tick.
Action ProxySpotlightOn(int entity, const char[] prop, int &value, int element, int client)
{
    if (!IsValidClientIndex(client))
        return Plugin_Continue;

    // m_bSpotlightOn is a bool: the extension reads 4 bytes, only the lowest one is the prop
    int turnOn = IsBeamVisibleTo(client, entity) ? 1 : 0;
    if ((value & 0xFF) == turnOn)
        return Plugin_Continue;

    value = turnOn;
    return Plugin_Changed;
}

/****************************************************************************************************/

Action ProxyHaloIndex(int entity, const char[] prop, int &value, int element, int client)
{
    if (!IsValidClientIndex(client))
        return Plugin_Continue;

    int halo = gc_iResolved[client][ge_iBeamGroup[entity]][PREF_HALO];
    if (halo == PREF_FOLLOW)
        return Plugin_Continue;

    int haloIndex = (halo == 1) ? g_iHalo : -1;
    if (value == haloIndex)
        return Plugin_Continue;

    value = haloIndex;
    return Plugin_Changed;
}

/****************************************************************************************************/

Action ProxyRenderColor(int entity, const char[] prop, int &value, int element, int client)
{
    if (!IsValidClientIndex(client))
        return Plugin_Continue;

    int color = gc_iResolved[client][ge_iBeamGroup[entity]][PREF_COLOR];
    if (color == PREF_FOLLOW)
        return Plugin_Continue;

    // The setting is 0xRRGGBB, the network value is R, G, B, A from the lowest byte up
    int packed = (value & 0xFF000000) | ((color >> 16) & 0xFF) | (color & 0xFF00) | ((color & 0xFF) << 16);
    if (value == packed)
        return Plugin_Continue;

    value = packed;
    return Plugin_Changed;
}

/****************************************************************************************************/

Action ProxySpotlightLength(int entity, const char[] prop, float &value, int element, int client)
{
    if (!IsValidClientIndex(client))
        return Plugin_Continue;

    int percent = gc_iResolved[client][ge_iBeamGroup[entity]][PREF_LENGTH];
    if (percent == PREF_FOLLOW || percent == 100)
        return Plugin_Continue;

    value *= percent / 100.0;
    return Plugin_Changed;
}

/****************************************************************************************************/

Action ProxySpotlightWidth(int entity, const char[] prop, float &value, int element, int client)
{
    if (!IsValidClientIndex(client))
        return Plugin_Continue;

    int percent = gc_iResolved[client][ge_iBeamGroup[entity]][PREF_WIDTH];
    if (percent == PREF_FOLLOW || percent == 100)
        return Plugin_Continue;

    value *= percent / 100.0;
    if (value > MAX_BEAM_WIDTH)
        value = MAX_BEAM_WIDTH;

    return Plugin_Changed;
}

/****************************************************************************************************/

// Briefly turns every beam off for this client, then back on with the new settings,
// so the client rebuilds its beams and picks up the halo and color.
void RefreshClientBeams(int client)
{
    if (!g_bSendProxy)
        return;

    gc_bBeamRefresh[client] = true;
    MarkAllBeamsChanged();

    delete gc_hRefreshTimer[client];
    gc_hRefreshTimer[client] = CreateTimer(REFRESH_DELAY, TimerEndRefresh, client);
}

/****************************************************************************************************/

Action TimerEndRefresh(Handle timer, int client)
{
    gc_hRefreshTimer[client] = null;
    gc_bBeamRefresh[client] = false;
    MarkAllBeamsChanged();

    return Plugin_Stop;
}

/****************************************************************************************************/

// Proxied values only reach a client when the entity is repacked, so flag every beam as changed.
void MarkAllBeamsChanged()
{
    int beam;
    for (int i = 0; i < g_alPluginEntities.Length; i++)
    {
        beam = EntRefToEntIndex(g_alPluginEntities.Get(i));
        if (beam != INVALID_ENT_REFERENCE)
            ChangeEdictState(beam);
    }
}

// ====================================================================================================
// Beams that players turn on for items hidden by default
// ====================================================================================================
bool IsGroupDemanded(int group)
{
    return (g_bSendProxy && group != GROUP_NONE && g_iGroupDemand[group] > 0);
}

/****************************************************************************************************/

/**
 * Recounts, per item group, how many players turned the beams on.
 *
 * @param notifyClient    Client told in chat if a new beam hits the edict limit, 0 for nobody.
 * @param scan            Create the beams of groups that just got their first player.
 */
void UpdateGroupDemand(int notifyClient, bool scan = true)
{
    int demand[MAX_GROUPS];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
            continue;

        for (int group = 0; group < g_iGroupCount; group++)
        {
            if (gc_iResolved[client][group][PREF_VISIBLE] == 1)
                demand[group]++;
        }
    }

    bool gained;
    bool lost;

    for (int group = 0; group < g_iGroupCount; group++)
    {
        if (demand[group] > 0 && g_iGroupDemand[group] == 0)
            gained = true;
        else if (demand[group] == 0 && g_iGroupDemand[group] > 0)
            lost = true;

        g_iGroupDemand[group] = demand[group];
    }

    if (lost)
        RemoveUndemandedBeams();

    if (gained && scan)
        CreateDemandedBeams(notifyClient);
}

/****************************************************************************************************/

void CreateDemandedBeams(int notifyClient)
{
    if (!g_bCvar_Enabled || !g_bSendProxy)
        return;

    bool blocked;

    int entity = INVALID_ENT_REFERENCE;
    while ((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
    {
        if (entity <= MaxClients)
            continue;

        TryCreateBeam(entity, true, blocked);
    }

    if (blocked && IsValidClient(notifyClient))
        CPrintToChat(notifyClient, "%t", "L4DRandomBeamItem_EdictLimit");
}

/****************************************************************************************************/

void RemoveUndemandedBeams()
{
    int beam;
    for (int i = 0; i < g_alPluginEntities.Length; i++)
    {
        beam = EntRefToEntIndex(g_alPluginEntities.Get(i));
        if (beam == INVALID_ENT_REFERENCE || ge_bBeamDefault[beam])
            continue;

        if (!IsGroupDemanded(ge_iBeamGroup[beam]))
            AcceptEntityInput(beam, "Kill"); // Deferred to the end of the frame, the list is updated in OnEntityDestroyed
    }
}

// ====================================================================================================
// Player settings
// ====================================================================================================
void ResetClientPrefs(int client)
{
    for (int scope = 0; scope <= MAX_GROUPS; scope++)
        ResetScope(client, scope);

    ResolveClientPrefs(client);

    gc_bBeamRefresh[client] = false;
    gc_bPrefsDirty[client] = false;
    gc_bNotSavedWarned[client] = false;
    gc_iPrefsState[client] = PREFS_NONE;
    gc_sAuthId[client][0] = '\0';
    delete gc_hRefreshTimer[client];
    delete gc_hSaveTimer[client];
}

/****************************************************************************************************/

void ResetScope(int client, int scope)
{
    for (int field = 0; field < PREF_COUNT; field++)
        gc_iPref[client][scope][field] = PREF_FOLLOW;
}

/****************************************************************************************************/

bool IsScopeDefault(int client, int scope)
{
    for (int field = 0; field < PREF_COUNT; field++)
    {
        if (gc_iPref[client][scope][field] != PREF_FOLLOW)
            return false;
    }

    return true;
}

/****************************************************************************************************/

void ResolveClientPrefs(int client)
{
    int value;
    for (int group = 0; group <= MAX_GROUPS; group++)
    {
        for (int field = 0; field < PREF_COUNT; field++)
        {
            value = gc_iPref[client][group][field];
            if (value == PREF_FOLLOW)
                value = gc_iPref[client][SCOPE_GLOBAL][field];

            gc_iResolved[client][group][field] = value;
        }
    }
}

/****************************************************************************************************/

int SanitizePref(int scope, int field, int value)
{
    switch (field)
    {
        case PREF_VISIBLE:
        {
            // "All items" can hide everything but not show every item on the map
            if (value == 0 || (value == 1 && scope != SCOPE_GLOBAL))
                return value;
        }
        case PREF_LENGTH, PREF_WIDTH:
        {
            if (value > 0)
                return value < 10 ? 10 : (value > 1000 ? 1000 : value);
        }
        case PREF_COLOR:
        {
            if (0 <= value <= 0xFFFFFF)
                return value;
        }
        case PREF_HALO:
        {
            if (value == 0 || value == 1)
                return value;
        }
    }

    return PREF_FOLLOW;
}

/****************************************************************************************************/

// Called after the player changed a setting from the menu or the command.
void OnClientPrefsEdited(int client)
{
    gc_bPrefsDirty[client] = true;
    ApplyClientPrefs(client, client);

    if (gc_iPrefsState[client] == PREFS_READY)
    {
        delete gc_hSaveTimer[client];
        gc_hSaveTimer[client] = CreateTimer(SAVE_DELAY, TimerSavePrefs, client);
    }
    else if (gc_iPrefsState[client] != PREFS_LOADING && !gc_bNotSavedWarned[client])
    {
        gc_bNotSavedWarned[client] = true;
        CPrintToChat(client, "%t", "L4DRandomBeamItem_PrefsNotSaved");
    }
}

/****************************************************************************************************/

void ApplyClientPrefs(int client, int notifyClient)
{
    ResolveClientPrefs(client);

    if (IsClientInGame(client))
        RefreshClientBeams(client);

    UpdateGroupDemand(notifyClient);
}

/****************************************************************************************************/

void ApplyPreset(int client, const char[] style)
{
    int scope = SCOPE_GLOBAL;
    char phrase[64];

    if (StrEqual(style, "bright") || StrEqual(style, "subtle"))
    {
        int preset = StrEqual(style, "bright") ? PRESET_BRIGHT : PRESET_SUBTLE;
        gc_iPref[client][scope][PREF_VISIBLE] = PREF_FOLLOW;
        gc_iPref[client][scope][PREF_LENGTH] = g_iPresetLength[preset];
        gc_iPref[client][scope][PREF_WIDTH] = g_iPresetWidth[preset];
        gc_iPref[client][scope][PREF_HALO] = g_iPresetHalo[preset];
        strcopy(phrase, sizeof(phrase), preset == PRESET_BRIGHT ? "L4DRandomBeamItem_StyleBright" : "L4DRandomBeamItem_StyleSubtle");
    }
    else if (StrEqual(style, "off"))
    {
        gc_iPref[client][scope][PREF_VISIBLE] = 0;
        strcopy(phrase, sizeof(phrase), "L4DRandomBeamItem_StyleOff");
    }
    else // default
    {
        ResetScope(client, scope);
        strcopy(phrase, sizeof(phrase), "L4DRandomBeamItem_StyleDefault");
    }

    OnClientPrefsEdited(client);

    char name[64];
    FormatEx(name, sizeof(name), "%T", phrase, client);
    CPrintToChat(client, "%t", "L4DRandomBeamItem_StyleSet", name);
}

/****************************************************************************************************/

void ResetAllClientPrefs(int client)
{
    for (int scope = 0; scope <= MAX_GROUPS; scope++)
        ResetScope(client, scope);

    OnClientPrefsEdited(client);
    CPrintToChat(client, "%t", "L4DRandomBeamItem_PrefsReset");
}

/****************************************************************************************************/

/**
 * Stores the settings as "scope:visible,length,width,color,halo" entries separated by ";".
 * The scope is "*" for all items or the group key; the color is RRGGBB in hex; -1 means not set.
 */
void SerializePrefs(int client, char[] buffer, int maxlength)
{
    buffer[0] = '\0';

    char entry[96];
    char color[8];
    for (int scope = 0; scope <= MAX_GROUPS; scope++)
    {
        if (scope >= g_iGroupCount && scope != SCOPE_GLOBAL)
            continue;

        if (IsScopeDefault(client, scope))
            continue;

        if (gc_iPref[client][scope][PREF_COLOR] == PREF_FOLLOW)
            strcopy(color, sizeof(color), "-1");
        else
            FormatEx(color, sizeof(color), "%06x", gc_iPref[client][scope][PREF_COLOR]);

        FormatEx(entry, sizeof(entry), "%s%s:%i,%i,%i,%s,%i", buffer[0] == '\0' ? "" : ";", scope == SCOPE_GLOBAL ? "*" : g_sGroupKey[scope],
            gc_iPref[client][scope][PREF_VISIBLE], gc_iPref[client][scope][PREF_LENGTH], gc_iPref[client][scope][PREF_WIDTH], color, gc_iPref[client][scope][PREF_HALO]);
        StrCat(buffer, maxlength, entry);
    }
}

/****************************************************************************************************/

void ParsePrefs(int client, const char[] data)
{
    for (int scope = 0; scope <= MAX_GROUPS; scope++)
        ResetScope(client, scope);

    char entries[MAX_GROUPS + 1][96];
    char parts[2][80];
    char fields[PREF_COUNT][12];

    int count = ExplodeString(data, ";", entries, sizeof(entries), sizeof(entries[]));
    for (int i = 0; i < count; i++)
    {
        if (ExplodeString(entries[i], ":", parts, sizeof(parts), sizeof(parts[])) != 2)
            continue;

        int scope = StrEqual(parts[0], "*") ? SCOPE_GLOBAL : FindGroup(parts[0]);
        if (scope == -1) // Group removed from the data file
            continue;

        if (ExplodeString(parts[1], ",", fields, sizeof(fields), sizeof(fields[])) != PREF_COUNT)
            continue;

        for (int field = 0; field < PREF_COUNT; field++)
        {
            int value = StringToInt(fields[field]);
            if (field == PREF_COLOR && value != PREF_FOLLOW)
                value = StringToInt(fields[field], 16);

            gc_iPref[client][scope][field] = SanitizePref(scope, field, value);
        }
    }
}

// ====================================================================================================
// Database
// ====================================================================================================
void ConnectDatabase()
{
    if (!SQL_CheckConfig(DB_CONFIG))
    {
        LogError("Database config \"%s\" is missing, player beam settings won't be saved.", DB_CONFIG);
        return;
    }

    AnneDB_ConnectCompat(OnDatabaseConnected, DB_CONFIG);
}

/****************************************************************************************************/

void OnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        LogError("Database connection failed, player beam settings won't be saved: %s", error);
        return;
    }

    char driver[16];
    db.Driver.GetIdentifier(driver, sizeof(driver));
    if (!StrEqual(driver, "mysql"))
    {
        LogError("Database config \"%s\" uses \"%s\", player beam settings need MySQL.", DB_CONFIG, driver);
        delete db;
        return;
    }

    if (g_hDatabase != null)
    {
        delete db;
        return;
    }

    g_hDatabase = db;
    AnneDB_SetCharsetIfOwned(g_hDatabase, "utf8mb4");

    char query[512];
    FormatEx(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `%s` ("
        ... "`steamid` varchar(64) NOT NULL,"
        ... "`prefs` varchar(%i) NOT NULL DEFAULT '',"
        ... "`updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,"
        ... "PRIMARY KEY (`steamid`)"
        ... ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4", DB_TABLE, PREFS_MAX_LENGTH);

    g_hDatabase.Query(OnTableCreated, query);
}

/****************************************************************************************************/

void OnTableCreated(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
    {
        LogError("Failed to create table \"%s\", player beam settings won't be saved: %s", DB_TABLE, error);
        return;
    }

    g_bDatabaseReady = true;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && IsClientAuthorized(client))
            LoadClientPrefs(client);
    }
}

/****************************************************************************************************/

void LoadClientPrefs(int client)
{
    if (!g_bDatabaseReady || IsFakeClient(client))
        return;

    if (gc_iPrefsState[client] != PREFS_NONE)
        return;

    if (!GetClientAuthId(client, AuthId_Steam2, gc_sAuthId[client], sizeof(gc_sAuthId[])))
        return;

    char query[256];
    g_hDatabase.Format(query, sizeof(query), "SELECT `prefs` FROM `%s` WHERE `steamid` = '%s' LIMIT 1", DB_TABLE, gc_sAuthId[client]);

    gc_iPrefsState[client] = PREFS_LOADING;
    g_hDatabase.Query(OnPrefsLoaded, query, GetClientUserId(client));
}

/****************************************************************************************************/

void OnPrefsLoaded(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || gc_iPrefsState[client] != PREFS_LOADING)
        return;

    if (results == null)
    {
        // Keep the settings for this session only, saving could overwrite the stored ones
        LogError("Failed to load the beam settings of %N: %s", client, error);
        gc_iPrefsState[client] = PREFS_FAILED;
        return;
    }

    gc_iPrefsState[client] = PREFS_READY;

    // Settings changed before the database answered win over the stored ones
    if (gc_bPrefsDirty[client])
    {
        SaveClientPrefs(client);
        return;
    }

    if (!results.FetchRow())
        return;

    char data[PREFS_MAX_LENGTH];
    results.FetchString(0, data, sizeof(data));
    ParsePrefs(client, data);
    ApplyClientPrefs(client, 0);
}

/****************************************************************************************************/

Action TimerSavePrefs(Handle timer, int client)
{
    gc_hSaveTimer[client] = null;
    SaveClientPrefs(client);

    return Plugin_Stop;
}

/****************************************************************************************************/

void SaveClientPrefs(int client)
{
    delete gc_hSaveTimer[client];

    if (!gc_bPrefsDirty[client] || g_hDatabase == null || gc_sAuthId[client][0] == '\0')
        return;

    char data[PREFS_MAX_LENGTH];
    SerializePrefs(client, data, sizeof(data));

    char query[PREFS_MAX_LENGTH * 2 + 256];
    g_hDatabase.Format(query, sizeof(query), "INSERT INTO `%s` (`steamid`, `prefs`) VALUES ('%s', '%s') ON DUPLICATE KEY UPDATE `prefs` = VALUES(`prefs`)", DB_TABLE, gc_sAuthId[client], data);
    g_hDatabase.Query(OnPrefsSaved, query);

    gc_bPrefsDirty[client] = false;
}

/****************************************************************************************************/

void OnPrefsSaved(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null)
        LogError("Failed to save player beam settings: %s", error);
}

// ====================================================================================================
// Menus
// ====================================================================================================
void ShowMainMenu(int client)
{
    Menu menu = new Menu(MenuHandlerMain);
    menu.SetTitle("%T", "L4DRandomBeamItem_MenuMainTitle", client);
    AddMenuItemPhrase(menu, client, "presets", "L4DRandomBeamItem_MenuPresets");
    AddMenuItemPhrase(menu, client, "global", "L4DRandomBeamItem_MenuGlobal");
    AddMenuItemPhrase(menu, client, "groups", "L4DRandomBeamItem_MenuGroups");
    AddMenuItemPhrase(menu, client, "reset", "L4DRandomBeamItem_MenuResetAll");
    menu.Display(client, MENU_TIME_FOREVER);
}

/****************************************************************************************************/

int MenuHandlerMain(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[16];
            menu.GetItem(param2, info, sizeof(info));

            if (StrEqual(info, "presets"))
                ShowPresetMenu(param1);
            else if (StrEqual(info, "global"))
                ShowScopeMenu(param1, SCOPE_GLOBAL);
            else if (StrEqual(info, "groups"))
                ShowGroupMenu(param1, 0);
            else
            {
                ResetAllClientPrefs(param1);
                ShowMainMenu(param1);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

/****************************************************************************************************/

void ShowPresetMenu(int client)
{
    Menu menu = new Menu(MenuHandlerPreset);
    menu.SetTitle("%T", "L4DRandomBeamItem_MenuPresetsTitle", client);
    AddMenuItemPhrase(menu, client, "bright", "L4DRandomBeamItem_StyleMenuBright");
    AddMenuItemPhrase(menu, client, "subtle", "L4DRandomBeamItem_StyleMenuSubtle");
    AddMenuItemPhrase(menu, client, "off", "L4DRandomBeamItem_StyleMenuOff");
    AddMenuItemPhrase(menu, client, "default", "L4DRandomBeamItem_StyleMenuDefault");
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

/****************************************************************************************************/

int MenuHandlerPreset(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[16];
            menu.GetItem(param2, info, sizeof(info));
            ApplyPreset(param1, info);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
                ShowMainMenu(param1);
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

/****************************************************************************************************/

void ShowGroupMenu(int client, int position)
{
    Menu menu = new Menu(MenuHandlerGroup);
    menu.SetTitle("%T", "L4DRandomBeamItem_MenuGroupsTitle", client);

    char info[4];
    char display[128];
    for (int group = 0; group < g_iGroupCount; group++)
    {
        if (!g_bGroupSelectable[group])
            continue;

        GetScopeName(client, group, display, sizeof(display));
        if (!IsScopeDefault(client, group))
            Format(display, sizeof(display), "%T", "L4DRandomBeamItem_MenuCustomized", client, display);

        IntToString(group, info, sizeof(info));
        menu.AddItem(info, display);
    }

    menu.ExitBackButton = true;
    menu.DisplayAt(client, position, MENU_TIME_FOREVER);
}

/****************************************************************************************************/

int MenuHandlerGroup(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[4];
            menu.GetItem(param2, info, sizeof(info));
            gc_iGroupMenuPosition[param1] = menu.Selection;

            int group = StringToInt(info);
            if (group < g_iGroupCount)
                ShowScopeMenu(param1, group);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
                ShowMainMenu(param1);
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

/****************************************************************************************************/

void ShowScopeMenu(int client, int scope)
{
    gc_iMenuScope[client] = scope;

    char name[64];
    GetScopeName(client, scope, name, sizeof(name));

    Menu menu = new Menu(MenuHandlerScope);
    if (scope == SCOPE_GLOBAL)
        menu.SetTitle("%T", "L4DRandomBeamItem_MenuGlobalTitle", client);
    else
        menu.SetTitle("%T", "L4DRandomBeamItem_MenuGroupTitle", client, name);

    char info[4];
    char fieldName[64];
    char value[64];
    char display[128];
    for (int field = 0; field < PREF_COUNT; field++)
    {
        FormatEx(fieldName, sizeof(fieldName), "%T", g_sFieldPhrase[field], client);
        FormatPrefValue(client, scope, field, gc_iPref[client][scope][field], value, sizeof(value));
        FormatEx(display, sizeof(display), "%T", "L4DRandomBeamItem_MenuFieldValue", client, fieldName, value);

        IntToString(field, info, sizeof(info));
        menu.AddItem(info, display);
    }

    AddMenuItemPhrase(menu, client, "reset", "L4DRandomBeamItem_MenuResetScope", IsScopeDefault(client, scope) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

/****************************************************************************************************/

int MenuHandlerScope(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int scope = gc_iMenuScope[param1];

            char info[8];
            menu.GetItem(param2, info, sizeof(info));

            if (StrEqual(info, "reset"))
            {
                ResetScope(param1, scope);
                OnClientPrefsEdited(param1);
                ShowScopeMenu(param1, scope);
            }
            else
            {
                ShowValueMenu(param1, scope, StringToInt(info));
            }
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                if (gc_iMenuScope[param1] == SCOPE_GLOBAL)
                    ShowMainMenu(param1);
                else
                    ShowGroupMenu(param1, gc_iGroupMenuPosition[param1]);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

/****************************************************************************************************/

void ShowValueMenu(int client, int scope, int field)
{
    gc_iMenuField[client] = field;

    char name[64];
    char fieldName[64];
    GetScopeName(client, scope, name, sizeof(name));
    FormatEx(fieldName, sizeof(fieldName), "%T", g_sFieldPhrase[field], client);

    Menu menu = new Menu(MenuHandlerValue);
    menu.SetTitle("%T", "L4DRandomBeamItem_MenuValueTitle", client, name, fieldName);

    int options[16];
    int count = GetFieldOptions(scope, field, options);
    int current = gc_iPref[client][scope][field];

    char info[12];
    char display[128];
    for (int i = 0; i < count; i++)
    {
        FormatPrefValue(client, scope, field, options[i], display, sizeof(display));
        if (options[i] == current)
            Format(display, sizeof(display), "%T", "L4DRandomBeamItem_MenuCurrent", client, display);

        IntToString(options[i], info, sizeof(info));
        menu.AddItem(info, display, options[i] == current ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

/****************************************************************************************************/

int MenuHandlerValue(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int scope = gc_iMenuScope[param1];
            int field = gc_iMenuField[param1];

            char info[12];
            menu.GetItem(param2, info, sizeof(info));

            gc_iPref[param1][scope][field] = SanitizePref(scope, field, StringToInt(info));
            OnClientPrefsEdited(param1);
            ShowScopeMenu(param1, scope);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
                ShowScopeMenu(param1, gc_iMenuScope[param1]);
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

/****************************************************************************************************/

int GetFieldOptions(int scope, int field, int[] options)
{
    int count;
    options[count++] = PREF_FOLLOW;

    switch (field)
    {
        case PREF_VISIBLE:
        {
            if (scope != SCOPE_GLOBAL)
                options[count++] = 1;
            options[count++] = 0;
        }
        case PREF_LENGTH, PREF_WIDTH:
        {
            for (int i = 0; i < sizeof(g_iScaleLevels); i++)
            {
                // 100% is what "default" already means for all items
                if (scope == SCOPE_GLOBAL && g_iScaleLevels[i] == 100)
                    continue;

                options[count++] = g_iScaleLevels[i];
            }
        }
        case PREF_COLOR:
        {
            for (int i = 0; i < sizeof(g_iPaletteColor); i++)
                options[count++] = g_iPaletteColor[i];
        }
        case PREF_HALO:
        {
            options[count++] = 1;
            options[count++] = 0;
        }
    }

    return count;
}

/****************************************************************************************************/

void FormatPrefValue(int client, int scope, int field, int value, char[] buffer, int maxlength)
{
    if (value == PREF_FOLLOW)
    {
        if (scope == SCOPE_GLOBAL)
            FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueDefault", client);
        else
            FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueFollowGlobal", client);
        return;
    }

    switch (field)
    {
        case PREF_VISIBLE:
        {
            if (value == 1)
                FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueShow", client);
            else
                FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueHide", client);
        }
        case PREF_LENGTH, PREF_WIDTH:
        {
            FormatEx(buffer, maxlength, "%i%%", value);
        }
        case PREF_COLOR:
        {
            for (int i = 0; i < sizeof(g_iPaletteColor); i++)
            {
                if (g_iPaletteColor[i] == value)
                {
                    FormatEx(buffer, maxlength, "%T", g_sPalettePhrase[i], client);
                    return;
                }
            }

            FormatEx(buffer, maxlength, "#%06X", value);
        }
        case PREF_HALO:
        {
            if (value == 1)
                FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueOn", client);
            else
                FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_ValueOff", client);
        }
    }
}

/****************************************************************************************************/

void GetScopeName(int client, int scope, char[] buffer, int maxlength)
{
    if (scope == SCOPE_GLOBAL)
    {
        FormatEx(buffer, maxlength, "%T", "L4DRandomBeamItem_MenuGlobal", client);
        return;
    }

    // Groups added to the data file without a translation show their key
    char phrase[64];
    FormatEx(phrase, sizeof(phrase), "L4DRandomBeamItem_Group_%s", g_sGroupKey[scope]);
    if (TranslationPhraseExists(phrase))
        FormatEx(buffer, maxlength, "%T", phrase, client);
    else
        strcopy(buffer, maxlength, g_sGroupKey[scope]);
}

/****************************************************************************************************/

void AddMenuItemPhrase(Menu menu, int client, const char[] info, const char[] phrase, int style = ITEMDRAW_DEFAULT)
{
    char display[128];
    FormatEx(display, sizeof(display), "%T", phrase, client);
    menu.AddItem(info, display, style);
}

// ====================================================================================================
// Public Commands
// ====================================================================================================
Action CmdBeam(int client, int args)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return Plugin_Handled;

    if (!g_bSendProxy)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_StyleUnavailable");
        return Plugin_Handled;
    }

    if (gc_iPrefsState[client] == PREFS_LOADING)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_PrefsLoading");
        return Plugin_Handled;
    }

    if (args == 0)
    {
        ShowMainMenu(client);
        return Plugin_Handled;
    }

    char arg[16];
    GetCmdArg(1, arg, sizeof(arg));
    StringToLowerCase(arg);

    if (StrEqual(arg, "reset"))
        ResetAllClientPrefs(client);
    else if (StrEqual(arg, "bright") || StrEqual(arg, "subtle") || StrEqual(arg, "off") || StrEqual(arg, "default"))
        ApplyPreset(client, arg);
    else
        CPrintToChat(client, "%t", "L4DRandomBeamItem_StyleUsage");

    return Plugin_Handled;
}

// ====================================================================================================
// Admin Commands
// ====================================================================================================
Action CmdInfo(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    int entity = GetClientAimTarget(client, false);

    if (entity == -1)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_InvalidTarget");
        return Plugin_Handled;
    }

    if (ge_iChildEntRef[entity] == INVALID_ENT_REFERENCE)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_TargetEntityNoBeam");
        return Plugin_Handled;
    }

    int beam = EntRefToEntIndex(ge_iChildEntRef[entity]);
    if (beam == INVALID_ENT_REFERENCE)
    {
        ge_iChildEntRef[entity] = INVALID_ENT_REFERENCE;
        CPrintToChat(client, "%t", "L4DRandomBeamItem_TargetEntityNoBeam");
        return Plugin_Handled;
    }

    float length = GetEntPropFloat(beam, Prop_Send, "m_flSpotlightMaxLength");
    float width = GetEntPropFloat(beam, Prop_Send, "m_flSpotlightGoalWidth");
    float hdrColorScale = GetEntPropFloat(beam, Prop_Send, "m_flHDRColorScale");

    int color = GetEntProp(beam, Prop_Send, "m_clrRender");
    int rgb[3];
    rgb[0] = ((color >> 00) & 0xFF);
    rgb[1] = ((color >> 08) & 0xFF);
    rgb[2] = ((color >> 16) & 0xFF);

    char classname[36];
    GetEntityClassname(entity, classname, sizeof(classname));

    char modelname[PLATFORM_MAX_PATH];
    GetEntPropString(entity, Prop_Data, "m_ModelName", modelname, sizeof(modelname));

    CPrintToChat(client, "%t", "L4DRandomBeamItem_BeamIndexTargetIndexClassname", beam, entity, classname, modelname, rgb[0], rgb[1], rgb[2], color, GetRGB_Brightness(rgb), RoundFloat(length), RoundFloat(width), hdrColorScale);

    return Plugin_Handled;
}

/****************************************************************************************************/

Action CmdReload(int client, int args)
{
    // Group indexes can change, so carry the player settings over by group key
    ArrayList saved = new ArrayList(ByteCountToCells(PREFS_MAX_LENGTH));
    char data[PREFS_MAX_LENGTH];
    for (int target = 1; target <= MaxClients; target++)
    {
        SerializePrefs(target, data, sizeof(data));
        saved.PushString(data);
    }

    LoadConfigs();

    for (int target = 1; target <= MaxClients; target++)
    {
        saved.GetString(target - 1, data, sizeof(data));
        ParsePrefs(target, data);
        ResolveClientPrefs(target);
    }
    delete saved;

    for (int group = 0; group < MAX_GROUPS; group++)
        g_iGroupDemand[group] = 0;
    UpdateGroupDemand(0, false); // LateLoad creates the beams

    RemoveAll();

    LateLoad();

    if (IsValidClient(client))
        CPrintToChat(client, "%t", "L4DRandomBeamItem_BeamConfigsReloaded");

    return Plugin_Handled;
}

/****************************************************************************************************/

Action CmdRemove(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    int entity = GetClientAimTarget(client, false);

    if (entity == -1)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_InvalidTarget");
        return Plugin_Handled;
    }

    if (ge_iChildEntRef[entity] == INVALID_ENT_REFERENCE)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_TargetEntityNoBeam");
        return Plugin_Handled;
    }

    int beam = EntRefToEntIndex(ge_iChildEntRef[entity]);
    if (beam == INVALID_ENT_REFERENCE)
    {
        ge_iChildEntRef[entity] = INVALID_ENT_REFERENCE;
        CPrintToChat(client, "%t", "L4DRandomBeamItem_TargetEntityNoBeam");
        return Plugin_Handled;
    }
    else
    {
        AcceptEntityInput(beam, "Kill");
        CPrintToChat(client, "%t", "L4DRandomBeamItem_RemovedTargetEntityPluginBeam");
        return Plugin_Handled;
    }
}

/****************************************************************************************************/

Action CmdRemoveAll(int client, int args)
{
    RemoveAll();

    if (IsValidClient(client))
        CPrintToChat(client, "%t", "L4DRandomBeamItem_RemovedAllBeamsCreatedPlugin");

    return Plugin_Handled;
}

/****************************************************************************************************/

Action CmdAdd(int client, int args)
{
    if (!IsValidClient(client))
        return Plugin_Handled;

    int entity = GetClientAimTarget(client, false);

    if (entity == -1)
    {
        CPrintToChat(client, "%t", "L4DRandomBeamItem_InvalidTarget");
        return Plugin_Handled;
    }

    int beam = EntRefToEntIndex(ge_iChildEntRef[entity]);
    if (beam != INVALID_ENT_REFERENCE)
    {
        AcceptEntityInput(beam, "Kill");
    }
    else
    {
        ge_iChildEntRef[entity] = INVALID_ENT_REFERENCE;
    }

    if (g_bCvar_UseGlowColor && HasEntProp(entity, Prop_Send, "m_glowColorOverride") && GetEntProp(entity, Prop_Send, "m_glowColorOverride") != 0)
    {
        int glowColor = GetEntProp(entity, Prop_Send, "m_glowColorOverride");
        g_iDefaultConfig[CONFIG_R] = ((glowColor >> 00) & 0xFF);
        g_iDefaultConfig[CONFIG_G] = ((glowColor >> 08) & 0xFF);
        g_iDefaultConfig[CONFIG_B] = ((glowColor >> 16) & 0xFF);
    }
    else if (g_iDefaultConfig[CONFIG_RANDOM] == 1)
    {
        int colorRandom[3];
        do
        {
            colorRandom[0] = GetRandomInt(0, 255);
            colorRandom[1] = GetRandomInt(0, 255);
            colorRandom[2] = GetRandomInt(0, 255);
        }
        while (GetRGB_Brightness(colorRandom) < g_fCvar_MinBrightness);

        g_iDefaultConfig[CONFIG_R] = colorRandom[0];
        g_iDefaultConfig[CONFIG_G] = colorRandom[1];
        g_iDefaultConfig[CONFIG_B] = colorRandom[2];
    }

    CreateBeam(entity, g_iDefaultConfig, true);

    CPrintToChat(client, "%t", "L4DRandomBeamItem_BeamAddedTargetEntity");

    return Plugin_Handled;
}

/****************************************************************************************************/

Action CmdPrintCvars(int client, int args)
{
    PrintToConsole(client, "");
    PrintToConsole(client, "======================================================================");
    PrintToConsole(client, "");
    PrintToConsole(client, "---------------- Plugin Cvars (l4d_random_beam_item) -----------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "l4d_random_beam_item_version : %s", PLUGIN_VERSION);
    PrintToConsole(client, "l4d_random_beam_item_enable : %b (%s)", g_bCvar_Enabled, g_bCvar_Enabled ? "true" : "false");
    PrintToConsole(client, "l4d_random_beam_item_remove_spawner : %b (%s)", g_bCvar_RemoveSpawner, g_bCvar_RemoveSpawner ? "true" : "false");
    PrintToConsole(client, "l4d_random_beam_item_min_brightness : %.1f", g_fCvar_MinBrightness);
    if (g_bL4D2) PrintToConsole(client, "l4d_random_beam_item_use_glow_color : %b (%s)", g_bCvar_UseGlowColor, g_bCvar_UseGlowColor ? "true" : "false");
    PrintToConsole(client, "l4d_random_beam_item_player_edict_limit : %i", g_iCvar_PlayerEdictLimit);
    PrintToConsole(client, "");
    PrintToConsole(client, "----------------------------- Array List -----------------------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "g_alPluginEntities count : %i", g_alPluginEntities.Length);
    PrintToConsole(client, "");
    PrintToConsole(client, "---------------------------- Player Beams ----------------------------");
    PrintToConsole(client, "");
    PrintToConsole(client, "SendProxy : %s", g_bSendProxy ? "loaded" : "not loaded");
    PrintToConsole(client, "Database : %s", g_bDatabaseReady ? "ready" : "not ready");
    for (int group = 0; group < g_iGroupCount; group++)
        PrintToConsole(client, "Group %s : %i player(s) turned on", g_sGroupKey[group], g_iGroupDemand[group]);
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
 * @param client          Client index.
 * @return                True if client index is valid, false otherwise.
 */
bool IsValidClientIndex(int client)
{
    return (1 <= client <= MaxClients);
}

/****************************************************************************************************/

/**
 * Validates if is a valid client.
 *
 * @param client          Client index.
 * @return                True if client index is valid and client is in game, false otherwise.
 */
bool IsValidClient(int client)
{
    return (IsValidClientIndex(client) && IsClientInGame(client));
}

/****************************************************************************************************/

/**
 * Converts the string to lower case.
 *
 * @param input         Input string.
 */
void StringToLowerCase(char[] input)
{
    for (int i = 0; i < strlen(input); i++)
    {
        input[i] = CharToLower(input[i]);
    }
}

/****************************************************************************************************/

/**
 * Returns the integer array value of a RGB string.
 * Format: Three values between 0-255 separated by spaces. "<0-255> <0-255> <0-255>"
 * Example: "255 255 255"
 *
 * @param sColor        RGB color string.
 * @return              Integer array (int[3]) value of the RGB string or {0,0,0} if not in specified format.
 */
int[] ConvertRGBToIntArray(char[] sColor)
{
    int color[3];

    if (sColor[0] == 0)
        return color;

    char sColors[3][4];
    int count = ExplodeString(sColor, " ", sColors, sizeof(sColors), sizeof(sColors[]));

    switch (count)
    {
        case 1:
        {
            color[0] = StringToInt(sColors[0]);
        }
        case 2:
        {
            color[0] = StringToInt(sColors[0]);
            color[1] = StringToInt(sColors[1]);
        }
        case 3:
        {
            color[0] = StringToInt(sColors[0]);
            color[1] = StringToInt(sColors[1]);
            color[2] = StringToInt(sColors[2]);
        }
    }

    return color;
}

/****************************************************************************************************/

/**
 * Source: https://stackoverflow.com/a/12216661
 * Returns the RGB brightness of a RGB integer array value.
 *
 * @param rgb           RGB integer array (int[3]).
 * @return              Brightness float value between 0.0 and 1.0.
 */
float GetRGB_Brightness(int[] rgb)
{
    int r = rgb[0];
    int g = rgb[1];
    int b = rgb[2];

    int cmax = (r > g) ? r : g;
    if (b > cmax) cmax = b;
    return cmax / 255.0;
}
