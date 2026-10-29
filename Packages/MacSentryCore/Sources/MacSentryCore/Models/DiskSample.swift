import Foundation
import GRDB

public struct DiskSample: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "disk_sample"

    public var sampledAt: Date
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var importantFree: Int64

    public init(sampledAt: Date, totalBytes: Int64, freeBytes: Int64, importantFree: Int64) {
        self.sampledAt = sampledAt
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.importantFree = importantFree
    }

    enum CodingKeys: String, CodingKey {
        case sampledAt = "sampled_at"
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
        case importantFree = "important_free"
    }
}
