import Foundation
import Testing
@testable import MacSentryCore

struct SparklineTests {
    private static let base = Date(timeIntervalSince1970: 1_728_000_000)
    private static let bucket: TimeInterval = 6 * 3600

    private func sample(bucketIndex: Int, offset: TimeInterval = 0, freeGB: Int64) -> DiskSample {
        DiskSample(
            sampledAt: Self.base.addingTimeInterval(Double(bucketIndex) * Self.bucket + offset),
            totalBytes: 500 * gigabyte,
            freeBytes: freeGB * gigabyte,
            importantFree: freeGB * gigabyte,
        )
    }

    @Test func `groups samples into 6 hour buckets using the mean`() {
        let samples = [
            sample(bucketIndex: 0, offset: 0, freeGB: 100),
            sample(bucketIndex: 0, offset: 3600, freeGB: 200),
            sample(bucketIndex: 1, offset: 10, freeGB: 300),
        ]
        let line = Sparkline.make(samples: samples)
        #expect(line.points.count == 2)
        #expect(line.points[0] == SparklinePoint(bucketStart: Self.base, freeBytes: 150 * gigabyte, sampleCount: 2))
        #expect(line.points[1].bucketStart == Self.base.addingTimeInterval(Self.bucket))
        #expect(line.points[1].freeBytes == 300 * gigabyte)
    }

    @Test func `sample exactly on a boundary belongs to the later bucket`() {
        let line = Sparkline.make(samples: [
            sample(bucketIndex: 0, offset: Self.bucket - 1, freeGB: 100),
            sample(bucketIndex: 1, offset: 0, freeGB: 200),
        ])
        #expect(line.points.map(\.freeBytes) == [100 * gigabyte, 200 * gigabyte])
    }

    @Test func `empty buckets stay as gaps and split segments`() {
        let line = Sparkline.make(samples: [
            sample(bucketIndex: 0, freeGB: 100),
            sample(bucketIndex: 1, freeGB: 90),
            sample(bucketIndex: 4, freeGB: 50),
            sample(bucketIndex: 5, freeGB: 60),
            sample(bucketIndex: 9, freeGB: 70),
        ])
        #expect(line.points.count == 5)
        #expect(line.segments.map(\.count) == [2, 2, 1])
    }

    @Test func `min and max come from the drawn points`() {
        let line = Sparkline.make(samples: [
            sample(bucketIndex: 3, freeGB: 80),
            sample(bucketIndex: 0, freeGB: 300),
            sample(bucketIndex: 7, freeGB: 40),
        ])
        #expect(line.minPoint?.freeBytes == 40 * gigabyte)
        #expect(line.maxPoint?.freeBytes == 300 * gigabyte)
        #expect(line.points.map(\.bucketStart) == line.points.map(\.bucketStart).sorted())
    }

    @Test func `no samples gives empty sparkline`() {
        let line = Sparkline.make(samples: [])
        #expect(line.points.isEmpty)
        #expect(line.minPoint == nil)
        #expect(line.maxPoint == nil)
        #expect(line.segments.isEmpty)
    }

    @Test func `monitor sparkline only covers the requested window`() async throws {
        let clock = TestClock()
        let sampler = FakeVolumeSampler(capacity(free: 100))
        let monitor = try DiskMonitor(sampler: sampler, database: .inMemory(), now: { clock.now })
        let start = clock.now

        clock.set(start.addingTimeInterval(-40 * 86400))
        try await monitor.sampleNow()
        for day in [-20.0, -10.0, 0.0] {
            clock.set(start.addingTimeInterval(day * 86400))
            sampler.set(capacity(free: 100 + Int64(-day)))
            try await monitor.sampleNow()
        }

        let line = try await monitor.sparkline(days: 30)
        #expect(line.points.count == 3)
        #expect(line.points.map(\.freeBytes) == [120 * gigabyte, 110 * gigabyte, 100 * gigabyte])
        #expect(line.segments.count == 3)
    }
}
