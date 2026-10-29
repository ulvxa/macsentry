import Foundation
import GRDB

public struct IgnoredPath: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "ignored_path"

    var path: String
    public var createdAt: Date

    public var url: URL {
        get { URL(storagePath: path) }
        set { path = newValue.storagePath }
    }

    public init(url: URL, createdAt: Date) {
        path = url.storagePath
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case path
        case createdAt = "created_at"
    }
}
