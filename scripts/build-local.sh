#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

root="$(pwd -P)"
build="${SUPERMENU_BUILD_DIR:-$root/.build/local}"
if [[ "$build" != /* ]]; then build="$root/$build"; fi
mkdir -p "$build"
shared="$build/shared"
if [[ "${SUPERMENU_DISTRIBUTION:-0}" != 1 ]]; then
    mkdir -m 700 -p "$shared"
else
    export SUPERMENU_INCLUDE_REFERENCE_ASSETS=0
fi
stage="$(mktemp -d "$build/staging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/增强右键.app"
extension="$app/Contents/PlugIns/SuperMenuFinder.appex"
app_id="io.github.1078302479.SuperMenu"
home_storage="/Library/Application Support/$app_id"
architecture="$(uname -m)"
deployment="13.0"

mkdir -p "$app/Contents/"{MacOS,Resources} "$extension/Contents/MacOS"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
./scripts/prepare-webp.sh
webp="$root/.build/dependencies/libwebp-1.6.0"
flags=(-sdk "$sdk" -target "$architecture-apple-macosx$deployment" -module-cache-path "$build/module-cache" -parse-as-library -D SUPER_MENU_LOCAL_BUILD)

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$app_id</string>
<key>CFBundleName</key><string>增强右键</string>
<key>CFBundleDisplayName</key><string>增强右键</string>
<key>CFBundleExecutable</key><string>SuperMenu</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.4</string>
<key>CFBundleVersion</key><string>32</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>NSAppleEventsUsageDescription</key><string>在所选目录中打开终端窗口或 iTerm2 标签页。</string>
<key>NSServices</key><array>
<dict><key>NSMenuItem</key><dict><key>default</key><string>增强右键 / 百度翻译</string></dict>
<key>NSMessage</key><string>translateWithBaidu</string><key>NSPortName</key><string>SuperMenu</string>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array></dict>
<dict><key>NSMenuItem</key><dict><key>default</key><string>增强右键 / 谷歌翻译</string></dict>
<key>NSMessage</key><string>translateWithGoogle</string><key>NSPortName</key><string>SuperMenu</string>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array></dict>
<dict><key>NSMenuItem</key><dict><key>default</key><string>增强右键 / 生成二维码</string></dict>
<key>NSMessage</key><string>generateQRCode</string><key>NSPortName</key><string>SuperMenu</string>
<key>NSSendTypes</key><array><string>public.utf8-plain-text</string><string>NSStringPboardType</string></array></dict>
<dict><key>NSMenuItem</key><dict><key>default</key><string>增强右键 / 文件服务</string></dict>
<key>NSMessage</key><string>processFiles</string><key>NSPortName</key><string>SuperMenu</string>
<key>NSSendTypes</key><array><string>public.file-url</string></array>
<key>NSRequiredContext</key><dict><key>NSServiceCategory</key><string>Files</string></dict></dict>
</array>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>LSMinimumSystemVersion</key><string>$deployment</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>$app_id.template-row</string>
<key>UTTypeDescription</key><string>增强右键模板行</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
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
<key>CFBundleName</key><string>增强右键 Finder 扩展</string>
<key>CFBundleDisplayName</key><string>增强右键</string>
<key>CFBundleExecutable</key><string>SuperMenuFinder</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>0.3.4</string>
<key>CFBundleVersion</key><string>32</string>
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
$1
</dict></plist>
PLIST
}
write_entitlements '
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.automation.apple-events</key><true/>
<key>com.apple.security.temporary-exception.apple-events</key>
<array><string>com.apple.Terminal</string><string>com.googlecode.iterm2</string></array>
<key>com.apple.security.temporary-exception.shared-preference.read-write</key>
<array><string>com.apple.finder</string></array>' > "$stage/app.entitlements"
write_entitlements '<key>com.apple.security.app-sandbox</key><true/>' > "$stage/finder.entitlements"

for bundle in "$app" "$extension"; do
    plutil -insert SuperMenuDirectFileAccess -bool true "$bundle/Contents/Info.plist"
    if [[ "${SUPERMENU_DISTRIBUTION:-0}" == 1 ]]; then
        plutil -insert SuperMenuHomeRelativeStorage -string "$home_storage" "$bundle/Contents/Info.plist"
    else
        plutil -insert SuperMenuLocalStorage -string "$shared" "$bundle/Contents/Info.plist"
    fi
    ./scripts/stage-templates.sh "$bundle"
done
if [[ "${SUPERMENU_DISTRIBUTION:-0}" == 1 ]]; then
    storage_entitlement='com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-write'
    shared="$home_storage"
else
    storage_entitlement='com\.apple\.security\.temporary-exception\.files\.absolute-path\.read-write'
fi
plutil -insert "$storage_entitlement" -array "$stage/finder.entitlements"
plutil -insert "$storage_entitlement.0" -string "$shared/" "$stage/finder.entitlements"

swiftc "${flags[@]}" -module-name SuperMenu Sources/Shared/*.swift Sources/App/*.swift \
    -I Sources/CArchive -larchive \
    -I "$webp/module" "$webp/src/.libs/libwebp.a" "$webp/sharpyuv/.libs/libsharpyuv.a" \
    -o "$app/Contents/MacOS/SuperMenu"
swiftc "${flags[@]}" -application-extension -module-name SuperMenuFinder Sources/Shared/*.swift \
    Sources/FinderExtension/*.swift -Xlinker -e -Xlinker _NSExtensionMain -o "$extension/Contents/MacOS/SuperMenuFinder"

swift -module-cache-path "$build/module-cache" scripts/render-icon.swift design/app-icon.svg "$stage/icon.png"
sips -s format icns "$stage/icon.png" --out "$app/Contents/Resources/AppIcon.icns" >/dev/null
cp Resources/MenuBarIcon.svg "$app/Contents/Resources/"
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE "$app/Contents/Resources/Licenses/MIT.txt"
cp "$webp/COPYING" "$app/Contents/Resources/Licenses/libwebp-COPYING"
cp "$webp/PATENTS" "$app/Contents/Resources/Licenses/libwebp-PATENTS"

codesign --force --sign - --entitlements "$stage/finder.entitlements" "$extension"
codesign --force --sign - --entitlements "$stage/app.entitlements" "$app"
codesign --verify --deep --strict "$app"

output="$build/增强右键.app"
if [ -e "$output" ]; then rm -rf "$output"; fi
mv "$app" "$output"
legacy="$build/SuperMenu.app"
if [[ -d "$legacy" && ! -L "$legacy" ]] &&
   [[ "$(plutil -extract CFBundleIdentifier raw -o - "$legacy/Contents/Info.plist" 2>/dev/null)" == "$app_id" ]]; then
    mv "$legacy" "$stage/"
fi
printf '%s\n' "$output"
