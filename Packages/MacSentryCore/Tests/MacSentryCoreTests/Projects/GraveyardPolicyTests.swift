import Foundation
import GRDB
import Testing
@testable import MacSentryCore

struct GraveyardPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86400

    private func project(commit: Date?, modified: Date, sessionID: Int64 = 1, root: String = "/p/app") -> Project {
        Project(
            sessionID: sessionID, rootURL: URL(filePath: root), name: "app", ecosystems: ["node"],
            lastCommitAt: commit, lastModifiedAt: modified, artifactsSize: 0,
        )
    }

    private func artifact(_ tier: Tier, path: String, sessionID: Int64 = 1) -> Candidate {
        Candidate(
            sessionID: sessionID, url: URL(filePath: path), kind: .folder, category: .projectArtifact,
            ruleID: "graveyard.node.node_modules", tier: tier, action: .quarantine, reason: "r",
            logicalSize: 10, allocatedSize: 10, freeableSize: 10,
        )
    }

    @Test func `age uses the newest of commit and file dates`() {
        let commitNewer = project(commit: now - 10 * day, modified: now - 100 * day)
        let filesNewer = project(commit: now - 100 * day, modified: now - 5 * day)
        let noCommit = project(commit: nil, modified: now - 200 * day)

        #expect(GraveyardPolicy.age(of: commitNewer, now: now) == 10 * day)
        #expect(GraveyardPolicy.age(of: filesNewer, now: now) == 5 * day)
        #expect(GraveyardPolicy.age(of: noCommit, now: now) == 200 * day)
        #expect(!GraveyardPolicy.isIdle(commitNewer, now: now))
        #expect(GraveyardPolicy.isIdle(noCommit, now: now))
        #expect(GraveyardPolicy.isIdle(commitNewer, idleDays: 7, now: now))
    }

    @Test func `idle filter keeps projects past the threshold`() {
        let items = [
            GraveyardProject(
                project: project(commit: nil, modified: now - 91 * day),
                artifacts: [],
                hasGit: false,
                uncommitted: .clean,
                gitUnavailable: false,
            ),
            GraveyardProject(
                project: project(commit: nil, modified: now - 89 * day),
                artifacts: [],
                hasGit: false,
                uncommitted: .clean,
                gitUnavailable: false,
            ),
        ]
        #expect(GraveyardPolicy.idle(items, now: now).count == 1)
    }

    @Test func `IDE block needs a running IDE and recent activity`() {
        let recent = project(commit: nil, modified: now - 3600)
        let stale = project(commit: now - 30 * day, modified: now - 30 * day)
        let idle = AppInventoryDouble()

        for bundleID in GraveyardPolicy.ideBundleIDs {
            let running = AppInventoryDouble(running: [bundleID])
            #expect(GraveyardPolicy.isBlockedByIDE(project: recent, inventory: running, now: now))
            #expect(!GraveyardPolicy.isBlockedByIDE(project: stale, inventory: running, now: now))
        }
        #expect(!GraveyardPolicy.isBlockedByIDE(project: recent, inventory: idle, now: now))
        #expect(!GraveyardPolicy.isBlockedByIDE(project: recent, inventory: AppInventoryDouble(running: ["com.apple.Safari"]), now: now))
    }

    @Test func `default selection is green only and nothing when uncommitted or unknown`() {
        let green = artifact(.green, path: "/p/app/node_modules")
        let yellow = artifact(.yellow, path: "/p/app/.venv")
        var item = GraveyardProject(
            project: project(commit: nil, modified: now), artifacts: [green, yellow], hasGit: true, uncommitted: .clean,
            gitUnavailable: false,
        )
        #expect(GraveyardPolicy.defaultSelection(for: item) == [green])
        item.uncommitted = .dirty
        #expect(GraveyardPolicy.defaultSelection(for: item).isEmpty)
        item.uncommitted = .unknown
        #expect(GraveyardPolicy.defaultSelection(for: item).isEmpty)
    }

    @Test func `store inserts projects then their candidates with project id`() async throws {
        let database = try Database.inMemory()
        let sessionID = try await database.writer.write { db in
            var session = ScanSession(startedAt: Date(timeIntervalSince1970: 1), status: .running, roots: [URL(filePath: "/p")])
            try session.insert(db)
            return try #require(session.id)
        }
        let items = [
            GraveyardProject(
                project: project(commit: now, modified: now, sessionID: sessionID),
                artifacts: [artifact(.green, path: "/p/app/node_modules", sessionID: sessionID)],
                hasGit: true, uncommitted: .clean, gitUnavailable: false,
            ),
            GraveyardProject(
                project: project(commit: nil, modified: now, sessionID: sessionID, root: "/p/other"),
                artifacts: [
                    artifact(.green, path: "/p/other/target", sessionID: sessionID),
                    artifact(.yellow, path: "/p/other/dist", sessionID: sessionID),
                ],
                hasGit: false, uncommitted: .clean, gitUnavailable: false,
            ),
        ]

        let saved = try await DatabaseProjectStore(database: database).save(items)

        let ids = saved.compactMap(\.project.id)
        #expect(ids.count == 2)
        for item in saved {
            #expect(item.artifacts.allSatisfy { $0.projectID == item.project.id && $0.id != nil })
        }
        let rows = try await database.writer.read { db in
            try (Project.fetchAll(db), Candidate.fetchAll(db))
        }
        #expect(rows.0.map(\.rootURL.storagePath).sorted() == ["/p/app", "/p/other"])
        #expect(rows.1.count == 3)
        #expect(Set(rows.1.compactMap(\.projectID)) == Set(ids))
    }

    @Test func `store rolls back everything when a candidate fails`() async throws {
        let database = try Database.inMemory()
        let duplicate = artifact(.green, path: "/p/app/node_modules", sessionID: 99)
        let item = GraveyardProject(
            project: project(commit: nil, modified: now, sessionID: 99), artifacts: [duplicate],
            hasGit: false, uncommitted: .clean, gitUnavailable: false,
        )

        await #expect(throws: ProjectStoreError.self) { try await DatabaseProjectStore(database: database).save([item]) }
        let count = try await database.writer.read { db in try Project.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func `store double records saves`() async throws {
        let store = ProjectStoreDouble()
        let item = GraveyardProject(
            project: project(commit: nil, modified: now), artifacts: [], hasGit: false, uncommitted: .clean, gitUnavailable: false,
        )
        _ = try await store.save([item])
        #expect(store.saved.withLock { $0 } == [item])
    }
}
