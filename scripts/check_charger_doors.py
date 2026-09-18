#!/usr/bin/env python3
"""Exercise the actual Charger door handler with engine/trace stubs (requires c++)."""

from pathlib import Path
import subprocess
import tempfile

from check_ai_landing_path import cpp, function


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/sourcemod/scripting/optional/AnneHappy/ai_charger3/ai_charger3.sp"


def main():
    source = SOURCE.read_text()
    command = function(source.replace("public Action", "Action"), "OnPlayerRunCmd")
    interception = "if (tryClawBlockingDoor(client, buttons, vel, angles))\n\t\treturn Plugin_Changed;"
    assert command.index("if (!isAiCharger(client))") < command.index(interception)
    assert command.index(interception) < command.index(".update(buttons, vel, angles)")
    bodies = function(source, "chargerDoorTraceFilter").replace("any client", "int client")
    bodies += "\n" + function(source, "tryClawBlockingDoor")
    harness = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
#include <vector>
using Vec = std::array<float, 3>;
constexpr int MaxClients = 4, Prop_Data = 0, MOVETYPE_LADDER = 9;
constexpr int IN_ATTACK = 1, IN_JUMP = 2, IN_DUCK = 4, IN_FORWARD = 8;
constexpr int IN_BACK = 16, IN_MOVELEFT = 512, IN_MOVERIGHT = 1024;
constexpr int IN_LEFT = 128, IN_RIGHT = 256, IN_ATTACK2 = 2048;
constexpr int CH_STATE_APPROACH = 1, MASK_SHOT = 123, RayType_EndPoint = 0;
constexpr int DOOR_FLAG_UNBREAKABLE = 524288;
const Vec NULL_VECTOR{};
bool grounded = true, charging = false, pinning = false, staggering = false;
int moveType = 0, queuedVictim = 0, traces = 0, turns = 0, resets = 0, cooldowns = 0;
Vec velocity{}, eye{0, 0, 64}, facing{};
float clawRange = 70;
struct State { int id = 2; void transitionTo(int value) { id = value; } };
State g_ChargerStateContext[MaxClients + 1];
struct Entity { int id; const char *name; Vec pos; int flags = 0; };
std::vector<Entity> entities;
int GetEntityMoveType(int) { return moveType; }
bool IsClientOnGround(int) { return grounded; }
bool isChargerCharging(int) { return charging; }
bool IsPinningSurvivor(int) { return pinning; }
bool IsValidSurvivor(int id) { return id > 0 && id <= MaxClients; }
int L4D2_GetQueuedPummelVictim(int) { return queuedVictim; }
bool L4D_IsPlayerStaggering(int) { return staggering; }
void GetEntPropVector(int, int, const char *, Vec &out) { out = velocity; }
float getVectorLength2D(const Vec &v) { return std::hypot(v[0], v[1]); }
void GetClientEyePosition(int, Vec &out) { out = eye; }
void GetAngleVectors(const Vec &a, Vec &forward, Vec &right, const Vec &) {
    float yaw = a[1] * 3.14159265f / 180;
    forward = {std::cos(yaw), std::sin(yaw), 0};
    right = {std::sin(yaw), -std::cos(yaw), 0};
}
void ScaleVector(Vec &v, float scale) { for (auto &x : v) x *= scale; }
void AddVectors(const Vec &a, const Vec &b, Vec &out) {
    for (int i = 0; i < 3; ++i) out[i] = a[i] + b[i];
}
float NormalizeVector(const Vec &v, Vec &out) {
    float length = std::sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    out = v; if (length > 0) ScaleVector(out, 1/length); return length;
}
float getChargerClawRange() { return clawRange; }
struct Trace { int id = -1; };
using Handle = Trace *;
Handle TR_TraceRayFilterEx(const Vec &start, const Vec &end, int mask, int type,
                          bool (*filter)(int, int, int), int client) {
    assert(mask == MASK_SHOT && type == RayType_EndPoint); ++traces;
    Vec dir{}; for (int i = 0; i < 3; ++i) dir[i] = end[i] - start[i];
    float nearest = NormalizeVector(dir, dir);
    auto *result = new Trace;
    for (auto &e : entities) {
        if (!filter(e.id, mask, client)) continue;
        Vec delta{}; float projection = 0;
        for (int i = 0; i < 3; ++i) { delta[i] = e.pos[i] - start[i]; projection += delta[i]*dir[i]; }
        float offset = 0;
        for (int i = 0; i < 3; ++i) offset += std::pow(delta[i] - projection*dir[i], 2);
        if (projection >= 0 && projection <= nearest && offset < 0.01f) {
            nearest = projection; result->id = e.id;
        }
    }
    return result;
}
bool TR_DidHit(Handle trace) { return trace->id >= 0; }
int TR_GetEntityIndex(Handle trace) { return trace->id; }
bool IsValidEntity(int id) { for (auto &e : entities) if (e.id == id) return true; return false; }
void GetEntityClassname(int id, char *out, int size) {
    for (auto &e : entities) if (e.id == id) { std::strncpy(out, e.name, size); return; }
    assert(false);
}
int L4D_GetDoorFlag(int id) { for (auto &e : entities) if (e.id == id) return e.flags; assert(false); return 0; }
void AIPathMovement_Reset(int) { ++resets; }
void GetVectorAngles(const Vec &dir, Vec &out) {
    out = {0, std::atan2(dir[1], dir[0]) * 180 / 3.14159265f, 0};
}
void TeleportEntity(int, const Vec &, const Vec &a, const Vec &) { facing = a; ++turns; }
void setForwardBhopInput(int &buttons, bool startJump) {
    assert(!startJump);
    buttons &= ~(IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_LEFT | IN_RIGHT | IN_JUMP | IN_DUCK);
    buttons |= IN_FORWARD;
}
void setChargerAbilityCooldown(int, float duration) { assert(duration == 1); ++cooldowns; }
'''
    tests = r'''
void reset() {
    grounded = true; charging = pinning = staggering = false;
    moveType = queuedVictim = traces = turns = resets = cooldowns = 0;
    velocity = {}; clawRange = 70; g_ChargerStateContext[1].id = 2;
    entities = {{5, "prop_door_rotating", {40, 0, 64}}};
}
bool run(bool expected, Vec &move, Vec &angles) {
    int buttons = IN_ATTACK | IN_JUMP | IN_DUCK | IN_MOVELEFT;
    const int originalButtons = buttons;
    Vec originalMove = move, originalAngles = angles;
    bool result = tryClawBlockingDoor(1, buttons, move, angles);
    assert(result == expected);
    if (result) {
        assert(buttons & IN_ATTACK2);
        assert(!(buttons & (IN_ATTACK | IN_JUMP | IN_DUCK)));
        assert(g_ChargerStateContext[1].id == CH_STATE_APPROACH);
        assert(turns == 1 && resets == 1 && cooldowns == 1);
    } else {
        assert(buttons == originalButtons && move == originalMove && angles == originalAngles);
        assert(turns == 0 && resets == 0 && cooldowns == 0);
        assert(g_ChargerStateContext[1].id == 2);
    }
    return result;
}
int main() {
    Vec move{}, angles{};
    // The door itself is detected; no survivor visibility input is required.
    reset(); entities.push_back({1, "player", {0,0,64}}); run(true, move, angles);
    reset(); entities[0].pos[0] = 80; run(false, move, angles); // Beyond claw reach.
    reset(); entities[0].pos[0] = 70; run(true, move, angles); // Exact range boundary.
    reset(); clawRange = 30; run(false, move, angles); // Uses actual weapon range.
    reset(); entities[0].name = "prop_door_rotating_checkpoint"; run(false, move, angles);
    reset(); entities[0].flags = DOOR_FLAG_UNBREAKABLE; run(false, move, angles);
    reset(); entities[0].name = "prop_dynamic"; run(false, move, angles);
    reset(); entities.clear(); run(false, move, angles); // Door broken/opened out of the way.
    // The first obstruction wins; no punching through walls, people, or props.
    for (int blocker : {0, 2, 6}) {
        reset(); entities.push_back({blocker, "obstacle", {20,0,64}}); run(false, move, angles);
    }
    for (int gate = 0; gate < 7; ++gate) {
        reset();
        if (gate == 0) grounded = false;
        if (gate == 1) moveType = MOVETYPE_LADDER;
        if (gate == 2) charging = true;
        if (gate == 3) pinning = true;
        if (gate == 4) queuedVictim = 2;
        if (gate == 5) staggering = true;
        if (gate == 6) velocity = {51,0,0};
        run(false, move, angles); assert(traces == 0);
    }
    // Nav movement can differ from aim. Turning must preserve its world direction.
    reset(); entities[0].pos = {0,40,64}; move = {0,-220,0};
    run(true, move, angles);
    assert(std::abs(angles[1] - 90) < 0.001f && move[0] == 220 && move[1] == 0);
    reset(); entities[0].pos = {40,0,64}; move = {}; angles = {45,0,20};
    run(true, move, angles); assert(angles[0] == 0 && angles[2] == 0);
    std::cout << "Charger door regression checks passed\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="charger-door-check-") as directory:
        path = Path(directory)
        (path / "check.cpp").write_text(harness + cpp(bodies) + tests)
        subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"), "-o", str(path / "check")], check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
