import Foundation

public actor InMemoryCandidateStore: CandidateStore {
    private struct CandidateObserver {
        var session: Int64
        var filter: CandidateFilter
        var sort: CandidateSort
        var limit: Int?
        var offset: Int
        var last: [Candidate]?
        var continuation: AsyncThrowingStream<[Candidate], Error>.Continuation
    }

    private struct TotalsObserver {
        var session: Int64
        var last: [Category: CategoryTotal]?
        var continuation: AsyncThrowingStream<[Category: CategoryTotal], Error>.Continuation
    }

    private var sessionRows: [ScanSession]
    var candidateRows: [Candidate]
    private var dirNodeRows: [DirNode]
    var groupRows: [DuplicateGroup]
    private var ignoredPaths: Set<String> = []
    private var candidateObservers: [UUID: CandidateObserver] = [:]
    private var totalsObservers: [UUID: TotalsObserver] = [:]
    private let now: @Sendable () -> Date

    public init(
        sessions: [ScanSession] = [],
        candidates: [Candidate] = [],
        dirNodes: [DirNode] = [],
        duplicateGroups: [DuplicateGroup] = [],
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        var nextSession: Int64 = (sessions.compactMap(\.id).max() ?? 0) + 1
        sessionRows = sessions.map { row in
            var row = row
            if row.id == nil {
                row.id = nextSession
                nextSession += 1
            }
            return row
        }
        var nextCandidate: Int64 = (candidates.compactMap(\.id).max() ?? 0) + 1
        candidateRows = candidates.map { row in
            var row = row
            if row.id == nil {
                row.id = nextCandidate
                nextCandidate += 1
            }
            return row
        }
        var nextNode: Int64 = (dirNodes.compactMap(\.id).max() ?? 0) + 1
        dirNodeRows = dirNodes.map { row in
            var row = row
            if row.id == nil {
                row.id = nextNode
                nextNode += 1
            }
            return row
        }
        groupRows = Self.numbered(duplicateGroups)
        self.now = now
    }

    public func latestSession() -> ScanSession? {
        sessionRows.max { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    public func latestFinishedSession() -> ScanSession? {
        sessionRows.filter { $0.status == .finished }.max { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    public func sessions(limit: Int) -> [ScanSession] {
        Array(sessionRows.sorted { ($0.id ?? 0) > ($1.id ?? 0) }.prefix(max(limit, 0)))
    }

    public func candidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) -> [Candidate] {
        query(session: session, filter: filter, sort: sort, limit: limit, offset: offset)
    }

    public func candidate(id: Int64) -> Candidate? {
        candidateRows.first { $0.id == id }
    }

    public func totals(session: Int64) -> [Category: CategoryTotal] {
        computeTotals(session: session)
    }

    public func topOffenders(session: Int64, category: Category, limit: Int) -> [Candidate] {
        let matches = candidateRows.filter { $0.sessionID == session && $0.category == category && $0.status == .found }
        let sorted = matches.sorted {
            $0.freeableSize != $1.freeableSize ? $0.freeableSize > $1.freeableSize : ($0.id ?? 0) < ($1.id ?? 0)
        }
        return Array(sorted.prefix(max(limit, 0)))
    }

    // swiftlint:disable:next modifier_order
    public nonisolated func observeCandidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) -> AsyncThrowingStream<[Candidate], Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task {
                await self.addObserver(
                    id: id,
                    observer: CandidateObserver(
                        session: session,
                        filter: filter,
                        sort: sort,
                        limit: limit,
                        offset: offset,
                        continuation: continuation,
                    ),
                )
            }
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id: id) }
            }
        }
    }

    // swiftlint:disable:next modifier_order
    public nonisolated func observeTotals(session: Int64) -> AsyncThrowingStream<[Category: CategoryTotal], Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task {
                await self.addTotalsObserver(id: id, observer: TotalsObserver(session: session, continuation: continuation))
            }
            continuation.onTermination = { _ in
                Task { await self.removeObserver(id: id) }
            }
        }
    }

    public func setStatus(_ status: CandidateStatus, ids: [Int64]) {
        let idSet = Set(ids)
        for index in candidateRows.indices where candidateRows[index].id.map(idSet.contains) == true {
            candidateRows[index].status = status
        }
        notify()
    }

    public func ignore(paths: [URL]) {
        let stored = Set(paths.map(\.storagePath))
        ignoredPaths.formUnion(stored)
        for index in candidateRows.indices where candidateRows[index].status == .found && stored.contains(candidateRows[index].path) {
            candidateRows[index].status = .ignored
        }
        notify()
    }

    public func children(of dirNodeID: Int64?, session: Int64) -> [DirNode] {
        dirNodeRows
            .filter { $0.sessionID == session && $0.parentID == dirNodeID }
            .sorted { $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : ($0.id ?? 0) < ($1.id ?? 0) }
    }

    public func rootDirNodes(session: Int64) -> [DirNode] {
        children(of: nil, session: session)
    }

    public func dirNode(id: Int64) -> DirNode? {
        dirNodeRows.first { $0.id == id }
    }

    public func ancestors(of dirNodeID: Int64) -> [DirNode] {
        var result: [DirNode] = []
        var cursor = dirNode(id: dirNodeID)?.parentID
        while let id = cursor, let node = dirNode(id: id), result.count <= dirNodeRows.count {
            result.append(node)
            cursor = node.parentID
        }
        return result.reversed()
    }

    public func candidateCount(underPath path: URL, session: Int64) -> Int {
        let base = path.storagePath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return candidateRows.count {
            $0.sessionID == session && $0.status == .found && ($0.path == base || $0.path.hasPrefix(prefix))
        }
    }

    public func isIgnored(_ url: URL) -> Bool {
        ignoredPaths.contains(url.storagePath)
    }

    public func insert(_ candidates: [Candidate]) {
        var next: Int64 = (candidateRows.compactMap(\.id).max() ?? 0) + 1
        for var row in candidates {
            if row.id == nil {
                row.id = next
                next += 1
            }
            candidateRows.append(row)
        }
        notify()
    }

    private func addObserver(id: UUID, observer: CandidateObserver) {
        var observer = observer
        let value = query(
            session: observer.session,
            filter: observer.filter,
            sort: observer.sort,
            limit: observer.limit,
            offset: observer.offset,
        )
        observer.last = value
        observer.continuation.yield(value)
        candidateObservers[id] = observer
    }

    private func addTotalsObserver(id: UUID, observer: TotalsObserver) {
        var observer = observer
        let value = computeTotals(session: observer.session)
        observer.last = value
        observer.continuation.yield(value)
        totalsObservers[id] = observer
    }

    private func removeObserver(id: UUID) {
        candidateObservers[id] = nil
        totalsObservers[id] = nil
    }

    func notify() {
        for (id, var observer) in candidateObservers {
            let value = query(
                session: observer.session,
                filter: observer.filter,
                sort: observer.sort,
                limit: observer.limit,
                offset: observer.offset,
            )
            guard value != observer.last else { continue }
            observer.last = value
            observer.continuation.yield(value)
            candidateObservers[id] = observer
        }
        for (id, var observer) in totalsObservers {
            let value = computeTotals(session: observer.session)
            guard value != observer.last else { continue }
            observer.last = value
            observer.continuation.yield(value)
            totalsObservers[id] = observer
        }
    }

    private func query(session: Int64, filter: CandidateFilter, sort: CandidateSort, limit: Int?, offset: Int) -> [Candidate] {
        let reference = now()
        let sorted = candidateRows
            .filter { $0.sessionID == session && filter.matches($0, now: reference) }
            .sorted { sort.areInIncreasingOrder($0, $1) }
        let tail = sorted.dropFirst(max(offset, 0))
        guard let limit else { return Array(tail) }
        return Array(tail.prefix(max(limit, 0)))
    }

    private func computeTotals(session: Int64) -> [Category: CategoryTotal] {
        var totals: [Category: CategoryTotal] = [:]
        for row in candidateRows where row.sessionID == session && row.status == .found {
            var total = totals[row.category] ?? .zero
            total.count += 1
            total.freeable += row.freeableSize
            totals[row.category] = total
        }
        return totals
    }
}

extension CandidateFilter {
    func matches(_ candidate: Candidate, now: Date) -> Bool {
        if !categories.isEmpty, !categories.contains(candidate.category) {
            return false
        }
        if !tiers.isEmpty, !tiers.contains(candidate.tier) {
            return false
        }
        if !statuses.isEmpty, !statuses.contains(candidate.status) {
            return false
        }
        if candidate.freeableSize < minFreeable {
            return false
        }
        if let minAgeDays {
            let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86400)
            let date = switch ageBasis {
            case .lastUsed: candidate.lastUsedAt ?? candidate.modifiedAt
            case .modified: candidate.modifiedAt
            case .created: candidate.createdAt
            }
            guard let date, date <= cutoff else { return false }
        }
        if let term = search?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty,
           candidate.path.range(of: term, options: .caseInsensitive) == nil {
            return false
        }
        return true
    }
}

extension CandidateSort {
    func areInIncreasingOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let order = compare(lhs, rhs)
        if order == .orderedSame {
            return (lhs.id ?? 0) < (rhs.id ?? 0)
        }
        return ascending ? order == .orderedAscending : order == .orderedDescending
    }

    private func compare(_ lhs: Candidate, _ rhs: Candidate) -> ComparisonResult {
        switch column {
        case .name: Self.compare(lhs.url.lastPathComponent.lowercased(), rhs.url.lastPathComponent.lowercased())
        case .path: Self.compare(lhs.path.lowercased(), rhs.path.lowercased())
        case .freeable: Self.compare(lhs.freeableSize, rhs.freeableSize)
        case .lastUsed: Self.compare(lhs.lastUsedAt ?? lhs.modifiedAt, rhs.lastUsedAt ?? rhs.modifiedAt)
        case .tier: Self.compare(lhs.tier.rank, rhs.tier.rank)
        case .group: Self.compare(lhs.ruleID.lowercased(), rhs.ruleID.lowercased())
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        compare(lhs ?? .distantPast, rhs ?? .distantPast)
    }
}

private extension Tier {
    var rank: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        }
    }
}
