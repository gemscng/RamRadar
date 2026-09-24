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
