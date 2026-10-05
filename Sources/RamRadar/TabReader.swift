import AppKit
import RamRadarCore
import ScriptingBridge

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

    /// Asks this group's own browser process, by pid. Addressing the bundle id would reach
    /// whichever copy macOS picks, which can be a headless one.
    /// The first call triggers macOS's "RamRadar wants to control Google Chrome" prompt.
    static func read(_ group: ProgramGroup) -> TabListState {
        guard let bundlePath = group.bundlePath,
              let app = NSRunningApplication.instance(bundlePath: bundlePath, among: group.processes) else {
            return .failed("\(group.name) is no longer running.")
        }
        // When the pid can't be resolved (the app just quit), Scripting Bridge has no `windows`
        // and asking for it raises an exception instead of returning nil.
        guard let browser = SBApplication(processIdentifier: app.processIdentifier),
              browser.responds(to: NSSelectorFromString("windows")) else {
            return .failed("Couldn't connect to \(group.name).")
        }
        let errors = EventErrors()
        browser.delegate = errors
        let windows = browser.value(forKey: "windows") as? SBElementArray
        let titles = windows?.value(forKeyPath: "tabs.title") as? [[String]]
        let urls = windows?.value(forKeyPath: "tabs.URL") as? [[String]]
        if let error = errors.first {
            if error.code == -1743 { return .notAllowed }  // errAEEventNotPermitted
            return .failed(error.localizedDescription)
        }
        return .loaded(BrowserTabs.windows(titles: titles ?? [], urls: urls ?? []))
    }
}

/// Keeps the first failed Apple Event. Without a delegate, Scripting Bridge raises an exception instead.
private final class EventErrors: NSObject, SBApplicationDelegate {
    var first: NSError?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        if first == nil { first = error as NSError }
        return nil
    }
}
