import Charts
import RamRadarCore
import SwiftUI

/// Donut of the biggest programs plus a ranked, bar-per-row list.
struct ProgramsSection: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.isStaticRender) private var isStaticRender
    let snapshot: Snapshot
    @State private var showAll = false

    private static let pageSize = 12
    private static let staticRows = 9

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let bytes: UInt64
        let color: Color
    }

    var body: some View {
        let groups = snapshot.groups
        let top = groups.prefix(Palette.programs.count)
        let otherBytes = groups.dropFirst(top.count).reduce(0) { $0 + $1.footprint }
        let slices = top.enumerated().map { Slice(id: $1.id, name: $1.name, bytes: $1.footprint, color: Palette.color(rank: $0)) }
            + (otherBytes > 0 ? [Slice(id: "other", name: "Everything else", bytes: otherBytes, color: Palette.other)] : [])
        let total = groups.reduce(0) { $0 + $1.footprint }
        let rowLimit = isStaticRender ? Self.staticRows : (showAll ? groups.count : Self.pageSize)
        let maxBytes = Double(max(groups.first?.footprint ?? 1, 1))
        let flagged = model.flaggedPIDs

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Programs by memory").font(.headline)
                Spacer()
                Text("\(groups.count) running").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Chart(slices) { slice in
                    SectorMark(angle: .value("Memory", Double(slice.bytes)), innerRadius: .ratio(0.62), angularInset: 1.2)
                        .cornerRadius(3)
                        .foregroundStyle(slice.color)
                }
                .chartLegend(.hidden)
                .frame(width: 118, height: 118)
                .help("Footprint counts compressed and swapped-out memory at full size, so the total can exceed physical RAM.")
                .overlay {
                    VStack(spacing: 0) {
                        Text(ByteFormat.string(total)).font(.headline).monospacedDigit()
                        Text("footprint").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(slices.prefix(6)) { slice in
                        HStack(spacing: 6) {
                            Circle().fill(slice.color).frame(width: 8, height: 8)
                            Text(slice.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(ByteFormat.string(slice.bytes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }

            VStack(spacing: 2) {
                ForEach(Array(groups.prefix(rowLimit).enumerated()), id: \.element.id) { rank, group in
                    ProgramRow(
                        group: group,
                        color: Palette.color(rank: rank),
                        fraction: Double(group.footprint) / maxBytes,
                        flagged: group.processes.contains { flagged.contains($0.pid) }
                    )
                }
            }

            if !isStaticRender, groups.count > Self.pageSize {
                Button(showAll ? "Show top \(Self.pageSize)" : "Show all \(groups.count)") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

struct ProgramRow: View {
    @EnvironmentObject var model: AppModel
    let group: ProgramGroup
    let color: Color
    let fraction: Double
    let flagged: Bool

    private var hasBreakdown: Bool { group.processes.count > 1 }

    var body: some View {
        let target = StopTarget(group: group)
        let stoppable = model.isStoppable(group)
        let age = (model.snapshot?.date ?? Date()).timeIntervalSince(group.startTime)

        HoverRow { hovering in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    ProgramIcon(bundlePath: group.bundlePath)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(group.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            if flagged {
                                Circle().fill(.red).frame(width: 6, height: 6).help("See suggestion above")
                            }
                        }
                        // The directory may truncate; the age always stays visible.
                        HStack(spacing: 0) {
                            if let detail = group.detail {
                                Text(detail).lineLimit(1).truncationMode(.head)
                                Text(" · ").fixedSize()
                            }
                            Text("running \(DurationFormat.string(age))").fixedSize()
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(ByteFormat.string(group.footprint)).font(.callout).monospacedDigit()
                    if hasBreakdown {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    StopIconButton(
                        help: stoppable ? "\(target.verb) \(group.name)" : "System process: RamRadar won't stop it",
                        enabled: stoppable, highlighted: hovering
                    ) { model.requestStop(target) }
                }
                SizeBar(fraction: fraction, color: color)
                    .padding(.leading, 30)
                StopControls(target: target)
                    .padding(.leading, 30)
            }
        }
        .onTapGesture {
            if hasBreakdown { model.selectedGroupID = group.id }
        }
        .help(hasBreakdown ? "Show the \(group.processes.count) processes" : "")
    }
}
