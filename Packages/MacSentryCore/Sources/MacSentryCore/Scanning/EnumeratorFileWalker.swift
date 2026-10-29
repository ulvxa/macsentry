import Darwin
import Foundation

public struct EnumeratorFileWalker: ReportingFileWalker {
    public init() {}

    public func walk(
        root: URL,
        excluded: [URL],
        onIssue: @escaping @Sendable (WalkIssue) -> Void,
        visit: @Sendable (FileEntry) async -> WalkDecision,
    ) async throws {
        let rootPath = WalkRules.path(of: root)
        let excludedPaths = Set(excluded.map(WalkRules.path(of:)))
        guard !WalkRules.isInside(rootPath, anyOf: excludedPaths) else { return }
        guard let rootInfo = Self.info(rootPath) else { throw ScanError.rootUnavailable(root, errno: errno) }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw ScanError.rootNotDirectory(root) }
        let devices = WalkRules.allowedDevices(rootPath: rootPath, rootDevice: rootInfo.st_dev)

        let enumerator = FileManager.default.enumerator(atPath: rootPath)
        while let relative = enumerator?.nextObject() as? String {
            let path = WalkRules.join(rootPath, relative)
            guard let info = Self.info(path) else { continue }
            if info.st_mode & S_IFMT == S_IFDIR {
                try Task.checkCancellation()
            }
            if WalkRules.isDataless(flags: info.st_flags) {
                onIssue(.skippedDataless(WalkRules.url(path, kind: info.st_mode & S_IFMT == S_IFDIR ? .folder : .file)))
                enumerator?.skipDescendants()
            } else if excludedPaths.contains(path) {
                enumerator?.skipDescendants()
            } else if try await !handle(path, info, devices: devices, excluded: excludedPaths, visit: visit) {
                enumerator?.skipDescendants()
            } else if info.st_mode & S_IFMT == S_IFDIR, access(path, R_OK | X_OK) != 0 {
                onIssue(.unreadable(WalkRules.url(path, kind: .folder), errno: errno))
            }
        }
    }

    private func handle(
        _ path: String,
        _ info: stat,
        devices: Set<Int32>,
        excluded: Set<String>,
        visit: @Sendable (FileEntry) async -> WalkDecision,
    ) async throws -> Bool {
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            _ = await visit(Self.entry(path, info, kind: .file))
        case S_IFLNK:
            _ = await visit(Self.entry(path, info, kind: .symlink))
        case S_IFDIR where devices.contains(info.st_dev):
            let url = WalkRules.url(path, kind: .folder)
            if WalkRules.isPackage(name: url.lastPathComponent) || Self.isPackage(url) {
                let summary = try Self.sizePackage(path, devices: devices, excluded: excluded)
                _ = await visit(Self.entry(path, info, kind: .package, summary: summary))
                return false
            }
            return await visit(Self.entry(path, info, kind: .folder)) == .descend
        case S_IFDIR:
            return false
        default:
            break
        }
        return true
    }

    private static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    private static func info(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func sizePackage(_ root: String, devices: Set<Int32>, excluded: Set<String>) throws -> FolderSummary {
        var accumulator = SizeAccumulator()
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            let path = WalkRules.join(root, relative)
            guard let info = info(path) else { continue }
            let skip = excluded.contains(path) || WalkRules.isDataless(flags: info.st_flags)
            switch info.st_mode & S_IFMT {
            case S_IFREG where !skip:
                accumulator.add(entry(path, info, kind: .file))
            case S_IFLNK where !skip:
                accumulator.add(entry(path, info, kind: .symlink))
            case S_IFDIR:
                try Task.checkCancellation()
                if skip || !devices.contains(info.st_dev) {
                    enumerator?.skipDescendants()
                }
            default:
                continue
            }
        }
        return accumulator.summary
    }

    private static func entry(_ path: String, _ info: stat, kind: EntryKind, summary: FolderSummary? = nil) -> FileEntry {
        let isItem = kind == .file || kind == .symlink
        return FileEntry(
            url: WalkRules.url(path, kind: kind),
            kind: kind,
            logicalSize: summary?.size.logical ?? (isItem ? Int64(info.st_size) : 0),
            allocatedSize: summary?.size.allocated ?? (isItem ? Int64(info.st_blocks) * 512 : 0),
            privateSize: summary?.size.freeable,
            linkCount: kind == .file ? UInt32(info.st_nlink) : 1,
            inode: info.st_ino,
            device: info.st_dev,
            flags: info.st_flags,
            created: date(info.st_birthtimespec),
            modified: date(info.st_mtimespec),
            ownerUID: info.st_uid,
        )
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }
}
