import Foundation
import GRDB

extension DefaultQuarantineService {
    private enum Operation {
        case trash, restore

        var targetStatus: QuarantineStatus {
            self == .trash ? .trashed : .restored
        }

        var candidateStatus: CandidateStatus {
            self == .trash ? .trashed : .restored
        }
    }

    public func trash(_ entryIDs: [Int64]) async -> TrashResult {
        let outcome = perform(.trash, on: entryIDs)
        return TrashResult(trashed: outcome.done, failed: outcome.failed)
    }

    public func restore(_ entryIDs: [Int64]) async -> RestoreResult {
        let outcome = perform(.restore, on: entryIDs)
        return RestoreResult(restored: outcome.done, failed: outcome.failed)
    }

    private func perform(_ operation: Operation, on entryIDs: [Int64]) -> (done: [QuarantineEntry], failed: [EntryFailure]) {
        var done: [QuarantineEntry] = []
        var failed: [EntryFailure] = []
        var touched: [Int64: Int] = [:]
        for entryID in entryIDs {
            do {
                let entry = try apply(operation, to: entryID, touched: &touched)
                done.append(entry)
            } catch {
                logger.error("Entry \(entryID) \(String(describing: operation)) failed: \(error.reason.rawValue, privacy: .public)")
                failed.append(error)
            }
        }
        finishBatches(Set(touched.keys))
        return (done, failed)
    }

    private func apply(_ operation: Operation, to entryID: Int64, touched: inout [Int64: Int]) throws(EntryFailure) -> QuarantineEntry {
        let (current, batch) = try loadEntry(entryID)
        var entry = current
        func fail(_ reason: EntryFailureReason) -> EntryFailure {
            EntryFailure(entryID: entryID, path: entry.originalURL, reason: reason)
        }
        switch entry.status {
        case .inQuarantine: break
        case .trashed: throw fail(.alreadyTrashed)
        case .restored: throw fail(.alreadyRestored)
        case .missing: throw fail(.missing)
        }
        if !batch.dryRun {
            guard !isDryRun else { throw fail(.dryRunMode) }
            do throws(EntryFailureReason) {
                try applyOnDisk(operation, to: &entry, in: batch)
            } catch {
                if error == .missing {
                    entry.status = .missing
                    try save(entry, candidateStatus: nil, failure: fail)
                    note(entry.batchID, in: &touched)
                }
                throw fail(error)
            }
        }
        entry.status = operation.targetStatus
        if operation == .trash {
            entry.trashedAt = now()
        }
        try save(entry, candidateStatus: operation.candidateStatus, failure: fail)
        note(entry.batchID, in: &touched)
        return entry
    }

    private func applyOnDisk(
        _ operation: Operation,
        to entry: inout QuarantineEntry,
        in batch: QuarantineBatch,
    ) throws(EntryFailureReason) {
        if operation == .restore, case let .denied(reason) = protectionPolicy.check(entry.originalURL) {
            let path = entry.originalURL.storagePath
            logger.error("Restore refused by protection (\(reason, privacy: .public)): \(path, privacy: .private)")
            throw .protected
        }
        let source = try verifiedQuarantineURL(entry, in: batch)
        switch operation {
        case .trash: entry.trashURL = try trashFromDisk(source)
        case .restore: try restoreOnDisk(source, to: entry.originalURL)
        }
    }

    private func loadEntry(_ entryID: Int64) throws(EntryFailure) -> (QuarantineEntry, QuarantineBatch) {
        let loaded: (QuarantineEntry, QuarantineBatch)?
        do {
            loaded = try database.writer.read { db in
                guard let entry = try QuarantineEntry.fetchOne(db, key: entryID),
                      let batch = try QuarantineBatch.fetchOne(db, key: entry.batchID)
                else { return nil }
                return (entry, batch)
            }
        } catch {
            throw EntryFailure(entryID: entryID, path: nil, reason: .unknown)
        }
        guard let loaded else { throw EntryFailure(entryID: entryID, path: nil, reason: .notFound) }
        return loaded
    }

    private func trashFromDisk(_ url: URL) throws(EntryFailureReason) -> URL? {
        do {
            return try trasher.trash(url)
        } catch {
            throw FileSystemCalls.posixCode(of: error).map(EntryFailureReason.init(errno:)) ?? .unknown
        }
    }

    private func restoreOnDisk(_ source: URL, to destination: URL) throws(EntryFailureReason) {
        if FileSystemCalls.exists(destination) {
            throw .destinationExists
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard protectionPolicy.check(destination) == .allowed else { throw EntryFailureReason.protected }
            try FileSystemCalls.renameExclusive(source, to: destination)
        } catch let reason as EntryFailureReason {
            throw reason
        } catch {
            throw FileSystemCalls.posixCode(of: error).map(EntryFailureReason.init(errno:)) ?? .unknown
        }
    }

    private func save(
        _ entry: QuarantineEntry,
        candidateStatus: CandidateStatus?,
        failure: (EntryFailureReason) -> EntryFailure,
    ) throws(EntryFailure) {
        do {
            try database.writer.write { db in
                try entry.update(db)
                if let candidateStatus {
                    try Self.updateCandidate(db, id: entry.candidateID, status: candidateStatus)
                }
            }
        } catch {
            logger.error("Saving entry status failed: \(error.localizedDescription, privacy: .public)")
            throw failure(.unknown)
        }
    }

    private func note(_ batchID: Int64, in touched: inout [Int64: Int]) {
        touched[batchID, default: 0] += 1
        if let count = touched[batchID], count.isMultiple(of: Self.flushInterval) {
            rewriteManifest(batchID: batchID)
        }
    }
}
