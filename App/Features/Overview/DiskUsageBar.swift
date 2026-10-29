import SwiftUI

struct DiskUsageBar: View {
    let breakdown: DiskUsageBreakdown

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let gap: CGFloat = contrast == .increased ? 1.5 : 2
        GeometryReader { proxy in
            HStack(spacing: gap) {
                ForEach(breakdown.barSlots(width: proxy.size.width, gap: gap, minimum: Space.xs)) { slot in
                    DiskSegmentFill(kind: slot.kind)
                        .frame(width: slot.width)
                        .help("\(slot.kind.title): \(ByteFormat.string(breakdown.bytes(for: slot.kind)))")
                }
            }
        }
        .frame(height: Space.l)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

struct DiskSegmentFill: View {
    let kind: DiskUsageBreakdown.Kind

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let boost = contrast == .increased ? 0.15 : 0
            switch kind {
            case .used:
                context.fill(Path(rect), with: .color(.primary.opacity(0.75 + boost)))
            case .reclaimable:
                context.fill(Path(rect), with: .color(.primary.opacity(0.5 + boost)))
                var hatch = Path()
                var offset = -size.height
                while offset < size.width {
                    hatch.move(to: CGPoint(x: offset, y: size.height))
                    hatch.addLine(to: CGPoint(x: offset + size.height, y: 0))
                    offset += 4
                }
                context.stroke(hatch, with: .style(.background), lineWidth: 1)
            case .quarantine:
                context.fill(Path(rect), with: .color(.primary.opacity(0.32 + boost)))
            case .trash:
                context.fill(Path(rect), with: .color(.primary.opacity(0.18 + boost)))
                var dots = Path()
                for row in stride(from: 1.25, to: size.height, by: 4) {
                    for column in stride(from: 1.25, to: size.width, by: 4) {
                        dots.addEllipse(in: CGRect(x: column, y: row, width: 1.5, height: 1.5))
                    }
                }
                context.fill(dots, with: .color(.primary.opacity(0.6 + boost)))
            case .free:
                context.fill(Path(rect), with: .style(.quaternary))
                context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.primary.opacity(0.25 + boost)), lineWidth: 1)
            }
        }
    }
}

struct DiskLegend: View {
    let breakdown: DiskUsageBreakdown

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.l) {
                ForEach(DiskUsageBreakdown.Kind.allCases) { kind in
                    item(kind)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
                GridRow {
                    item(.used)
                    item(.reclaimable)
                    item(.quarantine)
                }
                GridRow {
                    item(.trash)
                    item(.free)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Disk usage")
    }

    private func item(_ kind: DiskUsageBreakdown.Kind) -> some View {
        HStack(spacing: Space.s) {
            DiskSegmentFill(kind: kind)
                .frame(width: 10, height: 10)
                .clipShape(.rect(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if kind == .reclaimable, !breakdown.isScanned {
                    Text("Not scanned")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    SizeText(breakdown.bytes(for: kind))
                        .font(.callout.weight(.medium))
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
