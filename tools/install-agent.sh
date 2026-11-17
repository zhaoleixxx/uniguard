#!/bin/sh
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/build/UniGuard.app"
DEST="$HOME/Applications/UniGuard.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

PLIST="$HOME/Library/LaunchAgents/com.uniguard.agent.plist"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.uniguard.agent</string>
  <key>ProgramArguments</key>
  <array><string>$DEST/Contents/MacOS/UniGuard</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/UniGuard.err</string>
</dict>
</plist>
PLISTEOF

pkill -x UniGuard 2>/dev/null || true
launchctl bootout gui/$(id -u)/com.uniguard.agent 2>/dev/null || true
sleep 1
launchctl bootstrap gui/$(id -u) "$PLIST" 2>/tmp/uniguard.bootstrap.err \
  || launchctl load -w "$PLIST" \
  || echo "安装失败：$(cat /tmp/uniguard.bootstrap.err)"
sleep 2
launchctl print gui/$(id -u)/com.uniguard.agent 2>/dev/null | grep -E "state = running|pid =" | head -2
echo "agent installed at $DEST"
