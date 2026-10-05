#!/usr/bin/env python3
"""Exercise the actual normal-throw decision bodies with engine inputs mocked."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from check_rock_lagcomp import ROOT, cpp, function


def main():
    combat = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/ai_tank3/combat.inc").read_text()
    main_source = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/ai_tank3.sp").read_text()
    run_cmd = function(main_source, "OnPlayerRunCmd")
    assert run_cmd.index("Combat_LimitThrowDistance(client, buttons)") < run_cmd.index("rider > 0 || holdMovement || target <= 0")
    bodies = cpp("\n".join(function(combat, name) for name in (
        "Combat_IsNormalRockTarget", "Combat_SelectNormalRockTarget", "Combat_LimitThrowDistance",
    )))
    prelude = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <iostream>
using Vec=std::array<float,3>;
constexpr int MaxClients=5, IN_ATTACK=1, IN_ATTACK2=2048;
struct Cvar { float FloatValue; bool BoolValue=true; };
Cvar g_cvThrowMinDist{200}, g_cvThrowMaxDist{450}, g_cvRockTargetAdjust{1};
struct Tank { bool throwing=false; float rockPendingUntil=0; } g_Tank[6];
Vec pos[6]{};
bool alive[6]{}, visible[6]{}, incap[6]{}, hanging[6]{}, pinned[6]{};
int current=1;
float GetEngineTime() { return 10; }
bool IsValidSurvivor(int c) { return c>=1 && c<=4; }
bool IsPlayerAlive(int c) { return alive[c]; }
bool IsClientIncapped(int c) { return incap[c]; }
bool IsClientHanging(int c) { return hanging[c]; }
bool isPinnedByHunterOrCharger(int c) { return pinned[c]; }
bool clientIsVisibleToClient(int,int c) { assert(c>=1 && c<=4); return visible[c]; }
int Target_GetCurrent(int) { return current; }
void GetClientAbsOrigin(int c,Vec &v) { v=pos[c]; }
float GetVectorDistance(const Vec &a,const Vec &b) {
    float sum=0;for(int i=0;i<3;i++)sum+=(a[i]-b[i])*(a[i]-b[i]);return std::sqrt(sum);
}
'''
    tests = r'''
void reset() {
    g_Tank[5]={}; current=1; g_cvRockTargetAdjust.BoolValue=true;
    for(int c=1;c<=4;c++) {
        pos[c]={float(600+c*100),0,0}; alive[c]=visible[c]=true;
        incap[c]=hanging[c]=pinned[c]=false;
    }
}
bool blocked() {
    int buttons=IN_ATTACK|IN_ATTACK2;
    bool changed=Combat_LimitThrowDistance(5,buttons);
    assert((buttons & IN_ATTACK)!=0);
    assert(changed==((buttons & IN_ATTACK2)==0));
    return changed;
}
int main() {
    reset(); assert(blocked()); // Four distant survivors: keep chasing.
    pos[2]={400,0,0}; assert(!blocked()); // Chase victim is distant, throw victim is in range.
    assert(Combat_SelectNormalRockTarget(5)==2);
    current=0; assert(!blocked()); // No chase victim must not bypass the throw check.
    visible[2]=false; assert(blocked());
    reset(); pos[1]={450,0,0}; assert(!blocked());
    pos[1]={450.1f,0,0}; assert(blocked());
    pos[1]={200,0,0}; assert(!blocked());
    pos[1]={199.9f,0,0}; assert(blocked());
    pos[2]={450,0,0}; assert(!blocked()); // Skip the too-close target and choose an in-range one.
    assert(Combat_SelectNormalRockTarget(5)==2);
    pos[3]={300,0,0}; assert(Combat_SelectNormalRockTarget(5)==3);
    pos[3]={451,0,0}; assert(Combat_SelectNormalRockTarget(5)==2); // Re-select when a target leaves range.
    visible[2]=false; assert(blocked());
    reset(); pos[1]={400,0,250}; assert(blocked()); // Distance includes height.
    reset(); pos[1]={100,0,0}; hanging[1]=true;
    pos[2]={100,0,0}; incap[2]=true;
    pos[3]={100,0,0}; pinned[3]=true;
    pos[4]={450,0,0}; assert(!blocked());
    alive[4]=false; assert(blocked());
    reset(); g_Tank[5].throwing=true; assert(!blocked()); // Never interrupt an active throw.
    reset(); g_Tank[5].rockPendingUntil=11; assert(!blocked()); // Forced anti-block throw.
    g_Tank[5].rockPendingUntil=10; assert(blocked());
    reset(); pos[2]={400,0,0}; g_cvRockTargetAdjust.BoolValue=false;
    assert(blocked()); current=2; assert(!blocked());
    current=0; assert(blocked());
    int buttons=IN_ATTACK; assert(!Combat_LimitThrowDistance(5,buttons) && buttons==IN_ATTACK);
    std::cout << "PASS: 200–450 boundaries, in-range retargeting, visibility, forced/active throws, target modes\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="tank-throw-test-") as directory:
        path = Path(directory) / "throw.cpp"
        path.write_text(prelude + "\n" + bodies + "\n" + tests)
        executable = Path(directory) / "throw"
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", str(path), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
