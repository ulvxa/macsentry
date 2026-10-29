import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct GraveyardQuarantineTests {
    @Test func `quarantining a projects artifacts leaves its git directory and sources untouched`() async throws {
        let harness = try QuarantineHarness(name: "GraveyardQuarantine")
        let fixture = harness.fixture
        let repo = try fixture.folder("home/Code/webapp")
        try fixture.file("home/Code/webapp/.git/HEAD", size: 24)
        try fixture.file("home/Code/webapp/package.json", size: 20)
        try fixture.file("home/Code/webapp/src/index.js", size: 100)
        let nodeModules = try fixture.folder("home/Code/webapp/node_modules")
        try fixture.file("home/Code/webapp/node_modules/left-pad/index.js", size: 4096)
        let venv = try fixture.folder("home/Code/webapp/.venv")
        try fixture.file("home/Code/webapp/.venv/pyvenv.cfg", size: 30)
        let candidates = try [
            harness.candidate(nodeModules, ruleID: "graveyard.node.node_modules", tier: .green),
            harness.candidate(venv, ruleID: "graveyard.python..venv", tier: .yellow),
        ]

        let result = await harness.makeService().quarantine(candidates)

        #expect(result.failed.isEmpty)
        #expect(result.moved.count == 2)
        #expect(!exists(nodeModules))
        #expect(!exists(venv))
        for kept in [".git/HEAD", "package.json", "src/index.js"] {
            #expect(exists(repo.appending(path: kept)))
        }
        #expect(Set(result.moved.map(\.originalURL.storagePath)) == [nodeModules.storagePath, venv.storagePath])
    }
}
