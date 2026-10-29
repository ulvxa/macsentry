import Darwin
import Foundation

extension DefaultQuarantineService {
    static let journalName = "journal.jsonl"

    func journalURL(_ batch: QuarantineBatch) -> URL {
        batchFolder(batch).appending(path: Self.journalName, directoryHint: .notDirectory)
    }

    func verifiedQuarantineURL(_ entry: QuarantineEntry, in batch: QuarantineBatch) throws(EntryFailureReason) -> URL {
        let folder = batchFolder(batch)
        guard Self.isMirrored(entry.quarantineURL.storagePath, original: entry.originalURL.storagePath, in: folder) else {
            throw .outsideQuarantine
        }
        let realFolder: NormalizedPath
        let realParent: String
        do {
            realFolder = try NormalizedPath(absolutePath: FileSystemCalls.realPath(folder))
            realParent = try FileSystemCalls.realPath(entry.quarantineURL.deletingLastPathComponent())
        } catch {
            throw EntryFailureReason(errno: error.code)
        }
        let parent = NormalizedPath(absolutePath: realParent)
        guard parent.count > realFolder.count, parent.isInside(realFolder) else {
            logger.error("Quarantine path \(entry.quarantineURL.storagePath, privacy: .private) resolves outside its batch")
            throw .outsideQuarantine
        }
        let physical = URL(filePath: parent.path, directoryHint: .isDirectory).appending(path: entry.quarantineURL.lastPathComponent)
        let info: FileStatus
        do {
            info = try FileSystemCalls.status(of: physical)
        } catch {
            throw EntryFailureReason(errno: error.code)
        }
        guard !info.isSymlink else { throw .outsideQuarantine }
        return physical
    }

    static func isMirrored(_ quarantinePath: String, original originalPath: String, in folder: URL) -> Bool {
        let components = originalPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard originalPath.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { return false }
        let expected = folder.appending(path: String(originalPath.dropFirst()))
        return quarantinePath == expected.storagePath && isStrictlyInside(expected, folder)
    }

    func appendJournal(_ entry: QuarantineEntry, status: QuarantineStatus, batch: QuarantineBatch) {
        guard !batch.dryRun, !isDryRun else { return }
        var line = QuarantineManifest.Entry(entry)
        line.status = status
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        do {
            try FileSystemCalls.appendLine(encoder.encode(line), to: journalURL(batch))
        } catch {
            logger
                .error(
                    "Appending to journal of \(batch.folderName, privacy: .public) failed: \(String(describing: error), privacy: .public)",
                )
        }
    }

    static func journalEntries(in folder: URL) -> [QuarantineManifest.Entry] {
        guard let data = try? Data(contentsOf: folder.appending(path: journalName, directoryHint: .notDirectory)) else { return [] }
        let decoder = JSONDecoder()
        var latest: [String: QuarantineManifest.Entry] = [:]
        var order: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = try? decoder.decode(QuarantineManifest.Entry.self, from: Data(line)) else { continue }
            if latest.updateValue(entry, forKey: entry.quarantinePath) == nil {
                order.append(entry.quarantinePath)
            }
        }
        return order.compactMap { latest[$0] }.filter { $0.status == .inQuarantine }
    }

    static func batchDate(fromFolderName name: String, timeZone: TimeZone) -> Date? {
        let digits = name.prefix(17)
        guard digits.count == 17 else { return nil }
        let parts = digits.split(separator: "_")
        let day = parts.first?.split(separator: "-").compactMap { Int($0) } ?? []
        guard parts.count == 2, day.count == 3, let time = parts.last, time.count == 6, let clock = Int(time) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: day[0], month: day[1], day: day[2], hour: clock / 10000, minute: clock / 100 % 100, second: clock % 100,
        ))
    }

    func untrackedItems(in batch: QuarantineBatch, entries: [QuarantineEntry]) -> [URL] {
        let folder = batchFolder(batch).storagePath
        let tracked = Set(entries.filter { $0.status == .inQuarantine || $0.status == .missing }.map(\.quarantineURL.storagePath))
        var ancestors = Set<String>()
        for path in tracked {
            var parent = URL(storagePath: path).deletingLastPathComponent().storagePath
            while parent.count > folder.count, ancestors.insert(parent).inserted {
                parent = URL(storagePath: parent).deletingLastPathComponent().storagePath
            }
        }
        var untracked: [URL] = []
        var stack = [folder]
        while let directory = stack.popLast() {
            for name in Self.children(of: directory) {
                let path = directory + "/" + name
                if tracked.contains(path) || name == ".DS_Store"
                    || (directory == folder && (name == Self.manifestName || name == Self.journalName)) {
                    continue
                }
                if Self.isRealDirectory(path) {
                    if ancestors.contains(path) {
                        stack.append(path)
                    } else if Self.holdsContent(path) {
                        untracked.append(URL(filePath: path))
                    }
                } else {
                    untracked.append(URL(filePath: path))
                }
            }
        }
        return untracked.sorted { $0.storagePath < $1.storagePath }
    }

    private static func children(of directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        (try? FileSystemCalls.status(of: URL(filePath: path)))?.isDirectory == true
    }

    static func holdsContent(_ directory: String) -> Bool {
        var stack = [directory]
        while let current = stack.popLast() {
            for name in children(of: current) where name != ".DS_Store" {
                let path = current + "/" + name
                guard isRealDirectory(path) else { return true }
                stack.append(path)
            }
        }
        return false
    }
}
