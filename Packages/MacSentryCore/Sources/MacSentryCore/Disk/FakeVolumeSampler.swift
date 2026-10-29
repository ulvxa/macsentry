import Foundation
import Synchronization

public final class FakeVolumeSampler: VolumeSampler {
    private struct State {
        var queue: [Result<VolumeCapacity, DiskMonitorError>]
        var last: VolumeCapacity
    }

    private let state: Mutex<State>

    public init(_ initial: VolumeCapacity) {
        state = Mutex(State(queue: [], last: initial))
    }

    public convenience init(total: Int64, free: Int64, importantFree: Int64? = nil) {
        self.init(VolumeCapacity(total: total, available: free, importantAvailable: importantFree ?? free))
    }

    public func enqueue(_ capacities: VolumeCapacity...) {
        state.withLock { $0.queue.append(contentsOf: capacities.map { .success($0) }) }
    }

    public func enqueueFailure(_ error: DiskMonitorError) {
        state.withLock { $0.queue.append(.failure(error)) }
    }

    public func set(_ capacity: VolumeCapacity) {
        state.withLock {
            $0.queue.removeAll()
            $0.last = capacity
        }
    }

    public func sample() throws -> VolumeCapacity {
        try state.withLock { state in
            guard !state.queue.isEmpty else { return state.last }
            let next = try state.queue.removeFirst().get()
            state.last = next
            return next
        }
    }
}
