import AppKit
import RamRadarCore
import SwiftUI

enum CLI {
    static let usage = """
    RamRadar: menu-bar memory monitor for macOS.

    Usage:
      RamRadar                     Run in the menu bar.
      RamRadar --dump              Print one check (memory, top programs, suggestions) and exit.
      RamRadar --snapshot <png>    Render the panel to a PNG and exit. Add --dark for dark mode,
                                   --detail <program name> to render that program's breakdown.
      RamRadar --demo              Use built-in sample data instead of this Mac's processes
                                   (combine with any mode; used for README screenshots).
    """

    static func dump(demo: Bool) {
        let snapshot = demo ? DemoData.snapshot() : Sampler.snapshot()
        let baseline = demo ? DemoData.baseline() : nil
        let findings = SuggestionEngine.findings(snapshot: snapshot, baseline: baseline)
        let s = snapshot.system
        print("Memory   \(ByteFormat.string(s.used)) used of \(ByteFormat.string(s.physical)) · pressure \(s.pressure)")
        print("         apps \(ByteFormat.string(s.appMemory)) · wired \(ByteFormat.string(s.wired)) · compressed \(ByteFormat.string(s.compressed)) · cached \(ByteFormat.string(s.cached)) · swap \(ByteFormat.string(s.swapUsed))")
        print("Programs \(snapshot.groups.count) (from \(snapshot.processes.count) processes)")
        for g in snapshot.groups.prefix(15) {
            let size = ByteFormat.string(g.footprint).padding(toLength: 8, withPad: " ", startingAt: 0)
            let age = DurationFormat.string(snapshot.date.timeIntervalSince(g.startTime)).padding(toLength: 7, withPad: " ", startingAt: 0)
            print("  \(size) \(age) \(g.name)\(g.detail.map { "  [\($0)]" } ?? "")")
        }
        print("Suggestions \(findings.count)")
        for f in findings {
            var pids = f.targets.prefix(8).map { String($0.pid) }.joined(separator: " ")
            if f.targets.count > 8 { pids += " …" }
            print("  • \(f.title) — \(ByteFormat.string(f.bytes))" + (f.targets.isEmpty ? "" : " · \(f.targets.count) process(es): \(pids)"))
            if let subtitle = f.subtitle { print("      \(subtitle)") }
            for r in f.reasons { print("      [\(r.kind.rawValue)] \(r.text)") }
        }
    }

    @MainActor
    static func snapshot(to path: String, demo: Bool, dark: Bool, detail: String? = nil) -> Bool {
        _ = NSApplication.shared
        let defaults = UserDefaults(suiteName: "RamRadar.snapshot") ?? .standard
        let model = AppModel(defaults: defaults, demo: demo)
        model.refreshNow()
        if let detail, let group = model.snapshot?.groups.first(where: { $0.name == detail }) {
            model.selectedGroupID = group.id
            if demo { model.loadTabs(for: group) }
        }
        let view = PanelView()
            .environmentObject(model)
            .environment(\.isStaticRender, true)
            .background(dark ? Color(white: 0.13) : Color(white: 0.97))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            FileHandle.standardError.write(Data("render failed\n".utf8))
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path) (\(cgImage.width)x\(cgImage.height))")
            return true
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return false
        }
    }
}
