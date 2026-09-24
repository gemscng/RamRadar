import AppKit
import RamRadarCore

enum TabListState: Equatable {
    case loading
    case loaded([BrowserTabs.Window])
    case notAllowed
    case failed(String)
}

@MainActor
enum TabReader {
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func bundleID(forBundle path: String) -> String? {
        Bundle(path: path)?.bundleIdentifier
    }

    static func supports(bundlePath: String?) -> Bool {
        guard let path = bundlePath, let id = bundleID(forBundle: path) else { return false }
        return BrowserTabs.supportedBundleIDs.contains(id)
    }

    /// The first call triggers macOS's "RamRadar wants to control Google Chrome" prompt.
    static func read(bundlePath: String) -> TabListState {
        guard let id = bundleID(forBundle: bundlePath), let script = NSAppleScript(source: BrowserTabs.script(bundleID: id)) else {
            return .failed("Couldn't build the AppleScript for this app.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 { return .notAllowed }  // errAEEventNotPermitted
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "AppleScript error \(code)")
        }
        let lists = strings(result)
        guard lists.count == 2 else { return .loaded([]) }
        return .loaded(BrowserTabs.windows(titles: lists[0], urls: lists[1]))
    }

    /// `{{"a","b"},{"c"}}` → `[["a","b"],["c"]]`
    private static func strings(_ descriptor: NSAppleEventDescriptor) -> [[[String]]] {
        func list(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
            guard d.numberOfItems > 0 else { return [] }
            return (1...d.numberOfItems).compactMap { d.atIndex($0) }
        }
        return list(descriptor).map { perWindowLists in
            list(perWindowLists).map { window in list(window).map { $0.stringValue ?? "" } }
        }
    }
}
