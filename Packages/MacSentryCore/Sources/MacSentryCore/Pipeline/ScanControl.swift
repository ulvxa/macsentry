import Foundation
import Synchronization

public struct HashingProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public let bytes: Int64

    public init(done: Int, total: Int, bytes: Int64) {
        self.done = done
        self.total = total
        self.bytes = bytes
    }
}

public final class ScanControl: Sendable {
    private struct State {
        var skipped = false
        var cancelHashing: (@Sendable () -> Void)?
        var cancelled = false
        var cancelScan: (@Sendable () -> Void)?
    }

    public let hashingProgress: AsyncStream<HashingProgress>
    private let continuation: AsyncStream<HashingProgress>.Continuation
    private let state = Mutex(State())

    public init() {
        (hashingProgress, continuation) = AsyncStream.makeStream(of: HashingProgress.self, bufferingPolicy: .bufferingNewest(1))
    }

    public var isDuplicatesSkipped: Bool {
        state.withLock(\.skipped)
    }

    public func skipDuplicates() {
        let cancel = state.withLock { state in
            state.skipped = true
            return state.cancelHashing
        }
        cancel?()
    }

    public var isCancelled: Bool {
        state.withLock(\.cancelled)
    }

    /// False when no scan registered a handler, so the caller has to cancel its consuming task instead.
    @discardableResult
    public func cancel() -> Bool {
        let cancel = state.withLock { state in
            state.cancelled = true
            return state.cancelScan
        }
        cancel?()
        return cancel != nil
    }

    /// Scan services call this to stop their work and then finish their stream once their state is saved.
    public func attachCancel(_ cancel: @escaping @Sendable () -> Void) {
        let cancelled = state.withLock { state in
            state.cancelScan = cancel
            return state.cancelled
        }
        if cancelled {
            cancel()
        }
    }

    func attachHashing(cancel: @escaping @Sendable () -> Void) {
        let skipped = state.withLock { state in
            state.cancelHashing = cancel
            return state.skipped
        }
        if skipped {
            cancel()
        }
    }

    func detachHashing() {
        state.withLock { $0.cancelHashing = nil }
    }

    func report(_ progress: HashingProgress) {
        continuation.yield(progress)
    }

    func end() {
        continuation.finish()
    }
}
