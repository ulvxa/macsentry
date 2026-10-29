import Foundation
import Testing
@testable import MacSentryCore

struct DiskMonitorTests {
    private let interval: Duration = .seconds(15 * 60)

    private func makeMonitor(
        sampler: FakeVolumeSampler,
        clock: TestClock = TestClock(),
        gate: TickGate? = nil,
        settings: ThresholdSettings = ThresholdSettings(),
    ) throws -> DiskMonitor {
        try DiskMonitor(
            sampler: sampler,
            database: .inMemory(),
            settings: settings,
            sleep: { duration in
                if let gate {
                    try await gate.wait(duration)
                } else {
                    throw CancellationError()
                }
            },
            now: { clock.now },
        )
    }

    @Test func `stores one row per tick of the injected clock`() async throws {
        let clock = TestClock()
        let gate = TickGate()
        let sampler = FakeVolumeSampler(capacity(free: 100))
        let monitor = try makeMonitor(sampler: sampler, clock: clock, gate: gate)
        var iterator = monitor.events.makeAsyncIterator()

        await monitor.start(interval: interval)
        _ = await nextEvents(1, from: &iterator)
        let ticks = 8
        for _ in 0 ..< ticks {
            clock.advance(15 * 60)
            gate.tick()
            _ = await nextEvents(1, from: &iterator)
        }

        let rows = try await monitor.history(days: 1)
        #expect(rows.count == ticks + 1)
        let gaps = zip(rows, rows.dropFirst()).map { $1.sampledAt.timeIntervalSince($0.sampledAt) }
        #expect(gaps.allSatisfy { $0 == 15 * 60 })
        #expect(gate.requestedIntervals.allSatisfy { $0 == interval })
        await monitor.stop()
    }

    @Test func `sample row carries total available and important free`() async throws {
        let sampler = FakeVolumeSampler(VolumeCapacity(total: 500 * gigabyte, available: 90 * gigabyte, importantAvailable: 120 * gigabyte))
        let monitor = try makeMonitor(sampler: sampler)
        let sample = try await monitor.sampleNow()
        let rows = try await monitor.history(days: 1)
        #expect(rows == [sample])
        #expect(sample.totalBytes == 500 * gigabyte)
        #expect(sample.freeBytes == 90 * gigabyte)
        #expect(sample.importantFree == 120 * gigabyte)
    }

    @Test func `same timestamp collision keeps the latest sample`() async throws {
        let sampler = FakeVolumeSampler(capacity(free: 100))
        let monitor = try makeMonitor(sampler: sampler)
        try await monitor.sampleNow()
        sampler.set(capacity(free: 80))
        try await monitor.sampleNow()
        let rows = try await monitor.history(days: 1)
        #expect(rows.count == 1)
        #expect(rows.first?.importantFree == 80 * gigabyte)
    }

    @Test func `failed read skips the tick and the loop keeps running`() async throws {
        let clock = TestClock()
        let gate = TickGate()
        let sampler = FakeVolumeSampler(capacity(free: 100))
        let monitor = try makeMonitor(sampler: sampler, clock: clock, gate: gate)
        var iterator = monitor.events.makeAsyncIterator()

        await monitor.start(interval: interval)
        _ = await nextEvents(1, from: &iterator)
        sampler.enqueueFailure(.volumeValuesMissing(URL(filePath: "/")))
        clock.advance(900)
        gate.tick()
        clock.advance(900)
        gate.tick()
        let events = await nextEvents(1, from: &iterator)

        #expect(events.map(EventTag.init) == [.sample])
        #expect(try await monitor.history(days: 1).count == 2)
        await monitor.stop()
    }

    @Test func `stop halts sampling`() async throws {
        let gate = TickGate()
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 100)), gate: gate)
        var iterator = monitor.events.makeAsyncIterator()

        await monitor.start(interval: interval)
        _ = await nextEvents(1, from: &iterator)
        await monitor.stop()
        gate.tick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await monitor.history(days: 1).count == 1)
    }

    @Test func `sampleNow and handleWake store immediately without the clock`() async throws {
        let clock = TestClock()
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 100)), clock: clock)
        try await monitor.sampleNow()
        clock.advance(3 * 86400)
        await monitor.handleWake()
        let rows = try await monitor.history(days: 7)
        #expect(rows.count == 2)
    }

    @Test func `currentSample reads without storing or emitting`() async throws {
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 77)))
        let sample = try await monitor.currentSample()
        #expect(sample.importantFree == 77 * gigabyte)
        #expect(try await monitor.history(days: 1).isEmpty)
    }

    @Test func `retention prunes samples older than 90 days`() async throws {
        let clock = TestClock()
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 100)), clock: clock)
        let today = clock.now
        for daysAgo in [120.0, 91.0, 89.0, 10.0, 0.0] {
            clock.set(today.addingTimeInterval(-daysAgo * 86400))
            try await monitor.sampleNow()
        }
        clock.set(today)

        let removed = try await monitor.pruneSamples(olderThan: DiskMonitor.retention)
        let remaining = try await monitor.history(days: 365)
        #expect(removed == 2)
        #expect(remaining.count == 3)
        #expect(remaining.allSatisfy { $0.sampledAt >= today.addingTimeInterval(-90 * 86400) })
    }

    @Test func `prune defaults to 90 days and is a no op on fresh data`() async throws {
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 100)))
        try await monitor.sampleNow()
        #expect(try await monitor.pruneSamples() == 0)
        #expect(try await monitor.history(days: 1).count == 1)
    }

    @Test func `notification event fires once per crossing with hysteresis`() async throws {
        let clock = TestClock()
        let sampler = FakeVolumeSampler(capacity(free: 100))
        let monitor = try makeMonitor(sampler: sampler, clock: clock, settings: ThresholdSettings(thresholdBytes: 30 * gigabyte))
        var iterator = monitor.events.makeAsyncIterator()

        let script: [Int64] = [40, 29, 25, 20, 32, 35, 36, 28, 27, 40, 40]
        for free in script {
            clock.advance(900)
            sampler.set(capacity(free: free))
            try await monitor.sampleNow()
        }

        let events = await nextEvents(script.count + 4, from: &iterator)
        let expected: [EventTag] = [
            .sample, // 40
            .sample, .crossed, // 29
            .sample, // 25
            .sample, // 20
            .sample, // 32 still armed off
            .sample, // 35 not above 35
            .sample, .recovered, // 36
            .sample, .crossed, // 28
            .sample, // 27
            .sample, .recovered, // 40
            .sample, // 40
        ]
        #expect(events.map(EventTag.init) == expected)
        let crossings = events.compactMap { event -> Int64? in
            if case let .crossedBelowThreshold(sample) = event {
                sample.importantFree
            } else {
                nil
            }
        }
        #expect(crossings == [29 * gigabyte, 28 * gigabyte])
    }

    @Test func `first sample already below threshold fires exactly once`() async throws {
        let sampler = FakeVolumeSampler(capacity(free: 10))
        let monitor = try makeMonitor(sampler: sampler)
        var iterator = monitor.events.makeAsyncIterator()
        for _ in 0 ..< 3 {
            try await monitor.sampleNow()
        }
        let events = await nextEvents(4, from: &iterator)
        #expect(events.map(EventTag.init) == [.sample, .crossed, .sample, .sample])
    }

    @Test func `disabled threshold emits samples only and re arms on enable`() async throws {
        let sampler = FakeVolumeSampler(capacity(free: 10))
        let monitor = try makeMonitor(sampler: sampler, settings: ThresholdSettings(isEnabled: false))
        var iterator = monitor.events.makeAsyncIterator()
        try await monitor.sampleNow()
        try await monitor.sampleNow()
        await monitor.updateSettings(ThresholdSettings(isEnabled: true))
        try await monitor.sampleNow()
        try await monitor.sampleNow()
        let events = await nextEvents(5, from: &iterator)
        #expect(events.map(EventTag.init) == [.sample, .sample, .sample, .crossed, .sample])
    }

    @Test func `threshold updates apply to the next sample`() async throws {
        let sampler = FakeVolumeSampler(capacity(free: 50))
        let monitor = try makeMonitor(sampler: sampler)
        var iterator = monitor.events.makeAsyncIterator()
        try await monitor.sampleNow()
        await monitor.updateSettings(ThresholdSettings(thresholdBytes: 60 * gigabyte))
        try await monitor.sampleNow()
        let events = await nextEvents(3, from: &iterator)
        #expect(events.map(EventTag.init) == [.sample, .sample, .crossed])
    }

    @Test func `every subscriber receives every event`() async throws {
        let monitor = try makeMonitor(sampler: FakeVolumeSampler(capacity(free: 100)))
        var first = monitor.events.makeAsyncIterator()
        var second = monitor.events.makeAsyncIterator()
        try await monitor.sampleNow()
        #expect(await nextEvents(1, from: &first).count == 1)
        #expect(await nextEvents(1, from: &second).count == 1)
    }

    @Test func `system sampler reads the boot volume`() throws {
        let capacity = try SystemVolumeSampler().sample()
        #expect(capacity.total > 0)
        #expect(capacity.available >= 0)
        #expect(capacity.importantAvailable >= 0)
    }

    @Test func `system sampler reports a missing volume`() {
        let sampler = SystemVolumeSampler(volumeURL: URL(filePath: "/definitely/not/a/real/volume"))
        #expect(throws: DiskMonitorError.self) { try sampler.sample() }
    }
}
