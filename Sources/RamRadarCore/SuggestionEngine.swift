import Foundation

public enum FindingKind: String, Sendable, CaseIterable {
    /// macOS itself reports memory pressure.
    case pressure
    /// A dev tool or stream whose terminal / agent session is gone (re-parented to launchd).
    case leftover
    /// Grew fast since the previous check.
    case growing
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
    public var bundlePath: String?
    public var reasons: [Reason]
    public var bytes: UInt64
    /// What the Stop button terminates. Empty for the system-wide pressure notice.
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
    /// "Growing" = gained at least this much...
    public var growthBytes: UInt64 = 1 << 30
    /// ...and at least this multiple of the earlier size.
    public var growthRatio: Double = 1.5

    public init() {}
    public static let `default` = SuggestionRules()

    public func heavyThreshold(physical: UInt64) -> UInt64 {
        min(heavyCap, UInt64(Double(physical) * heavyFraction))
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

public enum SuggestionEngine {
    static let systemPathPrefixes = [
        "/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/PrivilegedHelperTools/",
    ]

    static let devNames: Set<String> = [
        "node", "nodejs", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "tsx", "ts-node",
        "esbuild", "vite", "webpack", "ruby", "rails", "java", "gradle", "php", "idevicesyslog",
        "uvicorn", "gunicorn", "flask",
    ]

    static let devPrefixes = ["python", "Python", "next-server", "next-router-worker"]

    /// Long-running developer tools: servers, watchers, log streams.
    public static func isDevCommand(_ p: ProcessSample) -> Bool {
        var names: Set<String> = [p.executableName, p.name]
        if let arg0 = p.arguments.first { names.insert((arg0 as NSString).lastPathComponent) }
        if names.contains("log") { return p.arguments.contains("stream") }
        if names.contains("tail") { return p.arguments.contains { $0 == "-f" || $0 == "-F" } }
        if names.contains(where: { name in devPrefixes.contains { name.hasPrefix($0) } }) { return true }
        return !names.isDisjoint(with: devNames)
    }

    /// A dev process whose parent session ended: macOS re-parents it to launchd (pid 1)
    /// and it keeps running, unseen, until reboot.
    public static func isLeftover(
        _ p: ProcessSample, now: Date, currentUID: UInt32, ownPID: Int32, rules: SuggestionRules = .default
    ) -> Bool {
        guard p.ppid == 1, p.uid == currentUID, p.pid != ownPID, p.appBundlePath == nil else { return false }
        guard now.timeIntervalSince(p.startTime) >= rules.leftoverMinAge else { return false }
        guard !systemPathPrefixes.contains(where: { p.path.hasPrefix($0) }) else { return false }
        return isDevCommand(p)
    }

    public static func findings(
        snapshot: Snapshot,
        baseline: Baseline?,
        rules: SuggestionRules = .default,
        ignored: Set<String> = [],
        ownPID: Int32 = getpid()
    ) -> [Finding] {
        var byID: [String: Finding] = [:]

        func add(
            id: String, title: String, subtitle: String?, bundlePath: String?,
            kind: FindingKind, text: String, bytes: UInt64, targets: [ProcessSample]
        ) {
            guard !ignored.contains(Finding.ignoreKey(kind: kind, id: id)) else { return }
            if byID[id] != nil {
                byID[id]!.reasons.append(.init(kind: kind, text: text))
            } else {
                byID[id] = Finding(
                    id: id, title: title, subtitle: subtitle, bundlePath: bundlePath,
                    reasons: [.init(kind: kind, text: text)], bytes: bytes, targets: targets
                )
            }
        }

        let now = snapshot.date
        let uid = snapshot.currentUID
        let system = snapshot.system

        for p in snapshot.processes where isLeftover(p, now: now, currentUID: uid, ownPID: ownPID, rules: rules) {
            let tree = [p] + Grouper.descendants(of: p.pid, in: snapshot.processes)
            var text = "Its terminal or agent session has ended · running \(DurationFormat.string(now.timeIntervalSince(p.startTime)))"
            if tree.count > 1 { text += " · \(tree.count - 1) child process\(tree.count == 2 ? "" : "es")" }
            add(
                id: p.identity, title: Grouper.describe(p), subtitle: Grouper.displayDirectory(p.cwd), bundlePath: nil,
                kind: .leftover, text: text, bytes: tree.reduce(0) { $0 + $1.footprint }, targets: tree
            )
        }

        // A dev server under a leftover `npm exec` belongs on the leftover's card, not a second one.
        var leftoverOwner: [Int32: String] = [:]
        for f in byID.values { for t in f.targets { leftoverOwner[t.pid] = f.id } }

        let heavyLimit = rules.heavyThreshold(physical: system.physical)
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
        }

        var result = byID.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.id < $1.id }

        if system.pressure > .normal {
            let level = system.pressure == .critical ? "critical" : "high"
            let text = "macOS is compressing memory and has \(ByteFormat.string(system.swapUsed)) in swap. Stopping the items below frees memory fastest."
            result.insert(Finding(
                id: Finding.systemID, title: "Memory pressure is \(level)", subtitle: nil, bundlePath: nil,
                reasons: [.init(kind: .pressure, text: text)], bytes: system.used, targets: []
            ), at: 0)
        }
        return result
    }
}
