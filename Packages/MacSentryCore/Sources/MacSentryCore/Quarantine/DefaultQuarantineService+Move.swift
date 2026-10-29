import Foundation

extension DefaultQuarantineService {
    func preflight(_ candidate: Candidate) throws(MoveFailure) -> FileStatus {
        let source = candidate.url
        guard !overlapsQuarantine(source), protectionPolicy.check(source) == .allowed else { throw .protected }
        let info: FileStatus
        do {
            info = try FileSystemCalls.status(of: source)
        } catch {
            let failure = MoveFailure(errno: error.code)
            if failure == .missing {
                setCandidateStatus(.stale, id: candidate.id)
            }
            throw failure
        }
        guard !info.isSymlink, info.isDirectory == (candidate.kind != .file) else { throw .changedSinceScan }
        if info.isLocked {
            throw .locked
        }
        if info.isDataless {
            throw .dataless
        }
        return info
    }

    func verifyUnchanged(_ candidate: Candidate, info: FileStatus) async throws(MoveFailure) {
        let current: Int64
        if info.isDirectory {
            do {
                current = try await sizeCalculator.aggregate(folder: candidate.url).allocated
            } catch {
                throw FileSystemCalls.posixCode(of: error).map(MoveFailure.init(errno:)) ?? .unknown
            }
        } else {
            current = info.allocatedBytes
        }
        let scanned = candidate.allocatedSize
        if abs(current - scanned) * 10 > scanned {
            throw .changedSinceScan
        }
    }

    func createParent(of destination: URL) throws(MoveFailure) {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw FileSystemCalls.posixCode(of: error).map(MoveFailure.init(errno:)) ?? .unknown
        }
    }

    func move(_ source: URL, to destination: URL) throws(MoveFailure) {
        do {
            try FileSystemCalls.renameExclusive(source, to: destination)
        } catch {
            throw MoveFailure(errno: error.code)
        }
    }

    func makeEntry(_ candidate: Candidate, batch: QuarantineBatch, destination: URL) throws(MoveFailure) -> QuarantineEntry {
        guard let batchID = batch.id else { throw .unknown }
        return QuarantineEntry(
            batchID: batchID,
            candidateID: candidate.id,
            originalURL: candidate.url,
            quarantineURL: destination,
            kind: candidate.kind,
            ruleID: candidate.ruleID,
            tier: candidate.tier,
            size: candidate.freeableSize,
            quarantinedAt: now(),
            status: .inQuarantine,
        )
    }

    func record(_ pending: QuarantineEntry, batch: QuarantineBatch) throws(MoveFailure) -> QuarantineEntry {
        var entry = pending
        do {
            try database.writer.write { db in
                try entry.insert(db)
                try Self.updateCandidate(db, id: entry.candidateID, status: .quarantined)
            }
        } catch {
            logger.error("Recording quarantine entry failed: \(error.localizedDescription, privacy: .public)")
            if !isDryRun {
                revert(pending, batch: batch)
            }
            throw .unknown
        }
        return entry
    }

    func revert(_ entry: QuarantineEntry, batch: QuarantineBatch) {
        do {
            try FileSystemCalls.renameExclusive(entry.quarantineURL, to: entry.originalURL)
            appendJournal(entry, status: .restored, batch: batch)
        } catch {
            let path = entry.quarantineURL.storagePath
            logger.fault("UNTRACKED quarantine item, rename back failed (errno \(error.code)): \(path, privacy: .private)")
        }
    }
}
