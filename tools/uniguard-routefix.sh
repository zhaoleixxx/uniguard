#!/bin/sh
# UniGuard 修复器（root 常驻）：
#   1) 清掉指向已消失 utun 的残留路由
#   2) DNS 守护：清掉 VPN 客户端硬塞进来的 DNS（默认 61.139.2.69）
LOG=/var/log/uniguard-routefix.log
# 网关列表不写死：从所有用户的 UniVPN 配置里自动提取
GW_LIST="${UNIGUARD_GW_LIST:-}"
if [ -z "$GW_LIST" ]; then
    GW_LIST=$(grep -h -i "^GatewayAddress" /Users/*/.UniVPN/config/*.ini 2>/dev/null \
        | sed 's/[[:space:]]//g' | cut -d= -f2 | sort -u | tr '\n' ' ')
fi

# ---------- DNS 守护配置 ----------
DNS_TRIGGER=/tmp/uniguard.dnsfix.trigger
BAD_DNS_DEFAULT="61.139.2.69"
BAD_DNS_CONF="${UNIGUARD_BAD_DNS_CONF:-/usr/local/etc/uniguard/bad-dns.txt}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# 暂停 DNS 守护：任一用户建了 ~/.uniguard/dns-guard.off 就整体停手
dns_guard_paused() {
    for f in /Users/*/.uniguard/dns-guard.off; do
        [ -e "$f" ] && return 0
    done
    return 1
}

bad_dns_list() {
    echo "$BAD_DNS_DEFAULT"
    [ -r "$BAD_DNS_CONF" ] && grep -E '^[0-9]+(\.[0-9]+){3}$' "$BAD_DNS_CONF" 2>/dev/null
}

# 删掉各网络服务 DNS 里的黑名单条目，其余保持原样；删空了就交回 DHCP
fix_dns_once() {
    dns_guard_paused && return 0
    BAD=$(bad_dns_list | sort -u | tr '\n' ' ')
    [ -n "$(echo $BAD)" ] || return 0
    /usr/sbin/networksetup -listallnetworkservices 2>/dev/null | tail -n +2 \
        | grep -v '^\*' | while IFS= read -r svc; do
        [ -n "$svc" ] || continue
        CUR=$(/usr/sbin/networksetup -getdnsservers "$svc" 2>/dev/null)
        case "$CUR" in *"aren't any DNS"*) continue ;; esac
        KEEP=""; HIT=""
        for ip in $CUR; do
            skip=0
            for b in $BAD; do [ "$ip" = "$b" ] && skip=1; done
            if [ "$skip" = 1 ]; then HIT="$HIT $ip"; else KEEP="$KEEP $ip"; fi
        done
        [ -n "$HIT" ] || continue
        if [ -z "$(echo $KEEP)" ]; then
            if /usr/sbin/networksetup -setdnsservers "$svc" Empty >/dev/null 2>&1; then
                log "DNS：${svc} 删除$HIT，改为 DHCP 下发"
            else
                log "DNS：${svc} 删除$HIT 失败（返回码 $?）"
            fi
        else
            if /usr/sbin/networksetup -setdnsservers "$svc" $KEEP >/dev/null 2>&1; then
                log "DNS：${svc} 删除$HIT，保留$KEEP"
            else
                log "DNS：${svc} 删除$HIT 失败（返回码 $?）"
            fi
        fi
    done
}

# 触发文件里可以带"该清哪个网关"的提示（守护按当前配置档写入）
GW_HINT=""
take_trigger() {
    [ -f /tmp/uniguard.routefix.trigger ] || return 1
    H=$(tr -d '[:space:]' < /tmp/uniguard.routefix.trigger 2>/dev/null)
    rm -f /tmp/uniguard.routefix.trigger 2>/dev/null
    case "$H" in
        *[!0-9.]*|"") ;;                     # 不是纯 IP 就忽略
        *) GW_HINT="$H" ;;
    esac
    return 0
}

live_tuns() { /sbin/ifconfig 2>/dev/null | awk '/^utun[0-9]+: flags/ {print $1}' | tr -d ':' ; }

# 活的 utun 上的地址（VIP），用于识别"经由隧道内地址"的坏路由
live_tun_vips() {
    /sbin/ifconfig 2>/dev/null | awk '/^utun[0-9]+:/{tun=1} /inet /{if(tun==1) print $2} /^[a-z]/&&!/^utun/{tun=0}'
}

fix_once() {
    LIVE=$(live_tuns)
    # 1) 网关相关路由：直接扫表，逐个判断（不依赖 route get，避免被 /32 克隆路由掩盖）
    for gw in $GW_HINT $GW_LIST; do
        /usr/sbin/netstat -rn -f inet 2>/dev/null \
            | awk -v g="$gw" '($1==g || $1==g"/32") {print $1"|"$2"|"$NF}' \
            | while IFS='|' read -r dst via ifc; do
                break_reason=""
                case "$ifc" in
                    utun*)
                        echo "$LIVE" | grep -qx "$ifc" || break_reason="隧道 $ifc 已不存在"
                        ;;
                    *)
                        # 下一跳落在隧道池里，但没有存活 utun 拥有这个地址 → 坏路由
                        VIPS=$(live_tun_vips)
                        for vip in $VIPS; do
                            PFX=$(echo "$vip" | cut -d. -f1-2)
                            case "$via" in
                                "$PFX".*)
                                    echo "$VIPS" | grep -qx "$via" || break_reason="下一跳 $via 属于隧道池且已不存在"
                                    ;;
                            esac
                        done
                        ;;
                esac
                if [ -n "$break_reason" ]; then
                    /sbin/route delete -host "$gw" >/dev/null 2>&1 \
                        && log "删除网关坏路由 $gw（$break_reason）"
                fi
            done
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

log "routefix 启动（DNS 黑名单：$(bad_dns_list | sort -u | tr '\n' ' ')）"
fix_dns_once
tick=0
while :; do
    if take_trigger; then
        log "收到清理请求${GW_HINT:+（目标网关 $GW_HINT）}"
        fix_once
        GW_HINT=""
    else
        fix_once
    fi
    # 手动触发（菜单「立即清理 VPN DNS」）→ 立刻清一次
    if [ -f "$DNS_TRIGGER" ]; then
        rm -f "$DNS_TRIGGER" 2>/dev/null
        log "收到 DNS 清理请求"
        fix_dns_once
        tick=0
    fi
    # 自动巡检：每 2 轮（约 8 秒）扫一次 DNS
    tick=$((tick + 1))
    [ $((tick % 2)) -eq 0 ] && fix_dns_once
    sleep 4
done
