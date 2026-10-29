import Darwin
import Foundation
import GRDB
import os

public actor DefaultQuarantineService: QuarantineService {
    public static let folderName = "MacSentry Quarantine"
    static let manifestName = "manifest.json"
    static let flushInterval = 100

    let quarantineRoot: URL
    let isDryRun: Bool
    let database: Database
    let protectionPolicy: any ProtectionPolicy
    let appInventory: any AppInventory
    let sizeCalculator: any SizeCalculator
    let trasher: any Trasher
    let timeZone: TimeZone
    let now: @Sendable () -> Date
    let logger = Logger(subsystem: "com.macsentry.core", category: "Quarantine")

    public init(
        database: Database,
        quarantineRoot: URL,
        isDryRun: Bool,
        protectionPolicy: any ProtectionPolicy,
        appInventory: any AppInventory,
        sizeCalculator: any SizeCalculator,
        trasher: any Trasher = SystemTrasher(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.database = database
        self.quarantineRoot = URL(filePath: quarantineRoot.storagePath, directoryHint: .isDirectory)
        self.isDryRun = isDryRun
        self.protectionPolicy = protectionPolicy
        self.appInventory = appInventory
        self.sizeCalculator = sizeCalculator
        self.trasher = trasher
        self.timeZone = timeZone
        self.now = now
    }

    public init(
        environment: AppEnvironment,
        database: Database,
        protectionPolicy: any ProtectionPolicy,
        appInventory: any AppInventory,
        sizeCalculator: any SizeCalculator,
        trasher: any Trasher = SystemTrasher(),
    ) {
        self.init(
            database: database,
            quarantineRoot: Self.quarantineRoot(home: environment.homeURL),
            isDryRun: environment.isDryRun,
            protectionPolicy: protectionPolicy,
            appInventory: appInventory,
            sizeCalculator: sizeCalculator,
            trasher: trasher,
        )
    }

    public static func quarantineRoot(home: URL) -> URL {
        home.appending(path: folderName, directoryHint: .isDirectory)
    }

    public func quarantine(
        _ candidates: [Candidate],
        progress: (@Sendable (QuarantineProgress) -> Void)?,
    ) async -> QuarantineResult {
        let startedAt = now()
        var batch: QuarantineBatch?
        var moved: [QuarantineEntry] = []
        var failed: [QuarantineFailure] = []
        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                break
            }
            do {
                let entry = try await quarantineOne(candidate, batch: &batch, startedAt: startedAt)
                moved.append(entry)
                if let batch, moved.count.isMultiple(of: Self.flushInterval) {
                    writeManifest(batch, entries: moved)
                }
            } catch {
                logger.error("Quarantine refused \(candidate.url.storagePath, privacy: .private): \(error.rawValue, privacy: .public)")
                failed.append(QuarantineFailure(path: candidate.url, reason: error))
            }
            progress?(QuarantineProgress(completed: index + 1, total: candidates.count, currentURL: candidate.url))
        }
        guard let batch else {
            return QuarantineResult(batchID: nil, moved: [], failed: failed)
        }
        if moved.isEmpty {
            discardEmptyBatch(batch)
            return QuarantineResult(batchID: nil, moved: [], failed: failed)
        }
        writeManifest(batch, entries: moved)
        return QuarantineResult(batchID: batch.id, moved: moved, failed: failed)
    }

    private func quarantineOne(
        _ candidate: Candidate,
        batch: inout QuarantineBatch?,
        startedAt: Date,
    ) async throws(MoveFailure) -> QuarantineEntry {
        let source = candidate.url
        guard candidate.action == .quarantine, !overlapsQuarantine(source), protectionPolicy.check(source) == .allowed else {
            throw .protected
        }
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
        try await verifyUnchanged(candidate, info: info)
        if let bundleID = candidate.appBundleID, appInventory.isRunning(bundleID: bundleID) {
            throw .appRunning
        }
        if info.isLocked {
            throw .locked
        }
        if info.isDataless {
            throw .dataless
        }

        let currentBatch: QuarantineBatch
        if let batch {
            currentBatch = batch
        } else {
            currentBatch = try openBatch(startedAt: startedAt)
            batch = currentBatch
        }
        let destination = destinationURL(for: source, in: currentBatch)
        guard FileSystemCalls.pathLength(destination) < Int(PATH_MAX) else {
            logger.error("Quarantine path too long for \(source.storagePath, privacy: .private)")
            throw .unknown
        }
        if !isDryRun {
            try move(source, to: destination)
        }
        return try record(candidate, batch: currentBatch, destination: destination)
    }

    private func verifyUnchanged(_ candidate: Candidate, info: FileStatus) async throws(MoveFailure) {
        guard !info.isSymlink, info.isDirectory == (candidate.kind != .file) else { throw .changedSinceScan }
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

    private func move(_ source: URL, to destination: URL) throws(MoveFailure) {
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw FileSystemCalls.posixCode(of: error).map(MoveFailure.init(errno:)) ?? .unknown
        }
        do {
            try FileSystemCalls.renameExclusive(source, to: destination)
        } catch {
            throw MoveFailure(errno: error.code)
        }
    }

    private func record(_ candidate: Candidate, batch: QuarantineBatch, destination: URL) throws(MoveFailure) -> QuarantineEntry {
        guard let batchID = batch.id else { throw .unknown }
        var entry = QuarantineEntry(
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
        do {
            try database.writer.write { db in
                try entry.insert(db)
                try Self.updateCandidate(db, id: candidate.id, status: .quarantined)
            }
        } catch {
            logger.error("Recording quarantine entry failed: \(error.localizedDescription, privacy: .public)")
            if !isDryRun {
                try? FileSystemCalls.renameExclusive(destination, to: candidate.url)
            }
            throw .unknown
        }
        return entry
    }

    private func openBatch(startedAt: Date) throws(MoveFailure) -> QuarantineBatch {
        let base = Self.batchFolderName(for: startedAt, timeZone: timeZone)
        if !isDryRun {
            do {
                try prepareQuarantineRoot()
            } catch {
                throw FileSystemCalls.posixCode(of: error).map(MoveFailure.init(errno:)) ?? .unknown
            }
        }
        for attempt in 1 ... 1000 {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let folder = quarantineRoot.appending(path: name, directoryHint: .isDirectory)
            do {
                let taken = try database.writer.read { db in
                    try QuarantineBatch.filter(Column("folder_name") == name).fetchCount(db) > 0
                }
                if taken || FileSystemCalls.exists(folder) {
                    continue
                }
                if !isDryRun {
                    try FileSystemCalls.makeDirectory(folder)
                }
                var batch = QuarantineBatch(folderName: name, createdAt: startedAt, dryRun: isDryRun)
                try database.writer.write { try batch.insert($0) }
                return batch
            } catch let failure as POSIXFailure where failure.code == EEXIST {
                continue
            } catch {
                throw FileSystemCalls.posixCode(of: error).map(MoveFailure.init(errno:)) ?? .unknown
            }
        }
        throw .unknown
    }

    private func discardEmptyBatch(_ batch: QuarantineBatch) {
        if !batch.dryRun {
            let folder = batchFolder(batch)
            removeEmptyDirectories(below: folder)
            FileSystemCalls.removeEmptyDirectory(folder)
        }
        _ = try? database.writer.write { db in try batch.delete(db) }
    }

    func setCandidateStatus(_ status: CandidateStatus, id: Int64?) {
        do {
            try database.writer.write { try Self.updateCandidate($0, id: id, status: status) }
        } catch {
            logger.error("Updating candidate status failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func updateCandidate(_ db: GRDB.Database, id: Int64?, status: CandidateStatus) throws {
        guard let id else { return }
        try db.execute(sql: "UPDATE candidate SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
    }
}
