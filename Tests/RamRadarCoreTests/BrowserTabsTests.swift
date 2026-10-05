import XCTest
@testable import RamRadarCore

final class BrowserTabsTests: XCTestCase {
    func testPairsTitlesAndURLsPerWindow() {
        let windows = BrowserTabs.windows(
            titles: [["Inbox", ""], [], ["Docs"]],
            urls: [["https://mail.google.com/", "about:blank"], [], ["https://www.example.com/a"]]
        )
        XCTAssertEqual(windows.map(\.number), [1, 2], "empty windows are dropped and numbering stays contiguous")
        XCTAssertEqual(windows[0].tabs, [
            .init(title: "Inbox", url: "https://mail.google.com/"),
            .init(title: "Untitled", url: "about:blank"),
        ])
        XCTAssertEqual(windows[1].tabs[0].host, "example.com")
    }

    func testMissingURLsDoNotCrash() {
        let windows = BrowserTabs.windows(titles: [["A", "B"]], urls: [["https://a.dev"]])
        XCTAssertEqual(windows[0].tabs[1].url, "")
        XCTAssertEqual(BrowserTabs.windows(titles: [["A"]], urls: []).first?.tabs.first?.url, "")
    }

    func testHost() {
        XCTAssertEqual(BrowserTabs.Tab(title: "", url: "chrome://settings/").host, "settings")
        XCTAssertEqual(BrowserTabs.Tab(title: "", url: "about:blank").host, "about:blank")
    }

    func testSupportsChrome() {
        XCTAssertTrue(BrowserTabs.supportedBundleIDs.contains("com.google.Chrome"))
    }
}
