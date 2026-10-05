import Foundation

public enum Grouper {
    /// Programs RamRadar never offers to stop: quitting them logs you out,
    /// blanks the screen, or is refused by macOS anyway.
    public static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "SystemUIServer", "ControlCenter", "NotificationCenter", "RamRadar",
    ]

    /// `/Applications/Google Chrome.app/Contents/Frameworks/.../Helper.app/Contents/MacOS/x`
    /// → `/Applications/Google Chrome.app`
    /// An `.app` nested in a `.framework` (Homebrew's `Python.framework/.../Python.app`)
    /// is an implementation detail, not something the user launched.
    public static func outermostAppBundle(in path: String) -> String? {
        // Xcode's developer tools (`swift-frontend`, `sourcekit-lsp`, `xcodebuild`) are command-line
        // programs, and the apps in there (Simulator, Instruments) are apps of their own.
        if let developer = path.range(of: ".app/Contents/Developer/") {
            guard let inner = outermostAppBundle(in: String(path[developer.upperBound...])) else { return nil }
            return path[..<developer.upperBound] + inner
        }
        let prefix: Substring
        if let r = path.range(of: ".app/") {
            prefix = path[..<r.lowerBound]
        } else if path.hasSuffix(".app") {
            prefix = path.dropLast(4)
        } else {
            return nil
        }
        return prefix.contains(".framework/") ? nil : prefix + ".app"
    }

    public static func appName(bundlePath: String) -> String {
        let base = (bundlePath as NSString).lastPathComponent
        return base.hasSuffix(".app") ? String(base.dropLast(4)) : base
    }

    /// Readable one-line command: `node /long/path/proxy.mjs --port 8098` → `node proxy.mjs --port 8098`.
    /// Paths shortened to file names, long `--flag=value` noise dropped, whitespace collapsed.
    public static func describe(_ p: ProcessSample, maxLength: Int = 64) -> String {
        let args = p.arguments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = args.first else { return p.name.isEmpty ? p.executableName : p.name }
        var parts = [first.hasPrefix("/") ? (first as NSString).lastPathComponent : first]
        for arg in args.dropFirst() where !(arg.hasPrefix("--") && arg.count > 32) {
            parts.append(arg.hasPrefix("/") ? (arg as NSString).lastPathComponent : arg)
        }
        let s = parts.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return s.count > maxLength ? String(s.prefix(maxLength - 1)) + "…" : s
    }

    public static func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// A working directory worth showing: `~`-abbreviated, and nil for `/` (daemons) or unknown.
    public static func displayDirectory(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        return abbreviateHome(cwd)
    }

    public static func groups(from processes: [ProcessSample]) -> [ProgramGroup] {
        var result: [ProgramGroup] = []
        func bySize(_ ps: [ProcessSample]) -> [ProcessSample] { ps.sorted { $0.footprint > $1.footprint } }

        // A booted simulator is ~200 processes, some of them `.app`s (SpringBoard…): one program.
        var claimed: Set<Int32> = []
        for root in processes where root.isSimulatorRoot {
            let tree = [root] + descendants(of: root.pid, in: processes, includingApps: true)
            claimed.formUnion(tree.map(\.pid))
            let runtime = Simulators.runtime(tree).map { "\($0) · " } ?? ""
            result.append(ProgramGroup(
                id: "sim:" + root.identity, name: root.deviceName.map { "\($0) simulator" } ?? "Simulator",
                detail: "\(runtime)\(tree.count) processes", bundlePath: nil, processes: bySize(tree)
            ))
        }

        var apps: [String: [ProcessSample]] = [:]
        var machines: [ProcessSample] = []
        for p in processes where !claimed.contains(p.pid) {
            if p.isVirtualMachine {
                machines.append(p)
            } else if let bundle = p.appBundlePath {
                apps[bundle, default: []].append(p)
            } else {
                result.append(ProgramGroup(
                    id: p.identity, name: describe(p), detail: displayDirectory(p.cwd), bundlePath: nil, processes: [p]
                ))
            }
        }

        // A VM counts toward the app running it, whose Quit shuts the VM down cleanly.
        for vm in machines {
            let owner = VirtualMachines.owner(openFiles: vm.openFiles)
            if let bundleName = owner?.bundleName,
               let bundle = apps.keys.first(where: { ($0 as NSString).lastPathComponent == bundleName }) {
                apps[bundle]!.append(vm)
            } else {
                result.append(ProgramGroup(
                    id: vm.identity, name: owner.map { "\($0.name) virtual machine" } ?? "Virtual machine",
                    detail: nil, bundlePath: nil, processes: [vm]
                ))
            }
        }

        func appGroup(id: String, name: String, bundle: String, members: [ProcessSample], detail: String? = nil) -> ProgramGroup {
            ProgramGroup(
                id: id, name: name, detail: detail ?? (members.count > 1 ? "\(members.count) processes" : nil),
                bundlePath: bundle, processes: bySize(members)
            )
        }
        for (bundle, members) in apps {
            // A headless Chrome a script left running is its own program, so stopping it
            // never quits the Chrome the user is browsing in.
            var rest = members
            for root in members where root.isAutomatedInstance && rest.contains(root) {
                let tree = Set([root.pid] + descendants(of: root.pid, in: members, includingApps: true).map(\.pid))
                result.append(appGroup(
                    id: automatedInstanceID(bundle: bundle, root: root),
                    name: automatedInstanceName(bundle: bundle, root: root),
                    bundle: bundle, members: rest.filter { tree.contains($0.pid) },
                    detail: displayDirectory(root.cwd)
                ))
                rest.removeAll { tree.contains($0.pid) }
            }
            if !rest.isEmpty {
                result.append(appGroup(id: "app:" + bundle, name: appName(bundlePath: bundle), bundle: bundle, members: rest))
            }
        }
        return result.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    public static func automatedInstanceID(bundle: String, root: ProcessSample) -> String {
        "app:\(bundle)#\(root.identity)"
    }

    /// `Google Chrome (headless)`, or `(automated)` for a windowed Puppeteer / Playwright browser.
    public static func automatedInstanceName(bundle: String, root: ProcessSample) -> String {
        "\(appName(bundlePath: bundle)) (\(root.isHeadless ? "headless" : "automated"))"
    }

    /// Every descendant of `root`, so stopping `npm exec next dev` also stops the
    /// `next-server` it spawned. Processes inside an app are skipped unless `includingApps`.
    public static func descendants(of root: Int32, in processes: [ProcessSample], includingApps: Bool = false) -> [ProcessSample] {
        let children = Dictionary(grouping: processes, by: \.ppid)
        var result: [ProcessSample] = []
        var visited: Set<Int32> = [root]
        var queue: [Int32] = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where !visited.contains(child.pid) && (includingApps || child.appBundlePath == nil) {
                visited.insert(child.pid)
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    /// Yours, not launchd, not RamRadar itself.
    static func isOwned(_ p: ProcessSample, currentUID: UInt32, ownPID: Int32) -> Bool {
        p.uid == currentUID && p.pid > 1 && p.pid != ownPID
    }

    /// One process on its own. Not a virtual machine: a signal powers it off without
    /// shutting it down, which can corrupt its disk. Quitting the app that runs it is safe.
    public static func isStoppable(_ p: ProcessSample, currentUID: UInt32, ownPID: Int32) -> Bool {
        isOwned(p, currentUID: currentUID, ownPID: ownPID) && !p.isVirtualMachine
    }

    public static func isStoppable(_ group: ProgramGroup, currentUID: UInt32, ownPID: Int32) -> Bool {
        guard !group.processes.isEmpty,
              group.processes.allSatisfy({ isOwned($0, currentUID: currentUID, ownPID: ownPID) })
        else { return false }
        if let bundle = group.bundlePath { return !protectedNames.contains(appName(bundlePath: bundle)) }
        return isStoppable(group.processes[0], currentUID: currentUID, ownPID: ownPID)
            && !protectedNames.contains(group.processes[0].executableName)
    }
}
