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
            target.bundlePath.flatMap { path in
                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == path }
            }
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
