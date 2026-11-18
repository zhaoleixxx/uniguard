import Foundation
import AppKit

// MARK: - 故障分类

enum Fault: String {
    case ok            = "正常"
    case engineDead    = "引擎未运行"
    case dialTimeout   = "连接未成功"
    case dialogStuck   = "客户端弹窗阻塞"
    case staleRoute    = "残留路由挡网关"
    case tunnelSilent  = "隧道起来了但不通"
}

struct Snapshot {
    var fault: Fault = .engineDead
    var tunName = ""
    var vip = ""
    var gateway = ""
    var gatewayIf = ""
    var engineAlive = false
    var gatewayReachable = false
    var staleRoutes: [String] = []
    var dialogText = ""
    var activeProfile = ""
    var targetProfile = ""
    var targetSource = "none"
    var pinnedProfile = ""
    var attempt = 0
    var note = ""
    var lastAction = ""
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var out = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return }
            lock.lock(); out += String(data: d, encoding: .utf8) ?? ""; lock.unlock()
        }
        do { try p.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; return (-1, "") }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() }
        usleep(30_000)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let s = out; lock.unlock()
        return (p.terminationStatus, s)
    }

    @discardableResult
    static func sh(_ c: String, timeout: TimeInterval = 20) -> (Int32, String) {
        run("/bin/sh", ["-c", c], timeout: timeout)
    }

    static func osa(_ script: String, timeout: TimeInterval = 15) -> String {
        let (_, o) = run("/usr/bin/osascript", ["-e", script], timeout: timeout)
        return o.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 守护

final class Guard {
    static let shared = Guard()

    private init() {
        loadPersistedProfile()          // 先载入断线前档位
        gateway = resolveGateway()      // 再按它解析网关
    }

    /// 网关不写死：优先环境变量，其次当前档配置，最后任一档配置
    func resolveGateway() -> String {
        if let e = ProcessInfo.processInfo.environment["UNIGUARD_GATEWAY"], !e.isEmpty { return e }
        let files = availableProfiles()
        guard !files.isEmpty else { return "" }
        let last = targetProfile.isEmpty ? readLastSession() : targetProfile
        let pick = files.first(where: { $0 == last }) ?? files[0]
        let path = configDir + "/" + pick
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        for line in txt.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("gatewayaddress"), let eq = t.firstIndex(of: "=") {
                let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
        return ""
    }

    private(set) var snap = Snapshot()
    var onChange: ((Snapshot) -> Void)?

    var logPath = NSHomeDirectory() + "/Library/Logs/UniGuard.log"
    var gateway = ""
    var vipPrefix = "172.16."
    var interval: TimeInterval = 15
    var paused = false
    var cooldownUntil = Date.distantPast

    private var streak = 0
    private var lastRestart = Date.distantPast
    private var lastDialogDismiss = Date.distantPast
    private var lastRouteFixReq = Date.distantPast
    private var lastActionText = ""

    // 运行记录
    var startedAt = Date()
    private(set) var history: [(Date, Fault)] = []
    private(set) var downCount = 0
    private(set) var upCount = 0
    private var lastFault: Fault? = nil
    private var softRestarts = 0
    private(set) var fullRestarts = 0
    private var lastFullRestart = Date.distantPast
    private var lastAuthWarn = Date.distantPast
    /// 点按钮被系统拒绝（缺自动化权限）时为 true，此后走重启路径而不是反复点
    private(set) var axBlocked = false
    private var axRetryAt = Date.distantPast

    // 多配置档支持：断线前记住是哪一档，重连时写回客户端配置
    var pinnedProfile = ""
    private(set) var targetProfile = ""
    private(set) var activeProfile = ""
    /// 目标档来源：measured=实测到过、pinned=手动锁定、inferred=从客户端记录推断、none=未知
    private(set) var targetSource = "none"

    private var lastProfileFile: String { NSHomeDirectory() + "/.uniguard/last-profile.txt" }
    private var okSince: Date? = nil

    // MARK: 日志
    func log(_ m: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(m)\n"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: line.data(using: .utf8) ?? Data())
        }
    }

    // MARK: 探测

    private func tunnels() -> [(name: String, ip: String)] {
        let (_, out) = Shell.run("/sbin/ifconfig", [], timeout: 10)
        var r: [(String, String)] = []
        var cur = ""
        for raw in out.split(separator: "\n") {
            let l = String(raw)
            if !l.hasPrefix("\t") && l.contains(": flags=") {
                cur = String(l.split(separator: ":")[0])
            } else if l.contains("inet ") {
                let t = l.split(separator: " ")
                if t.count >= 2 && cur.hasPrefix("utun") { r.append((cur, String(t[1]))) }
            }
        }
        return r
    }

    private func engineAlive() -> Bool {
        let (_, out) = Shell.sh("pgrep -x UniVPNCS", timeout: 6)
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sysconfigPath: String { NSHomeDirectory() + "/.UniVPN/sysconfig.ini" }
    private var configDir: String { NSHomeDirectory() + "/.UniVPN/config" }

    private func loadPersistedProfile() {
        guard let v = (try? String(contentsOfFile: lastProfileFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        targetProfile = v
        targetSource = "measured"
    }

    private func persistProfile(_ v: String) {
        let dir = NSHomeDirectory() + "/.uniguard"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? v.write(toFile: lastProfileFile, atomically: true, encoding: .utf8)
    }

    func availableProfiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: configDir)) ?? [])
            .filter { $0.hasSuffix(".ini") }.sorted()
    }

    func readLastSession() -> String {
        guard let s = try? String(contentsOfFile: sysconfigPath, encoding: .utf8) else { return "" }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ClientLastAccessSession"), let eq = t.firstIndex(of: "=") {
                return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    @discardableResult
    func setLastSession(_ name: String) -> Bool {
        guard !name.isEmpty, var txt = try? String(contentsOfFile: sysconfigPath, encoding: .utf8) else { return false }
        var lines = txt.components(separatedBy: "\n")
        var hit = false
        for i in lines.indices where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("ClientLastAccessSession") {
            lines[i] = "ClientLastAccessSession = \(name)"
            hit = true
        }
        if !hit { lines.append("ClientLastAccessSession = \(name)") }
        txt = lines.joined(separator: "\n")
        do { try txt.write(toFile: sysconfigPath, atomically: true, encoding: .utf8); return true } catch { return false }
    }

    /// 重启前把目标档写回客户端，确保它连的是断线前那一档
    private func restoreProfileBeforeLaunch() {
        var want = targetProfile
        if !pinnedProfile.isEmpty {
            want = pinnedProfile
            targetSource = "pinned"
        }
        if want.isEmpty {
            // 从没实测过（例如刚装、还没授权）：只能退而用客户端记录，并明确标注是推断
            let guess = readLastSession()
            guard !guess.isEmpty else { log("配置档：未知目标，按客户端自己记忆连"); return }
            want = guess
            targetSource = "inferred"
            log("配置档：尚未实测过档位，按客户端记录推断 = \(guess)（未写回，避免污染）")
            return
        }
        if targetSource == "pinned" { log("配置档：按锁定档 \(want) 处理") }
        let cur = readLastSession()
        if cur != want {
            let ok = setLastSession(want)
            log("配置档：写回 \(want)（原为 \(cur.isEmpty ? "空" : cur)，\(ok ? "成功" : "失败")）")
        } else {
            log("配置档：已是 \(want)，无需写回")
        }
    }

    private func guiRunning() -> Bool {
        let (_, out) = Shell.sh("pgrep -x UniVPN", timeout: 6)
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func routeGet(_ host: String) -> (ifname: String, gw: String) {
        let (_, out) = Shell.run("/sbin/route", ["-n", "get", host], timeout: 8)
        var i = "", g = ""
        for raw in out.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("interface:") { i = l.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("gateway:")   { g = l.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return (i, g)
    }

    private func staleRouteScan() -> [String] {
        let live = Set(tunnels().map { $0.name })
        let (_, out) = Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"], timeout: 12)
        var bad: [String] = []
        for raw in out.split(separator: "\n") {
            let t = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard t.count >= 4 else { continue }
            let dst = String(t[0])
            let ifc = String(t[t.count - 1])
            guard ifc.hasPrefix("utun") else { continue }
            if !live.contains(ifc) { bad.append("\(dst)->\(ifc)") }
        }
        return bad
    }

    private func tcpReachable(_ host: String, _ port: Int, timeoutSec: Int = 3) -> Bool {
        let (rc, _) = Shell.sh("nc -z -G \(timeoutSec) -w \(timeoutSec) \(host) \(port)", timeout: Double(timeoutSec + 3))
        return rc == 0
    }

    private func clientUI() -> (windows: Int, texts: String, buttons: String) {
        let s = """
        tell application "System Events"
            if not (exists process "UniVPN") then return "NOPROC"
            tell process "UniVPN"
                set wc to count of windows
                set t to ""
                set b to ""
                repeat with i from 1 to wc
                    try
                        set t to t & "|" & (value of every static text of window i as text)
                    end try
                    try
                        set b to b & "|" & (name of every button of window i as text)
                    end try
                end repeat
                return (wc as text) & "§" & t & "§" & b
            end tell
        end tell
        """
        let raw = Shell.osa(s, timeout: 20)
        if raw == "NOPROC" { return (0, "", "") }
        if raw.contains("不允许辅助访问") || raw.contains("not allowed assistive") || raw.contains("-25211") {
            if Date().timeIntervalSince(lastAuthWarn) > 600 {
                lastAuthWarn = Date()
                log("⚠️ 缺少自动化权限：系统设置 → 隐私与安全性 → 自动化，勾选 UniGuard 控制 System Events，否则无法点按钮/读弹窗")
            }
            // 探测阶段就发现没权限：后续直接跳过 AppleScript，避免每轮白等 20s
            if !axBlocked {
                axBlocked = true
                axRetryAt = Date().addingTimeInterval(300)
                log("探测阶段确认无自动化权限，暂停调用 AppleScript（5 分钟后重试）")
            }
            return (0, "", "")
        }
        let parts = raw.components(separatedBy: "§")
        let wc = Int(parts.first ?? "0") ?? 0
        let texts = parts.count > 1 ? parts[1] : ""
        let btns  = parts.count > 2 ? parts[2] : ""
        return (wc, texts, btns)
    }

    func probe() -> Snapshot {
        var s = Snapshot()
        s.gateway = gateway
        s.engineAlive = engineAlive()

        let ifs = tunnels()
        if let hit = ifs.first(where: { $0.ip.hasPrefix(vipPrefix) }) {
            s.tunName = hit.name
            s.vip = hit.ip
        }

        let (gif, _) = routeGet(gateway)
        s.gatewayIf = gif
        s.staleRoutes = staleRouteScan()

        let ui = axBlocked ? (windows: 0, texts: "", buttons: "") : clientUI()
        s.dialogText = ui.texts
        // 从 AX 文字里取「VPN名称：」后面那一项
        let toks = ui.texts
            .components(separatedBy: CharacterSet(charactersIn: "|,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let idx = toks.firstIndex(of: "VPN名称："), idx + 1 < toks.count {
            s.activeProfile = toks[idx + 1]
        }
        s.targetProfile = targetProfile
        s.targetSource = pinnedProfile.isEmpty ? targetSource : "pinned"
        let badDialog = ["超时", "重新启动客户端", "已退出"].first { ui.texts.contains($0) } != nil

        if !s.engineAlive {
            s.fault = badDialog ? .dialogStuck : .engineDead
        } else if !s.vip.isEmpty {
            s.gatewayReachable = tcpReachable(gateway, 1024, timeoutSec: 3)
            if badDialog { s.fault = .dialogStuck }
            else if !s.gatewayReachable { s.fault = .tunnelSilent }
            else { s.fault = .ok }
        } else if !s.staleRoutes.isEmpty {
            s.fault = .staleRoute
        } else if badDialog {
            s.fault = .dialogStuck
        } else {
            s.fault = .dialTimeout
        }
        s.attempt = streak
        s.lastAction = lastActionText
        return s
    }

    // MARK: 动作

    private func act(_ d: String) { lastActionText = d; log("动作：\(d)") }

    private func launchClient() {
        act("启动客户端")
        Shell.run("/usr/bin/open", ["-a", "UniVPN"], timeout: 10)
    }

    private func clickConnect() -> String {
        if axBlocked { return "blocked" }
        let s = """
        tell application "System Events"
            if not (exists process "UniVPN") then return "noproc"
            tell process "UniVPN"
                if (count of windows) is 0 then return "nowin"
                repeat with i from 1 to (count of windows)
                    set btns to name of every button of window i
                    if btns contains "断开连接" then return "connected"
                    if btns contains "连接" then
                        click button "连接" of window i
                        return "clicked"
                    end if
                end repeat
                return "nobtn"
            end tell
        end tell
        """
        let out = Shell.osa(s)
        if out.contains("不允许辅助访问") || out.contains("execution error") || out.contains("-25211") {
            if !axBlocked {
                axBlocked = true
                axRetryAt = Date().addingTimeInterval(300)
                log("点按钮被系统拒绝（缺自动化权限）→ 改为重启客户端拉起（5 分钟后重试授权）")
            }
        } else if out == "clicked" || out == "connected" {
            axBlocked = false
        }
        return out
    }

    private func dismissDialogs() -> String {
        let s = """
        tell application "System Events"
            if not (exists process "UniVPN") then return "noproc"
            tell process "UniVPN"
                set n to 0
                repeat with i from 1 to (count of windows)
                    try
                        set btns to name of every button of window i
                        if btns contains "确定" then
                            click button "确定" of window i
                            set n to n + 1
                        end if
                    end try
                end repeat
                return (n as text)
            end tell
        end tell
        """
        return Shell.osa(s)
    }

    /// 二级：只杀 GUI，引擎随之退出，然后重开
    func softRestart(_ reason: String) {
        act("重启客户端（\(reason)）")
        _ = Shell.sh("killall -9 UniVPN 2>/dev/null; sleep 2", timeout: 12)
        _ = requestRouteFixAndWait("重启前清理", wait: 8)
        restoreProfileBeforeLaunch()
        launchClient()
        usleep(5_000_000)
        if axBlocked {
            log("无自动化权限，等客户端自动登录")
        } else {
            _ = clickConnect()
        }
        lastRestart = Date()
        softRestarts += 1
    }

    /// 三级·终极兜底：完全退出 UniVPN（含引擎与提升服务）、清残留路由、再重新启动
    func fullRestart(_ reason: String) {
        act("终极兜底：完全退出并重启（\(reason)）")
        // ① 先走优雅退出
        _ = Shell.osa("tell application \"UniVPN\" to quit", timeout: 10)
        usleep(2_500_000)
        // ② 三个进程一个不留
        _ = Shell.sh("killall -9 UniVPN UniVPNCS UniVPNPromoteService 2>/dev/null", timeout: 12)
        // ③ 等它们真的消失
        for _ in 0..<14 {
            if !guiRunning() && !engineAlive() { break }
            usleep(500_000)
        }
        // ④ 清残留路由，并等到真正清完再启动
        _ = requestRouteFixAndWait("兜底重启前清理", wait: 10)
        // ⑤ 把断线前的配置档写回去，再重新启动
        restoreProfileBeforeLaunch()
        launchClient()
        usleep(8_000_000)
        if axBlocked {
            log("无自动化权限，等客户端自动登录")
        } else {
            let r = clickConnect()
            log("完全重启后点击结果：\(r)")
        }
        lastRestart = Date()
        lastFullRestart = Date()
        softRestarts = 0
        fullRestarts += 1
    }

    /// 只读扫描：是否存在指向已消失 utun 的路由
    func deadUtunRoutes() -> [String] {
        let live = Set(
            Shell.sh("/sbin/ifconfig | awk '/^utun[0-9]+: flags/{print $1}' | tr -d ':'", timeout: 8).1
                .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        )
        var out: [String] = []
        let rows = Shell.sh("/usr/sbin/netstat -rn -f inet", timeout: 10).1.split(separator: "\n")
        for row in rows.dropFirst() {
            let cols = row.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let dst = cols.first, let ifc = cols.last, ifc.hasPrefix("utun") else { continue }
            if !live.contains(ifc) { out.append("\(dst) -> \(ifc)") }
        }
        return out
    }

    /// 请求 root 修复器清理，并等到真的清干净（最多等 10 秒）
    @discardableResult
    func requestRouteFixAndWait(_ reason: String, wait: TimeInterval = 10) -> Bool {
        lastRouteFixReq = Date()
        let target = gateway.isEmpty ? "" : gateway
        // 触发文件内容 = 目标网关，root 端按它优先清理
        try? target.write(toFile: "/tmp/uniguard.routefix.trigger", atomically: true, encoding: .utf8)
        log("请求清理残留存路由（目标网关 \(target.isEmpty ? "未知" : target)）：\(reason)")

        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            usleep(700_000)
            if deadUtunRoutes().isEmpty {
                log("残留路由已清空")
                return true
            }
        }
        let left = deadUtunRoutes()
        log("残留路由仍存在：\(left.joined(separator: ", "))")
        return false
    }

    private func requestRouteFix() {
        if Date().timeIntervalSince(lastRouteFixReq) < 5 { return }
        lastRouteFixReq = Date()
        act("请求 root 路由修复器（\(snap.staleRoutes.count) 条残留）")
        try? Data().write(to: URL(fileURLWithPath: "/tmp/uniguard.routefix.trigger"))
    }

    // MARK: 主循环

    func tick(force: Bool = false) {
        if paused && !force { return }
        let now = Date()
        if now < cooldownUntil && !force {
            snap.note = "冷却中 \(Int(cooldownUntil.timeIntervalSince(now)))s"
            onChange?(snap)
            return
        }

        // 外部强制触发终极兜底（便于无人值守脚本调用）
        if FileManager.default.fileExists(atPath: "/tmp/uniguard.fullrestart.trigger") {
            try? FileManager.default.removeItem(atPath: "/tmp/uniguard.fullrestart.trigger")
            fullRestart("外部触发")
            return
        }

        if axBlocked && Date() >= axRetryAt { axBlocked = false; log("重试自动化权限检测") }

        // 网关跟随「断线前档位」动态更新，避免用错档的网关做判断
        let wantGW = resolveGateway()
        if !wantGW.isEmpty && wantGW != gateway {
            log("网关更新：\(gateway.isEmpty ? "未知" : gateway) -> \(wantGW)（跟随 \(targetProfile)）")
            gateway = wantGW
        }

        var s = probe()

        switch s.fault {
        case .ok:
            streak = 0
            if !s.activeProfile.isEmpty {
                let seen = s.activeProfile + ".ini"
                if activeProfile != s.activeProfile || targetProfile != seen {
                    activeProfile = s.activeProfile
                    if pinnedProfile.isEmpty {
                        targetProfile = seen
                        targetSource = "measured"
                        persistProfile(seen)
                        let gw = resolveGateway()
                        if !gw.isEmpty { gateway = gw }
                        log("配置档：实测当前档 = \(s.activeProfile)，已记为断线前档位")
                    }
                }
            }
            softRestarts = 0
            let pname = !s.activeProfile.isEmpty ? s.activeProfile
                      : (targetProfile.isEmpty ? "档未知" : targetProfile.replacingOccurrences(of: ".ini", with: ""))
            s.note = "隧道正常（\(pname)）"

        case .dialogStuck:
            if Date().timeIntervalSince(lastDialogDismiss) < 30 {
                s.note = "弹窗刚处理，等待恢复"
            } else {
                let n = dismissDialogs()
                lastDialogDismiss = Date()
                act("点掉弹窗 \(n) 个")
                if s.dialogText.contains("超时") || s.dialogText.contains("重新启动客户端") {
                    softRestart("弹窗：超时/引擎退出")
                } else {
                    _ = clickConnect()
                }
                cooldownUntil = Date().addingTimeInterval(25)
                s.note = "已处理弹窗"
            }

        case .staleRoute:
            requestRouteFix()
            cooldownUntil = Date().addingTimeInterval(20)
            s.note = "已请求清残留路由"

        case .engineDead:
            launchClient()
            sleep(4)
            s = probe()
            if s.vip.isEmpty { _ = clickConnect() }
            cooldownUntil = Date().addingTimeInterval(20)
            s.note = "已拉起客户端"

        case .dialTimeout:
            streak += 1
            if streak >= 2 && Date().timeIntervalSince(lastRouteFixReq) > 90 {
                _ = requestRouteFixAndWait("连不上第 \(streak) 次", wait: 8)
            }
            if axBlocked {
                // 点不动按钮：客户端重启后会自动登录，直接走这条路
                if Date().timeIntervalSince(lastRestart) > 30 {
                    softRestart("无自动化权限，重启客户端拉起")
                    cooldownUntil = Date().addingTimeInterval(40)
                    s.note = "已重启客户端（无权限点按钮，等自动登录）"
                } else {
                    s.note = "等客户端自动登录"
                    cooldownUntil = Date().addingTimeInterval(15)
                }
            } else {
            let r = clickConnect()
            if r == "connected" {
                s.note = "客户端已恢复连接"
                streak = 0
                cooldownUntil = Date().addingTimeInterval(15)
            } else {
                let backoff = min(pow(2.0, Double(streak - 1)) * interval, 240)
                cooldownUntil = Date().addingTimeInterval(backoff)
                s.note = "未成功，\(Int(backoff))s 后重试"
                if streak >= 6 && Date().timeIntervalSince(lastFullRestart) > 300 {
                    fullRestart("连续 \(streak) 次连不上")
                    streak = 0
                    cooldownUntil = Date().addingTimeInterval(60)
                } else if streak >= 3 && Date().timeIntervalSince(lastRestart) > 90 {
                    if softRestarts >= 2 {
                        fullRestart("连续重启无效")
                        streak = 0
                        cooldownUntil = Date().addingTimeInterval(60)
                    } else {
                        softRestart("连续 \(streak) 次连不上")
                        streak = 0
                        cooldownUntil = Date().addingTimeInterval(45)
                    }
                }
            }
            }

        case .tunnelSilent:
            streak += 1
            if Date().timeIntervalSince(lastRestart) > 120 {
                fullRestart("隧道不通")
                streak = 0
                cooldownUntil = Date().addingTimeInterval(40)
                s.note = "已重建隧道"
            } else {
                s.note = "隧道异常，观察中"
            }
        }

        // 记录状态变迁
        if lastFault != s.fault {
            if lastFault == .ok { downCount += 1 }
            if s.fault == .ok { upCount += 1; okSince = Date() }
            if s.fault != .ok { okSince = nil }
            history.append((Date(), s.fault))
            if history.count > 200 { history.removeFirst(history.count - 200) }
            log("状态变化：\(lastFault?.rawValue ?? "启动") -> \(s.fault.rawValue)")
            lastFault = s.fault
        }

        snap = s
        onChange?(s)
    }

    /// 过去 24h 在线时长占比（依据本次进程内的状态变迁估算）
    func statsText() -> String {
        let up = upCount, down = downCount
        return "重连 \(up) 次 · 断开 \(down) 次"
    }

    func uptimeText() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if let since = okSince {
            let d = Int(Date().timeIntervalSince(since))
            return "已连 \(d/3600)h\((d%3600)/60)m（自 \(f.string(from: since))）"
        }
        let d = Int(Date().timeIntervalSince(startedAt))
        return "守护运行 \(d/3600)h\((d%3600)/60)m"
    }

    func historyLines(_ n: Int) -> [String] {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        return history.suffix(n).map { "\(f.string(from: $0.0))  \($0.1.rawValue)" }
    }

    func startLoop() {
        log("守护启动 interval=\(Int(interval))s gateway=\(gateway)")
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "uniguard.loop"))
        t.schedule(deadline: .now() + 3, repeating: interval)
        t.setEventHandler { self.tick() }
        t.resume()
        self.timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                self.log("系统唤醒，立即探测")
                self.cooldownUntil = .distantPast
                DispatchQueue.global().async { self.tick(force: true) }
            }
    }
    private var timer: DispatchSourceTimer?
}
