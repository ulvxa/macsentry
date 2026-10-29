import Foundation

public enum GlobPatternError: LocalizedError, Equatable, Sendable {
    case empty
    case invalidCharacter
    case unsupportedSyntax(Character)
    case invalidDoubleStar(String)
    case relativeSegment(String)
    case userHomeNotSupported

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a path or pattern."
        case .invalidCharacter:
            "Patterns cannot contain control characters or line breaks."
        case let .unsupportedSyntax(character):
            "\"\(character)\" is not supported. Use *, ** and ? only."
        case let .invalidDoubleStar(segment):
            "\"\(segment)\" is invalid. ** must be a whole path segment, like ~/Work/**/secrets."
        case let .relativeSegment(segment):
            "\"\(segment)\" segments are not allowed in patterns."
        case .userHomeNotSupported:
            "Only ~ for your own home folder is supported, not ~user."
        }
    }
}

public enum GlobWarning: Sendable, Equatable {
    case protectsEverything

    public var message: String {
        switch self {
        case .protectsEverything:
            "This pattern protects everything. Scans will find nothing to clean."
        }
    }
}
