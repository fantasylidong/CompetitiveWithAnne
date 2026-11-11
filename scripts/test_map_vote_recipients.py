#!/usr/bin/env python3
"""Exercise the three production map-vote dispatch blocks with C++ stubs."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "addons/sourcemod/scripting/l4d2_map_vote.sp"


def dispatch(source, name):
    start = re.search(rf"^void {name}\(", source, re.M).start()
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    block = source[start:end].split("    int team;", 1)[1]
    block = block.replace("sizeof info[]", "sizeof info[0]")
    # SourcePawn zero-initializes local integers; C++ does not.
    block = block.replace("int numClients;", "int numClients = 0;")
    return f'''void {name}(int client) {{
    Vote vote;
    char buffer[128], info[2][64] = {{"mission", "chapter"}};
    const char *item = "mission", *mission = "mission";
    int team;
{block}
'''


HOST = r'''
#include <cassert>
#include <cstdio>
#include <vector>
constexpr int MAXPLAYERS = 16, MaxClients = MAXPLAYERS;
int teams[MAXPLAYERS + 1]{};
bool bots[MAXPLAYERS + 1]{};
std::vector<int> recipients, languages;
int calls = 0, titles = 0;
bool started = false, active = true;
bool IsClientInGame(int client) { return teams[client] != 0; }
bool IsFakeClient(int client) { return bots[client]; }
int GetClientTeam(int client) { return teams[client]; }
void fmt_Translate(const char *, char *, int, int client, const char *) {
    languages.push_back(client);
}
struct Vote {
    void SetTitle(const char *, ...) { ++titles; }
    bool DisplayVote(const int *clients, int count, int seconds) {
        ++calls;
        assert(count >= 0 && count <= MAXPLAYERS && seconds == 20);
        // Native_DisplayVote accepts only the first successful start.
        if (started) return false;
        if (count == 0) { active = false; return false; }
        recipients.assign(clients, clients + count);
        started = true;
        return true;
    }
};
'''

CHECKS = r'''
int main() {
    for (auto send : {VoteNextMap, VoteChangeMission, VoteChangeMap}) {
        for (int scenario = 0; scenario < 4; ++scenario) {
            for (int i = 1; i <= MaxClients; ++i) {
                teams[i] = 0; bots[i] = false;
            }
            std::vector<int> expected;
            if (scenario == 0) {
                teams[1] = 2; bots[1] = true;  // Lowest slot is a bot.
                teams[2] = teams[6] = 2;
                teams[3] = 1; teams[4] = 4;    // Ineligible teams.
                teams[5] = teams[8] = 3;
                teams[7] = 3; bots[7] = true;
                expected = {2, 5, 6, 8};      // Initiator is not first.
            } else if (scenario == 1) {
                teams[6] = 2; expected = {6};
            } else if (scenario == 2) {
                for (int i = 1; i <= MaxClients; ++i) {
                    teams[i] = 2 + i % 2; expected.push_back(i);
                }
            } // Final scenario: empty electorate must reset the vote.
            calls = titles = 0; started = false; active = true;
            recipients.clear(); languages.clear();
            send(6);
            assert(calls == 1 && titles == 1);
            assert(recipients == expected);
            assert(started == !expected.empty() && active == started);
            assert(!languages.empty());
            for (int language : languages) assert(language == 6);
        }
    }
    puts("PASS: all three map votes broadcast once to the full eligible roster");
}
'''


def main():
    source = SOURCE.read_text()
    code = HOST + "\n".join(dispatch(source, name) for name in (
        "VoteNextMap", "VoteChangeMission", "VoteChangeMap")) + CHECKS
    with tempfile.TemporaryDirectory(prefix="map-vote-check-") as directory:
        path = Path(directory)
        (path / "check.cpp").write_text(code)
        subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"),
                        "-o", str(path / "check")], check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
