import RamRadarCore
import SwiftUI

struct FindingsSection: View {
    let findings: [Finding]
    @State private var expanded = false

    private static let collapsedCount = 5

    var body: some View {
        let stoppable = findings.filter { !$0.isSystem }.count
        let visible = expanded ? findings : Array(findings.prefix(Self.collapsedCount))

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(stoppable > 0 ? "Suggested to stop" : "Heads up").font(.headline)
                if stoppable > 0 {
                    Text("\(stoppable)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            ForEach(visible) { FindingCard(finding: $0) }
            if findings.count > Self.collapsedCount {
                Button(expanded ? "Show fewer" : "Show \(findings.count - Self.collapsedCount) more") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

struct FindingCard: View {
    @EnvironmentObject var model: AppModel
    let finding: Finding

    private var tint: Color {
        guard finding.isSystem else { return .red }
        return model.snapshot?.system.pressure == .critical ? .red : .orange
    }

    var body: some View {
        let target = StopTarget(finding: finding)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ProgramIcon(bundlePath: finding.bundlePath, symbol: finding.isSystem ? "gauge.with.dots.needle.67percent" : "terminal")
                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = finding.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    ForEach(finding.reasons, id: \.self) { reason in
                        Label {
                            Text(reason.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Self.symbol(reason.kind)).foregroundStyle(tint)
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 8)
                if !finding.isSystem {
                    Text(ByteFormat.string(finding.bytes))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                }
            }
            if !finding.isSystem {
                Group {
                    if model.stopStates[target.id] == nil {
                        actions(target)
                    } else {
                        StopControls(target: target)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.3)))
    }

    private func actions(_ target: StopTarget) -> some View {
        HStack(spacing: 8) {
            Button(role: .destructive) { model.requestStop(target) } label: {
                Label(target.verb, systemImage: "stop.circle")
            }
            Button("Ignore") { model.ignore(finding) }
                .help("Hide this suggestion until something new comes up")
            if model.snapshot?.groups.contains(where: { $0.id == finding.id && $0.processes.count > 1 }) == true {
                Button("Details") { model.selectedGroupID = finding.id }
            }
        }
        .controlSize(.small)
    }

    static func symbol(_ kind: FindingKind) -> String {
        switch kind {
        case .pressure: return "exclamationmark.triangle.fill"
        case .leftover: return "moon.zzz.fill"
        case .growing: return "arrow.up.right"
        case .growingSlowly: return "chart.line.uptrend.xyaxis"
        case .heavy: return "scalemass.fill"
        }
    }
}
