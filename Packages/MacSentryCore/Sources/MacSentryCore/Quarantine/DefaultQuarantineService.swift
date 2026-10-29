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
    var activeBatchIDs: Set<Int64> = []

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
                if let batchID = batch?.id, moved.count.isMultiple(of: Self.flushInterval) {
                    rewriteManifest(batchID: batchID)
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
        if let batchID = batch.id {
            activeBatchIDs.remove(batchID)
        }
        if moved.isEmpty {
            discardEmptyBatch(batch)
            return QuarantineResult(batchID: nil, moved: [], failed: failed)
        }
        if let batchID = batch.id {
            rewriteManifest(batchID: batchID)
        }
        return QuarantineResult(batchID: batch.id, moved: moved, failed: failed)
    }

    private func quarantineOne(
        _ candidate: Candidate,
        batch: inout QuarantineBatch?,
        startedAt: Date,
    ) async throws(MoveFailure) -> QuarantineEntry {
        let source = candidate.url
        guard candidate.action == .quarantine else { throw .protected }
        let info = try preflight(candidate)
        try await verifyUnchanged(candidate, info: info)
        if let bundleID = candidate.appBundleID, appInventory.isRunning(bundleID: bundleID) {
            throw .appRunning
        }

        let currentBatch: QuarantineBatch
        if let batch {
            currentBatch = batch
        } else {
            currentBatch = try openBatch(startedAt: startedAt)
            batch = currentBatch
            if let batchID = currentBatch.id {
                activeBatchIDs.insert(batchID)
            }
        }
        let destination = destinationURL(for: source, in: currentBatch)
        guard FileSystemCalls.pathLength(destination) < Int(PATH_MAX) else {
            logger.error("Quarantine path too long for \(source.storagePath, privacy: .private)")
            throw .unknown
        }
        let entry = try makeEntry(candidate, batch: currentBatch, destination: destination)
        if !isDryRun {
            try createParent(of: destination)
            _ = try preflight(candidate)
            try move(source, to: destination)
            appendJournal(entry, status: .inQuarantine, batch: currentBatch)
        }
        return try record(entry, batch: currentBatch)
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
