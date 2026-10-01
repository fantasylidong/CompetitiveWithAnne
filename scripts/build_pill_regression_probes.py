#!/usr/bin/env python3
import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='anne-pill-probes-') as directory:
        stage = Path(directory)
        scripting = Path('addons/sourcemod/scripting')
        shutil.copytree(root / scripting, stage / scripting, symlinks=True)
        (stage / 'scripts').mkdir()
        shutil.copy2(root / 'scripts/spcomp-docker.sh', stage / 'scripts/spcomp-docker.sh')
        tracking = stage / scripting / 'confoglcompmod/ItemTracking.sp'
        source = tracking.read_text()
        hook = 'HookEvent("round_start", _IT_RoundStartEvent, EventHookMode_PostNoCopy);'
        assert source.count(hook) == 1
        source = source.replace(hook, 'RegServerCmd("pill_regression_run", PillRegression_Command);')
        tracking.write_text(source + '\n' + (root / scripting / 'disabled/test/pill_tracking_regression.inc').read_text())
        hint = stage / scripting / 'optional/AnneHappy/anne_pill_hint.sp'
        source = hint.read_text()
        hook = 'LoadTranslations("anne_pill_hint.phrases");'
        assert source.count(hook) == 1
        source = source.replace(hook, hook + '\n    RegServerCmd("pill_hint_regression", PillHintRegression_Command);')
        hook = 'SortSpots(iPct, iNum, iSpots);'
        assert source.count(hook) == 1
        source = source.replace(hook, hook + '\n    PillHintRegression_Snapshot(iPct, iNum, iSpots, iTotal);')
        hint.write_text(source + '\n' + (root / scripting / 'disabled/test/pill_hint_regression.inc').read_text())
        for name, entry in [('confogl_probe', 'confoglcompmod.sp'), ('hint_probe', 'optional/AnneHappy/anne_pill_hint.sp')]:
            subprocess.run(['bash', str(stage / 'scripts/spcomp-docker.sh'), str(scripting / entry), str(output / (name + '.smx'))], cwd=stage, check=True)


if __name__ == '__main__':
    main()
