#!/bin/bash
# Builds VoicePilot-Next.app — a SEPARATE bundle for evaluating the new speech
# engines side by side with the installed VoicePilot.app.
#
# Distinct CFBundleIdentifier so both can run at once. That means macOS treats it
# as a new app for TCC: Microphone, Speech Recognition and Accessibility must be
# granted for it separately, and it must be relaunched after each grant.
set -euo pipefail

CERT="D4A1F9BB5292176F9D4537F16426491AF9888B83"   # "VoicePilot Dev" — never ad-hoc
APP="/Applications/VoicePilot-Next.app"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/.build/release/VoicePilot" "$APP/Contents/MacOS/VoicePilotNext"
cp "$REPO/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.fabianklainman.VoicePilotNext</string>
    <key>CFBundleName</key>
    <string>VoicePilot Next</string>
    <key>CFBundleExecutable</key>
    <string>VoicePilotNext</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>2.0.0-next</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0-next</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>VoicePilot Next needs to send keystrokes to your terminal.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoicePilot Next needs microphone access for continuous voice recognition.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>VoicePilot Next uses speech recognition to convert your voice into prompts.</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> signing with stable cert (never ad-hoc: ad-hoc rotates CDHash and revokes TCC)"
codesign --force --deep --sign "$CERT" \
    --entitlements "$REPO/Resources/VoicePilot.entitlements" \
    "$APP"

# Start paused so this bundle never types into the terminal at the same time as
# the installed VoicePilot.app. Start it from its own menu bar item.
defaults write com.fabianklainman.VoicePilotNext autoStartListening -bool false

codesign --verify --verbose "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "^Authority|^Identifier"
echo "==> done: $APP"
