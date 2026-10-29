import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PipelineGraveyardTests {
    private typealias Harness = PipelineHarness

    static func makeRepo(_ fixture: FixtureBuilder) throws -> URL {
        let repo = try fixture.folder("Code/webapp")
        try fixture.file("Code/webapp/package.json", size: 20)
        try fixture.file("Code/webapp/src/index.js", size: 100)
        try "node_modules/\n.venv/\n".write(to: fixture.url("Code/webapp/.gitignore"), atomically: true, encoding: .utf8)
        try fixture.file("Code/webapp/node_modules/left-pad/package.json", size: 10)
        try fixture.file("Code/webapp/node_modules/left-pad/index.js", size: 4096)
        try fixture.file("Code/webapp/node_modules/left-pad/node_modules/inner/package.json", size: 10)
        try fixture.file("Code/webapp/node_modules/left-pad/node_modules/inner/index.js", size: 8192)
        try fixture.file("Code/webapp/.venv/pyvenv.cfg", size: 30)
        try fixture.file("Code/webapp/.venv/lib/site.py", size: 2048)
        try GraveyardTestSupport.commitAll(in: repo, home: fixture.root)
        return repo
    }

    @Test func `git project yields a project row and one candidate per artifact folder`() async throws {
        let harness = try Harness("Graveyard")
        let repo = try Self.makeRepo(harness.fixture)
        try "{\"name\":\"changed\"}".write(to: repo.appending(path: "package.json"), atomically: false, encoding: .utf8)

        let summary = try await harness.scan()
        #expect(summary.status == .finished)
        let projects = try await harness.database.writer.read { db in
            try Project.filter(Column("session_id") == summary.sessionID).fetchAll(db)
        }
        let project = try #require(projects.first)
        #expect(projects.count == 1)
        #expect(project.rootURL.storagePath == repo.storagePath)
        #expect(project.lastCommitAt == GraveyardTestSupport.commitDate)
        #expect(project.hasUncommitted)

        let candidates = try await harness.candidates(summary.sessionID)
        let artifacts = candidates.filter { $0.category == .projectArtifact }
        let nodeModules = repo.appending(path: "node_modules").storagePath
        #expect(Set(artifacts.map(\.url.storagePath)) == [nodeModules, repo.appending(path: ".venv").storagePath])
        #expect(artifacts.allSatisfy { $0.projectID == project.id && $0.kind == .folder })
        #expect(Set(artifacts.map(\.ruleID)) == ["graveyard.node.node_modules", "graveyard.python..venv"])
        #expect(project.artifactsSize == artifacts.reduce(0) { $0 + $1.freeableSize })

        let inside = candidates.filter { $0.url.storagePath.hasPrefix(repo.storagePath + "/") && !artifacts.contains($0) }
        #expect(inside.isEmpty)

        let expected = try [
            "left-pad/package.json",
            "left-pad/index.js",
            "left-pad/node_modules/inner/package.json",
            "left-pad/node_modules/inner/index.js",
        ]
        .map { try ScanTest.allocated(harness.fixture.url("Code/webapp/node_modules/\($0)")) }
        .reduce(0, +)
        let node = try #require(artifacts.first { $0.url.storagePath == nodeModules })
        #expect(node.freeableSize == expected)
        #expect(node.reason.contains("webapp"))
    }

    @Test func `artifact folders are part of the size tree`() async throws {
        let harness = try Harness("GraveyardTree")
        let repo = try Self.makeRepo(harness.fixture)

        let summary = try await harness.scan()
        let nodes = try ScanTest.nodes(harness.database, session: summary.sessionID)
        let node = try #require(nodes[repo.appending(path: "node_modules").storagePath])
        #expect(node.allocatedSize > 0)
    }
}
