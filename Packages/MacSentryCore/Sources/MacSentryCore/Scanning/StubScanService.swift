import Foundation

public struct StubScanService: ScanService {
    public let events: [ScanEvent]
    public let error: ScanError?

    public init(events: [ScanEvent], error: ScanError? = nil) {
        self.events = events
        self.error = error
    }

    public func scan(config _: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        for event in events {
            continuation.yield(event)
        }
        continuation.finish(throwing: error)
        return stream
    }
}
