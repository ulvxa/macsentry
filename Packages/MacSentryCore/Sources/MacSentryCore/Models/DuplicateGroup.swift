import Foundation
import GRDB

public struct DuplicateGroup: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "duplicate_group"

    public var id: Int64?
    public var sessionID: Int64
    public var contentHash: String
    public var fileSize: Int64
    public var memberCount: Int
    public var reclaimableSize: Int64
    var keeperPath: String

    public var keeperURL: URL {
        get { URL(storagePath: keeperPath) }
        set { keeperPath = newValue.storagePath }
    }

    public init(
        id: Int64? = nil,
        sessionID: Int64,
        contentHash: String,
        fileSize: Int64,
        memberCount: Int,
        reclaimableSize: Int64,
        keeperURL: URL,
    ) {
        self.id = id
        self.sessionID = sessionID
        self.contentHash = contentHash
        self.fileSize = fileSize
        self.memberCount = memberCount
        self.reclaimableSize = reclaimableSize
        keeperPath = keeperURL.storagePath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case contentHash = "content_hash"
        case fileSize = "file_size"
        case memberCount = "member_count"
        case reclaimableSize = "reclaimable_size"
        case keeperPath = "keeper_path"
    }
}
