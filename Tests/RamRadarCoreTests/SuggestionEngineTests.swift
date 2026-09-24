import XCTest
@testable import RamRadarCore


private func system(physical: UInt64 = 32 * gb, pressure: PressureLevel = .normal) -> SystemMemory {
    SystemMemory(physical: physical, appMemory: 10 * gb, wired: 2 * gb, compressed: 3 * gb, cached: 1 * gb,
                 swapUsed: 2 * gb, swapTotal: 4 * gb, pressure: pressure)
}

private func snap(_ ps: [ProcessSample], pressure: PressureLevel = .normal, physical: UInt64 = 32 * gb) -> Snapshot {
    Snapshot(date: now, system: system(physical: physical, pressure: pressure), processes: ps, currentUID: me)
}

final class LeftoverTests: XCTestCase {
    private func leftover(_ p: ProcessSample) -> Bool {
        SuggestionEngine.isLeftover(p, now: now, currentUID: me, ownPID: ownPID)
    }

    func testDetachedDevToolsAreLeftovers() {
        XCTAssertTrue(leftover(proc(1, name: "node", path: "/opt/homebrew/bin/node", args: ["npm exec next dev -p 3021"])))
        XCTAssertTrue(leftover(proc(2, name: "idevicesyslog", path: "/opt/homebrew/bin/idevicesyslog", args: ["idevicesyslog", "-u", "abc"])))
        XCTAssertTrue(leftover(proc(3, name: "Python", path: "/usr/local/Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python", args: ["python3", "-m", "http.server", "8091"])))
        XCTAssertTrue(leftover(proc(4, name: "log", path: "/usr/bin/log", args: ["/usr/bin/log", "stream", "--predicate", "x"])))
        XCTAssertTrue(leftover(proc(5, name: "tail", path: "/usr/bin/tail", args: ["tail", "-f", "a.log"])))
        XCTAssertTrue(leftover(proc(6, name: "java", path: "/opt/homebrew/opt/openjdk/bin/java", args: ["java", "-cp", "gradle-daemon.jar"])))
    }

    func testNotLeftovers() {
        let node = proc(1, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "server.js"])
        var attached = node; attached.ppid = 4242
        XCTAssertFalse(leftover(attached), "parent session still alive")
        var young = node; young.startTime = now.addingTimeInterval(-600)
        XCTAssertFalse(leftover(young), "younger than an hour")
        var foreign = node; foreign.uid = 0
        XCTAssertFalse(leftover(foreign), "someone else's process")
        var own = node; own.pid = ownPID
        XCTAssertFalse(leftover(own))
        XCTAssertFalse(leftover(proc(2, name: "log", path: "/usr/bin/log", args: ["log", "show", "--last", "1h"])), "log show exits on its own")
        XCTAssertFalse(leftover(proc(3, name: "tail", path: "/usr/bin/tail", args: ["tail", "-n", "5", "a.log"])))
        XCTAssertFalse(leftover(proc(4, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack")), "apps are launched by launchd on purpose")
        XCTAssertFalse(leftover(proc(5, name: "node", path: "/System/Library/Foo/node")), "system paths")
        XCTAssertFalse(leftover(proc(6, name: "mongod", path: "/usr/local/bin/mongod", args: ["mongod"])), "not a dev tool we know")
    }
}

final class FindingTests: XCTestCase {
    func testLeftoverCardCoversWholeTreeAndAbsorbsHeavyChild() {
        let ps = [
            proc(100, name: "node", path: "/opt/homebrew/bin/node", args: ["npm exec next dev -p 3000"], cwd: "/tmp/shop", hours: 26, bytes: 100 << 20),
            proc(101, ppid: 100, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "next", "dev"], hours: 26, bytes: 200 << 20),
            proc(102, ppid: 101, name: "node", path: "/opt/homebrew/bin/node", args: ["next-server (v16)"], hours: 26, bytes: 9 * gb),
        ]
        let findings = SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ownPID: ownPID)
        XCTAssertEqual(findings.count, 1, "the heavy next-server folds into its parent's leftover card")
        let f = findings[0]
        XCTAssertEqual(f.title, "npm exec next dev -p 3000")
        XCTAssertEqual(f.subtitle, "/tmp/shop")
        XCTAssertEqual(Set(f.targets.map(\.pid)), [100, 101, 102])
        XCTAssertEqual(f.bytes, 9 * gb + (300 << 20))
        XCTAssertEqual(f.kinds, [.leftover, .heavy])
        XCTAssertTrue(f.reasons[0].text.contains("2 child processes"))
    }

    func testHeavyThresholdIsTwentyPercentCappedAtEightGB() {
        XCTAssertEqual(SuggestionRules.default.heavyThreshold(physical: 8 * gb), UInt64(Double(8 * gb) * 0.2))
        XCTAssertEqual(SuggestionRules.default.heavyThreshold(physical: 64 * gb), 8 * gb)

        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let under = SuggestionEngine.findings(snapshot: snap([proc(10, path: chrome, bytes: 6 * gb)]), baseline: nil, ownPID: ownPID)
        XCTAssertTrue(under.isEmpty)
        let over = SuggestionEngine.findings(snapshot: snap([proc(10, path: chrome, bytes: 7 * gb)]), baseline: nil, ownPID: ownPID)
        XCTAssertEqual(over.map(\.title), ["Google Chrome"])
        guard over.count == 1 else { return }
        XCTAssertEqual(over[0].reasons[0].text, "Using 22% of this Mac's memory")
        XCTAssertEqual(over[0].bundlePath, "/Applications/Google Chrome.app")
    }

    func testUnstoppableProgramsAreNeverSuggested() {
        let ws = proc(10, uid: 88, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", bytes: 20 * gb)
        XCTAssertTrue(SuggestionEngine.findings(snapshot: snap([ws]), baseline: nil, ownPID: ownPID).isEmpty)
    }

    func testGrowthNeedsBothOneGBAndFiftyPercent() {
        let p = proc(7, ppid: 300, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "a.js"], bytes: 3 * gb)
        let s = snap([p])
        func baseline(_ before: UInt64) -> Baseline {
            Baseline(date: now.addingTimeInterval(-900), footprints: [s.groups[0].id: before])
        }
        let grew = SuggestionEngine.findings(snapshot: s, baseline: baseline(1 * gb), ownPID: ownPID)
        XCTAssertEqual(grew.first?.kinds, [.growing])
        XCTAssertEqual(grew.first?.reasons.first?.text, "Grew 2.0 GB in the last 15 min")
        XCTAssertTrue(SuggestionEngine.findings(snapshot: s, baseline: baseline(2 * gb + (512 << 20)), ownPID: ownPID).isEmpty, "only +0.5 GB")
        XCTAssertTrue(SuggestionEngine.findings(snapshot: s, baseline: baseline(3 * gb), ownPID: ownPID).isEmpty)
        XCTAssertTrue(SuggestionEngine.findings(snapshot: s, baseline: nil, ownPID: ownPID).isEmpty)
    }

    func testIgnoreHidesOnlyThatReason() {
        let ps = [proc(100, name: "node", path: "/opt/homebrew/bin/node", args: ["npm exec vite"], hours: 3, bytes: 9 * gb)]
        let all = SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ownPID: ownPID)
        XCTAssertEqual(all.first?.kinds, [.leftover, .heavy])
        let leftoverKey = Finding.ignoreKey(kind: .leftover, id: all[0].id)
        let heavyOnly = SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ignored: [leftoverKey], ownPID: ownPID)
        XCTAssertEqual(heavyOnly.first?.kinds, [.heavy])
        let none = SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ignored: Set(all[0].ignoreKeys), ownPID: ownPID)
        XCTAssertTrue(none.isEmpty)
    }

    func testPressureNoticeComesFirstAndHasNoTargets() {
        let ps = [proc(10, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bytes: 9 * gb)]
        let findings = SuggestionEngine.findings(snapshot: snap(ps, pressure: .critical), baseline: nil, ownPID: ownPID)
        XCTAssertEqual(findings.map(\.id).first, Finding.systemID)
        XCTAssertEqual(findings[0].title, "Memory pressure is critical")
        XCTAssertTrue(findings[0].targets.isEmpty)
        XCTAssertEqual(findings.count, 2)
        XCTAssertTrue(SuggestionEngine.findings(snapshot: snap([], pressure: .normal), baseline: nil, ownPID: ownPID).isEmpty)
    }

    func testFindingsSortedBySize() {
        let ps = [
            proc(10, name: "node", path: "/opt/homebrew/bin/node", args: ["small.js"], bytes: 10 << 20),
            proc(20, name: "node", path: "/opt/homebrew/bin/node", args: ["big.js"], bytes: 900 << 20),
        ]
        XCTAssertEqual(SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ownPID: ownPID).map(\.title), ["big.js", "small.js"])
    }
}

final class SamplerTests: XCTestCase {
    func testParseProcArgs() {
        var bytes: [UInt8] = []
        var argc: Int32 = 3
        withUnsafeBytes(of: &argc) { bytes += $0 }
        bytes += Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0, 0]
        for arg in ["node", "server.js", "--port=3000"] { bytes += Array(arg.utf8) + [0] }
        bytes += Array("PATH=/usr/bin".utf8) + [0]  // environment follows argv and must be ignored
        XCTAssertEqual(Sampler.parseProcArgs(bytes), ["node", "server.js", "--port=3000"])
        XCTAssertEqual(Sampler.parseProcArgs([UInt8]([1, 0])), [])
    }

    func testLiveSampleIncludesThisProcess() {
        let snapshot = Sampler.snapshot()
        XCTAssertGreaterThan(snapshot.system.physical, 0)
        XCTAssertGreaterThan(snapshot.system.used, 0)
        XCTAssertGreaterThan(snapshot.processes.count, 10)
        let me = snapshot.processes.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me?.footprint ?? 0, 0)
        XCTAssertFalse(me?.arguments.isEmpty ?? true)
        XCTAssertTrue(Sampler.isSameProcess(me!))
        var reused = me!
        reused.startTime = reused.startTime.addingTimeInterval(-60)
        XCTAssertFalse(Sampler.isSameProcess(reused), "a reused pid must not match")
    }
}
