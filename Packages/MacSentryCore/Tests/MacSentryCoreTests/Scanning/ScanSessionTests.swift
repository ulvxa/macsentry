import Darwin
import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct ScanSessionTests {
    @Test func `only the last five sessions are kept`() async throws {
        let fixture = try FixtureBuilder(name: "ScanRetention")
        try fixture.file("a/b.bin", size: 10)
        let database = try Database.inMemory()
        let service = ScanTest.service(database)
        var ids: [Int64] = []
        for _ in 0 ..< 7 {
            let events = try await ScanTest.collect(service.scan(config: ScanConfig(roots: [fixture.root])))
            try ids.append(#require(ScanTest.summary(events)).sessionID)
        }
        let (sessions, nodeSessions) = try await database.writer.read { db in
            try (
                ScanSession.order(Column("id")).fetchAll(db).compactMap(\.id),
                Set(Int64.fetchAll(db, sql: "SELECT DISTINCT session_id FROM dir_node")),
            )
        }
        #expect(sessions == Array(ids.suffix(5)))
        #expect(nodeSessions == Set(ids.suffix(5)))
    }

    @Test func `candidates are written in batches of 500 per transaction`() async throws {
        let fixture = try FixtureBuilder(name: "ScanBatches")
        let folder = try fixture.folder("many")
        for index in 0 ..< 1203 {
            let descriptor = open(folder.appending(path: "f\(index)").path(percentEncoded: false), O_WRONLY | O_CREAT, 0o644)
            close(descriptor)
        }
        let database = try Database.inMemory()
        let observer = InsertCommitCounter(table: "candidate")
        database.writer.add(transactionObserver: observer, extent: .observerLifetime)
        let handler = RecordingHandler { $0.kind == .file ? .claim(.test()) : .descend }

        let events = try await ScanTest
            .collect(ScanTest.service(database, handlers: [handler]).scan(config: ScanConfig(roots: [fixture.root])))
        let batches = ScanTest.candidates(events).map(\.count)
        #expect(batches.prefix(3).sorted() == [203, 500, 500])
        #expect(observer.commits == [500, 500, 203])
        let count = try await database.writer.read { try Candidate.fetchCount($0) }
        #expect(count == 1203)
        #expect(ScanTest.summary(events)?.candidateCount == 1203)
    }

    @Test func `progress is throttled to ten per second`() async throws {
        let fixture = try FixtureBuilder(name: "ScanProgress")
        for index in 0 ..< 300 {
            try fixture.file("d\(index % 3)/f\(index)", size: 1)
        }
        let database = try Database.inMemory()
        let handler = RecordingHandler(delay: .milliseconds(2))
        let started = ContinuousClock.now
        let events = try await ScanTest.collect(
            ScanTest.service(database, handlers: [handler]).scan(config: ScanConfig(roots: [fixture.root], maxConcurrency: 1)),
        )
        let elapsed = ContinuousClock.now - started
        let progress = events.filter {
            if case .progress = $0 {
                true
            } else {
                false
            }
        }
        #expect(progress.count >= 2)
        #expect(Double(progress.count) <= elapsed / .milliseconds(100) + 2)
        guard case let .progress(files, _, _) = progress.last else { return }
        #expect(files == 300)
    }

    @Test func `unreadable folders are reported in the summary`() async throws {
        let fixture = try FixtureBuilder(name: "ScanUnreadable")
        try fixture.file("locked/x.bin", size: 1)
        let locked = try fixture.url("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }
        let database = try Database.inMemory()
        let events = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root])))
        #expect(ScanTest.summary(events)?.unreadable.map(\.storagePath) == [locked.storagePath])
    }

    @Test func `missing root fails the session`() async throws {
        let fixture = try FixtureBuilder(name: "ScanMissing")
        let database = try Database.inMemory()
        await #expect(throws: ScanError.self) {
            _ = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.url("gone")])))
        }
        let session = try await database.writer.read { try ScanSession.fetchOne($0) }
        #expect(session?.status == .failed)
        #expect(session?.error != nil)
    }

    @Test func `cancel stops the walk within a second and marks the session cancelled`() async throws {
        let fixture = try FixtureBuilder(name: "ScanCancel")
        for directory in 0 ..< 20 {
            let folder = try fixture.folder("d\(directory)")
            for index in 0 ..< 200 {
                close(open(folder.appending(path: "f\(index)").path(percentEncoded: false), O_WRONLY | O_CREAT, 0o644))
            }
        }
        let database = try Database.inMemory()
        let handler = RecordingHandler(delay: .milliseconds(5)) { $0.url.lastPathComponent.hasSuffix("0") ? .claim(.test()) : .descend }
        let service = ScanTest.service(database, handlers: [handler])
        let consumer = Task {
            for try await _ in service.scan(config: ScanConfig(roots: [fixture.root], maxConcurrency: 4)) {}
        }
        try await Task.sleep(for: .milliseconds(400))
        consumer.cancel()
        let cancelledAt = ContinuousClock.now

        var status: ScanStatus?
        while ContinuousClock.now - cancelledAt < .seconds(3) {
            status = try await database.writer.read { try ScanSession.fetchOne($0)?.status }
            if status == .cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = ContinuousClock.now - cancelledAt
        #expect(status == .cancelled)
        #expect(elapsed < .seconds(1))

        let visited = handler.entries.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(handler.entries.count == visited)
        #expect(visited > 0)
        #expect(visited < 4020)
        let partial = try await database.writer.read { db in
            try (Candidate.fetchCount(db), DirNode.fetchCount(db))
        }
        #expect(partial.0 > 0)
        #expect(partial.1 > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSENTRY_PERF"] == "1"))
    func `scanning a 200k file fixture takes under 20 seconds`() async throws {
        let fixture = try FixtureBuilder(name: "ScanPerf")
        for directory in 0 ..< 2000 {
            let folder = try fixture.folder("g\(directory / 100)/d\(directory)")
            for index in 0 ..< 100 {
                close(open(folder.appending(path: "f\(index).txt").path(percentEncoded: false), O_WRONLY | O_CREAT, 0o644))
            }
        }
        let database = try Database.inMemory()
        let started = ContinuousClock.now
        let events = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root])))
        let elapsed = ContinuousClock.now - started
        print("MACSENTRY_PERF 200k files scanned in \(elapsed)")
        #expect(ScanTest.summary(events)?.filesVisited == 200_000)
        #expect(elapsed < .seconds(20))
    }
}
