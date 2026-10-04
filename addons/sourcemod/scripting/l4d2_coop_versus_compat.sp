#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <entitylump>
#include <l4d2_source_keyvalues>

#define CONFIG_FILE "configs/l4d2_coop_versus_compat.cfg"

ConVar g_cvEnabled, g_cvGameMode;
Handle g_hGetAllMissions;
Address g_pMatchExtL4D;
char g_sStatus[256] = "Not processed at map load; changelevel is required after loading this plugin.";
int g_iEntities, g_iOutputs;

public Plugin myinfo = {
    name = "L4D2 Coop Versus Compatibility",
    author = "Anne",
    description = "Use coop-only map I/O in versus without changing the engine game mode",
    version = "1.0.0",
    url = ""
};

public void OnPluginStart() {
    if (GetEngineVersion() != Engine_Left4Dead2)
        SetFailState("This plugin only supports Left 4 Dead 2.");

    // Reuse the mission registry access already used by l4d2_map_vote.
    GameData data = new GameData("l4d2_map_vote");
    if (data == null)
        SetFailState("Missing gamedata/l4d2_map_vote.txt.");
    g_pMatchExtL4D = data.GetAddress("g_pMatchExtL4D");
    delete data;
    if (g_pMatchExtL4D == Address_Null)
        SetFailState("Missing g_pMatchExtL4D address.");

    StartPrepSDKCall(SDKCall_Raw);
    PrepSDKCall_SetVirtual(0);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    g_hGetAllMissions = EndPrepSDKCall();
    if (g_hGetAllMissions == null)
        SetFailState("Could not prepare MatchExtL4D::GetAllMissions.");

    g_cvEnabled = CreateConVar("l4d2_coop_versus_compat", "1",
        "Adapt coop-only map I/O in versus. Changes apply on the next map load.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvGameMode = FindConVar("mp_gamemode");
    RegServerCmd("sm_coop_versus_status", Command_Status,
        "Show the compatibility decision made when this map loaded.");
}

public void OnMapInit(const char[] mapName) {
    g_iEntities = 0;
    g_iOutputs = 0;
    if (!g_cvEnabled.BoolValue) {
        strcopy(g_sStatus, sizeof g_sStatus, "Disabled at map load.");
        return;
    }

    char mode[64];
    g_cvGameMode.GetString(mode, sizeof mode);
    if (!StrEqual(mode, "versus", false)) {
        FormatEx(g_sStatus, sizeof g_sStatus, "Skipped: game mode is %s (only versus is supported).", mode);
        return;
    }

    int override = GetMapOverride(mapName);
    if (override == 0) {
        strcopy(g_sStatus, sizeof g_sStatus, "Skipped by map config (or invalid config; see error log).");
        return;
    }
    if (override != 1) {
        SourceKeyValues missions = SDKCall(g_hGetAllMissions, g_pMatchExtL4D);
        if (!IsCoopOnlyMap(missions, mapName)) {
            strcopy(g_sStatus, sizeof g_sStatus, "Skipped: official, native versus, or no coop mission found.");
            return;
        }
    }

    for (int i = 0; i < EntityLump.Length(); i++) {
        EntityLumpEntry entry = EntityLump.Get(i);
        char classname[64];
        entry.GetNextKey("classname", classname, sizeof classname);
        if (StrEqual(classname, "info_gamemode", false)) {
            int copied = RewriteOutput(entry, "OnCoop", "OnVersus");
            copied += RewriteOutput(entry, "OnCoopPostIO", "OnVersusPostIO");
            if (copied > 0) {
                g_iEntities++;
                g_iOutputs += copied;
            }
        }
        delete entry;
    }

    FormatEx(g_sStatus, sizeof g_sStatus, "%s: %d entities, %d coop output connections adapted.",
        override == 1 ? "Forced by map config" : "Detected coop-only mission", g_iEntities, g_iOutputs);
    LogMessage("%s: %s", mapName, g_sStatus);
}

// -1: automatic; 0: exclude; 1: explicitly enable this map.
int GetMapOverride(const char[] mapName) {
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof path, CONFIG_FILE);
    if (!FileExists(path))
        return -1;

    KeyValues config = new KeyValues("CoopVersusCompat");
    if (!config.ImportFromFile(path)) {
        delete config;
        LogError("Cannot parse %s; map adaptation skipped.", path);
        return 0;
    }
    // Read text so a typo cannot silently become an enable or exclude value.
    char setting[16];
    config.GetString(mapName, setting, sizeof setting, "auto");
    delete config;
    if (StrEqual(setting, "auto"))
        return -1;
    if (StrEqual(setting, "0"))
        return 0;
    if (StrEqual(setting, "1"))
        return 1;
    LogError("Invalid map setting for %s in %s; expected auto, 0 or 1.", mapName, path);
    return 0;
}

bool IsCoopOnlyMap(SourceKeyValues missions, const char[] mapName) {
    if (missions.IsNull())
        return false;

    bool foundCoop;
    for (SourceKeyValues mission = missions.GetFirstTrueSubKey(); !mission.IsNull(); mission = mission.GetNextTrueSubKey()) {
        SourceKeyValues versus = mission.FindKey("modes/versus");
        bool nativeVersus = !versus.IsNull() && !versus.GetInt("AnneHappyInjected", 0);
        // A map shared by multiple missions must never override native versus I/O.
        if (nativeVersus && ModeContainsMap(versus, mapName))
            return false;
        if (!ModeContainsMap(mission.FindKey("modes/coop"), mapName))
            continue;
        // Also protect maps deliberately omitted from an existing versus list.
        if (mission.GetInt("builtin", 0) || nativeVersus)
            return false;
        foundCoop = true;
    }
    return foundCoop;
}

bool ModeContainsMap(SourceKeyValues mode, const char[] mapName) {
    if (mode.IsNull())
        return false;
    char map[PLATFORM_MAX_PATH];
    for (SourceKeyValues chapter = mode.GetFirstTrueSubKey(); !chapter.IsNull(); chapter = chapter.GetNextTrueSubKey()) {
        chapter.GetString("Map", map, sizeof map);
        if (!map[0])
            chapter.GetString("map", map, sizeof map);
        if (StrEqual(map, mapName, false))
            return true;
    }
    return false;
}

int RewriteOutput(EntityLumpEntry entry, const char[] source, const char[] destination) {
    bool hasActions;
    char key[64], value[2];
    for (int i = 0; i < entry.Length; i++) {
        entry.Get(i, key, sizeof key, value, sizeof value);
        if (StrEqual(key, source, false) && value[0]) {
            hasActions = true;
            break;
        }
    }
    if (!hasActions)
        return 0;

    // Replace only the matching phase. Running both branches can delete the
    // entities that the coop branch needs. Reverse erase preserves duplicate keys.
    for (int i = entry.Length - 1; i >= 0; i--) {
        entry.Get(i, key, sizeof key);
        if (StrEqual(key, destination, false))
            entry.Erase(i);
    }
    int copied;
    for (int i = 0; i < entry.Length; i++) {
        entry.Get(i, key, sizeof key);
        if (StrEqual(key, source, false)) {
            // Keep the entire action byte-for-byte: target, input, parameter,
            // delay, fire count and either comma or ESC separators.
            entry.Update(i, destination);
            copied++;
        }
    }
    // Do not FireEntityOutput("OnCoop"): other plugins use it to detect game mode.
    // ponytail: map-lump I/O only; script-created entities and mode checks need
    // map-specific fixes. No global Director/VScript mode spoofing.
    return copied;
}

public Action Command_Status(int args) {
    PrintToServer("[CoopVersusCompat] %s", g_sStatus);
    PrintToServer("[CoopVersusCompat] Reload the map after changing the cvar/config or loading the plugin.");
    return Plugin_Handled;
}
