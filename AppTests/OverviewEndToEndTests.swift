import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

private struct FixtureGitClient: GitClient {
    let commitDate = Date(timeIntervalSince1970: 1_709_294_400)

    func lastCommitDate(in _: URL) async throws(GitError) -> Date? {
        commitDate
    }

    func hasUncommittedChanges(in _: URL) async throws(GitError) -> Bool {
        false
    }
}

private struct NoLastUsedResolver: LastUsedResolver {
    func lastUsed(for _: [URL]) async -> [URL: Date] {
        [:]
    }
}

@MainActor
struct OverviewEndToEndTests {
    private static let megabyte: Int64 = 1 << 20
    private static let old = Date(timeIntervalSinceNow: -400 * 86400)

    private static func confined(to root: URL) -> RuleFileSystem {
        let prefix = treemapStoragePath(root) + "/"
        let live = RuleFileSystem.live
        return RuleFileSystem(
            contentsOfDirectory: { (treemapStoragePath($0) + "/").hasPrefix(prefix) ? live.contentsOfDirectory($0) : [] },
            itemExists: { treemapStoragePath($0).hasPrefix(prefix) && live.itemExists($0) },
        )
    }

    private static func buildHome(_ fixture: FixtureBuilder) throws {
        try fixture.file("Applications/Installed.app/Contents/Info.plist", size: 512)
        try fixture.file("Library/Developer/Xcode/DerivedData/Foo/blob", size: megabyte)
        try fixture.file("Library/Caches/com.installed.app/blob", size: megabyte)
        try fixture.file("Documents/old-report.bin", size: 8 * megabyte, created: old, modified: old)
        try fixture.file("Code/webapp/package.json", size: 20)
        try fixture.file("Code/webapp/src/index.js", size: 100)
        try "node_modules/\n.venv/\n".write(to: fixture.url("Code/webapp/.gitignore"), atomically: true, encoding: .utf8)
        try fixture.file("Code/webapp/.git/HEAD", size: 23)
        try fixture.file("Code/webapp/node_modules/left-pad/package.json", size: 10)
        try fixture.file("Code/webapp/node_modules/left-pad/index.js", size: 4096)
        try fixture.file("Code/webapp/.venv/pyvenv.cfg", size: 30)
        try fixture.file("Code/webapp/.venv/lib/site.py", size: 2048)
        try fixture.file("Library/Application Support/com.fake.deletedapp/state.db", size: 64 * 1024)
        for index in 0 ..< 3 {
            try fixture.file("Downloads/dup-\(index).bin", size: 2 * megabyte, fill: 0x64)
        }
        try fixture.sparseFile("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", logicalSize: 4 << 30)
    }

    private static func makeApp(_ fixture: FixtureBuilder) async throws -> AppModel {
        let environment = try fixture.environment()
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        settings.thresholds = Thresholds(minAgeDays: 180, minSize: 5 * Self.megabyte, ageBasis: .modified)
        let app = AppModel(environment: environment, settingsStore: settings)

        let database = try Database.inMemory()
        let installed = InstalledApp(
            bundleID: "com.installed.app",
            name: "Installed",
            version: "1.0",
            url: fixture.root.appending(path: "Applications/Installed.app"),
        )
        let inventory = TestAppInventory(apps: [installed])
        let protection = ProtectionPolicyProvider(
            environment: environment,
            neverTouchStore: InMemoryNeverTouchStore(),
            ignoredPathStore: InMemoryIgnoredPathStore(),
            appInventory: inventory,
        )
        let pipeline = ScanPipeline(
            environment: environment,
            database: database,
            protection: protection,
            inventory: inventory,
            projectScanner: DefaultProjectScanner(git: FixtureGitClient()),
            lastUsedResolver: NoLastUsedResolver(),
            ruleFileSystem: Self.confined(to: fixture.root),
        )
        await app.attach(AppServices(
            candidates: GRDBCandidateStore(database: database),
            quarantine: TestQuarantineService(),
            neverTouch: InMemoryNeverTouchStore(),
            inventory: inventory,
            protection: protection,
            ruleGroups: RuleGroups.bundled(),
            scanConfig: { pipeline.config(scanRoots: $0) },
            makeScanService: { pipeline.makeService(options: $0) },
            volume: FakeVolumeSampler(total: 500_000_000_000, free: 200_000_000_000),
            snapshots: StubLocalSnapshotChecker(count: 0),
        ))
        return app
    }

    @Test func `a full scan through the app populates every sidebar section with correct counts`() async throws {
        let fixture = try FixtureBuilder(name: "AppEndToEnd")
        try Self.buildHome(fixture)
        let app = try await Self.makeApp(fixture)
        #expect(app.total(for: .devCaches) == nil)

        app.startScan()
        await app.waitForScan()
        guard case let .finished(summary) = app.scanState else {
            Issue.record("Scan did not finish: \(app.scanState)")
            return
        }
        #expect(app.currentSessionID == summary.sessionID)

        let expected: [SidebarItem: Int] = [
            .devCaches: 1, .appCaches: 1, .oldLarge: 1, .projects: 2, .orphans: 1, .duplicates: 2, .flagged: 1,
        ]
        #expect(await eventually { expected.allSatisfy { app.total(for: $0.key)?.count == $0.value } })
        for (item, count) in expected {
            #expect(app.total(for: item)?.count == count, "\(item.title)")
        }
        #expect(app.total(for: .overview) == nil)
        #expect(app.total(for: .quarantine) == nil)
        let sum = expected.keys.reduce(0) { $0 + (app.total(for: $1)?.count ?? 0) }
        #expect(sum == summary.candidateCount)

        for item in [SidebarItem.devCaches, .appCaches, .orphans, .flagged] {
            let list = CandidateListModel(configuration: .forItem(item), app: app)
            list.activate()
            #expect(await eventually { list.candidates.count == expected[item] }, "\(item.title) list")
        }

        let overview = OverviewModel(app: app)
        await overview.activate()
        await overview.waitForOffenders()
        #expect(overview.phase == .loaded)
        #expect(overview.cards.map(\.total.count) == OverviewModel.cardItems.map { expected[$0] ?? -1 })
        #expect(overview.cards.first { $0.item == .duplicates }?.offenders.count == 2)
        #expect(await eventually { overview.treemap?.phase == .loaded })
    }
}
