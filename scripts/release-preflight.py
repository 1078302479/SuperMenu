#!/usr/bin/env python3
"""Build and validate a fresh release candidate; never installs or publishes it."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='also check GitHub availability (network failures fail the gate)')
    args = parser.parse_args()
    os.chdir(ROOT)
    base = ROOT / '.build/release-preflight'
    base.mkdir(parents=True, exist_ok=True)
    lock = (base / 'lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Another release preflight is running.', file=sys.stderr)
        return 1
    run = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=base))
    report = {'status': 'running', 'steps': [], 'directory': str(run),
              'manual_checks': ['Finder menu display and actual actions in local/cloud folders, file/multiple/window contexts',
                                'permission revoke/reauthorize and cold start after Finder/login restart',
                                'complete in-app upgrade confirmation, replacement and relaunch'],
              'scope': 'Automatic checks only; manual checks are not inferred from a passing report.'}
    report_path = run / 'report.json'
    # Drop inherited test switches so this run always tests its own new candidate.
    env = {k: v for k, v in os.environ.items() if not k.startswith('SUPERMENU_TEST_') and k != 'SUPERMENU_CAPTURE_UI'}
    env['SUPERMENU_INCLUDE_REFERENCE_ASSETS'] = '0'

    def save():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')

    def step(name, command, extra=None, timeout=1800):
        print(f'Running: {name}', flush=True)
        log = run / (name + '.log')
        entry = {'name': name, 'status': 'running', 'log': str(log)}
        report['steps'].append(entry)
        save()
        start = time.monotonic()
        with log.open('w') as output:
            process = subprocess.Popen(command, env={**env, **(extra or {})}, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                entry['status'] = 'interrupted-or-timed-out'
                save()
                raise RuntimeError(f'{name} interrupted or exceeded {timeout}s; see {log}')
        entry.update(status='passed' if code == 0 else 'failed', exit_code=code,
                     seconds=round(time.monotonic() - start, 2))
        save()
        if code:
            raise RuntimeError(f'{name} failed ({code}); see {log}')

    def fingerprint():
        result = {}
        for folder in ('Sources', 'Resources', 'scripts', 'Tests', 'ThirdParty'):
            for path in sorted((ROOT / folder).rglob('*')):
                if path.is_file():
                    result[str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
        for name in ('LICENSE', 'NOTICE'):
            result[name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
        return result

    try:
        before = fingerprint()
        report['source_sha256'] = before
        report['commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
        step('diff-check', ['git', 'diff', '--check'])
        step('publication-gate', [sys.executable, 'scripts/test-release-gate.py'])
        step('installer-rollback', [sys.executable, 'scripts/test-update-helper.py'])
        build = run / 'build'
        step('distribution-build', ['bash', 'scripts/build-local.sh'],
             {'SUPERMENU_DISTRIBUTION': '1', 'SUPERMENU_BUILD_DIR': str(build)})
        app = build / '增强右键.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        version = info['CFBundleShortVersionString']
        report.update(version=version, build=info['CFBundleVersion'])
        step('app-integrity', [sys.executable, 'scripts/verify-app.py', str(app), '--version', version])
        packages = run / 'packages'
        step('package', ['bash', 'scripts/package-release.sh', str(app), str(packages)])
        # The app verifier already enforces matching host/extension versions.
        archives = list(packages.glob('*.zip'))
        if len(archives) != 1:
            raise RuntimeError('Expected exactly one freshly generated ZIP')
        hashes = {}
        for line in (packages / 'SHA256SUMS.txt').read_text().splitlines():
            digest, name = line.split()
            if Path(name).name != name:
                raise RuntimeError('Invalid checksum manifest path')
            actual = hashlib.sha256((packages / name).read_bytes()).hexdigest()
            if actual != digest:
                raise RuntimeError(f'Checksum mismatch: {name}')
            hashes[name] = actual
        if set(hashes) != {p.name for p in packages.iterdir() if p.suffix in ('.zip', '.dmg')} or len(hashes) != 2:
            raise RuntimeError('Incomplete release checksum manifest')
        report['artifacts'] = hashes
        step('full-regression', ['bash', 'scripts/test-background.sh'],
             {'SUPERMENU_TEST_HOME_STORAGE': '1', 'SUPERMENU_TEST_CROSS_VOLUME': '1',
              'SUPERMENU_CAPTURE_UI': '1', 'SUPERMENU_TEST_UPDATE_ARCHIVE': str(archives[0]),
              'SUPERMENU_TEST_UPDATE_VERSION': version,
              'SUPERMENU_TEST_LIVE_UPDATE': '1' if args.live else '0'})
        # Preserve per-run screenshots instead of relying on a mutable shared output.
        import shutil
        shutil.copytree(ROOT / '.build/ui-check', run / 'screenshots',
                        ignore=shutil.ignore_patterns('*.*swift', 'render', 'PreviewModel.swift'))
        if fingerprint() != before:
            raise RuntimeError('Source changed during validation; rerun before releasing')
        report['status'] = 'passed'
        print(f'PASS: automatic release checks. Candidate packages: {packages}')
        print('Manual checks still require real UI evidence; see report.json.')
        return 0
    except (Exception, KeyboardInterrupt) as error:
        report.update(status='failed', error=str(error))
        print(f'FAIL: {error}', file=sys.stderr)
        return 1
    finally:
        save()
        print(f'Report: {report_path}', flush=True)


if __name__ == '__main__':
    sys.exit(main())
