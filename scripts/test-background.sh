#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/background-test
root="$(cd .build/background-test && pwd -P)"
run="$(mktemp -d "$root/run.XXXXXX")"
trap 'rm -rf "$run"' EXIT
shared="$run/shared"
receiver="$run/SuperMenuSmoke.app"
sender="$run/SuperMenuSmokeSender.app"
id="io.github.1078302479.SuperMenu.smoke.$(basename "$run")"
scheme="supermenu-smoke-${run##*.}"
mkdir -m 700 "$shared"
mkdir -p "$sender/Contents/MacOS" "$receiver/Contents/MacOS"

swiftc -D SUPER_MENU_LOCAL_BUILD -module-cache-path "$root/module-cache" \
    Sources/Shared/*.swift Sources/App/FileActions.swift Tests/BackgroundHandoff.swift -o "$sender/Contents/MacOS/Smoke"
cp "$sender/Contents/MacOS/Smoke" "$receiver/Contents/MacOS/Smoke"

write_info() {
    local bundle="$1" suffix="$2"
    cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id.$suffix</string>
<key>CFBundleExecutable</key><string>Smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSBackgroundOnly</key><true/>
</dict></plist>
PLIST
    plutil -insert SuperMenuLocalScheme -string "$scheme" "$bundle/Contents/Info.plist"
    plutil -insert SuperMenuLocalStorage -string "$shared" "$bundle/Contents/Info.plist"
}
write_info "$receiver" receiver
write_info "$sender" sender
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLSchemes":[]}]' "$receiver/Contents/Info.plist"
plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes.0 -string "$scheme" "$receiver/Contents/Info.plist"

entitlements="$run/entitlements.plist"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key><array/>
</dict></plist>
PLIST
plutil -insert 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write.0' -string "$shared/" "$entitlements"
for bundle in "$sender" "$receiver"; do
    codesign --force --sign - --entitlements "$entitlements" "$bundle"
done
"$sender/Contents/MacOS/Smoke" "$receiver"
