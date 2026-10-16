#!/usr/bin/env python3
"""Exercise throw timing and release ballistics with engine inputs mocked."""
from pathlib import Path
import re
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
        "Combat_SolveThrowPitch", "L4D_TankRock_OnRelease",
    )))
    bodies = bodies.replace("public ", "").replace("null", "nullptr")
    bodies = re.sub(r"\b(throwForce|svGravity)\.", r"\1->", bodies)
    bodies = re.sub(r"\blog\b", "logger", bodies).replace("logger.", "logger->")
    setup = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/ai_tank3/setup.inc").read_text()
    constants = "\n".join(line for line in setup.splitlines()
                          if re.match(r"#define (DEFAULT_THROW_FORCE|DEFAULT_SV_GRAVITY|PLAYER_CHEST)\s", line))
    prelude = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
using Vec=std::array<float,3>;
enum Action { Plugin_Continue, Plugin_Changed };
constexpr int MaxClients=5, IN_ATTACK=1, IN_ATTACK2=2048;
constexpr int Prop_Data=0;
constexpr auto NULL_VECTOR=nullptr;
struct Cvar { float FloatValue; bool BoolValue=true; };
Cvar g_cvThrowMinDist{200}, g_cvThrowMaxDist{450}, g_cvRockTargetAdjust{1}, g_cvEnable{1};
Cvar throwForce{DEFAULT_THROW_FORCE}, gravity{DEFAULT_SV_GRAVITY};
using ConVar=Cvar *;
ConVar FindConVar(const char *name) { return std::strcmp(name,"z_tank_throw_force")==0?&throwForce:&gravity; }
struct Logger { template<class... Args> void debugAll(const char *,Args...) {} };
Logger *logger=nullptr;
struct Tank { bool throwing=false; float rockPendingUntil=0; int rockAimUser=0; } g_Tank[6];
Vec pos[6]{}, targetVelocity[6]{};
float gravityScale=1;
bool alive[6]{}, visible[6]{}, incap[6]{}, hanging[6]{}, pinned[6]{};
int current=1;
float GetEngineTime() { return 10; }
int GetClientOfUserId(int id) { return id; }
bool isAiTank(int c) { return c==5; }
bool IsValidEntity(int entity) { return entity==10; }
bool HasEntProp(int,int,const char *) { return true; }
float GetEntPropFloat(int,int,const char *) { return gravityScale; }
void GetEntPropVector(int c,int,const char *,Vec &v) { v=targetVelocity[c]; }
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
float AIPathMovement_GetDistance2D(const Vec &a,const Vec &b) { return std::hypot(a[0]-b[0],a[1]-b[1]); }
float SquareRoot(float x) { return std::sqrt(x); }
float ArcTangent(float x) { return std::atan(x); }
float ArcTangent2(float y,float x) { return std::atan2(y,x); }
float RadToDeg(float x) { return x*180.0f/3.14159265358979323846f; }
float DegToRad(float x) { return x*3.14159265358979323846f/180.0f; }
float Cosine(float x) { return std::cos(x); }
void MakeVectorFromPoints(const Vec &a,const Vec &b,Vec &v) { for(int i=0;i<3;i++)v[i]=b[i]-a[i]; }
float NormalizeVector(const Vec &a,Vec &v) {
    float n=GetVectorDistance(a,Vec{});for(int i=0;i<3;i++)v[i]=n>0?a[i]/n:0;return n;
}
void ScaleVector(Vec &v,float scale) { for(float &value:v)value*=scale; }
void GetAngleVectors(const Vec &angles,Vec &forward,std::nullptr_t,std::nullptr_t) {
    float pitch=DegToRad(angles[0]), yaw=DegToRad(angles[1]);
    forward={std::cos(pitch)*std::cos(yaw),std::cos(pitch)*std::sin(yaw),-std::sin(pitch)};
}
'''
    tests = r'''
void reset() {
    g_Tank[5]={}; current=1; g_cvRockTargetAdjust.BoolValue=true;
    g_cvEnable.BoolValue=true; gravityScale=1;
    for(int c=1;c<=4;c++) {
        pos[c]={float(600+c*100),0,0}; alive[c]=visible[c]=true;
        incap[c]=hanging[c]=pinned[c]=false;
        targetVelocity[c]={};
    }
}
bool blocked() {
    int buttons=IN_ATTACK|IN_ATTACK2;
    bool changed=Combat_LimitThrowDistance(5,buttons);
    assert((buttons & IN_ATTACK)!=0);
    assert(changed==((buttons & IN_ATTACK2)==0));
    return changed;
}
Action release(Vec &velocity,int tank=5) {
    Vec origin{0,0,80}, angles{}, rotation{};
    return L4D_TankRock_OnRelease(tank,10,origin,angles,velocity,rotation);
}
void assertHitsStationaryTarget(const Vec &velocity,int target) {
    assert(velocity[0]>0);
    float time=pos[target][0]/velocity[0];
    assert(std::abs(velocity[1]*time-pos[target][1])<0.1f);
    float height=80+velocity[2]*time-0.5f*gravity.FloatValue*gravityScale*time*time;
    assert(std::abs(height-(pos[target][2]+PLAYER_CHEST))<0.1f);
    assert(std::abs(GetVectorDistance(velocity,Vec{})-throwForce.FloatValue)<0.1f);
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
    // A throw started at 400 must retain ballistics after the target retreats to 600.
    reset(); pos[1]={400,0,0}; assert(!blocked());
    pos[1]={600,0,0}; assert(blocked()); // Still too far to start another throw.
    Vec velocity{};
    assert(release(velocity)==Plugin_Changed);
    assertHitsStationaryTarget(velocity,1);
    // Crossing the lower boundary or having a height difference must not discard aim either.
    pos[1]={150,0,0}; assert(blocked());
    assert(release(velocity)==Plugin_Changed); assertHitsStationaryTarget(velocity,1);
    pos[1]={600,0,120}; assert(blocked());
    assert(release(velocity)==Plugin_Changed); assertHitsStationaryTarget(velocity,1);
    pos[1]={600,0,0}; targetVelocity[1]={0,180,0};
    assert(release(velocity)==Plugin_Changed && velocity[1]>0); // Horizontal lead is still applied.
    // Keep the existing preference for a valid in-range target over a too-close one.
    reset(); pos[1]={100,0,0}; pos[2]={400,100,0};
    assert(release(velocity)==Plugin_Changed); assertHitsStationaryTarget(velocity,2);
    reset(); g_cvRockTargetAdjust.BoolValue=false; current=2;
    assert(release(velocity)==Plugin_Changed); assertHitsStationaryTarget(velocity,2);
    // With no visible valid target, or with a human/disabled Tank, leave native velocity intact.
    reset(); for(int c=1;c<=4;c++)visible[c]=false;
    Vec native{650,20,150}; velocity=native;
    assert(release(velocity)==Plugin_Continue && velocity==native);
    visible[1]=true; hanging[1]=true;
    visible[2]=true; incap[2]=true;
    visible[3]=true; pinned[3]=true;
    visible[4]=true; alive[4]=false;
    assert(release(velocity)==Plugin_Continue && velocity==native);
    reset(); assert(release(velocity,4)==Plugin_Continue && velocity==native);
    g_cvEnable.BoolValue=false;
    assert(release(velocity)==Plugin_Continue && velocity==native);
    // A pending anti-block throw retains its designated target and consumes the plan.
    reset(); pos[1]={400,0,0}; pos[3]={600,100,0}; visible[3]=false;
    g_Tank[5].rockPendingUntil=11; g_Tank[5].rockAimUser=3;
    assert(release(velocity)==Plugin_Changed); assertHitsStationaryTarget(velocity,3);
    assert(g_Tank[5].rockPendingUntil==0 && g_Tank[5].rockAimUser==0);
    std::cout << "PASS: throw boundaries, retargeting, release ballistics outside range, lead, native/forced throws\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="tank-throw-test-") as directory:
        path = Path(directory) / "throw.cpp"
        path.write_text(constants + "\n" + prelude + "\n" + bodies + "\n" + tests)
        executable = Path(directory) / "throw"
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-parameter", str(path), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
