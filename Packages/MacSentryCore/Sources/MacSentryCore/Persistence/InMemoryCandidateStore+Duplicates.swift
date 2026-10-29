import Foundation

public extension InMemoryCandidateStore {
    func duplicateGroups(session: Int64) -> [DuplicateGroup] {
        groupRows
            .filter { group in
                group.sessionID == session && candidateRows.contains { $0.dupGroupID == group.id && $0.status == .found }
            }
            .sorted {
                $0.reclaimableSize != $1.reclaimableSize ? $0.reclaimableSize > $1.reclaimableSize : ($0.id ?? 0) < ($1.id ?? 0)
            }
    }

    func members(ofGroup groupID: Int64) -> [Candidate] {
        candidateRows.filter { $0.dupGroupID == groupID }.sorted { $0.path < $1.path }
    }

    /// Never touches the disk: the previous keeper is rebuilt from the group's file size.
    func changeKeeper(ofGroup groupID: Int64, to newKeeper: URL) throws -> (group: DuplicateGroup, members: [Candidate]) {
        guard let groupIndex = groupRows.firstIndex(where: { $0.id == groupID }) else { throw DuplicateError.groupNotFound(groupID) }
        let group = groupRows[groupIndex]
        let previous = FileEntry(
            url: group.keeperURL, kind: .file, logicalSize: group.fileSize, allocatedSize: group.fileSize, privateSize: nil,
            linkCount: 1, inode: 0, device: 0, flags: 0, created: nil, modified: nil, ownerUID: 0,
        )
        let changed = try DuplicateKeeper.changeKeeper(
            group: group, members: members(ofGroup: groupID), to: newKeeper, previousKeeper: previous,
        )
        groupRows[groupIndex] = changed.group
        var next: Int64 = (candidateRows.compactMap(\.id).max() ?? 0) + 1
        var saved: [Candidate] = []
        for var member in changed.members {
            if member.id == nil {
                member.id = next
                next += 1
                candidateRows.append(member)
            } else if let index = candidateRows.firstIndex(where: { $0.id == member.id }) {
                candidateRows[index] = member
            }
            saved.append(member)
        }
        notify()
        return (changed.group, saved)
    }
}

extension InMemoryCandidateStore {
    static func numbered(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        var next: Int64 = (groups.compactMap(\.id).max() ?? 0) + 1
        return groups.map { row in
            var row = row
            if row.id == nil {
                row.id = next
                next += 1
            }
            return row
        }
    }
}
