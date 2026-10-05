#!/usr/bin/env python3
"""Exercise the cleaner's actual predicates and batch code with fake engine state."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "addons/sourcemod/scripting/extend/anne_entity_cleaner.sp").read_text()
    names = ["ForgetEntity", "ResetTracking", "OnMapStart", "OnMapEnd", "OnEntityCreated",
             "OnEntityDestroyed", "IsNetworkEntity", "IsOrdinaryWeapon", "TrackEntity",
             "WeaponDropPost", "WeaponEquipPost", "Event_Drop", "Event_Death", "RefreshCandidates", "HasProtectedIdentity",
             "IsAttachedOrOwned", "IsFarFromPlayers", "IsEligible", "CountUsedEdicts",
             "CleanupBatch", "VerifyPreviousBatch", "Timer_Check", "Command_Clean"]
    functions = []
    for name in names:
        match = re.search(rf"^(?:public )?\w+ {name}\([^\n]*\)\n\{{.*?^\}}", source, re.M | re.S)
        if not match:
            raise AssertionError(f"Missing actual function: {name}")
        body = match.group().removeprefix("public ").replace("const char[]", "const char*")
        body = re.sub(r"static const char (\w+)\[\]\[\]", r"static const char* \1[]", body)
        for array in ("weapons", "parents", "children"):
            body = body.replace(f"sizeof({array})", f"int(std::size({array}))")
        functions.append(body)
    kinds = re.search(r"^enum CleanupKind\n\{.*?^\};", source, re.M | re.S).group()
    constants = "\n".join(re.findall(r"^#define (?:MAX_EDICTS|MAX_BATCH) \d+$", source, re.M))
    harness = r'''
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <functional>
#include <iostream>
#include <iterator>
#include <set>
#include <string>
#include <vector>
CONSTANTS
KINDS
constexpr int INVALID_ENT_REFERENCE=-1, MaxClients=4, Prop_Data=1, Prop_Send=0, Plugin_Continue=0, Plugin_Handled=1;
using Action=int; using Handle=int;
struct Cvar { int IntValue=0; float FloatValue=0; bool BoolValue=false; };
Cvar g_Enable, g_Threshold, g_Target, g_Batch, g_Age, g_DropAge, g_Distance;
int g_Refs[MAX_EDICTS], g_QueuedRefs[MAX_BATCH], g_QueuedCount, g_BeforeUsed;
CleanupKind g_Kinds[MAX_EDICTS]; float g_Since[MAX_EDICTS], g_NextReport, g_NextCleanup, now;
bool g_MapRunning, g_Baseline, g_Cleaning; char g_LogPath[32];
struct Entity {
    bool valid=false; int serial=1, hammer=0, owner=-1, weaponOwner=-1, parent=-1, child=-1, life=2, health=0;
    std::string classname="", name="", global="", parentField="m_pParent", childField="m_pChild";
    float origin[3]={5000,0,0};
    std::set<std::string> missing;
} entities[MAX_EDICTS];
struct Player { bool ingame=false, fake=false; int team=2; float origin[3]={0,0,0}; } players[MaxClients+1];
struct Event {
    int userid=0, entityid=0, propid=0;
    int GetInt(const char* key) {
        if (std::strcmp(key,"userid")==0) return userid;
        if (std::strcmp(key,"entityid")==0) return entityid;
        assert(std::strcmp(key,"propid")==0); return propid;
    }
};
int GetClientOfUserId(int userid) { return userid==1001 && players[1].ingame ? 1 : 0; }
std::vector<int> deletes; std::function<void(int)> on_remove; int reported=1800, snapshots=0;
float GetGameTime() { return now; }
int GetMaxEntities() { return MAX_EDICTS; }
int GetEntityCount() { return reported; }
bool IsValidEntity(int e) { return e>=0 && e<MAX_EDICTS && entities[e].valid; }
bool IsValidEdict(int e) { return IsValidEntity(e); }
int EntIndexToEntRef(int e) { assert(IsValidEntity(e)); return entities[e].serial*4096+e; }
int EntRefToEntIndex(int r) {
    if (r<0) return -1;
    int e=r%4096;
    return IsValidEntity(e) && entities[e].serial==r/4096 ? e : -1;
}
bool StrEqual(const char* a,const char* b) { return std::strcmp(a,b)==0; }
void strcopy(char* out,int size,const char* value) { std::snprintf(out,size,"%s",value); }
void GetEntityClassname(int e,char* out,int size) { strcopy(out,size,entities[e].classname.c_str()); }
bool HasEntProp(int e,int prop,const char* field) {
    static std::set<std::string> fields={"m_iHammerID","m_iName","m_iGlobalname","m_hOwnerEntity",
        "m_vecAbsOrigin","m_lifeState","m_iHealth"};
    if (entities[e].missing.count(field)) return false;
    if (StrEqual(field,"m_hOwner")) return prop==Prop_Send;
    return prop==Prop_Data && (fields.count(field) || entities[e].parentField==field || entities[e].childField==field);
}
int GetEntProp(int e,int,const char* field) {
    assert(HasEntProp(e,Prop_Data,field));
    if (StrEqual(field,"m_iHammerID")) return entities[e].hammer;
    if (StrEqual(field,"m_lifeState")) return entities[e].life;
    assert(StrEqual(field,"m_iHealth")); return entities[e].health;
}
int GetEntPropEnt(int e,int prop,const char* field) {
    assert(HasEntProp(e,prop,field));
    if (StrEqual(field,"m_hOwnerEntity")) return entities[e].owner;
    if (StrEqual(field,"m_hOwner")) return entities[e].weaponOwner;
    if (entities[e].parentField==field) return entities[e].parent;
    assert(entities[e].childField==field); return entities[e].child;
}
void GetEntPropString(int e,int,const char* field,char* out,int size) {
    assert(HasEntProp(e,Prop_Data,field));
    strcopy(out,size,(StrEqual(field,"m_iName") ? entities[e].name : entities[e].global).c_str());
}
void GetEntPropVector(int e,int,const char* field,float out[3]) {
    assert(HasEntProp(e,Prop_Data,field)); std::copy_n(entities[e].origin,3,out);
}
bool IsClientInGame(int c) { return players[c].ingame; }
bool IsFakeClient(int c) { return players[c].fake; }
int GetClientTeam(int c) { return players[c].team; }
void GetClientAbsOrigin(int c,float out[3]) { std::copy_n(players[c].origin,3,out); }
float GetVectorDistance(const float a[3],const float b[3],bool squared) {
    float d=0; for(int i=0;i<3;i++) d+=(a[i]-b[i])*(a[i]-b[i]); return squared ? d : std::sqrt(d);
}
void LogToFileEx(const char*,const char*,...) {}
void ConsoleLine(int,const char*,...) {}
void WriteSnapshot(int) { snapshots++; }
void RemoveEntity(int e) { deletes.push_back(e); if(on_remove) on_remove(e); }
FUNCTIONS
void reset() {
    for(auto &e:entities) e=Entity{};
    for(auto &p:players) p=Player{};
    players[1].ingame=true;
    deletes.clear(); on_remove=nullptr; now=0; reported=1800; snapshots=0;
    g_Enable.BoolValue=true; g_Threshold.IntValue=1800; g_Target.IntValue=1700;
    g_Batch.IntValue=32; g_Age.FloatValue=30; g_DropAge.FloatValue=120; g_Distance.FloatValue=1500;
    OnMapStart();
}
void create(int e,const char* cls,const char* name="") {
    entities[e]=Entity{}; entities[e].valid=true; entities[e].classname=cls; entities[e].name=name;
    OnEntityCreated(e,cls);
}
void occupy_protected_slots(int count) {
    for(int e=200;e<200+count;e++) create(e,"logic_relay","map_logic");
}
void finish_deletes() {
    for(int e:deletes) { entities[e].valid=false; entities[e].serial++; OnEntityDestroyed(e); }
    deletes.clear();
}
int main() {
    reset();
    create(100,"beam_spotlight","l4d_random_beam_item"); RefreshCandidates();
    now=29.9f; assert(!IsEligible(100,now)); now=30; assert(IsEligible(100,now));
    entities[100].hammer=12; assert(!IsEligible(100,now)); entities[100].hammer=0;
    entities[100].parent=200; assert(!IsEligible(100,now)); entities[100].parent=-1;
    entities[100].child=201; assert(!IsEligible(100,now)); entities[100].child=-1;
    entities[100].owner=1; assert(!IsEligible(100,now)); entities[100].owner=-1;
    entities[100].weaponOwner=1; assert(!IsEligible(100,now)); entities[100].weaponOwner=-1;
    for(const char* field:{"m_pParent","m_hMoveParent","m_hParent"}) {
        entities[100].parentField=field; entities[100].parent=2; assert(!IsEligible(100,now));
        entities[100].parent=-1; assert(IsEligible(100,now));
    }
    entities[100].parentField="m_pParent";
    entities[100].childField="m_hMoveChild"; entities[100].child=2; assert(!IsEligible(100,now));
    entities[100].child=-1; assert(IsEligible(100,now)); entities[100].childField="m_pChild";
    entities[100].global="quest"; assert(!IsEligible(100,now)); entities[100].global="";
    for(const char* field:{"m_iHammerID","m_iName","m_pParent","m_hOwnerEntity","m_vecAbsOrigin"}) {
        entities[100].missing.insert(field); assert(!IsEligible(100,now)); entities[100].missing.erase(field);
    }
    entities[100].name="map_beam"; assert(!IsEligible(100,now)); entities[100].name="l4d_random_beam_item";
    entities[100].origin[0]=1500; assert(!IsEligible(100,now)); entities[100].origin[0]=1501; assert(IsEligible(100,now));
    players[2].ingame=true; players[2].team=3; players[2].origin[0]=1501; assert(!IsEligible(100,now));
    players[2].fake=true; assert(IsEligible(100,now)); players[2].ingame=false;
    players[1].ingame=false; assert(!IsEligible(100,now)); players[1].ingame=true;
    entities[100].serial++; assert(!IsEligible(100,now)); RefreshCandidates(); assert(!IsEligible(100,now));

    reset(); create(110,"weapon_rifle"); now=500; RefreshCandidates(); assert(!IsEligible(110,now));
    WeaponDropPost(1,110); now=619.9f; assert(!IsEligible(110,now)); now=620; assert(IsEligible(110,now));
    entities[110].name="quest_gun"; assert(!IsEligible(110,now)); entities[110].name="";
    WeaponEquipPost(1,110); assert(!IsEligible(110,now)); WeaponDropPost(1,110);
    now=740; assert(IsEligible(110,now)); entities[110].owner=1; RefreshCandidates();
    entities[110].owner=-1; assert(!IsEligible(110,now)); // No synthetic age on a later unobserved drop.
    for(const char* cls:{"weapon_gascan","weapon_cola_bottles","weapon_gnome","weapon_spawn",
        "weapon_rifle_spawn","weapon_chainsaw","weapon_melee","weapon_custom","pipe_bomb_projectile",
        "molotov_projectile","tank_rock","ability_lunge","point_hurt","info_particle_system","logic_relay"}) {
        create(111,cls); WeaponDropPost(1,111); now+=200; assert(!IsEligible(111,now));
        g_Kinds[111]=Cleanup_DroppedWeapon; g_Refs[111]=EntIndexToEntRef(111); g_Since[111]=0;
        assert(!IsEligible(111,now)); // Revalidation rejects a changed classname too.
    }

    reset(); create(120,"infected"); TrackEntity(120,Cleanup_DeadCommon); now=30;
    assert(IsEligible(120,now)); entities[120].life=0; assert(!IsEligible(120,now));
    entities[120].life=1; assert(!IsEligible(120,now)); entities[120].life=2;
    entities[120].health=1; assert(!IsEligible(120,now)); entities[120].health=0;
    entities[120].classname="witch"; assert(!IsEligible(120,now));

    reset(); create(100,"weapon_rifle");
    Event_Drop(Event{9999,0,100},"weapon_drop",false); assert(g_Kinds[100]==Cleanup_None);
    Event_Drop(Event{1001,0,100},"weapon_drop",false); assert(g_Kinds[100]==Cleanup_DroppedWeapon);
    create(101,"infected"); Event_Death(Event{1001,101,0},"player_death",false); assert(g_Kinds[101]==Cleanup_None);
    Event_Death(Event{0,101,0},"player_death",false); assert(g_Kinds[101]==Cleanup_DeadCommon);

    reset(); create(100,"beam_spotlight","l4d_random_beam_item"); RefreshCandidates();
    now=30; reported=2048; Timer_Check(0); assert(deletes.empty()); // A high engine watermark is not pressure.

    reset(); occupy_protected_slots(1790); for(int e=100;e<140;e++) create(e,"beam_spotlight","l4d_random_beam_item");
    RefreshCandidates(); now=30; Timer_Check(0); assert(deletes.size()==32 && g_QueuedCount==32);
    assert(CountUsedEdicts()==1830); // RemoveEntity is deliberately deferred in the mock engine.
    Command_Clean(0,0); assert(deletes.size()==32); finish_deletes();
    now=32; reported=1700; Timer_Check(0); assert(g_QueuedCount==8 && CountUsedEdicts()==1798 && deletes.size()==8);
    finish_deletes(); now=34; Timer_Check(0); assert(deletes.empty()); // No fallback deletion of protected objects.
    assert(g_Cleaning); // Threshold starts a cycle; it continues toward the lower target.
    g_Enable.BoolValue=false; reported=2048; now=35; Timer_Check(0); Command_Clean(0,0); assert(deletes.empty() && !g_Cleaning);
    create(150,"beam_spotlight","l4d_random_beam_item"); RefreshCandidates(); now=65;
    g_Enable.BoolValue=true; g_Threshold.IntValue=1791; g_Target.IntValue=1900; Timer_Check(0); assert(deletes.size()==1);
    finish_deletes(); now=67; Timer_Check(0); assert(!g_Cleaning); // Inverted target clamps below threshold.

    reset(); occupy_protected_slots(1820); for(int e=100;e<140;e++) create(e,"beam_spotlight","l4d_random_beam_item");
    RefreshCandidates(); now=30; Command_Clean(0,0); assert(deletes.size()==32); finish_deletes();
    now=30.1f; Timer_Check(0); Command_Clean(0,0); assert(deletes.empty());
    now=32; Timer_Check(0); assert(deletes.size()==8); // Timer and manual requests share a real cooldown.

    reset(); occupy_protected_slots(1640);
    for(int e=5;e<165;e++) create(e,"beam_spotlight","l4d_random_beam_item");
    RefreshCandidates(); assert(CountUsedEdicts()==1800);
    int removed=0;
    for(now=30;now<=38;now+=2) { Timer_Check(0); removed+=deletes.size(); finish_deletes(); }
    assert(removed==100 && CountUsedEdicts()==1700 && !g_Cleaning); // Default target reached exactly.

    reset(); create(100,"beam_spotlight","l4d_random_beam_item"); create(101,"beam_spotlight","l4d_random_beam_item");
    RefreshCandidates(); now=30;
    on_remove=[](int e) { if(e==100) entities[101].serial++; }; // Another plugin destroys/reuses a later candidate.
    assert(CleanupBatch(2)==1 && deletes.size()==1 && deletes[0]==100);
    OnMapEnd(); now=500; Timer_Check(0); assert(!g_MapRunning && g_QueuedCount==0 && g_Kinds[101]==Cleanup_None);
    OnMapStart(); assert(g_MapRunning && !IsEligible(101,now));
    assert(!IsNetworkEntity(-1) && !IsNetworkEntity(1) && !IsNetworkEntity(2048));
    std::cout << "PASS: actual cleaner predicates, provenance, protected identities, missing fields, age/distance, reuse, batches and lifecycle\n";
}
'''
    harness = harness.replace("CONSTANTS", constants).replace("KINDS", kinds).replace("FUNCTIONS", "\n\n".join(functions))
    compiler = shutil.which("c++")
    if not compiler:
        raise SystemExit("A C++ compiler is required")
    with tempfile.TemporaryDirectory(prefix="anne-entity-cleaner-check-") as tmp:
        cpp, binary = Path(tmp) / "check.cpp", Path(tmp) / "check"
        cpp.write_text(harness)
        subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Wno-unused-parameter", str(cpp), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
