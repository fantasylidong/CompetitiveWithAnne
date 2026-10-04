#!/usr/bin/env python3
"""Exercise the plugin's actual classification and I/O rewrite bodies with C++ stubs.

Requires c++. Does not simulate Source/Stripper load order or gameplay.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/sourcemod/scripting/l4d2_coop_versus_compat.sp"


def body(source, name):
    start = re.search(rf"^(?:bool|int) {name}\(", source, re.M).start()
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    text = source[start:end].replace("const char[]", "const char*")
    return re.sub(r"\b(bool|int) (\w+);", r"\1 \2{};", text)


def main():
    source = SOURCE.read_text()
    code = "\n".join(body(source, name) for name in (
        "ModeContainsMap", "IsCoopOnlyMap", "RewriteOutput"))
    harness = r'''
#include <algorithm>
#include <cassert>
#include <cstring>
#include <iostream>
#include <map>
#include <string>
#include <strings.h>
#include <utility>
#include <vector>
constexpr int PLATFORM_MAX_PATH = 256;
bool StrEqual(const char *a, const char *b, bool sensitive = true) {
    return (sensitive ? strcmp(a, b) : strcasecmp(a, b)) == 0;
}
void copy(const std::string &s, char *out, int len) {
    if (len > 0) { std::strncpy(out, s.c_str(), len); out[len - 1] = 0; }
}
struct Node {
    std::string name;
    std::map<std::string, std::string> values;
    std::vector<Node> children;
};
struct SourceKeyValues {
    Node *node = nullptr;
    std::vector<Node> *siblings = nullptr;
    size_t index = 0;
    bool IsNull() { return node == nullptr; }
    SourceKeyValues FindKey(const char *key) {
        if (!node) return {};
        std::string path(key);
        auto split = path.find('/');
        for (auto &child : node->children) {
            if (child.name != path.substr(0, split)) continue;
            SourceKeyValues found{&child};
            return split == std::string::npos ? found : found.FindKey(path.substr(split + 1).c_str());
        }
        return {};
    }
    int GetInt(const char *key, int fallback = 0) {
        assert(node);
        auto it = node->values.find(key);
        return it == node->values.end() ? fallback : std::stoi(it->second);
    }
    void GetString(const char *key, char *out, int len) {
        assert(node);
        auto it = node->values.find(key);
        copy(it == node->values.end() ? "" : it->second, out, len);
    }
    SourceKeyValues GetFirstTrueSubKey() {
        assert(node);
        return node->children.empty() ? SourceKeyValues{} : SourceKeyValues{&node->children[0], &node->children, 0};
    }
    SourceKeyValues GetNextTrueSubKey() {
        assert(siblings);
        return index + 1 >= siblings->size() ? SourceKeyValues{} : SourceKeyValues{&(*siblings)[index + 1], siblings, index + 1};
    }
};
using Fields = std::vector<std::pair<std::string, std::string>>;
struct EntityLumpEntry {
    Fields &fields;
    int Length;
    EntityLumpEntry(Fields &f) : fields(f), Length(f.size()) {}
    void Get(int i, char *key, int keylen, char *value = nullptr, int vallen = 0) {
        const auto &f = fields.at(i);
        copy(f.first, key, keylen);
        if (value) copy(f.second, value, vallen);
    }
    void Erase(int i) { fields.erase(fields.begin() + i); --Length; }
    void Update(int i, const char *key) { fields.at(i).first = key; }
};
'''
    tests = r'''
Node mode(const std::string &name, const std::string &map, bool lowercase = false) {
    return {name, {}, {{"1", {{lowercase ? "map" : "Map", map}}, {}}}};
}
Node mission(bool builtin = false, int versus = 0, bool lowercase = false) {
    Node modes{"modes", {}, {mode("coop", "custom_m1", lowercase)}};
    if (versus) {
        Node vs = mode("versus", versus == 3 ? "other_map" : "custom_m1");
        if (versus == 2) vs.values["AnneHappyInjected"] = "1";
        modes.children.push_back(vs);
    }
    return {"custom", {{"builtin", builtin ? "1" : "0"}}, {modes}};
}
bool eligible(std::vector<Node> list, const char *map = "custom_m1") {
    Node root{"Missions", {}, list};
    return IsCoopOnlyMap({&root}, map);
}
int main() {
    assert(!IsCoopOnlyMap({}, "custom_m1"));
    assert(!eligible({}));
    assert(eligible({mission()}));
    assert(eligible({mission(false, 0, true)}, "CUSTOM_M1"));
    assert(eligible({mission(false, 2)})); // Map vote injected versus is not native.
    assert(!eligible({mission()}, "unknown_map"));
    assert(!eligible({mission(true)}));
    assert(!eligible({mission(true, 2)}));
    assert(!eligible({mission(false, 1)}));
    assert(!eligible({mission(false, 3)})); // Native mission intentionally omits map.
    assert(!eligible({mission(), mission(false, 1)}));
    assert(!eligible({mission(false, 1), mission()})); // Registry order independent.
    Node versusOnly{"versus_only", {}, {{"modes", {}, {mode("versus", "custom_m1")}}}};
    assert(!eligible({mission(), versusOnly}));
    Node realismOnly{"realism_only", {}, {{"modes", {}, {mode("realism", "custom_m1")}}}};
    assert(!eligible({realismOnly}));

    std::string esc = "relay\x1bTrigger\x1b\x1b" "0.5\x1b-1";
    std::string longAction = "script,RunScriptCode," + std::string(2048, 'x') + ",3,1";
    Fields original{{"classname", "info_gamemode"},
        {"OnVersus", "coop_door,Kill,,0,-1"}, {"OnCoop", esc},
        {"OnUser1", "unrelated,Trigger,,0,-1"}, {"oncoop", longAction},
        {"onversus", "other,Kill,,0,-1"},
        {"OnCoopPostIO", "post,Trigger,,1,1"},
        {"OnVersusPostIO", "bad,Kill,,0,-1"}};
    Fields expected{{"classname", "info_gamemode"}, {"OnVersus", esc},
        {"OnUser1", "unrelated,Trigger,,0,-1"}, {"OnVersus", longAction},
        {"OnVersusPostIO", "post,Trigger,,1,1"}};
    for (int round = 0; round < 2; ++round) {
        Fields f = original;
        assert(RewriteOutput(f, "OnCoop", "OnVersus") == 2);
        assert(RewriteOutput(f, "OnCoopPostIO", "OnVersusPostIO") == 1);
        assert(f == expected); // Byte-exact parameters, separators, delay, fire count.
        assert(RewriteOutput(f, "OnCoop", "OnVersus") == 0);
        assert(f == expected); // Already rewritten actions are not erased.
    }
    Fields noCoop{{"OnVersus", "keep,Trigger,,0,-1"}};
    Fields unchanged = noCoop;
    assert(RewriteOutput(noCoop, "OnCoop", "OnVersus") == 0 && noCoop == unchanged);
    Fields emptyCoop{{"OnCoop", ""}, {"OnVersus", "keep,Trigger,,0,-1"}};
    unchanged = emptyCoop;
    assert(RewriteOutput(emptyCoop, "OnCoop", "OnVersus") == 0 && emptyCoop == unchanged);
    Fields phase{{"OnCoop", "coop,Trigger,,0,-1"}, {"OnVersusPostIO", "keep,Trigger,,0,-1"}};
    assert(RewriteOutput(phase, "OnCoop", "OnVersus") == 1);
    assert(RewriteOutput(phase, "OnCoopPostIO", "OnVersusPostIO") == 0);
    assert(phase.back().first == "OnVersusPostIO" && phase.back().second == "keep,Trigger,,0,-1");
    std::cout << "Coop-versus mission classification and entity I/O checks passed\n";
}
'''
    with tempfile.TemporaryDirectory(prefix="coop-versus-check-") as directory:
        path = Path(directory)
        (path / "check.cpp").write_text(harness + code + tests)
        subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"), "-o", str(path / "check")], check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
