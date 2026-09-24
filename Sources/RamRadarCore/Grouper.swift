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
        var apps: [String: [ProcessSample]] = [:]
        var result: [ProgramGroup] = []
        for p in processes {
            if let bundle = p.appBundlePath {
                apps[bundle, default: []].append(p)
            } else {
                result.append(ProgramGroup(
                    id: p.identity, name: describe(p), detail: displayDirectory(p.cwd), bundlePath: nil, processes: [p]
                ))
            }
        }
        for (bundle, members) in apps {
            let detail = members.count > 1 ? "\(members.count) processes" : nil
            result.append(ProgramGroup(
                id: "app:" + bundle, name: appName(bundlePath: bundle), detail: detail,
                bundlePath: bundle, processes: members.sorted { $0.footprint > $1.footprint }
            ))
        }
        return result.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    /// Every non-app descendant of `root`, so stopping `npm exec next dev` also
    /// stops the `next-server` it spawned.
    public static func descendants(of root: Int32, in processes: [ProcessSample]) -> [ProcessSample] {
        let children = Dictionary(grouping: processes, by: \.ppid)
        var result: [ProcessSample] = []
        var visited: Set<Int32> = [root]
        var queue: [Int32] = [root]
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where !visited.contains(child.pid) && child.appBundlePath == nil {
                visited.insert(child.pid)
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    /// Yours, not launchd, not RamRadar itself.
    public static func isStoppable(_ p: ProcessSample, currentUID: UInt32, ownPID: Int32) -> Bool {
        p.uid == currentUID && p.pid > 1 && p.pid != ownPID
    }

    public static func isStoppable(_ group: ProgramGroup, currentUID: UInt32, ownPID: Int32) -> Bool {
        guard !group.processes.isEmpty,
              group.processes.allSatisfy({ isStoppable($0, currentUID: currentUID, ownPID: ownPID) })
        else { return false }
        if let bundle = group.bundlePath { return !protectedNames.contains(appName(bundlePath: bundle)) }
        return !protectedNames.contains(group.processes[0].executableName)
    }
}
