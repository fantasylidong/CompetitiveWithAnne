#!/usr/bin/env python3
"""在服务器主机上批量导出官图 Nav 图 v2（含实体/机关层）。

必须先 sm_fm annehappy：空服默认没进比赛模式，l4d_ready_cfg_name
都不存在；已进其他模式时 sm_fm 会直接忽略，改走 sm_fchmatch。
"""
import argparse
import re
import socket
import struct
import subprocess
import sys
import time

CONTAINER = "anne4"
RCON_HOST, RCON_PORT = "172.16.0.60", 18924
L4D2_DIR = "/home/louis/l4d2/left4dead2"
SM_DIR = L4D2_DIR + "/addons/sourcemod"
OUT_DIR = SM_DIR + "/data/anne_navgraph"
TARGET_MODE = "annehappy"

MAPS = [
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


def docker(*cmd, text=True, check=True):
    result = subprocess.run(["docker", "exec", CONTAINER, *cmd],
                            check=check, capture_output=True, text=text)
    return result.stdout


def rcon_password() -> str:
    cfg = docker("cat", L4D2_DIR + "/cfg/server.cfg")
    match = re.search(r'^\s*rcon_password\s+"?([^"\r\n]+)"?', cfg, re.M | re.I)
    if not match:
        raise SystemExit("rcon_password not found in server.cfg")
    return match.group(1)


def rcon_packet(request_id: int, packet_type: int, body: str) -> bytes:
    payload = struct.pack("<ii", request_id, packet_type) + body.encode() + b"\0\0"
    return struct.pack("<i", len(payload)) + payload


def receive_packet(sock: socket.socket):
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
    def __init__(self, host, port, password):
        self.host, self.port, self.password = host, port, password

    def command(self, command: str, attempts: int = 5) -> str:
        last_error = None
        for attempt in range(attempts):
            try:
                with socket.create_connection((self.host, self.port), timeout=5.0) as sock:
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
                        raise RuntimeError("missing RCON auth response")
                    sock.sendall(rcon_packet(2, 2, command))
                    request_id, _, body = receive_packet(sock)
                    return body if request_id == 2 else ""
            except (OSError, RuntimeError) as error:
                last_error = error
                time.sleep(min(1.0 + attempt, 5.0))
        raise RuntimeError(f"RCON failed: {command}: {last_error}")


def current_map(rcon) -> str:
    status = rcon.command("status")
    match = re.search(r"^map\s*:\s*(\S+)", status, re.M)
    return match.group(1) if match else ""


def human_count(rcon) -> int:
    status = rcon.command("status")
    match = re.search(r"players\s*:\s*(\d+)\s+humans", status)
    return int(match.group(1)) if match else 0


def export_file_ok(map_name: str) -> bool:
    out = docker("sh", "-c",
                 f"test -s {OUT_DIR}/{map_name}.json && grep -q '\"map\":\"{map_name}\"' {OUT_DIR}/{map_name}.json && grep -q '\"ents\"' {OUT_DIR}/{map_name}.json && echo OK || echo NO",
                 check=False)
    return "OK" in out


def bot_count(rcon) -> int:
    status = rcon.command("status")
    match = re.search(r"players\s*:\s*\d+\s+humans,\s*(\d+)\s+bots", status)
    return int(match.group(1)) if match else 0


def ready_cfg_name(rcon) -> str:
    try:
        raw = rcon.command("sm_cvar l4d_ready_cfg_name")
    except RuntimeError:
        return ""
    if "无法找到" in raw or "Unknown command" in raw or "not found" in raw.lower():
        return ""
    match = re.search(r'"l4d_ready_cfg_name"\s*=\s*"([^"]*)"', raw)
    if match:
        return match.group(1)
    match = re.search(r'值:\s*"([^"]+)"', raw)
    if match:
        return match.group(1)
    match = re.search(r'=\s*"([^"]+)"', raw)
    return match.group(1) if match else ""


def is_annehappy(name: str) -> bool:
    return "annehappy" in name.lower().replace(" ", "").replace("_", "")


def ensure_annehappy(rcon) -> str:
    """空服先 sm_fm；已进其他模式则 sm_fchmatch。返回切换前的模式名。"""
    original = ready_cfg_name(rcon)
    print(f"[batch] current mode={original or '(none)'}", flush=True)
    if is_annehappy(original):
        print("[batch] already annehappy", flush=True)
        return original
    if original:
        print(f"[batch] sm_fchmatch {TARGET_MODE} (sm_fm ignored while match loaded)", flush=True)
        try:
            reply = rcon.command(f"sm_fchmatch {TARGET_MODE}")
            print(f"[batch] fchmatch: {reply.strip()[:160]}", flush=True)
        except RuntimeError as error:
            print(f"[batch] WARN fchmatch: {error}", flush=True)
    else:
        print(f"[batch] sm_fm {TARGET_MODE}", flush=True)
        try:
            reply = rcon.command(f"sm_fm {TARGET_MODE}")
            print(f"[batch] fm: {reply.strip()[:160]}", flush=True)
        except RuntimeError as error:
            print(f"[batch] WARN fm: {error}", flush=True)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        time.sleep(4)
        try:
            current = ready_cfg_name(rcon)
        except RuntimeError:
            continue
        if is_annehappy(current):
            print(f"[batch] mode now {current}", flush=True)
            return original
    print("[batch] WARN annehappy not confirmed, continuing anyway", flush=True)
    return original


def wait_annehappy(rcon, timeout=90) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if is_annehappy(ready_cfg_name(rcon)):
                return True
        except RuntimeError:
            pass
        time.sleep(3)
    return False


def ensure_environment(rcon):
    """srcds 被监督进程自动重启后，手动加载的插件与运行时 cvar 会全部
    丢失（矩阵 runner 同款场景）。每图开工前检测并自愈。
    切图时 AnneHappy 会短暂卸掉，先等它自己回来，不要再 sm_fm 一轮。"""
    if not is_annehappy(ready_cfg_name(rcon)):
        if wait_annehappy(rcon, 90):
            print("[batch] annehappy came back after map change", flush=True)
        else:
            print("[batch] WARN annehappy still missing; not calling sm_fm again", flush=True)
    probe = rcon.command("sm_navmatrix_status")
    if "[NavMatrix]" not in probe:
        print("[batch] environment lost (srcds restart?), re-bootstrapping", flush=True)
        rcon.command("sm plugins load_unlock")
        rcon.command("sm plugins load anne_navgraph_export")
        rcon.command("sm plugins load optional/AnneHappy/l4d_CreateSurvivorBot.smx")
        rcon.command("sm plugins load disabled/test/anne_nav_wave_matrix.smx")
    rcon.command("stripper_cfg_path cfg/stripper/zonemod_anne")
    rcon.command("director_vs_convert_pills 0")
    rcon.command("sv_cheats 1")
    rcon.command("sb_all_bot_game 1")
    rcon.command("sb_stop 1")


def parse_args():
    parser = argparse.ArgumentParser(description="Export official navgraphs on an empty Anne server")
    parser.add_argument("--container", default=CONTAINER)
    parser.add_argument("--host", default=RCON_HOST)
    parser.add_argument("--port", type=int, default=RCON_PORT)
    parser.add_argument("--maps", nargs="*")
    parser.add_argument("--skip-mode-switch", action="store_true",
                        help="不要 sm_fm（空服 unload_all 会触发监督重启）")
    return parser.parse_args()


def main():
    global CONTAINER, RCON_HOST, RCON_PORT, MAPS
    args = parse_args()
    CONTAINER = args.container
    RCON_HOST = args.host
    RCON_PORT = args.port
    if args.maps:
        MAPS = args.maps
    print(f"[batch] target {CONTAINER} {RCON_HOST}:{RCON_PORT} maps={len(MAPS)}", flush=True)

    password = rcon_password()
    rcon = SourceRcon(RCON_HOST, RCON_PORT, password)

    humans = human_count(rcon)
    if humans > 0:
        raise SystemExit(f"ABORT: {humans} human player(s) online")

    initial_map = current_map(rcon) or "c2m1_highway"
    print(f"[batch] initial map={initial_map}", flush=True)
    if args.skip_mode_switch:
        original_mode = ready_cfg_name(rcon)
        print(f"[batch] skip mode switch, current={original_mode or '(none)'}", flush=True)
    else:
        original_mode = ensure_annehappy(rcon)

    rcon.command("sm plugins load_unlock")
    load_reply = rcon.command("sm plugins load anne_navgraph_export")
    print(f"[batch] plugin load: {load_reply.strip()[:120]}", flush=True)
    if "failed to load" in load_reply:
        rcon.command("sm plugins load_lock")
        raise SystemExit("ABORT: plugin failed to load")

    # 物品完整布局（松散实例 + director 密度放置/删减）只在回合开始后
    # 存在。空服不会自己开局：用矩阵测试的 bot 探针创建冻结生还者触发
    # 回合，导出后清理。
    rcon.command("sm plugins load optional/AnneHappy/l4d_CreateSurvivorBot.smx")
    rcon.command("sm plugins load disabled/test/anne_nav_wave_matrix.smx")
    rcon.command("sv_cheats 1")
    rcon.command("sb_all_bot_game 1")
    rcon.command("sb_stop 1")

    # annehappy 会带 zonemod_anne stripper；这里再写一次，防 srcds 重启丢路径。
    stripper_raw = rcon.command("stripper_cfg_path")
    stripper_match = re.search(r'"stripper_cfg_path"\s*=\s*"([^"]*)"', stripper_raw)
    initial_stripper = stripper_match.group(1) if stripper_match else "cfg/stripper"
    print(f"[batch] initial stripper_cfg_path={initial_stripper}", flush=True)
    rcon.command("stripper_cfg_path cfg/stripper/zonemod_anne")
    rcon.command("director_vs_convert_pills 0")

    ok, failed = [], []
    try:
        for index, map_name in enumerate(MAPS, 1):
            if human_count(rcon) > 0:
                print("[batch] ABORT mid-run: human player joined", flush=True)
                break

            success = False
            reason = ""
            # srcds 可能在 changelevel 时被监督进程重启（丢插件/丢 cvar/丢
            # stripper 路径）。activate 报 Unknown command 即为该信号：
            # 原地自愈并重跑本图，避免带病导出。
            for attempt in range(3):
                print(f"[batch] ({index}/{len(MAPS)}) changelevel {map_name}"
                      + (f" (retry {attempt})" if attempt else ""), flush=True)
                # 删除旧文件，防止把上一轮的坏数据误判为本轮成功
                docker("rm", "-f", f"{OUT_DIR}/{map_name}.json", check=False)
                try:
                    rcon.command("stripper_cfg_path cfg/stripper/zonemod_anne")
                except RuntimeError:
                    pass
                try:
                    rcon.command(f"changelevel {map_name}")
                except RuntimeError:
                    pass
                deadline = time.monotonic() + 120
                loaded = False
                while time.monotonic() < deadline:
                    time.sleep(4)
                    try:
                        if current_map(rcon) == map_name:
                            loaded = True
                            break
                    except RuntimeError:
                        pass
                if not loaded:
                    reason = "load timeout"
                    continue
                try:
                    ensure_environment(rcon)
                except RuntimeError as error:
                    print(f"[batch] WARN ensure_environment: {error}", flush=True)

                # 探针创建 4 名冻结生还者并合成 round_start（触发 director
                # 物品放置）。成功判据与矩阵 runner 相同："[NavMatrix] active"。
                spawned = False
                environment_lost = False
                activate_deadline = time.monotonic() + 60
                response = ""
                while time.monotonic() < activate_deadline:
                    try:
                        response = rcon.command("sm_navmatrix_activate")
                    except RuntimeError:
                        response = ""
                    if "[NavMatrix] active" in response:
                        spawned = True
                        break
                    if "Unknown command" in response:
                        environment_lost = True
                        break
                    time.sleep(2.0)
                if environment_lost:
                    print(f"[batch] WARN {map_name}: environment lost during load, retrying map", flush=True)
                    reason = "environment lost"
                    continue
                if not spawned:
                    print(f"[batch] WARN {map_name}: activate failed ({response.strip()[:80]}), item layout may be incomplete", flush=True)
                else:
                    time.sleep(6)  # director populate + 回合稳定

                time.sleep(5)
                try:
                    if current_map(rcon) != map_name:
                        print(f"[batch] WARN {map_name}: map drifted to {current_map(rcon)}, retrying", flush=True)
                        reason = "map drifted"
                        continue
                except RuntimeError as error:
                    print(f"[batch] WARN {map_name}: map check failed: {error}", flush=True)
                    reason = "map check failed"
                    continue
                reply = ""
                for _ in range(4):
                    try:
                        reply = rcon.command("sm_navgraph_export")
                    except RuntimeError as error:
                        reply = str(error)
                    if export_file_ok(map_name):
                        success = True
                        line = reply.strip().splitlines()[-1] if reply.strip() else "(no reply)"
                        print(f"[batch] OK {map_name}: {line[:160]}", flush=True)
                        break
                    time.sleep(4)
                if not success:
                    reason = (reply or "").strip()[:120]
                try:
                    rcon.command("sm_navmatrix_clear")
                except RuntimeError:
                    pass
                if success:
                    break

            if success:
                ok.append(map_name)
            else:
                failed.append((map_name, reason))
                print(f"[batch] FAIL {map_name}: {reason}", flush=True)
    finally:
        try:
            rcon.command("sm_navmatrix_clear")
            rcon.command("sm plugins unload disabled/test/anne_nav_wave_matrix")
            rcon.command("sm plugins unload optional/AnneHappy/l4d_CreateSurvivorBot")
            rcon.command(f"stripper_cfg_path {initial_stripper}")
            rcon.command("sb_stop 0")
            rcon.command("sb_all_bot_game 0")
            rcon.command("sv_cheats 0")
            rcon.command("sm plugins unload anne_navgraph_export")
            rcon.command("sm plugins load_lock")
            if original_mode and not is_annehappy(original_mode):
                print(f"[batch] restore mode via sm_fchmatch {original_mode}", flush=True)
                rcon.command(f"sm_fchmatch {original_mode}")
            rcon.command(f"changelevel {initial_map}")
        except RuntimeError as error:
            print(f"[batch] RESTORE WARNING: {error}", flush=True)

    print(f"[batch] DONE ok={len(ok)} failed={len(failed)}", flush=True)
    for map_name, reason in failed:
        print(f"[batch] failed: {map_name}: {reason}", flush=True)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
