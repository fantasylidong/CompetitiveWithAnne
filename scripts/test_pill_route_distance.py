#!/usr/bin/env python3
"""Check route detours using the production predicate and a mocked Nav host."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'addons/sourcemod/scripting/confoglcompmod/ItemTracking.sp').read_text()
start = re.search(r'^static bool PF_IsOnRoute\(', source, re.M).start()
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
host = r'''
#include <cassert>
#include <cstdio>
#include <limits>
#include <map>
using Address=int;
struct PFRoute {
    Address pStart=1,pGoal=2;
    float fRouteLen=1000,fPathMax=2000;
    float fStart[3]={1,0,0}, fGoal[3]={2,0,0};
};
std::map<std::pair<int,int>,float> distances;
std::map<std::pair<int,int>,bool> walkable;
int pathCalls=0;
void L4D_GetNavAreaCenter(Address area,float point[3]) { point[0]=area; }
float L4D2_NavAreaTravelDistance(const float from[3],const float to[3],bool ignore) {
    assert(ignore);
    auto found=distances.find({int(from[0]),int(to[0])});
    return found==distances.end() ? -1 : found->second;
}
bool PF_PathWithin(Address from,Address to,float budget) {
    assert(budget==2200); ++pathCalls;
    auto found=walkable.find({from,to});
    return found==walkable.end() || found->second;
}
'''
checks = r'''
int main() {
    PFRoute route;
    distances={{{1,3},400},{{3,2},600}};
    assert(PF_IsOnRoute(route,3,100) && pathCalls==2); // main route, independent of flow scaling
    distances[{1,3}]=500; distances[{3,2}]=700;
    assert(PF_IsOnRoute(route,3,100)); // exact 100-unit detour depth
    distances[{3,2}]=701; pathCalls=0;
    assert(!PF_IsOnRoute(route,3,100) && pathCalls==0);
    distances[{3,2}]=-1;
    assert(!PF_IsOnRoute(route,3,100)); // unreachable goal
    distances[{3,2}]=600; distances[{1,3}]=-1;
    assert(!PF_IsOnRoute(route,3,100)); // unreachable from start
    distances[{1,3}]=std::numeric_limits<float>::quiet_NaN();
    assert(!PF_IsOnRoute(route,3,100));
    distances[{1,3}]=400;
    walkable[{1,3}]=false;
    assert(!PF_IsOnRoute(route,3,100)); // Nav distance alone cannot override survivor traversal
    walkable.clear(); walkable[{3,2}]=false;
    assert(!PF_IsOnRoute(route,3,100));
    assert(PF_IsOnRoute(route,2,100)); // the already-validated goal
    puts("PASS: actual route distance, detour boundary, unreachable/NaN distances, survivor traversal");
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp, binary = Path(directory) / 'test.cpp', Path(directory) / 'test'
    cpp.write_text(host + source[start:end] + checks)
    subprocess.run(['c++', '-std=c++17', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
