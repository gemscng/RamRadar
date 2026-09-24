import RamRadarCore
import SwiftUI

/// Total memory, pressure, and the Activity Monitor-style split of what's using it.
struct SystemHeader: View {
    let system: SystemMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(ByteFormat.string(system.used)) of \(ByteFormat.string(system.physical))")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                PressurePill(level: system.pressure)
            }
            MemoryBar(system: system)
            HStack(spacing: 12) {
                LegendItem(color: Palette.app, label: "Apps", value: system.appMemory)
                LegendItem(color: Palette.wired, label: "Wired", value: system.wired)
                LegendItem(color: Palette.compressed, label: "Compressed", value: system.compressed)
                LegendItem(color: Palette.cached, label: "Cached", value: system.cached)
                Spacer(minLength: 0)
            }
            if system.swapUsed > 0 {
                Text("Swap: \(ByteFormat.string(system.swapUsed)) on disk")
                    .font(.caption)
                    .foregroundStyle(system.pressure > .normal ? Palette.pressure(system.pressure) : .secondary)
            }
        }
    }
}

struct PressurePill: View {
    let level: PressureLevel

    var body: some View {
        let color = Palette.pressure(level)
        let text: String = switch level {
        case .normal: "Pressure normal"
        case .warning: "Pressure high"
        case .critical: "Pressure critical"
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct MemoryBar: View {
    let system: SystemMemory

    var body: some View {
        let total = Double(max(system.physical, 1))
        let segments: [(Color, UInt64)] = [
            (Palette.app, system.appMemory), (Palette.wired, system.wired),
            (Palette.compressed, system.compressed), (Palette.cached, system.cached),
        ]
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments.indices, id: \.self) { i in
                    Rectangle()
                        .fill(segments[i].0)
                        .frame(width: max(0, geo.size.width * CGFloat(Double(segments[i].1) / total)))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct LegendItem: View {
    let color: Color
    let label: String
    let value: UInt64

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(label) \(ByteFormat.string(value))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
