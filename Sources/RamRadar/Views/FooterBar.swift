import AppKit
import RamRadarCore
import SwiftUI

/// Last-check time, Check Now, and the settings menu.
struct FooterBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isStaticRender) private var isStaticRender

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(status(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isStaticRender {
                Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            } else {
                refreshButton
                settingsMenu
            }
        }
    }

    private var refreshButton: some View {
        Button { model.refresh() } label: {
            if model.isSampling {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .help("Check now")
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Check every", selection: $model.interval) {
                ForEach(AppModel.intervals, id: \.self) { value in
                    Text("\(Int(value / 60)) minutes").tag(value)
                }
            }
            Toggle("Open at Login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            if let error = model.loginItemError {
                Text(error)
            }
            if !model.ignored.isEmpty {
                Button("Show Ignored Suggestions Again (\(model.ignored.count))") { model.resetIgnored() }
            }
            Divider()
            Button("RamRadar on GitHub") { NSWorkspace.shared.open(AppModel.repositoryURL) }
            Button("Quit RamRadar") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func status(now: Date) -> String {
        let every = "checks every \(Int(model.interval / 60)) min"
        guard let date = model.snapshot?.date else { return every }
        let age = now.timeIntervalSince(date)
        return (age < 60 ? "Updated just now" : "Updated \(DurationFormat.string(age)) ago") + " · " + every
    }
}
