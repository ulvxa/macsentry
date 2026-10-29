import Foundation
import GRDB

extension DefaultQuarantineService {
    public func list() async throws -> [QuarantineBatchSummary] {
        let (batches, entries) = try read { db in
            try (
                QuarantineBatch.order(Column("created_at").desc, Column("id").desc).fetchAll(db),
                QuarantineEntry.order(Column("id")).fetchAll(db),
            )
        }
        let grouped = Dictionary(grouping: entries, by: \.batchID)
        return batches.map { QuarantineBatchSummary(batch: $0, entries: $0.id.flatMap { grouped[$0] } ?? []) }
    }

    public func totals() async throws -> QuarantineTotals {
        let (dryRunBatchIDs, entries) = try read { db in
            try (
                Set(Int64.fetchAll(db, sql: "SELECT id FROM quarantine_batch WHERE dry_run = 1")),
                QuarantineEntry
                    .filter([QuarantineStatus.inQuarantine, QuarantineStatus.trashed].map(\.rawValue).contains(Column("status")))
                    .fetchAll(db),
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let reference = now()
        var inQuarantine: Int64 = 0
        var inTrash: Int64 = 0
        var freed: Int64 = 0
        var dryRun: Int64 = 0
        for entry in entries {
            if dryRunBatchIDs.contains(entry.batchID) {
                if entry.status == .inQuarantine {
                    dryRun += entry.size
                }
                continue
            }
            switch entry.status {
            case .inQuarantine:
                inQuarantine += entry.size
            case .trashed:
                guard let trashURL = entry.trashURL else { continue }
                if FileSystemCalls.exists(trashURL) {
                    inTrash += entry.size
                } else if let trashedAt = entry.trashedAt, calendar.isDate(trashedAt, equalTo: reference, toGranularity: .month) {
                    freed += entry.size
                }
            case .restored, .missing:
                continue
            }
        }
        return QuarantineTotals(inQuarantine: inQuarantine, inTrash: inTrash, freedThisMonth: freed, dryRunInQuarantine: dryRun)
    }

    public func reconcile() async throws {
        try await reconcileWithReport()
    }

    @discardableResult
    public func reconcileWithReport() async throws -> ReconcileReport {
        var changed = Set<Int64>()
        var skipped = 0
        for source in loadBatchSources() {
            let outcome = try importBatch(source)
            changed.formUnion(outcome.changed)
            skipped += outcome.skipped
        }
        let tracked = try read { db in
            try QuarantineEntry
                .filter([QuarantineStatus.inQuarantine, QuarantineStatus.missing].map(\.rawValue).contains(Column("status")))
                .filter(sql: "batch_id IN (SELECT id FROM quarantine_batch WHERE dry_run = 0)")
                .fetchAll(db)
        }
        var updates: [QuarantineEntry] = []
        for var entry in tracked {
            switch (entry.status, FileSystemCalls.presence(of: entry.quarantineURL)) {
            case (.inQuarantine, false?): entry.status = .missing
            case (.missing, true?): entry.status = .inQuarantine
            default: continue
            }
            updates.append(entry)
        }
        if !updates.isEmpty {
            try write { [updates] db in
                for entry in updates {
                    try entry.update(db)
                }
            }
            changed.formUnion(updates.map(\.batchID))
        }
        for batchID in changed.sorted() {
            rewriteManifest(batchID: batchID)
        }
        let report = try ReconcileReport(
            untracked: findUntracked(),
            skippedEntries: skipped,
            markedMissing: updates.count { $0.status == .missing },
            recovered: updates.count { $0.status == .inQuarantine },
        )
        for url in report.untracked {
            logger.notice("Untracked item in quarantine folder, left in place: \(url.storagePath, privacy: .private)")
        }
        return report
    }

    private struct BatchSource {
        let folderName: String
        let createdAt: Date
        let dryRun: Bool
        let entries: [QuarantineManifest.Entry]
    }

    private func batchFolders() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: quarantineRoot, includingPropertiesForKeys: nil)) ?? []
        return folders
            .filter { (try? FileSystemCalls.status(of: $0))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadBatchSources() -> [BatchSource] {
        batchFolders().compactMap { folder in
            let name = folder.lastPathComponent
            var manifest: QuarantineManifest?
            let manifestURL = folder.appending(path: Self.manifestName, directoryHint: .notDirectory)
            if FileSystemCalls.exists(manifestURL) {
                do {
                    manifest = try QuarantineManifest.decode(Data(contentsOf: manifestURL))
                } catch {
                    logger.error("Skipping unreadable manifest in \(name, privacy: .public)")
                }
            }
            if let decoded = manifest, decoded.batch != name {
                logger.error("Skipping manifest naming another batch in \(name, privacy: .public)")
                manifest = nil
            }
            let listed = Set(manifest?.entries.map(\.quarantinePath) ?? [])
            let journaled = Self.journalEntries(in: folder).filter { !listed.contains($0.quarantinePath) }
            guard manifest != nil || !journaled.isEmpty else { return nil }
            return BatchSource(
                folderName: name,
                createdAt: manifest?.createdDate(timeZone: timeZone) ?? Self.batchDate(fromFolderName: name, timeZone: timeZone) ?? now(),
                dryRun: manifest?.dryRun ?? false,
                entries: (manifest?.entries ?? []) + journaled,
            )
        }
    }

    private func importBatch(_ source: BatchSource) throws -> (changed: Set<Int64>, skipped: Int) {
        let folder = quarantineRoot.appending(path: source.folderName, directoryHint: .isDirectory)
        let policy = protectionPolicy
        let outcome = try write { db -> (changed: Set<Int64>, skipped: Int) in
            var batch = try QuarantineBatch.filter(Column("folder_name") == source.folderName).fetchOne(db)
                ?? QuarantineBatch(folderName: source.folderName, createdAt: source.createdAt, dryRun: source.dryRun)
            if batch.id == nil {
                try batch.insert(db)
            }
            guard let batchID = batch.id else { return ([], 0) }
            var inserted = false
            var skipped = 0
            for item in source.entries {
                let exists = try QuarantineEntry
                    .filter(Column("batch_id") == batchID && Column("quarantine_path") == item.quarantinePath)
                    .fetchCount(db) > 0
                if exists {
                    continue
                }
                guard Self.isMirrored(item.quarantinePath, original: item.originalPath, in: folder),
                      policy.check(URL(storagePath: item.originalPath)) == .allowed
                else {
                    skipped += 1
                    continue
                }
                var entry = QuarantineEntry(
                    batchID: batchID,
                    originalURL: URL(storagePath: item.originalPath),
                    quarantineURL: URL(storagePath: item.quarantinePath),
                    kind: item.kind,
                    ruleID: item.ruleId,
                    tier: item.tier,
                    size: item.size,
                    quarantinedAt: source.createdAt,
                    status: item.status,
                )
                try entry.insert(db)
                inserted = true
            }
            return (inserted ? [batchID] : [], skipped)
        }
        if outcome.skipped > 0 {
            logger.error("Skipped \(outcome.skipped) manifest entries in \(source.folderName, privacy: .public) that failed validation")
        }
        return outcome
    }

    private func findUntracked() throws -> [URL] {
        let (batches, entries) = try read { db in
            try (QuarantineBatch.filter(Column("dry_run") == false).fetchAll(db), QuarantineEntry.fetchAll(db))
        }
        let grouped = Dictionary(grouping: entries, by: \.batchID)
        let known = Dictionary(batches.map { ($0.folderName, $0) }) { first, _ in first }
        return batchFolders().flatMap { folder -> [URL] in
            guard let batch = known[folder.lastPathComponent] else {
                return Self.holdsContent(folder.storagePath) ? [folder] : []
            }
            return untrackedItems(in: batch, entries: batch.id.flatMap { grouped[$0] } ?? [])
        }
    }

    private func read<T: Sendable>(_ body: @Sendable (GRDB.Database) throws -> T) throws -> T {
        do {
            return try database.writer.read(body)
        } catch {
            throw QuarantineServiceError.database(error.localizedDescription)
        }
    }

    private func write<T: Sendable>(_ body: @Sendable (GRDB.Database) throws -> T) throws -> T {
        do {
            return try database.writer.write(body)
        } catch {
            throw QuarantineServiceError.database(error.localizedDescription)
        }
    }
}
