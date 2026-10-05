import Foundation

public enum FindingKind: String, Sendable, CaseIterable {
    /// macOS reports memory pressure, or a lot of memory has gone to swap.
    case pressure
    /// A dev tool, stream, headless browser or simulator nobody is using any more.
    case leftover
    /// Grew fast since the previous check.
    case growing
    /// Kept growing for hours or days since RamRadar first saw it.
    case growingSlowly
    /// Holds a large share of physical memory.
    case heavy
}

/// One card in the "Suggested to stop" list.
public struct Finding: Identifiable, Hashable, Sendable {
    public struct Reason: Hashable, Sendable {
        public var kind: FindingKind
        public var text: String
    }

    public static let systemID = "system"

    public var id: String
    public var title: String
    public var subtitle: String?
    /// The app the card is about, for its icon.
    public var bundlePath: String?
    /// Stop quits that app normally. False when the targets are only part of it, like one tab's process.
    public var quitsApp: Bool
    public var reasons: [Reason]
    public var bytes: UInt64
    /// What the Stop button terminates. Empty for the system-wide notice.
    public var targets: [ProcessSample]

    public var isSystem: Bool { id == Finding.systemID }
    public var kinds: [FindingKind] { reasons.map(\.kind) }

    public static func ignoreKey(kind: FindingKind, id: String) -> String { "\(kind.rawValue):\(id)" }
    public var ignoreKeys: [String] { reasons.map { Finding.ignoreKey(kind: $0.kind, id: id) } }
}

public struct SuggestionRules: Sendable {
    /// A detached dev process must be at least this old before it counts as left over.
    public var leftoverMinAge: TimeInterval = 3_600
    /// "Heavy" = at least this share of physical memory...
    public var heavyFraction: Double = 0.20
    /// ...capped at this many bytes, so big Macs still get warned.
    public var heavyCap: UInt64 = 8 << 30
    /// One browser tab's process using at least this share of physical memory...
    public var heavyTabFraction: Double = 0.10
    /// ...capped at this many bytes.
    public var heavyTabCap: UInt64 = 2 << 30
    /// "Growing" = gained at least this much...
    public var growthBytes: UInt64 = 1 << 30
    /// ...and at least this multiple of the earlier size.
    public var growthRatio: Double = 1.5
    /// "Growing slowly" = a command-line program that gained at least this much...
    public var slowGrowthBytes: UInt64 = 512 << 20
    /// ...and at least this multiple of its size when RamRadar first saw it...
    public var slowGrowthRatio: Double = 3
    /// ...at least this long ago.
    public var slowGrowthMinSpan: TimeInterval = 6 * 3_600
    /// Warn about swap from this share of physical memory, even when macOS reports normal pressure.
    public var swapFraction: Double = 0.25

    public init() {}
    public static let `default` = SuggestionRules()

    public func heavyThreshold(physical: UInt64) -> UInt64 {
        min(heavyCap, UInt64(Double(physical) * heavyFraction))
    }

    public func heavyTabThreshold(physical: UInt64) -> UInt64 {
        min(heavyTabCap, UInt64(Double(physical) * heavyTabFraction))
    }
}

/// Per-group footprints from an earlier check, for the growth rule.
public struct Baseline: Sendable {
    public var date: Date
    public var footprints: [String: UInt64]

    public init(date: Date, footprints: [String: UInt64]) {
        self.date = date
        self.footprints = footprints
    }

    public init(_ snapshot: Snapshot) {
        self.init(date: snapshot.date, footprints: Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.id, $0.footprint) }))
    }
}

/// Each program's size when RamRadar first saw it, for the slow-growth rule.
/// The growth rule only looks back a few hours; this catches growth over days.
public struct FirstSeen: Sendable {
    public struct Entry: Hashable, Sendable {
        public var date: Date
        public var startTime: Date
        public var footprint: UInt64
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// Keeps the first sighting of every program still running. A relaunched app starts over.
    public mutating func record(_ snapshot: Snapshot) {
        var next: [String: Entry] = [:]
        for g in snapshot.groups {
            if let seen = entries[g.id], seen.startTime == g.startTime {
                next[g.id] = seen
            } else {
                next[g.id] = Entry(date: snapshot.date, startTime: g.startTime, footprint: g.footprint)
            }
        }
        entries = next
    }
}

public enum SuggestionEngine {
    static let systemPathPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/PrivilegedHelperTools/",
    ]

    static let devNames: Set<String> = [
        "node", "nodejs", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "tsx", "ts-node",
        "esbuild", "vite", "webpack", "ruby", "rails", "java", "gradle", "php", "idevicesyslog",
        "uvicorn", "gunicorn", "flask",
        // Language servers an editor left behind.
        "sourcekit-lsp", "gopls", "rust-analyzer", "clangd",
    ]

    /// `qemu-system-*` is the Android emulator, still running after Android Studio has quit.
    static let devPrefixes = ["python", "Python", "next-server", "next-router-worker", "qemu-system-"]

    /// Long-running developer tools: servers, watchers, log streams, language servers, emulators.
    public static func isDevCommand(_ p: ProcessSample) -> Bool {
        var names: Set<String> = [p.executableName, p.name]
        if let arg0 = p.arguments.first { names.insert((arg0 as NSString).lastPathComponent) }
        if names.contains("log") { return p.arguments.contains("stream") }
        if names.contains("tail") { return p.arguments.contains { $0 == "-f" || $0 == "-F" } }
        if names.contains(where: { name in devPrefixes.contains { name.hasPrefix($0) } }) { return true }
        return !names.isDisjoint(with: devNames)
    }

    /// A dev process or headless browser nobody is using: its parent session ended, so macOS
    /// re-parented it to launchd (pid 1), or the folder it runs in has been deleted.
    public static func isLeftover(
        _ p: ProcessSample, now: Date, currentUID: UInt32, ownPID: Int32, rules: SuggestionRules = .default
    ) -> Bool {
        guard p.uid == currentUID, p.pid != ownPID else { return false }
        guard !systemPathPrefixes.contains(where: { p.path.hasPrefix($0) }) else { return false }
        let isDev = p.appBundlePath == nil && isDevCommand(p)
        // A dev server in a removed git worktree is done with, even while the agent that started it runs on.
        if p.cwdDeleted && isDev { return true }
        guard p.ppid == 1, now.timeIntervalSince(p.startTime) >= rules.leftoverMinAge else { return false }
        // Apps the user opens also have launchd as parent; a headless or automated one was started by a script.
        return p.isAutomatedInstance || isDev
    }

    public static func findings(
        snapshot: Snapshot,
        baseline: Baseline?,
        firstSeen: FirstSeen? = nil,
        rules: SuggestionRules = .default,
        ignored: Set<String> = [],
        ownPID: Int32 = getpid()
    ) -> [Finding] {
        var byID: [String: Finding] = [:]

        func add(
            id: String, title: String, subtitle: String?, bundlePath: String?, quitsApp: Bool? = nil,
            kind: FindingKind, text: String, bytes: UInt64, targets: [ProcessSample]
        ) {
            guard !ignored.contains(Finding.ignoreKey(kind: kind, id: id)) else { return }
            if byID[id] != nil {
                byID[id]!.reasons.append(.init(kind: kind, text: text))
            } else {
                byID[id] = Finding(
                    id: id, title: title, subtitle: subtitle, bundlePath: bundlePath, quitsApp: quitsApp ?? (bundlePath != nil),
                    reasons: [.init(kind: kind, text: text)], bytes: bytes, targets: targets
                )
            }
        }

        let now = snapshot.date
        let uid = snapshot.currentUID
        let system = snapshot.system
        func age(_ p: ProcessSample) -> String { DurationFormat.string(now.timeIntervalSince(p.startTime)) }

        // A leftover's children go on its card. In a deleted folder they qualify on their own too,
        // since they inherit the folder, so only the topmost one gets a card.
        let leftovers = snapshot.processes.filter { isLeftover($0, now: now, currentUID: uid, ownPID: ownPID, rules: rules) }
        let leftoverPIDs = Set(leftovers.map(\.pid))
        let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func hasLeftoverAncestor(_ p: ProcessSample) -> Bool {
            var pid = p.ppid
            var visited: Set<Int32> = [p.pid]
            while pid > 1, visited.insert(pid).inserted {
                if leftoverPIDs.contains(pid) { return true }
                pid = byPID[pid]?.ppid ?? 0
            }
            return false
        }

        for p in leftovers where !hasLeftoverAncestor(p) {
            // A headless Chrome's helpers live in its app bundle; they go with it.
            let tree = [p] + Grouper.descendants(of: p.pid, in: snapshot.processes, includingApps: p.isAutomatedInstance)
            let cause = p.isAutomatedInstance ? "The script or agent that started it has ended"
                : p.cwdDeleted ? "The folder it runs in has been deleted"
                : "Its terminal or agent session has ended"
            var text = "\(cause) · running \(age(p))"
            if tree.count > 1 { text += " · \(tree.count - 1) child process\(tree.count == 2 ? "" : "es")" }
            // Same id and name as its program group, so its heavy / growing reasons and Details join this card.
            let bundle = p.appBundlePath
            add(
                id: bundle.map { Grouper.automatedInstanceID(bundle: $0, root: p) } ?? p.identity,
                title: bundle.map { Grouper.automatedInstanceName(bundle: $0, root: p) } ?? Grouper.describe(p),
                subtitle: Grouper.displayDirectory(p.cwd), bundlePath: bundle,
                kind: .leftover, text: text, bytes: tree.reduce(0) { $0 + $1.footprint }, targets: tree
            )
        }

        // A booted simulator with the Simulator app closed is one nobody is looking at. Xcode's
        // previews and `xcodebuild test` runs use simulators without the app, so those are left alone.
        let paths = snapshot.processes.map(\.path)
        let simulatorAppOpen = paths.contains { $0.hasSuffix("/Simulator.app/Contents/MacOS/Simulator") }
        let xcodeOpen = paths.contains { $0.hasSuffix("/Contents/MacOS/Xcode") }
        let testing = snapshot.processes.contains { $0.executableName == "xcodebuild" }
        for g in snapshot.groups where !simulatorAppOpen && !testing {
            guard let root = g.processes.first(where: \.isSimulatorRoot),
                  Grouper.isStoppable(g, currentUID: uid, ownPID: ownPID),
                  now.timeIntervalSince(root.startTime) >= rules.leftoverMinAge,
                  !(xcodeOpen && Simulators.isPreview(root)) else { continue }
            add(
                id: g.id, title: g.name, subtitle: g.detail, bundlePath: nil,
                kind: .leftover, text: "Running with the Simulator app closed · booted \(age(root)) ago",
                // launchd_sim first: once it exits, the simulated system exits with it.
                bytes: g.footprint, targets: [root] + g.processes.filter { $0.pid != root.pid }
            )
        }

        // A dev server under a leftover `npm exec` belongs on the leftover's card, not a second one.
        var leftoverOwner: [Int32: String] = [:]
        for f in byID.values { for t in f.targets { leftoverOwner[t.pid] = f.id } }

        let heavyLimit = rules.heavyThreshold(physical: system.physical)
        let tabLimit = rules.heavyTabThreshold(physical: system.physical)
        for g in snapshot.groups where Grouper.isStoppable(g, currentUID: uid, ownPID: ownPID) {
            let cardID = g.isApp ? g.id : (leftoverOwner[g.processes[0].pid] ?? g.id)
            if g.footprint >= heavyLimit, system.physical > 0 {
                let pct = Int((Double(g.footprint) / Double(system.physical) * 100).rounded())
                add(
                    id: cardID, title: g.name, subtitle: g.detail, bundlePath: g.bundlePath,
                    kind: .heavy, text: "Using \(pct)% of this Mac's memory",
                    bytes: g.footprint, targets: g.processes
                )
            }
            if let baseline, let before = baseline.footprints[g.id],
               g.footprint >= before + rules.growthBytes,
               Double(g.footprint) >= Double(before) * rules.growthRatio {
                let span = DurationFormat.string(now.timeIntervalSince(baseline.date))
                add(
                    id: cardID, title: g.name, subtitle: g.detail, bundlePath: g.bundlePath,
                    kind: .growing, text: "Grew \(ByteFormat.string(g.footprint - before)) in the last \(span)",
                    bytes: g.footprint, targets: g.processes
                )
            }
            // Apps grow as they're used (more tabs, more projects). A command-line program that keeps
            // growing for hours, like a days-old agent session or dev server, is holding on to memory.
            if !g.isApp, let seen = firstSeen?.entries[g.id], seen.startTime == g.startTime,
               now.timeIntervalSince(seen.date) >= rules.slowGrowthMinSpan,
               g.footprint >= seen.footprint + rules.slowGrowthBytes,
               Double(g.footprint) >= Double(seen.footprint) * rules.slowGrowthRatio {
                let span = DurationFormat.string(now.timeIntervalSince(seen.date))
                add(
                    id: cardID, title: g.name, subtitle: g.detail, bundlePath: g.bundlePath,
                    kind: .growingSlowly,
                    text: "Grew from \(ByteFormat.string(seen.footprint)) to \(ByteFormat.string(g.footprint)) in \(span)",
                    bytes: g.footprint, targets: g.processes
                )
            }
            // One tab's process: stopping it crashes only its tabs, where quitting the browser closes them all.
            if g.isApp, system.physical > 0, BrowserTabs.appNames.contains(g.name) {
                for p in g.processes where ProcessKind.label(p) == "Renderer" && p.footprint >= tabLimit
                    && leftoverOwner[p.pid] == nil && Grouper.isStoppable(p, currentUID: uid, ownPID: ownPID) {
                    add(
                        id: p.identity, title: "\(g.name) tab", subtitle: "PID \(p.pid)", bundlePath: g.bundlePath,
                        quitsApp: false, kind: .heavy,
                        text: "One tab's process is using \(ByteFormat.string(p.footprint)) · running \(age(p)). "
                            + "Stopping it crashes only the tabs it serves; reload them to get them back.",
                        bytes: p.footprint, targets: [p]
                    )
                }
            }
        }

        var result = byID.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }

        let swap = ByteFormat.string(system.swapUsed)
        if system.pressure > .normal {
            let level = system.pressure == .critical ? "critical" : "high"
            let text = "macOS is compressing memory and has \(swap) in swap. Stopping the items below frees memory fastest."
            result.insert(Finding(
                id: Finding.systemID, title: "Memory pressure is \(level)", subtitle: nil, bundlePath: nil, quitsApp: false,
                reasons: [.init(kind: .pressure, text: text)], bytes: system.used, targets: []
            ), at: 0)
        } else if system.physical > 0, Double(system.swapUsed) >= Double(system.physical) * rules.swapFraction {
            // macOS can report normal pressure while a large swap file is in use.
            let text = "Memory pressure is normal, but macOS has moved \(swap) of memory to disk, which slows down "
                + "switching between programs. Stopping the items below frees it fastest."
            result.insert(Finding(
                id: Finding.systemID, title: "\(swap) of memory is in swap", subtitle: nil, bundlePath: nil, quitsApp: false,
                reasons: [.init(kind: .pressure, text: text)], bytes: system.swapUsed, targets: []
            ), at: 0)
        }
        return result
    }
}
