import AppKit

func readGatewayFromConfig() -> String {
    let home = NSHomeDirectory()
    let dir = "\(home)/.UniVPN/config"
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".ini") }.sorted()
    for f in files {
        let p = "\(dir)/\(f)"
        guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("GatewayAddress"), let eq = t.firstIndex(of: "=") {
                let v = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return v }
            }
        }
    }
    return ""
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var statusLine = NSMenuItem(title: "状态：启动中", action: nil, keyEquivalent: "")
    var detailLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var uptimeLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var statsLine  = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var actionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var historyItem = NSMenuItem(title: "最近状态变化", action: nil, keyEquivalent: "")
    var profileItem = NSMenuItem(title: "目标配置档", action: nil, keyEquivalent: "")
    var profileLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var pauseItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        for m in [statusLine, detailLine, uptimeLine, statsLine, actionLine, profileLine] { m.isEnabled = false; menu.addItem(m) }
        menu.addItem(.separator())

        let reconnect = NSMenuItem(title: "立即重连", action: #selector(reconnectNow), keyEquivalent: "r")
        reconnect.target = self; menu.addItem(reconnect)

        pauseItem = NSMenuItem(title: "暂停守护", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self; menu.addItem(pauseItem)

        let fix = NSMenuItem(title: "清理残留路由", action: #selector(fixRoute), keyEquivalent: "f")
        fix.target = self; menu.addItem(fix)

        let hard = NSMenuItem(title: "彻底重启客户端", action: #selector(hardRestart), keyEquivalent: "R")
        hard.target = self; menu.addItem(hard)

        menu.addItem(.separator())
        profileItem.submenu = NSMenu()
        menu.addItem(profileItem)
        historyItem.submenu = NSMenu()
        menu.addItem(historyItem)

        let openLog = NSMenuItem(title: "打开日志", action: #selector(showLog), keyEquivalent: "l")
        openLog.target = self; menu.addItem(openLog)
        let quit = NSMenuItem(title: "退出守护", action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        item.menu = menu
        item.button?.imagePosition = .imageLeft

        let g = Guard.shared
        g.gateway = readGatewayFromConfig()
        g.onChange = { [weak self] s in DispatchQueue.main.async { self?.render(s) } }
        g.startLoop()
        render(g.probe())
    }

    func render(_ s: Snapshot) {
        let name: String
        switch s.fault {
        case .ok:           name = "lock.shield.fill"
        case .dialTimeout:  name = "shield.lefthalf.filled"
        case .engineDead:   name = "shield.slash"
        case .staleRoute:   name = "exclamationmark.shield"
        case .dialogStuck:  name = "bell.badge"
        case .tunnelSilent: name = "exclamationmark.triangle"
        }
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: s.fault.rawValue) {
            img.isTemplate = true
            item.button?.image = img
        }

        // 菜单栏文字：一眼看状态
        let g = Guard.shared
        let short: String
        switch s.fault {
        case .ok:
            if let t = g.history.last, t.1 == .ok {
                let sec = Int(Date().timeIntervalSince(t.0))
                short = String(format: "在线 %dh%02dm", sec / 3600, (sec % 3600) / 60)
            } else { short = "在线" }
        case .engineDead:   short = "引擎停"
        case .dialTimeout:  short = "重连中"
        case .staleRoute:   short = "残留路由"
        case .dialogStuck:  short = "弹窗阻塞"
        case .tunnelSilent: short = "隧道异常"
        }
        item.button?.title = " " + short
        item.button?.toolTip = "\(s.fault.rawValue)｜\(s.vip.isEmpty ? "无隧道" : s.vip)"

        statusLine.title = "状态：\(s.fault.rawValue)\(g.paused ? "（守护暂停）" : "")"
        var d = ""
        if !s.vip.isEmpty { d += "隧道 \(s.tunName) \(s.vip)　" }
        d += "引擎\(s.engineAlive ? "在" : "停")　网关\(s.gatewayReachable ? "通" : "不通")"
        detailLine.title = d
        uptimeLine.title = g.uptimeText()
        statsLine.title = g.statsText() + (s.staleRoutes.isEmpty ? "" : "　残留 \(s.staleRoutes.count)")
        actionLine.title = s.note.isEmpty ? "上次动作：\(s.lastAction)" : "\(s.note)　[\(s.lastAction)]"

        let g2 = Guard.shared
        let pin = g2.pinnedProfile
        profileLine.title = "断线前档位：\(s.activeProfile.isEmpty ? g2.targetProfile : s.activeProfile)" + (pin.isEmpty ? "" : "　（锁定 \(pin)）")

        if let sub = profileItem.submenu {
            sub.removeAllItems()
            let auto = NSMenuItem(title: "跟随断线前档位（自动）", action: #selector(pinProfile(_:)), keyEquivalent: "")
            auto.target = self; auto.representedObject = ""
            auto.state = pin.isEmpty ? .on : .off
            sub.addItem(auto)
            sub.addItem(.separator())
            for f in g2.availableProfiles() {
                let mi = NSMenuItem(title: f.replacingOccurrences(of: ".ini", with: ""), action: #selector(pinProfile(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = f
                mi.state = (pin == f) ? .on : .off
                sub.addItem(mi)
            }
        }

        // 历史子菜单
        if let sub = historyItem.submenu {
            sub.removeAllItems()
            let lines = g.historyLines(12)
            if lines.isEmpty {
                let empty = NSMenuItem(title: "暂无变化记录", action: nil, keyEquivalent: ""); empty.isEnabled = false
                sub.addItem(empty)
            } else {
                for l in lines.reversed() {
                    let mi = NSMenuItem(title: l, action: nil, keyEquivalent: ""); mi.isEnabled = false
                    sub.addItem(mi)
                }
            }
        }
    }

    @objc func reconnectNow() {
        Guard.shared.cooldownUntil = .distantPast
        DispatchQueue.global().async { Guard.shared.tick(force: true) }
    }

    @objc func pinProfile(_ sender: NSMenuItem) {
        let v = (sender.representedObject as? String) ?? ""
        Guard.shared.pinnedProfile = v
        Guard.shared.log("配置档：\(v.isEmpty ? "改为跟随断线前档位" : "锁定 \(v)")")
        render(Guard.shared.probe())
    }

    @objc func hardRestart() {
        DispatchQueue.global().async {
            let before = Guard.shared.fullRestarts
            Guard.shared.fullRestart("手动")
            DispatchQueue.main.async { self.render(Guard.shared.probe()); _ = before }
        }
    }

    @objc func fixRoute() {
        try? Data().write(to: URL(fileURLWithPath: "/tmp/uniguard.routefix.trigger"))
        Guard.shared.log("手动请求路由修复")
    }

    @objc func togglePause() {
        Guard.shared.paused.toggle()
        pauseItem.title = Guard.shared.paused ? "恢复守护" : "暂停守护"
        render(Guard.shared.probe())
    }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: Guard.shared.logPath)) }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
