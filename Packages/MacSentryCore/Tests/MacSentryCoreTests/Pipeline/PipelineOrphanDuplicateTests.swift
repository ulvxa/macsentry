import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PipelineOrphanDuplicateTests {
    private typealias Harness = PipelineHarness

    @Test func `leftovers of a deleted app are high confidence orphans, installed and apple folders are not`() async throws {
        let probe = try FixtureBuilder(name: "PipelineOrphanApps")
        let installed = Harness.app("Installed", bundleID: "com.installed.app", home: probe.root)
        let harness = try Harness("Orphans", apps: [installed])
        try harness.fixture.file("Library/Application Support/com.fake.deletedapp/state.db", size: 64 * 1024)
        try harness.fixture.file("Library/Application Support/com.installed.app/state.db", size: 64 * 1024)
        try harness.fixture.file("Library/Application Support/com.apple.something/state.db", size: 64 * 1024)

        let summary = try await harness.scan()
        let orphans = try await harness.candidates(summary.sessionID, in: .orphan)
        let deleted = try #require(orphans.first { $0.url.lastPathComponent == "com.fake.deletedapp" })
        #expect(deleted.confidence == .high)
        #expect(deleted.freeableSize >= 64 * 1024)
        #expect(!orphans.contains { $0.url.lastPathComponent == "com.installed.app" })
        #expect(!orphans.contains { $0.url.lastPathComponent.hasPrefix("com.apple.") })
    }

    @Test func `launch services lookup keeps a folder from being an orphan`() async throws {
        let harness = try Harness("OrphanLaunchServices")
        try harness.fixture.file("Library/Application Support/com.fake.deletedapp/state.db", size: 1024)
        let pipeline = ScanPipeline(
            environment: harness.pipeline.environment,
            database: harness.database,
            protection: harness.pipeline.protection,
            inventory: TestAppInventory(),
            applicationURL: { $0 == "com.fake.deletedapp" ? URL(filePath: "/Applications/Fake.app") : nil },
            lastUsedResolver: FixedLastUsedResolver(),
            ruleFileSystem: Harness.confined(to: harness.home),
        )
        let events = try await ScanTest
            .collect(pipeline.makeService(options: ScanPipelineOptions()).scan(config: pipeline.config(scanRoots: [])))
        let summary = try #require(ScanTest.summary(events))
        #expect(try await harness.candidates(summary.sessionID, in: .orphan).isEmpty)
    }

    private func makeDuplicates(_ fixture: FixtureBuilder) throws -> [URL] {
        let size = 20 * Harness.megabyte
        let triple = try [2019, 2021, 2023].enumerated().map { index, year in
            try fixture.file(
                "Downloads/copy-\(index).bin",
                size: size,
                created: Date(timeIntervalSince1970: TimeInterval(year - 1970) * 365 * 86400),
            )
        }
        let original = try fixture.file("Downloads/movie.mov", size: 5 * Harness.megabyte, fill: 0x62)
        try fixture.clone("Downloads/movie copy.mov", of: original)
        let linked = try fixture.file("Downloads/linked.bin", size: 3 * Harness.megabyte, fill: 0x63)
        try fixture.hardLink("Downloads/linked-2.bin", to: linked)
        return triple
    }

    @Test func `identical files form one group, clones are near free, hard links are not duplicates`() async throws {
        let harness = try Harness("Duplicates")
        let triple = try makeDuplicates(harness.fixture)
        let control = ScanControl()

        let summary = try await harness.scan(control: control)
        #expect(summary.status == .finished)
        let groups = try await harness.database.writer.read { db in
            try DuplicateGroup.filter(Column("session_id") == summary.sessionID).fetchAll(db)
        }
        #expect(groups.count == 2)
        let group = try #require(groups.first { $0.fileSize == 20 * Harness.megabyte })
        #expect(group.memberCount == 3)
        #expect(group.keeperURL.storagePath == triple[0].storagePath)

        let duplicates = try await harness.candidates(summary.sessionID, in: .duplicate)
        let members = duplicates.filter { $0.dupGroupID == group.id }
        #expect(Set(members.map(\.url.storagePath)) == Set(triple.dropFirst().map(\.storagePath)))
        #expect(members.allSatisfy { $0.tier == .yellow && $0.ruleID == DuplicateGroup.ruleID })

        let clones = try #require(groups.first { $0.fileSize == 5 * Harness.megabyte })
        #expect(clones.isSpaceEfficient)
        #expect(!duplicates.contains { $0.url.lastPathComponent.hasPrefix("linked") })

        var progress: HashingProgress?
        for await value in control.hashingProgress {
            progress = value
        }
        #expect(progress.map { $0.total > 0 && $0.done == $0.total } == true)
    }

    @Test func `skipping duplicates mid hash finishes the session without groups`() async throws {
        let harness = try Harness("SkipDuplicates", finder: GatedDuplicateFinder())
        _ = try makeDuplicates(harness.fixture)
        try harness.fixture.file("Library/Developer/Xcode/DerivedData/Foo/blob", size: Harness.megabyte)
        let control = ScanControl()
        let skipper = Task {
            for await _ in control.hashingProgress {
                control.skipDuplicates()
                return true
            }
            return false
        }

        let started = ContinuousClock.now
        let summary = try await harness.scan(control: control)
        #expect(await skipper.value)
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(summary.status == .finished)
        #expect(try await harness.session(summary.sessionID)?.status == .finished)
        let groups = try await harness.database.writer.read { db in
            try DuplicateGroup.filter(Column("session_id") == summary.sessionID).fetchCount(db)
        }
        #expect(groups == 0)
        #expect(try await harness.candidates(summary.sessionID, in: .duplicate).isEmpty)
        #expect(try await harness.candidates(summary.sessionID, in: .devCache).count == 1)
    }

    @Test func `skipping duplicates before the phase starts never hashes`() async throws {
        let harness = try Harness("SkipEarly")
        _ = try makeDuplicates(harness.fixture)
        let control = ScanControl()
        control.skipDuplicates()

        let summary = try await harness.scan(control: control)
        #expect(summary.status == .finished)
        #expect(try await harness.candidates(summary.sessionID, in: .duplicate).isEmpty)
        var updates = 0
        for await _ in control.hashingProgress {
            updates += 1
        }
        #expect(updates == 0)
    }
}
