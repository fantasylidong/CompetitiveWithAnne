#!/usr/bin/env python3
"""Run the actual SourcePawn decision bodies with C++ stubs (requires c++).

Only engine inputs are mocked. This checks landing consumption and bounded path
selection without a game server; full SourcePawn compilation is still required.
"""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
AI = ROOT / "addons/sourcemod/scripting/optional/AnneHappy"


def function(source, name):
    start = re.search(rf"^(?:stock )?(?:bool|void|float|Action) {name}\(", source, re.M).start()
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def cpp(source):
    source = re.sub(
        r"float (\w+(?:\[3\])?(?:,\s*\w+(?:\[3\])?)*)\s*;",
        lambda m: " ".join(
            f"Vec {n[:-3]}{{}};" if n.endswith("[3]") else f"float {n}{{}};"
            for n in re.split(r",\s*", m[1])
        ),
        source,
    )
    source = re.sub(r"const float (\w+)\[3\]", r"const Vec &\1", source)
    source = re.sub(r"float (\w+)\[3\](?=\s*[,)])", r"Vec &\1", source)
    # SourcePawn initializes local scalar variables to zero.
    source = re.sub(r"\b(int|float|bool|Address) (\w+);", r"\1 \2{};", source)
    return source.replace("view_as<", "static_cast<").replace("stock ", "")


def main():
    spitter = (AI / "ai_spitter_3.sp").read_text()
    path = (AI / "ai_tank3/path.inc").read_text()
    setup = (AI / "ai_tank3/setup.inc").read_text()
    command = spitter[spitter.index("public Action OnPlayerRunCmd"):]
    consume = re.search(r"bool owedSpit = [^;]+;", command).group()
    # The real command must consume before either grounded early-return branch.
    assert command.index(consume) < command.index("if (onLadder)")
    assert command.index(consume) < command.index("if (buttons & IN_ATTACK)")
    assert "&& owedSpit && hasSight && spitReadyToFire(spitter)" in command
    constants = "\n".join(
        line for line in (spitter + setup).splitlines()
        if re.match(r"#define (SPIT_OWE_TTL|PATH_LOOKAHEAD_\w+|JUMP_HEIGHT|TANK_HOP_MAX_DROP|HULL_CENTER_HEIGHT)\s", line)
    )
    declarations = "\n".join(
        line for line in setup.splitlines()
        if re.match(r"int\s+g_iPathTrace", line)
    )
    bodies = "\n".join(function(spitter, n) for n in ("spitOweMark", "spitOweClear", "spitOweTake"))
    bodies += "\n" + "\n".join(function(path, n) for n in ("Path_AcquireTraceBudget", "Path_GetLookAhead"))
    harness = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
using Vec = std::array<float, 3>;
using Address = int;
constexpr int MAXPLAYERS = 4, MaxClients = MAXPLAYERS;
float now = 10.0f, spitOweTime[MAXPLAYERS + 1]{};
int tick = 1;
float GetGameTime() { return now; }
int GetGameTickCount() { return tick; }
float FloatAbs(float x) { return std::abs(x); }
enum AnneNextBotPathSegmentType {
    AnneNextBotPathSegment_OnGround, AnneNextBotPathSegment_DropDown,
    AnneNextBotPathSegment_ClimbUp, AnneNextBotPathSegment_LadderUp
};
struct PathInfo { bool fresh = true; int currentIndex = 0, count = 0; } g_TankPath[MAXPLAYERS + 1];
struct Segment { Vec pos; bool blocked; int type = AnneNextBotPathSegment_OnGround; };
std::vector<Segment> paths[MAXPLAYERS + 1];
int traces[MAXPLAYERS + 1]{};
bool Path_ReadSegment(int client, int index, Vec &goal, int &type, Address &area) {
    if (index < 0 || index >= int(paths[client].size())) return false;
    goal = paths[client][index].pos; type = paths[client][index].type; area = 0;
    return true;
}
float AIPathMovement_GetDistance2D(const Vec &a, const Vec &b) {
    return std::hypot(a[0] - b[0], a[1] - b[1]);
}
struct Trace { bool blocked; };
using Handle = Trace *;
constexpr int MASK_PLAYERSOLID = 0, AIPathMovement_TraceFilter = 0;
Handle TR_TraceHullFilterEx(const Vec &, Vec end, const Vec &, const Vec &, int, int, int client) {
    ++traces[client]; end[2] -= HULL_CENTER_HEIGHT;
    for (const auto &segment : paths[client])
        if (segment.pos[0] == end[0] && segment.pos[1] == end[1]) return new Trace{segment.blocked};
    assert(false); return nullptr;
}
bool TR_DidHit(Handle trace) { return trace->blocked; }
'''
    tests = r'''
void setPath(int client, std::initializer_list<Segment> segments) {
    paths[client] = segments; g_TankPath[client].count = paths[client].size();
    traces[client] = 0;
}
int main() {
    // Airborne records survive until landing, then cannot leak to another hop.
    spitOweMark(1);
    assert(!consumeLanding(1, false) && spitOweTime[1] == 10.0f);
    now = 10.05f;
    assert(consumeLanding(1, true)); // Simulate a landing with no sight/cooldown ready.
    assert(spitOweTime[1] == 0.0f);
    now = 10.83f;
    assert(!consumeLanding(1, true)); // Sight returns on the next hop: no old attack.
    spitOweMark(1); now += 0.1f;
    assert(consumeLanding(1, true)); // Valid first landing still gets its re-press.
    assert(!consumeLanding(1, true)); // Grounded early returns cannot preserve it.
    spitOweMark(1); now += 1.1f;
    assert(!consumeLanding(1, true) && spitOweTime[1] == 0.0f);
    spitOweMark(1); now -= 2.0f;
    assert(!consumeLanding(1, true) && spitOweTime[1] == 0.0f);

    Vec pos{}, out{};
    // Three blocked far points must not hide the one reachable near point.
    setPath(1, {{{64,0,0},false}, {{128,0,0},true}, {{192,0,0},true}, {{256,0,0},true}});
    assert(Path_GetLookAhead(1, pos, 400, 10, out) && out[0] == 64);
    // A consumes its full budget; B still gets its own reachable path this tick.
    ++tick;
    setPath(1, {{{64,0,0},false}, {{128,0,0},false}, {{192,0,0},false}, {{256,0,0},false}});
    setPath(2, {{{64,0,0},false}});
    assert(Path_GetLookAhead(1, pos, 400, 10, out) && out[0] == 192);
    assert(traces[1] == PATH_LOOKAHEAD_TRACE_BUDGET);
    assert(!Path_GetLookAhead(1, pos, 400, 10, out));
    assert(traces[1] == PATH_LOOKAHEAD_TRACE_BUDGET);
    assert(Path_GetLookAhead(2, pos, 400, 10, out) && traces[2] == 1);
    ++tick;
    assert(Path_GetLookAhead(1, pos, 400, 10, out)); // Budget refreshes next tick.
    // Too-close nodes use no traces; a blocked nearest usable node is rejected.
    ++tick;
    setPath(1, {{{16,0,0},false}, {{64,0,0},false}});
    assert(Path_GetLookAhead(1, pos, 400, 10, out) && out[0] == 64 && traces[1] == 1);
    ++tick;
    setPath(1, {{{64,0,0},true}});
    assert(!Path_GetLookAhead(1, pos, 400, 10, out));
    ++tick;
    setPath(1, {{{64,0,0},false,AnneNextBotPathSegment_LadderUp}});
    assert(!Path_GetLookAhead(1, pos, 400, 10, out) && traces[1] == 0);
    // A known ordinary drop can supply a launch direction; air correction and
    // deep/unknown cliffs still cannot take it as an ordinary flat waypoint.
    ++tick;
    setPath(1, {{{180,0,-200},false,AnneNextBotPathSegment_DropDown}});
    assert(!Path_GetLookAhead(1, pos, 500, 10, out));
    assert(Path_GetLookAhead(1, pos, 500, 10, out, true) && out[2] == -200);
    ++tick;
    setPath(1, {{{180,0,-300},false,AnneNextBotPathSegment_DropDown}});
    assert(!Path_GetLookAhead(1, pos, 500, 10, out, true));
    ++tick;
    setPath(1, {{{180,0,-200},true,AnneNextBotPathSegment_DropDown}});
    assert(!Path_GetLookAhead(1, pos, 500, 10, out, true));
    std::cout << "PASS: landing consumption, path fallback, per-Tank budget and limits\n";
}
'''
    source = constants + "\n" + harness + "\n" + declarations + "\n" + cpp(bodies)
    source += "\nbool consumeLanding(int spitter, bool onGround) { " + consume + " return owedSpit; }\n"
    with tempfile.TemporaryDirectory(prefix="anne-ai-check-") as directory:
        src = Path(directory) / "check.cpp"
        binary = Path(directory) / "check"
        src.write_text(source + tests)
        subprocess.run(["c++", "-std=c++17", str(src), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
