import Foundation

/// Open tabs of a Chromium browser, read through its AppleScript dictionary.
///
/// Chromium doesn't say which renderer process serves which tab, so this is a plain list
/// of what's open, not a per-tab memory breakdown.
public enum BrowserTabs {
    public struct Tab: Hashable, Sendable {
        public var title: String
        public var url: String

        public init(title: String, url: String) {
            self.title = title
            self.url = url
        }

        /// `https://www.example.com/a/b` → `example.com`; non-web URLs are returned whole.
        public var host: String {
            guard let host = URL(string: url)?.host, !host.isEmpty else { return url }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    public struct Window: Hashable, Sendable {
        public var number: Int
        public var tabs: [Tab]

        public init(number: Int, tabs: [Tab]) {
            self.number = number
            self.tabs = tabs
        }
    }

    /// Chromium browsers whose AppleScript dictionary has `window` → `tab` → `title` / `URL`.
    public static let supportedBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
    ]

    /// Two Apple Events in total, however many tabs are open.
    public static func script(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            return {title of every tab of every window, URL of every tab of every window}
        end tell
        """
    }

    /// Pairs the per-window title and URL lists the script returns. Empty windows are dropped.
    public static func windows(titles: [[String]], urls: [[String]]) -> [Window] {
        var result: [Window] = []
        for (i, windowTitles) in titles.enumerated() {
            let windowURLs = i < urls.count ? urls[i] : []
            let tabs = windowTitles.enumerated().map { j, title in
                Tab(title: title.isEmpty ? "Untitled" : title, url: j < windowURLs.count ? windowURLs[j] : "")
            }
            if !tabs.isEmpty { result.append(Window(number: result.count + 1, tabs: tabs)) }
        }
        return result
    }
}
