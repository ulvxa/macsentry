import CoreGraphics
import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

struct OverviewDiskUsageTests {
    private static let gigabyte: Int64 = 1_000_000_000

    private static func sum(_ breakdown: DiskUsageBreakdown) -> Int64 {
        breakdown.segments.reduce(0) { $0 + $1.bytes }
    }

    @Test func `segments partition the capacity with reclaimable quarantine and trash inside used`() {
        let breakdown = DiskUsageBreakdown(
            total: 500 * Self.gigabyte,
            free: 200 * Self.gigabyte,
            reclaimable: 80 * Self.gigabyte,
            quarantine: 4 * Self.gigabyte,
            trash: 2 * Self.gigabyte,
        )
        #expect(breakdown.segments.map(\.kind) == [.used, .reclaimable, .quarantine, .trash, .free])
        #expect(breakdown.used == 214 * Self.gigabyte)
        #expect(breakdown.reclaimable == 80 * Self.gigabyte)
        #expect(breakdown.quarantine == 4 * Self.gigabyte)
        #expect(breakdown.trash == 2 * Self.gigabyte)
        #expect(breakdown.free == 200 * Self.gigabyte)
        #expect(Self.sum(breakdown) == breakdown.total)
        #expect(breakdown.freeFraction == 0.4)
        #expect(breakdown.isScanned)
    }

    @Test func `oversized parts are clamped so the bar never exceeds capacity`() {
        let breakdown = DiskUsageBreakdown(
            total: 100 * Self.gigabyte,
            free: 90 * Self.gigabyte,
            reclaimable: 50 * Self.gigabyte,
            quarantine: 6 * Self.gigabyte,
            trash: 7 * Self.gigabyte,
        )
        #expect(breakdown.quarantine == 6 * Self.gigabyte)
        #expect(breakdown.trash == 4 * Self.gigabyte)
        #expect(breakdown.reclaimable == 0)
        #expect(breakdown.used == 0)
        #expect(Self.sum(breakdown) == breakdown.total)

        let freeOverflow = DiskUsageBreakdown(total: 10, free: 50, reclaimable: 3, quarantine: -1, trash: 0)
        #expect(freeOverflow.free == 10)
        #expect(freeOverflow.quarantine == 0)
        #expect(Self.sum(freeOverflow) == 10)

        let empty = DiskUsageBreakdown(total: -5, free: 1, reclaimable: nil, quarantine: 1, trash: 1)
        #expect(Self.sum(empty) == 0)
        #expect(empty.freeFraction == 0)
        #expect(!empty.isScanned)
        #expect(empty.barSlots(width: 400, gap: 2, minimum: 4).isEmpty)
    }

    @Test func `capacity uses important free space and quarantine totals`() {
        let capacity = VolumeCapacity(total: 500 * Self.gigabyte, available: 150 * Self.gigabyte, importantAvailable: 212 * Self.gigabyte)
        let totals = QuarantineTotals(inQuarantine: 3 * Self.gigabyte, inTrash: Self.gigabyte, freedThisMonth: 0, dryRunInQuarantine: 9)
        let breakdown = DiskUsageBreakdown(capacity: capacity, reclaimable: nil, quarantine: totals)
        #expect(breakdown.free == 212 * Self.gigabyte)
        #expect(breakdown.quarantine == 3 * Self.gigabyte)
        #expect(breakdown.trash == Self.gigabyte)
        #expect(breakdown.reclaimable == 0)
        #expect(!breakdown.isScanned)
    }

    @Test func `bar slots keep tiny segments visible and fill the width`() {
        let breakdown = DiskUsageBreakdown(total: 1000, free: 500, reclaimable: 1, quarantine: 0, trash: 0)
        let slots = breakdown.barSlots(width: 402, gap: 2, minimum: 4)
        #expect(slots.map(\.kind) == [.used, .reclaimable, .free])
        #expect(slots.first { $0.kind == .reclaimable }?.width == 4)
        let filled = slots.reduce(CGFloat(0)) { $0 + $1.width } + 2 * CGFloat(slots.count - 1)
        #expect(abs(filled - 402) < 0.001)
    }
}
