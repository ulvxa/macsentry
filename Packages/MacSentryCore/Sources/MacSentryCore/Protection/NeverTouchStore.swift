import Foundation
import GRDB

public protocol NeverTouchStore: Sendable {
    func patterns() async throws -> [NeverTouchPattern]
    func add(_ pattern: String, note: String?) async throws
    func remove(id: Int64) async throws
}

public protocol IgnoredPathStore: Sendable {
    func paths() async throws -> [IgnoredPath]
    func add(_ url: URL) async throws
    func remove(_ url: URL) async throws
}

public enum ProtectionStoreError: LocalizedError, Equatable {
    case invalidPattern(GlobPatternError)
    case duplicatePattern(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPattern(error): error.errorDescription
        case let .duplicatePattern(pattern): "\(pattern) is already in your Never Touch list."
        case let .database(reason): "Could not update the protection list: \(reason)"
        }
    }
}

enum ProtectionInput {
    static func pattern(_ raw: String) throws(ProtectionStoreError) -> String {
        do {
            try GlobPattern.validate(raw)
        } catch {
            throw .invalidPattern(error)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func note(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public struct GRDBNeverTouchStore: NeverTouchStore {
    private let database: Database
    private let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    public func patterns() async throws -> [NeverTouchPattern] {
        try await perform { try await database.writer.read { try NeverTouchPattern.order(Column("id")).fetchAll($0) } }
    }

    public func add(_ pattern: String, note: String?) async throws {
        let value = try ProtectionInput.pattern(pattern)
        let note = ProtectionInput.note(note)
        let createdAt = now()
        try await perform {
            try await database.writer.write { db in
                guard try NeverTouchPattern.filter(Column("pattern") == value).fetchCount(db) == 0 else {
                    throw ProtectionStoreError.duplicatePattern(value)
                }
                var record = NeverTouchPattern(pattern: value, note: note, createdAt: createdAt)
                try record.insert(db)
            }
        }
    }

    public func remove(id: Int64) async throws {
        try await perform { _ = try await database.writer.write { try NeverTouchPattern.deleteOne($0, key: id) } }
    }
}

public struct GRDBIgnoredPathStore: IgnoredPathStore {
    private let database: Database
    private let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    public func paths() async throws -> [IgnoredPath] {
        try await perform { try await database.writer.read { try IgnoredPath.order(Column("path")).fetchAll($0) } }
    }

    public func add(_ url: URL) async throws {
        let record = IgnoredPath(url: url, createdAt: now())
        try await perform { try await database.writer.write { try record.insert($0, onConflict: .ignore) } }
    }

    public func remove(_ url: URL) async throws {
        try await perform { _ = try await database.writer.write { try IgnoredPath.deleteOne($0, key: url.storagePath) } }
    }
}

private func perform<T: Sendable>(_ body: () async throws -> T) async throws(ProtectionStoreError) -> T {
    do {
        return try await body()
    } catch let error as ProtectionStoreError {
        throw error
    } catch {
        throw .database(error.localizedDescription)
    }
}
