import Foundation
import MacSentryCore

struct CandidateRow: Identifiable {
    // swiftlint:disable:next type_name
    enum ID: Hashable {
        case group(String)
        case item(Int64)
    }

    let id: ID
    let name: String
    let path: String
    let freeable: Int64
    let lastUsed: Date?
    let tier: Tier?
    let group: String
    let candidate: Candidate?
    let children: [CandidateRow]

    var isGroup: Bool {
        candidate == nil
    }

    var lastUsedSortKey: Date {
        lastUsed ?? .distantPast
    }

    var tierRank: Int {
        tier?.rank ?? 0
    }

    var candidates: [Candidate] {
        if let candidate {
            return [candidate]
        }
        return children.compactMap(\.candidate)
    }

    init?(candidate: Candidate, group: String) {
        guard let id = candidate.id else { return nil }
        self.id = .item(id)
        name = candidate.name
        path = candidate.url.path(percentEncoded: false)
        freeable = candidate.freeableSize
        lastUsed = candidate.lastUsedAt ?? candidate.modifiedAt
        tier = candidate.tier
        self.group = group
        self.candidate = candidate
        children = []
    }

    init(group: String, children: [CandidateRow]) {
        id = .group(group)
        name = group
        path = ""
        freeable = children.reduce(0) { $0 + $1.freeable }
        lastUsed = children.compactMap(\.lastUsed).max()
        tier = nil
        self.group = group
        candidate = nil
        self.children = children
    }
}

extension CandidateSort {
    var comparator: KeyPathComparator<CandidateRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        return switch column {
        case .name: KeyPathComparator(\CandidateRow.name, order: order)
        case .path: KeyPathComparator(\CandidateRow.path, order: order)
        case .freeable: KeyPathComparator(\CandidateRow.freeable, order: order)
        case .lastUsed: KeyPathComparator(\CandidateRow.lastUsedSortKey, order: order)
        case .tier: KeyPathComparator(\CandidateRow.tierRank, order: order)
        case .group: KeyPathComparator(\CandidateRow.group, order: order)
        }
    }

    init?(comparator: KeyPathComparator<CandidateRow>) {
        let columns: [(PartialKeyPath<CandidateRow>, Column)] = [
            (\CandidateRow.name, .name), (\CandidateRow.path, .path), (\CandidateRow.freeable, .freeable),
            (\CandidateRow.lastUsedSortKey, .lastUsed), (\CandidateRow.tierRank, .tier), (\CandidateRow.group, .group),
        ]
        guard let column = columns.first(where: { $0.0 == comparator.keyPath })?.1 else { return nil }
        self.init(column: column, ascending: comparator.order == .forward)
    }
}
