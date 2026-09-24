import Foundation

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

public enum DurationFormat {
    public static func string(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s >= 86_400 { return "\(s / 86_400) d" }
        if s >= 3_600 { return "\(s / 3_600) h" }
        if s >= 60 { return "\(s / 60) min" }
        return "\(s) s"
    }
}
