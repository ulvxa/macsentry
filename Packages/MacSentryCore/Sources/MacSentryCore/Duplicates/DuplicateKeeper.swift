import Foundation

public enum DuplicateKeeper {
    public static func preferred(among entries: [FileEntry], homeURL: URL) -> FileEntry? {
        let downloads = homeURL.appending(path: "Downloads", directoryHint: .isDirectory).storagePath + "/"
        return entries.min { lhs, rhs in
            isPreferred(lhs.url, lhs.created, over: rhs.url, rhs.created, downloadsPrefix: downloads)
        }
    }

    public static func changeKeeper(
        group: DuplicateGroup,
        members: [Candidate],
        to newKeeper: URL,
        previousKeeper: FileEntry,
    ) throws(DuplicateError) -> (group: DuplicateGroup, members: [Candidate]) {
        let newPath = newKeeper.storagePath
        let oldPath = group.keeperURL.storagePath
        guard newPath != oldPath else { return (group, members) }
        guard previousKeeper.url.storagePath == oldPath else { throw .keeperNotInGroup(previousKeeper.url) }
        guard let newIndex = members.firstIndex(where: { $0.url.storagePath == newPath }) else {
            throw .keeperNotInGroup(newKeeper)
        }

        var members = members
        members[newIndex].status = .ignored
        if let oldIndex = members.firstIndex(where: { $0.url.storagePath == oldPath }) {
            members[oldIndex].status = .found
        } else {
            members.append(candidate(for: previousKeeper, keeper: newKeeper, sessionID: group.sessionID, groupID: group.id))
        }
        for index in members.indices where members[index].status != .ignored {
            members[index].reason = reason(
                keeper: newKeeper, allocated: members[index].allocatedSize, freeable: members[index].freeableSize,
            )
        }

        var group = group
        group.keeperURL = newKeeper
        group.reclaimableSize = members.filter { $0.status != .ignored }.reduce(0) { $0 + $1.freeableSize }
        return (group, members)
    }

    public static func wouldRemoveEveryMember(
        group: DuplicateGroup,
        members: [Candidate],
        selection: some Sequence<URL>,
    ) -> Bool {
        let selected = Set(selection.map(\.storagePath))
        var remaining = Set(members.filter { $0.status != .quarantined && $0.status != .trashed }.map(\.url.storagePath))
        remaining.insert(group.keeperURL.storagePath)
        return remaining.isSubset(of: selected)
    }

    static func candidate(for entry: FileEntry, keeper: URL, sessionID: Int64, groupID: Int64?) -> Candidate {
        let freeable = freeableSize(of: entry)
        return Candidate(
            sessionID: sessionID,
            url: entry.url,
            kind: .file,
            category: .duplicate,
            ruleID: DuplicateGroup.ruleID,
            tier: .yellow,
            action: .quarantine,
            reason: reason(keeper: keeper, allocated: entry.allocatedSize, freeable: freeable),
            logicalSize: entry.logicalSize,
            allocatedSize: entry.allocatedSize,
            freeableSize: freeable,
            createdAt: entry.created,
            modifiedAt: entry.modified,
            dupGroupID: groupID,
        )
    }

    static func freeableSize(of entry: FileEntry) -> Int64 {
        guard entry.linkCount <= 1 else { return 0 }
        return max(0, min(entry.privateSize ?? entry.allocatedSize, entry.allocatedSize))
    }

    static func reason(keeper: URL, allocated: Int64, freeable: Int64) -> String {
        let base = "Same content as \(keeper.lastPathComponent) in \(keeper.deletingLastPathComponent().lastPathComponent), which is kept."
        guard allocated > 0, freeable * 20 < allocated else { return base }
        return base + " Shares its storage with another file (APFS clone or hard link), so removing it frees almost nothing."
    }

    private static func isPreferred(
        _ lhs: URL, _ lhsCreated: Date?,
        over rhs: URL, _ rhsCreated: Date?,
        downloadsPrefix: String,
    ) -> Bool {
        let lhsDate = lhsCreated ?? .distantFuture
        let rhsDate = rhsCreated ?? .distantFuture
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        let lhsPath = lhs.storagePath
        let rhsPath = rhs.storagePath
        if lhsPath.count != rhsPath.count {
            return lhsPath.count < rhsPath.count
        }
        let lhsInDownloads = lhsPath.hasPrefix(downloadsPrefix)
        let rhsInDownloads = rhsPath.hasPrefix(downloadsPrefix)
        if lhsInDownloads != rhsInDownloads {
            return rhsInDownloads
        }
        return lhsPath < rhsPath
    }
}
