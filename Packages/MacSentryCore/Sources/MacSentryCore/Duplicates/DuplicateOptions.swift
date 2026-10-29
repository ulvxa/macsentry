import Foundation

public struct DuplicateOptions: Sendable, Equatable {
    public static let defaultMinSize: Int64 = 1_000_000
    public static let defaultConcurrency = 4

    public var roots: [URL]
    public var minSize: Int64
    public var concurrency: Int
    public var homeURL: URL
    public var sessionID: Int64

    public init(
        roots: [URL],
        minSize: Int64 = DuplicateOptions.defaultMinSize,
        concurrency: Int = DuplicateOptions.defaultConcurrency,
        homeURL: URL,
        sessionID: Int64,
    ) {
        self.roots = roots
        self.minSize = minSize
        self.concurrency = concurrency
        self.homeURL = homeURL
        self.sessionID = sessionID
    }

    public static func defaultRoots(homeURL: URL) -> [URL] {
        ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"].map {
            homeURL.appending(path: $0, directoryHint: .isDirectory)
        }
    }
}
