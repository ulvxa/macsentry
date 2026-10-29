import Foundation

public protocol DuplicateFinder: Sendable {
    func find(sizeIndex: SizeIndex, options: DuplicateOptions) -> AsyncThrowingStream<DuplicateEvent, Error>
}

public enum DuplicateEvent: Sendable, Equatable {
    case hashing(done: Int, total: Int, bytes: Int64)
    case group(DuplicateGroup, members: [Candidate])
    case finished(DuplicateSummary)
}

public struct DuplicateSummary: Sendable, Equatable {
    public var groupCount = 0
    public var filesHashed = 0
    public var bytesHashed: Int64 = 0
    public var datalessSkipped = 0
    public var unreadable: [URL] = []
    public var changedDuringHashing: [URL] = []

    public init() {}
}

public enum DuplicateError: Error, LocalizedError, Equatable {
    case unreadable(URL, errno: Int32)
    case keeperNotInGroup(URL)
    case groupNotFound(Int64)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(url, code):
            "Could not read \(url.path(percentEncoded: false)): \(String(cString: strerror(code)))"
        case let .keeperNotInGroup(url):
            "\(url.lastPathComponent) is not a member of this duplicate group"
        case let .groupNotFound(id):
            "Duplicate group \(id) no longer exists"
        case let .storage(reason):
            "Could not save duplicates: \(reason)"
        }
    }
}

public extension DuplicateGroup {
    static let ruleID = "duplicate.content"

    var isSpaceEfficient: Bool {
        reclaimableSize * 20 < fileSize * Int64(max(memberCount - 1, 1))
    }
}
