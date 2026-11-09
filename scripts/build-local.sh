#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

root="$(pwd -P)"
build="${SUPERMENU_BUILD_DIR:-$root/.build/local}"
if [[ "$build" != /* ]]; then build="$root/$build"; fi
mkdir -p "$build"
shared="$build/shared"
mkdir -m 700 -p "$shared"
stage="$(mktemp -d "$build/staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/SuperMenu.app"
extension="$app/Contents/PlugIns/SuperMenuFinder.appex"
app_id="io.github.1078302479.SuperMenu"
architecture="$(uname -m)"
deployment="13.0"

mkdir -p "$app/Contents/"{MacOS,Resources} "$extension/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
flags=(-sdk "$sdk" -target "$architecture-apple-macosx$deployment" -module-cache-path "$build/module-cache" -parse-as-library -D SUPER_MENU_LOCAL_BUILD)

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id</string>
<key>CFBundleName</key><string>SuperMenu</string>
<key>CFBundleDisplayName</key><string>SuperMenu</string>
<key>CFBundleExecutable</key><string>SuperMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>$deployment</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>$app_id.request</string>
<key>CFBundleURLSchemes</key><array><string>supermenu-local</string></array>
</dict></array>
</dict></plist>
PLIST

cat > "$extension/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id.Finder</string>
<key>CFBundleName</key><string>SuperMenu Finder</string>
<key>CFBundleDisplayName</key><string>SuperMenu</string>
<key>CFBundleExecutable</key><string>SuperMenuFinder</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>$deployment</string>
<key>NSExtension</key><dict>
<key>NSExtensionAttributes</key><dict/>
<key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
<key>NSExtensionPrincipalClass</key><string>SuperMenuFinder.FinderSync</string>
</dict>
</dict></plist>
PLIST

write_entitlements() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
$1
</dict></plist>
PLIST
}
write_entitlements '
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>' > "$stage/app.entitlements"
write_entitlements '' > "$stage/finder.entitlements"

for bundle in "$app" "$extension"; do
    plutil -insert SuperMenuLocalStorage -string "$shared" "$bundle/Contents/Info.plist"
done
for entitlements in "$stage/app.entitlements" "$stage/finder.entitlements"; do
    plutil -insert 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write' -array "$entitlements"
    plutil -insert 'com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write.0' -string "$shared/" "$entitlements"
done

swiftc "${flags[@]}" -module-name SuperMenu Sources/Shared/*.swift Sources/App/*.swift \
    -o "$app/Contents/MacOS/SuperMenu"
swiftc "${flags[@]}" -application-extension -module-name SuperMenuFinder Sources/Shared/*.swift \
    Sources/FinderExtension/*.swift -Xlinker -e -Xlinker _NSExtensionMain -o "$extension/Contents/MacOS/SuperMenuFinder"

swift -module-cache-path "$build/module-cache" scripts/render-icon.swift design/app-icon.svg "$stage/icon.png"
sips -s format icns "$stage/icon.png" --out "$app/Contents/Resources/AppIcon.icns" >/dev/null

codesign --force --sign - --entitlements "$stage/finder.entitlements" "$extension"
codesign --force --sign - --entitlements "$stage/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

output="$build/SuperMenu.app"
if [ -e "$output" ]; then rm -rf "$output"; fi
mv "$app" "$output"
printf '%s\n' "$output"
