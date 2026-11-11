#!/usr/bin/env python3
"""Exercise ASTT timer termination and map cleanup using production bodies."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/l4d2_Anne_stuck_tank_teleport.sp").read_text()


def function(name):
    start = re.search(rf"^public (?:void|Action) {name}\(", source, re.M).start()
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("public ", "").replace(
        "delete g_hTimerRusher;", "DeleteTimer(g_hTimerRusher);")


# The early stop paths are independent of the survivor-distance calculations.
callback = function("Timer_CheckRusher").split("    if (L4D_IsMissionFinalMap())", 1)[0]
callback += "    return Plugin_Continue;\n}\n"
host = r'''
#include <cassert>
#include <cstdio>
using Handle = int;
using Action = int;
constexpr int null = 0, Plugin_Stop = 0, Plugin_Continue = 1, MaxClients = 4;
bool g_bEnabled, g_bSuccessTeleport;
int g_iTanksCount, g_iRushTimes[5], g_iStuckTimes[5];
float g_LastPos[5][3];
Handle g_hTimerRusher;
bool active[16];
int deletes;
void DeleteTimer(Handle timer) {
    if (!timer) return;
    assert(active[timer]); // The native rejects an already-expired handle.
    active[timer] = false;
    ++deletes;
}
'''
checks = r'''
int main() {
    // Both natural termination paths must clear the saved handle before cleanup.
    for (int scenario = 0; scenario < 2; ++scenario) {
        g_bEnabled = scenario != 0;
        g_iTanksCount = scenario == 0 ? 1 : 0;
        g_hTimerRusher = 1;
        active[1] = true;
        assert(Timer_CheckRusher(1) == Plugin_Stop);
        active[1] = false; // SourceMod closes a timer that returns Plugin_Stop.
        assert(g_hTimerRusher == null);
        OnMapEnd();
        OnMapStart();
    }
    // An active timer is still owned and must be cancelled exactly once.
    g_bEnabled = true;
    g_iTanksCount = 1;
    g_hTimerRusher = 2;
    active[2] = true;
    assert(Timer_CheckRusher(2) == Plugin_Continue);
    assert(g_hTimerRusher == 2);
    OnMapEnd();
    OnMapEnd();
    OnMapStart();
    assert(deletes == 1 && g_hTimerRusher == null && g_iTanksCount == 0);
    puts("PASS: ASTT self-stopped timers and repeated map cleanup");
}
'''
with tempfile.TemporaryDirectory(prefix="astt-timer-check-") as directory:
    path = Path(directory)
    (path / "check.cpp").write_text(host + callback + function("OnMapStart")
                                    + function("OnMapEnd") + checks)
    subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"),
                    "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
