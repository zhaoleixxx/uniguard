#!/bin/sh
# UniGuard 反向守护：UniVPN 一启动，就把 UniGuard 拉起来
#
# 规则：
#   1) 用户在菜单里「退出守护」后保持退出状态，直到下一次 UniVPN 重新启动；
#   2) UniGuard 崩溃/被强杀由它自己的 LaunchAgent 负责重启，这里不插手；
#   3) 不动 VPN 进程，只负责「看到 VPN 起来 → 把守护拉起来」。

UID_=$(id -u)
HOME_DIR="${HOME:-/Users/$(id -un)}"
STATE_DIR="$HOME_DIR/.uniguard"
STATE="$STATE_DIR/vpn.state"
QUIT_FLAG="$STATE_DIR/quit.flag"
LOG="$HOME_DIR/Library/Logs/UniGuard.log"

mkdir -p "$STATE_DIR"

running=0
if pgrep -x UniVPN >/dev/null 2>&1; then running=1; fi
prev=$(cat "$STATE" 2>/dev/null)

if [ "$running" != "$prev" ]; then
    echo "$running" > "$STATE"
fi

# VPN 从「没运行」→「运行」：说明是用户重新启动的，清掉上次的退出标记
if [ "$running" = 1 ] && [ "$prev" != 1 ]; then
    rm -f "$QUIT_FLAG"
fi

[ "$running" = 1 ] || exit 0
[ -f "$QUIT_FLAG" ] && exit 0
pgrep -x UniGuard >/dev/null 2>&1 && exit 0

logline() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if launchctl kickstart "gui/$UID_/com.uniguard.agent" >/dev/null 2>&1; then
    logline "watch：检测到 UniVPN 启动，已拉起守护"
elif /usr/bin/open -a UniGuard >/dev/null 2>&1; then
    logline "watch：检测到 UniVPN 启动，已打开 UniGuard"
else
    logline "watch：检测到 UniVPN 启动，但拉起守护失败"
fi
