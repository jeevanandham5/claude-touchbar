#!/bin/bash
# Builds build/ClaudeTouchBar.app (Touch Bar helper + hook CLI inside) with clang from the
# Command Line Tools. No Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"

xcode-select -p >/dev/null 2>&1 || { echo "Needs Apple's Command Line Tools. Run: xcode-select --install"; exit 1; }

APP=build/ClaudeTouchBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

clang -fobjc-arc -O2 -Wall -mmacosx-version-min=11.0 -framework AppKit \
    Sources/App.m -o "$APP/Contents/MacOS/ClaudeTouchBar"
clang -fobjc-arc -O2 -Wall -mmacosx-version-min=11.0 -framework Foundation \
    Sources/Hook.m -o "$APP/Contents/MacOS/claude-touchbar-hook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.claude.touchbar</string>
    <key>CFBundleName</key><string>ClaudeTouchBar</string>
    <key>CFBundleExecutable</key><string>ClaudeTouchBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/claude-touchbar-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
