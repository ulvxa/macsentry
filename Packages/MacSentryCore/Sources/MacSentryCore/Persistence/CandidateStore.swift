import Foundation

public enum CandidateStoreError: LocalizedError, Equatable {
    case queryFailed(reason: String)
    case writeFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .queryFailed(reason):
            "Could not read scan results: \(reason)"
        case let .writeFailed(reason):
            "Could not save changes to scan results: \(reason)"
        }
    }
}

public struct CandidateFilter: Sendable, Equatable {
    public var categories: Set<Category>
    public var tiers: Set<Tier>
    public var minFreeable: Int64
    public var minAgeDays: Int?
    public var ageBasis: AgeBasis
    public var statuses: Set<CandidateStatus>
    public var search: String?

    /// Empty `categories`, `tiers` or `statuses` means no restriction on that dimension.
    public init(
        categories: Set<Category> = [],
        tiers: Set<Tier> = [],
        minFreeable: Int64 = 0,
        minAgeDays: Int? = nil,
        ageBasis: AgeBasis = .lastUsed,
        statuses: Set<CandidateStatus> = [.found],
        search: String? = nil,
    ) {
        self.categories = categories
        self.tiers = tiers
        self.minFreeable = minFreeable
        self.minAgeDays = minAgeDays
        self.ageBasis = ageBasis
        self.statuses = statuses
        self.search = search
    }
}

public struct CandidateSort: Sendable, Equatable {
    public enum Column: String, Sendable, CaseIterable {
        case name, path, freeable, lastUsed, tier, group
    }

    public static let `default` = CandidateSort(column: .freeable, ascending: false)

    public var column: Column
    public var ascending: Bool

    public init(column: Column, ascending: Bool) {
        self.column = column
        self.ascending = ascending
    }
}

public struct CategoryTotal: Sendable, Equatable {
    public static let zero = CategoryTotal(count: 0, freeable: 0)

    public var count: Int
    public var freeable: Int64

    public init(count: Int, freeable: Int64) {
        self.count = count
        self.freeable = freeable
    }
}

public protocol CandidateStore: Sendable {
    func latestSession() async throws -> ScanSession?
    func latestFinishedSession() async throws -> ScanSession?
    func sessions(limit: Int) async throws -> [ScanSession]

    func candidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) async throws -> [Candidate]
    func candidate(id: Int64) async throws -> Candidate?
    func totals(session: Int64) async throws -> [Category: CategoryTotal]
    func topOffenders(session: Int64, category: Category, limit: Int) async throws -> [Candidate]

    func observeCandidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) -> AsyncThrowingStream<[Candidate], Error>
    func observeTotals(session: Int64) -> AsyncThrowingStream<[Category: CategoryTotal], Error>

    func setStatus(_ status: CandidateStatus, ids: [Int64]) async throws
    /// Records the paths in `ignored_path` and flips matching `found` candidates to `ignored`.
    func ignore(paths: [URL]) async throws

    func children(of dirNodeID: Int64?, session: Int64) async throws -> [DirNode]
    func rootDirNodes(session: Int64) async throws -> [DirNode]
    func dirNode(id: Int64) async throws -> DirNode?
    /// Root first, direct parent last, excluding the node itself.
    func ancestors(of dirNodeID: Int64) async throws -> [DirNode]
    /// Number of `found` candidates at or below `path`.
    func candidateCount(underPath path: URL, session: Int64) async throws -> Int

    /// Groups that still have a `found` member, largest reclaimable first.
    func duplicateGroups(session: Int64) async throws -> [DuplicateGroup]
    func members(ofGroup groupID: Int64) async throws -> [Candidate]
    func changeKeeper(ofGroup groupID: Int64, to newKeeper: URL) async throws -> (group: DuplicateGroup, members: [Candidate])
}

public extension CandidateStore {
    func candidates(session: Int64, filter: CandidateFilter) async throws -> [Candidate] {
        try await candidates(session: session, filter: filter, sort: .default, limit: nil, offset: 0)
    }

    func observeCandidates(session: Int64, filter: CandidateFilter) -> AsyncThrowingStream<[Candidate], Error> {
        observeCandidates(session: session, filter: filter, sort: .default, limit: nil, offset: 0)
    }
}
