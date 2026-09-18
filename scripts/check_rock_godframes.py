#!/usr/bin/env python3
"""Run the plugin's actual protection predicate against release-time boundaries."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "addons/sourcemod/scripting/optional/AnneHappy/l4d_rock_lagcomp.sp").read_text()
    start = source.index("bool IsRockDamageAllowed(int rockIndex)")
    end = source.index("\nvoid UpdateRockRenderByRef", start)
    predicate = source[start:end]
    constants = "\n".join(re.findall(r"^#define BLOCK_\w+ \d+$", source, re.M))
    defaults = dict(re.findall(r'CreateConVar\("(sm_rock_(?:release_)?godframes)", "([\d.]+)"', source))
    assert 'Set(index, -1.0, BLOCK_RELEASE_TIME)' in source
    assert 'Set(rockIndex, GetGameTime(), BLOCK_RELEASE_TIME)' in source
    harness = r'''
#include <cassert>
#include <iostream>
CONSTANTS
struct { float FloatValue; } g_cvRockGodframes{@FALLBACK@}, g_cvRockReleaseGodframes{@RELEASE@};
struct {
    float data[2][BLOCK_COUNT]{};
    float Get(int row, int col) { return data[row][col]; }
} g_aRockEntities;
float now;
float GetGameTime() { return now; }
PREDICATE
int main() {
    auto &rock = g_aRockEntities.data[0];
    rock[BLOCK_SPAWN_TIME] = 0.0f;
    rock[BLOCK_RELEASE_TIME] = -1.0f;
    now = 1.69f; assert(!IsRockDamageAllowed(0));
    now = 1.7f; assert(IsRockDamageAllowed(0)); // Missing release still expires.
    rock[BLOCK_RELEASE_TIME] = 1.0f;
    now = 1.149f; assert(!IsRockDamageAllowed(0));
    now = 1.151f; assert(IsRockDamageAllowed(0)); // Does not wait for spawn fallback.
    rock[BLOCK_RELEASE_TIME] = 2.0f;
    now = 2.149f; assert(!IsRockDamageAllowed(0)); // Late release gets its own window.
    now = 2.151f; assert(IsRockDamageAllowed(0));
    rock[BLOCK_RELEASE_TIME] = 0.0f; // Release at map time zero is valid.
    now = 0.0f; assert(!IsRockDamageAllowed(0));
    now = 0.15f; assert(IsRockDamageAllowed(0)); // Exact boundary.
    g_cvRockReleaseGodframes.FloatValue = 0.0f;
    now = 0.0f; assert(IsRockDamageAllowed(0)); // Explicit opt-out.
    g_cvRockReleaseGodframes.FloatValue = 0.15f;
    g_cvRockGodframes.FloatValue = 0.0f;
    rock[BLOCK_RELEASE_TIME] = -1.0f; assert(IsRockDamageAllowed(0));
    rock[BLOCK_RELEASE_TIME] = 0.0f; assert(!IsRockDamageAllowed(0));
    g_aRockEntities.data[1][BLOCK_RELEASE_TIME] = 1.0f;
    now = 1.05f;
    assert(IsRockDamageAllowed(0) && !IsRockDamageAllowed(1)); // Per-rock timestamps.
    std::cout << "PASS: rock release protection, fallback, zero-time release, opt-out and independent rocks\n";
}
'''
    harness = harness.replace("CONSTANTS", constants).replace("PREDICATE", predicate)
    harness = harness.replace("@FALLBACK@", defaults["sm_rock_godframes"] + "f")
    harness = harness.replace("@RELEASE@", defaults["sm_rock_release_godframes"] + "f")
    compiler = shutil.which("c++")
    if not compiler:
        raise SystemExit("A C++ compiler is required")
    with tempfile.TemporaryDirectory(prefix="rock-godframes-") as tmp:
        src, exe = Path(tmp) / "check.cpp", Path(tmp) / "check"
        src.write_text(harness)
        subprocess.run([compiler, "-std=c++17", str(src), "-o", str(exe)], check=True)
        subprocess.run([str(exe)], check=True)


if __name__ == "__main__":
    main()
