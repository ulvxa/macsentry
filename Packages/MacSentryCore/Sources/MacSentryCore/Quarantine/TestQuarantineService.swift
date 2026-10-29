import Foundation

public actor TestQuarantineService: QuarantineService {
    public private(set) var batches: [QuarantineBatch] = []
    public private(set) var entries: [QuarantineEntry] = []
    public private(set) var quarantineCalls: [[Candidate]] = []
    public private(set) var trashCalls: [[Int64]] = []
    public private(set) var restoreCalls: [[Int64]] = []
    public private(set) var reconcileCount = 0
    public var moveFailures: [URL: MoveFailure]
    public var entryFailures: [Int64: EntryFailureReason] = [:]
    public var readError: QuarantineServiceError?
    public let quarantineRoot: URL
    public let isDryRun: Bool
    private let now: @Sendable () -> Date

    public init(
        quarantineRoot: URL = URL(filePath: "/MacSentry Quarantine", directoryHint: .isDirectory),
        isDryRun: Bool = false,
        moveFailures: [URL: MoveFailure] = [:],
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.quarantineRoot = quarantineRoot
        self.isDryRun = isDryRun
        self.moveFailures = moveFailures
        self.now = now
    }

    public func setMoveFailure(_ failure: MoveFailure?, for url: URL) {
        moveFailures[url] = failure
    }

    public func setEntryFailure(_ failure: EntryFailureReason?, for entryID: Int64) {
        entryFailures[entryID] = failure
    }

    public func setReadError(_ error: QuarantineServiceError?) {
        readError = error
    }

    public func quarantine(
        _ candidates: [Candidate],
        progress: (@Sendable (QuarantineProgress) -> Void)?,
    ) async -> QuarantineResult {
        quarantineCalls.append(candidates)
        let batchID = Int64(batches.count + 1)
        let batch = QuarantineBatch(id: batchID, folderName: "batch-\(batchID)", createdAt: now(), dryRun: isDryRun)
        var moved: [QuarantineEntry] = []
        var failed: [QuarantineFailure] = []
        for (index, candidate) in candidates.enumerated() {
            if let failure = moveFailures[candidate.url] {
                failed.append(QuarantineFailure(path: candidate.url, reason: failure))
            } else {
                let entry = QuarantineEntry(
                    id: Int64(entries.count + moved.count + 1),
                    batchID: batchID,
                    candidateID: candidate.id,
                    originalURL: candidate.url,
                    quarantineURL: quarantineRoot.appending(path: batch.folderName).appending(path: candidate.url.storagePath),
                    kind: candidate.kind,
                    ruleID: candidate.ruleID,
                    tier: candidate.tier,
                    size: candidate.freeableSize,
                    quarantinedAt: now(),
                    status: .inQuarantine,
                )
                moved.append(entry)
            }
            progress?(QuarantineProgress(completed: index + 1, total: candidates.count, currentURL: candidate.url))
        }
        guard !moved.isEmpty else { return QuarantineResult(batchID: nil, moved: [], failed: failed) }
        batches.append(batch)
        entries.append(contentsOf: moved)
        return QuarantineResult(batchID: batchID, moved: moved, failed: failed)
    }

    public func trash(_ entryIDs: [Int64]) async -> TrashResult {
        trashCalls.append(entryIDs)
        let outcome = transition(entryIDs, to: .trashed)
        return TrashResult(trashed: outcome.done, failed: outcome.failed)
    }

    public func restore(_ entryIDs: [Int64]) async -> RestoreResult {
        restoreCalls.append(entryIDs)
        let outcome = transition(entryIDs, to: .restored)
        return RestoreResult(restored: outcome.done, failed: outcome.failed)
    }

    public func list() async throws -> [QuarantineBatchSummary] {
        if let readError {
            throw readError
        }
        return batches.reversed().map { batch in
            QuarantineBatchSummary(batch: batch, entries: entries.filter { $0.batchID == batch.id })
        }
    }

    public func totals() async throws -> QuarantineTotals {
        if let readError {
            throw readError
        }
        let real = entries.filter { entry in batches.contains { $0.id == entry.batchID && !$0.dryRun } }
        let dry = entries.filter { entry in batches.contains { $0.id == entry.batchID && $0.dryRun } }
        return QuarantineTotals(
            inQuarantine: real.filter { $0.status == .inQuarantine }.reduce(0) { $0 + $1.size },
            inTrash: real.filter { $0.status == .trashed }.reduce(0) { $0 + $1.size },
            freedThisMonth: 0,
            dryRunInQuarantine: dry.filter { $0.status == .inQuarantine }.reduce(0) { $0 + $1.size },
        )
    }

    public func reconcile() async throws {
        if let readError {
            throw readError
        }
        reconcileCount += 1
    }

    private func transition(_ entryIDs: [Int64], to status: QuarantineStatus) -> (done: [QuarantineEntry], failed: [EntryFailure]) {
        var done: [QuarantineEntry] = []
        var failed: [EntryFailure] = []
        for entryID in entryIDs {
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
                failed.append(EntryFailure(entryID: entryID, path: nil, reason: .notFound))
                continue
            }
            if let reason = entryFailures[entryID] ?? Self.blockingReason(entries[index].status) {
                failed.append(EntryFailure(entryID: entryID, path: entries[index].originalURL, reason: reason))
                continue
            }
            entries[index].status = status
            if status == .trashed {
                entries[index].trashedAt = now()
            }
            done.append(entries[index])
        }
        return (done, failed)
    }

    private static func blockingReason(_ status: QuarantineStatus) -> EntryFailureReason? {
        switch status {
        case .inQuarantine: nil
        case .trashed: .alreadyTrashed
        case .restored: .alreadyRestored
        case .missing: .missing
        }
    }
}
