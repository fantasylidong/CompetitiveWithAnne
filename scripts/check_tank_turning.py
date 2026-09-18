#!/usr/bin/env python3
"""Execute Tank movement bodies with mocked engine inputs; no live server needed."""
from pathlib import Path
import re
import subprocess
import tempfile

from check_ai_landing_path import AI, cpp, function


def main():
    movement = (AI / "ai_tank3/movement.inc").read_text()
    shared = (AI / "ai_path_movement.inc").read_text()
    setup = (AI / "ai_tank3/setup.inc").read_text()
    buttons_header = (AI.parents[1] / "sourcemod/include/entity_prop_stocks.inc").read_text()
    constants = "\n".join(line for line in (setup + shared).splitlines() if re.match(
        r"#define (JUMP_HEIGHT|HULL_CENTER_HEIGHT|PATH_GOAL_TOLERANCE_DIST|PATH_LOOKAHEAD_MIN_DIST|"
        r"LADDER_HOP_MARGIN|TANK_HOP_MAX_DROP|TANK_AIR_\w+|AI_PATH_MOVEMENT_\w+)\s", line))
    constants += "\n" + "\n".join(line for line in buttons_header.splitlines() if re.match(
        r"#define IN_(FORWARD|BACK|LEFT|RIGHT|MOVELEFT|MOVERIGHT|DUCK|JUMP)\s", line))
    helpers = ["AIPathMovement_GetHorizontalSpeed", "AIPathMovement_NormalizeHorizontal",
               "AIPathMovement_ClampHorizontalSpeed", "AIPathMovement_VectorAngle",
               "AIPathMovement_PrepareAirCorrection", "AIPathMovement_BuildAirCorrectionVelocity",
               "AIPathMovement_ComputeAirCorrectionToward"]
    functions = ["Movement_Reset", "Movement_AddLegacyImpulse", "Movement_CanDirectChase",
                 "Movement_RotateHorizontal", "Movement_CanStrafe", "Movement_RemainingAirTime",
                 "Movement_IsTurnRouteSafe", "Movement_IsDropHopSafe", "Movement_TrySafeAirCorrection", "Movement_UpdateAirDirection",
                 "Movement_AirControl", "Movement_GroundHop"]
    prelude = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
using Vec = std::array<float, 3>;
constexpr int MaxClients = 4, Prop_Data = 0, Prop_Send = 1,
    MASK_PLAYERSOLID = 0, AIPathMovement_TraceFilter = 0;
constexpr auto NULL_VECTOR = nullptr;
enum Action { Plugin_Continue, Plugin_Changed };
enum TankHopMode { TankHop_None, TankHop_Target, TankHop_Path, TankHop_Velocity };
struct Cvar { float FloatValue; int IntValue = 10; bool BoolValue = true; };
Cvar g_cvDirectChaseMaxAngle{45}, g_cvBhopStrafeAngle{15}, g_cvBhopStrafeMinDist{600},
    g_cvBhopMaxSpeed{800}, g_cvBhopImpulse{60}, g_cvBhopFirstHopRatio{0.6},
    g_cvAirVecModifyDegree{5}, g_cvAirVecModifyMaxDegree{89}, g_cvAirVecModifyInterval{0.3},
    g_cvPathLookAheadMaxDepth{10}, g_cvBhopNoVisionMaxAng{57}, g_cvBhopNoVision{1};
struct Tank {
    TankHopMode hopMode = TankHop_Target;
    float hopStrafeYaw = 0, nextAirThink = 0;
    int lastStrafeSide = 0;
} g_Tank[5];
struct Path { bool fresh = true, reachesTarget = true; float blockHopDist = -1, dropDist = -1, dropLandingZ = 0; } g_TankPath[5];
struct Air { bool active = true; float hopSpeed = 600, maxSpeed = 800, lastCorrectionTime = 0; Vec goal{}; }
    g_AIPathMovementState[5];
float engineTime = 10;
float ceilingHeight = 1000000, highestFoot = 0;
float wallAfterX = 1000000, lastRouteTime = 0;
bool dropScene = false, unsupportedCorner = false;
bool groundAvailable = true, hullBlocked = false, gap = false, blockPositiveY = false,
    landing = false, normalBlocked = false, hasLook = true;
int teleports = 0, lookups = 0, groundChecks = 0;
Vec nextGoal{1000,0,0}, teleported{}, targetVelocity{};
float GetEngineTime() { return engineTime; }
float FloatAbs(float x) { return std::abs(x); }
float SquareRoot(float x) { return std::sqrt(x); }
float Pow(float x, float y) { return std::pow(x,y); }
float DegToRad(float x) { return x * 3.14159265358979323846f / 180; }
float RadToDeg(float x) { return x * 180 / 3.14159265358979323846f; }
float Cosine(float x) { return std::cos(x); }
float Sine(float x) { return std::sin(x); }
float ArcCosine(float x) { return std::acos(x); }
int RoundToCeil(float x) { return int(std::ceil(x)); }
float NormalizeVector(const Vec &v, Vec &out) {
    float n = std::sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);
    out = n > 0 ? Vec{v[0]/n,v[1]/n,v[2]/n} : Vec{}; return n;
}
void ScaleVector(Vec &v, float s) { for (auto &x : v) x *= s; }
void MakeVectorFromPoints(const Vec &a, const Vec &b, Vec &out) {
    out = {b[0]-a[0], b[1]-a[1], b[2]-a[2]};
}
float GetVectorDotProduct(const Vec &a, const Vec &b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
float GetVectorDistance(const Vec &a, const Vec &b) { Vec d; MakeVectorFromPoints(a,b,d); return std::sqrt(GetVectorDotProduct(d,d)); }
float AIPathMovement_GetDistance2D(const Vec &a, const Vec &b) { return std::hypot(a[0]-b[0],a[1]-b[1]); }
bool AIPathMovement_IsPathHopActive(int tank) { return g_AIPathMovementState[tank].active; }
void AIPathMovement_Reset(int tank) { g_AIPathMovementState[tank].active = false; }
void AIPathMovement_UpdateGoal(int tank, const Vec &goal) { g_AIPathMovementState[tank].goal = goal; }
float AIPathMovement_GetJumpAirTime(float) { return 2 * std::sqrt(2 * JUMP_HEIGHT / 750.0f); }
bool AIPathMovement_TryFindGround(int, const Vec &p, float, bool previous, float, float &z) {
    ++groundChecks; z = dropScene && p[0] < 100 ? 200 : 0;
    return groundAvailable && !(unsupportedCorner && previous && p[1] > 0);
}
bool AIPathMovement_HasPotentialGap(int, const Vec &start, const Vec &end, float) {
    assert(start[2] == 0 || dropScene); return gap || (blockPositiveY && end[1] > 1);
}
struct Trace { bool blocked; };
using Handle = Trace *;
Handle TR_TraceHullFilterEx(const Vec &start, const Vec &end, const Vec &mins, const Vec &maxs, int, int, int) {
    assert(mins[0] == -16 && mins[2] == 0 && maxs[0] == 16 && maxs[2] >= 72);
    highestFoot = std::max(highestFoot, std::max(start[2],end[2]));
    return new Trace{hullBlocked || end[0] > wallAfterX || std::max(start[2],end[2]) + maxs[2] > ceilingHeight};
}
bool TR_StartSolid(Handle) { return false; }
bool TR_DidHit(Handle t) { return t->blocked; }
bool Path_GetLookAhead(int, const Vec &, float, int, Vec &goal, bool = false) {
    ++lookups; goal = nextGoal; return hasLook;
}
float Movement_GetRunSpeed(int) { return 225; }
bool AIPathMovement_IsRouteCheckThrottled(int) { return false; }
void AIPathMovement_MarkRouteCheckFailure(int) {}
bool AIPathMovement_IsLandingHop(int) { return landing; }
float AIPathMovement_GetHopImpulse(int, float impulse, float ratio) { return impulse * (landing ? 1 : ratio); }
void AIPathMovement_BeginPathHop(int tank, const Vec &goal, float speed, float cap) {
    g_AIPathMovementState[tank] = {true,speed,cap,engineTime,goal}; landing = false;
}
void GetEntPropVector(int, int, const char *name, Vec &out) {
    if (!std::strcmp(name, "m_vecMins")) out = {-16,-16,0};
    else if (!std::strcmp(name, "m_vecMaxs")) out = {16,16,72};
    else out = targetVelocity;
}
int GetRandomInt(int, int) { return 1; }
bool AIPathMovement_IsJumpRouteSafe(int, const Vec &, float time, float drop, bool, float) {
    lastRouteTime = time; return !normalBlocked && !(dropScene && drop <= JUMP_HEIGHT);
}
void TeleportEntity(int, std::nullptr_t, std::nullptr_t, const Vec &v) { teleported = v; ++teleports; }
'''
    tests = r'''
void reset() {
    engineTime += 1; groundAvailable = hasLook = true;
    hullBlocked = gap = blockPositiveY = landing = normalBlocked = false;
    teleports = lookups = groundChecks = 0; nextGoal = {1000,0,0};
    ceilingHeight = 1000000; highestFoot = 0;
    dropScene = unsupportedCorner = false; wallAfterX = 1000000; lastRouteTime = 0;
    g_Tank[1] = Tank{}; g_TankPath[1] = Path{}; g_AIPathMovementState[1] = Air{};
}
int main() {
    Vec out{}, pos{0,0,40}, velocity{600,0,0}, target{1000,200,0};
    int buttons = IN_FORWARD;
    // Legacy sideways controls add lateral impulse without changing vertical speed.
    Movement_AddLegacyImpulse(IN_MOVELEFT, {300,0,25}, {1,0,0}, 60, out);
    assert(out[0] == 300 && out[1] == 60 && out[2] == 25);
    Movement_AddLegacyImpulse(IN_MOVERIGHT, {300,0,25}, {1,0,0}, 60, out);
    assert(out[1] == -60);
    Movement_AddLegacyImpulse(IN_MOVELEFT|IN_MOVERIGHT, {300,0,25}, {1,0,0}, 60, out);
    assert(out[1] == 0);
    Movement_AddLegacyImpulse(IN_LEFT|IN_RIGHT, {300,0,25}, {1,0,0}, 60, out);
    assert(out[1] == 0);

    // An 11-degree target movement now changes velocity smoothly and retains Z.
    reset();
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true) == Plugin_Changed);
    assert(teleported[1] > 0 && teleported[1] < 120 && teleported[2] == 0);
    assert(AIPathMovement_GetHorizontalSpeed(teleported) <= 800);
    int calls = groundChecks;
    Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true);
    assert(groundChecks == calls); // Multiple commands in a tick do not retrace.

    // Path hop has passed its original point; a fresh forward turn replaces it.
    reset(); g_Tank[1].hopMode = TankHop_Path;
    g_AIPathMovementState[1].goal = {-100,0,0}; nextGoal = {150,50,0};
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, false) == Plugin_Changed);
    assert(g_AIPathMovementState[1].goal == nextGoal && teleported[1] > 0);
    engineTime += 0.1f; nextGoal = {180,80,0};
    Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, false);
    assert(g_AIPathMovementState[1].goal == nextGoal);
    reset(); g_Tank[1].hopMode = TankHop_Path; g_TankPath[1].fresh = false;
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, false) == Plugin_Continue);
    assert(teleports == 0);

    // Neither a wall nor a gap nor an imminent ladder is accepted as a turn route.
    for (int obstruction = 0; obstruction < 3; ++obstruction) {
        reset(); hullBlocked = obstruction == 0; gap = obstruction == 1;
        if (obstruction == 2) g_TankPath[1].blockHopDist = 80;
        assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true) == Plugin_Continue);
        assert(teleports == 0 && g_AIPathMovementState[1].lastCorrectionTime == 0);
    }
    reset(); groundAvailable = false;
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true) == Plugin_Continue);
    reset(); g_AIPathMovementState[1].active = false;
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true) == Plugin_Continue);
    assert(groundChecks == 0); // Engine jumps/falls are untouched.
    // Full standing hull rises above a low ceiling; a center-to-ground ray misses it.
    reset(); ceilingHeight = 100;
    assert(!Movement_IsTurnRouteSafe(1, {0,0,20}, {0,0,0}, {600,0,200}, 0.6));
    assert(highestFoot > 21);
    reset();
    assert(Movement_IsTurnRouteSafe(1, {0,0,0}, {0,0,0}, {600,0,0},
        AIPathMovement_GetJumpAirTime(56), true));
    assert(highestFoot > 55); // Ground side-hop checks the upward half too.

    // Open ground: alternating hop sides; an engine-rejected jump does not flip.
    reset(); pos = {0,0,0}; target = {1000,0,0};
    assert(Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true) == Plugin_Changed);
    assert(teleported[1] > 0 && g_Tank[1].lastStrafeSide == 1);
    assert(g_Tank[1].nextAirThink > engineTime);
    float yaw = g_Tank[1].hopStrafeYaw;
    engineTime += 0.01f;
    Movement_AirControl(1, buttons, {0,0,3}, teleported, 636, target, 1000, true);
    assert(g_Tank[1].hopStrafeYaw == yaw && groundChecks == 0);
    Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true);
    assert(g_Tank[1].hopStrafeYaw == yaw);
    landing = true;
    Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true);
    assert(teleported[1] < 0 && g_Tank[1].lastStrafeSide == -1);
    // A blocked side falls back to normal hopping, and close range has no weave.
    reset(); blockPositiveY = true;
    assert(Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true) == Plugin_Changed);
    assert(teleported[1] == 0 && g_Tank[1].hopStrafeYaw == 0);
    reset(); target = {400,0,0};
    Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true);
    assert(g_Tank[1].hopStrafeYaw == 0);
    // Unsafe air strafe is discarded; the same frame can still follow the target.
    reset(); pos = {0,0,40}; target = {1000,-100,0};
    g_Tank[1].hopStrafeYaw = 15; blockPositiveY = true;
    assert(Movement_AirControl(1, buttons, pos, velocity, 600, target, 1005, true) == Plugin_Changed);
    assert(g_Tank[1].hopStrafeYaw == 0 && teleported[1] < 0);
    // At normal jump apex, ground height (not current Z) keeps a direct hop active.
    reset(); pos = {0,0,60}; target = {1000,200,0}; g_Tank[1].hopStrafeYaw = 15;
    Movement_AirControl(1, buttons, pos, velocity, 600, target, 1020, true);
    assert(g_Tank[1].hopStrafeYaw == 15 && teleported[1] > 0);

    float air = AIPathMovement_GetJumpAirTime(56);
    assert(std::abs(Movement_RemainingAirTime(56,0,air) - air/2) < 0.001f);
    assert(Movement_RemainingAirTime(10,-200,air) < 0.1f);
    assert(Movement_RemainingAirTime(10,200,air) > 0.5f);
    // A path-confirmed 200hu drop preserves forward speed and keeps the landing
    // hop chain. Validate beyond the flat airtime, then coast without air turns.
    reset(); dropScene = true; pos = {0,0,200}; target = {1500,0,0};
    g_TankPath[1].dropDist = 100; nextGoal = {500,0,0};
    assert(Movement_GroundHop(1, buttons, pos, velocity, 600, 2, target, true) == Plugin_Changed);
    assert(teleported[0] > 600 && teleported[1] == 0 && teleported[2] == 0);
    assert(lastRouteTime > air + 0.3f && g_Tank[1].hopMode == TankHop_Velocity);
    calls = groundChecks; engineTime += 0.1f;
    assert(Movement_AirControl(1, buttons, {150,0,230}, {636,0,100}, 636, target, 1300, true) == Plugin_Continue);
    assert(groundChecks == calls);
    dropScene = false; landing = true; g_TankPath[1] = Path{};
    g_cvBhopStrafeAngle.FloatValue = 0;
    assert(Movement_GroundHop(1, buttons, {0,0,0}, {636,0,0}, 636, 2, target, true) == Plugin_Changed);
    assert(std::abs(teleported[0] - 696) < .01f); // Full landing impulse, no startup penalty.

    for (int obstruction = 0; obstruction < 8; obstruction++) {
        reset(); dropScene = true; g_TankPath[1].dropDist = 100;
        if (obstruction == 0) groundAvailable = false;
        if (obstruction == 1) unsupportedCorner = true;
        if (obstruction == 2) wallAfterX = 600; // Beyond a flat hop, inside the real drop flight.
        if (obstruction == 3) ceilingHeight = 300;
        if (obstruction == 4) gap = true;
        if (obstruction == 5) g_TankPath[1].blockHopDist = 650; // Ladder/gap beyond flat reach.
        if (obstruction == 6) g_TankPath[1].fresh = false;
        if (obstruction == 7) g_TankPath[1].dropLandingZ = -100; // 300hu exceeds the safe-drop allowance.
        assert(!Movement_IsDropHopSafe(1, {0,0,200}, {600,0,0}, true));
    }
    std::cout << "PASS: Tank tracking, refreshed path, side impulses, alternating hops, safety and timing\n";
}
'''
    bodies = "\n".join(function(shared, name) for name in helpers)
    bodies += "\n" + "\n".join(function(movement, name) for name in functions)
    with tempfile.TemporaryDirectory(prefix="tank-turning-check-") as directory:
        src = Path(directory) / "check.cpp"
        binary = Path(directory) / "check"
        src.write_text(constants + "\n" + prelude + "\n" + cpp(bodies) + tests)
        subprocess.run(["c++", "-std=c++17", str(src), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
