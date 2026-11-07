#!/usr/bin/env python3
"""Check the production ammo-clearance function without a game server."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'addons/sourcemod/scripting/confoglcompmod/ItemTracking.sp').read_text()
match = re.search(r'^static bool PF_NearAmmoPile\(', source, re.M)
opening = source.index('{', match.start())
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
body = source[match.start():end]
assert 'PF_NearDoor(hDoors, fOut) || PF_NearAmmoPile(fOut)' in source

host = r'''
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
constexpr int Prop_Data=0, Prop_Send=1;
struct Pile { float origin[3], mins[3], maxs[3]; };
std::vector<Pile> piles;
float FloatAbs(float value) { return std::fabs(value); }
float SquareRoot(float value) { return std::sqrt(value); }
int FindEntityByClassname(int previous, const char* name) {
    assert(std::strcmp(name,"weapon_ammo_spawn")==0);
    int next=previous<0 ? 0 : previous+1;
    return next<int(piles.size()) ? next : -1;
}
void GetEntPropVector(int entity, int prop, const char* name, float out[3]) {
    const auto& pile=piles.at(entity);
    const float* value=nullptr;
    if(std::strcmp(name,"m_vecAbsOrigin")==0) { assert(prop==Prop_Data); value=pile.origin; }
    if(std::strcmp(name,"m_vecMins")==0) { assert(prop==Prop_Send); value=pile.mins; }
    if(std::strcmp(name,"m_vecMaxs")==0) { assert(prop==Prop_Send); value=pile.maxs; }
    assert(value);
    for(int i=0;i<3;++i) out[i]=value[i];
}
'''
checks = r'''
bool near(float x,float y,float z) {
    float point[3]={x,y,z}; return PF_NearAmmoPile(point);
}
int main() {
    assert(!near(0,0,2)); // no ammo piles
    piles={{{100,200,0},{-24,-32,0},{24,32,16}}}; // radius 40 + 48
    assert(near(100,200,2)); // overlap despite weapon entities being ignored by traces
    assert(near(188,200,2)); // clearance boundary
    assert(!near(189,200,2));
    assert(near(160,260,2)); // bounding circle covers any horizontal rotation
    assert(!near(100,200,33)); // above the pile's vertical clearance
    assert(near(100,200,-28)); // pill's 12-unit height intersects lower clearance
    assert(!near(100,200,-29));
    assert(!near(100,200,256)); // another floor must not block a usable spot
    assert(!near(100,200,-256));
    piles.push_back({{1000,2000,256},{-30,-40,0},{10,20,24}});
    assert(near(1098,2000,258)); // use larger negative extents; inspect every pile
    assert(!near(1099,2000,258));
    piles={{{0,0,0},{0,0,0},{0,0,0}}};
    assert(near(0,0,2)); // non-solid/zero bounds still reserve pickup clearance
    assert(near(48,0,2));
    assert(!near(49,0,2));
    puts("PASS: ammo overlap, pickup margin, rotation, vertical clearance, multiple piles, zero bounds");
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp, binary = Path(directory) / 'test.cpp', Path(directory) / 'test'
    cpp.write_text(host + body + checks)
    subprocess.run(['c++', '-std=c++17', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
