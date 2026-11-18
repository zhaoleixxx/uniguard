#!/bin/sh
set -e
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /usr/local/libexec
cp "$SRC_DIR/uniguard-routefix.sh" /usr/local/libexec/uniguard-routefix.sh
chmod 755 /usr/local/libexec/uniguard-routefix.sh
touch /var/log/uniguard-routefix.log
chmod 644 /var/log/uniguard-routefix.log

# DNS 黑名单配置（存在就保留用户修改）
mkdir -p /usr/local/etc/uniguard
if [ ! -f /usr/local/etc/uniguard/bad-dns.txt ]; then
    cat > /usr/local/etc/uniguard/bad-dns.txt <<'CONF'
# UniGuard DNS 守护：这些地址一旦出现在任一网络服务的 DNS 列表里就被删掉
# 每行一个 IPv4，可用 # 注释
61.139.2.69
CONF
fi
chmod 644 /usr/local/etc/uniguard/bad-dns.txt

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

# 清理历史版本用过的其它 label（凡是同名的旧 plist 一律卸掉）
for old in /Library/LaunchDaemons/*.uniguard.routefix.plist; do
    [ -f "$old" ] || continue
    case "$old" in */com.uniguard.routefix.plist) continue ;; esac
    lbl=$(basename "$old" .plist)
    launchctl bootout "system/$lbl" 2>/dev/null || true
    rm -f "$old"
done

launchctl bootout system/com.uniguard.routefix 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.uniguard.routefix.plist 2>/dev/null || \
  launchctl load -w /Library/LaunchDaemons/com.uniguard.routefix.plist
echo "routefix daemon installed"
