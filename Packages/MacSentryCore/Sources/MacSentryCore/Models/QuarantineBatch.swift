import Foundation
import GRDB

public struct QuarantineBatch: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "quarantine_batch"

    public var id: Int64?
    public var folderName: String
    public var createdAt: Date
    public var dryRun: Bool

    public init(id: Int64? = nil, folderName: String, createdAt: Date, dryRun: Bool = false) {
        self.id = id
        self.folderName = folderName
        self.createdAt = createdAt
        self.dryRun = dryRun
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case folderName = "folder_name"
        case createdAt = "created_at"
        case dryRun = "dry_run"
    }
}
