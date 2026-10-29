import Foundation

public struct ScanConfig: Sendable, Equatable {
    public static let alwaysExcluded: [URL] = [
        "/System", "/Volumes", "/dev", "/private/var/vm", "/private/var/db", "/Library/Apple",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.MobileBackups",
    ].map { URL(filePath: $0, directoryHint: .isDirectory) }

    public var roots: [URL]
    public var excluded: [URL]
    public var candidateExcluded: [URL]
    public var maxConcurrency: Int
    public var treeDepth: Int
    public var minTreeNodeSize: Int64

    public init(
        roots: [URL],
        excluded: [URL] = [],
        candidateExcluded: [URL] = [],
        maxConcurrency: Int = 8,
        treeDepth: Int = 8,
        minTreeNodeSize: Int64 = 10_000_000,
    ) {
        self.roots = roots
        self.excluded = excluded
        self.candidateExcluded = candidateExcluded
        self.maxConcurrency = max(1, maxConcurrency)
        self.treeDepth = max(0, treeDepth)
        self.minTreeNodeSize = minTreeNodeSize
    }

    public init(environment: AppEnvironment, quarantineFolder: URL?) {
        let root = environment.scanRoot ?? URL(filePath: "/", directoryHint: .isDirectory)
        self.init(
            roots: [root],
            excluded: quarantineFolder.map { [$0] } ?? [],
            candidateExcluded: Self.cloudStorageFolders(home: environment.homeURL),
        )
    }

    public static func cloudStorageFolders(home: URL) -> [URL] {
        ["Library/Mobile Documents", "Library/CloudStorage"].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    var effectiveExcluded: [URL] {
        excluded + Self.alwaysExcluded
    }
}

public enum ScanPhase: String, Sendable, Codable, CaseIterable {
    case walking, evaluatingRules, projects, orphans, duplicates, lastUsed
}

public enum ScanEvent: Sendable {
    case started(sessionID: Int64)
    case progress(filesVisited: Int, bytesVisited: Int64, currentPath: String)
    case candidates([Candidate])
    case phase(ScanPhase)
    case finished(ScanSummary)
}

public struct ScanSummary: Sendable, Equatable {
    public let sessionID: Int64
    public let status: ScanStatus
    public let duration: Duration
    public let filesVisited: Int
    public let bytesVisited: Int64
    public let unreadable: [URL]
    public let skippedDataless: Int
    public let candidateCount: Int
    public let totalFreeable: Int64

    public init(
        sessionID: Int64,
        status: ScanStatus,
        duration: Duration,
        filesVisited: Int,
        bytesVisited: Int64,
        unreadable: [URL],
        skippedDataless: Int,
        candidateCount: Int,
        totalFreeable: Int64,
    ) {
        self.sessionID = sessionID
        self.status = status
        self.duration = duration
        self.filesVisited = filesVisited
        self.bytesVisited = bytesVisited
        self.unreadable = unreadable
        self.skippedDataless = skippedDataless
        self.candidateCount = candidateCount
        self.totalFreeable = totalFreeable
    }
}

public enum ScanError: LocalizedError, Equatable {
    case rootUnavailable(URL, errno: Int32)
    case rootNotDirectory(URL)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case let .rootUnavailable(url, code):
            "Cannot scan \(url.path(percentEncoded: false)): \(String(cString: strerror(code)))"
        case let .rootNotDirectory(url):
            "Cannot scan \(url.path(percentEncoded: false)): not a folder"
        case let .persistence(reason):
            "Could not save scan results: \(reason)"
        }
    }
}
