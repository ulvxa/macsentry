import Foundation

public struct StubDuplicateFinder: DuplicateFinder {
    public var events: [DuplicateEvent]
    public var failure: DuplicateError?

    public init(events: [DuplicateEvent] = [.finished(DuplicateSummary())], failure: DuplicateError? = nil) {
        self.events = events
        self.failure = failure
    }

    public func find(sizeIndex _: SizeIndex, options _: DuplicateOptions) -> AsyncThrowingStream<DuplicateEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish(throwing: failure)
        }
    }
}
