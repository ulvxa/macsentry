import Foundation
import GRDB

public struct DirNode: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "dir_node"

    public var id: Int64?
    public var sessionID: Int64
    public var parentID: Int64?
    var path: String
    public var name: String
    public var depth: Int
    public var allocatedSize: Int64
    public var fileCount: Int64

    public var url: URL {
        get { URL(storagePath: path) }
        set { path = newValue.storagePath }
    }

    public init(
        id: Int64? = nil,
        sessionID: Int64,
        parentID: Int64? = nil,
        url: URL,
        name: String,
        depth: Int,
        allocatedSize: Int64,
        fileCount: Int64,
    ) {
        self.id = id
        self.sessionID = sessionID
        self.parentID = parentID
        path = url.storagePath
        self.name = name
        self.depth = depth
        self.allocatedSize = allocatedSize
        self.fileCount = fileCount
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case parentID = "parent_id"
        case path
        case name
        case depth
        case allocatedSize = "allocated_size"
        case fileCount = "file_count"
    }
}
