#!/usr/bin/env python3
"""Run isolated 12-SI spawn waves at directed-Nav flow checkpoints."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import socket
import struct
import subprocess
import time
from collections import Counter
from pathlib import Path


OFFICIAL_MAPS = [
    "c1m1_hotel", "c1m2_streets", "c1m3_mall", "c1m4_atrium",
    "c2m1_highway", "c2m2_fairgrounds", "c2m3_coaster", "c2m4_barns", "c2m5_concert",
    "c3m1_plankcountry", "c3m2_swamp", "c3m3_shantytown", "c3m4_plantation",
    "c4m1_milltown_a", "c4m2_sugarmill_a", "c4m3_sugarmill_b", "c4m4_milltown_b", "c4m5_milltown_escape",
    "c5m1_waterfront", "c5m2_park", "c5m3_cemetery", "c5m4_quarter", "c5m5_bridge",
    "c6m1_riverbank", "c6m2_bedlam", "c6m3_port",
    "c7m1_docks", "c7m2_barge", "c7m3_port",
    "c8m1_apartment", "c8m2_subway", "c8m3_sewers", "c8m4_interior", "c8m5_rooftop",
    "c9m1_alleys", "c9m2_lots",
    "c10m1_caves", "c10m2_drainage", "c10m3_ranchhouse", "c10m4_mainstreet", "c10m5_houseboat",
    "c11m1_greenhouse", "c11m2_offices", "c11m3_garage", "c11m4_terminal", "c11m5_runway",
    "c12m1_hilltop", "c12m2_traintunnel", "c12m3_bridge", "c12m4_barn", "c12m5_cornfield",
    "c13m1_alpinecreek", "c13m2_southpinestream", "c13m3_memorialbridge", "c13m4_cutthroatcreek",
    "c14m1_junkyard", "c14m2_lighthouse",
]

TEST_CVARS = {
    "sv_cheats": "1",
    "sv_hibernate_when_empty": "0",
    "sb_all_bot_game": "1",
    # Freeze only survivor bots. nb_stop also freezes spawned infected and
    # creates artificial invisible-timeout/teleport results.
    "sb_stop": "1",
    "nb_stop": "0",
    # infected_control uses Director-assisted validation/fallback internally; forcing
    # this cvar also changes which infected Navs the engine reports as blocked.
    "director_no_specials": "0",
    "director_no_bosses": "1",
    "z_common_limit": "0",
    "inf_traitor_enable": "0",
    "inf_antibait_enable": "0",
    "inf_TeleportSi": "0",
    # This fixture measures directed-Nav candidate throughput, so support-class
    # tactical release must not hold Boomer/Spitter in the queue after the
    # pressure classes have been seeded.
    "inf_support_unlock_killers": "0",
    "inf_support_unlock_ratio": "0.0",
    "inf_support_unlock_grace": "0.0",
    "inf_spawn_perf_stats": "1",
    "inf_DebugMode": "1",
    "inf_spawn_attempts_per_frame": "8",
    "inf_spawn_frame_budget_ms": "4.0",
    "inf_spawn_nav_candidates_per_slice": "512",
    "inf_spawn_nav_expensive_per_slice": "16",
    "inf_spawn_nav_slice_budget_ms": "2.0",
    "versus_special_respawn_interval": "16.0",
    "l4d_infected_limit": "12",
    "z_smoker_limit": "3",
    "z_boomer_limit": "2",
    "z_hunter_limit": "3",
    "z_spitter_limit": "2",
    "z_jockey_limit": "3",
    "z_charger_limit": "3",
}

# These three values are deliberately overridden only to isolate candidate
# throughput. Restore the Anne production policy even when a previous aborted
# matrix run left its test values behind before capture_state() ran.
PRODUCTION_RESTORE_CVARS = {
    "inf_support_unlock_killers": "-1",
    "inf_support_unlock_ratio": "0.4",
    "inf_support_unlock_grace": "1.0",
}

PLUGIN_PATHS = (
    "optional/AnneHappy/l4d_CreateSurvivorBot.smx",
    "disabled/test/anne_nav_wave_matrix.smx",
    "optional/AnneHappy/infected_control.smx",
)


def rcon_packet(request_id: int, packet_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, packet_type) + body.encode() + b"\0\0"
    return struct.pack("<i", len(payload)) + payload


def receive_packet(sock: socket.socket) -> tuple[int, int, str]:
    size_data = sock.recv(4)
    if len(size_data) != 4:
        raise RuntimeError("short RCON size")
    size = struct.unpack("<i", size_data)[0]
    payload = b""
    while len(payload) < size:
        chunk = sock.recv(size - len(payload))
        if not chunk:
            raise RuntimeError("short RCON packet")
        payload += chunk
    request_id, packet_type = struct.unpack("<ii", payload[:8])
    return request_id, packet_type, payload[8:-2].decode("utf-8", errors="replace")


class SourceRcon:
    def __init__(self, host: str, port: int, password: str):
        self.host = host
        self.port = port
        self.password = password

    def command(self, command: str, attempts: int = 5) -> str:
        last_error: Exception | None = None
        for attempt in range(attempts):
            try:
                with socket.create_connection((self.host, self.port), timeout=5.0) as sock:
                    # Plugin reload can synchronously initialize the persisted
                    # directed Nav graph before Source sends the RCON reply.
                    sock.settimeout(15.0)
                    sock.sendall(rcon_packet(1, 3, self.password))
                    authenticated = False
                    for _ in range(2):
                        request_id, packet_type, _ = receive_packet(sock)
                        if request_id == -1:
                            raise RuntimeError("RCON authentication failed")
                        if request_id == 1 and packet_type == 2:
                            authenticated = True
                            break
                    if not authenticated:
                        raise RuntimeError("missing RCON authentication response")
                    sock.sendall(rcon_packet(2, 2, command))
                    request_id, _, body = receive_packet(sock)
                    return body if request_id == 2 else ""
            except (OSError, RuntimeError) as error:
                last_error = error
                time.sleep(min(1.0 + attempt, 5.0))
        raise RuntimeError(f"RCON command failed: {command}: {last_error}")


class MatrixRunner:
    log_path = "/home/louis/l4d2/left4dead2/addons/sourcemod/logs/infected_control_fdxxnav.txt"

    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.rcon = SourceRcon(args.rcon_host, args.rcon_port, args.password)
        self.output = Path(args.output)
        self.output.mkdir(parents=True, exist_ok=True)
        (self.output / "raw").mkdir(exist_ok=True)
        self.initial_map = ""
        self.initial_cvars: dict[str, str] = {}
        self.initial_plugins: dict[str, bool] = {}

    def docker(self, *command: str, text: bool = True) -> str | bytes:
        result = subprocess.run(
            ["docker", "exec", self.args.container, *command],
            check=True, capture_output=True, text=text)
        return result.stdout

    def log_size(self) -> int:
        try:
            return int(self.docker("stat", "-c", "%s", self.log_path).strip())
        except (subprocess.CalledProcessError, ValueError):
            return 0

    def log_since(self, offset: int) -> str:
        start = max(1, offset + 1)
        data = self.docker("tail", "-c", f"+{start}", self.log_path, text=False)
        return data.decode("utf-8", errors="replace")

    def wait_for_map(self, map_name: str) -> None:
        deadline = time.monotonic() + self.args.map_timeout
        while time.monotonic() < deadline:
            try:
                output = self.rcon.command("status", attempts=1)
                if re.search(rf"^map\s*:\s*{re.escape(map_name)}\s*$", output, re.MULTILINE):
                    return
            except RuntimeError:
                pass
            time.sleep(1.0)
        raise RuntimeError(f"map did not become ready: {map_name}")

    def current_map(self) -> str:
        output = self.rcon.command("status")
        match = re.search(r"^map\s*:\s*(\S+)\s*$", output, re.MULTILINE)
        return match.group(1) if match else ""

    def plugin_running(self, path: str) -> bool:
        output = self.rcon.command(f"sm plugins info {path}")
        return bool(re.search(r"\bStatus:\s*running\b", output, re.IGNORECASE))

    def query_cvar(self, name: str) -> str | None:
        output = self.rcon.command(f"sm_cvar {name}")
        patterns = (
            rf'Value of cvar "{re.escape(name)}":\s*"([^"]*)"',
            rf'"{re.escape(name)}"\s*=\s*"([^"]*)"',
        )
        for pattern in patterns:
            match = re.search(pattern, output, re.IGNORECASE)
            if match:
                return match.group(1)
        return None

    def capture_state(self) -> None:
        self.initial_map = self.current_map()
        self.initial_plugins = {
            path: self.plugin_running(path) for path in PLUGIN_PATHS
        }
        for name in TEST_CVARS:
            value = self.query_cvar(name)
            if value is not None:
                self.initial_cvars[name] = value

    @staticmethod
    def parse_status(output: str) -> dict[str, float | int | str]:
        line = next((item for item in output.splitlines()
                     if "[NavMatrix] status" in item), "")
        values: dict[str, float | int | str] = {}
        for key, raw in re.findall(r"(\w+)=([^\s]+)", line):
            try:
                values[key] = float(raw) if "." in raw else int(raw)
            except ValueError:
                values[key] = raw
        return values

    def bootstrap_plugins(self) -> None:
        survivor_plugin, matrix_plugin, production_plugin = PLUGIN_PATHS
        commands = ["sm plugins load_unlock"]
        if not self.plugin_running(survivor_plugin):
            commands.append(f"sm plugins load {survivor_plugin}")

        # SourceMod runs OnGameFrame forwards in plugin load order. Reload the
        # matrix probe first and production second so survivor locks are applied
        # before infected_control captures its per-frame eye snapshot.
        if self.plugin_running(matrix_plugin):
            commands.append(f"sm plugins unload {matrix_plugin}")
        commands.append(f"sm plugins load {matrix_plugin}")
        commands.append(
            f"sm plugins {'reload' if self.plugin_running(production_plugin) else 'load'} "
            f"{production_plugin}")
        for command in commands:
            try:
                response = self.rcon.command(command)
            except RuntimeError:
                # A reload may finish server-side while its RCON reply is lost
                # during plugin forwards. Verify the resulting state once.
                if (command.startswith("sm plugins reload ")
                        and self.plugin_running(production_plugin)):
                    continue
                raise
            if "failed to load" in response.lower():
                raise RuntimeError(f"plugin setup failed: {command}: {response.strip()}")
        probe = self.rcon.command("sm_navmatrix_status")
        if "[NavMatrix] status" not in probe:
            raise RuntimeError(f"matrix probe unavailable: {probe.strip()}")

    def wait_for_graph(self) -> str:
        deadline = time.monotonic() + self.args.graph_timeout
        last = ""
        while time.monotonic() < deadline:
            last = self.rcon.command("sm_navmatrix_status")
            status = self.parse_status(last)
            if (status.get("graphStatus") == 3
                    and status.get("graphComplete") == 1
                    and int(status.get("graphAreas", 0)) > 0
                    and int(status.get("graphEdges", 0)) > 0):
                return last
            time.sleep(0.25)
        raise RuntimeError(f"directed Nav graph did not become complete: {last.strip()}")

    def configure_map(self) -> None:
        for name, value in TEST_CVARS.items():
            command = f"sm_cvar {name} {value}"
            response = self.rcon.command(command)
            if "failed to load" in response.lower():
                raise RuntimeError(f"plugin setup failed: {command}: {response.strip()}")
        activation = self.rcon.command("sm_navmatrix_activate")
        if "Unknown command" in activation or "not found" in activation.lower():
            # A srcds/SourceMod session can survive a short RCON reconnect while
            # losing the disabled test probe. Restore the probe before treating
            # the checkpoint as a fixture failure.
            self.bootstrap_plugins()
            activation = self.rcon.command("sm_navmatrix_activate")
        if "[NavMatrix] active" not in activation:
            raise RuntimeError(f"empty-server round activation failed: {activation.strip()}")
        time.sleep(self.args.graph_wait)
        self.wait_for_graph()

    def wait_for_empty_infected(self) -> str:
        deadline = time.monotonic() + 5.0
        last = ""
        while time.monotonic() < deadline:
            last = self.rcon.command("sm_navmatrix_status")
            status = self.parse_status(last)
            if (status.get("infectedTeam") == 0
                    and status.get("aliveSI") == 0
                    and status.get("humanClients") == 0
                    and status.get("humanInfected") == 0):
                return last
            time.sleep(0.1)
        raise RuntimeError(f"test baseline is not empty: {last.strip()}")

    def scenario_flow_tolerance(self, map_name: str, percent: int) -> float:
        # c8m4's elevator splits raw flow into two sparse multi-floor bands.
        # 45-55% requests consistently resolve to the nearest live band.
        if map_name == "c8m4_interior" and 45 <= percent <= 60:
            return max(self.args.flow_tolerance, 18.0)
        return self.args.flow_tolerance

    def prepare(self, percent: int) -> str:
        self.rcon.command("sm_stopspawn")
        self.rcon.command("sm_navmatrix_clear")
        self.wait_for_empty_infected()
        # StopAll clears spawn history but NavArea cooldowns intentionally live
        # for 0.5s. Reusing a map without a short gap makes the next fixture
        # inherit the previous wave's rejected areas and produces false long
        # tails, especially on compact multi-floor maps such as c6m2.
        if self.args.wave_reset_wait > 0.0:
            time.sleep(self.args.wave_reset_wait)
        response = ""
        status = ""
        for _ in range(100):
            response = self.rcon.command(f"sm_navmatrix_prepare {percent}")
            if "ready map=" not in response:
                time.sleep(0.1)
                continue
            status = self.rcon.command("sm_navmatrix_status")
            values = self.parse_status(status)
            map_name = values.get("map", "")
            flow_tolerance = self.scenario_flow_tolerance(str(map_name), percent)
            if (values.get("controlled") == 4
                    and values.get("validPosition") == 4
                    and values.get("uniqueNav") == 4
                    and float(values.get("spreadMin", 0.0)) >= 128.0
                    and float(values.get("spreadMax", 99999.0)) <= 800.0
                    and abs(float(values.get("minPositionPct", -999.0)) - percent)
                        <= flow_tolerance
                    and abs(float(values.get("maxPositionPct", -999.0)) - percent)
                        <= flow_tolerance):
                return f"{response.rstrip()}\n{status.rstrip()}"
        return f"{response.rstrip()}\n{status.rstrip()}"

    def wait_for_twelve(self) -> tuple[bool, str, float, int]:
        started = time.monotonic()
        deadline = started + self.args.wave_timeout
        last_status = ""
        peak_alive = 0
        while time.monotonic() < deadline:
            last_status = self.rcon.command("sm_navmatrix_status")
            status = self.parse_status(last_status)
            alive = int(status.get("aliveSI", 0))
            peak_alive = max(peak_alive, alive)
            if (alive == 12
                    and status.get("humanInfected") == 0
                    and int(status.get("visibilityChecks", 0)) >= 12):
                return True, last_status, time.monotonic() - started, peak_alive
            time.sleep(0.1)
        return False, last_status, time.monotonic() - started, peak_alive

    @staticmethod
    def metric_summary(lines: list[str], field: str,
                       allow_negative: bool = False) -> dict:
        values = []
        pattern = re.compile(rf"\b{re.escape(field)}=(-?[0-9.]+)")
        for line in lines:
            match = pattern.search(line)
            if not match:
                continue
            value = float(match.group(1))
            if allow_negative or value >= 0.0:
                values.append(value)
        if not values:
            return {"count": 0, "min": None, "p50": None,
                    "p95": None, "max": None, "avg": None}
        values.sort()

        def percentile(percent: float) -> float:
            index = round((len(values) - 1) * percent)
            return round(values[index], 3)

        return {
            "count": len(values),
            "min": round(values[0], 3),
            "p50": percentile(0.50),
            "p95": percentile(0.95),
            "max": round(values[-1], 3),
            "avg": round(sum(values) / len(values), 3),
        }

    @staticmethod
    def summarize(raw: str) -> dict:
        lines = raw.splitlines()
        begin_mark = next((index for index, line in enumerate(lines)
                           if "[NavMatrix] End" in line and " begin requested=" in line), 0)
        result_mark = next((index for index, line in enumerate(lines[begin_mark:], begin_mark)
                            if "[NavMatrix] End" in line and " result requested=" in line),
                           len(lines) - 1)
        lines = lines[begin_mark:result_mark + 1]
        begin_lines = [line for line in lines if "[SpawnWave][Begin]" in line]
        first_wave = None
        if begin_lines:
            match = re.search(r"\bwave=(\d+)", begin_lines[0])
            first_wave = int(match.group(1)) if match else None
        spawn_lines = [line for line in lines if "[SpawnWave][Spawn]" in line
                       and (first_wave is None or f"wave={first_wave} " in line)]
        successes = [line for line in spawn_lines if "result=success" in line]
        failures = [line for line in spawn_lines if "result=failed" in line]
        actual_rejects = [line for line in lines if "[SPAWN REJECT ACTUAL]" in line]
        directed_retargets = [line for line in lines
                              if "[TARGET] directed coverage retarget" in line]
        runtime_target_changes = [line for line in lines
                                  if "[TARGET] runtime change" in line]
        normal_successes = [line for line in successes if "mode=normal_" in line]
        teleport_successes = [line for line in successes if "mode=teleport_" in line]
        nav_success = [line for line in normal_successes if "mode=normal_nav" in line]
        range_success = [line for line in normal_successes if "normal_director_range" in line]
        unrestricted_success = [line for line in normal_successes if "normal_director_unrestricted" in line]
        actual_valid = [line for line in normal_successes if "actualValid=1" in line]
        classes = Counter()
        elapsed = []
        for line in normal_successes:
            class_match = re.search(r"class=(\w+)", line)
            elapsed_match = re.search(r"waveElapsedMs=([0-9.]+)", line)
            if class_match:
                classes[class_match.group(1)] += 1
            if elapsed_match:
                elapsed.append(float(elapsed_match.group(1)))
        graph_lines = [line for line in lines if "[SpawnPerf][Graph]" in line]
        summary_lines = [line for line in lines if "[SpawnWave][Summary]" in line
                         and (first_wave is None or f"wave={first_wave} " in line)]
        first_begin = begin_lines[0] if begin_lines else ""
        first_summary = summary_lines[-1] if summary_lines else ""
        begin_values = {key: int(value) for key, value in
            re.findall(r"\b(plannedAi|pendingAtStart|wave)=(\d+)", first_begin)}
        summary_values = {key: int(value) for key, value in re.findall(
            r"\b(normalSuccess|remainingQueue|failed|wave)=(\d+)", first_summary)}
        distance_metrics = {
            "team_min_distance": MatrixRunner.metric_summary(
                normal_successes, "teamMinDistance"),
            "target_distance": MatrixRunner.metric_summary(
                normal_successes, "targetDistance"),
            "nav_distance": MatrixRunner.metric_summary(
                normal_successes, "navDistance"),
            "spawn_call_ms": MatrixRunner.metric_summary(
                normal_successes, "spawnCallMs"),
        }
        return {
            "wave": first_wave,
            "wave_count": len(begin_lines),
            "spawn_success": len(normal_successes),
            "teleport_success": len(teleport_successes),
            "spawn_failed_calls": len(failures),
            "actual_spawn_rejects": len(actual_rejects),
            "directed_retargets": len(directed_retargets),
            "runtime_target_changes": len(runtime_target_changes),
            "actual_valid": len(actual_valid),
            "nav_success": len(nav_success),
            "director_range_success": len(range_success),
            "director_unrestricted_success": len(unrestricted_success),
            "last_spawn_ms": max(elapsed) if elapsed else None,
            "server_wave_ms": max(elapsed) if elapsed else None,
            "distance_metrics": distance_metrics,
            "classes": dict(sorted(classes.items())),
            "begin": first_begin,
            "summary": first_summary,
            "begin_values": begin_values,
            "summary_values": summary_values,
            "graph": graph_lines[-1] if graph_lines else "",
        }

    def run_scenario(self, map_name: str, percent: int, index: int) -> dict:
        offset = self.log_size()
        prepare_output = self.prepare(percent)
        status_values = self.parse_status(prepare_output)
        flow_tolerance = self.scenario_flow_tolerance(map_name, percent)
        prepared = (
            "ready map=" in prepare_output
            and status_values.get("controlled") == 4
            and status_values.get("validPosition") == 4
            and status_values.get("uniqueNav") == 4
            and float(status_values.get("spreadMin", 0.0)) >= 128.0
            and float(status_values.get("spreadMax", 99999.0)) <= 800.0
            and abs(float(status_values.get("minPositionPct", -999.0)) - percent)
                <= flow_tolerance
            and abs(float(status_values.get("maxPositionPct", -999.0)) - percent)
                <= flow_tolerance
        )
        if not prepared:
            raise RuntimeError(f"survivor flow positioning failed: {prepare_output.strip()}")
        self.rcon.command("sm_spawnperf_reset")
        self.rcon.command(f"sm_navmatrix_mark begin requested={percent}")
        self.rcon.command("sm_startspawn")
        observed_alive_12, status, wall_seconds, peak_alive = self.wait_for_twelve()
        self.rcon.command("sm_stopspawn")
        self.rcon.command("sm_spawnperf")
        self.rcon.command(
            f"sm_navmatrix_mark result requested={percent} alive12={int(observed_alive_12)} peakAlive={peak_alive} wallMs={wall_seconds * 1000.0:.1f}")
        time.sleep(0.2)

        raw = self.log_since(offset)
        raw_path = self.output / "raw" / f"{index:03d}_{map_name}_{percent}.log"
        raw_path.write_text(raw, encoding="utf-8")
        summary = self.summarize(raw)
        begin_values = summary.get("begin_values", {})
        summary_values = summary.get("summary_values", {})
        complete = (
            observed_alive_12
            and peak_alive == 12
            and summary.get("wave") == 1
            and summary.get("wave_count") == 1
            and summary.get("spawn_success") == 12
            and summary.get("actual_valid") == 12
            and summary.get("spawn_failed_calls")
                == summary.get("actual_spawn_rejects")
            and begin_values.get("plannedAi") == 12
            and begin_values.get("pendingAtStart") == 12
            and summary_values.get("normalSuccess") == 12
            and summary_values.get("remainingQueue") == 0
            and summary_values.get("failed")
                == summary.get("actual_spawn_rejects")
            and int(self.parse_status(status).get("visibilityChecks", 0)) == 12
            and int(self.parse_status(status).get("visibilityViolations", -1)) == 0
        )
        result = {
            "index": index,
            "map": map_name,
            "requested_percent": percent,
            "actual_percent": float(status_values.get("avgPositionPct", -1.0)),
            "min_percent": float(status_values.get("minPositionPct", -1.0)),
            "max_percent": float(status_values.get("maxPositionPct", -1.0)),
            "unique_nav": int(status_values.get("uniqueNav", 0)),
            "spread_min": float(status_values.get("spreadMin", 0.0)),
            "spread_max": float(status_values.get("spreadMax", 0.0)),
            "visibility_checks": int(self.parse_status(status).get("visibilityChecks", 0)),
            "visibility_violations": int(self.parse_status(status).get("visibilityViolations", -1)),
            "frame_samples": int(self.parse_status(status).get("frameSamples", 0)),
            "frame_avg_ms": float(self.parse_status(status).get("frameAvgMs", 0.0)),
            "frame_max_ms": float(self.parse_status(status).get("frameMaxMs", 0.0)),
            "frame_over_tick": int(self.parse_status(status).get("frameOverTick", 0)),
            "frame_over_2tick": int(self.parse_status(status).get("frameOver2Tick", 0)),
            "frame_over_4tick": int(self.parse_status(status).get("frameOver4Tick", 0)),
            "prepared": prepared,
            "complete_12": complete,
            "observed_alive_12": observed_alive_12,
            "peak_alive": peak_alive,
            "wall_ms": round(wall_seconds * 1000.0, 3),
            "observer_wall_ms": round(wall_seconds * 1000.0, 3),
            "prepare_output": prepare_output.strip(),
            "status": status.strip(),
            "raw_log": str(raw_path),
        }
        result.update(summary)
        server_wave_ms = result.get("server_wave_ms")
        result["within_nominal_target"] = (
            server_wave_ms is not None
            and float(server_wave_ms) <= self.args.target_wave_ms
        )
        return result

    def run(self, maps: list[str], progress: list[int]) -> list[dict]:
        results = []
        jsonl_path = self.output / "results.jsonl"
        self.bootstrap_plugins()
        with jsonl_path.open("a", encoding="utf-8") as jsonl:
            index = 0
            for map_name in maps:
                map_ready = False
                for percent in progress:
                    index += 1
                    print(f"MAP {map_name} CASE {percent}%", flush=True)
                    try:
                        if not self.args.reuse_map or not map_ready:
                            self.rcon.command(f"changelevel {map_name}")
                            self.wait_for_map(map_name)
                            self.configure_map()
                            map_ready = True
                        result = self.run_scenario(map_name, percent, index)
                        if not self.args.reuse_map:
                            map_ready = False
                    except Exception as error:
                        # The next checkpoint reloads this map so a failed wave,
                        # dynamic entity state, or stale test bot cannot leak forward.
                        map_ready = False
                        result = {
                            "index": index,
                            "map": map_name,
                            "requested_percent": percent,
                            "prepared": False,
                            "complete_12": False,
                            "error": str(error),
                        }
                    results.append(result)
                    jsonl.write(json.dumps(result, ensure_ascii=False) + "\n")
                    jsonl.flush()
                    print(
                        f"CASE {index} {map_name} {percent}% complete={result.get('complete_12')} "
                        f"success={result.get('spawn_success')} nav={result.get('nav_success')} "
                        f"actual_rejects={result.get('actual_spawn_rejects')} "
                        f"server_wave_ms={result.get('server_wave_ms')} "
                        f"observer_wall_ms={result.get('observer_wall_ms')} "
                        f"error={result.get('error', '')}",
                        flush=True)
        return results

    def restore(self) -> None:
        commands = ["sm_stopspawn", "sm_navmatrix_clear"]
        try:
            if self.initial_map:
                self.rcon.command(f"changelevel {self.initial_map}")
                self.wait_for_map(self.initial_map)
        except Exception as error:
            print(f"RESTORE map warning: {error}", flush=True)
        for name, value in self.initial_cvars.items():
            commands.append(f'sm_cvar {name} "{value}"')
        for name, value in PRODUCTION_RESTORE_CVARS.items():
            commands.append(f'sm_cvar {name} "{value}"')
        # The matrix runs against the production spawn plugin. Never unload it
        # during cleanup when an earlier RCON state probe was truncated or lost;
        # only restore the two temporary harness plugins to their initial state.
        for path in reversed(PLUGIN_PATHS[:-1]):
            if not self.initial_plugins.get(path, False):
                commands.append(f"sm plugins unload {path}")
        commands.append("sm plugins load_lock")
        for command in commands:
            try:
                self.rcon.command(command)
            except Exception as error:
                print(f"RESTORE command warning {command}: {error}", flush=True)


def write_csv(path: Path, results: list[dict]) -> None:
    fields = [
        "index", "map", "requested_percent", "actual_percent", "prepared", "complete_12",
        "min_percent", "max_percent", "observed_alive_12", "peak_alive",
        "unique_nav", "spread_min", "spread_max",
        "visibility_checks", "visibility_violations",
        "frame_samples", "frame_avg_ms", "frame_max_ms",
        "frame_over_tick", "frame_over_2tick", "frame_over_4tick",
        "wall_ms", "wave", "wave_count", "spawn_success", "teleport_success",
        "actual_valid", "spawn_failed_calls", "actual_spawn_rejects",
        "directed_retargets", "runtime_target_changes",
        "nav_success", "director_range_success", "director_unrestricted_success",
        "last_spawn_ms", "server_wave_ms", "within_nominal_target",
        "observer_wall_ms", "distance_metrics", "classes", "error",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for result in results:
            row = dict(result)
            row["classes"] = json.dumps(row.get("classes", {}), ensure_ascii=False, sort_keys=True)
            row["distance_metrics"] = json.dumps(
                row.get("distance_metrics", {}), ensure_ascii=False, sort_keys=True)
            writer.writerow(row)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--container", default="anne1")
    parser.add_argument("--rcon-host", default="10.0.1.2")
    parser.add_argument("--rcon-port", type=int, default=2331)
    parser.add_argument("--password", default=os.environ.get("RCON_PASSWORD", ""))
    parser.add_argument("--output", required=True)
    parser.add_argument("--progress", default="20,50,80")
    parser.add_argument("--maps", default="all",
        help="all or a comma-separated official map list")
    parser.add_argument("--graph-wait", type=float, default=0.5)
    parser.add_argument(
        "--wave-reset-wait", type=float, default=0.65,
        help="seconds to let NavArea cooldowns expire between reused-map waves")
    parser.add_argument("--graph-timeout", type=float, default=20.0)
    parser.add_argument("--map-timeout", type=float, default=45.0)
    parser.add_argument("--wave-timeout", type=float, default=8.0)
    parser.add_argument("--target-wave-ms", type=float, default=3000.0,
        help="nominal server-side 12-SI completion target; does not fail open-terrain cases")
    parser.add_argument("--flow-tolerance", type=float, default=8.0)
    parser.add_argument(
        "--reuse-map", action="store_true",
        help="load each map once and reset the wave/bots between progress checkpoints")
    args = parser.parse_args()
    if not args.password:
        parser.error("--password or RCON_PASSWORD is required")
    return args


def main() -> int:
    args = parse_args()
    maps = OFFICIAL_MAPS if args.maps == "all" else [item for item in args.maps.split(",") if item]
    progress = [int(item) for item in args.progress.split(",")]
    runner = MatrixRunner(args)
    results = []
    try:
        runner.capture_state()
        results = runner.run(maps, progress)
    finally:
        runner.restore()
        if results:
            write_csv(Path(args.output) / "results.csv", results)
    complete = sum(bool(item.get("complete_12")) for item in results)
    print(f"DONE cases={len(results)} complete={complete} failed={len(results) - complete}", flush=True)
    return 0 if complete == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
