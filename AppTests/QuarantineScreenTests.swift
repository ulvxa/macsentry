import Darwin
import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

private struct AllowAllProtection: ProtectionPolicy {
    func check(_: URL) -> ProtectionVerdict {
        .allowed
    }
}

private struct FixtureTrasher: Trasher {
    let trashDirectory: URL

    func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = trashDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

@MainActor
private struct QuarantineScreenHarness {
    let fixture: FixtureBuilder
    let home: URL
    let trash: URL
    let app: AppModel
    let model: QuarantineModel

    var quarantineRoot: URL {
        DefaultQuarantineService.quarantineRoot(home: home)
    }

    init(name: String, dryRun: Bool = false) async throws {
        fixture = try FixtureBuilder(name: name)
        home = try fixture.folder("home")
        trash = home.appending(path: ".Trash", directoryHint: .isDirectory)
        var arguments = ["MacSentry", "-MacSentryScanRoot", home.path(percentEncoded: false)]
        if dryRun {
            arguments += ["-MacSentryDryRun", "YES"]
        }
        try arguments += ["-MacSentryDatabasePath", fixture.url("db/macsentry.sqlite").path(percentEncoded: false)]
        let environment = AppEnvironment(arguments: arguments, realHomeURL: fixture.root)
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: home)
        app = AppModel(environment: environment, settingsStore: settings, notifier: SilentLowSpaceNotifier())
        let service = try DefaultQuarantineService(
            database: Database.inMemory(),
            quarantineRoot: DefaultQuarantineService.quarantineRoot(home: home),
            isDryRun: environment.isDryRun,
            protectionPolicy: AllowAllProtection(),
            appInventory: TestAppInventory(),
            sizeCalculator: DefaultSizeCalculator(),
            trasher: FixtureTrasher(trashDirectory: trash),
        )
        let store = InMemoryCandidateStore(
            sessions: [ScanSession(id: 1, startedAt: Date(), finishedAt: Date(), status: .finished, roots: [home])],
        )
        let root = home
        await app.attach(AppServices(
            candidates: store,
            quarantine: service,
            neverTouch: InMemoryNeverTouchStore(),
            inventory: TestAppInventory(),
            protection: nil,
            ruleGroups: [:],
            scanConfig: { _ in ScanConfig(roots: [root]) },
            makeScanService: { _, _ in StubScanService(events: []) },
        ))
        model = QuarantineModel(app: app)
    }

    func cacheFolder(_ relativePath: String) throws -> URL {
        let folder = try fixture.folder("home/\(relativePath)")
        try fixture.file("home/\(relativePath)/blob.bin", size: 64 * 1024)
        return folder
    }

    func candidate(for url: URL) async throws -> Candidate {
        let allocated = try await DefaultSizeCalculator().aggregate(folder: url).allocated
        return Candidate(
            sessionID: 1,
            url: url,
            kind: .folder,
            category: .devCache,
            ruleID: "test.cache",
            tier: .green,
            action: .quarantine,
            reason: "test",
            logicalSize: allocated,
            allocatedSize: allocated,
            freeableSize: allocated,
        )
    }

    func quarantine(_ urls: [URL]) async throws -> QuarantineResult {
        var candidates: [Candidate] = []
        for url in urls {
            try await candidates.append(candidate(for: url))
        }
        let result = try #require(await app.quarantine(candidates))
        await model.load()
        return result
    }

    func selectFirstBatch() throws {
        let batch = try #require(model.rows.first)
        model.selection = [batch.id]
    }

    func entry(at index: Int = 0) throws -> QuarantineEntry {
        try #require(model.rows.first?.children[index].entry)
    }
}

private func inode(_ url: URL) -> UInt64? {
    var info = stat()
    return lstat(url.path(percentEncoded: false), &info) == 0 ? info.st_ino : nil
}

private func exists(_ url: URL) -> Bool {
    inode(url) != nil
}

@MainActor
struct QuarantineScreenTests {
    @Test func `quarantining a fixture folder moves the same inode into a mirrored batch path and lists the batch`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenMove")
        let source = try harness.cacheFolder("Library/Caches/com.fixture.app")
        let originalInode = try #require(inode(source))

        let result = try await harness.quarantine([source])

        #expect(result.failed.isEmpty)
        let moved = try #require(result.moved.first)
        let batch = try #require(harness.model.batches.first)
        let mirrored = String(source.path(percentEncoded: false).drop(while: { $0 == "/" }))
        let expected = harness.quarantineRoot.appending(path: batch.batch.folderName).appending(path: mirrored)
        #expect(moved.quarantineURL.standardizedFileURL.path == expected.standardizedFileURL.path)
        #expect(!exists(source))
        #expect(inode(expected) == originalInode)

        #expect(harness.model.phase == .loaded)
        #expect(harness.model.rows.count == 1)
        #expect(harness.model.rows.first?.isDryRun == false)
        #expect(harness.model.rows.first?.children.map(\.entry?.originalURL.lastPathComponent) == ["com.fixture.app"])
        #expect(harness.model.isExpanded(batch.id))
        #expect(harness.model.counts == QuarantineModel.Counts(items: 1, batches: 1, dryRunItems: 0))
        #expect(harness.app.quarantineTotals?.inQuarantine == moved.size)
    }

    @Test func `move to trash asks for confirmation then marks entries trashed and updates the banner`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenTrash")
        let first = try harness.cacheFolder("Library/Caches/one")
        let second = try harness.cacheFolder("Library/Caches/two")
        let result = try await harness.quarantine([first, second])
        let total = result.moved.reduce(Int64(0)) { $0 + $1.size }
        try harness.selectFirstBatch()

        #expect(harness.model.actionableRows().count == 2)
        #expect(harness.model.disabledReason() == nil)
        harness.model.requestTrash()
        let confirmation = try #require(harness.model.trashConfirmation)
        #expect(confirmation.title == "Move 2 items to the Trash?")
        #expect(confirmation.totalBytes == total)
        #expect(!confirmation.isSimulated)

        await harness.model.confirmTrash(confirmation)

        #expect(harness.model.trashConfirmation?.id == nil)
        #expect(harness.model.failureReport?.id == nil)
        let statuses = harness.model.rows.first?.children.compactMap(\.entry?.status)
        #expect(statuses == [.trashed, .trashed])
        let trashed = try (0 ..< 2).map { try harness.entry(at: $0) }
        for entry in trashed {
            let trashURL = try #require(entry.trashURL)
            #expect(trashURL.deletingLastPathComponent().standardizedFileURL.path == harness.trash.standardizedFileURL.path)
            #expect(exists(trashURL))
            #expect(!exists(entry.quarantineURL))
        }
        #expect(harness.app.quarantineTotals?.inQuarantine == 0)
        #expect(harness.app.quarantineTotals?.inTrash == total)
        #expect(harness.model.counts.items == 0)

        #expect(harness.model.actionableRows().isEmpty)
        #expect(harness.model.disabledReason() == QuarantineModel.putBackHint)
        #expect(harness.model.chipText == QuarantineModel.putBackHint)
    }

    @Test func `restore moves the item back to its original path`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenRestore")
        let source = try harness.cacheFolder("Library/Caches/restore-me")
        let originalInode = try #require(inode(source))
        _ = try await harness.quarantine([source])
        try harness.selectFirstBatch()

        await harness.model.restore()

        #expect(harness.model.failureReport?.id == nil)
        #expect(inode(source) == originalInode)
        #expect(try harness.entry().status == .restored)
        #expect(harness.app.quarantineTotals?.inQuarantine == 0)
    }

    @Test func `restore refuses when something exists at the original path and reports why`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenRestoreConflict")
        let source = try harness.cacheFolder("Library/Caches/conflict")
        _ = try await harness.quarantine([source])
        let quarantined = try harness.entry()
        try harness.fixture.folder("home/Library/Caches/conflict")
        try harness.selectFirstBatch()

        await harness.model.restore()

        let report = try #require(harness.model.failureReport)
        #expect(report.title == "Nothing, 1 could not be restored")
        #expect(report.reasons.map(\.id) == [EntryFailureReason.destinationExists.rawValue])
        #expect(report.reasons.first?.message == EntryFailureReason.destinationExists.errorDescription)
        #expect(try harness.entry().status == .inQuarantine)
        #expect(exists(quarantined.quarantineURL))
    }

    @Test func `dry run moves nothing on disk and badges the batch`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenDryRun", dryRun: true)
        let source = try harness.cacheFolder("Library/Caches/dry")
        let originalInode = try #require(inode(source))

        let result = try await harness.quarantine([source])

        #expect(result.moved.count == 1)
        #expect(inode(source) == originalInode)
        #expect(!exists(harness.quarantineRoot))
        let row = try #require(harness.model.rows.first)
        #expect(row.isDryRun)
        #expect(row.children.first?.location?.standardizedFileURL.path == source.standardizedFileURL.path)
        #expect(harness.model.counts == QuarantineModel.Counts(items: 0, batches: 0, dryRunItems: 1))
        #expect(harness.app.quarantineTotals?.inQuarantine == 0)
        #expect(harness.app.quarantineTotals?.dryRunInQuarantine == result.moved.first?.size)

        try harness.selectFirstBatch()
        harness.model.requestTrash()
        let confirmation = try #require(harness.model.trashConfirmation)
        #expect(confirmation.isSimulated)
        #expect(harness.model.isSimulatedTrash())
        #expect(harness.model.trashTitle() == "Simulate Move to Trash…")
        await harness.model.confirmTrash(confirmation)
        #expect(inode(source) == originalInode)
        #expect(!exists(harness.trash))
    }

    @Test func `empty quarantine loads with no rows`() async throws {
        let harness = try await QuarantineScreenHarness(name: "QuarantineScreenEmpty")
        await harness.model.load()
        #expect(harness.model.phase == .loaded)
        #expect(harness.model.rows.isEmpty)
        #expect(harness.model.disabledReason() == "Select items in quarantine")
        #expect(harness.model.chipText == nil)
    }
}
