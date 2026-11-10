#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/background-test
./scripts/prepare-webp.sh
webp="$(pwd -P)/.build/dependencies/libwebp-1.6.0"
root="$(cd .build/background-test && pwd -P)"
run="$(mktemp -d "$root/run.XXXXXX")"
volume=""
cleanup() {
    if [ -n "$volume" ] && ! hdiutil detach "$volume" >/dev/null; then
        printf 'Unable to detach test volume at %s\n' "$volume" >&2
        return 1
    fi
    rm -rf "$run"
}
trap cleanup EXIT
shared="$run/shared"
storage_key=SuperMenuLocalStorage
storage_path="$shared"
storage_entitlement='com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write'
if [ "${SUPERMENU_TEST_HOME_STORAGE:-0}" = 1 ]; then
    account_home="$(cd ~ && pwd -P)"
    case "$shared" in "$account_home"/*) ;; *) echo 'Home storage test requires a checkout under the account home.' >&2; exit 1 ;; esac
    storage_key=SuperMenuHomeRelativeStorage
    storage_path="${shared#"$account_home"}"
    storage_entitlement='com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-write'
fi
receiver="$run/SuperMenuSmoke.app"
sender="$run/SuperMenuSmokeSender.app"
id="io.github.1078302479.SuperMenu.smoke.$(basename "$run")"
scheme="supermenu-smoke-${run##*.}"
mkdir -m 700 "$shared"
mkdir -p "$sender/Contents/MacOS" "$receiver/Contents/MacOS"
if [ "${SUPERMENU_TEST_CROSS_VOLUME:-0}" = 1 ]; then
    mkdir "$shared/volume"
    hdiutil create -size 64m -fs APFS -volname SuperMenuSmoke "$run/smoke.dmg" >/dev/null
    hdiutil attach -nobrowse -noautoopen -mountpoint "$shared/volume" "$run/smoke.dmg" >/dev/null
    volume="$shared/volume"
    export SUPERMENU_TEST_VOLUME="$volume"
fi

swiftc -D SUPER_MENU_LOCAL_BUILD -D SUPERMENU_TEST -parse-as-library -module-cache-path "$root/module-cache" \
    Sources/Shared/*.swift Sources/App/*.swift \
    -I Sources/CArchive -larchive \
    -I "$webp/module" "$webp/src/.libs/libwebp.a" "$webp/sharpyuv/.libs/libsharpyuv.a" \
    Sources/FinderExtension/FinderSync.swift Tests/BackgroundHandoff.swift -o "$sender/Contents/MacOS/Smoke"
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
    plutil -insert "$storage_key" -string "$storage_path" "$bundle/Contents/Info.plist"
}
write_info "$receiver" receiver
write_info "$sender" sender
./scripts/stage-templates.sh "$sender"
./scripts/stage-templates.sh "$receiver"
plutil -insert CFBundleURLTypes -json '[{"CFBundleURLSchemes":[]}]' "$receiver/Contents/Info.plist"
plutil -insert CFBundleURLTypes.0.CFBundleURLSchemes.0 -string "$scheme" "$receiver/Contents/Info.plist"

entitlements="$run/entitlements.plist"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
plutil -insert "$storage_entitlement" -array "$entitlements"
plutil -insert "$storage_entitlement.0" -string "$storage_path/" "$entitlements"
codesign --force --sign - --entitlements "$entitlements" "$sender"
if [ "$storage_key" = SuperMenuHomeRelativeStorage ]; then
    codesign --force --sign - "$receiver"
else
    codesign --force --sign - --entitlements "$entitlements" "$receiver"
fi
direct="$run/SuperMenuDirectSmoke.app"
mkdir -p "$direct/Contents/MacOS" "$run/direct-shared"
cp "$sender/Contents/MacOS/Smoke" "$direct/Contents/MacOS/Smoke"
cp "$sender/Contents/Info.plist" "$direct/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$id.direct" "$direct/Contents/Info.plist"
plutil -remove "$storage_key" "$direct/Contents/Info.plist"
plutil -insert SuperMenuLocalStorage -string "$run/direct-shared" "$direct/Contents/Info.plist"
plutil -insert SuperMenuDirectFileAccess -bool true "$direct/Contents/Info.plist"
codesign --force --sign - "$direct"
"$direct/Contents/MacOS/Smoke" --direct-access
"$sender/Contents/MacOS/Smoke" "$receiver"
if [ "${SUPERMENU_CAPTURE_UI:-0}" = 1 ]; then
    mkdir -p .build/ui-check
    cp "$shared/ui/"*.png .build/ui-check/
fi
