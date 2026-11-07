#!/usr/bin/env python3
"""Exercise the production fill-gap selector without a game server."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'addons/sourcemod/scripting/confoglcompmod/ItemTracking.sp').read_text()
start = re.search(r'^static float PF_PickFillGap\(', source, re.M).start()
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
host = r'''
#include <algorithm>
#include <cassert>
#include <cstdio>
#include <vector>
constexpr int Sort_Ascending=0, Sort_Float=1;
float fraction=0.5;
float GetRandomFloat(float low,float high) { return low+(high-low)*fraction; }
struct ArrayList {
    std::vector<float>* data;
    int Length;
    ArrayList(std::vector<float>& values):data(&values),Length(values.size()) {}
    void Sort(int order,int type) {
        assert(order==Sort_Ascending && type==Sort_Float);
        std::sort(data->begin(),data->end());
    }
    float Get(int i) { return data->at(i); }
};
'''
checks = r'''
int main() {
    float left=0,right=0;
    std::vector<float> flows={80,46,40,50,42};
    for(fraction=0;fraction<=1;fraction+=0.25) {
        float target=PF_PickFillGap(flows,left,right);
        assert(left==50 && right==80 && target>=62 && target<=68);
    }
    fraction=0.5;
    flows.push_back(65); // a successful fill splits the largest gap
    assert(PF_PickFillGap(flows,left,right)==57.5f);
    assert(left==50 && right==65);
    flows.push_back(57.5f); // a failed target also redirects subsequent attempts
    assert(PF_PickFillGap(flows,left,right)==72.5f);
    flows={40,80}; // no original pills
    assert(PF_PickFillGap(flows,left,right)==60);
    flows={40,40,50,50,80,80}; // stacks/duplicate progress do not hide the gap
    assert(PF_PickFillGap(flows,left,right)==65);
    puts("PASS: retained pills, largest gap, jitter bounds, successful/failed targets, empty map, stacks");
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp, binary = Path(directory) / 'test.cpp', Path(directory) / 'test'
    cpp.write_text(host + source[start:end] + checks)
    subprocess.run(['c++', '-std=c++17', str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
