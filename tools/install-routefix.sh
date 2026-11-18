#!/bin/sh
set -e
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /usr/local/libexec
cp "$SRC_DIR/uniguard-routefix.sh" /usr/local/libexec/uniguard-routefix.sh
chmod 755 /usr/local/libexec/uniguard-routefix.sh
touch /var/log/uniguard-routefix.log
chmod 644 /var/log/uniguard-routefix.log

cat > /Library/LaunchDaemons/com.uniguard.routefix.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.uniguard.routefix</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>/usr/local/libexec/uniguard-routefix.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/uniguard-routefix.err</string>
</dict>
</plist>
PLIST

# 清理旧 label（改名前的版本）
launchctl bootout system/work.zhaolei.uniguard.routefix 2>/dev/null || true
rm -f /Library/LaunchDaemons/work.zhaolei.uniguard.routefix.plist

launchctl bootout system/com.uniguard.routefix 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.uniguard.routefix.plist 2>/dev/null || \
  launchctl load -w /Library/LaunchDaemons/com.uniguard.routefix.plist
echo "routefix daemon installed"
