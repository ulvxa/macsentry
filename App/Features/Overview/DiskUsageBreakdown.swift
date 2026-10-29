import CoreGraphics
import Foundation
import MacSentryCore

struct DiskUsageBreakdown: Equatable {
    enum Kind: CaseIterable, Identifiable {
        case used, reclaimable, quarantine, trash, free

        var id: Self {
            self
        }

        var title: String {
            switch self {
            case .used: "Used"
            case .reclaimable: "Reclaimable"
            case .quarantine: "In quarantine"
            case .trash: "In Trash"
            case .free: "Free"
            }
        }
    }

    struct Segment: Identifiable, Equatable {
        let kind: Kind
        let bytes: Int64

        var id: Kind {
            kind
        }
    }

    let total: Int64
    let free: Int64
    let used: Int64
    let reclaimable: Int64
    let quarantine: Int64
    let trash: Int64
    let isScanned: Bool

    /// Quarantine, Trash and Reclaimable are carved out of used space in that order, each clamped to what is left.
    init(total: Int64, free: Int64, reclaimable: Int64?, quarantine: Int64, trash: Int64) {
        isScanned = reclaimable != nil
        let total = max(total, 0)
        let free = min(max(free, 0), total)
        var remaining = total - free
        let quarantine = min(max(quarantine, 0), remaining)
        remaining -= quarantine
        let trash = min(max(trash, 0), remaining)
        remaining -= trash
        let reclaimable = min(max(reclaimable ?? 0, 0), remaining)
        remaining -= reclaimable
        self.total = total
        self.free = free
        self.quarantine = quarantine
        self.trash = trash
        self.reclaimable = reclaimable
        used = remaining
    }

    init(capacity: VolumeCapacity, reclaimable: Int64?, quarantine: QuarantineTotals?) {
        self.init(
            total: capacity.total,
            free: capacity.importantAvailable,
            reclaimable: reclaimable,
            quarantine: quarantine?.inQuarantine ?? 0,
            trash: quarantine?.inTrash ?? 0,
        )
    }

    var segments: [Segment] {
        Kind.allCases.map { Segment(kind: $0, bytes: bytes(for: $0)) }
    }

    func bytes(for kind: Kind) -> Int64 {
        switch kind {
        case .used: used
        case .reclaimable: reclaimable
        case .quarantine: quarantine
        case .trash: trash
        case .free: free
        }
    }

    func fraction(for kind: Kind) -> Double {
        total > 0 ? Double(bytes(for: kind)) / Double(total) : 0
    }

    var freeFraction: Double {
        fraction(for: .free)
    }
}

extension DiskUsageBreakdown {
    struct BarSlot: Identifiable, Equatable {
        let kind: Kind
        let width: CGFloat

        var id: Kind {
            kind
        }
    }

    func barSlots(width: CGFloat, gap: CGFloat, minimum: CGFloat) -> [BarSlot] {
        let visible = segments.filter { $0.bytes > 0 }
        let available = width - gap * CGFloat(max(visible.count - 1, 0))
        guard total > 0, available > minimum * CGFloat(visible.count) else { return [] }
        var widths = visible.map { max(CGFloat(Double($0.bytes) / Double(total)) * available, minimum) }
        let excess = widths.reduce(0, +) - available
        if excess > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] -= excess
        }
        return zip(visible, widths).map { BarSlot(kind: $0.kind, width: $1) }
    }
}
