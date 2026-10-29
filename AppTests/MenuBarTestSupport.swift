import Foundation
import MacSentryCore
import Synchronization
@testable import MacSentry

actor TickGate {
    private var waiters: [CheckedContinuation<Void, any Error>] = []
    private var pendingTicks = 0

    func wait() async throws {
        if pendingTicks > 0 {
            pendingTicks -= 1
            return
        }
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func tick() {
        if waiters.isEmpty {
            pendingTicks += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date {
        current.withLock { $0 }
    }

    func advance(_ interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

final class RecordingNotifier: LowSpaceNotifier {
    struct State {
        var posts: [Int64] = []
        var requests = 0
        var status: NotificationAuthorization
        var statusAfterRequest: NotificationAuthorization
    }

    private let state: Mutex<State>

    init(status: NotificationAuthorization = .authorized, statusAfterRequest: NotificationAuthorization = .authorized) {
        state = Mutex(State(status: status, statusAfterRequest: statusAfterRequest))
    }

    var posts: [Int64] {
        state.withLock { $0.posts }
    }

    var requests: Int {
        state.withLock { $0.requests }
    }

    func authorization() async -> NotificationAuthorization {
        state.withLock { $0.status }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        state.withLock {
            $0.requests += 1
            $0.status = $0.statusAfterRequest
            return $0.status
        }
    }

    func postLowSpace(freeBytes: Int64, thresholdBytes _: Int64) async {
        state.withLock { $0.posts.append(freeBytes) }
    }

    func openSystemSettings() async {}
}

struct SilentLowSpaceNotifier: LowSpaceNotifier {
    func authorization() async -> NotificationAuthorization {
        .denied
    }

    func requestAuthorization() async -> NotificationAuthorization {
        .denied
    }

    func postLowSpace(freeBytes _: Int64, thresholdBytes _: Int64) async {}

    func openSystemSettings() async {}
}

@MainActor
final class FakeLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var registerResult: LoginItemStatus = .enabled
    var failure: (any Error)?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    func register() throws {
        registerCalls += 1
        if let failure {
            throw failure
        }
        status = registerResult
    }

    func unregister() throws {
        unregisterCalls += 1
        if let failure {
            throw failure
        }
        status = .notRegistered
    }

    func openSystemSettings() {}
}

func eventually(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
