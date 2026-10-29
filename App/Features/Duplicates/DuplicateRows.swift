import Foundation
import MacSentryCore

struct KeeperProbe: Equatable, Sendable {
    let exists: Bool
    let created: Date?
    let modified: Date?

    static func probe(_ url: URL) -> KeeperProbe {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return KeeperProbe(exists: values != nil, created: values?.creationDate, modified: values?.contentModificationDate)
    }
}

struct DuplicateMember: Identifiable, Equatable {
    let groupID: Int64
    let url: URL
    let row: Candidate?
    let isKeeper: Bool
    let size: Int64
    let freeable: Int64
    let created: Date?

    var id: DuplicateTableRow.ID {
        .member(groupID: groupID, path: path)
    }

    var path: String {
        url.path(percentEncoded: false)
    }

    var name: String {
        url.lastPathComponent
    }
}

struct DuplicateGroupRow: Identifiable, Equatable {
    let group: DuplicateGroup
    let groupID: Int64
    let keeper: DuplicateMember
    let copies: [DuplicateMember]
    let allRows: [Candidate]
    let keeperProbe: KeeperProbe

    var id: Int64 {
        groupID
    }

    var name: String {
        group.keeperURL.lastPathComponent
    }

    var members: [DuplicateMember] {
        [keeper] + copies
    }

    var candidates: [Candidate] {
        copies.compactMap(\.row)
    }

    var reclaimable: Int64 {
        copies.reduce(0) { $0 + $1.freeable }
    }

    var isSpaceEfficient: Bool {
        group.isSpaceEfficient
    }

    var isKeeperMissing: Bool {
        !keeperProbe.exists || keeper.row.map { $0.status == .quarantined || $0.status == .trashed } == true
    }

    func wouldRemoveEveryCopy(selecting urls: [URL]) -> Bool {
        let selection = isKeeperMissing ? urls + [group.keeperURL] : urls
        return DuplicateKeeper.wouldRemoveEveryMember(group: group, members: allRows, selection: selection)
    }

    var wouldRemoveEveryCopy: Bool {
        wouldRemoveEveryCopy(selecting: candidates.map(\.url))
    }

    func matches(_ term: String) -> Bool {
        members.contains { $0.path.range(of: term, options: .caseInsensitive) != nil }
    }

    static func make(group: DuplicateGroup, rows: [Candidate], probe: KeeperProbe) -> DuplicateGroupRow? {
        guard let groupID = group.id else { return nil }
        let keeperPath = group.keeperURL.path(percentEncoded: false)
        let keeperRow = rows.first { $0.url.path(percentEncoded: false) == keeperPath }
        let keeper = DuplicateMember(
            groupID: groupID,
            url: group.keeperURL,
            row: keeperRow,
            isKeeper: true,
            size: keeperRow?.logicalSize ?? group.fileSize,
            freeable: 0,
            created: keeperRow?.createdAt ?? probe.created,
        )
        let copies = rows
            .filter { $0.status == .found && $0.url.path(percentEncoded: false) != keeperPath }
            .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
            .map { row in
                DuplicateMember(
                    groupID: groupID, url: row.url, row: row, isKeeper: false,
                    size: row.logicalSize, freeable: row.freeableSize, created: row.createdAt,
                )
            }
        guard !copies.isEmpty else { return nil }
        return DuplicateGroupRow(group: group, groupID: groupID, keeper: keeper, copies: copies, allRows: rows, keeperProbe: probe)
    }
}

struct DuplicateTableRow: Identifiable {
    // swiftlint:disable:next type_name
    enum ID: Hashable {
        case group(Int64)
        case member(groupID: Int64, path: String)
    }

    enum Kind {
        case group(DuplicateGroupRow)
        case member(DuplicateMember)
    }

    let id: ID
    let kind: Kind
    let children: [DuplicateTableRow]

    init(group: DuplicateGroupRow) {
        id = .group(group.groupID)
        kind = .group(group)
        children = group.members.map(DuplicateTableRow.init(member:))
    }

    init(member: DuplicateMember) {
        id = member.id
        kind = .member(member)
        children = []
    }

    var name: String {
        switch kind {
        case let .group(group): group.name
        case let .member(member): member.name
        }
    }
}
