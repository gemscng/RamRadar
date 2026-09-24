import Foundation
import RamRadarCore

/// Made-up processes for screenshots and UI work, so nobody's real paths end up in the README.
enum DemoData {
    private static let now = Date()
    private static let gb: Double = 1_073_741_824

    static func snapshot() -> Snapshot {
        let uid = getuid()
        let home = NSHomeDirectory()
        var processes: [ProcessSample] = []
        var nextPID: Int32 = 400

        @discardableResult
        func add(
            _ name: String, path: String, args: [String] = [], cwd: String? = nil,
            ppid: Int32 = 1, hours: Double, gigabytes: Double, uid owner: UInt32? = nil
        ) -> Int32 {
            nextPID += 7
            processes.append(ProcessSample(
                pid: nextPID, ppid: ppid, uid: owner ?? uid, name: name, path: path, arguments: args,
                cwd: cwd, startTime: now.addingTimeInterval(-hours * 3600), footprint: UInt64(gigabytes * gb)
            ))
            return nextPID
        }

        let chromePath = "/Applications/Google Chrome.app"
        let chrome = add("Google Chrome", path: "\(chromePath)/Contents/MacOS/Google Chrome", args: ["\(chromePath)/Contents/MacOS/Google Chrome"], hours: 30, gigabytes: 0.9)
        let helper = "\(chromePath)/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        for i in 0..<11 {
            add("Google Chrome Helper (Renderer)", path: helper, args: [helper, "--type=renderer"],
                ppid: chrome, hours: 20 - Double(i), gigabytes: [0.62, 0.41, 0.33, 0.28][i % 4])
        }
        add("Google Chrome Helper (Renderer)", path: helper, args: [helper, "--type=renderer", "--extension-process"], ppid: chrome, hours: 30, gigabytes: 0.21)
        add("Google Chrome Helper (GPU)", path: helper, args: [helper, "--type=gpu-process"], ppid: chrome, hours: 30, gigabytes: 0.55)
        add("Google Chrome Helper", path: helper, args: [helper, "--type=utility", "--utility-sub-type=network.mojom.NetworkService"], ppid: chrome, hours: 30, gigabytes: 0.12)
        let xcode = add("Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", hours: 6, gigabytes: 2.3)
        add("SourceKitService", path: "/Applications/Xcode.app/Contents/SharedFrameworks/SourceKit.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService", ppid: xcode, hours: 6, gigabytes: 0.9)
        let slack = add("Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack", hours: 50, gigabytes: 0.4)
        add("Slack Helper (Renderer)", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)", ppid: slack, hours: 50, gigabytes: 0.8)
        add("Figma", path: "/Applications/Figma.app/Contents/MacOS/Figma", hours: 3, gigabytes: 1.1)
        add("Music", path: "/System/Applications/Music.app/Contents/MacOS/Music", hours: 5, gigabytes: 0.35)
        add("WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", hours: 80, gigabytes: 1.6, uid: 88)
        let terminal = add("Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", hours: 30, gigabytes: 0.3)
        let shell = add("zsh", path: "/bin/zsh", args: ["-zsh"], ppid: terminal, hours: 30, gigabytes: 0.01)
        add("postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres", args: ["/opt/homebrew/opt/postgresql@16/bin/postgres", "-D", "/opt/homebrew/var/postgresql@16"], cwd: "/opt/homebrew/var/postgresql@16", hours: 80, gigabytes: 0.2)
        add("vite", path: "/opt/homebrew/bin/node", args: ["node", "\(home)/code/landing/node_modules/.bin/vite", "--port", "5173"], cwd: "\(home)/code/landing", ppid: shell, hours: 2, gigabytes: 0.7)

        // Left behind by a closed terminal / agent session.
        let npm = add("node", path: "/opt/homebrew/bin/node", args: ["npm exec next dev -p 3000"], cwd: "\(home)/code/shop-web", hours: 26, gigabytes: 0.08)
        let nextDev = add("node", path: "/opt/homebrew/bin/node", args: ["node", "\(home)/code/shop-web/node_modules/.bin/next", "dev", "-p", "3000"], cwd: "\(home)/code/shop-web", ppid: npm, hours: 26, gigabytes: 0.2)
        add("node", path: "/opt/homebrew/bin/node", args: ["next-server (v16.3.4)"], cwd: "\(home)/code/shop-web", ppid: nextDev, hours: 26, gigabytes: 7.1)
        add("idevicesyslog", path: "/opt/homebrew/bin/idevicesyslog", args: ["idevicesyslog", "-u", "00008150-001A2B3C4D5E6F70"], hours: 27, gigabytes: 5.6)
        add("Python", path: "/opt/homebrew/Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server", "8000"], cwd: "\(home)/code/landing/dist", hours: 230, gigabytes: 0.03)

        return Snapshot(date: now, system: system(), processes: processes, currentUID: uid)
    }

    static func tabs() -> [BrowserTabs.Window] {
        [
            .init(number: 1, tabs: [
                .init(title: "Pull requests · acme/shop-web", url: "https://github.com/acme/shop-web/pulls"),
                .init(title: "Build failed: shop-web #812", url: "https://ci.example.com/shop-web/812"),
                .init(title: "Array.prototype.toSorted() - JavaScript | MDN", url: "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array/toSorted"),
                .init(title: "Inbox (3)", url: "https://mail.example.com/inbox"),
            ]),
            .init(number: 2, tabs: [
                .init(title: "Quarterly planning", url: "https://docs.example.com/d/planning"),
                .init(title: "Lo-fi beats to code to", url: "https://www.youtube.com/watch?v=demo"),
                .init(title: "Swift Charts | Apple Developer Documentation", url: "https://developer.apple.com/documentation/charts"),
            ]),
        ]
    }

    static func baseline() -> Baseline {
        let snap = snapshot()
        var footprints = Baseline(snap).footprints
        if let syslog = snap.groups.first(where: { $0.name.hasPrefix("idevicesyslog") }) {
            footprints[syslog.id] = UInt64(2.1 * gb)
        }
        return Baseline(date: now.addingTimeInterval(-15 * 60), footprints: footprints)
    }

    static func system() -> SystemMemory {
        SystemMemory(
            physical: UInt64(32 * gb), appMemory: UInt64(18.2 * gb), wired: UInt64(3.4 * gb),
            compressed: UInt64(7.6 * gb), cached: UInt64(1.9 * gb),
            swapUsed: UInt64(6.3 * gb), swapTotal: UInt64(7 * gb), pressure: .warning
        )
    }
}
