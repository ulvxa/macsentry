import Foundation

public enum DatabaseOpenError: LocalizedError, Equatable {
    case cannotCreateDirectory(URL, reason: String)
    case cannotMoveCorruptFile(URL, reason: String)
    case openFailed(URL?, reason: String)
    case migrationFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .cannotCreateDirectory(url, reason):
            "Could not create the database folder at \(url.path(percentEncoded: false)): \(reason)"
        case let .cannotMoveCorruptFile(url, reason):
            "Could not move the damaged database at \(url.path(percentEncoded: false)) aside: \(reason)"
        case let .openFailed(url, reason):
            "Could not open the database\(url.map { " at \($0.path(percentEncoded: false))" } ?? ""): \(reason)"
        case let .migrationFailed(reason):
            "Could not upgrade the database: \(reason)"
        }
    }
}
