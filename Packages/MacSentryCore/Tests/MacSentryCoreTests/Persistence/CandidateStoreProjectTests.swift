import Foundation
import GRDB
import Testing
@testable import MacSentryCore

@Suite(.timeLimit(.minutes(1)))
struct CandidateStoreProjectTests {
    private static func project(_ id: Int64, _ path: String, size: Int64, session: Int64 = 1) -> Project {
        Project(
            id: id,
            sessionID: session,
            rootURL: URL(filePath: path, directoryHint: .isDirectory),
            name: URL(filePath: path).lastPathComponent,
            ecosystems: ["node", "python"],
            lastCommitAt: daysAgo(200),
            lastModifiedAt: daysAgo(150),
            hasUncommitted: id == 2,
            artifactsSize: size,
        )
    }

    private static let projectRows = [
        project(1, "/Users/u/dev/small", size: 100),
        project(2, "/Users/u/dev/big", size: 5000),
        project(3, "/Users/u/dev/other-session", size: 9000, session: 2),
    ]

    private func makeStore(_ backend: StoreBackend) throws -> any CandidateStore {
        switch backend {
        case .grdb:
            let database = try Database.inMemory()
            try database.writer.write { db in
                for var row in sessionRows {
                    try row.insert(db)
                }
                for var row in Self.projectRows {
                    try row.insert(db)
                }
            }
            return GRDBCandidateStore(database: database, now: { referenceNow })
        case .memory:
            return InMemoryCandidateStore(sessions: sessionRows, projects: Self.projectRows, now: { referenceNow })
        }
    }

    @Test(arguments: StoreBackend.allCases)
    func `projects are scoped to the session and sorted by artifacts size`(backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let rows = try await store.projects(session: 1)
        #expect(rows.map(\.name) == ["big", "small"])
        #expect(rows.first?.hasUncommitted == true)
        #expect(rows.first?.ecosystems == ["node", "python"])
        #expect(rows.first?.rootURL.storagePath == "/Users/u/dev/big")
        #expect(rows.first?.lastCommitAt == daysAgo(200))
        #expect(try await store.projects(session: 2).map(\.name) == ["other-session"])
        #expect(try await store.projects(session: 9).isEmpty)
    }
}
