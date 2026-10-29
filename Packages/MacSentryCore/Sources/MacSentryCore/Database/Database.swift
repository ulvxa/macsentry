import Foundation
import GRDB

public struct Database: Sendable {
    let writer: any DatabaseWriter
    public let fileURL: URL?
    public let corruptBackupURL: URL?

    public var recoveredFromCorruption: Bool {
        corruptBackupURL != nil
    }

    public static func open(at url: URL, now: Date = Date()) throws(DatabaseOpenError) -> Database {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .cannotCreateDirectory(directory, reason: error.localizedDescription)
        }

        do {
            return try Database(writer: openPool(at: url), fileURL: url, corruptBackupURL: nil)
        } catch let error as GRDB.DatabaseError where error.isCorruption {
            let backup = try moveAside(url, now: now)
            do {
                return try Database(writer: openPool(at: url), fileURL: url, corruptBackupURL: backup)
            } catch {
                throw .openFailed(url, reason: error.localizedDescription)
            }
        } catch let error as DatabaseOpenError {
            throw error
        } catch {
            throw .openFailed(url, reason: error.localizedDescription)
        }
    }

    public static func inMemory() throws(DatabaseOpenError) -> Database {
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(configuration: configuration)
        } catch {
            throw .openFailed(nil, reason: error.localizedDescription)
        }
        try migrate(queue)
        return Database(writer: queue, fileURL: nil, corruptBackupURL: nil)
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "MacSentry"
        return config
    }

    private static func openPool(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
        try pool.read { db in
            let result = try String.fetchOne(db, sql: "PRAGMA quick_check")
            guard result == "ok" else {
                throw GRDB.DatabaseError(resultCode: .SQLITE_CORRUPT, message: "quick_check: \(result ?? "no result")")
            }
        }
        do {
            try Migrations.migrator.migrate(pool)
        } catch let error as GRDB.DatabaseError where error.isCorruption {
            throw error
        } catch {
            throw DatabaseOpenError.migrationFailed(reason: error.localizedDescription)
        }
        return pool
    }

    private static func migrate(_ writer: some DatabaseWriter) throws(DatabaseOpenError) {
        do {
            try Migrations.migrator.migrate(writer)
        } catch {
            throw .migrationFailed(reason: error.localizedDescription)
        }
    }

    private static func moveAside(_ url: URL, now: Date) throws(DatabaseOpenError) -> URL {
        let fileManager = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var backup = url.appendingPathExtension("corrupt-\(stamp)")
        var attempt = 1
        while fileManager.fileExists(atPath: backup.path(percentEncoded: false)) {
            backup = url.appendingPathExtension("corrupt-\(stamp)-\(attempt)")
            attempt += 1
        }
        do {
            try fileManager.moveItem(at: url, to: backup)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(filePath: url.path(percentEncoded: false) + suffix)
                guard fileManager.fileExists(atPath: sidecar.path(percentEncoded: false)) else { continue }
                try fileManager.moveItem(at: sidecar, to: URL(filePath: backup.path(percentEncoded: false) + suffix))
            }
        } catch {
            throw .cannotMoveCorruptFile(url, reason: error.localizedDescription)
        }
        return backup
    }
}

private extension GRDB.DatabaseError {
    var isCorruption: Bool {
        resultCode == .SQLITE_CORRUPT || resultCode == .SQLITE_NOTADB
    }
}
