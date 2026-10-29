import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct GraveyardNodeModulesTests {
    private typealias Support = GraveyardTestSupport

    @Test(arguments: [true, false])
    func `nothing inside node_modules is a project, even without a package json next to it`(honorSkip: Bool) async throws {
        let fixture = try FixtureBuilder(name: "GraveyardNodeModules")
        let base = "Desktop/PROJECTS/solana_test/CANNA_TEST/node_modules"
        try fixture.file("\(base)/axios/package.json", size: 10)
        try fixture.file("\(base)/axios/dist/axios.js", size: 4096)
        try fixture.file("\(base)/rpc-websockets/package.json", size: 10)
        try fixture.file("\(base)/rpc-websockets/node_modules/eventemitter3/package.json", size: 10)
        try fixture.file("\(base)/rpc-websockets/dist/index.js", size: 4096)
        try fixture.file("Desktop/PROJECTS/app/package.json", size: 10)
        try fixture.file("Desktop/PROJECTS/app/src/index.js", size: 100)
        try fixture.file("Desktop/PROJECTS/app/node_modules/lib/package.json", size: 10)
        try fixture.file("Desktop/PROJECTS/app/node_modules/lib/dist/lib.js", size: 4096)
        let collector = GraveyardCollector(
            home: fixture.root,
            quarantineFolder: fixture.root.appending(path: "MacSentry Quarantine"),
            scanner: Support.scanner(home: fixture.root),
        )

        let projects = try await Support.collect(collector, root: fixture.root, honorSkip: honorSkip)

        #expect(projects.map(\.project.name) == ["app"])
        #expect(projects.first?.artifacts.map(\.ruleID) == ["graveyard.node.node_modules"])
        let artifacts = projects.flatMap(\.artifacts).map(\.url.storagePath)
        #expect(!artifacts.contains { $0.contains("/node_modules/") })
        #expect(try collector.isInsideProject(fixture.url("Desktop/PROJECTS/app/src/index.js")))
        #expect(try !collector.isInsideProject(fixture.url("\(base)/axios/dist/axios.js")))
        #expect(try !collector.isInsideProject(fixture.url("Desktop/PROJECTS/notes.txt")))
    }
}
