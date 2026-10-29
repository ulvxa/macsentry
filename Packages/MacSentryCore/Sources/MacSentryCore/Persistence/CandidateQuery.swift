import Foundation
import GRDB

struct CandidateQuery: Sendable {
    var filter: CandidateFilter
    var sort: CandidateSort
    var limit: Int?
    var offset: Int

    private static let secondsPerDay: TimeInterval = 86400
    private static let basename = "substr(path, length(rtrim(path, replace(path, '/', ''))) + 1)"

    func sql(session: Int64, now: Date) -> (sql: String, arguments: StatementArguments) {
        var (sql, values) = whereClause(session: session, now: now)
        sql = "SELECT * FROM candidate WHERE " + sql
        sql += " ORDER BY \(Self.orderExpression(sort.column)) \(sort.ascending ? "ASC" : "DESC"), id ASC"
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            values.append(max(limit, 0))
            values.append(max(offset, 0))
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
            values.append(offset)
        }
        return (sql, StatementArguments(values))
    }

    func totalSQL(session: Int64, now: Date) -> (sql: String, arguments: StatementArguments) {
        let (clause, values) = whereClause(session: session, now: now)
        let sql = "SELECT COUNT(*) AS item_count, COALESCE(SUM(freeable_size), 0) AS freeable FROM candidate WHERE " + clause
        return (sql, StatementArguments(values))
    }

    private func whereClause(session: Int64, now: Date) -> (String, [(any DatabaseValueConvertible)?]) {
        var clauses = ["session_id = ?"]
        var values: [(any DatabaseValueConvertible)?] = [session]

        func addIn(_ column: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            clauses.append("\(column) IN (\(databaseQuestionMarks(count: items.count)))")
            values.append(contentsOf: items)
        }
        addIn("category", filter.categories.map(\.rawValue).sorted())
        addIn("tier", filter.tiers.map(\.rawValue).sorted())
        addIn("action", filter.actions.map(\.rawValue).sorted())
        addIn("status", filter.statuses.map(\.rawValue).sorted())

        if filter.minFreeable > 0 {
            clauses.append("freeable_size >= ?")
            values.append(filter.minFreeable)
        }
        if let days = filter.minAgeDays {
            clauses.append("(rule_id = ? OR \(Self.ageExpression(filter.ageBasis)) <= ?)")
            values.append(OldLargeRule.largeRule.id)
            values.append(now.timeIntervalSince1970 - Double(days) * Self.secondsPerDay)
        }
        if let term = filter.search?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            clauses.append("path LIKE ? ESCAPE '\\'")
            values.append("%" + Self.escapeLike(term) + "%")
        }
        return (clauses.joined(separator: " AND "), values)
    }

    static func ageExpression(_ basis: AgeBasis) -> String {
        switch basis {
        case .lastUsed: "COALESCE(last_used_at, modified_at)"
        case .modified: "modified_at"
        case .created: "created_at"
        }
    }

    static func orderExpression(_ column: CandidateSort.Column) -> String {
        switch column {
        case .name: "\(basename) COLLATE NOCASE"
        case .path: "path COLLATE NOCASE"
        case .freeable: "freeable_size"
        case .lastUsed: ageExpression(.lastUsed)
        case .tier: "CASE tier WHEN 'green' THEN 0 WHEN 'yellow' THEN 1 ELSE 2 END"
        case .group: "rule_id COLLATE NOCASE"
        }
    }

    private static func escapeLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
