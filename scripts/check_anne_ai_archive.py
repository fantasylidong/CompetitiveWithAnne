#!/usr/bin/env python3
"""Check Anne archive wiring and the compiled private-ConVar boundary."""
import json
import struct
import zlib
from pathlib import Path

from freeze_anne_ai import lex, _selftest

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / 'addons/sourcemod/scripting/archive/AnneHappy/ai_versions'


def smx_image(path):
    raw = path.read_bytes()
    magic, version, compressed, disk_size, image_size, count, names, data = struct.unpack_from('<IHBII BII', raw)
    assert magic == 0x53504646 and disk_size == len(raw), path
    image = raw[:data] + zlib.decompress(raw[data:]) if compressed else raw
    assert len(image) == image_size, path

    def string(offset):
        return image[offset:image.index(b'\0', offset)].decode()

    sections = {}
    for i in range(count):
        name, offset, size = struct.unpack_from('<III', image, 24 + i * 12)
        sections[string(names + name)] = (offset, size)
    start, length = sections['.natives']
    natives = {string(sections['.names'][0] + struct.unpack_from('<I', image, start + i)[0])
               for i in range(0, length, 4)}
    return image, natives


def check():
    _selftest()
    manifest = json.loads((ARCHIVE / 'manifest.json').read_text())
    spec = json.loads((ROOT / 'scripts/anne_ai_profiles.json').read_text())
    unload = (ROOT / 'cfg/vote/Anne/unloadall.cfg').read_text().splitlines()
    ai_unload_indices, settings_unload_indices = [], []
    count = 0
    expected_files = set()
    parameters = {}
    for profile, data in manifest['profiles'].items():
        assert data['load_order'] == spec['profiles'][profile]['load_order']
        assert data['load_order'][0] == data['settings']['smx']
        assert len(data['load_order']) == len(set(data['load_order']))
        assert set(data['load_order']) == {data['settings']['smx'], *data['compatibility_plugins'], *(p['smx'] for p in data['plugins'])}
        for cfg in data['versions']:
            lines = (ROOT / 'cfg/vote/Anne' / cfg).read_text().splitlines()
            label = next(i for i, line in enumerate(lines) if line.startswith('sm_cvar AnnePluginVersion '))
            loads = [line.removeprefix('sm plugins load ') for line in lines[label + 1:] if line.startswith('sm plugins load ')]
            assert loads == data['load_order'], cfg
            assert not any('dynamic_ai_difficulty.smx' in path for path in loads), cfg
            for legacy in data['compatibility_plugins']:
                assert (ROOT / 'addons/sourcemod/plugins' / legacy).is_file(), legacy
        for plugin in [data['settings'], *data['plugins']]:
            path = ROOT / 'addons/sourcemod/plugins' / plugin['smx']
            expected_files.add(path)
            image, natives = smx_image(path)
            assert 'CreateConVar' not in natives, path
            command = 'sm plugins unload ' + plugin['smx']
            assert unload.count(command) == 1, command
            (settings_unload_indices if plugin is data['settings'] else ai_unload_indices).append(unload.index(command))
            for source, gamedata in plugin.get('gamedata', {}).items():
                assert (ROOT / gamedata).is_file(), gamedata
                assert Path(gamedata).stem.encode() in image, path
            if 'private_cvars' in plugin:
                for value in plugin['private_cvars']:
                    parameters[(profile, Path(plugin['original']).stem, value['name'] or value['handle'])] = value
                if profile in ('25-10', '25-11') and plugin['original'].endswith('/ai_smoker3.sp'):
                    assert b'SmokerTongueVictim::SmokerTongueVictim' not in image, 'Unsafe raw constructor preparation remains'
                    source = (ROOT / plugin['source']).read_text()
                    assert 'g_hSdkSmokerTongueVictim = EndPrepSDKCall()' not in source, 'Unsafe constructor preparation remains'
            count += 1
    assert min(settings_unload_indices) > max(ai_unload_indices), 'Restore engine values only after all AI has stopped'
    actual_files = set((ROOT / 'addons/sourcemod/plugins/optional/AnneHappy/ai_versions').rglob('*.smx'))
    assert actual_files == expected_files, 'Unexpected or missing archive SMX'
    for path in ARCHIVE.rglob('*'):
        if path.suffix in ('.sp', '.inc'):
            assert not any(t.kind == 'identifier' and t.text == 'CreateConVar' for t in lex(path.read_text())), path
    assert parameters['22-06', 'ai_charger_new', 'ai_ChargerCoolTime']['numeric'] == 12
    assert parameters['22-06', 'ai_tank_new', 'ai_TankTarget']['numeric'] == 1
    assert parameters['25-11', 'ai_hunter_2', 'ai_hunter_no_sight_pounce_range']['value'] == '300.0,250.0'
    assert parameters['26-07', 'ai_charger3', 'ai_charger3_bhop_direct_dist']['numeric'] == 350
    assert parameters['26-07', 'ai_charger3', 'ai_charger3_bhop_impulse']['numeric'] == 90
    assert parameters['26-07', 'ai_charger3', 'ai_charger3_target_watch_maxdeg']['numeric'] == 30
    for version in ('25-10', '25-11'):
        assert parameters[version, 'ai_smoker3', 'ai_smoker3_imm_pull']['numeric'] == 0
    july = manifest['profiles']['26-07']['settings']['parameters']
    assert july['inf_ai_difficulty_link'] == '0' and july['inf_ai_difficulty_fallback_level'] == '3'
    print(f'PASS: {count} SMXs, {len(parameters)} frozen parameters, 15 version entries, engine restore order and compatibility paths')


if __name__ == '__main__':
    check()
