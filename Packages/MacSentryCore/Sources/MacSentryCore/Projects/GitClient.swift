import Foundation
import Synchronization

public enum GitError: LocalizedError, Equatable {
    case gitNotFound
    case timedOut
    case launchFailed(String)
    case failed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .gitNotFound:
            "Git is not installed."
        case .timedOut:
            "Git did not answer in time."
        case let .launchFailed(reason):
            "Could not run git: \(reason)"
        case let .failed(status, message):
            "Git failed with status \(status): \(message)"
        }
    }
}

public protocol GitClient: Sendable {
    func lastCommitDate(in repository: URL) async throws(GitError) -> Date?
    func hasUncommittedChanges(in repository: URL) async throws(GitError) -> Bool
}

public struct ProcessGitClient: GitClient {
    public static let defaultTimeout: Duration = .seconds(3)

    /// `/usr/bin/git` is an xcrun shim that pops the Command Line Tools installer when they are missing.
    public static let knownLocations: [URL] = [
        URL(filePath: "/Library/Developer/CommandLineTools/usr/bin/git"),
        URL(filePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git"),
        URL(filePath: "/opt/homebrew/bin/git"),
        URL(filePath: "/usr/local/bin/git"),
    ]

    public let executableURL: URL?
    public let timeout: Duration
    public let environmentOverrides: [String: String]

    public init(
        executableURL: URL? = ProcessGitClient.locateGit(),
        timeout: Duration = ProcessGitClient.defaultTimeout,
        environmentOverrides: [String: String] = [:],
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.environmentOverrides = environmentOverrides
    }

    public static func locateGit(in candidates: [URL] = knownLocations) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
    }

    public func lastCommitDate(in repository: URL) async throws(GitError) -> Date? {
        let output = try await run(["log", "-1", "--format=%ct"], in: repository)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(text).map(Date.init(timeIntervalSince1970:))
    }

    public func hasUncommittedChanges(in repository: URL) async throws(GitError) -> Bool {
        let output = try await run(["status", "--porcelain", "--untracked-files=no"], in: repository)
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func run(_ arguments: [String], in repository: URL) async throws(GitError) -> String {
        guard let executableURL else { throw .gitNotFound }
        let collector = OutputCollector()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = makeProcess(executableURL, arguments: arguments, in: repository, output: (stdout, stderr), collector: collector)

        let timeout = timeout
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, collector.markTimedOut() else { return }
            process.terminate()
        }
        defer { timeoutTask.cancel() }

        let status: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
                process.terminationHandler = { finished in
                    continuation.resume(returning: collector.markFinished() ? finished.terminationStatus : nil)
                }
                do {
                    try process.run()
                    collector.markLaunched()
                } catch {
                    process.terminationHandler = nil
                    collector.launchError = error.localizedDescription
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            if collector.markTimedOut() {
                process.terminate()
            }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        collector.append((try? stdout.fileHandleForReading.readToEnd()) ?? Data(), to: \.out)
        collector.append((try? stderr.fileHandleForReading.readToEnd()) ?? Data(), to: \.err)

        if let reason = collector.launchError {
            throw .launchFailed(reason)
        }
        guard let status else { throw .timedOut }
        let output = collector.output
        guard status == 0 else {
            throw .failed(status: status, message: output.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.out
    }

    private func makeProcess(
        _ executableURL: URL,
        arguments: [String],
        in repository: URL,
        output: (out: Pipe, err: Pipe),
        collector: OutputCollector,
    ) -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", repository.path(percentEncoded: false)]
            + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.merge(environmentOverrides) { $1 }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output.out
        process.standardError = output.err
        output.out.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, to: \.out) }
        output.err.fileHandleForReading.readabilityHandler = { collector.append($0.availableData, to: \.err) }
        return process
    }
}

private final class OutputCollector: Sendable {
    struct Buffers {
        var out = Data()
        var err = Data()
        var launched = false
        var finished = false
        var timedOut = false
        var launchError: String?
    }

    private let state = Mutex(Buffers())

    var output: (out: String, err: String) {
        state.withLock { (String(bytes: $0.out, encoding: .utf8) ?? "", String(bytes: $0.err, encoding: .utf8) ?? "") }
    }

    var launchError: String? {
        get { state.withLock { $0.launchError } }
        set { state.withLock { $0.launchError = newValue } }
    }

    func append(_ data: Data, to keyPath: WritableKeyPath<Buffers, Data> & Sendable) {
        guard !data.isEmpty else { return }
        state.withLock { $0[keyPath: keyPath].append(data) }
    }

    func markLaunched() {
        state.withLock { $0.launched = true }
    }

    func markFinished() -> Bool {
        state.withLock { buffers in
            buffers.finished = true
            return !buffers.timedOut
        }
    }

    func markTimedOut() -> Bool {
        state.withLock { buffers in
            guard buffers.launched, !buffers.finished else { return false }
            buffers.timedOut = true
            return true
        }
    }
}
