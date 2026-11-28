#!/bin/bash
# Builds macos/.build into dist/appring.app. The icon comes from the ready-made assets/icons/macos.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="dist/appring.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/appring "$APP/Contents/MacOS/appring"
cp Info.plist "$APP/Contents/Info.plist"
cp Sources/appring/default.json "$APP/Contents/Resources/default.json"
cp ../assets/icons/macos/appring.icns "$APP/Contents/Resources/appring.icns"
echo "built $APP"
