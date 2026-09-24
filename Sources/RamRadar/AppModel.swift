import AppKit
import RamRadarCore
import ServiceManagement

/// Something the user can stop: a whole program, a suggestion's process tree, or one process.
struct StopTarget {
    let id: String
    let name: String
    let processes: [ProcessSample]
    /// Set for apps, which get a normal Quit instead of SIGTERM.
    let bundlePath: String?

    var verb: String { bundlePath == nil ? "Stop" : "Quit" }

    init(group: ProgramGroup) {
        (id, name, processes, bundlePath) = (group.id, group.name, group.processes, group.bundlePath)
    }

    init(finding: Finding) {
        (id, name, processes, bundlePath) = (finding.id, finding.title, finding.targets, finding.bundlePath)
    }

    /// A single process inside an app: stopped with SIGTERM, not by quitting the app.
    init(process: ProcessSample, label: String) {
        (id, name, processes, bundlePath) = (process.identity, "\(label) (PID \(String(process.pid)))", [process], nil)
    }
}

enum StopState: Equatable {
    case confirming
    case stopping
    case stillRunning(Int)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    static let intervals: [TimeInterval] = [5 * 60, 15 * 60, 30 * 60, 60 * 60]
    static let defaultInterval: TimeInterval = 60 * 60
    static let repositoryURL = URL(string: "https://github.com/gemscng/RamRadar")!

    // Latest check
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var isSampling = false

    // UI state
    @Published private(set) var stopStates: [String: StopState] = [:]
    @Published var selectedGroupID: String?
    @Published private(set) var tabLists: [String: TabListState] = [:]
    @Published var panelHeight: CGFloat = 680
    @Published private(set) var loginItemError: String?

    // Settings
    @Published var interval: TimeInterval {
        didSet {
            defaults.set(interval, forKey: Keys.interval)
            schedule()
        }
    }

    @Published private(set) var ignored: Set<String> {
        didSet { defaults.set(Array(ignored).sorted(), forKey: Keys.ignored) }
    }

    private enum Keys {
        static let interval = "checkInterval"
        static let ignored = "ignoredSuggestions"
    }

    private let defaults: UserDefaults
    private let isDemo: Bool
    private var history: [Baseline] = []
    private var baseline: Baseline?
    private var timer: Timer?

    init(defaults: UserDefaults = .standard, demo: Bool = false) {
        self.defaults = defaults
        self.isDemo = demo
        let saved = defaults.double(forKey: Keys.interval)
        self.interval = AppModel.intervals.contains(saved) ? saved : AppModel.defaultInterval
        self.ignored = Set(defaults.stringArray(forKey: Keys.ignored) ?? [])
        if demo { history = [DemoData.baseline()] }
    }

    var selectedGroup: ProgramGroup? {
        guard let id = selectedGroupID else { return nil }
        return snapshot?.groups.first { $0.id == id }
    }

    /// Every process some suggestion would stop; their rows get a red dot.
    var flaggedPIDs: Set<Int32> { Set(findings.flatMap { $0.targets.map(\.pid) }) }

    // MARK: Checking

    func start() {
        refresh()
        schedule()
    }

    /// `RAMRADAR_CHECK_SECONDS` overrides the interval, for testing the timer without waiting a full interval.
    private var effectiveInterval: TimeInterval {
        ProcessInfo.processInfo.environment["RAMRADAR_CHECK_SECONDS"].flatMap(TimeInterval.init) ?? interval
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = min(30, effectiveInterval / 10)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Samples off the main thread; a pass over ~800 processes takes a fraction of a second.
    func refresh() {
        guard !isSampling else { return }
        if isDemo {
            apply(DemoData.snapshot())
            return
        }
        isSampling = true
        Task {
            let snap = await Task.detached(priority: .utility) { Sampler.snapshot() }.value
            apply(snap)
            isSampling = false
        }
    }

    /// Synchronous variant for the command-line modes.
    func refreshNow() {
        apply(isDemo ? DemoData.snapshot() : Sampler.snapshot())
    }

    private func apply(_ snap: Snapshot) {
        // Compare against the newest check that is at least ~10 minutes old, so opening
        // the panel (which also checks) doesn't hide slow growth.
        let minAge = min(600, interval * 0.66)
        baseline = history.last { snap.date.timeIntervalSince($0.date) >= minAge }
        snapshot = snap
        recomputeFindings()
        if !isDemo {
            history.append(Baseline(snap))
            history.removeAll { snap.date.timeIntervalSince($0.date) > 3 * 3600 }
        }
        let live = Set(snap.groups.map(\.id)).union(findings.map(\.id)).union(snap.processes.map(\.identity))
        stopStates = stopStates.filter { live.contains($0.key) }
        if let selected = selectedGroupID, !snap.groups.contains(where: { $0.id == selected }) {
            selectedGroupID = nil
        }
    }

    private func recomputeFindings() {
        guard let snapshot else { return }
        findings = SuggestionEngine.findings(snapshot: snapshot, baseline: baseline, ignored: ignored)
    }

    // MARK: Ignoring suggestions

    func ignore(_ finding: Finding) {
        ignored.formUnion(finding.ignoreKeys)
        recomputeFindings()
    }

    func resetIgnored() {
        ignored = []
        recomputeFindings()
    }

    // MARK: Stopping

    func isStoppable(_ process: ProcessSample) -> Bool {
        guard let snapshot else { return false }
        return Grouper.isStoppable(process, currentUID: snapshot.currentUID, ownPID: getpid())
    }

    func isStoppable(_ group: ProgramGroup) -> Bool {
        guard let snapshot else { return false }
        return Grouper.isStoppable(group, currentUID: snapshot.currentUID, ownPID: getpid())
    }

    func requestStop(_ target: StopTarget) { stopStates[target.id] = .confirming }

    func cancelStop(_ target: StopTarget) { stopStates[target.id] = nil }

    func stop(_ target: StopTarget, force: Bool) {
        stopStates[target.id] = .stopping
        Task {
            switch await Killer.stop(target, force: force) {
            case .stopped:
                stopStates[target.id] = nil
                refresh()
            case .stillRunning(let n):
                stopStates[target.id] = .stillRunning(n)
            case .failed(let message):
                stopStates[target.id] = .failed(message)
            }
        }
    }

    // MARK: Browser tabs

    func loadTabs(for group: ProgramGroup) {
        guard let bundlePath = group.bundlePath else { return }
        if isDemo {
            tabLists[group.id] = .loaded(DemoData.tabs())
            return
        }
        tabLists[group.id] = .loading
        // Let the spinner draw before the Apple Event (and maybe a permission prompt) blocks.
        DispatchQueue.main.async { [weak self] in
            self?.tabLists[group.id] = TabReader.read(bundlePath: bundlePath)
        }
    }

    // MARK: Open at login

    var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setOpensAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        objectWillChange.send()
    }
}
