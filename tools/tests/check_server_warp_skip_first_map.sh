#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
plugin="$repo_root/addons/sourcemod/scripting/optional/AnneHappy/server.sp"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$plugin" ]] || fail "missing plugin source: $plugin"

grep -Fq 'L4D_IsFirstMapInScenario()' "$plugin" \
  || fail "server warp-to-start must detect the first map in the current scenario"

grep -Fq 'g_bFirstMapInScenario' "$plugin" \
  || fail "server warp-to-start must cache whether the current map is the first map"

grep -Fq 'bool ShouldAllowSpawnWarpToStart(int client)' "$plugin" \
  || fail "server warp-to-start must use a shared guard helper"

python3 - "$plugin" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text()

def body_of(name):
    pattern = re.compile(rf'(?m)^(?:public\s+)?(?:Action|void|bool)\s+{re.escape(name)}\([^)]*\)\s*\{{')
    match = pattern.search(source)
    if not match:
        raise SystemExit(f"FAIL: missing function {name}")
    pos = match.end()
    depth = 1
    while pos < len(source) and depth:
        if source[pos] == "{":
            depth += 1
        elif source[pos] == "}":
            depth -= 1
        pos += 1
    return source[match.end():pos - 1]

guard = body_of("ShouldAllowSpawnWarpToStart")
if "g_bFirstMapInScenario" not in guard:
    raise SystemExit("FAIL: shared warp guard must skip first scenario maps")

queue = body_of("QueueSpawnWarpToStart")
timer = body_of("Timer_WarpSpawnToStart")

if "ShouldAllowSpawnWarpToStart(client)" not in queue:
    raise SystemExit("FAIL: QueueSpawnWarpToStart must use the shared warp guard")

if "ShouldAllowSpawnWarpToStart(client)" not in timer:
    raise SystemExit("FAIL: Timer_WarpSpawnToStart must re-check the shared warp guard")

print("server warp first-map skip checks passed")
PY

echo "server warp first-map static checks passed"
