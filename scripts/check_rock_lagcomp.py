#!/usr/bin/env python3
"""Run rock protection/geometry decision bodies with mocked engine inputs.

Uses the repository's SourcePawn-to-C++ test helper. This is not an SRCDS
integration test; compile the plugin separately and verify native pellets live.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from check_ai_landing_path import cpp


ROOT = Path(__file__).resolve().parents[1]


def function(source, name):
    start = re.search(rf"^(?:public )?(?:bool|void|float|int|Action) {name}\(", source, re.M).start()
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    source = (ROOT / "addons/sourcemod/scripting/optional/AnneHappy/l4d_rock_lagcomp.sp").read_text()
    constants = "\n".join(line for line in source.splitlines() if line.startswith("#define "))
    bodies = "\n".join(function(source, name) for name in (
        "Clamp", "FloatMax", "RayIntersectsSphere", "GetHistoryIndex",
        "GetRollbackTicks", "IsRockDamageAllowed",
        "SeedRockHistory", "GetRockPositionAtTick",
        "IsHitscanWeaponType", "GetHitscanWeaponAttributes", "IsShotgunWeaponName",
        "IsHitscanWeaponName", "IsDistanceAllowed", "ApplyDamageToRock", "OnRockTakeDamage",
    ))
    # Execute the release snapshot statements, using a pre-registered rock.
    release = function(source, "L4D_TankRock_OnRelease_Post")
    release = release[release.index("float protection ="):release.index("SeedRockHistory(rockIndex,")]
    bodies += "\nvoid releaseRock(int tank, int rockIndex, const float vecPos[3], const float vecVel[3]) {\n" + release + "}\n"
    bodies = cpp(bodies).replace("public ", "").replace("null", "nullptr")
    bodies = re.sub(r"const char\[\] (\w+)", r"const char *\1", bodies)
    bodies = re.sub(r"(g_cv\w+)\.", r"\1->", bodies)
    prelude = r'''
#include <array>
#include <cassert>
#include <cmath>
#include <cstring>
#include <iostream>
using Vec = std::array<float, 3>;
enum Action { Plugin_Continue, Plugin_Handled };
enum { WEAPONTYPE_PISTOL=1, WEAPONTYPE_SMG, WEAPONTYPE_RIFLE,
    WEAPONTYPE_SHOTGUN, WEAPONTYPE_SNIPERRIFLE, WEAPONTYPE_MACHINEGUN,
    L4D2IWA_WeaponType, L4D2IWA_Damage, L4D2IWA_Bullets, L4D2FWA_Range,
    L4D2FWA_RangeModifier, Prop_Send, NetFlow_Outgoing };
constexpr int Frame_DetonateRock=0, DMG_BULLET=2, DMG_BUCKSHOT=0x20000000;
struct Cvar { float FloatValue=0; bool BoolValue=true; };
Cvar lag{0,true}, unlag{0.35f}, fallback{1.7f}, nativeShotgun{0,true},
    releaseTime{0.15f}, minRange{1}, maxRange{2000},
    hitbox{0,true}, print{0,false};
Cvar *g_cvRockLagComp=&lag, *g_cvMaxUnlag=&unlag,
    *g_cvRockGodframes=&fallback, *g_cvNativeShotgun=&nativeShotgun,
    *g_cvRockReleaseGodframes=&releaseTime, *g_cvRangeMinAll=&minRange,
    *g_cvRangeMaxAll=&maxRange, *g_cvRockHitbox=&hitbox, *g_cvRockPrint=&print;
struct Records {
    int Length=1;
    float cells[BLOCK_COUNT]{};
    float Get(int i, int block) { assert(i==0); return cells[block]; }
    void Set(int i, float value, int block) { assert(i==0); cells[block]=value; }
} g_aRockEntities;
struct ArrayList {
    static inline float rows[MAX_HISTORY_FRAMES][4]{};
    explicit ArrayList(float handle) { assert(handle==1); }
    float Get(int i,int field) { return rows[i][field]; }
    void Set(int i,float value,int field) { rows[i][field]=value; }
    void SetArray(int i,const Vec &v,int n) { assert(n==3); for(int a=0;a<n;a++)rows[i][a]=v[a]; }
    void GetArray(int i,Vec &v,int n) { assert(n==3); for(int a=0;a<n;a++)v[a]=rows[i][a]; }
};
float now=10, interval=0.01f, latency=0.05f, lerp=0.03f;
bool fake[5]{}, alive[5]{};
Vec positions[5]{};
int team[5]{0,2,2,3,3}, weaponType=WEAPONTYPE_SHOTGUN, requests=0;
bool tracked=true;
float GetGameTime() { return now; }
int GetGameTickCount() { return 1000; }
float GetTickInterval() { return interval; }
float GetClientInterp(int) { return lerp; }
float GetClientLatency(int, int flow) { assert(flow==NetFlow_Outgoing); return latency; }
bool IsFakeClient(int c) { return fake[c]; }
bool IsClientInGame(int c) { return c>0 && c<=4; }
bool IsSurvivor(int c) { return c>0 && c<=4 && team[c]==2; }
bool IsPlayerAlive(int c) { return alive[c]; }
int GetClientTeam(int c) { return team[c]; }
int GetEntProp(int, int, const char *) { return 8; }
void GetClientEyePosition(int c, Vec &v) { v=positions[c]; }
float SquareRoot(float x) { return std::sqrt(x); }
float Pow(float a, float b) { return std::pow(a,b); }
int RoundToNearest(float x) { return std::lround(x); }
int RoundToFloor(float x) { return std::floor(x); }
void SubtractVectors(const Vec &a,const Vec &b,Vec &v) { for(int i=0;i<3;i++)v[i]=a[i]-b[i]; }
float GetVectorDotProduct(const Vec &a,const Vec &b) { return a[0]*b[0]+a[1]*b[1]+a[2]*b[2]; }
float GetVectorLength(const Vec &v,bool squared=false) { float n=GetVectorDotProduct(v,v); return squared?n:std::sqrt(n); }
float GetVectorDistance(const Vec &a,const Vec &b) { Vec v; SubtractVectors(a,b,v);return GetVectorLength(v); }
void NormalizeWeaponName(const char *a,char *b,int) { std::strcpy(b,a); }
bool IsWeaponAttributeReadable(const char *) { return true; }
int L4D2_GetIntWeaponAttribute(const char *,int attr) {
    if(attr==L4D2IWA_WeaponType)return weaponType;
    if(attr==L4D2IWA_Damage)return weaponType==WEAPONTYPE_SHOTGUN?16:24;
    return weaponType==WEAPONTYPE_SHOTGUN?16:1;
}
float L4D2_GetFloatWeaponAttribute(const char *,int attr) { return attr==L4D2FWA_Range?3000:0.745f; }
int EntIndexToEntRef(int e) { return e; }
int EntRefToEntIndex(int e) { return e; }
int FindTrackedRock(int) { return tracked?0:-1; }
bool GetNativeDamageWeaponName(int,int,char *name,int) { std::strcpy(name,"shotgun_chrome");return true; }
void GetEntPropVector(int,int,const char *,Vec &pos) { pos={400,0,0}; }
template<class... T>void PrintToChatAll(T...) {}
void RequestFrame(int,int) { ++requests; }
bool near(float a,float b) { return std::abs(a-b)<0.0001f; }
'''
    tests = r'''
int main() {
    Vec origin{0,0,0}, direction{1,0,0}; float hit;
    assert(RayIntersectsSphere(origin,direction,{100,0,0},30,hit) && near(hit,70));
    assert(!RayIntersectsSphere(origin,direction,{-100,0,0},30,hit));
    assert(!RayIntersectsSphere(origin,direction,{100,31,0},30,hit));
    assert(RayIntersectsSphere(origin,direction,{0,0,0},30,hit) && hit==0);
    // A wall at 60 wins over this intersection at 70.
    assert(RayIntersectsSphere(origin,direction,{100,0,0},30,hit) && hit>60);
    assert(GetHistoryIndex(-1)==99 && GetHistoryIndex(101)==1);
    // Seeding must not invent pre-release samples, and a wrapped slot is invalid.
    g_aRockEntities.Set(0,1,BLOCK_POS_HISTORY);
    SeedRockHistory(0,{20,0,0}); Vec sample;
    assert(GetRockPositionAtTick(0,1000,sample) && sample[0]==400);
    assert(!GetRockPositionAtTick(0,999,sample));
    ArrayList history(1); history.SetArray(99,{100,0,0},3); history.Set(99,999,3);
    assert(GetRockPositionAtTick(0,999,sample) && sample[0]==100);
    history.Set(99,1099,3); assert(!GetRockPositionAtTick(0,999,sample));
    SeedRockHistory(0,{30,0,0}); assert(!GetRockPositionAtTick(0,999,sample));
    assert(GetRollbackTicks(1)==8);
    latency=9; assert(GetRollbackTicks(1)<=35);
    unlag.FloatValue=5; assert(GetRollbackTicks(1)<=99);
    interval=1.0f/30; assert(GetRollbackTicks(1)<=99);
    interval=0.01f; unlag.FloatValue=0.035f; assert(GetRollbackTicks(1)==3);
    unlag.FloatValue=0; assert(GetRollbackTicks(1)==0);
    unlag.FloatValue=0.35f; latency=-1; lerp=0; assert(GetRollbackTicks(1)==0);
    fake[1]=true; latency=9; assert(GetRollbackTicks(1)==0); fake[1]=false;
    lag.BoolValue=false; assert(GetRollbackTicks(1)==0); lag.BoolValue=true;
    g_aRockEntities.Set(0,9,BLOCK_SPAWN_TIME);
    fake[3]=true;
    releaseRock(3,0,origin,{800,0,0});
    assert(ROCK_HEALTH==100);
    assert(!IsRockDamageAllowed(0,10.149f));
    assert(IsRockDamageAllowed(0,10.151f));
    assert(!IsRockDamageAllowed(0,8));
    // Server protection expired, but the historical shot is still protected.
    now=10.3f; assert(!IsRockDamageAllowed(0,now-0.2f));
    releaseTime.FloatValue=0.25f;
    assert(near(g_aRockEntities.Get(0,BLOCK_PROTECTED_UNTIL),10.15f));
    // Player and AI Tanks receive the same duration captured at release.
    now=10; releaseRock(4,0,origin,{1000,0,0});
    assert(near(g_aRockEntities.Get(0,BLOCK_PROTECTED_UNTIL),10.25f));
    float durations[]={0.0f,0.05f,0.10f,0.15f,0.20f,0.25f};
    for(float duration:durations) {
        releaseTime.FloatValue=duration;
        releaseRock(3,0,origin,{800,0,0});
        assert(!IsRockDamageAllowed(0,10+duration-0.001f));
        assert(IsRockDamageAllowed(0,10+duration));
        assert(IsRockDamageAllowed(0,10+duration+0.001f));
    }
    g_aRockEntities.Set(0,-1,BLOCK_RELEASE_TIME);
    assert(!IsRockDamageAllowed(0,10.69f) && IsRockDamageAllowed(0,10.71f));
    fallback.FloatValue=0; assert(!IsRockDamageAllowed(0,8) && IsRockDamageAllowed(0,9));
    float dmg,range,modifier;
    assert(!GetHitscanWeaponAttributes("shotgun_chrome",dmg,range,modifier));
    nativeShotgun.BoolValue=false;
    assert(GetHitscanWeaponAttributes("shotgun_chrome",dmg,range,modifier) && dmg==256);
    nativeShotgun.BoolValue=true;
    weaponType=WEAPONTYPE_SMG;
    assert(GetHitscanWeaponAttributes("smg",dmg,range,modifier) && dmg==24);
    // Engine pellet damage is counted once, with no second distance falloff.
    weaponType=WEAPONTYPE_SHOTGUN; latency=0; lerp=0;
    int attacker=1,inflictor=1,damageType=DMG_BULLET;
    dmg=40; assert(OnRockTakeDamage(10,attacker,inflictor,dmg,damageType)==Plugin_Handled);
    assert(dmg==0 && g_aRockEntities.Get(0,BLOCK_DMG_DEALT)==40 && requests==0);
    // Holding a shotgun must not classify a delayed blast as a pellet hit.
    damageType=64; dmg=50;
    OnRockTakeDamage(10,attacker,inflictor,dmg,damageType);
    assert(g_aRockEntities.Get(0,BLOCK_DMG_DEALT)==40);
    damageType=DMG_BULLET;
    weaponType=WEAPONTYPE_SMG; dmg=24;
    OnRockTakeDamage(10,attacker,inflictor,dmg,damageType);
    assert(g_aRockEntities.Get(0,BLOCK_DMG_DEALT)==40);
    weaponType=WEAPONTYPE_SHOTGUN; dmg=65;
    OnRockTakeDamage(10,attacker,inflictor,dmg,damageType);
    assert(requests==1); dmg=65;
    OnRockTakeDamage(10,attacker,inflictor,dmg,damageType); assert(requests==1);
    // Explicitly excluded rocks must retain their engine damage.
    tracked=false; dmg=16;
    assert(OnRockTakeDamage(10,attacker,inflictor,dmg,damageType)==Plugin_Continue && dmg==16);
    std::cout << "PASS: protection, release scope, rollback bounds/history, ray geometry, shotgun routing\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="rock-lagcomp-test-") as directory:
        path = Path(directory) / "rock.cpp"
        path.write_text(constants + "\n" + prelude + "\n" + bodies + "\n" + tests)
        executable = Path(directory) / "rock"
        subprocess.run(["c++", "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-parameter", str(path), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)

    config = (ROOT / "addons/sourcemod/configs/AnneHappy/dynamic_ai_difficulty.cfg").read_text()
    tiers = re.findall(r'"level\d"\s*\{([^{}]*)\}', config)
    assert len(tiers) == 6
    for tier, duration in zip(tiers, [0, 0.05, 0.10, 0.15, 0.20, 0.25]):
        pairs = re.findall(r'"([^"\n]+)"\s*"([^"\n]+)"', tier)
        values = dict(pairs)
        assert len(pairs) == len(values), "duplicate tier cvar"
        assert float(values["sm_rock_release_godframes"]) == duration
        assert "sm_rock_ai_health" not in values and "sm_rock_ai_safe_distance" not in values
        assert float(values["ai_tank3_throw_min_dist"]) == 200
        assert float(values["ai_tank3_throw_max_dist"]) == 450
    print("PASS: six difficulty tiers")


if __name__ == "__main__":
    main()
