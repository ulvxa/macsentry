import Foundation
import GRDB

public enum ProjectStoreError: LocalizedError, Equatable {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(reason):
            "Could not save projects: \(reason)"
        }
    }
}

public protocol ProjectStore: Sendable {
    func save(_ projects: [GraveyardProject]) async throws(ProjectStoreError) -> [GraveyardProject]
}

public struct DatabaseProjectStore: ProjectStore {
    let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func save(_ projects: [GraveyardProject]) async throws(ProjectStoreError) -> [GraveyardProject] {
        do {
            return try await database.writer.write { db in
                try projects.map { item in
                    var saved = item
                    try saved.project.insert(db)
                    saved.artifacts = try item.artifacts.map { artifact in
                        var row = artifact
                        row.projectID = saved.project.id
                        try row.insert(db)
                        return row
                    }
                    return saved
                }
            }
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }
}
