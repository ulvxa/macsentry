import Foundation
import GRDB

public struct QuarantineEntry: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "quarantine_entry"

    public var id: Int64?
    public var batchID: Int64
    public var candidateID: Int64?
    var originalPath: String
    var quarantinePath: String
    public var kind: CandidateKind
    public var ruleID: String
    public var tier: Tier
    public var size: Int64
    public var quarantinedAt: Date
    public var status: QuarantineStatus
    public var trashedAt: Date?
    var trashPath: String?

    public var originalURL: URL {
        get { URL(storagePath: originalPath) }
        set { originalPath = newValue.storagePath }
    }

    public var quarantineURL: URL {
        get { URL(storagePath: quarantinePath) }
        set { quarantinePath = newValue.storagePath }
    }

    public var trashURL: URL? {
        get { trashPath.map(URL.init(storagePath:)) }
        set { trashPath = newValue?.storagePath }
    }

    public init(
        id: Int64? = nil,
        batchID: Int64,
        candidateID: Int64? = nil,
        originalURL: URL,
        quarantineURL: URL,
        kind: CandidateKind,
        ruleID: String,
        tier: Tier,
        size: Int64,
        quarantinedAt: Date,
        status: QuarantineStatus,
        trashedAt: Date? = nil,
        trashURL: URL? = nil,
    ) {
        self.id = id
        self.batchID = batchID
        self.candidateID = candidateID
        originalPath = originalURL.storagePath
        quarantinePath = quarantineURL.storagePath
        self.kind = kind
        self.ruleID = ruleID
        self.tier = tier
        self.size = size
        self.quarantinedAt = quarantinedAt
        self.status = status
        self.trashedAt = trashedAt
        trashPath = trashURL?.storagePath
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case candidateID = "candidate_id"
        case originalPath = "original_path"
        case quarantinePath = "quarantine_path"
        case kind
        case ruleID = "rule_id"
        case tier
        case size
        case quarantinedAt = "quarantined_at"
        case status
        case trashedAt = "trashed_at"
        case trashPath = "trash_path"
    }
}
