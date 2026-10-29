import Foundation
import GRDB
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PipelineEndToEndTests {
    private typealias Harness = PipelineHarness

    private static let smallThresholds = Thresholds(minAgeDays: 180, minSize: 5 * Harness.megabyte, ageBasis: .modified)

    @Test func `a full scan of a mixed home populates every category`() async throws {
        let probe = try FixtureBuilder(name: "PipelineMixedApps")
        let installed = Harness.app("Installed", bundleID: "com.installed.app", home: probe.root)
        let harness = try Harness("Mixed", apps: [installed])
        let fixture = harness.fixture
        try fixture.file("Library/Developer/Xcode/DerivedData/Foo/blob", size: Harness.megabyte)
        try fixture.file("Library/Caches/com.installed.app/blob", size: Harness.megabyte)
        try fixture.file("Documents/old-report.bin", size: 8 * Harness.megabyte, created: Harness.old, modified: Harness.old)
        _ = try PipelineGraveyardTests.makeRepo(fixture)
        try fixture.file("Library/Application Support/com.fake.deletedapp/state.db", size: 64 * 1024)
        for index in 0 ..< 3 {
            try fixture.file("Downloads/dup-\(index).bin", size: 2 * Harness.megabyte, fill: 0x64)
        }
        try fixture.sparseFile("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", logicalSize: 4 << 30)

        let summary = try await harness.scan(ScanPipelineOptions(thresholds: Self.smallThresholds))
        #expect(summary.status == .finished)
        let totals = try await GRDBCandidateStore(database: harness.database).totals(session: summary.sessionID)
        #expect(totals[.devCache]?.count == 1)
        #expect(totals[.appCache]?.count == 1)
        #expect(totals[.oldLarge]?.count == 1)
        #expect(totals[.projectArtifact]?.count == 2)
        #expect(totals[.orphan]?.count == 1)
        #expect(totals[.duplicate]?.count == 2)
        #expect(totals[.flagged]?.count == 1)
        #expect(totals.values.allSatisfy { $0.freeable >= 0 })

        let candidates = try await harness.candidates(summary.sessionID)
        #expect(Set(candidates.map(\.url.storagePath)).count == candidates.count)
        #expect(summary.candidateCount == candidates.count)
        #expect(summary.totalFreeable == candidates.reduce(0) { $0 + $1.freeableSize })
        #expect(candidates.allSatisfy { $0.lastUsedAt != nil })
        let protection = harness.pipeline.protection
        #expect(candidates.allSatisfy { $0.action == .flagOnly || protection.check($0.url) == .allowed })
    }

    @Test func `protected and ignored paths never become candidates`() async throws {
        let harness = try Harness(
            "Protected",
            ignored: ["Documents/ignored.bin", "Library/Caches/Yarn"],
            neverTouch: ["**/ClientWork/**"],
        )
        let fixture = harness.fixture
        for path in [
            ".ssh/big",
            "Library/Keychains/login.keychain-db",
            "Documents/ignored.bin",
            "Work/ClientWork/big.bin",
            "Documents/visible.bin",
        ] {
            try fixture.file(path, size: 8 * Harness.megabyte, created: Harness.old, modified: Harness.old)
        }
        try fixture.file("Library/Caches/Yarn/v6/blob", size: Harness.megabyte)

        let summary = try await harness.scan(ScanPipelineOptions(thresholds: Self.smallThresholds))
        let paths = try await harness.candidates(summary.sessionID).map(\.url.storagePath)
        #expect(paths.contains(fixture.root.appending(path: "Documents/visible.bin").storagePath))
        for denied in [".ssh", "Library/Keychains", "Documents/ignored.bin", "Work/ClientWork", "Library/Caches/Yarn"] {
            let prefix = fixture.root.appending(path: denied).storagePath
            #expect(!paths.contains { $0 == prefix || $0.hasPrefix(prefix + "/") }, "\(denied) leaked")
        }
    }

    @Test func `flag only candidates stay visible on protected paths`() async throws {
        let harness = try Harness("FlagOnlyProtected", neverTouch: ["**/MobileSync/**"])
        try harness.fixture.file("Library/Application Support/MobileSync/Backup/device-1/Info.plist", size: 4096)

        let summary = try await harness.scan()
        let backup = try #require(try await harness.candidates(summary.sessionID).first { $0.ruleID == "mobileSync.backups" })
        #expect(backup.action == .flagOnly)
        #expect(harness.pipeline.protection.check(backup.url) != .allowed)
    }

    @Test func `stale running sessions from an earlier launch are marked failed`() async throws {
        let harness = try Harness("Stale")
        try harness.fixture.file("a.bin", size: 10)
        let staleID = try await harness.database.writer.write { db in
            var session = ScanSession(startedAt: Date(timeIntervalSinceNow: -3600), status: .running, roots: [harness.home])
            try session.insert(db)
            return try #require(session.id)
        }

        let summary = try await harness.scan()
        #expect(summary.status == .finished)
        let stale = try #require(try await harness.session(staleID))
        #expect(stale.status == .failed)
        #expect(stale.finishedAt != nil)
        #expect(stale.error != nil)
    }

    @Test func `a protection refresh failure stops the scan with a typed error`() async throws {
        let harness = try Harness("RefreshFails")
        let protection = ProtectionPolicyProvider(
            environment: harness.pipeline.environment,
            neverTouchStore: FailingNeverTouchStore(),
            ignoredPathStore: InMemoryIgnoredPathStore(),
        )
        let pipeline = ScanPipeline(
            environment: harness.pipeline.environment,
            database: harness.database,
            protection: protection,
            inventory: TestAppInventory(),
            lastUsedResolver: FixedLastUsedResolver(),
            ruleFileSystem: Harness.confined(to: harness.home),
        )
        await #expect(throws: ScanPipelineError.self) {
            _ = try await ScanTest
                .collect(pipeline.makeService(options: ScanPipelineOptions()).scan(config: pipeline.config(scanRoots: [])))
        }
        let sessions = try await harness.database.writer.read { try ScanSession.fetchCount($0) }
        #expect(sessions == 0)
    }

    @Test func `artifact predicate matches catalog folders by trailing components`() {
        let isArtifact = ScanPipeline.isKnownArtifact()
        #expect(isArtifact(URL(filePath: "/Users/me/Code/app/node_modules")))
        #expect(isArtifact(URL(filePath: "/Users/me/Code/app/.angular/cache")))
        #expect(!isArtifact(URL(filePath: "/Users/me/Code/app/cache")))
        #expect(!isArtifact(URL(filePath: "/Users/me/Code/app/src")))
    }
}

private struct FailingNeverTouchStore: NeverTouchStore {
    func patterns() async throws -> [NeverTouchPattern] {
        throw ProtectionStoreError.database("disk on fire")
    }

    func add(_: String, note _: String?) async throws {}

    func remove(id _: Int64) async throws {}
}
