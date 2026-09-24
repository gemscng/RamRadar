import XCTest
@testable import RamRadarCore

final class ProcessKindTests: XCTestCase {
    private let helper = "/Applications/Google Chrome.app/Contents/Frameworks/F.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    func testChromiumTypes() {
        XCTAssertEqual(ProcessKind.label(proc(10, path: helper, args: ["x", "--type=renderer", "--lang=en"])), "Renderer")
        XCTAssertEqual(ProcessKind.label(proc(11, path: helper, args: ["x", "--type=renderer", "--extension-process"])), "Extension")
        XCTAssertEqual(ProcessKind.label(proc(12, path: helper, args: ["x", "--type=gpu-process"])), "GPU")
        XCTAssertEqual(ProcessKind.label(proc(13, path: helper, args: ["x", "--type=utility", "--utility-sub-type=network.mojom.NetworkService"])), "Utility: NetworkService")
        XCTAssertEqual(ProcessKind.label(proc(14, path: helper, args: ["x", "--type=utility"])), "Utility")
        XCTAssertEqual(ProcessKind.label(proc(15, path: helper, args: ["x", "--type=some-new-type"])), "Some New Type")
    }

    func testFallsBackToExecutableName() {
        XCTAssertEqual(ProcessKind.label(proc(20, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", args: ["x"])), "Google Chrome")
        XCTAssertEqual(ProcessKind.label(proc(21, name: "Slack")), "Slack")
    }

    func testBreakdownSumsAndSorts() {
        let ps = [
            proc(30, path: helper, args: ["x", "--type=renderer"], bytes: 300),
            proc(31, path: helper, args: ["x", "--type=renderer"], bytes: 200),
            proc(32, path: helper, args: ["x", "--type=gpu-process"], bytes: 400),
        ]
        XCTAssertEqual(ProcessKind.breakdown(ps), [
            .init(label: "Renderer", count: 2, bytes: 500),
            .init(label: "GPU", count: 1, bytes: 400),
        ])
    }
}
