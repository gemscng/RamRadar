#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) RamRadar.app into ./build and ad-hoc signs it.
#   scripts/build-app.sh            # version from VERSION file
#   VERSION=1.2.0 scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
APP="build/RamRadar.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/RamRadar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RamRadar"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
echo "Built $APP ($VERSION)"
