import Foundation
import GRDB

public struct GRDBCandidateStore: CandidateStore {
    private static let chunkSize = 500

    private let writer: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        writer = database.writer
        self.now = now
    }

    public func latestSession() async throws -> ScanSession? {
        try await read { db in
            try ScanSession.fetchOne(db, sql: "SELECT * FROM scan_session ORDER BY id DESC LIMIT 1")
        }
    }

    public func latestFinishedSession() async throws -> ScanSession? {
        try await read { db in
            try ScanSession.fetchOne(db, sql: "SELECT * FROM scan_session WHERE status = 'finished' ORDER BY id DESC LIMIT 1")
        }
    }

    public func sessions(limit: Int) async throws -> [ScanSession] {
        try await read { db in
            try ScanSession.fetchAll(db, sql: "SELECT * FROM scan_session ORDER BY id DESC LIMIT ?", arguments: [max(limit, 0)])
        }
    }

    public func candidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) async throws -> [Candidate] {
        let query = CandidateQuery(filter: filter, sort: sort, limit: limit, offset: offset)
        let now = now()
        return try await read { db in
            let (sql, arguments) = query.sql(session: session, now: now)
            return try Candidate.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    public func candidate(id: Int64) async throws -> Candidate? {
        try await read { db in try Candidate.fetchOne(db, key: id) }
    }

    public func totals(session: Int64) async throws -> [Category: CategoryTotal] {
        try await read { db in try Self.fetchTotals(db, session: session) }
    }

    public func actionTotals(session: Int64) async throws -> SessionTotals {
        try await read { db in try Self.fetchActionTotals(db, session: session) }
    }

    public func total(session: Int64, filter: CandidateFilter) async throws -> CategoryTotal {
        let query = CandidateQuery(filter: filter, sort: .default, limit: nil, offset: 0)
        let now = now()
        return try await read { db in
            let (sql, arguments) = query.totalSQL(session: session, now: now)
            guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return .zero }
            return CategoryTotal(count: row["item_count"], freeable: row["freeable"])
        }
    }

    public func topOffenders(session: Int64, category: Category, limit: Int) async throws -> [Candidate] {
        try await read { db in
            try Candidate.fetchAll(db, sql: """
            SELECT * FROM candidate WHERE session_id = ? AND category = ? AND status = 'found'
            ORDER BY freeable_size DESC, id ASC LIMIT ?
            """, arguments: [session, category, max(limit, 0)])
        }
    }

    public func projects(session: Int64) async throws -> [Project] {
        try await read { db in
            try Project.fetchAll(db, sql: """
            SELECT * FROM project WHERE session_id = ? ORDER BY artifacts_size DESC, id ASC
            """, arguments: [session])
        }
    }

    public func observeCandidates(
        session: Int64,
        filter: CandidateFilter,
        sort: CandidateSort,
        limit: Int?,
        offset: Int,
    ) -> AsyncThrowingStream<[Candidate], Error> {
        let query = CandidateQuery(filter: filter, sort: sort, limit: limit, offset: offset)
        let now = now
        let observation = ValueObservation.tracking { db -> [Candidate] in
            let (sql, arguments) = query.sql(session: session, now: now())
            return try Candidate.fetchAll(db, sql: sql, arguments: arguments)
        }
        .removeDuplicates()
        return stream(observation)
    }

    public func observeActionTotals(session: Int64) -> AsyncThrowingStream<SessionTotals, Error> {
        let observation = ValueObservation.tracking { db in
            try Self.fetchActionTotals(db, session: session)
        }
        .removeDuplicates()
        return stream(observation)
    }

    public func setStatus(_ status: CandidateStatus, ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await write { db in
            for chunk in ids.chunks(of: Self.chunkSize) {
                var arguments: [(any DatabaseValueConvertible)?] = [status]
                arguments.append(contentsOf: chunk.map { $0 as (any DatabaseValueConvertible)? })
                try db.execute(
                    sql: "UPDATE candidate SET status = ? WHERE id IN (\(databaseQuestionMarks(count: chunk.count)))",
                    arguments: StatementArguments(arguments),
                )
            }
        }
    }

    public func ignore(paths: [URL]) async throws {
        let stored = Array(Set(paths.map(\.storagePath)))
        guard !stored.isEmpty else { return }
        let timestamp = now()
        try await write { db in
            for path in stored {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO ignored_path (path, created_at) VALUES (?, ?)",
                    arguments: [path, timestamp.timeIntervalSince1970],
                )
            }
            for chunk in stored.chunks(of: Self.chunkSize) {
                try db.execute(
                    sql: """
                    UPDATE candidate SET status = 'ignored'
                    WHERE status = 'found' AND path IN (\(databaseQuestionMarks(count: chunk.count)))
                    """,
                    arguments: StatementArguments(chunk),
                )
            }
        }
    }

    public func children(of dirNodeID: Int64?, session: Int64) async throws -> [DirNode] {
        try await read { db in
            if let dirNodeID {
                try DirNode.fetchAll(db, sql: """
                SELECT * FROM dir_node WHERE session_id = ? AND parent_id = ? ORDER BY allocated_size DESC, id ASC
                """, arguments: [session, dirNodeID])
            } else {
                try DirNode.fetchAll(db, sql: """
                SELECT * FROM dir_node WHERE session_id = ? AND parent_id IS NULL ORDER BY allocated_size DESC, id ASC
                """, arguments: [session])
            }
        }
    }

    public func rootDirNodes(session: Int64) async throws -> [DirNode] {
        try await children(of: nil, session: session)
    }

    public func dirNode(id: Int64) async throws -> DirNode? {
        try await read { db in try DirNode.fetchOne(db, key: id) }
    }

    public func ancestors(of dirNodeID: Int64) async throws -> [DirNode] {
        try await read { db in
            try DirNode.fetchAll(db, sql: """
            WITH RECURSIVE up(id, parent_id, level) AS (
              SELECT id, parent_id, 0 FROM dir_node WHERE id = ?
              UNION ALL
              SELECT d.id, d.parent_id, up.level + 1 FROM dir_node d JOIN up ON d.id = up.parent_id
            )
            SELECT dir_node.* FROM dir_node JOIN up ON dir_node.id = up.id WHERE up.level > 0 ORDER BY up.level DESC
            """, arguments: [dirNodeID])
        }
    }

    public func candidateCount(underPath path: URL, session: Int64) async throws -> Int {
        let base = path.storagePath
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let upperBound = String(prefix.dropLast()) + "0"
        return try await read { db in
            try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM candidate
            WHERE session_id = ? AND status = 'found' AND (path = ? OR (path >= ? AND path < ?))
            """, arguments: [session, base, prefix, upperBound]) ?? 0
        }
    }

    public func duplicateGroups(session: Int64) async throws -> [DuplicateGroup] {
        try await read { db in
            try DuplicateGroup.fetchAll(db, sql: """
            SELECT * FROM duplicate_group WHERE session_id = ? AND EXISTS (
              SELECT 1 FROM candidate WHERE candidate.dup_group_id = duplicate_group.id AND candidate.status = 'found'
            )
            ORDER BY reclaimable_size DESC, id ASC
            """, arguments: [session])
        }
    }

    public func members(ofGroup groupID: Int64) async throws -> [Candidate] {
        try await read { db in try DuplicateStore.members(ofGroup: groupID, in: db) }
    }

    public func changeKeeper(ofGroup groupID: Int64, to newKeeper: URL) async throws -> (group: DuplicateGroup, members: [Candidate]) {
        try await write { db in try DuplicateStore.changeKeeper(ofGroup: groupID, to: newKeeper, in: db) }
    }

    private static func fetchTotals(_ db: GRDB.Database, session: Int64) throws -> [Category: CategoryTotal] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT category, COUNT(*) AS item_count, COALESCE(SUM(freeable_size), 0) AS freeable
        FROM candidate WHERE session_id = ? AND status = 'found' GROUP BY category
        """, arguments: [session])
        var totals: [Category: CategoryTotal] = [:]
        for row in rows {
            let raw: String = row["category"]
            guard let category = Category(rawValue: raw) else { continue }
            totals[category] = CategoryTotal(count: row["item_count"], freeable: row["freeable"])
        }
        return totals
    }

    private static func fetchActionTotals(_ db: GRDB.Database, session: Int64) throws -> SessionTotals {
        let rows = try Row.fetchAll(db, sql: """
        SELECT category, action, COUNT(*) AS item_count, COALESCE(SUM(freeable_size), 0) AS freeable
        FROM candidate WHERE session_id = ? AND status = 'found' GROUP BY category, action
        """, arguments: [session])
        var totals = SessionTotals()
        for row in rows {
            let rawCategory: String = row["category"]
            let rawAction: String = row["action"]
            guard let category = Category(rawValue: rawCategory), let action = CandidateAction(rawValue: rawAction) else { continue }
            totals.add(CategoryTotal(count: row["item_count"], freeable: row["freeable"]), category: category, action: action)
        }
        return totals
    }

    private func read<T: Sendable>(_ block: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        do {
            return try await writer.read(block)
        } catch {
            throw CandidateStoreError.queryFailed(reason: error.localizedDescription)
        }
    }

    private func write<T: Sendable>(_ block: @escaping @Sendable (GRDB.Database) throws -> T) async throws -> T {
        do {
            return try await writer.write(block)
        } catch {
            throw CandidateStoreError.writeFailed(reason: error.localizedDescription)
        }
    }

    private func stream<Reducer: ValueReducer>(
        _ observation: ValueObservation<Reducer>,
    ) -> AsyncThrowingStream<Reducer.Value, Error> where Reducer.Value: Sendable {
        let writer = writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: writer) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: CandidateStoreError.queryFailed(reason: error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension Array {
    func chunks(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}

public extension GRDBCandidateStore {
    func unignore(paths: [URL]) async throws {
        let stored = Array(Set(paths.map(\.storagePath)))
        guard !stored.isEmpty else { return }
        try await write { db in
            for chunk in stored.chunks(of: Self.chunkSize) {
                let marks = databaseQuestionMarks(count: chunk.count)
                try db.execute(sql: "DELETE FROM ignored_path WHERE path IN (\(marks))", arguments: StatementArguments(chunk))
                try db.execute(
                    sql: "UPDATE candidate SET status = 'found' WHERE status = 'ignored' AND path IN (\(marks))",
                    arguments: StatementArguments(chunk),
                )
            }
        }
    }

    func ignoredPaths() async throws -> [IgnoredPath] {
        try await read { db in
            try IgnoredPath.order(Column("created_at").desc, Column("path")).fetchAll(db)
        }
    }
}
