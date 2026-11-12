#!/usr/bin/env python3
"""Exercise the production helper's transaction with isolated app directories.
System registration/open are recorded; this does not claim a real GUI relaunch.
"""
from pathlib import Path
import subprocess
import tempfile
import textwrap

source = Path('Sources/App/UpdateInstaller.swift').read_text()
helper = textwrap.dedent(source.split('let text = """', 1)[1].split('"""', 1)[0]).strip() + '\n'
for scenario in ('success', 'replace-failure', 'launch-failure', 'bad-signature'):
    with tempfile.TemporaryDirectory(prefix='supermenu-update-') as temporary:
        root = Path(temporary)
        current, staged, backup = [root / name for name in ('current.app', 'staged.bundle', 'backup.bundle')]
        for folder, version in ((current, '0.5.0'), (staged, '0.5.1')):
            folder.mkdir()
            (folder / 'version').write_text(version)
        settings = root / 'settings.json'
        settings.write_text('{"customTemplate":"保留"}')
        before = settings.read_bytes()
        script = helper.replace('/usr/bin/codesign --verify --deep --strict "$staged_app"', 'false' if scenario == 'bad-signature' else 'true')
        script = script.replace('/usr/bin/pluginkit -a "$current_app/Contents/PlugIns/SuperMenuFinder.appex"', 'true')
        script = script.replace('/usr/bin/open -g "$current_app"', 'true')
        script = script.replace('/usr/bin/open "$current_app"', 'false' if scenario == 'launch-failure' else 'true')
        if scenario == 'replace-failure':
            script = script.replace('/bin/mv "$staged_app" "$current_app"', 'false')
        path = root / 'install.sh'
        path.write_text(script)
        result = subprocess.run(['/bin/sh', str(path), '99999999', str(current), str(staged), str(backup)], capture_output=True)
        expected = '0.5.1' if scenario == 'success' else '0.5.0'
        assert (current / 'version').read_text() == expected, (scenario, result.stderr)
        assert settings.read_bytes() == before
        assert (result.returncode == 0) == (scenario == 'success'), scenario
        if scenario == 'success':
            assert (backup / 'version').read_text() == '0.5.0'
        print('PASS:', scenario, 'retains settings and the expected app version')
