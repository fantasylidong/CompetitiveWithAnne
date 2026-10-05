#!/usr/bin/env python3
"""Run the actual campaign and Confogl medkit handlers against engine mocks."""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/sourcemod/scripting/confoglcompmod/WeaponInformation.sp"


def check_confogl():
    source = SOURCE.read_text()
    function = re.search(r"static void WI_ReplaceExtra\(.*?\n}\n", source, re.S)
    assert function, "WI_ReplaceExtra definition not found"
    defines = re.findall(
        r"^#define\s+(?:WEAPON_REMOVE_INDEX|WEAPON_FIRST_AID_KIT_INDEX|"
        r"WEAPON_PAIN_PILLS_INDEX|NUM_OF_WEAPONS|WEAPON_NUMBER_OF_START_KITS)\s+-?\d+",
        source,
        re.M,
    )
    assert len(defines) == 5
    harness = "\n".join(defines) + r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>

#define DEBUG_WI 0
const int Prop_Send = 0, ReplacementIndex = 0;
const int MAX_ENTITY_NAME_LENGTH = 128, MOVETYPE_NONE = 0;
const float NULL_VECTOR[3] = {};
int Weapon_Attributes[NUM_OF_WEAPONS][1] = {};
bool Weapon_bConvar[NUM_OF_WEAPONS] = {};
bool Weapon_bReplaceStartKits, Weapon_bReplaceFinaleKits, Weapon_bRemoveExtraItems;
int Weapon_iKitCount;
struct KitSlots {
    std::array<int, WEAPON_NUMBER_OF_START_KITS> values{};
    int& operator[](int index) { return values.at(index); }
} Weapon_iKitEntity;
const char* Weapon_Spawns[NUM_OF_WEAPONS] = {};
const char* SPAWN_PREFIX = "weapon_";
const char* SPAWN_SURFIX = "_spawn";
float Weapon_fMapOrigin_Start[3] = {}, Weapon_fMapOrigin_End[3] = {1000, 0, 0};
float Weapon_fMapDist_Start = 100, Weapon_fMapDist_StartExtra = 150, Weapon_fMapDist_End = 100;
struct Entity { float position[3] = {}; bool killed = false; } entities[128];
int created;
bool finale;
void KillEntity(int id) { entities[id].killed = true; }
void GetEntPropVector(int id, int, const char*, float out[3]) {
    std::copy_n(entities[id].position, 3, out);
}
float GetVectorDistance(const float a[3], const float b[3]) {
    float sum = 0;
    for (int i = 0; i < 3; ++i) sum += (a[i] - b[i]) * (a[i] - b[i]);
    return std::sqrt(sum);
}
bool L4D_IsMissionFinalMap() { return finale; }
template<typename... Args>
void FormatEx(char* out, int size, const char* format, Args... args) {
    std::snprintf(out, size, format, args...);
}
int CreateEntityByName(const char* name) {
    assert(std::strcmp(name, "weapon_pain_pills_spawn") == 0);
    return 100 + ++created;
}
void TeleportEntity(int id, const float pos[3], const float*, const float*) {
    std::copy_n(pos, 3, entities[id].position);
}
void DispatchSpawn(int) {}
void SetEntityMoveType(int, int) {}
void Reset() {
    for (auto& entity : entities) entity = Entity{};
    for (auto& flag : Weapon_bConvar) flag = false;
    Weapon_iKitEntity = KitSlots{};
    Weapon_iKitCount = created = 0;
    Weapon_bReplaceStartKits = Weapon_bReplaceFinaleKits = Weapon_bRemoveExtraItems = finale = false;
    Weapon_Attributes[WEAPON_FIRST_AID_KIT_INDEX][ReplacementIndex] = WEAPON_REMOVE_INDEX;
    Weapon_Spawns[WEAPON_PAIN_PILLS_INDEX] = "pain_pills";
}
'''
    harness = "#include <algorithm>\n" + harness + function.group() + r'''
int main() {
    // Campaign modes: Confogl keeps map kits for Pure or the saferoom controller.
    Reset();
    for (int id = 1; id <= 8; ++id) WI_ReplaceExtra(id, WEAPON_FIRST_AID_KIT_INDEX);
    entities[9].position[0] = 500;
    entities[10].position[0] = 1000;
    WI_ReplaceExtra(9, WEAPON_FIRST_AID_KIT_INDEX);
    WI_ReplaceExtra(10, WEAPON_FIRST_AID_KIT_INDEX);
    finale = true;
    WI_ReplaceExtra(10, WEAPON_FIRST_AID_KIT_INDEX);
    for (int id = 1; id <= 10; ++id) assert(!entities[id].killed);
    assert(created == 0 && Weapon_iKitCount == 0);

    // AnneHappy: the original start-kit cap, static removal and finale replacement remain.
    Reset();
    Weapon_bConvar[WEAPON_FIRST_AID_KIT_INDEX] = true;
    Weapon_bReplaceFinaleKits = Weapon_bRemoveExtraItems = true;
    for (int id = 1; id <= 8; ++id) WI_ReplaceExtra(id, WEAPON_FIRST_AID_KIT_INDEX);
    for (int id = 1; id <= 4; ++id) assert(!entities[id].killed);
    for (int id = 5; id <= 8; ++id) assert(entities[id].killed);
    assert(Weapon_iKitCount == 4);
    entities[9].position[0] = 500;
    WI_ReplaceExtra(9, WEAPON_FIRST_AID_KIT_INDEX);
    assert(entities[9].killed);
    entities[10].position[0] = 1000;
    finale = true;
    WI_ReplaceExtra(10, WEAPON_FIRST_AID_KIT_INDEX);
    assert(entities[10].killed && created == 1);
}
'''
    run_harness(harness)


def run_harness(harness):
    compiler = shutil.which("c++")
    if not compiler:
        raise SystemExit("A C++ compiler is required")
    with tempfile.TemporaryDirectory(prefix="anne-medkits-") as directory:
        cpp = Path(directory) / "check.cpp"
        binary = Path(directory) / "check"
        cpp.write_text(harness)
        subprocess.run([compiler, "-std=c++17", str(cpp), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


def check_dynamic():
    source = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/l4d2_med_dynamic.sp").read_text()
    names = (
        "ScheduleMedkitScan", "OnConfigsExecuted", "OnMapEnd", "Evt_RoundStart",
        "Evt_PlayerLeftStartArea", "Cmd_ApplyNow", "Timer_RemoveSaferoomMedkits",
        "RemoveSaferoomMedkits", "RemoveMedkitsByClass", "IsEntityInAnySaferoom",
        "GiveMedkitsBasedOnPlayers", "GiveMedkitToClient",
    )
    functions = []
    for name in names:
        match = re.search(r"^(?:public )?(?:void|int|bool|Action) " + name + r"\(.*?\n}\n", source, re.S | re.M)
        assert match, name
        function = match.group().replace("public ", "").replace("const char[]", "const char*")
        function = function.replace("delete g_hScanTimer;", "g_hScanTimer = 0;")
        function = function.replace("null", "0").replace(", _, TIMER_FLAG_NO_MAPCHANGE", ", 0, TIMER_FLAG_NO_MAPCHANGE")
        functions.append(function)
    assert 'Evt_PlayerLeftStartArea, EventHookMode_Post)' in source
    defines = re.findall(r"^#define\s+(?:SLOT_HEAVY_HEALTH|WEAPON_ID_MEDKIT)\s+\d+", source, re.M)
    assert len(defines) == 2
    harness = "\n".join(defines) + r'''
#include <cassert>
#include <cstring>
#include <cstdio>
#include <string>
using Action = int;
using Handle = int;
const int MaxClients = 8, Prop_Send = 0, Prop_Data = 1;
const int Plugin_Handled = 1, Plugin_Stop = 2, TIMER_FLAG_NO_MAPCHANGE = 1;
bool g_bEnable, g_bKitsGiven;
float g_fRemoveDelay = 1.5;
Handle g_hScanTimer;
int created, killed, nextEntity, scheduled;
struct Event { int userid; int GetInt(const char*) { return userid; } };
struct Player { int team = 2, slot = -1; bool alive = true; } players[9];
struct Entity { std::string classname; int owner = 0, weaponID = 0, area = 0; bool valid = false; } entities[512];
bool IsValidEntity(int id) { return id > MaxClients && id < 512 && entities[id].valid; }
bool IsValidClientSurvivor(int id) { return id > 0 && id <= MaxClients && players[id].team == 2; }
bool IsPlayerAlive(int id) { return players[id].alive; }
int GetClientOfUserId(int id) { return id; }
bool StrEqual(const char* a, const char* b) { return std::strcmp(a, b) == 0; }
bool HasEntProp(int, int, const char*) { return true; }
int GetEntProp(int id, int, const char*) { return entities[id].weaponID; }
int GetEntPropEnt(int id, int, const char*) { return entities[id].owner; }
void GetEntPropVector(int id, int, const char*, float out[3]) { out[0] = entities[id].area; }
bool L4D_IsPositionInFirstCheckpoint(float pos[3]) { return pos[0] == 1; }
bool L4D_IsPositionInLastCheckpoint(float pos[3]) { return pos[0] == 2; }
int FindEntityByClassname(int after, const char* classname) {
    for (int id = after + 1; id < 512; ++id)
        if (IsValidEntity(id) && entities[id].classname == classname) return id;
    return -1;
}
void KillEntitySafe(int id) { assert(IsValidEntity(id)); entities[id].valid = false; ++killed; }
int GetPlayerWeaponSlot(int id, int) { return players[id].slot; }
void GetEntityClassname(int id, char* out, int size) { std::snprintf(out, size, "%s", entities[id].classname.c_str()); }
int CreateEntityByName(const char* classname) {
    if (nextEntity == -1) return -1;
    int id = nextEntity++;
    entities[id] = {classname, 0, 0, 1, true}; ++created;
    return id;
}
void RemovePlayerItem(int id, int entity) { assert(players[id].slot == entity); players[id].slot = -1; }
void DispatchSpawn(int) {}
void EquipPlayerWeapon(int id, int entity) { players[id].slot = entity; entities[entity].owner = id; }
template<typename... Args> void Dbg(const char*, Args...) {}
template<typename... Args> void ReplyToCommand(int, const char*, Args...) {}
int CreateTimer(float, Action(*)(Handle), int, int) { return ++scheduled; }
void Reset() {
    for (auto& entity : entities) entity = Entity{};
    for (auto& player : players) player = Player{};
    players[7].alive = false; players[8].team = 1;
    entities[20] = {"weapon_first_aid_kit_spawn", 0, 0, 1, true};
    entities[21] = {"weapon_first_aid_kit_spawn", 0, 0, 2, true};
    entities[22] = {"weapon_first_aid_kit_spawn", 0, 0, 0, true};
    entities[23] = {"weapon_first_aid_kit", 0, 0, 2, true};
    entities[24] = {"weapon_spawn", 0, WEAPON_ID_MEDKIT, 1, true};
    entities[25] = {"weapon_spawn", 0, WEAPON_ID_MEDKIT, 2, true};
    entities[26] = {"weapon_spawn", 0, WEAPON_ID_MEDKIT, 0, true};
    entities[27] = {"weapon_spawn", 0, 1, 1, true};
    entities[28] = {"weapon_first_aid_kit", 5, 0, 1, true}; players[5].slot = 28;
    entities[29] = {"weapon_defibrillator", 6, 0, 1, true}; players[6].slot = 29;
    g_bEnable = g_bKitsGiven = false;
    g_hScanTimer = created = killed = scheduled = 0; nextEntity = 100;
}
'''
    for function in functions:
        harness += function[:function.index("\n{")] + ";\n"
    harness += "\n".join(functions) + r'''
int main() {
    Reset();
    Evt_RoundStart(Event{}, "round_start", false);
    OnConfigsExecuted();
    Evt_PlayerLeftStartArea(Event{1}, "player_left_start_area", false);
    Cmd_ApplyNow(1, 0); Timer_RemoveSaferoomMedkits(0);
    assert(!g_bKitsGiven && !created && !killed && !scheduled);

    // Enabled after round_start: configuration readiness must schedule a scan.
    g_bEnable = true; OnConfigsExecuted();
    assert(g_hScanTimer && scheduled == 1);
    Evt_PlayerLeftStartArea(Event{8}, "player_left_start_area", false);
    assert(!g_bKitsGiven && !killed);
    // A fast first exit cleans the map before issuing six kits (including bots).
    Evt_PlayerLeftStartArea(Event{1}, "player_left_start_area", false);
    assert(g_bKitsGiven && !g_hScanTimer && created == 5 && killed == 6);
    for (int id : {20, 21, 23, 24, 25, 29}) assert(!entities[id].valid);
    for (int id : {22, 26, 27, 28}) assert(entities[id].valid);
    for (int id = 1; id <= 6; ++id) assert(entities[players[id].slot].classname == "weapon_first_aid_kit");
    assert(players[5].slot == 28 && players[7].slot == -1 && players[8].slot == -1);
    Evt_PlayerLeftStartArea(Event{2}, "player_left_start_area", false);
    Cmd_ApplyNow(1, 0); Timer_RemoveSaferoomMedkits(0); OnConfigsExecuted();
    assert(created == 5 && killed == 6 && !g_hScanTimer);
    OnMapEnd(); assert(!g_bKitsGiven && !g_hScanTimer);

    // Normal delayed scan removes only unowned saferoom medkits.
    Reset(); g_bEnable = true;
    Evt_RoundStart(Event{}, "round_start", false);
    Timer_RemoveSaferoomMedkits(g_hScanTimer);
    assert(killed == 5 && !created && !g_hScanTimer && entities[28].valid);
    // Entity allocation failure must not destroy the survivor's old defibrillator.
    nextEntity = -1;
    assert(!GiveMedkitToClient(6) && players[6].slot == 29 && entities[29].valid);
}
'''
    run_harness(harness)


def check_health_floor():
    source = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/server.sp").read_text()
    functions = []
    for name in ("GetSurvivorPermHealth", "SetSurvivorPermHealth", "ApplyHealFloorTo50"):
        match = re.search(r"^(?:stock )?(?:void|int)\s+" + name + r"\(.*?\n}\n", source, re.M | re.S)
        assert match, name
        functions.append(match.group().replace("stock ", ""))
    harness = r'''
#include <cassert>
#include <cstring>
const int MaxClients = 7, Prop_Send = 0;
struct Player { int hp, revives = 2; bool thirdStrike = true, goingToDie = true, alive = true, survivor = true; } players[8];
bool IsSurvivor(int id) { return players[id].survivor; }
bool IsPlayerAlive(int id) { return players[id].alive; }
int GetEntProp(int id, int, const char*) { return players[id].hp; }
void SetEntProp(int id, int, const char* name, int value) {
    if (!std::strcmp(name, "m_iHealth")) players[id].hp = value;
    else if (!std::strcmp(name, "m_currentReviveCount")) players[id].revives = value;
    else if (!std::strcmp(name, "m_bIsOnThirdStrike")) players[id].thirdStrike = value;
    else if (!std::strcmp(name, "m_isGoingToDie")) players[id].goingToDie = value;
    else assert(false);
}
'''
    harness += "\n".join(functions) + r'''
int main() {
    const int before[] = {0, 0, 1, 49, 50, 80, 0, 10};
    for (int id = 1; id <= MaxClients; ++id) players[id].hp = before[id];
    players[6].alive = false; players[7].survivor = false;
    ApplyHealFloorTo50();
    for (int id = 1; id <= 5; ++id) {
        assert(players[id].hp == (before[id] < 50 ? 50 : before[id]));
        assert(!players[id].revives && !players[id].thirdStrike && !players[id].goingToDie);
    }
    for (int id : {6, 7}) {
        assert(players[id].hp == before[id] && players[id].revives == 2);
        assert(players[id].thirdStrike && players[id].goingToDie);
    }
}
'''
    run_harness("#include <initializer_list>\n" + harness)


if __name__ == "__main__":
    check_confogl()
    check_dynamic()
    check_health_floor()
    print("Campaign checks passed: medkit rules, Pure/AnneHappy isolation, living-survivor health floor and status reset.")
