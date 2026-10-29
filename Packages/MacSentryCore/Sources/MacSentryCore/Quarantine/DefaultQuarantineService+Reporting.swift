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
        var changed = Set<Int64>()
        for manifest in loadManifests() {
            try changed.formUnion(importManifest(manifest))
        }
        let candidates = try read { db in
            try QuarantineEntry
                .filter(Column("status") == QuarantineStatus.inQuarantine.rawValue)
                .filter(sql: "batch_id IN (SELECT id FROM quarantine_batch WHERE dry_run = 0)")
                .fetchAll(db)
        }
        let vanished = candidates.filter { !FileSystemCalls.exists($0.quarantineURL) }
        if !vanished.isEmpty {
            try write { db in
                for var entry in vanished {
                    entry.status = .missing
                    try entry.update(db)
                }
            }
            changed.formUnion(vanished.map(\.batchID))
        }
        for batchID in changed.sorted() {
            rewriteManifest(batchID: batchID)
        }
    }

    private func loadManifests() -> [QuarantineManifest] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: quarantineRoot,
            includingPropertiesForKeys: nil,
        )) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            guard (try? FileSystemCalls.status(of: folder))?.isDirectory == true else { return nil }
            let manifestURL = folder.appending(path: Self.manifestName, directoryHint: .notDirectory)
            guard FileSystemCalls.exists(manifestURL) else { return nil }
            do {
                let manifest = try QuarantineManifest.decode(Data(contentsOf: manifestURL))
                guard manifest.batch == folder.lastPathComponent else { return nil }
                return manifest
            } catch {
                logger.error("Skipping unreadable manifest in \(folder.lastPathComponent, privacy: .public)")
                return nil
            }
        }
    }

    private func importManifest(_ manifest: QuarantineManifest) throws -> Set<Int64> {
        let folder = quarantineRoot.appending(path: manifest.batch, directoryHint: .isDirectory)
        let createdAt = manifest.createdDate(timeZone: timeZone) ?? now()
        return try write { db in
            var batch = try QuarantineBatch.filter(Column("folder_name") == manifest.batch).fetchOne(db)
                ?? QuarantineBatch(folderName: manifest.batch, createdAt: createdAt, dryRun: manifest.dryRun)
            if batch.id == nil {
                try batch.insert(db)
            }
            guard let batchID = batch.id else { return [] }
            var inserted = false
            for item in manifest.entries {
                let quarantineURL = URL(storagePath: item.quarantinePath)
                guard item.originalPath.hasPrefix("/"), Self.isStrictlyInside(quarantineURL, folder) else { continue }
                let exists = try QuarantineEntry
                    .filter(Column("batch_id") == batchID && Column("quarantine_path") == quarantineURL.storagePath)
                    .fetchCount(db) > 0
                if exists {
                    continue
                }
                var entry = QuarantineEntry(
                    batchID: batchID,
                    originalURL: URL(storagePath: item.originalPath),
                    quarantineURL: quarantineURL,
                    kind: item.kind,
                    ruleID: item.ruleId,
                    tier: item.tier,
                    size: item.size,
                    quarantinedAt: createdAt,
                    status: item.status,
                )
                try entry.insert(db)
                inserted = true
            }
            return inserted ? [batchID] : []
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
