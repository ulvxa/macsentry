import Foundation
import Synchronization

public struct CandidateDraft: Sendable, Equatable {
    public var category: Category
    public var ruleID: String
    public var tier: Tier
    public var action: CandidateAction
    public var reason: String
    public var cliCommand: String?
    public var appBundleID: String?
    public var confidence: Confidence?
    public var projectID: Int64?
    public var dupGroupID: Int64?
    public var lastUsedAt: Date?
    public var minFreeableSize: Int64

    public init(
        category: Category,
        ruleID: String,
        tier: Tier,
        action: CandidateAction,
        reason: String,
        cliCommand: String? = nil,
        appBundleID: String? = nil,
        confidence: Confidence? = nil,
        projectID: Int64? = nil,
        dupGroupID: Int64? = nil,
        lastUsedAt: Date? = nil,
        minFreeableSize: Int64 = 0,
    ) {
        self.category = category
        self.ruleID = ruleID
        self.tier = tier
        self.action = action
        self.reason = reason
        self.cliCommand = cliCommand
        self.appBundleID = appBundleID
        self.confidence = confidence
        self.projectID = projectID
        self.dupGroupID = dupGroupID
        self.lastUsedAt = lastUsedAt
        self.minFreeableSize = minFreeableSize
    }
}

public enum HandlerDecision: Sendable, Equatable {
    case descend
    case skip
    case claim(CandidateDraft)
}

public struct ScanContext: Sendable {
    public let sessionID: Int64
    public let config: ScanConfig
    public let database: Database
    public let sizeCalculator: DefaultSizeCalculator
    public let lastUsedResolver: any LastUsedResolver

    public func candidate(_ draft: CandidateDraft, for entry: FileEntry, size: SizeInfo? = nil, modified: Date? = nil) -> Candidate {
        let size = size ?? sizeCalculator.sizeInfo(for: entry)
        return Candidate(
            sessionID: sessionID,
            url: entry.url,
            kind: entry.kind == .folder ? .folder : entry.kind == .package ? .package : .file,
            category: draft.category,
            ruleID: draft.ruleID,
            tier: draft.tier,
            action: draft.action,
            reason: draft.reason,
            cliCommand: draft.cliCommand,
            appBundleID: draft.appBundleID,
            logicalSize: size.logical,
            allocatedSize: size.allocated,
            freeableSize: size.freeable,
            createdAt: entry.created,
            modifiedAt: modified ?? entry.modified,
            lastUsedAt: draft.lastUsedAt,
            confidence: draft.confidence,
            projectID: draft.projectID,
            dupGroupID: draft.dupGroupID,
        )
    }
}

public protocol ScanEntryHandler: Sendable {
    var finishPhase: ScanPhase? { get }
    func visit(_ entry: FileEntry, context: ScanContext) async -> HandlerDecision
    func finish(context: ScanContext) async throws -> [Candidate]
}

public extension ScanEntryHandler {
    var finishPhase: ScanPhase? {
        nil
    }

    func visit(_: FileEntry, context _: ScanContext) async -> HandlerDecision {
        .descend
    }

    func finish(context _: ScanContext) async throws -> [Candidate] {
        []
    }
}

public final class FileIndexCollector: ScanEntryHandler {
    public let minimumSize: Int64
    private let storage = Mutex<[FileEntry]>([])

    public init(minimumSize: Int64 = 1) {
        self.minimumSize = minimumSize
    }

    public var entries: [FileEntry] {
        storage.withLock { $0 }
    }

    public func visit(_ entry: FileEntry, context _: ScanContext) async -> HandlerDecision {
        if entry.kind == .file, entry.logicalSize >= minimumSize {
            storage.withLock { $0.append(entry) }
        }
        return .descend
    }
}
