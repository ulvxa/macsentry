import Foundation
import GRDB

public struct NeverTouchPattern: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "never_touch"

    public var id: Int64?
    public var pattern: String
    public var note: String?
    public var createdAt: Date

    public init(id: Int64? = nil, pattern: String, note: String? = nil, createdAt: Date) {
        self.id = id
        self.pattern = pattern
        self.note = note
        self.createdAt = createdAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case pattern
        case note
        case createdAt = "created_at"
    }
}
