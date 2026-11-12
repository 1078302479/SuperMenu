#!/usr/bin/env python3
"""Publish only the fresh candidate produced by the mandatory release gate."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def checked_report(path):
    report = json.loads(path.read_text())
    if report.get('status') != 'passed' or not report.get('steps') or any(s.get('status') != 'passed' for s in report['steps']):
        raise RuntimeError('Release checks did not pass')
    if report['commit'] != subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip():
        raise RuntimeError('Commit changed during checks')
    current_names = {str(p.relative_to(ROOT)) for folder in ('Sources', 'Resources', 'scripts', 'Tests', 'ThirdParty')
                     for p in (ROOT / folder).rglob('*') if p.is_file()} | {'LICENSE', 'NOTICE'}
    if current_names != set(report['source_sha256']):
        raise RuntimeError('Source file list changed after checks')
    for name, expected in report['source_sha256'].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError('Source changed after checks: ' + name)
    packages = path.parent / 'packages'
    artifacts = []
    for name, expected in report['artifacts'].items():
        if Path(name).name != name:
            raise RuntimeError('Invalid artifact name')
        artifact = packages / name
        if hashlib.sha256(artifact.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Artifact changed after checks: ' + name)
        artifacts.append(artifact)
    if len(artifacts) != 2 or {p.suffix for p in artifacts} != {'.dmg', '.zip'}:
        raise RuntimeError('Missing release artifacts')
    manifest = packages / 'SHA256SUMS.txt'
    expected_lines = {f'{digest}  {name}' for name, digest in report['artifacts'].items()}
    if set(manifest.read_text().splitlines()) != expected_lines:
        raise RuntimeError('Checksum manifest changed after checks')
    return report, artifacts + [manifest]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--notes-file', type=Path)
    parser.add_argument('--check-only', action='store_true', help='run the full gate without publishing')
    args = parser.parse_args()
    if not args.check_only:
        if not args.notes_file or not args.notes_file.is_file():
            parser.error('--notes-file must point to the reviewed release notes')
        if subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=no'], cwd=ROOT, text=True).strip():
            raise RuntimeError('Commit tracked changes before publishing')
    # No skip flag and no externally supplied report: always run a fresh full gate.
    result = subprocess.run([sys.executable, str(ROOT / 'scripts/release-preflight.py'), '--live'],
                            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end='')
    if result.returncode:
        return result.returncode
    paths = [line[len('Report: '):] for line in result.stdout.splitlines() if line.startswith('Report: ')]
    if len(paths) != 1:
        raise RuntimeError('Missing unambiguous preflight report')
    report, artifacts = checked_report(Path(paths[0]))
    if args.check_only:
        print('PASS: publication gate; nothing uploaded')
        return 0
    tag = 'v' + report['version']
    tagged = subprocess.check_output(['git', 'rev-parse', tag + '^{commit}'], cwd=ROOT, text=True).strip()
    if tagged != report['commit']:
        raise RuntimeError('Release tag must point to the tested commit')
    # gh verifies the tag exists remotely; all asset paths are taken from this run.
    subprocess.run(['gh', 'release', 'create', tag, '--verify-tag', '--title', tag,
                    '--notes-file', str(args.notes_file.resolve()), *map(str, artifacts)], cwd=ROOT, check=True)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt) as error:
        print('Publication blocked: ' + str(error), file=sys.stderr)
        sys.exit(1)
