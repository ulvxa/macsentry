import Foundation
import GRDB

public struct ScanSession: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "scan_session"

    public var id: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: ScanStatus
    var rootPaths: [String]
    public var filesVisited: Int64
    public var bytesVisited: Int64
    public var error: String?

    public var roots: [URL] {
        get { rootPaths.map(URL.init(storagePath:)) }
        set { rootPaths = newValue.map(\.storagePath) }
    }

    public init(
        id: Int64? = nil,
        startedAt: Date,
        finishedAt: Date? = nil,
        status: ScanStatus,
        roots: [URL],
        filesVisited: Int64 = 0,
        bytesVisited: Int64 = 0,
        error: String? = nil,
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        rootPaths = roots.map(\.storagePath)
        self.filesVisited = filesVisited
        self.bytesVisited = bytesVisited
        self.error = error
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case status
        case rootPaths = "roots_json"
        case filesVisited = "files_visited"
        case bytesVisited = "bytes_visited"
        case error
    }
}
