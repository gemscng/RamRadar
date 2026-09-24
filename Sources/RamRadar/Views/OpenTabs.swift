import RamRadarCore
import SwiftUI

/// Opt-in list of a browser's open tabs (read through AppleScript; macOS asks permission once).
struct OpenTabsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isStaticRender) private var isStaticRender
    let group: ProgramGroup
    @State private var showAll = false

    private static let pageSize = 30

    var body: some View {
        let state = model.tabLists[group.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Open tabs").font(.subheadline.weight(.semibold))
                if case .loaded(let windows) = state {
                    let count = windows.reduce(0) { $0 + $1.tabs.count }
                    Text("\(count) in \(windows.count) window\(windows.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isStaticRender, state != nil, state != .loading {
                    Button { model.loadTabs(for: group) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Read the tabs again")
                }
            }
            switch state {
            case nil:
                note("See what's open in \(group.name). macOS will ask once whether RamRadar may read it.")
                Button("Show Open Tabs") { model.loadTabs(for: group) }
                    .controlSize(.small)
            case .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading tabs…").font(.caption).foregroundStyle(.secondary)
                }
            case .notAllowed:
                note("RamRadar isn't allowed to read \(group.name). Turn it on under Privacy & Security → Automation, then try again.")
                HStack {
                    Button("Open Settings") { NSWorkspace.shared.open(TabReader.automationSettingsURL) }
                    Button("Try Again") { model.loadTabs(for: group) }
                }
                .controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            case .loaded(let windows):
                tabList(windows)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func tabList(_ windows: [BrowserTabs.Window]) -> some View {
        let rows = windows.flatMap { w in w.tabs.map { (window: w.number, tab: $0) } }
        let limit = isStaticRender || !showAll ? Self.pageSize : rows.count
        ForEach(Array(rows.prefix(limit).enumerated()), id: \.offset) { index, row in
            if windows.count > 1, index == 0 || rows[index - 1].window != row.window {
                Text("Window \(row.window)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, index == 0 ? 0 : 6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.tab.title).font(.callout).lineLimit(1)
                Text(row.tab.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .help(row.tab.url)
        }
        if !isStaticRender, rows.count > Self.pageSize {
            Button(showAll ? "Show first \(Self.pageSize)" : "Show all \(rows.count) tabs") { showAll.toggle() }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
