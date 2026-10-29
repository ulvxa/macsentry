import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct PipelineHarness {
    static let megabyte: Int64 = 1 << 20
    static let old = Date(timeIntervalSinceNow: -400 * 86400)

    let fixture: FixtureBuilder
    let database: MacSentryCore.Database
    let pipeline: ScanPipeline

    var home: URL {
        fixture.root
    }

    init(
        _ name: String,
        apps: [InstalledApp] = [],
        ignored: [String] = [],
        neverTouch: [String] = [],
        finder: any DuplicateFinder = DefaultDuplicateFinder(),
    ) throws {
        fixture = try FixtureBuilder(name: "Pipeline\(name)")
        let databaseFolder = try FixtureBuilder(name: "PipelineDB\(name)")
        let environment = AppEnvironment(
            arguments: [
                "MacSentry",
                "-MacSentryScanRoot", fixture.root.path(percentEncoded: false),
                "-MacSentryDryRun", "YES",
                "-MacSentryDatabasePath", databaseFolder.root.appending(path: "macsentry.sqlite").path(percentEncoded: false),
            ],
            realHomeURL: fixture.root,
        )
        database = try MacSentryCore.Database.inMemory()
        let root = fixture.root
        let inventory = TestAppInventory(apps: apps)
        let protection = ProtectionPolicyProvider(
            environment: environment,
            neverTouchStore: InMemoryNeverTouchStore(patterns: neverTouch),
            ignoredPathStore: InMemoryIgnoredPathStore(urls: ignored.map { root.appending(path: $0) }),
            appInventory: inventory,
        )
        pipeline = ScanPipeline(
            environment: environment,
            database: database,
            protection: protection,
            inventory: inventory,
            projectScanner: GraveyardTestSupport.scanner(home: fixture.root),
            lastUsedResolver: FixedLastUsedResolver(),
            duplicateFinder: finder,
            ruleFileSystem: Self.confined(to: root),
        )
    }

    static func confined(to root: URL) -> RuleFileSystem {
        let prefix = root.storagePath + "/"
        let live = RuleFileSystem.live
        return RuleFileSystem(
            contentsOfDirectory: { (($0.storagePath + "/").hasPrefix(prefix)) ? live.contentsOfDirectory($0) : [] },
            itemExists: { $0.storagePath.hasPrefix(prefix) && live.itemExists($0) },
        )
    }

    func scan(_ options: ScanPipelineOptions = ScanPipelineOptions(), control: ScanControl = ScanControl()) async throws -> ScanSummary {
        let service = pipeline.makeService(options: options, control: control)
        let events = try await ScanTest.collect(service.scan(config: pipeline.config(scanRoots: [])))
        return try #require(ScanTest.summary(events))
    }

    func candidates(_ session: Int64) async throws -> [Candidate] {
        try await database.writer.read { db in
            try Candidate.filter(Column("session_id") == session).order(Column("path")).fetchAll(db)
        }
    }

    func candidates(_ session: Int64, in category: MacSentryCore.Category) async throws -> [Candidate] {
        try await candidates(session).filter { $0.category == category }
    }

    func session(_ id: Int64) async throws -> ScanSession? {
        try await database.writer.read { try ScanSession.fetchOne($0, key: id) }
    }

    func url(_ relative: String) -> URL {
        home.appending(path: relative)
    }

    static func app(_ name: String, bundleID: String, home: URL) -> InstalledApp {
        InstalledApp(bundleID: bundleID, name: name, version: "1.0", url: home.appending(path: "Applications/\(name).app"))
    }
}

struct GatedDuplicateFinder: DuplicateFinder {
    let base = DefaultDuplicateFinder()

    func find(sizeIndex: SizeIndex, options: DuplicateOptions) -> AsyncThrowingStream<DuplicateEvent, Error> {
        let upstream = base.find(sizeIndex: sizeIndex, options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .finished = event {
                            try await Task.sleep(for: .seconds(30))
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
