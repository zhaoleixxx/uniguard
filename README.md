# UniGuard

macOS 菜单栏守护程序：持续监控某个企业 VPN 客户端（华为 SVN 客户端 UniVPN）的隧道状态，隧道断了就**自动重连**，并把"重连不回去"的各种情况逐级兜底掉。

适用于无人值守场景（远程机器、值班机、长期挂机的办公机）——你不再需要坐在屏幕前点「连接」。

> 这是对**本机已安装的客户端**做外围守护，不替代客户端本身，也不绕过任何授权。请仅在你被授权使用的设备与账号上运行。

## 它解决的问题

| 现象 | 人工做法 | UniGuard 做法 |
|---|---|---|
| 隧道断了，客户端没反应 | 手动点「连接」 | 每 15 秒探测一次，断了就点「连接」 |
| 弹「返回码超时 / 请重新启动客户端」 | 关弹窗、重启客户端 | 读窗口文字识别弹窗 → 点「确定」→ 重启会话 |
| 客户端异常退出留下残留路由，连不上网关 | `sudo route delete <网关>` | root 常驻修复器自动清理（无需密码） |
| 点连接一直失败 | 反复手点 | 三级恢复阶梯，最后彻底重启客户端 |
| 系统唤醒后隧道是假的 | 手动重连 | 监听唤醒事件，立即探测 |
| 有多个 VPN 配置档 | 手动切回原来那一档 | 记住断线前是哪一档，重连前写回配置，再启动 |

## 组成

```
UniGuard.app            菜单栏守护程序（用户级 LaunchAgent 常驻）
└─ 探测：utun 接口 / VIP / 引擎进程 / 网关 TCP 1024 / 残留路由 / 客户端弹窗
└─ 恢复：点连接 → 重启客户端 → 彻底退出并重启
tools/uniguard-routefix.sh   root 级路由修复器（LaunchDaemon 常驻，每 8 秒扫一次）
```

## 安装

```sh
./build.sh                 # 编译，产物 build/UniGuard.app
./tools/install-agent.sh   # 安装到 ~/Applications 并注册 LaunchAgent（无需 root）
./tools/install-routefix.sh  # 注册 root 路由修复器（会要求管理员密码）
```

要求 macOS 13+、已安装 Command Line Tools（`xcode-select --install`）。

## 权限（一次性）

菜单栏图标能显示状态不需要任何权限；但**点按钮、读弹窗**需要自动化权限：

系统设置 → 隐私与安全性 → 自动化 → 允许 `UniGuard` 控制 `System Events`。

未授权时守护仍能拉起客户端，但点不动按钮，日志会提示：
`⚠️ 缺少自动化权限……`

> 注意：本程序以 ad-hoc 签名分发，**每次重新编译后系统会重新要求授权**。长期使用建议自备代码签名证书。

## 多配置档

客户端自身会记住"上次连接的档"。UniGuard 的做法：

1. 每次探测到"已连接"时，从客户端窗口读取当前档名（`VPN名称：` 右侧文字），记为目标档并写入 `~/.uniguard/last-profile.txt`；
2. 需要重连时，先把 `~/.UniVPN/sysconfig.ini` 的 `ClientLastAccessSession` 写回目标档，再启动客户端；
3. 因此重连回到的是**断线前那一档**，而不是客户端碰巧记住的档。

菜单里「目标配置档」可手动锁定某一档（默认"跟随断线前档位"）。

菜单上会标明档位来源，避免"用错档"：

| 标注 | 含义 |
|---|---|
| 实测 | 从客户端界面真实读到过，已持久化，重连就写回它 |
| 锁定 | 你在菜单里手工指定的档 |
| 推断，未记录 | 从未实测过（例如还没授权自动化），仅按客户端记录的 `ClientLastAccessSession` 推测，**不写回**，避免污染 |
| 未知 | 完全无法判断 |

网关地址也跟随这个档位动态解析，不会拿另一个档的网关做健康判断。

## 恢复阶梯

| 级别 | 动作 | 触发条件 |
|---|---|---|
| 一级 | 点「连接」 | 引擎在、隧道没起来 |
| 二级 | 只退出 GUI 再重开 | 连续 3 次点连接无效 |
| 三级·终极兜底 | 优雅退出 → 强杀 `UniVPN` / `UniVPNCS` / `UniVPNPromoteService` → 确认进程消失 → 清残留路由 → 写回配置档 → 重新启动 → 补点一次 | 连续 6 次失败／二级重启两次仍无效／隧道假连 |

退避：15s → 30s → 60s → 120s → 240s，避免把账号打到风控。

## 菜单里能看什么

状态、隧道名与 VIP、引擎/网关通断、已连时长、重连与断开次数、上次动作、断线前档位、最近 12 次状态变化、彻底重启次数。

图标语义：实心盾=在线，半盾=重连中，斜线=引擎停，感叹=残留路由，铃铛=弹窗阻塞，三角=隧道异常。

## 日志与外部触发

```
~/Library/Logs/UniGuard.log            守护日志
~/Library/Logs/UniGuard.err            标准错误
/var/log/uniguard-routefix.log         路由修复器日志（root）
```

```sh
touch /tmp/uniguard.routefix.trigger    # 请求立即清理残留路由
touch /tmp/uniguard.fullrestart.trigger # 请求立即彻底重启客户端
```

## 卸载

```sh
launchctl bootout gui/$(id -u)/com.uniguard.agent
rm -rf ~/Applications/UniGuard.app ~/Library/LaunchAgents/com.uniguard.agent.plist
sudo launchctl bootout system/com.uniguard.routefix
sudo rm -f /Library/LaunchDaemons/com.uniguard.routefix.plist /usr/local/libexec/uniguard-routefix.sh
```

## 残留路由清理（按档位定向）

断开异常时，客户端会在路由表里留下一条指向网关的主机路由（`route add -host <网关> <隧道内地址>`）。
隧道销毁后这条路由还在，后续所有发往网关的包都会被它带进黑洞，表现就是"怎么点连接都连不上、只报返回码超时"。

UniGuard 的处理方式：

- **定向**：清理请求里带当前配置档的网关 IP，root 修复器优先清这一条，不去动其它档的路由。
- **绑进失败阶梯**，不是靠旁路碰运气：
  - 二级重启（重启 GUI）启动客户端前先清一次，并等到真的清干净再启动；
  - 三级兜底（完全退出重启）第 ④ 步同样先清后启；
  - 连续拨号失败 ≥ 2 次时立即触发一次（90 秒内不重复）；
  - **掉线刚被检测到就先预清一次**（等最多 4 秒，60 秒节流）。删除残留路由本身没有副作用，没有可删的就只是 `not in table`，所以提前清比等到失败更划算。
- **两种残留形态都能识别**（必须直接扫路由表，`route get` 会被 `/32` 克隆路由掩盖）：
  1. 接口指向已经不存在的 `utunN`；
  2. 接口看着正常（en0），但下一跳落在隧道地址池里、而该地址已不被任何存活 utun 拥有。

只读自查（不修改任何东西）：

```sh
# 当前网关的主机路由
netstat -rn -f inet | grep $(grep -h GatewayAddress ~/.UniVPN/config/*.ini | cut -d= -f2 | tr -d " ")
# 存活隧道与 VIP
ifconfig | grep -A3 '^utun'
```

## 限制

- 依赖客户端自身的登录态（记住密码/自动登录需已开启），守护不保存任何凭据。
- 网关地址、账号、配置档名均运行期读取，代码中不含任何站点信息。
- 若账号在网关侧被限流或被"单会话策略"踢下线，重连会持续退避重试，但能否成功取决于服务端策略。
- 仅支持 macOS；UI 自动化基于 System Events，窗口结构变化需相应调整匹配文字。

## License

MIT
