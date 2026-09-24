import RamRadarCore
import SwiftUI

enum Palette {
    static let programs: [Color] = [.blue, .orange, .purple, .pink, .teal, .yellow, .green, .indigo]
    static let other = Color.gray.opacity(0.5)
    static let app = Color.blue
    static let wired = Color.orange
    static let compressed = Color.purple
    static let cached = Color.gray.opacity(0.55)

    static func color(rank: Int) -> Color { rank < programs.count ? programs[rank] : other }

    static func pressure(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - Static rendering

private struct StaticRenderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when drawing into a PNG (`--snapshot`). `ImageRenderer` can't draw scroll views or
    /// AppKit-backed controls, so views lay out flat, cap their lists, and skip those controls.
    var isStaticRender: Bool {
        get { self[StaticRenderKey.self] }
        set { self[StaticRenderKey.self] = newValue }
    }
}

// MARK: - Building blocks

/// A thin capsule whose length is `fraction` of the available width.
struct SizeBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(color.gradient)
                .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
        }
        .frame(height: height)
    }
}

/// The ⓧ at the end of a program or process row.
struct StopIconButton: View {
    let help: String
    let enabled: Bool
    let highlighted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted && enabled ? Color.red : Color.secondary)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .help(help)
    }
}

/// Row container with a hover highlight.
struct HoverRow<Content: View>: View {
    @ViewBuilder let content: (_ hovering: Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct ProgramIcon: View {
    let bundlePath: String?
    var symbol = "terminal"

    var body: some View {
        if let bundlePath {
            Image(nsImage: IconCache.icon(for: bundlePath))
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        }
    }
}

@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
