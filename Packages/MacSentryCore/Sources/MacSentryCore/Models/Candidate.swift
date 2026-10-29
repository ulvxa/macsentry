import Foundation
import GRDB

public struct Candidate: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord, UnixTimestampRecord {
    public static let databaseTableName = "candidate"

    public var id: Int64?
    public var sessionID: Int64
    var path: String
    public var kind: CandidateKind
    public var category: Category
    public var ruleID: String
    public var tier: Tier
    public var action: CandidateAction
    public var reason: String
    public var cliCommand: String?
    public var appBundleID: String?
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var freeableSize: Int64
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var lastUsedAt: Date?
    public var confidence: Confidence?
    public var projectID: Int64?
    public var dupGroupID: Int64?
    public var status: CandidateStatus
    public var group: String?

    public var url: URL {
        get { URL(storagePath: path) }
        set { path = newValue.storagePath }
    }

    public init(
        id: Int64? = nil,
        sessionID: Int64,
        url: URL,
        kind: CandidateKind,
        category: Category,
        ruleID: String,
        tier: Tier,
        action: CandidateAction,
        reason: String,
        cliCommand: String? = nil,
        appBundleID: String? = nil,
        logicalSize: Int64,
        allocatedSize: Int64,
        freeableSize: Int64,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil,
        lastUsedAt: Date? = nil,
        confidence: Confidence? = nil,
        projectID: Int64? = nil,
        dupGroupID: Int64? = nil,
        status: CandidateStatus = .found,
        group: String? = nil,
    ) {
        self.id = id
        self.sessionID = sessionID
        path = url.storagePath
        self.kind = kind
        self.category = category
        self.ruleID = ruleID
        self.tier = tier
        self.action = action
        self.reason = reason
        self.cliCommand = cliCommand
        self.appBundleID = appBundleID
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.freeableSize = freeableSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastUsedAt = lastUsedAt
        self.confidence = confidence
        self.projectID = projectID
        self.dupGroupID = dupGroupID
        self.status = status
        self.group = group
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case path
        case kind
        case category
        case ruleID = "rule_id"
        case tier
        case action
        case reason
        case cliCommand = "cli_command"
        case appBundleID = "app_bundle_id"
        case logicalSize = "logical_size"
        case allocatedSize = "allocated_size"
        case freeableSize = "freeable_size"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case lastUsedAt = "last_used_at"
        case confidence
        case projectID = "project_id"
        case dupGroupID = "dup_group_id"
        case status
        case group = "rule_group"
    }
}
