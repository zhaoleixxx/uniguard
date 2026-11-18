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
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
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

# 反向守护：UniVPN 启动时把 UniGuard 拉起来（用户退出后保持退出，直到下次启动 VPN）
WATCH_PLIST="$HOME/Library/LaunchAgents/com.uniguard.watch.plist"
cat > "$WATCH_PLIST" <<WATCHEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.uniguard.watch</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>$DEST/Contents/Resources/uniguard-watch.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/UniGuard.watch.err</string>
</dict>
</plist>
WATCHEOF

launchctl bootout gui/$(id -u)/com.uniguard.watch 2>/dev/null || true
launchctl bootstrap gui/$(id -u) "$WATCH_PLIST" 2>/dev/null \
  || launchctl load -w "$WATCH_PLIST" 2>/dev/null || true
echo "watch agent installed"
echo "agent installed at $DEST"
