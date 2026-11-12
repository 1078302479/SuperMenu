#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -lt 1 ]; then
    echo 'Usage: bash scripts/package-release.sh path/to/增强右键.app [output-directory]' >&2
    exit 1
fi
app="$1"
version="$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
architecture="$(lipo -archs "$app/Contents/MacOS/SuperMenu")"
case "$architecture" in arm64|x86_64) ;; *) echo 'Package architecture is unsupported' >&2; exit 1 ;; esac
python3 scripts/verify-app.py "$app" --version "$version"
output="${2:-.build/packages/v$version}"
mkdir -p "$output"
staging="$(mktemp -d "$output/package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$app" "$staging/增强右键.app"
ln -s /Applications "$staging/Applications"
name="SuperMenu-v$version-$architecture"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$name.zip"
hdiutil create -volname "增强右键 $version" -srcfolder "$staging" -format UDZO -ov "$output/$name.dmg"
hdiutil verify "$output/$name.dmg"
python3 - "$output" "$name" <<'PY'
from pathlib import Path
import hashlib
import sys
root, name = Path(sys.argv[1]), sys.argv[2]
files = [root / (name + suffix) for suffix in (".dmg", ".zip")]
(root / "SHA256SUMS.txt").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in files))
print("Packaged and verified:", *(str(p) for p in files), sep="\n")
PY
