import Foundation
import Synchronization
@testable import MacSentryCore

let gigabyte: Int64 = 1_000_000_000

final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(start: Date = Date(timeIntervalSince1970: 1_728_000_000)) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    func set(_ date: Date) {
        current.withLock { $0 = date }
    }
}

final class TickGate: @unchecked Sendable {
    // Single consumer: only the monitor's loop task calls wait.
    private var iterator: AsyncStream<Void>.Iterator
    private let continuation: AsyncStream<Void>.Continuation
    private let intervals = Mutex<[Duration]>([])

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        iterator = stream.makeAsyncIterator()
        self.continuation = continuation
    }

    var requestedIntervals: [Duration] {
        intervals.withLock { $0 }
    }

    func tick() {
        continuation.yield()
    }

    func wait(_ interval: Duration) async throws {
        intervals.withLock { $0.append(interval) }
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }
}

func capacity(free gigabytes: Int64, total: Int64 = 500) -> VolumeCapacity {
    VolumeCapacity(total: total * gigabyte, available: gigabytes * gigabyte, importantAvailable: gigabytes * gigabyte)
}

func nextEvents(_ count: Int, from iterator: inout AsyncStream<DiskEvent>.Iterator) async -> [DiskEvent] {
    var events: [DiskEvent] = []
    while events.count < count, let event = await iterator.next() {
        events.append(event)
    }
    return events
}

enum EventTag: Equatable {
    case sample, crossed, recovered

    init(_ event: DiskEvent) {
        switch event {
        case .sample: self = .sample
        case .crossedBelowThreshold: self = .crossed
        case .recovered: self = .recovered
        }
    }
}
