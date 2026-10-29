import Foundation
import Synchronization

final class DiskEventBroadcaster: Sendable {
    private let continuations = Mutex<[UUID: AsyncStream<DiskEvent>.Continuation]>([:])

    func stream() -> AsyncStream<DiskEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiskEvent.self)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.continuations.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ event: DiskEvent) {
        let targets = continuations.withLock { Array($0.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    func finish() {
        let targets = continuations.withLock { state in
            defer { state.removeAll() }
            return Array(state.values)
        }
        for continuation in targets {
            continuation.finish()
        }
    }
}
