import Foundation

/// One process as seen at sampling time.
public struct ProcessSample: Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    /// Short process name from the kernel (`pbi_name` / `pbi_comm`).
    public var name: String
    /// Executable path. Empty when the kernel refuses to tell us.
    public var path: String
    /// argv. Empty for processes owned by other users.
    public var arguments: [String]
    /// Working directory, when readable.
    public var cwd: String?
    public var startTime: Date
    /// Physical footprint in bytes: the "Memory" column in Activity Monitor.
    /// Unlike RSS it includes compressed and swapped-out pages.
    public var footprint: UInt64

    public init(
        pid: Int32, ppid: Int32, uid: UInt32, name: String, path: String = "",
        arguments: [String] = [], cwd: String? = nil, startTime: Date, footprint: UInt64
    ) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.path = path
        self.arguments = arguments
        self.cwd = cwd
        self.startTime = startTime
        self.footprint = footprint
    }

    /// Stable across samples. A bare pid is not, because macOS reuses pids.
    public var identity: String {
        "pid:\(pid)@\(Int64((startTime.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Chrome re-execs from a temporary code-sign clone, so fall back to argv[0]
    /// when the executable path itself isn't inside an app.
    public var appBundlePath: String? {
        if let bundle = Grouper.outermostAppBundle(in: path) { return bundle }
        guard let arg0 = arguments.first, arg0.hasPrefix("/") else { return nil }
        return Grouper.outermostAppBundle(in: arg0)
    }

    public var executableName: String {
        path.isEmpty ? name : (path as NSString).lastPathComponent
    }
}

public enum PressureLevel: Int, Sendable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    public static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whole-machine memory, split the way Activity Monitor splits it.
public struct SystemMemory: Hashable, Sendable {
    public var physical: UInt64
    public var appMemory: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: PressureLevel

    public init(
        physical: UInt64, appMemory: UInt64, wired: UInt64, compressed: UInt64,
        cached: UInt64, swapUsed: UInt64, swapTotal: UInt64, pressure: PressureLevel
    ) {
        self.physical = physical
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.pressure = pressure
    }

    public var used: UInt64 { appMemory + wired + compressed }

    public var free: UInt64 {
        let taken = used + cached
        return physical > taken ? physical - taken : 0
    }
}

/// What the user thinks of as one program: every process inside one `.app`
/// bundle (Chrome and its helpers), or a single command-line process.
public struct ProgramGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String?
    public var bundlePath: String?
    public var processes: [ProcessSample]
    public var footprint: UInt64
    /// When the program started: for an app, its oldest process (the launch).
    public var startTime: Date

    public init(id: String, name: String, detail: String?, bundlePath: String?, processes: [ProcessSample]) {
        self.id = id
        self.name = name
        self.detail = detail
        self.bundlePath = bundlePath
        self.processes = processes
        self.footprint = processes.reduce(0) { $0 + $1.footprint }
        self.startTime = processes.map(\.startTime).min() ?? .distantPast
    }

    public var isApp: Bool { bundlePath != nil }
}

public struct Snapshot: Sendable {
    public var date: Date
    public var system: SystemMemory
    public var processes: [ProcessSample]
    /// Sorted by footprint, largest first.
    public var groups: [ProgramGroup]
    public var currentUID: UInt32

    public init(date: Date, system: SystemMemory, processes: [ProcessSample], currentUID: UInt32) {
        self.date = date
        self.system = system
        self.processes = processes
        self.groups = Grouper.groups(from: processes)
        self.currentUID = currentUID
    }
}
