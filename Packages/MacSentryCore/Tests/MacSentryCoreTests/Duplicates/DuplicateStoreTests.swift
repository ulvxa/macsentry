import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct DuplicateStoreTests {
    private typealias Support = DuplicateTestSupport

    @Test func `group and members persist together and keeper changes are saved`() async throws {
        let fixture = try FixtureBuilder(name: "DupStore")
        let urls = try [
            fixture.file("Documents/a.bin", size: 2_000_000, created: Support.date(1)),
            fixture.file("Desktop/a.bin", size: 2_000_000, created: Support.date(2)),
            fixture.file("Downloads/a.bin", size: 2_000_000, created: Support.date(3)),
        ]
        let database = try Database.inMemory()
        let sessionID = try await database.writer.write { db in
            var session = ScanSession(startedAt: Date(timeIntervalSince1970: 1), status: .running, roots: [fixture.root])
            try session.insert(db)
            return session.id
        }
        var options = Support.options(fixture)
        options.sessionID = try #require(sessionID)
        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: Support.index(fixture, urls), options: options))
        let found = try #require(Support.groups(events).first)

        let stored = try DuplicateStore.insert(found.group, members: found.members, into: database)

        let groupID = try #require(stored.group.id)
        #expect(stored.members.allSatisfy { $0.dupGroupID == groupID && $0.id != nil })
        let (savedKeeper, savedMembers) = try await database.writer.read { db in
            try (DuplicateGroup.fetchOne(db, key: groupID)?.keeperURL, DuplicateStore.members(ofGroup: groupID, in: db))
        }
        #expect(savedKeeper?.path == urls[0].path)
        #expect(savedMembers.map(\.url.path) == [urls[1].path, urls[2].path])

        let changed = try await database.writer.write { db in
            try DuplicateStore.changeKeeper(ofGroup: groupID, to: urls[2], in: db)
        }
        #expect(changed.group.keeperURL.path == urls[2].path)
        let (newKeeper, members) = try await database.writer.read { db in
            try (DuplicateGroup.fetchOne(db, key: groupID)?.keeperURL, DuplicateStore.members(ofGroup: groupID, in: db))
        }
        #expect(newKeeper?.path == urls[2].path)
        #expect(members.count == 3)
        let byPath = Dictionary(uniqueKeysWithValues: members.map { ($0.url.path, $0) })
        #expect(byPath[urls[0].path]?.status == .found)
        #expect(byPath[urls[0].path]?.createdAt == Support.date(1))
        #expect(byPath[urls[0].path]?.logicalSize == 2_000_000)
        #expect(byPath[urls[1].path]?.status == .found)
        #expect(byPath[urls[2].path]?.status == .ignored)
    }

    @Test func `changing the keeper of a missing group fails`() async throws {
        let database = try Database.inMemory()
        await #expect(throws: DuplicateError.groupNotFound(42)) {
            try await database.writer.write { db in
                try DuplicateStore.changeKeeper(ofGroup: 42, to: URL(filePath: "/msfixture/x"), in: db)
            }
        }
    }
}
