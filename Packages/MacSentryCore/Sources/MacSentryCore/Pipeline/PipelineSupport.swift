import Darwin
import Foundation
import GRDB
import Synchronization

public enum ScanPipelineError: LocalizedError, Equatable {
    case protectionUnavailable(String)
    case catalogUnavailable(String)
    case persistence(String)
    case artifactNotRecorded(URL)

    public var errorDescription: String? {
        switch self {
        case let .protectionUnavailable(reason):
            "Could not load the protection list, scan stopped: \(reason)"
        case let .catalogUnavailable(reason):
            "Could not load the cleanup rules: \(reason)"
        case let .persistence(reason):
            "Could not save scan results: \(reason)"
        case let .artifactNotRecorded(url):
            "\(url.lastPathComponent) was not recorded during the scan"
        }
    }
}

struct CandidateGate: Sendable {
    let policy: any ProtectionPolicy
    let excluded: Set<String>

    init(policy: any ProtectionPolicy, excluded: [URL]) {
        self.policy = policy
        self.excluded = Set(excluded.map(WalkRules.path(of:)))
    }

    /// flagOnly items are never moved, so they stay visible even on protected paths.
    func admits(_ url: URL, action: CandidateAction) -> Bool {
        guard !WalkRules.isInside(url.storagePath, anyOf: excluded) else { return false }
        return action == .flagOnly || policy.check(url) == .allowed
    }
}

final class WalkClaims: Sendable {
    private let paths = Mutex<Set<String>>([])

    func insert(_ url: URL) {
        paths.withLock { _ = $0.insert(url.storagePath) }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.storagePath
        return paths.withLock { $0.contains(path) }
    }
}

struct EmittedPaths: Sendable {
    private let exact: Set<String>
    private let ancestors: Set<String>

    init(_ paths: [String]) {
        exact = Set(paths)
        var ancestors = Set<String>()
        for path in paths {
            var cursor = Substring(path)
            while let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
                cursor = cursor[..<slash]
                guard ancestors.insert(String(cursor)).inserted else { break }
            }
        }
        self.ancestors = ancestors
    }

    static func load(session: Int64, database: Database) async throws -> EmittedPaths {
        do {
            let paths = try await database.writer.read { db in
                try String.fetchAll(db, sql: "SELECT path FROM candidate WHERE session_id = ?", arguments: [session])
            }
            return EmittedPaths(paths)
        } catch {
            throw ScanPipelineError.persistence(error.localizedDescription)
        }
    }

    func overlaps(_ url: URL) -> Bool {
        let path = url.storagePath
        if exact.contains(path) || ancestors.contains(path) {
            return true
        }
        var cursor = Substring(path)
        while let slash = cursor.lastIndex(of: "/"), slash > cursor.startIndex {
            cursor = cursor[..<slash]
            if exact.contains(String(cursor)) {
                return true
            }
        }
        return false
    }
}

final class GitWorkTreeCache: Sendable {
    private let homePrefix: String
    private let known = Mutex<[String: Bool]>([:])

    init(home: URL) {
        let path = home.storagePath
        homePrefix = path.hasSuffix("/") ? path : path + "/"
    }

    func contains(_ url: URL) -> Bool {
        var directory = url.deletingLastPathComponent().storagePath
        var visited: [String] = []
        var result = false
        while directory.hasPrefix(homePrefix) {
            if let cached = known.withLock({ $0[directory] }) {
                result = cached
                break
            }
            visited.append(directory)
            var info = stat()
            if lstat(directory + "/.git", &info) == 0 {
                result = true
                break
            }
            guard let slash = directory.lastIndex(of: "/") else { break }
            directory = String(directory[..<slash])
        }
        known.withLock { cache in
            for path in visited {
                cache[path] = result
            }
        }
        return result
    }
}

extension CompiledRuleSet {
    func claims(_ url: URL) -> Bool {
        let components = PathPattern.entryComponents(url)
        var prefix = ""
        for component in components {
            prefix += "/" + component
            if literalIndex[prefix] != nil {
                return true
            }
        }
        return globbed.contains { $0.pattern.contains(components) }
    }
}

enum ProcessClock {
    static let launched = Date()
}
