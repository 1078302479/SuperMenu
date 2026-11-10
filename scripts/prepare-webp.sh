#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd -P)"
target="$root/.build/dependencies/libwebp-1.6.0"
if [ -s "$target/src/.libs/libwebp.a" ] && [ -s "$target/sharpyuv/.libs/libsharpyuv.a" ] && [ -f "$target/ready" ]; then
    exit 0
fi
archive=ThirdParty/libwebp-1.6.0.tar.gz
test "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" = e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
mkdir -p "$root/.build/dependencies"
tar -xzf "$archive" -C "$root/.build/dependencies"
cd "$target"
./configure --disable-shared --enable-static --disable-png --disable-jpeg --disable-tiff --disable-gif \
    --disable-sdl --disable-threading --disable-libwebpmux --disable-libwebpdemux \
    CFLAGS="-O2 -mmacosx-version-min=13.0" > configure.log 2>&1
make -j 4 -C sharpyuv > build.log 2>&1
make -j 4 -C src >> build.log 2>&1
mkdir -p module
cat > module/module.modulemap <<'MODULE'
module CWebP {
    header "../src/webp/encode.h"
    export *
}
MODULE
touch ready
