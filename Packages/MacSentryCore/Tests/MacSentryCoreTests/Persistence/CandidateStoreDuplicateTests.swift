import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

@Suite(.timeLimit(.minutes(1)))
struct CandidateStoreDuplicateTests {
    private static let size: Int64 = 2_000_000

    private struct Seed {
        let store: any CandidateStore
        let fixture: FixtureBuilder
        let urls: [URL]
    }

    private static func member(_ id: Int64, _ url: URL, group: Int64, session: Int64 = 1, status: CandidateStatus = .found) -> Candidate {
        Candidate(
            id: id, sessionID: session, url: url, kind: .file, category: .duplicate, ruleID: DuplicateGroup.ruleID,
            tier: .yellow, action: .quarantine, reason: "dup", logicalSize: size, allocatedSize: size, freeableSize: size,
            dupGroupID: group, status: status,
        )
    }

    private static func group(_ id: Int64, keeper: URL, members: Int, session: Int64 = 1) -> DuplicateGroup {
        DuplicateGroup(
            id: id, sessionID: session, contentHash: "hash\(id)", fileSize: size, memberCount: members + 1,
            reclaimableSize: size * Int64(members), keeperURL: keeper,
        )
    }

    private static func seed(_ backend: StoreBackend, name: String) throws -> Seed {
        let fixture = try FixtureBuilder(name: name)
        let urls = try ["a", "b", "c", "d", "e", "f", "g"].map { try fixture.sparseFile("Documents/\($0).bin", logicalSize: size) }
        let groups = [
            group(1, keeper: urls[0], members: 2),
            group(2, keeper: urls[3], members: 1),
            group(3, keeper: urls[5], members: 1, session: 2),
        ]
        let members = [
            member(1, urls[1], group: 1),
            member(2, urls[2], group: 1),
            member(3, urls[4], group: 2, status: .quarantined),
            member(4, urls[6], group: 3, session: 2),
        ]
        switch backend {
        case .grdb:
            let database = try Database.inMemory()
            try database.writer.write { db in
                for var row in sessionRows {
                    try row.insert(db)
                }
                for var row in groups {
                    try row.insert(db)
                }
                for var row in members {
                    try row.insert(db)
                }
            }
            return Seed(store: GRDBCandidateStore(database: database), fixture: fixture, urls: urls)
        case .memory:
            let store = InMemoryCandidateStore(sessions: sessionRows, candidates: members, duplicateGroups: groups)
            return Seed(store: store, fixture: fixture, urls: urls)
        }
    }

    @Test(arguments: StoreBackend.allCases)
    func `duplicate groups hide fully quarantined groups and stay in their session`(backend: StoreBackend) async throws {
        let seed = try Self.seed(backend, name: "StoreDupGroups\(backend)")
        #expect(try await seed.store.duplicateGroups(session: 1).compactMap(\.id) == [1])
        #expect(try await seed.store.duplicateGroups(session: 2).compactMap(\.id) == [3])

        try await seed.store.setStatus(.quarantined, ids: [1, 2])
        #expect(try await seed.store.duplicateGroups(session: 1).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `groups sort by reclaimable size`(backend: StoreBackend) async throws {
        let seed = try Self.seed(backend, name: "StoreDupSort\(backend)")
        try await seed.store.setStatus(.found, ids: [3])
        #expect(try await seed.store.duplicateGroups(session: 1).compactMap(\.id) == [1, 2])
    }

    @Test(arguments: StoreBackend.allCases)
    func `members of a group come back by path`(backend: StoreBackend) async throws {
        let seed = try Self.seed(backend, name: "StoreDupMembers\(backend)")
        let members = try await seed.store.members(ofGroup: 1)
        #expect(members.compactMap(\.id) == [1, 2])
        #expect(try await seed.store.members(ofGroup: 2).map(\.status) == [.quarantined])
        #expect(try await seed.store.members(ofGroup: 99).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `changing the keeper flips candidates and notifies observers`(backend: StoreBackend) async throws {
        let seed = try Self.seed(backend, name: "StoreDupKeeper\(backend)")
        let urls = seed.urls
        var iterator = seed.store.observeCandidates(session: 1, filter: CandidateFilter(categories: [.duplicate])).makeAsyncIterator()
        #expect(try await iterator.next().map { Set(ids($0)) } == [1, 2])

        let changed = try await seed.store.changeKeeper(ofGroup: 1, to: urls[2])
        #expect(changed.group.keeperURL.path == urls[2].path)
        let byPath = Dictionary(uniqueKeysWithValues: changed.members.map { ($0.url.path, $0) })
        #expect(byPath[urls[2].path]?.status == .ignored)
        #expect(byPath[urls[1].path]?.status == .found)
        let previous = try #require(byPath[urls[0].path])
        #expect(previous.status == .found)
        #expect(previous.id != nil)
        #expect(previous.dupGroupID == 1)

        let found = try #require(try await iterator.next())
        #expect(Set(found.map(\.url.path)) == [urls[0].path, urls[1].path])
        let stored = try #require(try await seed.store.duplicateGroups(session: 1).first)
        #expect(stored.keeperURL.path == urls[2].path)
        #expect(try await seed.store.members(ofGroup: 1).count == 3)

        _ = try await seed.store.changeKeeper(ofGroup: 1, to: urls[0])
        let back = try await seed.store.members(ofGroup: 1)
        #expect(back.count == 3)
        #expect(back.first { $0.url.path == urls[0].path }?.status == .ignored)
        #expect(back.first { $0.url.path == urls[2].path }?.status == .found)
    }

    @Test(arguments: StoreBackend.allCases)
    func `changing the keeper of a missing group or to a stranger fails`(backend: StoreBackend) async throws {
        let seed = try Self.seed(backend, name: "StoreDupKeeperFail\(backend)")
        await #expect(throws: (any Error).self) {
            try await seed.store.changeKeeper(ofGroup: 42, to: seed.urls[1])
        }
        await #expect(throws: (any Error).self) {
            try await seed.store.changeKeeper(ofGroup: 1, to: seed.urls[6])
        }
        #expect(try await seed.store.duplicateGroups(session: 1).first?.keeperURL.path == seed.urls[0].path)
    }
}
