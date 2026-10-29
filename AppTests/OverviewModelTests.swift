import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct OverviewHarness {
    static let gigabyte: Int64 = 1_000_000_000

    let fixture: FixtureBuilder
    let app: AppModel
    let store: InMemoryCandidateStore
    let quarantine: TestQuarantineService
    let sampler: FakeVolumeSampler

    init(
        name: String,
        candidates: [Candidate] = [],
        dirNodes: [DirNode] = [],
        sessions: [ScanSession]? = nil,
        snapshots: Int = 0,
        scan: @escaping @Sendable () -> any ScanService = { StubScanService(events: []) },
    ) async throws {
        fixture = try FixtureBuilder(name: name)
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        app = try AppModel(environment: fixture.environment(), settingsStore: settings)
        store = InMemoryCandidateStore(
            sessions: sessions ?? [ScanSession(id: 1, startedAt: Date(), finishedAt: Date(), status: .finished, roots: [fixture.root])],
            candidates: candidates,
            dirNodes: dirNodes,
        )
        quarantine = TestQuarantineService()
        sampler = FakeVolumeSampler(VolumeCapacity(
            total: 500 * Self.gigabyte,
            available: 180 * Self.gigabyte,
            importantAvailable: 200 * Self.gigabyte,
        ))
        let root = fixture.root
        await app.attach(AppServices(
            candidates: store,
            quarantine: quarantine,
            neverTouch: InMemoryNeverTouchStore(),
            inventory: TestAppInventory(),
            protection: nil,
            ruleGroups: ["xcode.derivedData": "Xcode", "oldLarge": "Old and Large"],
            scanConfig: { _ in ScanConfig(roots: [root]) },
            makeScanService: { _, _ in scan() },
            volume: sampler,
            snapshots: StubLocalSnapshotChecker(count: snapshots),
        ))
    }

    func overview() async -> OverviewModel {
        let model = OverviewModel(app: app)
        await model.activate()
        await model.waitForOffenders()
        return model
    }
}

@MainActor
struct OverviewModelTests {
    private typealias Harness = OverviewHarness

    private static func candidate(
        _ id: Int64,
        _ name: String,
        category: MacSentryCore.Category = .devCache,
        action: CandidateAction = .quarantine,
        size: Int64,
        session: Int64 = 1,
    ) -> Candidate {
        CandidateHarness.candidate(
            id: id,
            session: session,
            name: name,
            category: category,
            ruleID: category == .oldLarge ? "oldLarge" : "xcode.derivedData",
            action: action,
            size: size,
        )
    }

    @Test func `cards follow sidebar order with totals and the top three offenders`() async throws {
        let harness = try await Harness(name: "OverviewCards", candidates: [
            Self.candidate(1, "DerivedData", size: 14 * Harness.gigabyte),
            Self.candidate(2, "CoreSimulator", size: 9 * Harness.gigabyte),
            Self.candidate(3, "Archives", size: 2 * Harness.gigabyte),
            Self.candidate(4, "Tiny", size: Harness.gigabyte),
            Self.candidate(5, "movie.mov", category: .oldLarge, size: 20 * Harness.gigabyte),
            Self.candidate(6, "Docker.raw", category: .flagged, action: .flagOnly, size: 60 * Harness.gigabyte),
        ])
        let model = await harness.overview()
        #expect(await eventually { model.phase == .loaded })

        #expect(model.cards.map(\.item) == [.devCaches, .appCaches, .oldLarge, .projects, .orphans, .duplicates, .flagged])
        let dev = try #require(model.cards.first)
        #expect(dev.total == CategoryTotal(count: 4, freeable: 26 * Harness.gigabyte))
        #expect(dev.offenders.map(\.name) == ["DerivedData", "CoreSimulator", "Archives"])
        #expect(dev.accessibilityText.hasPrefix("Dev Caches, 26 GB freeable, 4 items. Largest: DerivedData"))
        #expect(model.cards.first { $0.item == .oldLarge }?.offenders.map(\.id) == [5])
        #expect(model.cards.first { $0.item == .flagged }?.total.count == 1)
        #expect(model.cards.first { $0.item == .appCaches }?.total == .zero)
    }

    @Test func `the disk bar excludes flagged items from reclaimable and adds quarantine`() async throws {
        let target = Self.candidate(1, "DerivedData", size: 10 * Harness.gigabyte)
        let harness = try await Harness(name: "OverviewBar", candidates: [
            target,
            Self.candidate(2, "Old.iso", category: .oldLarge, size: 5 * Harness.gigabyte),
            Self.candidate(3, "Docker.raw", category: .flagged, action: .flagOnly, size: 60 * Harness.gigabyte),
        ])
        let model = await harness.overview()
        #expect(await eventually { harness.app.reclaimableBytes == 15 * Harness.gigabyte })
        let breakdown = try #require(model.breakdown)
        #expect(breakdown.free == 200 * Harness.gigabyte)
        #expect(breakdown.reclaimable == 15 * Harness.gigabyte)
        #expect(breakdown.used == 285 * Harness.gigabyte)

        _ = await harness.app.quarantine([target])
        await model.refreshCapacity()
        #expect(await eventually { model.breakdown?.quarantine == 10 * Harness.gigabyte })
        #expect(await eventually { model.breakdown?.reclaimable == 5 * Harness.gigabyte })
        #expect(model.breakdown.map { $0.segments.reduce(0) { $0 + $1.bytes } } == 500 * Harness.gigabyte)
    }

    @Test func `no scan state hides cards and treemap and keeps reclaimable unscanned`() async throws {
        let harness = try await Harness(name: "OverviewNoScan", sessions: [])
        let model = await harness.overview()
        #expect(model.phase == .noScan)
        #expect(model.scanCaption == "Never scanned")
        #expect(model.lastScanCaptionDate == nil)
        #expect(model.breakdown?.isScanned == false)
        #expect(model.treemap?.phase == .noScan)
    }

    @Test func `a finished scan with nothing found reports the empty phase`() async throws {
        let harness = try await Harness(name: "OverviewEmpty")
        let model = await harness.overview()
        #expect(await eventually { model.phase == .nothingFound })
        #expect(model.scanCaption == "Last scan")
        #expect(model.lastScanCaptionDate != nil)
    }

    @Test func `local snapshots raise the caveat`() async throws {
        let withSnapshots = try await Harness(name: "OverviewSnapshots", snapshots: 2)
        #expect(withSnapshots.app.hasLocalSnapshots)
        let without = try await Harness(name: "OverviewNoSnapshots")
        #expect(!without.app.hasLocalSnapshots)
    }

    @Test func `scanning swaps the caption and a new session reloads cards and treemap`() async throws {
        let summary = ScanSummary(
            sessionID: 2,
            status: .finished,
            duration: .seconds(3),
            filesVisited: 10,
            bytesVisited: 100,
            unreadable: [],
            skippedDataless: 0,
            candidateCount: 1,
            totalFreeable: Harness.gigabyte,
        )
        let gate = ScanGate()
        let harness = try await Harness(
            name: "OverviewRescan",
            candidates: [
                Self.candidate(1, "Before", size: Harness.gigabyte),
                Self.candidate(2, "After", size: 3 * Harness.gigabyte, session: 2),
            ],
        ) {
            GatedScanService(gate: gate, events: [.started(sessionID: 2), .phase(.walking), .finished(summary)])
        }
        let app = harness.app
        let model = await harness.overview()
        #expect(app.currentSessionID == 1)
        #expect(await eventually { model.cards.first?.offenders.map(\.name) == ["Before"] })

        app.startScan()
        #expect(await eventually { app.scanActivity?.phase == .walking })
        #expect(model.scanCaption == ScanPhase.walking.label)
        #expect(model.lastScanCaptionDate == nil)
        await gate.open()
        await app.waitForScan()
        #expect(app.currentSessionID == 2)
        await model.sessionChanged()
        await model.waitForOffenders()
        #expect(await eventually { model.cards.first?.offenders.map(\.name) == ["After"] })
        #expect(model.cards.first?.total.count == 1)
        #expect(model.scanCaption == "Last scan")
    }

    @Test func `option clicking a treemap tile selects that candidate in its list`() async throws {
        let base = URL(filePath: "/fixture")
        let nodes = [
            DirNode(id: 1, sessionID: 1, parentID: nil, url: base, name: "fixture", depth: 0, allocatedSize: 30, fileCount: 3),
            DirNode(
                id: 2,
                sessionID: 1,
                parentID: 1,
                url: base.appending(path: "Movie"),
                name: "Movie",
                depth: 1,
                allocatedSize: 20,
                fileCount: 1,
            ),
        ]
        let movie = Self.candidate(9, "Movie", category: .oldLarge, size: 20 * Harness.gigabyte)
        let harness = try await Harness(name: "OverviewReveal", candidates: [movie], dirNodes: nodes)
        let model = await harness.overview()
        let treemap = try #require(model.treemap)
        #expect(await eventually { treemap.phase == .loaded })
        let tile = try #require(treemap.placedTiles(in: CGSize(width: 400, height: 300)).first { $0.item.name == "Movie" })

        await treemap.activate(tile, selectingCandidate: true)
        #expect(await eventually { harness.app.selection == .oldLarge })
        #expect(harness.app.pendingRowSelection == PendingRowSelection(item: .oldLarge, candidateID: 9))

        let list = CandidateListModel(configuration: .forItem(.oldLarge), app: harness.app)
        list.activate()
        #expect(await eventually { list.focusedIDs == [.item(9)] })
        #expect(harness.app.pendingRowSelection == nil)
    }
}

actor ScanGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

struct GatedScanService: ScanService {
    let gate: ScanGate
    let events: [ScanEvent]

    func scan(config _: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if case .finished = event {
                        await gate.wait()
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
