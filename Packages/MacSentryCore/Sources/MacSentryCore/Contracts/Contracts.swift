import Foundation

public enum ProtectionVerdict: Sendable, Equatable {
    case allowed
    case denied(String)
}

public protocol ProtectionPolicy: Sendable {
    func check(_ url: URL) -> ProtectionVerdict
}

public struct InstalledApp: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let version: String?
    public let url: URL
    public let executable: String?

    public init(bundleID: String, name: String, version: String?, url: URL, executable: String? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.url = url
        self.executable = executable
    }
}

public protocol AppInventory: Sendable {
    func installedApps() async -> [InstalledApp]
    func isRunning(bundleID: String) -> Bool
    /// Localized and executable names of running apps, for folders no installed app could be attributed to.
    func runningAppNames() -> [String]
}

public extension AppInventory {
    func runningAppNames() -> [String] {
        []
    }
}

public enum EntryKind: String, Sendable, Codable {
    case file, folder, package, symlink
}

public struct FileEntry: Sendable, Equatable {
    public let url: URL
    public let kind: EntryKind
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let privateSize: Int64?
    public let linkCount: UInt32
    public let inode: UInt64
    public let device: Int32
    public let flags: UInt32
    public let created: Date?
    public let modified: Date?
    public let ownerUID: uid_t

    public init(
        url: URL,
        kind: EntryKind,
        logicalSize: Int64,
        allocatedSize: Int64,
        privateSize: Int64?,
        linkCount: UInt32,
        inode: UInt64,
        device: Int32,
        flags: UInt32,
        created: Date?,
        modified: Date?,
        ownerUID: uid_t,
    ) {
        self.url = url
        self.kind = kind
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.linkCount = linkCount
        self.inode = inode
        self.device = device
        self.flags = flags
        self.created = created
        self.modified = modified
        self.ownerUID = ownerUID
    }
}

public enum WalkDecision: Sendable {
    case descend, skipChildren
}

public protocol FileWalker: Sendable {
    func walk(root: URL, excluded: [URL], visit: @Sendable (FileEntry) async -> WalkDecision) async throws
}

public struct SizeInfo: Sendable, Equatable {
    public let logical: Int64
    public let allocated: Int64
    public let freeable: Int64

    public init(logical: Int64, allocated: Int64, freeable: Int64) {
        self.logical = logical
        self.allocated = allocated
        self.freeable = freeable
    }
}

public protocol SizeCalculator: Sendable {
    func sizeInfo(for entry: FileEntry) -> SizeInfo
    func aggregate(folder: URL) async throws -> SizeInfo
}

public struct Thresholds: Sendable, Equatable {
    public var minAgeDays: Int
    public var minSize: Int64
    public var ageBasis: AgeBasis

    public init(minAgeDays: Int = 180, minSize: Int64 = 500_000_000, ageBasis: AgeBasis = .lastUsed) {
        self.minAgeDays = minAgeDays
        self.minSize = minSize
        self.ageBasis = ageBasis
    }
}
