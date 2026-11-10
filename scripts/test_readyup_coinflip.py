#!/usr/bin/env python3
"""Run the merged ReadyUp and Coinflip function bodies with C++ stubs."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "addons/sourcemod/scripting/optional"


def body(source, name):
    start = re.search(rf"^(?:bool|Action) {name}\(", source, re.M).start()
    end = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    readyup = (SOURCES / "readyup/action.inc").read_text()
    coinflip = (SOURCES / "coinflip.sp").read_text()
    # SourcePawn switch cases do not fall through; C++ needs explicit breaks.
    ready_body = body(readyup, "CheckFullReady").replace(
        "survReadyCount++;", "survReadyCount++; break;").replace(
        "infReadyCount++;", "infReadyCount++; break;")
    code = ready_body + "\n" + "\n".join(
        body(coinflip, name) for name in ("IsOnCooldown", "Cmd_Coinflip", "Cmd_Roll"))
    host = r'''
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
constexpr int MaxClients = 8, MAX_NAME_LENGTH = 32, DEFAULT_SIDES = 20;
constexpr int L4D2Team_Survivor = 2, L4D2Team_Infected = 3;
enum { ReadyMode_PlayerReady = 1, ReadyMode_AutoStart, ReadyMode_TeamReady };
enum Action { Plugin_Handled };
struct ConVar { int IntValue = 0; bool BoolValue = false; };
ConVar l4d_ready_unbalanced_start, l4d_ready_unbalanced_min;
ConVar survivor_limit{4}, z_max_player_zombies{4}, g_cvDelay{-1};
int readyUpMode = ReadyMode_PlayerReady, team[MaxClients + 1]{};
bool hasInfectedTeam = false, ready[MaxClients + 1]{};
bool IsClientInGame(int client) {
    assert(client > 0 && client <= MaxClients);
    return team[client] != 0;
}
bool IsPlayerReady(int client) { return ready[client]; }
int GetClientTeam(int client) { assert(IsClientInGame(client)); return team[client]; }
int GetTeamHumanCount(int which) {
    int count = 0;
    for (int i = 1; i <= MaxClients; ++i) count += team[i] == which;
    return count;
}
int now = 100, sidesArg = 0, g_iLastFlip = 0, g_iLastRoll = 0;
int messages = 0, cooldownMessages = 0, rolledSides = 0;
int GetTime() { return now; }
int GetCmdArgInt(int arg) { assert(arg == 1); return sidesArg; }
int GetURandomInt() { return 1; }
int GetRandomInt(int low, int high) { assert(low == 1 && high >= low); return high; }
void GetClientName(int client, char *name, int len) {
    assert(IsClientInGame(client)); std::snprintf(name, len, "player");
}
void CPrintToChatAll(const char *format, const char *tag, const char *phrase,
                    const char *name, int sides = 0, int result = 0) {
    assert(std::string(format) == "%t %t" && std::string(tag) == "Tag");
    assert(std::string(name) == "player");
    if (std::string(phrase) == "rolled") {
        assert(result >= 1 && result <= sides); rolledSides = sides;
    } else assert(std::string(phrase) == "Heads" || std::string(phrase) == "Tails");
    ++messages;
}
void CPrintToChat(int client, const char *format, const char *tag,
                  const char *phrase, int delay) {
    assert(IsClientInGame(client) && std::string(format) == "%t %t");
    assert(std::string(tag) == "Tag" && std::string(phrase) == "Cooldown");
    assert(delay == g_cvDelay.IntValue); ++cooldownMessages;
}
'''
    checks = r'''
int main() {
    assert(!CheckFullReady()); // Empty coop cannot start.
    team[1] = team[2] = L4D2Team_Survivor; ready[1] = true;
    assert(!CheckFullReady());
    ready[2] = true; assert(CheckFullReady()); // Actual coop roster, not slot limit.
    readyUpMode = ReadyMode_TeamReady; ready[2] = false;
    assert(CheckFullReady()); // Coop team-ready needs only a survivor vote.
    hasInfectedTeam = true; assert(!CheckFullReady());
    team[3] = L4D2Team_Infected; ready[3] = true; assert(CheckFullReady());
    readyUpMode = ReadyMode_PlayerReady; assert(!CheckFullReady());
    l4d_ready_unbalanced_start.BoolValue = true;
    l4d_ready_unbalanced_min.IntValue = 1;
    assert(!CheckFullReady()); // Both connected survivors must be ready.
    ready[2] = true; assert(CheckFullReady());
    readyUpMode = ReadyMode_AutoStart; assert(!CheckFullReady());

    Cmd_Coinflip(0, 0); Cmd_Roll(0, 0); // Server console cannot touch player APIs.
    Cmd_Coinflip(8, 0); Cmd_Roll(8, 0); // Disconnected client, no cooldown mutation.
    assert(messages == 0 && g_iLastFlip == 0 && g_iLastRoll == 0);
    Cmd_Coinflip(1, 0); Cmd_Roll(1, 0);
    assert(messages == 2 && rolledSides == 20);
    for (int sides : {0, -1, -20, 1, 6, 2147483647}) {
        sidesArg = sides; Cmd_Roll(1, 1);
        assert(rolledSides == (sides < 1 ? 20 : sides));
    }
    g_cvDelay.IntValue = 5;
    int before = messages;
    Cmd_Coinflip(1, 0); Cmd_Roll(1, 0);
    assert(messages == before && cooldownMessages == 2);
    now += 5; Cmd_Roll(1, 0); assert(messages == before);
    ++now; Cmd_Roll(1, 0); assert(messages == before + 1);
    Cmd_Coinflip(1, 0); assert(messages == before + 2); // Separate cooldowns.
    puts("PASS: coop/versus ready gates, invalid clients, die bounds, translated cooldowns");
}
'''
    with tempfile.TemporaryDirectory(prefix="readyup-coinflip-check-") as directory:
        path = Path(directory)
        (path / "check.cpp").write_text(host + code + checks)
        subprocess.run(["c++", "-std=c++17", str(path / "check.cpp"),
                        "-o", str(path / "check")], check=True)
        subprocess.run([str(path / "check")], check=True)


if __name__ == "__main__":
    main()
