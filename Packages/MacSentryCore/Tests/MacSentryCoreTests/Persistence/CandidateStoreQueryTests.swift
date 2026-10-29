import Foundation
import GRDB
import Testing
@testable import MacSentryCore

@Suite(.timeLimit(.minutes(1)))
struct CandidateStoreQueryTests {
    @Test(arguments: StoreBackend.allCases)
    func `default filter returns found candidates of the session sorted by freeable desc`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter())
        #expect(ids(rows) == [3, 1, 4, 2, 5])
        #expect(rows.first?.url == URL(filePath: "/Users/u/Library/Developer/Xcode/DerivedData") || rows.first?.id == 3)
    }

    @Test(arguments: StoreBackend.allCases)
    func `filters by category and tier`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let dev = try await store.candidates(session: 1, filter: CandidateFilter(categories: [.devCache]))
        #expect(ids(dev) == [1, 4])
        let multi = try await store.candidates(session: 1, filter: CandidateFilter(categories: [.devCache, .appCache]))
        #expect(ids(multi) == [1, 4, 2])
        let green = try await store.candidates(session: 1, filter: CandidateFilter(tiers: [.green]))
        #expect(ids(green) == [1, 2, 5])
        let yellowRed = try await store.candidates(session: 1, filter: CandidateFilter(tiers: [.yellow, .red]))
        #expect(ids(yellowRed) == [3, 4])
        let both = try await store.candidates(session: 1, filter: CandidateFilter(categories: [.oldLarge], tiers: [.green]))
        #expect(ids(both) == [5])
    }

    @Test(arguments: StoreBackend.allCases)
    func `filters by minimum freeable size`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter(minFreeable: 700))
        #expect(ids(rows) == [3, 1, 4])
    }

    @Test(arguments: StoreBackend.allCases)
    func `age filter on last used falls back to modified and excludes undated`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter(minAgeDays: 150, ageBasis: .lastUsed))
        #expect(ids(rows) == [3, 2])
        let boundary = try await store.candidates(session: 1, filter: CandidateFilter(minAgeDays: 100, ageBasis: .lastUsed))
        #expect(ids(boundary) == [3, 1, 2])
    }

    @Test(arguments: StoreBackend.allCases)
    func `age filter on modified`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter(minAgeDays: 150, ageBasis: .modified))
        #expect(ids(rows) == [3, 1, 2])
    }

    @Test(arguments: StoreBackend.allCases)
    func `age filter on created`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter(minAgeDays: 350, ageBasis: .created))
        #expect(ids(rows) == [3, 1])
    }

    @Test(arguments: StoreBackend.allCases)
    func `age filter is relative to the injected now`(backend: StoreBackend) async throws {
        let later = referenceNow.addingTimeInterval(200 * 86400)
        let (store, _) = try makeStore(backend, now: later)
        let rows = try await store.candidates(session: 1, filter: CandidateFilter(minAgeDays: 150, ageBasis: .lastUsed))
        #expect(ids(rows) == [3, 1, 4, 2])
    }

    @Test(arguments: StoreBackend.allCases)
    func `search is case insensitive and treats like wildcards literally`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let xcode = try await store.candidates(session: 1, filter: CandidateFilter(search: "XCODE"))
        #expect(ids(xcode) == [1])
        let percent = try await store.candidates(session: 1, filter: CandidateFilter(search: "100%"))
        #expect(ids(percent) == [5])
        let underscore = try await store.candidates(session: 1, filter: CandidateFilter(search: "_cac"))
        #expect(ids(underscore) == [4])
        let wildcard = try await store.candidates(session: 1, filter: CandidateFilter(search: "%"))
        #expect(ids(wildcard) == [5])
        let blank = try await store.candidates(session: 1, filter: CandidateFilter(search: "  "))
        #expect(ids(blank) == [3, 1, 4, 2, 5])
        let none = try await store.candidates(session: 1, filter: CandidateFilter(search: "nothing-matches"))
        #expect(none.isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `status filter`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let quarantined = try await store.candidates(session: 1, filter: CandidateFilter(statuses: [.quarantined]))
        #expect(ids(quarantined) == [6])
        let any = try await store.candidates(session: 1, filter: CandidateFilter(statuses: []))
        #expect(Set(ids(any)) == [1, 2, 3, 4, 5, 6])
    }

    @Test(arguments: StoreBackend.allCases)
    func `sorts in SQL by every column in both directions`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let expectations: [SortCase] = [
            SortCase(.name, true, [5, 4, 3, 2, 1]),
            SortCase(.name, false, [1, 2, 3, 4, 5]),
            SortCase(.path, true, [4, 5, 3, 2, 1]),
            SortCase(.path, false, [1, 2, 3, 5, 4]),
            SortCase(.freeable, true, [5, 2, 4, 1, 3]),
            SortCase(.freeable, false, [3, 1, 4, 2, 5]),
            SortCase(.lastUsed, true, [5, 3, 2, 1, 4]),
            SortCase(.lastUsed, false, [4, 1, 2, 3, 5]),
            SortCase(.tier, true, [1, 2, 5, 3, 4]),
            SortCase(.tier, false, [4, 3, 1, 2, 5]),
            SortCase(.group, true, [2, 4, 3, 5, 1]),
            SortCase(.group, false, [1, 3, 5, 4, 2]),
        ]
        for sortCase in expectations {
            let (column, ascending, expected) = (sortCase.column, sortCase.ascending, sortCase.expected)
            let rows = try await store.candidates(
                session: 1,
                filter: CandidateFilter(),
                sort: CandidateSort(column: column, ascending: ascending),
                limit: nil,
                offset: 0,
            )
            #expect(ids(rows) == expected, "\(column) ascending=\(ascending)")
        }
    }

    @Test(arguments: StoreBackend.allCases)
    func `limit and offset page through sorted results`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        func page(limit: Int?, offset: Int) async throws -> [Int64] {
            try await ids(store.candidates(session: 1, filter: CandidateFilter(), sort: .default, limit: limit, offset: offset))
        }
        #expect(try await page(limit: 2, offset: 0) == [3, 1])
        #expect(try await page(limit: 2, offset: 1) == [1, 4])
        #expect(try await page(limit: nil, offset: 3) == [2, 5])
        #expect(try await page(limit: 10, offset: 4) == [5])
        #expect(try await page(limit: 2, offset: 10).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `totals count found candidates per category`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        let totals = try await store.totals(session: 1)
        #expect(totals == [
            .devCache: CategoryTotal(count: 2, freeable: 5700),
            .appCache: CategoryTotal(count: 1, freeable: 300),
            .oldLarge: CategoryTotal(count: 2, freeable: 9050),
        ])
        let other = try await store.totals(session: 2)
        #expect(other == [.devCache: CategoryTotal(count: 1, freeable: 77)])
        #expect(try await store.totals(session: 3).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `top offenders are the largest found candidates of a category`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        #expect(try await ids(store.topOffenders(session: 1, category: .devCache, limit: 3)) == [1, 4])
        #expect(try await ids(store.topOffenders(session: 1, category: .oldLarge, limit: 1)) == [3])
        #expect(try await store.topOffenders(session: 1, category: .orphan, limit: 3).isEmpty)
    }

    @Test(arguments: StoreBackend.allCases)
    func `sessions and single candidate lookups`(backend: StoreBackend) async throws {
        let (store, _) = try makeStore(backend)
        #expect(try await store.latestSession()?.id == 3)
        #expect(try await store.latestFinishedSession()?.id == 2)
        #expect(try await store.sessions(limit: 2).compactMap(\.id) == [3, 2])
        #expect(try await store.candidate(id: 3)?.freeableSize == 9000)
        #expect(try await store.candidate(id: 999) == nil)
    }
}

private struct SortCase {
    let column: CandidateSort.Column
    let ascending: Bool
    let expected: [Int64]

    init(_ column: CandidateSort.Column, _ ascending: Bool, _ expected: [Int64]) {
        self.column = column
        self.ascending = ascending
        self.expected = expected
    }
}
