#!/usr/bin/env python3
"""Run production lerp state functions with a small mocked SourceMod host.

Requires Python 3 and a C++ compiler; does not connect to a game server.
The selected SourcePawn function bodies also use valid C++ syntax.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'addons/sourcemod/scripting/optional/lerpmonitor.sp').read_text()


def function(name):
    start = re.search(r'^(?:void|bool|int) ' + name + r'\(', source, re.M).start()
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


host = r'''
#include <cassert>
#include <cstdio>
constexpr int MAXPLAYERS=2, L4D_TEAM_SURVIVORS=2, L4D_TEAM_SPECTATE=1;
constexpr int Prop_Data=0, LERP_LEGAL_CONFIRMATIONS=2;
constexpr float LERP_RECHECK_INTERVAL=0.5f;
constexpr auto null=nullptr;
struct Cvar { float FloatValue; int IntValue; };
Cvar cVarMinLerp{0,0}, cVarMaxLerp{0.100f,0}, cVarBadLerpAction{0,1};
bool g_bLerpWarningActive[3], g_bLerpQueryPending[3], g_bLerpQueryTeam[3], g_bCurrentLerpKnown[3];
int g_iLerpLegalConfirmations[3], g_iLerpWarningGeneration[3];
float g_fCurrentLerp[3], g_fLerpWarningDeadline[3], g_fQueriedUpdateRate[3], g_fQueriedInterpRatio[3];
void* g_hLerpWarningTimer[3];
float now=10, engineLerp=0, acceptedLerp=0;
int teamId=2, moves=0, applies=0, schedules=0, kicks=0;
float GetGameTime() { return now; }
int GetClientTeam(int) { return teamId; }
void SetEntPropFloat(int,int,const char*,float value) { engineLerp=value; }
void ChangeClientTeam(int,int team) { teamId=team; ++moves; }
void ScheduleLerpRecheck(int,float) { ++schedules; }
void KillTimer(void*) {}
void CPrintToChatEx(int,int,const char*,...) {}
void CPrintToChatAllEx(int,const char*,...) {}
void KickClient(int,const char*,...) { ++kicks; }
void ApplyPlayerLerp(int,float value,bool) { if(teamId>=2) {acceptedLerp=value; ++applies;} }
int FloatCompare(float a,float b) { return (a>b)-(a<b); }
'''
checks = r'''
int main() {
    float displayed=-1;
    assert(!TryGetLerpTime(1,displayed));
    // Exact 100ms is legal; existing accepted zero must not drive the display.
    ProcessQueriedLerp(1,0.100f);
    assert(!g_bLerpWarningActive[1] && applies==1 && moves==0);
    assert(TryGetLerpTime(1,displayed) && displayed==0.100f);
    // Use a 67ms mode to reproduce a queried 100ms above the configured cap.
    cVarMaxLerp.FloatValue=0.067f;
    acceptedLerp=0;
    ProcessQueriedLerp(1,0.100f);
    assert(g_bLerpWarningActive[1] && moves==0 && acceptedLerp==0);
    assert(TryGetLerpTime(1,displayed) && displayed==0.100f);
    now=14.9f;
    ProcessQueriedLerp(1,0.100f);
    assert(moves==0);
    now=15;
    ProcessQueriedLerp(1,0.100f);
    assert(moves==1 && teamId==1 && g_bLerpWarningActive[1]);
    ProcessQueriedLerp(1,0.100f); // spectator: no repeat punishment
    assert(moves==1);
    teamId=2; // !jg without changing any CVar
    ProcessQueriedLerp(1,0.100f);
    assert(moves==2 && teamId==1 && g_fLerpWarningDeadline[1]==15);
    assert(TryGetLerpTime(1,displayed) && displayed==0.100f);
    // Correction while spectating requires two legal samples, then rejoin works.
    ProcessQueriedLerp(1,0.05f);
    assert(g_bLerpWarningActive[1]);
    ProcessQueriedLerp(1,0.05f);
    assert(!g_bLerpWarningActive[1]);
    teamId=2;
    ProcessQueriedLerp(1,0.05f);
    assert(teamId==2 && moves==2 && acceptedLerp==0.05f);
    // Above 100ms remains illegal; the alternative kick action is preserved.
    cVarMaxLerp.FloatValue=0.100f;
    cVarBadLerpAction.IntValue=0;
    ProcessQueriedLerp(1,0.101f);
    now+=5;
    ProcessQueriedLerp(1,0.101f);
    assert(kicks==1);
    ResetLerpWarning(1);
    assert(!g_bLerpQueryPending[1] && !g_bLerpWarningActive[1]);
    puts("PASS: 100ms boundary, current display, grace deadline, rejoin, correction, kick");
}
'''
# Also guard the source of all samples: rejoining cannot fall back to userinfo.
assert 'GetClientInfo(' not in source
assert 'ArrLerpsValue' not in function('LM_GetLerpTime')
assert 'BeginClientLerpQuery(client)' in function('ProcessPlayerLerp')
assert 'ScheduleLerpRecheck' in function('BeginClientLerpQuery')
bodies = '\n'.join(function(n) for n in (
    'IsLerpInAllowedRange', 'ResetLerpWarning', 'TryGetLerpTime', 'ProcessQueriedLerp'))
with tempfile.TemporaryDirectory(prefix='lerp-regression-') as temp:
    cpp = Path(temp) / 'test.cpp'
    binary = Path(temp) / 'test'
    cpp.write_text(host + bodies + checks)
    subprocess.run(['c++', '-std=c++17', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
