import XCTest
@testable import RamRadarCore

final class StopperTests: XCTestCase {
    private func spawn(_ script: String) throws -> (Process, ProcessSample) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        addTeardownBlock { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let sample = Sampler.processes().first(where: { $0.pid == process.processIdentifier }) {
                return (process, sample)
            }
            usleep(50_000)
        }
        XCTFail("spawned process never showed up in a sample")
        throw CocoaError(.featureUnsupported)
    }

    func testStopEndsProcess() async throws {
        let (process, sample) = try spawn("exec sleep 60")
        XCTAssertEqual(Stopper.signal([sample], force: false), .sent)
        let remaining = await Stopper.waitForExit([sample], timeout: 3)
        process.waitUntilExit()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testProcessIgnoringSigtermNeedsForce() async throws {
        let (process, sample) = try spawn("trap '' TERM; while :; do sleep 0.1; done")
        usleep(200_000)  // let the trap install
        _ = Stopper.signal([sample], force: false)
        let afterTerm = await Stopper.waitForExit([sample], timeout: 1)
        XCTAssertEqual(afterTerm, 1, "SIGTERM is ignored")
        _ = Stopper.signal([sample], force: true)
        process.waitUntilExit()
        let afterKill = await Stopper.waitForExit([sample], timeout: 3)
        XCTAssertEqual(afterKill, 0)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testReusedPidIsNotSignalled() throws {
        let (process, sample) = try spawn("exec sleep 60")
        var stale = sample
        stale.startTime = stale.startTime.addingTimeInterval(-3600)
        XCTAssertEqual(Stopper.signal([stale], force: true), .sent)
        usleep(300_000)
        XCTAssertTrue(process.isRunning, "a sample from a different process lifetime must not be killed")
    }
}
