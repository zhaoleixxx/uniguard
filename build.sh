#!/bin/bash
set -e
cd "$(dirname "$0")"
APP="build/UniGuard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -swift-version 5 -target arm64-apple-macos13.0 -O \
  -sdk "$(xcrun --show-sdk-path)" \
  Sources/GuardCore.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/UniGuard"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>UniGuard</string>
  <key>CFBundleIdentifier</key><string>com.uniguard.app</string>
  <key>CFBundleName</key><string>UniGuard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.6</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>UniGuard 需要在隧道断开时自动点击 UniVPN 客户端重新连接。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
