#!/usr/bin/env python3
"""Rebuild checked-in Anne AI sources from pinned Git commits and parameters.

No server is contacted. Compile the emitted sources with spcomp-docker.sh.
The manifest records the original blobs and every frozen private parameter.
"""
from __future__ import annotations

import argparse
import json
import posixpath
import re
import subprocess
from pathlib import Path

from freeze_anne_ai import (FreezeError, arg_text, call_end,
                            freeze_source_with_report, lex, quote)

ROOT = Path(__file__).resolve().parents[1]
SCRIPTING = 'addons/sourcemod/scripting/'
DEST = ROOT / SCRIPTING / 'archive/AnneHappy/ai_versions'
PLUGIN_ROOT = 'optional/AnneHappy/ai_versions'
SPEC = Path(__file__).with_name('anne_ai_profiles.json')
PINNED_INCLUDES = {'treeutil', 'logger2', 'vector_show', 'infected_control', 'anne_nextbot'}
INCLUDE = re.compile(r'^\s*#include\s*[<"]([^>"\n]+)[>"]', re.M)


def git(commit: str, path: str) -> str:
    return subprocess.check_output(['git', 'show', commit + ':' + path], cwd=ROOT).decode('utf-8-sig')


def function_span(source: str, name: str) -> tuple[int, int]:
    tokens = lex(source)
    for i, token in enumerate(tokens):
        if token.text != name or tokens[i + 1].text != '(':
            continue
        end, _ = call_end(tokens, i + 1)
        if tokens[end + 1].text != '{':
            continue
        depth = 1
        j = end + 2
        while depth:
            depth += (tokens[j].text == '{') - (tokens[j].text == '}')
            j += 1
        start = source.rfind('\n', 0, token.start) + 1
        return start, tokens[j - 1].end
    raise FreezeError('Missing function ' + name)


def replace_function(source: str, name: str, replacement: str) -> str:
    a, b = function_span(source, name)
    return source[:a] + replacement + source[b:]


def prepare(source: str, path: str, values: dict[str, str]) -> str:
    """Explicit compatibility adaptations and the recorded Smoker crash fix."""
    if path.endswith('/ai_charger_new.sp'):
        source = source.replace('float UpdatePosition(', 'float[] UpdatePosition(')
        source = source.replace('CreateTimer(g_iChargerCoolTime,', 'CreateTimer(float(g_iChargerCoolTime),')
    if path.endswith('/ai_smoker_new.sp') and 'GetRandomMobileSurvivor()' in source and 'int GetRandomMobileSurvivor()' not in source:
        # The 2023-01 snapshot omitted this helper, retained unchanged in the
        # preceding recovered Smoker source. Restore only that missing function.
        previous = git('7792ac49ef57012e1f6e039bfbf337c914050ce7', SCRIPTING + 'AnneHappy/ai_smoker_new.sp')
        a, b = function_span(previous, 'GetRandomMobileSurvivor')
        source += '\n// Compatibility: missing helper from 7792ac49 ai_smoker_new.sp.\n' + previous[a:b] + '\n'
    if path.endswith('/ai_smoker3.sp') and 'g_cvImmPull = CreateConVar' in source:
        # 1a1670470a915d27d43dd83ffe389ce7791c42f3 removed this crash path.
        # Policy fixes imm_pull to 0; also omit the unconditional raw-address
        # constructor preparation, so even plugin load never touches that path.
        if values.get('ai_smoker3_imm_pull') != '0':
            raise FreezeError('Archived Smoker requires the recorded imm_pull crash fix')
        a = source.index('\tOS_Type osType = GetOSType();')
        b = source.index('\n\tdelete hGamedata;', a)
        source = source[:a] + '\t// Crash compatibility: imm_pull disabled; no raw constructor SDKCall preparation.\n' + source[b:]
    if path.endswith('/ai_charger3/ai_charger3.sp'):
        source = replace_function(source, 'getOrCreateLegacyConVar', '')
        tokens = lex(source)
        edits = []
        for i, token in enumerate(tokens):
            if token.text != 'getOrCreateLegacyConVar':
                continue
            end, args = call_end(tokens, i + 1)
            raw = [arg_text(source, tokens, a) for a in args]
            raw.insert(3, 'CVAR_FLAGS')
            edits.append((token.start, tokens[end].end, 'CreateConVar(' + ', '.join(raw) + ')'))
        for a, b, replacement in reversed(edits):
            source = source[:a] + replacement + source[b:]
        # Alias writes are resolved in the parameter manifest. Keep the original
        # string parsing, including defaults/clamps, for the extra-target range.
        a, b = function_span(source, 'syncLegacyChargerConfig')
        body = source[a:b]
        body = body[body.index('\tg_fLegacyExtraTargetMin ='):]
        source = source[:a] + 'void syncLegacyChargerConfig()\n{\n' + body + source[b:]
        source = source.replace('State_OnModuleStart(g_cvPluginName)', 'State_OnModuleStart()')
        source = source.replace('Stock_OnModuleStart(g_cvPluginName)', 'Stock_OnModuleStart()')
    if '/ai_charger3/' in path and path.endswith(('/state.inc', '/stocks.inc')):
        module = 'State' if path.endswith('/state.inc') else 'Stock'
        lower = module.lower()
        extra = '\n    registerStates();' if module == 'State' else ''
        source = replace_function(source, module + '_OnModuleStart', f'''stock void {module}_OnModuleStart() {{
    g_cv{module}LogLevel = CreateConVar("_ai_charger3_{lower}_log_level", "1", "", CVAR_FLAGS);
    {lower}Log = new Logger({module.upper()}_LOG_PREFIX, g_cv{module}LogLevel.IntValue);{extra}
}}''')
    if path.endswith('/ai_hunter_2.sp') and 'g_hNoSightPounceRangeLegacy' in source:
        # The new name has a nonempty fixed value, so the old-name fallback is
        # unreachable. Do not import the misspelled current cfg value into it.
        if not values.get('ai_hunter_no_sight_pounce_range', '300.0,250.0'):
            raise FreezeError('Empty Hunter range needs a reviewed legacy fallback')
        source = re.sub(r'^.*g_hNoSightPounceRangeLegacy.*\n', '', source, flags=re.M)
    if path.endswith('/ai_tank_new.sp'):
        source = source.replace('float UpdatePosition(', 'float[] UpdatePosition(')
        # Only two disabled DEBUG_* branches reference this missing debug file.
        assert '#define DEBUG_DOWNLINE 0' in source and '#define DEBUG_EYELINE 0' in source
        source = source.replace('#include "vector/vector_show.sp"', '// Debug drawing omitted: both DEBUG_* switches are 0.')
        source = source.replace('public void OnPluginStart()\n{', 'public void OnPluginStart()\n{\n\tLoadTranslations("ai_tank_new.phrases");')
        source = source.replace('CPrintToChat(curTarget, "{R}<Tank>：{G}喜欢绕树是吧？");', 'CPrintToChat(curTarget, "%t", "AITankNew_TankLikesWalkAroundTrees");')
    return source


def snapshot(commit: str, entry: str, values: dict[str, str]):
    files = {}
    blobs = {}

    def visit(path):
        if path in files:
            return
        original = git(commit, path)
        # Use git's blob identity (also preserves BOM and original line endings).
        blobs[path] = subprocess.check_output(['git', 'rev-parse', commit + ':' + path], cwd=ROOT, text=True).strip()
        files[path] = ''  # break cyclic guarded includes
        source = prepare(original, path, values)

        def include(match):
            name = match.group(1)
            if name in PINNED_INCLUDES:
                target = SCRIPTING + 'include/' + name + '.inc'
            elif name.startswith('.') or '/' in name and not name.startswith('sourcemod'):
                target = posixpath.normpath(posixpath.join(posixpath.dirname(path), name))
                if not target.endswith(('.sp', '.inc')):
                    target += '.inc'
            else:
                return match.group(0)
            visit(target)
            # Mirror source-relative paths inside the profile; APIs still use
            # the current SourceMod SDK, algorithmic helper includes are pinned.
            relative = posixpath.relpath(target, posixpath.dirname(path))
            return '\n#include "' + relative + '"'

        files[path] = INCLUDE.sub(include, source)

    visit(entry)
    # Freeze the translation unit together so globals used in Charger modules
    # are replaced as well. Split back into the original guarded include files.
    paths = sorted(files)
    marker = '// ANNE_ARCHIVE_SOURCE_BOUNDARY '
    bundle = ''.join(marker + p + '\n' + files[p] + '\n' for p in paths)
    transformed, report = freeze_source_with_report(bundle, values)
    result = {}
    for part in transformed.split(marker)[1:]:
        path, contents = part.split('\n', 1)
        result[path] = contents
    if set(result) != set(files):
        raise FreezeError('Source boundary mismatch')
    return result, report, blobs


def settings_source(profile: str, settings: dict, capture: list[str]) -> str:
    names = sorted(set(settings) | set(capture))
    rows = ',\n'.join('    {' + quote(n) + ', ' + quote(settings.get(n, '')) + '}' for n in names)
    return f'''// Generated by scripts/build_anne_ai_archive.py. Historical engine settings.
#include <sourcemod>
#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = {{
    name = "Anne {profile} AI engine settings", author = "Anne", version = "1.0",
    description = "Apply historical engine values after Confogl and restore on unload"
}};

static const char g_Settings[][][64] = {{
{rows}
}};
ConVar g_Handles[sizeof(g_Settings)];
char g_Previous[sizeof(g_Settings)][128];

public void OnPluginStart()
{{
    // This plugin loads BEFORE the AI and unloads AFTER it.
    for (int i = 0; i < sizeof(g_Settings); i++)
    {{
        g_Handles[i] = FindConVar(g_Settings[i][0]);
        if (g_Handles[i] != null)
            g_Handles[i].GetString(g_Previous[i], sizeof(g_Previous[]));
    }}
    ApplySettings();
}}

public void OnConfigsExecuted()
{{
    // Confogl replays the current mode's values in this forward as well.
    RequestFrame(ApplyAfterConfigs);
}}

public void ApplyAfterConfigs(any data)
{{
    ApplySettings();
}}

void ApplySettings()
{{
    for (int i = 0; i < sizeof(g_Settings); i++)
        if (g_Handles[i] != null && g_Settings[i][1][0] != '\\0')
            g_Handles[i].SetString(g_Settings[i][1]);
}}

public void OnPluginEnd()
{{
    for (int i = 0; i < sizeof(g_Settings); i++)
        if (g_Handles[i] != null)
            g_Handles[i].SetString(g_Previous[i]);
}}
'''


def generate(check=False):
    spec = json.loads(SPEC.read_text())
    outputs = {}
    manifest = {'schema': 1, 'profiles': {}}
    for profile, data in spec['profiles'].items():
        dest = DEST / profile
        record = {k: data[k] for k in ('commit', 'basis', 'versions', 'compatibility_plugins', 'load_order', 'adaptations')}
        record['plugins'] = []
        for entry in data['sources']:
            # Dynamic log names are pinned explicitly by their assigned handle.
            values = dict(data['parameters'])
            if entry.endswith(('/ai_tank3.sp', '/ai_smoker3.sp')):
                name = Path(entry).stem + '_log_level'
                values['g_cvLogLevel'] = values.get(name, '32')
            elif entry.endswith('/ai_charger3.sp'):
                values['g_cvLogLevel'] = values.get('ai_charger3_log_level', '1')
            files, report, blobs = snapshot(data['commit'], entry, values)
            gamedata = {}
            for path, contents in files.items():
                for name in re.findall(r'#define\s+GAMEDATA\s+"(l4d2_ai_[^"]+)"', contents):
                    original = 'addons/sourcemod/gamedata/' + name + '.txt'
                    archived_name = 'anne_ai_' + profile.replace('-', '_') + '_' + name.removeprefix('l4d2_ai_')
                    target_data = ROOT / 'addons/sourcemod/gamedata' / (archived_name + '.txt')
                    outputs[target_data] = git(data['commit'], original)
                    gamedata[original] = str(target_data.relative_to(ROOT))
                    contents = contents.replace('"' + name + '"', '"' + archived_name + '"')
                target = dest / path.removeprefix(SCRIPTING)
                if target in outputs and outputs[target] != contents:
                    raise FreezeError('Conflicting shared include ' + str(target))
                outputs[target] = contents
            source_path = str((dest / entry.removeprefix(SCRIPTING)).relative_to(ROOT))
            smx = f'{PLUGIN_ROOT}/{profile}/{Path(entry).stem}.smx'
            record['plugins'].append({
                'source': source_path, 'smx': smx, 'original': entry,
                'blobs': blobs, 'gamedata': gamedata, 'private_cvars': report['private_cvars']})
        settings = settings_source(profile, data['engine_parameters'], spec['restore_engine_parameters'])
        outputs[dest / 'settings.sp'] = settings
        record['settings'] = {'source': str((dest / 'settings.sp').relative_to(ROOT)),
                              'smx': f'{PLUGIN_ROOT}/{profile}/settings.smx',
                              'parameters': data['engine_parameters']}
        manifest['profiles'][profile] = record
    outputs[DEST / 'manifest.json'] = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
    stale = []
    for path, text in outputs.items():
        if check:
            if not path.exists() or path.read_text() != text:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
    if stale:
        raise SystemExit('Stale generated files:\n' + '\n'.join(stale))
    print(f'{"Verified" if check else "Generated"} {len(outputs)} files, {len(manifest["profiles"])} profiles')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    generate(parser.parse_args().check)
