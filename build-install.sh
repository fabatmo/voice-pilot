#!/bin/bash
# Builds and installs the primary /Applications/VoicePilot.app.
# Signs with the stable "VoicePilot Dev" cert — NEVER ad-hoc, which would
# rotate the CDHash and make macOS revoke every TCC grant.
set -euo pipefail

CERT="D4A1F9BB5292176F9D4537F16426491AF9888B83"
APP="/Applications/VoicePilot.app"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/.build/release/VoicePilot" "$APP/Contents/MacOS/VoicePilot"
cp "$REPO/Resources/AppIcon.icns"    "$APP/Contents/Resources/AppIcon.icns"
cp "$REPO/Resources/Info.plist"      "$APP/Contents/Info.plist"

echo "==> signing"
codesign --force --deep --sign "$CERT" \
    --entitlements "$REPO/Resources/VoicePilot.entitlements" "$APP"
codesign --verify --verbose "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority|^Identifier"
echo "==> installed $APP"
