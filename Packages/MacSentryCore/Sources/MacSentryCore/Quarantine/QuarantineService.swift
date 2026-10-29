import Foundation

public protocol QuarantineService: Sendable {
    func quarantine(_ candidates: [Candidate], progress: (@Sendable (QuarantineProgress) -> Void)?) async -> QuarantineResult
    func trash(_ entryIDs: [Int64]) async -> TrashResult
    func restore(_ entryIDs: [Int64]) async -> RestoreResult
    func list() async throws -> [QuarantineBatchSummary]
    func totals() async throws -> QuarantineTotals
    func reconcile() async throws
}

public extension QuarantineService {
    func quarantine(_ candidates: [Candidate]) async -> QuarantineResult {
        await quarantine(candidates, progress: nil)
    }
}

public struct QuarantineProgress: Sendable, Equatable {
    public let completed: Int
    public let total: Int
    public let currentURL: URL

    public init(completed: Int, total: Int, currentURL: URL) {
        self.completed = completed
        self.total = total
        self.currentURL = currentURL
    }
}

public struct QuarantineFailure: Sendable, Equatable {
    public let path: URL
    public let reason: MoveFailure

    public init(path: URL, reason: MoveFailure) {
        self.path = path
        self.reason = reason
    }
}

public struct QuarantineResult: Sendable, Equatable {
    public let batchID: Int64?
    public let moved: [QuarantineEntry]
    public let failed: [QuarantineFailure]

    public init(batchID: Int64?, moved: [QuarantineEntry], failed: [QuarantineFailure]) {
        self.batchID = batchID
        self.moved = moved
        self.failed = failed
    }
}

public struct EntryFailure: Error, Sendable, Equatable {
    public let entryID: Int64
    public let path: URL?
    public let reason: EntryFailureReason

    public init(entryID: Int64, path: URL?, reason: EntryFailureReason) {
        self.entryID = entryID
        self.path = path
        self.reason = reason
    }
}

public struct TrashResult: Sendable, Equatable {
    public let trashed: [QuarantineEntry]
    public let failed: [EntryFailure]

    public init(trashed: [QuarantineEntry], failed: [EntryFailure]) {
        self.trashed = trashed
        self.failed = failed
    }
}

public struct RestoreResult: Sendable, Equatable {
    public let restored: [QuarantineEntry]
    public let failed: [EntryFailure]

    public init(restored: [QuarantineEntry], failed: [EntryFailure]) {
        self.restored = restored
        self.failed = failed
    }
}

public struct TierTotal: Sendable, Equatable {
    public var count: Int
    public var size: Int64

    public init(count: Int = 0, size: Int64 = 0) {
        self.count = count
        self.size = size
    }
}

public struct QuarantineBatchSummary: Sendable, Equatable, Identifiable {
    public let batch: QuarantineBatch
    public let entries: [QuarantineEntry]

    public var id: String {
        batch.folderName
    }

    public var isDryRun: Bool {
        batch.dryRun
    }

    public var itemCount: Int {
        entries.count
    }

    public var totalSize: Int64 {
        entries.reduce(0) { $0 + $1.size }
    }

    public var tiers: [Tier: TierTotal] {
        entries.reduce(into: [:]) { totals, entry in
            totals[entry.tier, default: TierTotal()].count += 1
            totals[entry.tier, default: TierTotal()].size += entry.size
        }
    }

    public init(batch: QuarantineBatch, entries: [QuarantineEntry]) {
        self.batch = batch
        self.entries = entries
    }
}

public struct QuarantineTotals: Sendable, Equatable {
    public let inQuarantine: Int64
    public let inTrash: Int64
    public let freedThisMonth: Int64
    public let dryRunInQuarantine: Int64

    public init(inQuarantine: Int64, inTrash: Int64, freedThisMonth: Int64, dryRunInQuarantine: Int64) {
        self.inQuarantine = inQuarantine
        self.inTrash = inTrash
        self.freedThisMonth = freedThisMonth
        self.dryRunInQuarantine = dryRunInQuarantine
    }
}

public enum QuarantineServiceError: LocalizedError, Equatable {
    case database(String)

    public var errorDescription: String? {
        switch self {
        case let .database(reason):
            "The quarantine records couldn't be read or saved: \(reason)"
        }
    }
}
