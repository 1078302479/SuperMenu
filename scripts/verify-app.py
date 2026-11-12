#!/usr/bin/env python3
"""Verify a distribution app before packaging or after extracting a download."""
import argparse
import plistlib
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
parser.add_argument("--version")
args = parser.parse_args()
app = args.app.resolve()
root = Path(__file__).resolve().parent.parent
expected = {"docx", "xlsx", "pptx", "wps", "et", "dps", "pages", "numbers", "key", "ai", "psd"}
versions = []
for bundle, identifier in [(app, "io.github.1078302479.SuperMenu"),
                           (app / "Contents/PlugIns/SuperMenuFinder.appex", "io.github.1078302479.SuperMenu.Finder")]:
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == identifier
    assert "SuperMenuLocalStorage" not in info, "Developer storage path in distribution"
    assert info["SuperMenuHomeRelativeStorage"] == "/Library/Application Support/io.github.1078302479.SuperMenu"
    assert set(info["SuperMenuBundledTemplates"]) == expected
    versions.append((info["CFBundleShortVersionString"], info["CFBundleVersion"]))
    for extension in expected:
        seed = root / f"Resources/Templates/blank.{extension}"
        assert (bundle / f"Contents/Resources/Templates/{seed.name}").read_bytes() == seed.read_bytes(), seed
    for seed in (root / "Resources/ReferenceIcons").rglob("*.png"):
        target = bundle / "Contents/Resources" / seed.relative_to(root / "Resources/ReferenceIcons")
        assert target.read_bytes() == seed.read_bytes(), seed
assert versions[0] == versions[1], "App/extension version mismatch"
if args.version:
    assert versions[0][0] == args.version
assert (app / "Contents/Resources/Licenses/Apache-2.0.txt").read_bytes() == (root / "LICENSE").read_bytes()
assert (app / "Contents/Resources/Licenses/NOTICE.txt").read_bytes() == (root / "NOTICE").read_bytes()
assert not (app / "Contents/Resources/Licenses/MIT.txt").exists()
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(f"PASS: distribution {versions[0][0]} build {versions[0][1]}, signature, storage, all templates/icons, Apache-2.0 and NOTICE")
