import AppKit
import RamRadarCore

enum StopOutcome: Equatable {
    case stopped
    case stillRunning(Int)
    case failed(String)
}

enum Killer {
    /// Apps get a normal Quit (they can save work); processes get SIGTERM; `force` sends SIGKILL.
    static func stop(_ target: StopTarget, force: Bool) async -> StopOutcome {
        let live = target.processes.filter(Sampler.isSameProcess)
        guard !live.isEmpty else { return .stopped }

        let app: NSRunningApplication? = force ? nil : await MainActor.run {
            target.bundlePath.flatMap { NSRunningApplication.instance(bundlePath: $0, among: live) }
        }

        if let app {
            _ = await MainActor.run { app.terminate() }
        } else if case .notPermitted(let name) = Stopper.signal(live, force: force) {
            return .failed("macOS doesn't allow stopping \(name)")
        }

        let remaining = await Stopper.waitForExit(live)
        return remaining == 0 ? .stopped : .stillRunning(remaining)
    }
}

extension NSRunningApplication {
    /// The running copy of the app at `bundlePath` whose main process is one of `processes`.
    /// Matching the bundle alone isn't enough: a headless Chrome left by a script has the
    /// same bundle as the Chrome the user is browsing in.
    @MainActor
    static func instance(bundlePath: String, among processes: [ProcessSample]) -> NSRunningApplication? {
        let pids = Set(processes.map(\.pid))
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == bundlePath && pids.contains($0.processIdentifier)
        }
    }
}
