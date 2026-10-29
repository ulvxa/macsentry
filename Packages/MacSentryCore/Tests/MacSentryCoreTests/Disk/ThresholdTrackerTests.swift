import Testing
@testable import MacSentryCore

struct ThresholdTrackerTests {
    private let threshold = 30 * gigabyte

    private func run(_ freeGB: [Int64]) -> [ThresholdTracker.Transition?] {
        var tracker = ThresholdTracker()
        return freeGB.map { tracker.update(importantFree: $0 * gigabyte, thresholdBytes: threshold) }
    }

    @Test func `fires once when crossing below and stays quiet while below`() {
        let result = run([40, 35, 29, 25, 10, 29])
        #expect(result == [nil, nil, .crossedBelow, nil, nil, nil])
    }

    @Test func `exactly at threshold is not below`() {
        #expect(run([30]) == [nil])
    }

    @Test func `first sample already below fires once`() {
        #expect(run([12, 11, 10]) == [.crossedBelow, nil, nil])
    }

    @Test func `does not re arm until above threshold plus 5 GB`() {
        let result = run([20, 31, 34, 35, 28, 20])
        #expect(result == [.crossedBelow, nil, nil, nil, nil, nil])
    }

    @Test func `recovers above hysteresis then fires again on next crossing`() {
        let result = run([20, 36, 40, 29, 28, 36, 20])
        #expect(result == [.crossedBelow, .recovered, nil, .crossedBelow, nil, .recovered, .crossedBelow])
    }

    @Test func `reset re arms from the initial state`() {
        var tracker = ThresholdTracker()
        _ = tracker.update(importantFree: 10 * gigabyte, thresholdBytes: threshold)
        tracker.reset()
        #expect(tracker.update(importantFree: 10 * gigabyte, thresholdBytes: threshold) == .crossedBelow)
    }
}
