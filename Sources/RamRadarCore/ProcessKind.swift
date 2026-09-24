import Foundation

/// Names the role of a process inside an app, for the per-app breakdown.
/// Chromium-based apps (Chrome, Edge, Brave, Slack, VS Code, Electron apps) say it in `--type=`.
public enum ProcessKind {
    public struct Summary: Hashable, Sendable {
        public var label: String
        public var count: Int
        public var bytes: UInt64
    }

    public static func label(_ p: ProcessSample) -> String {
        func value(_ flag: String) -> String? {
            p.arguments.first { $0.hasPrefix(flag + "=") }.map { String($0.dropFirst(flag.count + 1)) }
        }
        guard let type = value("--type") else { return p.executableName }
        switch type {
        case "renderer":
            return p.arguments.contains("--extension-process") ? "Extension" : "Renderer"
        case "gpu-process":
            return "GPU"
        case "utility":
            guard let sub = value("--utility-sub-type") else { return "Utility" }
            let name = sub.split(separator: ".").last.map(String.init) ?? sub
            return "Utility: \(name)"
        case "crashpad-handler":
            return "Crash reporter"
        default:
            return type.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    /// Processes bucketed by label, largest total first.
    public static func breakdown(_ processes: [ProcessSample]) -> [Summary] {
        var buckets: [String: Summary] = [:]
        for p in processes {
            let key = label(p)
            buckets[key, default: Summary(label: key, count: 0, bytes: 0)].count += 1
            buckets[key]!.bytes += p.footprint
        }
        return buckets.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.label < $1.label }
    }
}
