import XCTest
@testable import RamRadarCore

final class GrouperTests: XCTestCase {
    func testOutermostAppBundle() {
        XCTAssertEqual(
            Grouper.outermostAppBundle(in: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"),
            "/Applications/Google Chrome.app"
        )
        XCTAssertEqual(Grouper.outermostAppBundle(in: "/Applications/Slack.app"), "/Applications/Slack.app")
        XCTAssertNil(Grouper.outermostAppBundle(in: "/opt/homebrew/bin/node"))
        XCTAssertNil(Grouper.outermostAppBundle(in: ""))
        // Homebrew Python lives in Python.framework/.../Python.app; that's not an app the user opened.
        XCTAssertNil(Grouper.outermostAppBundle(in: "/usr/local/Cellar/python@3.13/3.13.2/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python"))
        // Xcode's developer folder holds command-line tools and separate apps, not parts of Xcode.
        XCTAssertNil(Grouper.outermostAppBundle(in: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"))
        XCTAssertEqual(
            Grouper.outermostAppBundle(in: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"),
            "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app"
        )
        XCTAssertEqual(Grouper.outermostAppBundle(in: "/Applications/Xcode.app/Contents/MacOS/Xcode"), "/Applications/Xcode.app")
    }

    func testAppBundleFallsBackToArgv0ForChromeCodeSignClone() {
        let p = proc(10, path: "/private/var/folders/xx/X/com.google.Chrome.code_sign_clone/abc/Google Chrome.app.bundle/Contents/MacOS/Google Chrome",
                     args: ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "--flag"])
        XCTAssertEqual(p.appBundlePath, "/Applications/Google Chrome.app")
        XCTAssertNil(proc(11, path: "/opt/homebrew/bin/node", args: ["node", "server.js"]).appBundlePath)
    }

    func testDescribeShortensPathsAndDropsNoise() {
        let p = proc(1, path: "/opt/homebrew/bin/node", args: ["node", "/Users/me/app/proxy.mjs", "--port", "8098"])
        XCTAssertEqual(Grouper.describe(p), "node proxy.mjs --port 8098")
        let padded = proc(2, args: ["next-server (v16.3.4)      ", "", "  "])
        XCTAssertEqual(Grouper.describe(padded), "next-server (v16.3.4)")
        let flags = proc(3, args: ["chrome", "--type=renderer", "--origin-trial-disabled-features=CanvasTextNg|WebAssemblyCustomDescriptors"])
        XCTAssertEqual(Grouper.describe(flags), "chrome --type=renderer")
        XCTAssertEqual(Grouper.describe(proc(4, name: "kernel_task")), "kernel_task")
        XCTAssertEqual(Grouper.describe(proc(5, args: [String(repeating: "a", count: 100)]), maxLength: 10).count, 10)
    }

    func testGroupsMergeAppHelpersAndSortBySize() {
        let chrome = "/Applications/Google Chrome.app"
        let groups = Grouper.groups(from: [
            proc(1, path: "\(chrome)/Contents/MacOS/Google Chrome", bytes: 1 * gb),
            proc(2, path: "\(chrome)/Contents/Frameworks/F.framework/Helpers/H.app/Contents/MacOS/H", bytes: 2 * gb),
            proc(3, path: "/opt/homebrew/bin/node", args: ["node", "a.js"], cwd: "/", bytes: 2 * gb + 1),
            proc(4, path: "/Applications/Slack.app/Contents/MacOS/Slack", bytes: 10),
        ])
        XCTAssertEqual(groups.map(\.name), ["Google Chrome", "node a.js", "Slack"])
        XCTAssertEqual(groups[0].footprint, 3 * gb)
        XCTAssertEqual(groups[0].detail, "2 processes")
        XCTAssertEqual(groups[0].id, "app:\(chrome)")
        XCTAssertNil(groups[1].detail, "cwd of / is not worth showing")
        XCTAssertNil(groups[2].detail)
    }

    func testHeadlessInstanceIsItsOwnGroup() {
        let chrome = "/Applications/Google Chrome.app"
        let exe = "\(chrome)/Contents/MacOS/Google Chrome"
        let helper = "\(chrome)/Contents/Frameworks/F.framework/Helpers/H.app/Contents/MacOS/H"
        let groups = Grouper.groups(from: [
            proc(1, path: exe, args: [exe, "--restart"], bytes: 3 * gb),
            proc(2, ppid: 1, path: helper, args: [helper, "--type=renderer"], bytes: 2 * gb),
            proc(10, path: exe, args: [exe, "--headless", "--screenshot=a.png", "http://localhost:7791/"], cwd: "/tmp/cards", bytes: 100 << 20),
            proc(11, ppid: 10, path: helper, args: [helper, "--type=renderer", "--headless"], bytes: 200 << 20),
            proc(20, path: exe, args: [exe, "--enable-automation", "--remote-debugging-pipe"], bytes: 10 << 20),
        ])
        XCTAssertEqual(groups.map(\.name), ["Google Chrome", "Google Chrome (headless)", "Google Chrome (automated)"])
        XCTAssertEqual(groups.map { Set($0.processes.map(\.pid)) }, [[1, 2], [10, 11], [20]])
        XCTAssertEqual(groups[0].id, "app:\(chrome)", "the user's Chrome keeps its id")
        XCTAssertEqual(groups[1].detail, "/tmp/cards")
    }

    func testSimulatorIsOneProgram() {
        let runtime = "/Library/Developer/CoreSimulator/Volumes/iOS_22B81/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.1.simruntime/Contents/Resources/RuntimeRoot"
        var root = proc(10, name: "launchd_sim", path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/launchd_sim",
                        args: ["launchd_sim", "/Users/me/Library/Developer/CoreSimulator/Devices/ABC/data/var/run/launchd_bootstrap.plist"], bytes: 10 << 20)
        root.deviceName = "iPhone 16 Pro"
        let groups = Grouper.groups(from: [
            root,
            proc(11, ppid: 10, path: "\(runtime)/usr/libexec/logd", bytes: 20 << 20),
            proc(12, ppid: 10, path: "\(runtime)/System/Library/CoreServices/SpringBoard.app/SpringBoard", bytes: 300 << 20),
            proc(13, ppid: 12, path: "\(runtime)/usr/libexec/backboardd", bytes: 30 << 20),
        ])
        XCTAssertEqual(groups.count, 1, "SpringBoard.app is part of the simulator, not an app of its own")
        XCTAssertEqual(groups[0].name, "iPhone 16 Pro simulator")
        XCTAssertEqual(groups[0].detail, "iOS 18.1 · 4 processes")
        XCTAssertEqual(groups[0].id, "sim:" + root.identity)
        XCTAssertEqual(Simulators.deviceDirectory(root), "/Users/me/Library/Developer/CoreSimulator/Devices/ABC")
    }

    func testVirtualMachineCountsTowardItsApp() {
        let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        func vm(_ pid: Int32, disk: String?) -> ProcessSample {
            proc(pid, name: "com.apple.Virtualization.VirtualMachine", path: vmPath, bytes: 4 * gb, openFiles: disk.map { [$0] } ?? [])
        }
        let groups = Grouper.groups(from: [
            proc(31, path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", bytes: 200 << 20),
            vm(32, disk: "/Users/me/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
            vm(33, disk: "/Users/me/.colima/_lima/colima/diffdisk"),
            vm(34, disk: nil),
        ])
        let docker = groups.first { $0.name == "Docker" }
        XCTAssertEqual(docker.map { Set($0.processes.map(\.pid)) }, [31, 32], "Quitting Docker Desktop shuts its VM down")
        XCTAssertTrue(groups.contains { $0.name == "Colima virtual machine" && $0.processes.map(\.pid) == [33] })
        XCTAssertTrue(groups.contains { $0.name == "Virtual machine" && $0.processes.map(\.pid) == [34] })
        XCTAssertEqual(docker.map { ProcessKind.breakdown($0.processes).map(\.label) }, ["Virtual machine", "com.docker.backend"])

        // A signal would power a VM off mid-write; only quitting its app is offered.
        XCTAssertTrue(Grouper.isStoppable(docker!, currentUID: me, ownPID: ownPID))
        XCTAssertFalse(Grouper.isStoppable(vm(5, disk: nil), currentUID: me, ownPID: ownPID))
        XCTAssertFalse(Grouper.isStoppable(groups.first { $0.name == "Colima virtual machine" }!, currentUID: me, ownPID: ownPID))
    }

    func testDescendantsWalksTreeButSkipsApps() {
        let all = [
            proc(10, ppid: 1),
            proc(11, ppid: 10),
            proc(12, ppid: 11),
            proc(13, ppid: 10, path: "/Applications/Foo.app/Contents/MacOS/Foo"),
            proc(14, ppid: 99),
        ]
        XCTAssertEqual(Set(Grouper.descendants(of: 10, in: all).map(\.pid)), [11, 12])
        XCTAssertEqual(Grouper.descendants(of: 12, in: all).count, 0)
    }

    func testDescendantsSurvivesCycles() {
        let all = [proc(20, ppid: 21), proc(21, ppid: 20)]
        XCTAssertEqual(Set(Grouper.descendants(of: 20, in: all).map(\.pid)), [21])
    }

    func testStoppable() {
        func group(_ ps: [ProcessSample]) -> ProgramGroup { Grouper.groups(from: ps)[0] }
        XCTAssertTrue(Grouper.isStoppable(group([proc(50, path: "/opt/homebrew/bin/node")]), currentUID: me, ownPID: 1234))
        XCTAssertFalse(Grouper.isStoppable(group([proc(50, uid: 0)]), currentUID: me, ownPID: 1234), "other users' processes")
        XCTAssertFalse(Grouper.isStoppable(group([proc(1234)]), currentUID: me, ownPID: 1234), "RamRadar itself")
        XCTAssertFalse(Grouper.isStoppable(group([proc(1, ppid: 0)]), currentUID: me, ownPID: 1234), "launchd")
        XCTAssertFalse(Grouper.isStoppable(group([proc(60, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")]), currentUID: me, ownPID: 1234))
        XCTAssertFalse(Grouper.isStoppable(group([proc(61, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")]), currentUID: me, ownPID: 1234))
    }
}

final class FormatTests: XCTestCase {
    func testBytes() {
        XCTAssertEqual(ByteFormat.string(512 << 20), "512 MB")
        XCTAssertEqual(ByteFormat.string(UInt64(1.5 * Double(gb))), "1.5 GB")
        XCTAssertEqual(ByteFormat.string(41 * gb), "41 GB")
    }

    func testDuration() {
        XCTAssertEqual(DurationFormat.string(30), "30 s")
        XCTAssertEqual(DurationFormat.string(15 * 60), "15 min")
        XCTAssertEqual(DurationFormat.string(27 * 3600), "1 d")
        XCTAssertEqual(DurationFormat.string(-5), "0 s")
    }
}
