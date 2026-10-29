import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

public enum WalkIssue: Sendable, Equatable {
    case unreadable(URL, errno: Int32)
    case skippedDataless(URL)
}

public protocol ReportingFileWalker: FileWalker {
    func walk(
        root: URL,
        excluded: [URL],
        onIssue: @escaping @Sendable (WalkIssue) -> Void,
        visit: @Sendable (FileEntry) async -> WalkDecision,
    ) async throws
}

public extension ReportingFileWalker {
    func walk(root: URL, excluded: [URL], visit: @Sendable (FileEntry) async -> WalkDecision) async throws {
        try await walk(root: root, excluded: excluded, onIssue: { _ in }, visit: visit)
    }
}

public struct FolderSummary: Sendable, Equatable {
    public let size: SizeInfo
    public let itemCount: Int
    public let latestModified: Date?

    public init(size: SizeInfo, itemCount: Int, latestModified: Date?) {
        self.size = size
        self.itemCount = itemCount
        self.latestModified = latestModified
    }
}

struct InodeKey: Hashable {
    let device: Int32
    let inode: UInt64
}

struct SizedItem {
    let kind: EntryKind
    let logical: Int64
    let allocated: Int64
    let privateSize: Int64?
    let linkCount: UInt32
    let key: InodeKey
    let modified: Date?
}

struct SizeAccumulator {
    private struct LinkTally {
        var seen: Int
        let linkCount: UInt32
        let logical: Int64
        let allocated: Int64
        let freeable: Int64
    }

    private var logical: Int64 = 0
    private var allocated: Int64 = 0
    private var freeable: Int64 = 0
    private var itemCount = 0
    private var latestModified: Date?
    private var links: [InodeKey: LinkTally] = [:]

    mutating func add(_ entry: FileEntry) {
        add(SizedItem(
            kind: entry.kind, logical: entry.logicalSize, allocated: entry.allocatedSize, privateSize: entry.privateSize,
            linkCount: entry.linkCount, key: InodeKey(device: entry.device, inode: entry.inode), modified: entry.modified,
        ))
    }

    mutating func add(_ item: SizedItem) {
        if let modified = item.modified, latestModified.map({ modified > $0 }) ?? true {
            latestModified = modified
        }
        guard item.kind != .folder else { return }
        itemCount += 1
        let own = TrueSize.freeable(kind: item.kind, allocated: item.allocated, privateSize: item.privateSize, linkCount: 1)
        guard item.kind == .file, item.linkCount > 1 else {
            logical += item.logical
            allocated += item.allocated
            freeable += own
            return
        }
        if links[item.key] != nil {
            links[item.key]?.seen += 1
        } else {
            links[item.key] = LinkTally(
                seen: 1, linkCount: item.linkCount, logical: item.logical, allocated: item.allocated, freeable: own,
            )
        }
    }

    var summary: FolderSummary {
        var logical = logical
        var allocated = allocated
        var freeable = freeable
        for tally in links.values {
            logical += tally.logical
            allocated += tally.allocated
            if tally.seen >= Int(tally.linkCount) {
                freeable += tally.freeable
            }
        }
        return FolderSummary(
            size: SizeInfo(logical: logical, allocated: allocated, freeable: freeable),
            itemCount: itemCount,
            latestModified: latestModified,
        )
    }
}

enum TrueSize {
    static func freeable(kind: EntryKind, allocated: Int64, privateSize: Int64?, linkCount: UInt32) -> Int64 {
        switch kind {
        case .folder, .package:
            privateSize ?? allocated
        case .symlink:
            allocated
        case .file:
            linkCount > 1 ? 0 : min(privateSize ?? allocated, allocated)
        }
    }
}

enum WalkRules {
    private static let packageExtensions: Set = [
        "app", "photoslibrary", "vmwarevm", "bundle", "xcarchive", "framework", "plugin", "kext", "appex", "xpc",
        "pvm", "utm", "musiclibrary", "fcpbundle", "logicx", "imovielibrary", "tvlibrary", "rtfd", "pkg", "mpkg",
        "band", "xcodeproj", "xcworkspace", "playground", "docarchive", "sparsebundle", "dsym", "photolibrary",
    ]
    private static let typeCache = Mutex<[String: Bool]>([:])
    private static let hasBundleFinderFlag: UInt16 = 0x2000

    static func isDataless(flags: UInt32) -> Bool {
        flags & UInt32(SF_DATALESS) != 0
    }

    static func isPackage(name: String, finderFlags: UInt16 = 0) -> Bool {
        if finderFlags & hasBundleFinderFlag != 0 {
            return true
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        guard !ext.isEmpty else { return false }
        if packageExtensions.contains(ext) {
            return true
        }
        if let cached = typeCache.withLock({ $0[ext] }) {
            return cached
        }
        let conforms = UTType(filenameExtension: ext, conformingTo: .directory)?.conforms(to: .package) ?? false
        typeCache.withLock { $0[ext] = conforms }
        return conforms
    }

    static func path(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    static func isInside(_ path: String, anyOf roots: Set<String>) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    static func allowedDevices(rootPath: String, rootDevice: Int32) -> Set<Int32> {
        var devices: Set = [rootDevice]
        var info = stat()
        // `/` is the sealed system volume; /Users, /Applications etc. are firmlinks onto the Data volume.
        if rootPath == "/", lstat("/System/Volumes/Data", &info) == 0 {
            devices.insert(info.st_dev)
        }
        return devices
    }

    static func url(_ path: String, kind: EntryKind) -> URL {
        URL(filePath: path, directoryHint: kind == .folder || kind == .package ? .isDirectory : .notDirectory)
    }
}
