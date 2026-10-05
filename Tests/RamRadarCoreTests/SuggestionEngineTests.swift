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

    func testDetachedHeadlessBrowserIsLeftover() {
        let exe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        XCTAssertTrue(leftover(proc(1, path: exe, args: [exe, "--headless", "--screenshot=a.png"])))
        XCTAssertTrue(leftover(proc(2, path: exe, args: [exe, "--headless=new"])))
        XCTAssertTrue(leftover(proc(3, path: exe, args: [exe, "--enable-automation", "--remote-debugging-pipe"])))
        XCTAssertFalse(leftover(proc(4, path: exe, args: [exe, "--restart"])), "the user's own Chrome")
        XCTAssertFalse(leftover(proc(5, path: exe, args: [exe, "--type=renderer", "--headless"])), "a helper, not the browser")
        XCTAssertFalse(leftover(proc(6, ppid: 4242, path: exe, args: [exe, "--headless"])), "its script is still running")
    }

    func testDevToolInDeletedFolderIsLeftoverEvenWithParent() {
        let node = proc(1, ppid: 4242, name: "node", path: "/opt/homebrew/bin/node", args: ["node", "next", "dev"], hours: 0.2)
        var gone = node; gone.cwdDeleted = true
        XCTAssertFalse(leftover(node))
        XCTAssertTrue(leftover(gone), "parent alive and only 12 minutes old, but its worktree is gone")
        var shell = proc(2, ppid: 4242, name: "zsh", path: "/bin/zsh", args: ["-zsh"]); shell.cwdDeleted = true
        XCTAssertFalse(leftover(shell), "a terminal tab sitting in a deleted folder is the user's")
    }

    func testLanguageServersAndEmulatorsCount() {
        XCTAssertTrue(leftover(proc(1, name: "gopls", path: "/Users/me/go/bin/gopls", args: ["gopls", "serve"])))
        XCTAssertTrue(leftover(proc(2, name: "sourcekit-lsp", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp")),
                      "an Xcode toolchain binary is a command-line tool, even though its path runs through Xcode.app")
        XCTAssertTrue(leftover(proc(3, name: "qemu-system-aarch64", path: "/Users/me/Library/Android/sdk/emulator/qemu/darwin-aarch64/qemu-system-aarch64")))
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

    func testHeadlessBrowserCardCoversItsHelpersAndLeavesUsersChromeAlone() {
        let exe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/F.framework/Helpers/H.app/Contents/MacOS/H"
        let ps = [
            proc(1, path: exe, args: [exe], hours: 300, bytes: 2 * gb),
            proc(2, ppid: 1, path: helper, args: [helper, "--type=renderer"], hours: 300, bytes: 2 * gb),
            proc(10, path: exe, args: [exe, "--headless", "--screenshot=a.png", "http://localhost:7791/"], cwd: "/tmp/cards", hours: 110, bytes: 100 << 20),
            proc(11, ppid: 10, path: helper, args: [helper, "--type=gpu-process"], hours: 110, bytes: 200 << 20),
            proc(12, ppid: 10, path: helper, args: [helper, "--type=renderer"], hours: 110, bytes: 9 * gb),
        ]
        let s = snap(ps)
        let findings = SuggestionEngine.findings(snapshot: s, baseline: nil, ownPID: ownPID)
        XCTAssertEqual(findings.count, 1, "its heavy renderer joins the leftover card")
        let f = findings[0]
        XCTAssertEqual(f.title, "Google Chrome (headless)")
        XCTAssertEqual(f.subtitle, "/tmp/cards")
        XCTAssertEqual(f.bundlePath, "/Applications/Google Chrome.app")
        XCTAssertEqual(Set(f.targets.map(\.pid)), [10, 11, 12])
        XCTAssertEqual(f.kinds, [.leftover, .heavy])
        XCTAssertTrue(f.reasons[0].text.hasPrefix("The script or agent that started it has ended · running 4 d · 2 child processes"))
        XCTAssertTrue(s.groups.contains { $0.id == f.id }, "Details opens its program group")
    }

    func testDeletedFolderCardSitsOnTheTopmostProcess() {
        var pnpm = proc(100, ppid: 4242, name: "node", path: "/opt/homebrew/bin/node", args: ["pnpm", "exec", "next", "dev"],
                        cwd: "/Users/me/app-wt", hours: 3, bytes: 80 << 20)
        var server = proc(101, ppid: 100, name: "next-server (v16)", path: "/opt/homebrew/bin/node", args: ["next-server (v16)"],
                          cwd: "/Users/me/app-wt", hours: 3, bytes: 900 << 20)
        pnpm.cwdDeleted = true
        server.cwdDeleted = true
        let findings = SuggestionEngine.findings(snapshot: snap([pnpm, server]), baseline: nil, ownPID: ownPID)
        XCTAssertEqual(findings.count, 1, "the server inherits the deleted folder but belongs on its parent's card")
        XCTAssertEqual(Set(findings.first?.targets.map(\.pid) ?? []), [100, 101])
        XCTAssertEqual(findings.first?.reasons.first?.text, "The folder it runs in has been deleted · running 3 h · 1 child process")
    }

    func testSlowGrowthIsForCommandLinePrograms() {
        func session(_ bytes: UInt64) -> ProcessSample {
            proc(50, ppid: 4242, name: "claude", path: "/Users/me/.local/bin/claude", args: ["claude"], hours: 200, bytes: bytes)
        }
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        func browser(_ bytes: UInt64) -> ProcessSample { proc(60, path: chrome, args: [chrome], hours: 200, bytes: bytes) }
        func seen(hoursAgo: Double) -> FirstSeen {
            var firstSeen = FirstSeen()
            firstSeen.record(Snapshot(date: now.addingTimeInterval(-hoursAgo * 3600), system: system(),
                                      processes: [session(300 << 20), browser(1 * gb)], currentUID: me))
            return firstSeen
        }
        let later = snap([session(1 * gb), browser(5 * gb)])

        let grew = SuggestionEngine.findings(snapshot: later, baseline: nil, firstSeen: seen(hoursAgo: 190), ownPID: ownPID)
        XCTAssertEqual(grew.map(\.title), ["claude"], "Chrome grew too, but apps grow as they're used")
        XCTAssertEqual(grew.first?.kinds, [.growingSlowly])
        XCTAssertEqual(grew.first?.reasons.first?.text, "Grew from 300 MB to 1.0 GB in 7 d")
        XCTAssertTrue(SuggestionEngine.findings(snapshot: later, baseline: nil, firstSeen: seen(hoursAgo: 2), ownPID: ownPID).isEmpty,
                      "two hours is the short-term rule's job")

        var restarted = seen(hoursAgo: 190)
        var relaunched = session(1 * gb)
        relaunched.startTime = now.addingTimeInterval(-60)
        let afterRelaunch = snap([relaunched])
        restarted.record(afterRelaunch)
        XCTAssertTrue(SuggestionEngine.findings(snapshot: afterRelaunch, baseline: nil, firstSeen: restarted, ownPID: ownPID).isEmpty,
                      "a new process with a reused pid starts from its own first size")
    }

    func testSwapCardWhenPressureIsNormal() {
        func findings(swap: UInt64, pressure: PressureLevel = .normal) -> [Finding] {
            var s = snap([])
            s.system = SystemMemory(physical: 64 * gb, appMemory: 20 * gb, wired: 6 * gb, compressed: 20 * gb, cached: 9 * gb,
                                    swapUsed: swap, swapTotal: swap + gb, pressure: pressure)
            return SuggestionEngine.findings(snapshot: s, baseline: nil, ownPID: ownPID)
        }
        XCTAssertEqual(findings(swap: 24 * gb).map(\.title), ["24 GB of memory is in swap"])
        XCTAssertTrue(findings(swap: 15 * gb).isEmpty, "under a quarter of the Mac's memory")
        XCTAssertEqual(findings(swap: 24 * gb, pressure: .warning).map(\.title), ["Memory pressure is high"], "one system card, not two")
    }

    func testOneHugeTabGetsItsOwnCard() {
        let chrome = "/Applications/Google Chrome.app"
        let slack = "/Applications/Slack.app"
        func helper(_ app: String) -> String { "\(app)/Contents/Frameworks/F.framework/Helpers/H.app/Contents/MacOS/H" }
        let ps = [
            proc(41, path: "\(chrome)/Contents/MacOS/Google Chrome", hours: 200, bytes: 1 * gb),
            proc(42, ppid: 41, path: helper(chrome), args: [helper(chrome), "--type=renderer"], hours: 200, bytes: 2 * gb + (700 << 20)),
            proc(43, ppid: 41, path: helper(chrome), args: [helper(chrome), "--type=renderer"], hours: 200, bytes: 1 * gb),
            proc(44, ppid: 41, path: helper(chrome), args: [helper(chrome), "--type=renderer", "--extension-process"], bytes: 3 * gb),
            proc(10, path: "\(slack)/Contents/MacOS/Slack", bytes: 200 << 20),
            proc(11, ppid: 10, path: helper(slack), args: [helper(slack), "--type=renderer"], bytes: 3 * gb),
        ]
        var s = snap(ps)
        s.system.physical = 64 * gb
        let tabs = SuggestionEngine.findings(snapshot: s, baseline: nil, ownPID: ownPID).filter { $0.title.hasSuffix(" tab") }
        XCTAssertEqual(tabs.map(\.targets.first?.pid), [42], "not the 1 GB tab, not an extension, not a Slack window")
        XCTAssertEqual(tabs.first?.title, "Google Chrome tab")
        XCTAssertEqual(tabs.first?.quitsApp, false, "Stop ends that one process instead of quitting Chrome")
        XCTAssertEqual(tabs.first?.bundlePath, chrome)
        XCTAssertEqual(tabs.first?.kinds, [.heavy])
    }

    func testSimulatorLeftWithSimulatorAppClosed() {
        let bootstrap = "/Users/me/Library/Developer/CoreSimulator/Devices/ABC/data/var/run/launchd_bootstrap.plist"
        let simPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/launchd_sim"
        func sim(preview: Bool = false, hours: Double = 3) -> [ProcessSample] {
            let args = ["launchd_sim", preview ? bootstrap.replacingOccurrences(of: "/CoreSimulator/Devices/", with: "/Xcode/UserData/Previews/Simulator Devices/") : bootstrap]
            return [
                proc(10, name: "launchd_sim", path: simPath, args: args, hours: hours, bytes: 10 << 20),
                proc(11, ppid: 10, path: "/Library/Developer/CoreSimulator/Volumes/iOS/x.simruntime/Contents/Resources/RuntimeRoot/usr/libexec/logd", hours: hours, bytes: 900 << 20),
            ]
        }
        let simulatorApp = proc(20, path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
        let xcode = proc(21, path: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        let xcodebuild = proc(22, ppid: 4242, name: "xcodebuild", path: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild")
        func cards(_ ps: [ProcessSample]) -> [Finding] {
            SuggestionEngine.findings(snapshot: snap(ps), baseline: nil, ownPID: ownPID).filter { $0.kinds.contains(.leftover) }
        }

        let left = cards(sim())
        XCTAssertEqual(left.map(\.title), ["Simulator"])
        XCTAssertEqual(left.first?.targets.map(\.pid), [10, 11], "launchd_sim is stopped first")
        XCTAssertEqual(left.first?.reasons.first?.text, "Running with the Simulator app closed · booted 3 h ago")
        XCTAssertTrue(cards(sim() + [simulatorApp]).isEmpty, "the Simulator app is open")
        XCTAssertTrue(cards(sim() + [xcodebuild]).isEmpty, "tests are running")
        XCTAssertTrue(cards(sim(hours: 0.5)).isEmpty, "booted under an hour ago")
        XCTAssertTrue(cards(sim(preview: true) + [xcode]).isEmpty, "Xcode manages its preview simulators")
        XCTAssertEqual(cards(sim(preview: true)).count, 1, "a preview simulator Xcode left behind")
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

    func testOpenFilesListsAnOpenFile() throws {
        let name = "ramradar-open-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertTrue(Sampler.openFiles(getpid()).contains { $0.hasSuffix("/" + name) })
    }

    func testNoticesDeletedWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ramradar-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        process.currentDirectoryURL = dir
        try process.run()
        defer { process.terminate() }
        func sample() -> ProcessSample? { Sampler.processes().first { $0.pid == process.processIdentifier } }

        XCTAssertEqual(sample()?.cwdDeleted, false)
        try FileManager.default.removeItem(at: dir)
        let after = sample()
        XCTAssertEqual(after?.cwdDeleted, true)
        XCTAssertTrue(after?.cwd?.hasSuffix(dir.lastPathComponent) ?? false, "the kernel still reports the old path")
    }
}
