#!/usr/bin/env python3
"""Remove reproducible build outputs. Preview by default; --apply deletes them."""
import argparse
import re
import shutil
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--apply", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent / ".build"
targets = []
for name in ("background", "background-test", "release", "ui-check/module-cache",
             "file-icon-module-cache", "local/module-cache"):
    path = root / name
    if path.exists():
        targets.append(path)
review = root / "review"
versions = sorted((p for p in review.glob("v*") if re.fullmatch(r"v\d+(?:\.\d+){2}", p.name)),
                  key=lambda p: tuple(map(int, p.name[1:].split("."))))
targets.extend(versions[:-1])
if versions and (versions[-1] / "module-cache").exists():
    targets.append(versions[-1] / "module-cache")
for parent in (root / "local", *versions[-1:]):
    targets.extend(parent.glob("staging.*"))
total = 0
for path in targets:
    if path.is_symlink() or root.resolve() not in path.resolve().parents:
        raise RuntimeError(f"Refusing unexpected path: {path}")
    size = sum(p.stat().st_size for p in path.rglob("*") if p.is_file() and not p.is_symlink())
    total += size
    print(f"{'Remove' if args.apply else 'Would remove'} {path.relative_to(root)} ({size / 1024**2:.1f} MiB)")
    if args.apply:
        shutil.rmtree(path)
print(f"{'Removed' if args.apply else 'Reclaimable'}: {total / 1024**3:.2f} GiB")
print("Kept: sources, resources, latest local/review apps, local/shared, dependencies and shared module cache.")
