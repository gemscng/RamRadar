import RamRadarCore
import SwiftUI

/// Everything inside the dropdown: memory summary, then either the overview or one program's breakdown.
struct PanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = model.snapshot {
                SystemHeader(system: snapshot.system)
                    .padding(14)
                Divider()
                if isStaticRender {
                    content(snapshot)
                } else {
                    ScrollView { content(snapshot) }
                        .frame(maxHeight: .infinity)
                }
            } else {
                ProgressView("Checking memory…")
                    .frame(maxWidth: .infinity, maxHeight: isStaticRender ? nil : .infinity)
                    .frame(minHeight: 240)
            }
            Divider()
            FooterBar()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 440, height: isStaticRender ? nil : model.panelHeight)
    }

    @ViewBuilder private func content(_ snapshot: Snapshot) -> some View {
        Group {
            if let group = model.selectedGroup {
                ProgramDetailView(group: group)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.findings.isEmpty {
                        FindingsSection(findings: model.findings)
                    }
                    ProgramsSection(snapshot: snapshot)
                }
            }
        }
        .padding(14)
    }
}
