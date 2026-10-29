import Foundation
import GRDB

public enum DuplicateStore {
    public static func insert(
        _ group: DuplicateGroup,
        members: [Candidate],
        in db: GRDB.Database,
    ) throws -> (group: DuplicateGroup, members: [Candidate]) {
        var group = group
        try group.insert(db)
        let members = try members.map { member in
            var member = member
            member.dupGroupID = group.id
            try member.insert(db)
            return member
        }
        return (group, members)
    }

    public static func insert(
        _ group: DuplicateGroup,
        members: [Candidate],
        into database: Database,
    ) throws(DuplicateError) -> (group: DuplicateGroup, members: [Candidate]) {
        do {
            return try database.writer.write { db in try insert(group, members: members, in: db) }
        } catch {
            throw .storage(error.localizedDescription)
        }
    }

    public static func members(ofGroup groupID: Int64, in db: GRDB.Database) throws -> [Candidate] {
        try Candidate
            .filter(Column(Candidate.CodingKeys.dupGroupID.rawValue) == groupID)
            .order(Column(Candidate.CodingKeys.path.rawValue))
            .fetchAll(db)
    }

    public static func changeKeeper(
        ofGroup groupID: Int64,
        to newKeeper: URL,
        previousKeeper: FileEntry? = nil,
        in db: GRDB.Database,
    ) throws -> (group: DuplicateGroup, members: [Candidate]) {
        guard let group = try DuplicateGroup.fetchOne(db, key: groupID) else { throw DuplicateError.groupNotFound(groupID) }
        let previous = try previousKeeper ?? FileProbe.entry(for: group.keeperURL)
        let changed = try DuplicateKeeper.changeKeeper(
            group: group, members: members(ofGroup: groupID, in: db), to: newKeeper, previousKeeper: previous,
        )
        try changed.group.update(db)
        let members = try changed.members.map { member in
            var member = member
            if member.id == nil {
                try member.insert(db)
            } else {
                try member.update(db)
            }
            return member
        }
        return (changed.group, members)
    }
}
