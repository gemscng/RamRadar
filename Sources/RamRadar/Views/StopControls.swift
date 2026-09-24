import RamRadarCore
import SwiftUI

/// Confirm → stopping → (force quit | error) flow, shown once a stop has been requested.
struct StopControls: View {
    @EnvironmentObject var model: AppModel
    let target: StopTarget

    private var processCount: String {
        target.processes.count == 1 ? "1 process" : "\(target.processes.count) processes"
    }

    var body: some View {
        switch model.stopStates[target.id] {
        case nil:
            EmptyView()
        case .confirming:
            prompt("\(target.verb) \(target.name)? \(processCount).", action: target.verb, force: false)
        case .stopping:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Stopping…").font(.caption).foregroundStyle(.secondary)
            }
        case .stillRunning(let n):
            prompt("Still running (\(n)). It may be waiting on a save dialog.", action: "Force Quit", force: true)
        case .failed(let message):
            HStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.red)
                Spacer(minLength: 4)
                Button("OK") { model.cancelStop(target) }
            }
            .controlSize(.small)
        }
    }

    private func prompt(_ text: String, action: String, force: Bool) -> some View {
        HStack(spacing: 8) {
            Text(text).font(.caption).lineLimit(2)
            Spacer(minLength: 4)
            Button("Cancel") { model.cancelStop(target) }
            Button(action) { model.stop(target, force: force) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .controlSize(.small)
    }
}
