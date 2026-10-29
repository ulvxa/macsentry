import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct DuplicatesTests {
    private static let size: Int64 = 20_000_000

    private struct Seed {
        let files: FixtureBuilder
        let candidates: [Candidate]
        let groups: [DuplicateGroup]

        func url(_ relative: String) throws -> URL {
            try files.url(relative)
        }
    }

    private static func member(
        _ id: Int64,
        _ url: URL,
        group: Int64,
        freeable: Int64 = size,
        status: CandidateStatus = .found,
    ) -> Candidate {
        Candidate(
            id: id, sessionID: 1, url: url, kind: .file, category: .duplicate, ruleID: DuplicateGroup.ruleID, tier: .yellow,
            action: .quarantine, reason: "Same content", logicalSize: size, allocatedSize: size, freeableSize: freeable,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)), dupGroupID: group, status: status,
        )
    }

    private static func group(_ id: Int64, keeper: URL, copies: Int, reclaimable: Int64) -> DuplicateGroup {
        DuplicateGroup(
            id: id, sessionID: 1, contentHash: "hash\(id)", fileSize: size, memberCount: copies + 1,
            reclaimableSize: reclaimable, keeperURL: keeper,
        )
    }

    private static func seed(name: String, keeperExists: Bool = true) throws -> Seed {
        let files = try FixtureBuilder(name: name)
        let paths = [
            "Documents/holiday.mov", "Desktop/holiday.mov", "Downloads/holiday.mov",
            "Movies/clip.mov", "Movies/clip copy.mov", "Documents/old.bin", "Desktop/old.bin",
        ]
        for (index, path) in paths.enumerated() where keeperExists || index != 0 {
            try files.sparseFile(path, logicalSize: size)
        }
        let urls = try paths.map(files.url)
        return Seed(
            files: files,
            candidates: [
                member(1, urls[1], group: 1),
                member(2, urls[2], group: 1),
                member(3, urls[4], group: 2, freeable: 0),
                member(4, urls[6], group: 3, status: .quarantined),
            ],
            groups: [
                group(1, keeper: urls[0], copies: 2, reclaimable: 2 * size),
                group(2, keeper: urls[3], copies: 1, reclaimable: 0),
                group(3, keeper: urls[5], copies: 1, reclaimable: size),
            ],
        )
    }

    private static func harness(_ seed: Seed, name: String) async throws -> (CandidateHarness, DuplicatesModel) {
        let harness = try await CandidateHarness(name: name, candidates: seed.candidates, duplicateGroups: seed.groups)
        let model = DuplicatesModel(app: harness.app)
        model.activate()
        return (harness, model)
    }

    @Test func `three identical files form one group with the keeper preselected and two copies to quarantine`() async throws {
        let seed = try Self.seed(name: "DupThree")
        let (harness, model) = try await Self.harness(seed, name: "DupThreeApp")
        #expect(await eventually { model.phase == .loaded && model.groups.count == 2 })

        let three = try #require(model.groups.first)
        #expect(three.groupID == 1)
        #expect(three.members.count == 3)
        #expect(three.keeper.isKeeper)
        #expect(try three.keeper.path == seed.url("Documents/holiday.mov").path(percentEncoded: false))
        #expect(three.members.filter(\.isKeeper).count == 1)
        #expect(three.candidates.compactMap(\.id) == [1, 2])
        #expect(three.reclaimable == 2 * Self.size)
        #expect(model.tableRows.first?.children.count == 3)
        #expect(model.checkedGroupIDs.isEmpty)

        model.toggleCheck(three)
        #expect(model.checkedCandidates.compactMap(\.id) == [1, 2])
        #expect(model.primaryTitle == "Quarantine 2 duplicates, 40 MB")
        #expect(model.quarantineDisabledReason == nil)

        await model.quarantineChecked()
        #expect(await harness.quarantine.quarantineCalls.map { $0.compactMap(\.id) } == [[1, 2]])
        #expect(await eventually { model.groups.map(\.groupID) == [2] })
        #expect(model.checkedGroupIDs.isEmpty)
    }

    @Test func `clone pair is grouped, shown as space efficient and cannot be checked`() async throws {
        let seed = try Self.seed(name: "DupClone")
        let (_, model) = try await Self.harness(seed, name: "DupCloneApp")
        #expect(await eventually { model.groups.count == 2 })

        let clones = try #require(model.group(2))
        #expect(clones.isSpaceEfficient)
        #expect(clones.reclaimable == 0)
        #expect(clones.members.count == 2)
        #expect(try #require(model.group(1)).isSpaceEfficient == false)
        #expect(!model.isCheckable(clones))
        model.toggleCheck(clones)
        #expect(model.checkedGroupIDs.isEmpty)
    }

    @Test func `only groups stored in the database are listed and fully quarantined ones are hidden`() async throws {
        let seed = try Self.seed(name: "DupOnlyDB")
        let (_, model) = try await Self.harness(seed, name: "DupOnlyDBApp")
        #expect(await eventually { model.phase == .loaded })
        #expect(model.groups.map(\.groupID) == [1, 2])
        #expect(model.group(3) == nil)
        let listed = Set(model.groups.flatMap { $0.members.map(\.path) })
        let expected = try Set([
            "Documents/holiday.mov",
            "Desktop/holiday.mov",
            "Downloads/holiday.mov",
            "Movies/clip.mov",
            "Movies/clip copy.mov",
        ]
        .map { try seed.url($0).path(percentEncoded: false) })
        #expect(listed == expected)

        model.query = "clip copy"
        #expect(model.visibleGroups.map(\.groupID) == [2])
    }

    @Test func `changing the keeper flips which copies are candidates`() async throws {
        let seed = try Self.seed(name: "DupKeeper")
        let (_, model) = try await Self.harness(seed, name: "DupKeeperApp")
        #expect(await eventually { model.groups.count == 2 })
        let original = try seed.url("Documents/holiday.mov").path(percentEncoded: false)
        let desktop = try seed.url("Desktop/holiday.mov").path(percentEncoded: false)
        let downloads = try seed.url("Downloads/holiday.mov").path(percentEncoded: false)
        try model.toggleCheck(#require(model.group(1)))

        let newKeeper = try #require(model.group(1)?.members.first { $0.path == desktop })
        await model.setKeeper(newKeeper)
        #expect(await eventually { model.group(1)?.keeper.path == desktop })

        let group = try #require(model.group(1))
        #expect(group.copies.map(\.path) == [original, downloads].sorted())
        #expect(group.members.filter(\.isKeeper).map(\.path) == [desktop])
        #expect(Set(model.checkedCandidates.map { $0.url.path(percentEncoded: false) }) == [original, downloads])
        #expect(model.quarantineDisabledReason == nil)

        let back = try #require(group.members.first { $0.path == original })
        await model.setKeeper(back)
        #expect(await eventually { model.group(1)?.keeper.path == original })
        #expect(model.group(1)?.copies.map(\.path) == [desktop, downloads].sorted())
    }

    @Test func `quarantining every copy of a group is blocked`() async throws {
        let seed = try Self.seed(name: "DupBlocked", keeperExists: false)
        let (harness, model) = try await Self.harness(seed, name: "DupBlockedApp")
        #expect(await eventually { model.groups.count == 2 })
        let group = try #require(model.group(1))
        #expect(group.isKeeperMissing)
        #expect(group.wouldRemoveEveryCopy)

        model.toggleCheck(group)
        #expect(model.blockedGroups.map(\.groupID) == [1])
        #expect(model.quarantineDisabledReason == DuplicatesModel.keepOneCopyReason)
        await model.quarantineChecked()
        model.requestQuarantine()
        #expect(model.confirmation == nil)
        #expect(await harness.quarantine.quarantineCalls.isEmpty)

        let present = try #require(model.group(2))
        #expect(!present.wouldRemoveEveryCopy(selecting: present.candidates.map(\.url)))
        #expect(present.wouldRemoveEveryCopy(selecting: present.members.map(\.url)))
    }

    @Test func `inspector shows the keeper and the focused copy`() async throws {
        let seed = try Self.seed(name: "DupInspector")
        let (_, model) = try await Self.harness(seed, name: "DupInspectorApp")
        #expect(await eventually { model.groups.count == 2 })
        let group = try #require(model.group(1))
        model.focusedIDs = [group.keeper.id]
        let keeper = try #require(model.focusedCandidates.first)
        #expect(keeper.freeableSize == 0)
        #expect(keeper.url == group.keeper.url)
        model.focusedIDs = [.group(1)]
        #expect(model.focusedCandidates.compactMap(\.id) == [1, 2])
    }
}

@MainActor
struct DuplicatesScanTests {
    @Test func `skip duplicates calls the scan control and the scan finishes`() async throws {
        let summary = ScanSummary(
            sessionID: 2, status: .finished, duration: .seconds(3), filesVisited: 10, bytesVisited: 100,
            unreadable: [], skippedDataless: 0, candidateCount: 0, totalFreeable: 0,
        )
        let harness = try await CandidateHarness(
            name: "DupSkipStub",
            controlledScan: { control in SkippableScanService(control: control, summary: summary) },
        )
        let app = harness.app
        app.startScan()
        #expect(await eventually { app.scanActivity?.isHashingDuplicates == true })
        #expect(app.scanActivity?.phaseTitle == "Hashing duplicates")

        app.skipDuplicates()
        #expect(app.scanActivity?.duplicatesSkipped == true)
        #expect(app.scanActivity?.phaseTitle == "Skipping duplicates")
        await app.waitForScan()

        #expect(harness.scans.controls.count == 1)
        #expect(harness.scans.controls.first?.isDuplicatesSkipped == true)
        #expect(app.scanState == .finished(summary))
        #expect(app.duplicatesSkippedSessionID == 2)
        #expect(app.scanControl == nil)
        let model = DuplicatesModel(app: app)
        model.activate()
        #expect(model.isSkippedForSession)
    }

    private static func pipelineApp() async throws -> (AppModel, GRDBCandidateStore) {
        let fixture = try FixtureBuilder(name: "DupPipeline")
        try fixture.file("Documents/a.bin", size: 2_000_000)
        try fixture.file("Desktop/a.bin", size: 2_000_000)
        let environment = try fixture.environment()
        let database = try MacSentryCore.Database.inMemory()
        let inventory = TestAppInventory()
        let protection = ProtectionPolicyProvider(
            environment: environment,
            neverTouchStore: InMemoryNeverTouchStore(),
            ignoredPathStore: InMemoryIgnoredPathStore(),
            appInventory: inventory,
        )
        let prefix = fixture.root.path(percentEncoded: false)
        let pipeline = ScanPipeline(
            environment: environment,
            database: database,
            protection: protection,
            inventory: inventory,
            lastUsedResolver: FixedLastUsedResolver(),
            duplicateFinder: StallingDuplicateFinder(),
            ruleFileSystem: RuleFileSystem(
                contentsOfDirectory: { $0.path(percentEncoded: false).hasPrefix(prefix) ? RuleFileSystem.live.contentsOfDirectory($0) : []
                },
                itemExists: { $0.path(percentEncoded: false).hasPrefix(prefix) && RuleFileSystem.live.itemExists($0) },
            ),
        )
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        let app = AppModel(environment: environment, settingsStore: settings)
        let store = GRDBCandidateStore(database: database)
        await app.attach(AppServices(
            candidates: store,
            quarantine: TestQuarantineService(),
            neverTouch: InMemoryNeverTouchStore(),
            inventory: inventory,
            protection: protection,
            ruleGroups: [:],
            scanConfig: { pipeline.config(scanRoots: $0) },
            makeScanService: { pipeline.makeService(options: $0, control: $1) },
        ))
        return (app, store)
    }

    @Test(.timeLimit(.minutes(1)))
    func `real pipeline shows hashing progress and skipping finishes the scan without groups`() async throws {
        let (app, store) = try await Self.pipelineApp()
        let started = ContinuousClock.now
        app.startScan()
        #expect(await eventually(timeout: .seconds(20)) { app.scanActivity?.hashing != nil })
        let hashing = try #require(app.scanActivity?.hashing)
        #expect(hashing.total > 0)
        #expect(app.scanActivity?.phaseTitle.hasPrefix("Hashing duplicates") == true)
        app.skipDuplicates()
        await app.waitForScan()

        #expect(ContinuousClock.now - started < .seconds(25))
        guard case let .finished(summary) = app.scanState else {
            Issue.record("Scan did not finish: \(app.scanState)")
            return
        }
        #expect(summary.status == .finished)
        #expect(app.duplicatesSkippedSessionID == summary.sessionID)
        #expect(try await store.duplicateGroups(session: summary.sessionID).isEmpty)
    }
}

struct SkippableScanService: ScanService {
    let control: ScanControl
    let summary: ScanSummary

    func scan(config _: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        let task = Task { [control, summary] in
            continuation.yield(.started(sessionID: summary.sessionID))
            continuation.yield(.phase(.duplicates))
            let deadline = ContinuousClock.now + .seconds(10)
            while !control.isDuplicatesSkipped, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
            continuation.yield(.phase(.lastUsed))
            continuation.yield(.finished(summary))
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

struct StallingDuplicateFinder: DuplicateFinder {
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
