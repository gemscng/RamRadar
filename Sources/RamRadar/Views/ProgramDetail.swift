import RamRadarCore
import SwiftUI

/// One program's processes: memory by type, then each process with its own stop button.
struct ProgramDetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isStaticRender) private var isStaticRender
    let group: ProgramGroup
    @State private var showAll = false

    private static let pageSize = 25
    private static let staticRows = 14

    var body: some View {
        let summaries = ProcessKind.breakdown(group.processes)
        let colors = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($1.label, Palette.color(rank: $0)) })
        let processes = group.processes.sorted { $0.footprint > $1.footprint }
        let limit = isStaticRender ? Self.staticRows : (showAll ? processes.count : Self.pageSize)
        let maxBytes = Double(max(processes.first?.footprint ?? 1, 1))
        let isChromium = group.processes.contains { $0.arguments.contains { $0.hasPrefix("--type=") } }
        let target = StopTarget(group: group)

        VStack(alignment: .leading, spacing: 14) {
            Button { model.selectedGroupID = nil } label: {
                Label("All programs", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .font(.callout)

            HStack(spacing: 10) {
                ProgramIcon(bundlePath: group.bundlePath)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.headline)
                    Text("\(group.processes.count) processes · \(ByteFormat.string(group.footprint))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isStoppable(group), model.stopStates[target.id] == nil {
                    Button(role: .destructive) { model.requestStop(target) } label: {
                        Label("\(target.verb) All", systemImage: "stop.circle")
                    }
                    .controlSize(.small)
                }
            }
            StopControls(target: target)

            VStack(alignment: .leading, spacing: 6) {
                Text("By type").font(.subheadline.weight(.semibold))
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(summaries, id: \.label) { s in
                            Rectangle()
                                .fill(colors[s.label] ?? Palette.other)
                                .frame(width: max(1, geo.size.width * CGFloat(Double(s.bytes) / Double(max(group.footprint, 1)))))
                        }
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                ForEach(summaries.prefix(8), id: \.label) { s in
                    HStack(spacing: 6) {
                        Circle().fill(colors[s.label] ?? Palette.other).frame(width: 8, height: 8)
                        Text(s.label).font(.caption)
                        Text("×\(s.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(ByteFormat.string(s.bytes)).font(.caption).monospacedDigit()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Processes").font(.subheadline.weight(.semibold)).padding(.bottom, 4)
                ForEach(processes.prefix(limit), id: \.identity) { p in
                    let label = ProcessKind.label(p)
                    ProcessRow(process: p, label: label, color: colors[label] ?? Palette.other,
                               fraction: Double(p.footprint) / maxBytes)
                }
                if !isStaticRender, processes.count > Self.pageSize {
                    Button(showAll ? "Show top \(Self.pageSize)" : "Show all \(processes.count)") { showAll.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.top, 4)
                }
            }

            if isChromium {
                if TabReader.supports(bundlePath: group.bundlePath) {
                    OpenTabsSection(group: group)
                }
                Text("Chromium doesn't tell other apps which tab a renderer process belongs to, so tabs can't be matched to the processes above. For memory per tab, use the browser's own task manager (in Chrome: Window → Task Manager).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProcessRow: View {
    @EnvironmentObject var model: AppModel
    let process: ProcessSample
    let label: String
    let color: Color
    let fraction: Double

    var body: some View {
        let target = StopTarget(process: process, label: label)
        let stoppable = model.isStoppable(process)
        let age = (model.snapshot?.date ?? Date()).timeIntervalSince(process.startTime)

        HoverRow { hovering in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label).font(.callout).lineLimit(1)
                        Text("PID \(String(process.pid)) · running \(DurationFormat.string(age))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 6)
                    Text(ByteFormat.string(process.footprint)).font(.callout).monospacedDigit()
                    StopIconButton(
                        help: stoppable ? "Stop this process only" : "Owned by another user",
                        enabled: stoppable, highlighted: hovering
                    ) { model.requestStop(target) }
                }
                SizeBar(fraction: fraction, color: color, height: 3)
                StopControls(target: target)
            }
        }
    }
}
