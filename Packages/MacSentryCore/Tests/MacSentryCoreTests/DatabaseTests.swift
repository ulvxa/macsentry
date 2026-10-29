import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct DatabaseTests {
    private static let expectedTables: Set = [
        "scan_session", "dir_node", "candidate", "project", "duplicate_group",
        "quarantine_batch", "quarantine_entry", "never_touch", "ignored_path", "disk_sample",
    ]

    @Test func `in memory migration creates all tables and indexes`() throws {
        let database = try Database.inMemory()
        try database.writer.read { db in
            let tables = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            #expect(Self.expectedTables.isSubset(of: tables))
            let indexes = try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            #expect(indexes.isSuperset(of: [
                "dir_node_parent", "candidate_session_cat", "candidate_session_path", "quarantine_entry_status",
            ]))
            #expect(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") == true)
            #expect(try Migrations.migrator.appliedMigrations(db) == ["v1", "v2"])
        }
    }

    @Test func `v2 adds a nullable rule group that old rows read as nil`() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO scan_session (started_at, status, roots_json) VALUES (0, 'finished', '[]')")
            try db.execute(sql: """
            INSERT INTO candidate (session_id, path, kind, category, rule_id, tier, action, reason,
              logical_size, allocated_size, freeable_size)
            VALUES (1, '/old', 'folder', 'appCache', 'appcache.chromium', 'green', 'quarantine', 'x', 1, 1, 1)
            """)
        }
        try Migrations.migrator.migrate(queue)
        try queue.write { db in
            #expect(try Candidate.fetchOne(db)?.group == nil)
            var fresh = Candidate(
                sessionID: 1, url: URL(filePath: "/new"), kind: .folder, category: .appCache, ruleID: "appcache.chromium",
                tier: .green, action: .quarantine, reason: "x", logicalSize: 1, allocatedSize: 1, freeableSize: 1, group: "Notion",
            )
            try fresh.insert(db)
            #expect(try Candidate.fetchOne(db, key: fresh.id)?.group == "Notion")
        }
    }

    @Test func `check constraint rejects unknown status`() throws {
        let database = try Database.inMemory()
        #expect {
            try database.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO scan_session (started_at, status, roots_json) VALUES (?, ?, ?)",
                    arguments: [0, "bogus", "[]"],
                )
            }
        } throws: { error in
            (error as? GRDB.DatabaseError)?.resultCode == .SQLITE_CONSTRAINT
        }
    }

    @Test func `check constraint rejects unknown category`() throws {
        let database = try Database.inMemory()
        try database.writer.write { db in
            var session = ScanSession(startedAt: Date(timeIntervalSince1970: 1), status: .running, roots: [])
            try session.insert(db)
            let sessionID = try #require(session.id)
            #expect(throws: GRDB.DatabaseError.self) {
                try db.execute(sql: """
                INSERT INTO candidate (session_id, path, kind, category, rule_id, tier, action, reason,
                  logical_size, allocated_size, freeable_size)
                VALUES (?, '/a', 'file', 'nope', 'r', 'green', 'quarantine', 'x', 1, 1, 1)
                """, arguments: [sessionID])
            }
        }
    }

    @Test func `foreign keys are enforced`() throws {
        let database = try Database.inMemory()
        try database.writer.write { db in
            var node = DirNode(sessionID: 999, url: URL(filePath: "/x"), name: "x", depth: 0, allocatedSize: 0, fileCount: 0)
            #expect(throws: GRDB.DatabaseError.self) { try node.insert(db) }
        }
    }

    @Test func `records round trip with UR ls dates and enums`() throws {
        let database = try Database.inMemory()
        let root = URL(filePath: "/tmp/fixture root/", directoryHint: .isDirectory)
        let cacheURL = URL(filePath: "/tmp/fixture root/Library/Caches/com.example", directoryHint: .isDirectory)
        try database.writer.write { db in
            var session = ScanSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000), status: .running, roots: [root])
            try session.insert(db)
            let sessionID = try #require(session.id)
            var candidate = Candidate(
                sessionID: sessionID, url: cacheURL, kind: .folder, category: .appCache, ruleID: "app.cache",
                tier: .green, action: .quarantine, reason: "Cache", logicalSize: 10, allocatedSize: 8,
                freeableSize: 8, modifiedAt: Date(timeIntervalSince1970: 1_600_000_000),
            )
            try candidate.insert(db)

            let fetchedSession = try #require(try ScanSession.fetchOne(db, key: sessionID))
            #expect(fetchedSession == session)
            #expect(fetchedSession.roots.map(\.storagePath) == ["/tmp/fixture root"])
            let rootsJSON = try #require(try String.fetchOne(db, sql: "SELECT roots_json FROM scan_session"))
            #expect(try JSONDecoder().decode([String].self, from: Data(rootsJSON.utf8)) == ["/tmp/fixture root"])
            #expect(try Double.fetchOne(db, sql: "SELECT started_at FROM scan_session") == 1_700_000_000)

            let fetched = try #require(try Candidate.fetchOne(db, key: candidate.id))
            #expect(fetched == candidate)
            #expect(fetched.url.storagePath == "/tmp/fixture root/Library/Caches/com.example")
            #expect(fetched.status == .found)
        }
    }

    @Test func `file database uses WAL at override path`() throws {
        let fixture = try FixtureBuilder(name: "DatabaseWAL")
        let url = try fixture.url("nested/dir/macsentry.sqlite")
        let database = try Database.open(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        #expect(!database.recoveredFromCorruption)
        let journalMode = try database.writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(journalMode == "wal")
    }

    @Test func `reopening existing database keeps data`() throws {
        let fixture = try FixtureBuilder(name: "DatabaseReopen")
        let url = try fixture.url("macsentry.sqlite")
        try Database.open(at: url).writer.write { db in
            var pattern = NeverTouchPattern(pattern: "**/ClientWork/**", createdAt: Date(timeIntervalSince1970: 5))
            try pattern.insert(db)
        }
        let reopened = try Database.open(at: url)
        #expect(!reopened.recoveredFromCorruption)
        let count = try reopened.writer.read { try NeverTouchPattern.fetchCount($0) }
        #expect(count == 1)
    }

    @Test func `corrupt file is moved aside and replaced`() throws {
        let fixture = try FixtureBuilder(name: "DatabaseCorrupt")
        let url = try fixture.file("macsentry.sqlite", size: 8192, fill: 0x5A)
        let database = try Database.open(at: url, now: Date(timeIntervalSince1970: 1_761_700_000))
        let backup = try #require(database.corruptBackupURL)
        #expect(database.recoveredFromCorruption)
        #expect(backup.lastPathComponent == "macsentry.sqlite.corrupt-1761700000")
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        let hasCandidateTable = try database.writer.read { try $0.tableExists("candidate") }
        #expect(hasCandidateTable)
    }
}
