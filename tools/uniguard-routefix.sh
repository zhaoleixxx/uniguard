#!/bin/sh
# UniGuard 路由修复器（root 常驻）：清掉指向已消失 utun 的残留路由
LOG=/var/log/uniguard-routefix.log
# 网关列表不写死：从所有用户的 UniVPN 配置里自动提取
GW_LIST="${UNIGUARD_GW_LIST:-}"
if [ -z "$GW_LIST" ]; then
    GW_LIST=$(grep -h -i "^GatewayAddress" /Users/*/.UniVPN/config/*.ini 2>/dev/null \
        | sed 's/[[:space:]]//g' | cut -d= -f2 | sort -u | tr '\n' ' ')
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

live_tuns() { /sbin/ifconfig 2>/dev/null | awk '/^utun[0-9]+: flags/ {print $1}' | tr -d ':' ; }

fix_once() {
    LIVE=$(live_tuns)
    # 1) 网关主机路由若指向不存在的 utun → 删除
    for gw in $GW_LIST; do
        IF=$(/sbin/route -n get "$gw" 2>/dev/null | awk '/interface:/{print $2}')
        case "$IF" in
            utun*)
                echo "$LIVE" | grep -qx "$IF" || {
                    /sbin/route delete -host "$gw" >/dev/null 2>&1 && log "删除网关残留路由 $gw -> $IF"
                }
                ;;
        esac
    done
    # 2) 所有指向不存在 utun 的路由一并清理
    /usr/sbin/netstat -rn -f inet 2>/dev/null | while read -r dst rest; do
        case "$dst" in *utun*|Destination|Routing|Internet:|Netif) continue;; esac
        IF=$(echo "$rest" | awk '{print $NF}')
        case "$IF" in
            utun*)
                echo "$LIVE" | grep -qx "$IF" || {
                    /sbin/route delete -inet "$dst" >/dev/null 2>&1 && log "删除残留路由 $dst -> $IF"
                }
                ;;
        esac
    done
}

log "routefix 启动"
while :; do
    fix_once
    # 用户点「清理残留路由」时会创建触发文件，立即响应
    if [ -f /tmp/uniguard.routefix.trigger ]; then
        rm -f /tmp/uniguard.routefix.trigger
        log "收到手动触发，执行清理"
        fix_once
    fi
    sleep 8
done
