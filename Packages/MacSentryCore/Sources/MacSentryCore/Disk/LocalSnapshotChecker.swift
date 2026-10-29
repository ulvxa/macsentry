import Foundation
import Synchronization

public enum LocalSnapshotError: LocalizedError, Equatable {
    case launchFailed(String)
    case timedOut
    case failed(status: Int32)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(reason):
            "Could not list local snapshots: \(reason)"
        case .timedOut:
            "Listing local snapshots took too long."
        case let .failed(status):
            "Listing local snapshots failed with status \(status)."
        }
    }
}

public protocol LocalSnapshotChecker: Sendable {
    func localSnapshotCount() async throws(LocalSnapshotError) -> Int
}

public struct TmutilLocalSnapshotChecker: LocalSnapshotChecker {
    public static let defaultTimeout: Duration = .seconds(3)

    public let executableURL: URL
    public let volumeURL: URL
    public let timeout: Duration

    public init(
        executableURL: URL = URL(filePath: "/usr/bin/tmutil"),
        volumeURL: URL = URL(filePath: "/"),
        timeout: Duration = TmutilLocalSnapshotChecker.defaultTimeout,
    ) {
        self.executableURL = executableURL
        self.volumeURL = volumeURL
        self.timeout = timeout
    }

    public static func parseSnapshotCount(_ output: String) -> Int {
        output.split(whereSeparator: \.isNewline).count { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("com.apple.") && !trimmed.hasSuffix(":")
        }
    }

    public func localSnapshotCount() async throws(LocalSnapshotError) -> Int {
        let state = SnapshotProcessState()
        let output = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["listlocalsnapshots", volumeURL.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { state.append($0.availableData) }

        let timeout = timeout
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, state.markTimedOut() else { return }
            process.terminate()
        }
        defer { timeoutTask.cancel() }

        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: state.markFinished() ? finished.terminationStatus : nil)
                }
                do {
                    try process.run()
                    state.markLaunched()
                } catch {
                    process.terminationHandler = nil
                    state.launchError = error.localizedDescription
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            if state.markTimedOut() {
                process.terminate()
            }
        }

        output.fileHandleForReading.readabilityHandler = nil
        state.append((try? output.fileHandleForReading.readToEnd()) ?? Data())
        if let reason = state.launchError {
            throw .launchFailed(reason)
        }
        guard let status else { throw .timedOut }
        guard status == 0 else { throw .failed(status: status) }
        return Self.parseSnapshotCount(state.text)
    }
}

private final class SnapshotProcessState: Sendable {
    private struct Values {
        var data = Data()
        var launched = false
        var finished = false
        var timedOut = false
        var launchError: String?
    }

    private let values = Mutex(Values())

    var text: String {
        values.withLock { String(bytes: $0.data, encoding: .utf8) ?? "" }
    }

    var launchError: String? {
        get { values.withLock { $0.launchError } }
        set { values.withLock { $0.launchError = newValue } }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        values.withLock { $0.data.append(data) }
    }

    func markLaunched() {
        values.withLock { $0.launched = true }
    }

    func markFinished() -> Bool {
        values.withLock { state in
            state.finished = true
            return !state.timedOut
        }
    }

    func markTimedOut() -> Bool {
        values.withLock { state in
            guard state.launched, !state.finished else { return false }
            state.timedOut = true
            return true
        }
    }
}

public struct StubLocalSnapshotChecker: LocalSnapshotChecker {
    public var result: Result<Int, LocalSnapshotError>

    public init(count: Int) {
        result = .success(count)
    }

    public init(error: LocalSnapshotError) {
        result = .failure(error)
    }

    public func localSnapshotCount() async throws(LocalSnapshotError) -> Int {
        try result.get()
    }
}
