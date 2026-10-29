import Foundation
import GRDB
import Testing
@testable import MacSentryCore

@Suite(.timeLimit(.minutes(1)))
struct CandidateStoreMutationTests {
    @Test(arguments: StoreBackend.allCases)
    func `observation emits updated values after setStatus`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        var iterator = store.observeCandidates(session: 1, filter: CandidateFilter()).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first.map(ids) == [3, 1, 4, 2, 5])

        try await store.setStatus(.quarantined, ids: [3, 2])
        let second = try await iterator.next()
        #expect(second.map(ids) == [1, 4, 5])

        try await store.setStatus(.found, ids: [3])
        let third = try await iterator.next()
        #expect(third.map(ids) == [3, 1, 4, 5])
    }

    @Test(arguments: StoreBackend.allCases)
    func `totals observation reflects status changes`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        var iterator = store.observeActionTotals(session: 1).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.total(categories: [.oldLarge]) == CategoryTotal(count: 2, freeable: 9050))
        try await store.setStatus(.trashed, ids: [3])
        let second = try await iterator.next()
        #expect(second?.total(categories: [.oldLarge]) == CategoryTotal(count: 1, freeable: 50))
    }

    @Test(arguments: StoreBackend.allCases)
    func `observation honours filter sort and limit`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        var iterator = store.observeCandidates(
            session: 1,
            filter: CandidateFilter(categories: [.devCache, .oldLarge]),
            sort: CandidateSort(column: .freeable, ascending: true),
            limit: 2,
            offset: 0,
        ).makeAsyncIterator()
        #expect(try await iterator.next().map(ids) == [5, 4])
        try await store.setStatus(.ignored, ids: [5])
        #expect(try await iterator.next().map(ids) == [4, 1])
    }

    @Test(arguments: StoreBackend.allCases)
    func `children lists direct children largest first and nil lists roots`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        #expect(try await store.rootDirNodes(session: 1).compactMap(\.id) == [6, 1])
        #expect(try await store.children(of: nil, session: 2).compactMap(\.id) == [7])
        #expect(try await store.children(of: 1, session: 1).compactMap(\.id) == [2, 3])
        #expect(try await store.children(of: 3, session: 1).isEmpty)
        #expect(try await store.dirNode(id: 5)?.name == "Xcode")
        #expect(try await store.dirNode(id: 999) == nil)
    }

    @Test(arguments: StoreBackend.allCases)
    func `ancestors run from root to direct parent`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        #expect(try await store.ancestors(of: 5).compactMap(\.id) == [1, 2, 4])
        #expect(try await store.ancestors(of: 3).compactMap(\.id) == [1])
        #expect(try await store.ancestors(of: 1).isEmpty)
        #expect(try await store.ancestors(of: 999).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `candidate count under path matches whole components of found candidates only`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/Users/u/Library"), session: 1) == 2)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/Users/u/Library/"), session: 1) == 2)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/Users/u/Lib"), session: 1) == 0)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/Users/u/Downloads"), session: 1) == 2)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/Users/u/Library/Caches/com.foo.app"), session: 1) == 1)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/"), session: 1) == 5)
        #expect(try await store.candidateCount(underPath: URL(filePath: "/"), session: 2) == 1)
    }

    @Test(arguments: StoreBackend.allCases)
    func `ignore flips found candidates and skips others`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        try await store.ignore(paths: [
            URL(filePath: "/Users/u/Downloads/Big_Movie.mov"),
            URL(filePath: "/Users/u/Library/Caches/old.thing"),
            URL(filePath: "/nowhere"),
        ])
        #expect(try await store.candidate(id: 3)?.status == .ignored)
        #expect(try await store.candidate(id: 6)?.status == .quarantined)
        #expect(try await ids(store.candidates(session: 1, filter: CandidateFilter())) == [1, 4, 2, 5])
        let ignored = try await store.candidates(session: 1, filter: CandidateFilter(statuses: [.ignored]))
        #expect(ids(ignored) == [3])
    }

    @Test(arguments: StoreBackend.allCases)
    func `setStatus with no ids is a no-op`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        try await store.setStatus(.trashed, ids: [])
        #expect(try await store.candidates(session: 1, filter: CandidateFilter()).count == 5)
    }

    @Test func `grdb ignore records paths once and keeps the first timestamp`() async throws {
        let (store, database) = try makeStore(.grdb)
        let url = URL(filePath: "/Users/u/Downloads/Big_Movie.mov")
        try await store.ignore(paths: [url, url])
        try await store.ignore(paths: [url])
        let rows = try await database.writer.read { db in try IgnoredPath.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows.first?.url == url)
        #expect(rows.first?.createdAt == referenceNow)
    }

    @Test func `in memory ignore records paths`() async throws {
        let memory = InMemoryCandidateStore(sessions: sessionRows, candidates: candidateRows)
        let url = URL(filePath: "/Users/u/Downloads/Big_Movie.mov")
        try await memory.ignore(paths: [url])
        #expect(await memory.isIgnored(url))
        #expect(await !memory.isIgnored(URL(filePath: "/elsewhere")))
    }

    @Test func `grdb setStatus handles more ids than one statement chunk`() async throws {
        let bulk = (1000 ..< 2300).map { index in
            candidate(
                Int64(index), "/bulk/\(index)", category: .devCache, tier: .green, rule: "bulk",
                freeable: Int64(index), session: 3,
            )
        }
        let (store, _) = try makeStore(.grdb, candidates: candidateRows + bulk)
        try await store.setStatus(.trashed, ids: bulk.compactMap(\.id))
        #expect(try await store.candidates(session: 3, filter: CandidateFilter()).isEmpty)
        let trashed = try await store.candidates(
            session: 3,
            filter: CandidateFilter(statuses: [.trashed]),
            sort: .default,
            limit: 5,
            offset: 0,
        )
        #expect(ids(trashed) == [2299, 2298, 2297, 2296, 2295])
        #expect(try await store.totals(session: 3).isEmpty)
    }

    @Test func `grdb observation terminates cleanly when the consumer stops`() async throws {
        let (store, _) = try makeStore(.grdb)
        let task = Task {
            var count = 0
            for try await _ in store.observeCandidates(session: 1, filter: CandidateFilter()) {
                count += 1
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
    }
}
