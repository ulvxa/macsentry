import Foundation
import GRDB

public struct Project: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "project"

    public var id: Int64?
    public var sessionID: Int64
    var rootPath: String
    public var name: String
    public var ecosystems: [String]
    public var lastCommitAt: Date?
    public var lastModifiedAt: Date
    public var hasUncommitted: Bool
    public var artifactsSize: Int64

    public var rootURL: URL {
        get { URL(storagePath: rootPath) }
        set { rootPath = newValue.storagePath }
    }

    public init(
        id: Int64? = nil,
        sessionID: Int64,
        rootURL: URL,
        name: String,
        ecosystems: [String],
        lastCommitAt: Date? = nil,
        lastModifiedAt: Date,
        hasUncommitted: Bool = false,
        artifactsSize: Int64,
    ) {
        self.id = id
        self.sessionID = sessionID
        rootPath = rootURL.storagePath
        self.name = name
        self.ecosystems = ecosystems
        self.lastCommitAt = lastCommitAt
        self.lastModifiedAt = lastModifiedAt
        self.hasUncommitted = hasUncommitted
        self.artifactsSize = artifactsSize
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case rootPath = "root_path"
        case name
        case ecosystems = "ecosystems_json"
        case lastCommitAt = "last_commit_at"
        case lastModifiedAt = "last_modified_at"
        case hasUncommitted = "has_uncommitted"
        case artifactsSize = "artifacts_size"
    }
}
