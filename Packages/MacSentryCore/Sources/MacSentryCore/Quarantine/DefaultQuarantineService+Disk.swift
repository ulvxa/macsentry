import Darwin
import Foundation
import GRDB

extension DefaultQuarantineService {
    static let readme = """
    MacSentry Quarantine

    MacSentry moves items it cleans up into this folder instead of deleting them.
    Each subfolder is one cleanup batch, named by date and time. Inside it, every item
    sits at its original path, and manifest.json lists what was moved and from where.

    Use the Quarantine screen in MacSentry to restore items or move them to the Trash.
    Nothing here is deleted until you empty the Trash yourself.
    """

    func batchFolder(_ batch: QuarantineBatch) -> URL {
        quarantineRoot.appending(path: batch.folderName, directoryHint: .isDirectory)
    }

    func destinationURL(for source: URL, in batch: QuarantineBatch) -> URL {
        let relative = String(source.storagePath.drop { $0 == "/" })
        return batchFolder(batch).appending(path: relative)
    }

    func overlapsQuarantine(_ url: URL) -> Bool {
        Self.isInside(url, quarantineRoot) || Self.isInside(quarantineRoot, url)
    }

    static func isInside(_ url: URL, _ ancestor: URL) -> Bool {
        let path = url.storagePath
        let base = ancestor.storagePath
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    static func isStrictlyInside(_ url: URL, _ ancestor: URL) -> Bool {
        url.storagePath != ancestor.storagePath && isInside(url, ancestor)
    }

    func prepareQuarantineRoot() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
        let marker = quarantineRoot.appending(path: ".metadata_never_index", directoryHint: .notDirectory)
        if !FileSystemCalls.exists(marker) {
            try Data().write(to: marker, options: .withoutOverwriting)
        }
        let readmeURL = quarantineRoot.appending(path: "README.txt", directoryHint: .notDirectory)
        if !FileSystemCalls.exists(readmeURL) {
            try Data(Self.readme.utf8).write(to: readmeURL, options: .withoutOverwriting)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = quarantineRoot
        try root.setResourceValues(values)
    }

    func writeManifest(_ batch: QuarantineBatch, entries: [QuarantineEntry]) {
        guard !batch.dryRun, !isDryRun else { return }
        let folder = batchFolder(batch)
        guard (try? FileSystemCalls.status(of: folder))?.isDirectory == true else { return }
        let manifest = QuarantineManifest(batch: batch, entries: entries, timeZone: timeZone)
        do {
            try manifest.encoded().write(to: folder.appending(path: Self.manifestName, directoryHint: .notDirectory), options: .atomic)
        } catch {
            logger.error("Writing manifest \(batch.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func rewriteManifest(batchID: Int64) {
        do {
            let loaded = try database.writer.read { db -> (QuarantineBatch?, [QuarantineEntry]) in
                let batch = try QuarantineBatch.fetchOne(db, key: batchID)
                let entries = try QuarantineEntry.filter(Column("batch_id") == batchID).order(Column("id")).fetchAll(db)
                return (batch, entries)
            }
            if let batch = loaded.0 {
                writeManifest(batch, entries: loaded.1)
            }
        } catch {
            logger.error("Loading batch \(batchID) for manifest failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finishBatches(_ batchIDs: Set<Int64>) {
        for batchID in batchIDs.sorted() {
            rewriteManifest(batchID: batchID)
            trashBatchFolderIfSettled(batchID: batchID)
        }
    }

    func trashBatchFolderIfSettled(batchID: Int64) {
        let loaded = try? database.writer.read { db -> (QuarantineBatch?, Int) in
            let unsettled = try QuarantineEntry
                .filter(Column("batch_id") == batchID && Column("status") == QuarantineStatus.inQuarantine.rawValue)
                .fetchCount(db)
            return try (QuarantineBatch.fetchOne(db, key: batchID), unsettled)
        }
        guard !activeBatchIDs.contains(batchID), let loaded, let batch = loaded.0, loaded.1 == 0, !batch.dryRun, !isDryRun else { return }
        let folder = batchFolder(batch)
        guard (try? FileSystemCalls.status(of: folder))?.isDirectory == true else { return }
        removeEmptyDirectories(below: folder)
        guard containsOnlyLeftovers(folder) else {
            logger.notice("Batch \(batch.folderName, privacy: .public) still holds unexpected items, leaving it in place")
            return
        }
        do {
            _ = try trasher.trash(folder)
        } catch {
            logger.error("Trashing batch \(batch.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeEmptyDirectories(below folder: URL) {
        let directories = descendants(of: folder).filter { (try? FileSystemCalls.status(of: $0))?.isDirectory == true }
        for directory in directories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            FileSystemCalls.removeEmptyDirectory(directory)
        }
    }

    private func containsOnlyLeftovers(_ folder: URL) -> Bool {
        let ownFiles = Set([Self.manifestName, Self.journalName].map {
            folder.appending(path: $0, directoryHint: .notDirectory).storagePath
        })
        return descendants(of: folder).allSatisfy { url in
            guard let info = try? FileSystemCalls.status(of: url) else { return true }
            if info.isDirectory {
                return true
            }
            guard info.mode & S_IFMT == S_IFREG else { return false }
            return ownFiles.contains(url.storagePath) || url.lastPathComponent == ".DS_Store"
        }
    }

    private func descendants(of folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }

    static func batchFolderName(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d_%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
        )
    }
}
