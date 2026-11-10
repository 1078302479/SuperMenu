#!/bin/bash
set -euo pipefail

bundle="$1"
reference="${SUPERMENU_REFERENCE_APP:-/Applications/iRightMouse.app}/Contents/Resources"
target="$bundle/Contents/Resources/Templates"
mkdir -p "$target"
mkdir -p "$bundle/Contents/Resources/en.lproj"
cp Resources/en.lproj/Localizable.strings "$bundle/Contents/Resources/en.lproj/Localizable.strings"
mkdir -p "$bundle/Contents/Resources/zh-Hans.lproj"
cp Resources/zh-Hans.lproj/Localizable.strings "$bundle/Contents/Resources/zh-Hans.lproj/Localizable.strings"
manifest="$bundle/Contents/Info.plist"
plutil -insert SuperMenuBundledTemplates -array "$manifest"
index=0

stage() {
    local format="$1" source="$2"
    if [ -s "$source" ]; then
        cp "$source" "$target/blank.$format"
        plutil -insert "SuperMenuBundledTemplates.$index" -string "$format" "$manifest"
        index=$((index + 1))
    fi
}

stage docx Resources/Templates/blank.docx
stage xlsx Resources/Templates/blank.xlsx
stage pptx Resources/Templates/blank.pptx

if [ "${SUPERMENU_INCLUDE_REFERENCE_ASSETS:-1}" = 0 ]; then
    exit 0
fi

# Use the installed reference app only for local developer builds.
stage wps "$reference/WPS_wps.wps"
stage et "$reference/WPS_et.et"
stage dps "$reference/WPS_dps.dps"
stage pages "$reference/Pages.pages"
stage numbers "$reference/Numbers.numbers"
stage key "$reference/Keynote.key"
stage ai "$reference/Ai.ai"
stage psd "$reference/PSD.psd"

# The reference PNGs are local design assets and are not tracked in Git.
icon_index=design/reference-icons/index.json
icon_target="$bundle/Contents/Resources/TemplateIcons"
stage_icon() {
    local name="$1" file="$2" path
    path="$(plutil -extract "$name" raw -o - "$icon_index")"
    if [ -s "design/$path" ]; then
        mkdir -p "$icon_target"
        cp "design/$path" "$icon_target/$file.png"
    fi
}

for format in txt rtf xml docx xlsx pptx wps et dps pages numbers key ai psd md; do
    stage_icon "$format" "$format"
done
stage_icon newFile_icon new-file
stage_icon createNewFile_icon named-file
stage_icon "Copy File Name" copy-name
stage_icon "Copy Path" copy-path
stage_icon "Create Folder by File Name" folder-from-name
stage_icon "Cut" cut
stage_icon "Add to common path" add-favorite
stage_icon "File Information" file-info
stage_icon "Delete directly" delete
stage_icon "hide file" hide
stage_icon "unhide file" show
stage_icon hide_file_ext extension
stage_icon fix_filename repair-name
stage_icon "Send Shortcut to Desktop" desktop-alias
stage_icon AirDrop airdrop
stage_icon "Convert image format" convert-image
stage_icon fileIcon_icon file-icon
stage_icon "Dissolve Folder" dissolve
stage_icon "Set as Wallpaper" wallpaper
stage_icon "Grant write permission to selected files" grant-write
stage_icon iShot_logo ishot
stage_icon FastZip_logo fastzip
stage_icon DiskMap_logo diskmap

stage_icon general_icon nav-general
stage_icon newFile_icon nav-templates
stage_icon sendTo_icon nav-send
stage_icon commonFolder_icon nav-favorites
stage_icon fileIcon_icon nav-file-icons
stage_icon toolbox_icon nav-toolbox
stage_icon "Translate by Baidu" text-baidu
stage_icon "Translate by Google" text-google
stage_icon "Change to QR Code" text-qrCode

# Preserve the reference application icons in local builds where available.
while IFS= read -r asset; do
    stage_icon "$asset" "app-${asset#Open in }"
done < <(python3 - <<'ICONS'
import json
for name in json.load(open('design/reference-icons/index.json')):
    if name.startswith('Open in '): print(name)
ICONS
)

# Extract the local reference assets into the development bundle only.
if [ -f "$reference/Assets.car" ]; then
    mkdir -p .build/file-icon-module-cache
    swift -module-cache-path .build/file-icon-module-cache scripts/stage-file-icons.swift         "${reference%/Contents/Resources}" "$bundle/Contents/Resources/FileIconPresets"
fi
