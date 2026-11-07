#!/usr/bin/env python3
"""Exercise mission restoration and deferred door-lock bot returns.

Requires Python 3 and a C++ compiler, following test_lerpmonitor.py's mock-host
approach. --baseline demonstrates that the pre-fix bodies fail the same checks.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]


def source(path):
    if '--baseline' in sys.argv:
        return subprocess.check_output(['git', 'show', f'HEAD:{path}'], cwd=root).decode()
    return (root / path).read_text()


def function(text, name):
    match = re.search(r'^(?:public )?(?:void|int|Action) ' + name + r'\(', text, re.M)
    opening = text.index('{', match.start())
    end, depth = opening + 1, 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    body = text[match.start():end].replace('public ', '')
    return body.replace('view_as<', 'static_cast<')


melee = source('addons/sourcemod/scripting/optional/l4d2_melee_spawn_control.sp')
door = source('addons/sourcemod/scripting/extend/l4d2_door_lock.sp')
host = r'''
#include <cassert>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
using Address = int;
constexpr Address Address_Null=0;
constexpr int PLATFORM_MAX_PATH=256, MELEE_LIST_LENGTH=255;
constexpr int g_hSDKGetAllMissions=1, g_hSDKKvGetString=2, g_hSDKKvSetString=3;
Address g_pMatchExtL4D=5, registry=10, g_pMissionInfo=0xdead;
char g_sMissionName[256], g_sMissionMelee[255], g_sAppliedMelee[255];
std::map<std::string,std::string> values;
int writes=0;
Address SDKCall(int call, Address manager) {
    assert(call==g_hSDKGetAllMissions && manager==g_pMatchExtL4D);
    return registry;
}
void SDKCall(int call, Address ptr, char* out, int size, const char* key, const char* fallback) {
    assert(call==g_hSDKKvGetString && ptr==registry && ptr!=0);
    auto it=values.find(key);
    snprintf(out,size,"%s",it==values.end()?fallback:it->second.c_str());
}
void SDKCall(int call, Address ptr, const char* key, const char* value) {
    if(ptr==g_pMissionInfo) throw std::runtime_error("dereferenced freed mission pointer");
    assert(call==g_hSDKKvSetString && ptr==registry && ptr!=0);
    values[key]=value; ++writes;
}
void FormatEx(char* out,int size,const char* format,...) {
    va_list args; va_start(args,format); vsnprintf(out,size,format,args); va_end(args);
}
void prepareMission() {
    strcpy(g_sMissionName,"mission_a"); strcpy(g_sMissionMelee,"fireaxe");
    strcpy(g_sAppliedMelee,"katana");
    values={{"mission_a/meleeweapons","katana"}};
}
enum Action { Plugin_Continue, Plugin_Handled };
using Handle = int;
constexpr int MaxClients=3, FCVAR_CHEAT=16, TIMER_FLAG_NO_MAPCHANGE=2;
constexpr int Prop_Send=0, NULL_VECTOR=0;
bool enabled=true, inHook=false, online=true, entity=true, alive=true, fake=true;
bool g_bLeftSafeAreas=false, g_bLockThisMap=false, g_bLockSafeAreas=false;
bool g_bSurvivorBotFreezeActive=false, g_bNoBotMoveChanged=false;
int g_iGiveUpsTime=0, Cvar_DoorLock_NoBotMove=0;
int serial=100, team=2, commandFlags=FCVAR_CHEAT, warps=0, properties=0, teleports=0;
int removalMode=0, pendingSerial=0;
Action (*pending)(Handle,int)=nullptr;
bool L4D2_DoorLock_Enable() { return enabled; }
bool IsClientInGame(int i) { assert(i==1); return online; }
bool IsValidEnt(int i) { return i==1 && entity; }
bool IsPlayerAlive(int i) { assert(online && entity && i==1); return alive; }
int GetClientTeam(int i) { assert(online && entity && i==1); return team; }
bool IsFakeClient(int i) { assert(online && entity && i==1); return fake; }
int GetClientSerial(int i) { assert(online && entity && i==1); return serial; }
int GetClientFromSerial(int value) { return online && serial==value ? 1 : 0; }
int GetCommandFlags(const char*) { return commandFlags; }
void SetCommandFlags(const char*,int value) { commandFlags=value; }
void FakeClientCommand(int i,const char*) {
    assert(i==1 && online && entity);
    if(inHook) throw std::runtime_error("bot warp ran inside the safe-area hook");
    ++warps;
    if(removalMode==1) online=entity=false;
    if(removalMode==2) ++serial; // the slot now belongs to another connection
    if(removalMode==3) entity=false; // connection outlives its entity
    if(removalMode==4) alive=false;
    if(removalMode==5) team=1;
}
void SetEntPropFloat(int i,int,const char*,float) {
    assert(i==1 && online && entity && alive && team==2 && fake); ++properties;
}
void TeleportEntity(int i,int,int,int) {
    assert(i==1 && online && entity && alive && team==2 && fake); ++teleports;
    if(removalMode==6) online=entity=false; // no entity access may follow
}
void CreateTimer(float delay,Action (*callback)(Handle,int),int value,int flags) {
    assert(delay==0.0f && flags==TIMER_FLAG_NO_MAPCHANGE);
    pending=callback; pendingSerial=value;
}
int GetDoorLockBlockReason() { return 0; }
void PrintDoorLockBlockReason(int,int,bool) {}
void Activate_SurvivorTeleport(int) {}
void ResetConVar(int) {}
void UnFreezeSurvivorBots() {}
void prepareBot(int mode=0) {
    enabled=online=entity=alive=fake=true; inHook=g_bLeftSafeAreas=false;
    serial=100; team=2; removalMode=mode; pending=nullptr;
    commandFlags=FCVAR_CHEAT; warps=properties=teleports=0;
}
'''
checks = r'''
int main() {
    int failures=0;
    try {
    // The former result has been freed, while its named mission remains live.
    prepareMission(); RestoreMissionInfo();
    assert(values["mission_a/meleeweapons"]=="fireaxe" && writes==1);
    RestoreMissionInfo(); assert(writes==1); // map end followed by unload
    // A registry reload changes every mission address. Only the current root is used.
    prepareMission(); registry=20; RestoreMissionInfo();
    assert(values["mission_a/meleeweapons"]=="fireaxe" && writes==2);
    // Removed/empty missions and a missing registry must not be recreated.
    prepareMission(); values.clear(); RestoreMissionInfo();
    assert(values.empty() && writes==2 && !g_sMissionName[0]);
    prepareMission(); values["mission_a/meleeweapons"]=""; RestoreMissionInfo();
    assert(values["mission_a/meleeweapons"].empty() && writes==2);
    prepareMission(); registry=0; RestoreMissionInfo(); assert(writes==2);
    // Do not overwrite a replacement mission list changed by a reload/another plugin.
    prepareMission(); registry=25; values["mission_a/meleeweapons"]="pitchfork";
    RestoreMissionInfo(); assert(values["mission_a/meleeweapons"]=="pitchfork" && writes==2);
    // Preserve successful restoration for a third-party mission name containing spaces.
    registry=30; strcpy(g_sMissionName,"custom mission");
    strcpy(g_sAppliedMelee,"knife");
    values={{"custom mission/meleeweapons","knife"}}; RestoreMissionInfo();
    assert(values["custom mission/meleeweapons"]=="fireaxe" && writes==3);
    } catch(const std::exception& error) {
        fprintf(stderr,"MISSION: %s\n",error.what()); ++failures;
    }
    try {
    // The pre/post hook must finish while the player is still valid.
    for(int mode=0; mode<=6; ++mode) {
        prepareBot(mode); inHook=true;
        assert(L4D_OnFirstSurvivorLeftSafeArea(1)==Plugin_Handled);
        assert(online && entity && warps==0 && pending!=nullptr);
        inHook=false; pending(0,pendingSerial);
        assert(warps==1 && commandFlags==FCVAR_CHEAT);
        assert(properties==(mode==0 || mode==6 ? 1 : 0));
        assert(teleports==properties);
    }
    // Cancel work if the bot disconnects, changes team, is taken over, or the
    // plugin is disabled / a human leaves before the deferred callback runs.
    for(int mode=0; mode<8; ++mode) {
        prepareBot(); L4D_OnFirstSurvivorLeftSafeArea(1);
        if(mode==0) online=false;
        if(mode==1) ++serial;
        if(mode==2) entity=false;
        if(mode==3) alive=false;
        if(mode==4) team=1;
        if(mode==5) fake=false;
        if(mode==6) enabled=false;
        if(mode==7) g_bLeftSafeAreas=true;
        pending(0,pendingSerial);
        assert(warps==0 && properties==0 && teleports==0);
    }
    } catch(const std::exception& error) {
        fprintf(stderr,"DOOR-LOCK: %s\n",error.what()); ++failures;
    }
    if(failures) return failures;
    puts("PASS: mission restoration, deferred bot warp, invalid/reused clients, restored command flags");
}
'''
bodies = '\n'.join([
    function(melee, 'RestoreMissionInfo'),
    function(door, 'ReturnSurvivorBotToStartArea'),
    function(door, 'Timer_ReturnSurvivorBotToStartArea') if '--baseline' not in sys.argv else '',
    function(door, 'L4D_OnFirstSurvivorLeftSafeArea'),
])
with tempfile.TemporaryDirectory(prefix='anne-crash-regression-') as temp:
    cpp, binary = Path(temp) / 'test.cpp', Path(temp) / 'test'
    cpp.write_text(host + bodies + checks)
    subprocess.run(['c++', '-std=c++17', str(cpp), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)])
    if '--baseline' in sys.argv:
        assert result.returncode == 2, 'Both old lifetime paths must fail the regression checks'
        print('PASS: baseline rejected stale mission access and synchronous bot warp')
    else:
        result.check_returncode()
