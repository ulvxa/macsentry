import Foundation

public enum FixtureError: LocalizedError, Equatable {
    case invalidRelativePath(String)
    case systemCall(String, path: String, errno: Int32)
    case fileSystem(String, path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            "Fixture path must be relative and stay inside the fixture root: \(path)"
        case let .systemCall(call, path, code):
            "\(call) failed for \(path): \(String(cString: strerror(code)))"
        case let .fileSystem(operation, path, reason):
            "\(operation) failed for \(path): \(reason)"
        }
    }
}
