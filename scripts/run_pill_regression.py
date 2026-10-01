#!/usr/bin/env python3
import argparse
import copy
import hashlib
import importlib.util
import json
import re
import secrets
import shlex
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from run_nav_wave_matrix import OFFICIAL_MAPS


ROOT = Path(__file__).resolve().parents[1]
GAME = '/home/louis/l4d2/left4dead2'
ALIAS = 'anne-cloud-01-04'
SETTINGS = {'mp_gamemode': 'versus', 'sv_hibernate_when_empty': '0', 'sb_all_bot_game': '1',
            'confogl_enable_itemtracking': '1', 'confogl_itemtracking_mapspecific': '3',
            'confogl_itemtracking_savespawns': '1', 'confogl_pills_limit': '4', 'confogl_debug': '1',
            'confogl_pills_flow_min': '0.3', 'confogl_pills_flow_max': '0.9',
            'confogl_pills_flow_separation': '0', 'confogl_pills_flow_max_detour': '300',
            'confogl_pills_flow_fill': '1', 'confogl_pills_flow_fill_min': '0.4',
            'confogl_pills_flow_fill_max': '0.8', 'confogl_pills_flow_require_valid': '1',
            'confogl_pills_flow_finale': '0', 'confogl_pills_flow_visualize': '0'}


def run(command):
    result = subprocess.run(command, capture_output=True, text=True, errors='replace', timeout=90)
    if result.returncode:
        raise RuntimeError(f'{command[0]} failed: {result.stderr[:240]}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probes', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--maps', nargs='*', choices=OFFICIAL_MAPS, default=OFFICIAL_MAPS)
    parser.add_argument('--registry-tool', type=Path, default=Path('/Volumes/data/AI/codex/skills/anne-server-provisioning/scripts/anne_server.py'))
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('anne_server', args.registry_tool)
    registry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(registry)
    server = registry.get_server(registry.load_registry(), ALIAS)
    target = None
    report = {'started_utc': datetime.now(timezone.utc).isoformat(), 'servers': [], 'settings': SETTINGS, 'maps': args.maps, 'tests': []}
    for port in (18921, 18922, 18923, 18924):
        if port not in server['rcon']['ports']:
            raise RuntimeError('unregistered port')
        candidate = copy.deepcopy(server)
        candidate['rcon']['port'] = port
        status = registry.rcon_request(candidate, ALIAS, 'status', 8)
        humans = re.search(r'players\s*:\s*(\d+) humans', status)
        map_name = re.search(r'^map\s*:\s*(\S+)', status, re.M)
        if not humans or not map_name:
            raise RuntimeError('cannot verify server state')
        report['servers'].append({'port': port, 'humans': int(humans[1]), 'map': map_name[1]})
        if target is None and int(humans[1]) == 0:
            target = candidate
    if target is None:
        raise RuntimeError('all cloud 1-4 servers have humans; no server changed')
    port = target['rcon']['port']
    container = 'anne' + str(port - 18920)
    report.update({'selected_port': port, 'container': container})
    ssh_config = server['ssh']
    endpoint = ssh_config['user'] + '@' + ssh_config['host']
    ssh_args = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-p', str(ssh_config['port']), '-i', ssh_config['identity_file'], endpoint]

    def ssh(command):
        return run(ssh_args + [command])

    def docker(command):
        return ssh('docker exec ' + container + ' sh -lc ' + shlex.quote(command))

    def rcon(command):
        return registry.rcon_request(target, ALIAS, command, 12)

    def cvar(name):
        values = re.findall(r'"([^"]*)"', rcon('sm_cvar ' + name))
        return values[-1] if len(values) >= 2 else None

    def set_cvar(name, value):
        if any(character in value for character in ('"', '\n', '\r', ';')):
            raise RuntimeError('unsupported cvar quoting: ' + name)
        rcon(f'sm_cvar {name} "{value}"')

    def empty_status():
        status = rcon('status')
        humans = re.search(r'players\s*:\s*(\d+) humans', status)
        map_name = re.search(r'^map\s*:\s*(\S+)', status, re.M)
        if not humans or not map_name or int(humans[1]) != 0:
            raise RuntimeError('server no longer verifiably empty')
        return map_name[1]

    def change_map(name):
        empty_status()
        try:
            rcon('changelevel ' + name)
        except registry.RegistryError:
            pass
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            try:
                current_map = empty_status()
            except registry.RegistryError:
                time.sleep(1)
                continue
            if current_map == name:
                time.sleep(3)
                return
            time.sleep(1)
        raise RuntimeError('map load timeout')

    def save_report():
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    original_map = empty_status()
    initial = {name: cvar(name) for name in ('sv_password', 'confogl_customcfg', *SETTINGS)}
    if any(value is None and name != 'confogl_pills_flow_require_valid' for name, value in initial.items()):
        raise RuntimeError('incomplete cvar snapshot')
    files = [('addons/sourcemod/plugins/confoglcompmod.smx', args.probes / 'confogl_probe.smx'),
             ('addons/sourcemod/plugins/optional/AnneHappy/anne_pill_hint.smx', args.probes / 'hint_probe.smx')]
    for language in ('', 'chi/', 'zho/', 'jp/', 'ko/'):
        relative = 'addons/sourcemod/translations/' + language + 'anne_pill_hint.phrases.txt'
        files.append((relative, ROOT / relative))
    originals = {}
    for relative, local in files:
        if not local.is_file():
            raise RuntimeError('missing input: ' + str(local))
        remote_hash = docker('if [ -f ' + shlex.quote(GAME + '/' + relative) + ' ]; then sha256sum ' + shlex.quote(GAME + '/' + relative) + '; fi').split()
        originals[relative] = remote_hash[0] if remote_hash else None
    hint_loaded = 'Status: running' in rcon('sm plugins info optional/AnneHappy/anne_pill_hint')
    report.update({'original_map': original_map, 'original_files': originals,
                   'probe_hashes': {relative: hashlib.sha256(local.read_bytes()).hexdigest() for relative, local in files},
                   'hint_previously_loaded': hint_loaded})
    backup = ''
    modified = []
    locked = False
    warnings = []
    save_report()
    try:
        set_cvar('sv_password', secrets.token_urlsafe(24))
        locked = True
        empty_status()
        backup = ssh('mktemp -d /root/anne-pill-regression.XXXXXX').strip()
        for index, (relative, local) in enumerate(files):
            remote = GAME + '/' + relative
            if originals[relative]:
                ssh(f'docker cp {container}:{shlex.quote(remote)} {shlex.quote(backup)}/original{index}')
            run(['scp', '-q', '-o', 'BatchMode=yes', '-P', str(ssh_config['port']), '-i', ssh_config['identity_file'], str(local), endpoint + ':' + backup + '/new' + str(index)])
            modified.append((index, relative))
            ssh(f'docker cp {shlex.quote(backup)}/new{index} {container}:{shlex.quote(remote)} && docker exec -u 0 {container} chown louis:louis {shlex.quote(remote)}')
        rcon('sm plugins load_unlock')
        set_cvar('confogl_customcfg', 'annehappy')
        rcon('sm plugins reload confoglcompmod')
        rcon('sm plugins ' + ('reload' if hint_loaded else 'load') + ' optional/AnneHappy/anne_pill_hint')
        rcon('sm_reload_translations')
        rcon('sm plugins load_lock')
        if 'Status: running' not in rcon('sm plugins info confoglcompmod') or 'Status: running' not in rcon('sm plugins info optional/AnneHappy/anne_pill_hint'):
            raise RuntimeError('probe plugin failed to load')

        def measure(case):
            empty_status()
            for name, value in SETTINGS.items():
                set_cvar(name, value)
            log_path = docker(f'ls -t {GAME}/addons/sourcemod/logs/L*.log | head -1').strip()
            offset = int(docker('wc -c < ' + shlex.quote(log_path)).strip())
            error_path = docker(f'ls -t {GAME}/addons/sourcemod/logs/errors_*.log | head -1').strip()
            error_offset = int(docker('wc -c < ' + shlex.quote(error_path)).strip())
            command = 'pill_hint_regression' if case == 'hint' else 'pill_regression_run ' + case
            response = rcon(command)
            if 'Unknown command' in response:
                raise RuntimeError('probe command missing: ' + case)
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                text = docker(f'tail -c +{offset + 1} {shlex.quote(log_path)}')
                lines = [line for line in text.splitlines() if 'PILL_' in line or '[ItemTracking]' in line]
                passed = [line for line in lines if 'PILL_REGRESSION_PASS ' in line or 'PILL_HINT_REGRESSION_PASS ' in line]
                if passed:
                    if case != 'hint':
                        scan_offset = int(docker('wc -c < ' + shlex.quote(log_path)).strip())
                        rcon('pill_hint_regression scan')
                        snapshot = docker(f'tail -c +{scan_offset + 1} {shlex.quote(log_path)}')
                        scan_lines = [line for line in snapshot.splitlines() if 'PILL_HINT_SCAN_' in line]
                        scans = re.findall(r'PILL_HINT_SCAN_RESULT total=(\d+) known=(\d+)', '\n'.join(scan_lines))
                        counts = re.search(r'first=(\d+) second=(\d+) known=(\d+).*finale=(\d+)', passed[-1])
                        if not scans or not counts or any(scan != (counts[2], counts[3]) for scan in scans):
                            report['tests'].append({'case': case, 'map': empty_status(), 'logs': lines + scan_lines})
                            save_report()
                            raise RuntimeError('hint/tracking bottle count mismatch: ' + case)
                        lines += scan_lines
                    result = {'case': case, 'map': empty_status(), 'log_path': log_path, 'log_offset': offset, 'logs': lines}
                    report['tests'].append(result)
                    save_report()
                    print(passed[-1], flush=True)
                    return
                errors = docker(f'tail -c +{error_offset + 1} {shlex.quote(error_path)}')
                failures = [line for line in errors.splitlines() if 'REGRESSION_FAIL' in line]
                if failures:
                    report['tests'].append({'case': case, 'map': empty_status(), 'logs': lines, 'errors': errors.splitlines()})
                    save_report()
                    raise RuntimeError(failures[-1])
                time.sleep(1)
            raise RuntimeError('regression timeout/failure: ' + case)

        change_map('c2m1_highway')
        for case in ('stacked', 'generic', 'unlimited', 'zero', 'unknown', 'strict', 'hint'):
            measure(case)
        for name in args.maps:
            change_map(name)
            measure('map')
        report['complete'] = True
    except BaseException as error:
        report['failure'] = str(error)
        raise
    finally:
        def restore(label, action):
            try:
                action()
            except BaseException as error:
                warnings.append(label + ': ' + str(error))
        if locked:
            restore('unlock', lambda: rcon('sm plugins load_unlock'))
            restore('unload hint', lambda: rcon('sm plugins unload optional/AnneHappy/anne_pill_hint'))
            for index, relative in reversed(modified):
                remote = GAME + '/' + relative
                if originals[relative]:
                    restore(relative, lambda index=index, remote=remote: ssh(f'docker cp {shlex.quote(backup)}/original{index} {container}:{shlex.quote(remote)} && docker exec -u 0 {container} chown louis:louis {shlex.quote(remote)}'))
                else:
                    restore(relative, lambda remote=remote: docker('rm -f -- ' + shlex.quote(remote)))
            restore('reload original', lambda: rcon('sm plugins reload confoglcompmod'))
            if hint_loaded:
                restore('load original hint', lambda: rcon('sm plugins load optional/AnneHappy/anne_pill_hint'))
            restore('translations', lambda: rcon('sm_reload_translations'))
            for name, value in initial.items():
                if name != 'sv_password':
                    restore(name, lambda name=name, value=value: set_cvar(name, value if value is not None else '0'))
            restore('map', lambda: change_map(original_map))
            for name, value in initial.items():
                restore(name, lambda name=name, value=value: set_cvar(name, value if value is not None else '0'))
            restore('load lock', lambda: rcon('sm plugins load_lock'))
            for relative, original_hash in originals.items():
                def verify_file(relative=relative, original_hash=original_hash):
                    remote = shlex.quote(GAME + '/' + relative)
                    result = docker(f'if [ -f {remote} ]; then sha256sum {remote}; fi').split()
                    if (result[0] if result else None) != original_hash:
                        raise RuntimeError('hash mismatch')
                restore('verify ' + relative, verify_file)
            for name, value in initial.items():
                def verify_cvar(name=name, value=value):
                    if value is not None and cvar(name) != value:
                        raise RuntimeError('value mismatch')
                restore('verify ' + name, verify_cvar)
            def verify_plugin():
                if 'Status: running' not in rcon('sm plugins info confoglcompmod'):
                    raise RuntimeError('not running')
            restore('original plugin state', verify_plugin)
            def verify_map():
                if empty_status() != original_map:
                    raise RuntimeError('map mismatch')
            restore('original map', verify_map)
            if backup and not warnings:
                restore('backup cleanup', lambda: ssh('rm -r -- ' + shlex.quote(backup)))
        report.update({'finished_utc': datetime.now(timezone.utc).isoformat(), 'restore_warnings': warnings})
        save_report()
        print('RESTORE_WARNINGS ' + json.dumps(warnings, ensure_ascii=False), flush=True)
        if warnings:
            raise RuntimeError('restoration incomplete; backup retained: ' + backup)


if __name__ == '__main__':
    main()
