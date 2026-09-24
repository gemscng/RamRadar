import Darwin
import Foundation

public enum Stopper {
    public enum SignalResult: Equatable, Sendable {
        case sent
        case notPermitted(String)
    }

    /// Sends SIGTERM (or SIGKILL when `force`) to every target that is still the
    /// process we sampled. Pids reused since the check are left alone.
    public static func signal(_ targets: [ProcessSample], force: Bool) -> SignalResult {
        for p in targets where Sampler.isSameProcess(p) {
            if kill(p.pid, force ? SIGKILL : SIGTERM) != 0 && errno == EPERM {
                return .notPermitted(p.name)
            }
        }
        return .sent
    }

    /// Polls until every target has exited or `timeout` passes. Returns how many are still running.
    public static func waitForExit(_ targets: [ProcessSample], timeout: TimeInterval = 5) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !targets.contains(where: Sampler.isSameProcess) { return 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return targets.filter(Sampler.isSameProcess).count
    }
}
