import Foundation

public enum OrphanDetectorError: LocalizedError, Equatable {
    case allowlistMissing
    case allowlistInvalid(reason: String)

    public var errorDescription: String? {
        switch self {
        case .allowlistMissing:
            "The system allowlist is missing from the app bundle."
        case let .allowlistInvalid(reason):
            "The system allowlist is invalid: \(reason)"
        }
    }
}
