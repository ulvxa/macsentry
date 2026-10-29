import Darwin
import Foundation

public struct BulkFileWalker: ReportingFileWalker {
    public let maxConcurrency: Int

    public init(maxConcurrency: Int = 8) {
        self.maxConcurrency = max(1, maxConcurrency)
    }

    public func walk(
        root: URL,
        excluded: [URL],
        onIssue: @escaping @Sendable (WalkIssue) -> Void,
        visit: @Sendable (FileEntry) async -> WalkDecision,
    ) async throws {
        try await walk(root: root, excluded: excluded, pool: ReaderPool(), onIssue: onIssue, visit: visit)
    }

    func walk(
        root: URL,
        excluded: [URL],
        pool: ReaderPool,
        onIssue: @escaping @Sendable (WalkIssue) -> Void,
        visit: @Sendable (FileEntry) async -> WalkDecision,
    ) async throws {
        let rootPath = WalkRules.path(of: root)
        let excludedPaths = Set(excluded.map(WalkRules.path(of:)))
        guard !WalkRules.isInside(rootPath, anyOf: excludedPaths) else { return }

        var info = stat()
        guard lstat(rootPath, &info) == 0 else { throw ScanError.rootUnavailable(root, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ScanError.rootNotDirectory(root) }
        let devices = WalkRules.allowedDevices(rootPath: rootPath, rootDevice: info.st_dev)
        let limit = maxConcurrency

        try await withoutActuallyEscaping(visit) { visit in
            let job = WalkJob(excluded: excludedPaths, devices: devices, pool: pool, onIssue: onIssue, visit: visit)
            try await withThrowingTaskGroup(of: [String].self) { group in
                var stack = [rootPath]
                var inFlight = 0
                while true {
                    while inFlight < limit, let directory = stack.popLast() {
                        group.addTask { try await job.process(directory) }
                        inFlight += 1
                    }
                    guard let subdirectories = try await group.next() else { break }
                    inFlight -= 1
                    stack.append(contentsOf: subdirectories)
                }
            }
        }
    }
}

struct WalkJob: Sendable {
    let excluded: Set<String>
    let devices: Set<Int32>
    let pool: ReaderPool
    let onIssue: @Sendable (WalkIssue) -> Void
    let visit: @Sendable (FileEntry) async -> WalkDecision

    func process(_ directory: String) async throws -> [String] {
        try Task.checkCancellation()
        let reader = pool.checkout()
        defer { pool.checkin(reader) }
        guard let entries = read(directory, reader) else { return [] }

        var subdirectories: [String] = []
        for (index, raw) in entries.enumerated() {
            if index & 0xFFF == 0xFFF {
                try Task.checkCancellation()
            }
            if let subdirectory = try await handle(raw, in: directory, reader) {
                subdirectories.append(subdirectory)
            }
        }
        return subdirectories
    }

    func handle(_ raw: RawEntry, in directory: String, _ reader: DirectoryReader) async throws -> String? {
        guard isReadable(raw, in: directory) else { return nil }
        let path = WalkRules.join(directory, raw.name)
        guard !excluded.contains(path) else { return nil }
        guard !WalkRules.isDataless(flags: raw.flags) else {
            onIssue(.skippedDataless(WalkRules.url(path, kind: raw.isDirectory ? .folder : .file)))
            return nil
        }
        switch raw.type {
        case VREG.rawValue:
            _ = await visit(entry(raw, path: path, kind: .file))
        case VLNK.rawValue:
            _ = await visit(entry(raw, path: path, kind: .symlink))
        case VDIR.rawValue where devices.contains(raw.device):
            if WalkRules.isPackage(name: raw.name, finderFlags: raw.finderFlags) {
                let summary = try sizePackage(path, reader)
                _ = await visit(entry(raw, path: path, kind: .package, summary: summary))
            } else if await visit(entry(raw, path: path, kind: .folder)) == .descend {
                return path
            }
        default:
            break
        }
        return nil
    }

    private func read(_ directory: String, _ reader: DirectoryReader) -> [RawEntry]? {
        switch reader.read(directory, allowedDevices: devices) {
        case let .entries(entries):
            return entries
        case let .partial(entries, code):
            onIssue(.unreadable(WalkRules.url(directory, kind: .folder), errno: code))
            return entries
        case .otherDevice:
            return nil
        case let .failed(code):
            if code != ENOENT, code != ENOTDIR {
                onIssue(.unreadable(WalkRules.url(directory, kind: .folder), errno: code))
            }
            return nil
        }
    }

    private func sizePackage(_ root: String, _ reader: DirectoryReader) throws -> FolderSummary {
        var accumulator = SizeAccumulator()
        var stack = [root]
        while let directory = stack.popLast() {
            try Task.checkCancellation()
            guard let entries = read(directory, reader) else { continue }
            for raw in entries where isReadable(raw, in: directory) {
                let path = WalkRules.join(directory, raw.name)
                guard !excluded.contains(path), !WalkRules.isDataless(flags: raw.flags) else { continue }
                switch raw.type {
                case VREG.rawValue, VLNK.rawValue:
                    accumulator.add(SizedItem(
                        kind: raw.type == VREG.rawValue ? .file : .symlink,
                        logical: raw.logicalSize,
                        allocated: raw.allocatedSize,
                        privateSize: raw.privateSize,
                        linkCount: raw.linkCount,
                        key: InodeKey(device: raw.device, inode: raw.inode),
                        modified: raw.modified,
                    ))
                case VDIR.rawValue where devices.contains(raw.device):
                    stack.append(path)
                default:
                    continue
                }
            }
        }
        return accumulator.summary
    }

    private func isReadable(_ raw: RawEntry, in directory: String) -> Bool {
        guard raw.error != 0 else { return true }
        let url = raw.name.isEmpty
            ? WalkRules.url(directory, kind: .folder)
            : WalkRules.url(WalkRules.join(directory, raw.name), kind: raw.isDirectory ? .folder : .file)
        onIssue(.unreadable(url, errno: Int32(bitPattern: raw.error)))
        return false
    }

    private func entry(_ raw: RawEntry, path: String, kind: EntryKind, summary: FolderSummary? = nil) -> FileEntry {
        FileEntry(
            url: WalkRules.url(path, kind: kind),
            kind: kind,
            logicalSize: summary?.size.logical ?? (kind == .folder ? 0 : raw.logicalSize),
            allocatedSize: summary?.size.allocated ?? (kind == .folder ? 0 : raw.allocatedSize),
            privateSize: summary?.size.freeable ?? (kind == .file ? raw.privateSize : nil),
            linkCount: kind == .file ? raw.linkCount : 1,
            inode: raw.inode,
            device: raw.device,
            flags: raw.flags,
            created: raw.created,
            modified: raw.modified,
            added: raw.added,
            ownerUID: raw.ownerUID,
        )
    }
}
