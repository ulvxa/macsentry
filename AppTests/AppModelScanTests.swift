import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

@MainActor
struct AppModelScanTests {
    private static func summary(session: Int64, unreadable: [URL] = []) -> ScanSummary {
        ScanSummary(
            sessionID: session,
            status: .finished,
            duration: .seconds(131),
            filesVisited: 1204,
            bytesVisited: 9_000_000_000,
            unreadable: unreadable,
            skippedDataless: 0,
            candidateCount: 3,
            totalFreeable: 82_400_000_000,
        )
    }

    @Test func `scan runs idle to scanning to finished and switches session`() async throws {
        let summary = Self.summary(session: 2)
        let harness = try await CandidateHarness(name: "ScanFinish") {
            StubScanService(events: [
                .started(sessionID: 2),
                .phase(.walking),
                .progress(filesVisited: 10, bytesVisited: 100, currentPath: "/a"),
                .finished(summary),
            ])
        }
        let app = harness.app
        #expect(app.scanState == .idle)
        #expect(app.currentSessionID == 1)

        app.startScan()
        #expect(app.isScanning)
        #expect(app.statusOverlayKind == 1)
        await app.waitForScan()

        #expect(app.scanState == .finished(summary))
        #expect(app.currentSessionID == 2)
        #expect(app.runningSessionID == nil)
        #expect(app.toast?.kind == .scanFinished(summary))
        #expect(app.toast?.autoDismisses == true)
        #expect(app.statusOverlayKind == 2)
        #expect(harness.scans.options.count == 1)
    }

    @Test func `cancel stops the scan and keeps previous results`() async throws {
        let harness = try await CandidateHarness(name: "ScanCancel") { HangingScanService(sessionID: 2) }
        let app = harness.app
        app.startScan()
        #expect(await eventually { app.runningSessionID == 2 })
        #expect(await eventually { app.scanActivity?.filesVisited == 42 })

        app.cancelScan()
        await app.waitForScan()
        #expect(app.scanState == .cancelled)
        #expect(!app.isScanning)
        #expect(app.runningSessionID == nil)
        #expect(app.currentSessionID == 1)
        #expect(app.toast?.kind == .scanCancelled(hasPreviousResults: true))
        #expect(app.canStartScan)
    }

    @Test func `cancel waits for the old scan to end before another can start`() async throws {
        let release = TickGate()
        let harness = try await CandidateHarness(name: "ScanCancelling", controlledScan: { control in
            SlowCancelScanService(sessionID: 2, control: control, release: release)
        })
        let app = harness.app
        app.startScan()
        #expect(await eventually { app.scanActivity?.filesVisited == 7 })

        app.cancelScan()
        #expect(app.isCancellingScan)
        #expect(!app.isScanning)
        #expect(!app.canStartScan)
        #expect(app.statusOverlayKind == 1)
        #expect(app.menuBar.scanStatus() == .cancelling)
        app.startScan()
        #expect(harness.scans.options.count == 1)

        await release.tick()
        await app.waitForScan()
        #expect(app.scanState == .cancelled)
        #expect(app.canStartScan)
        #expect(app.toast?.kind == .scanCancelled(hasPreviousResults: true))
        app.startScan()
        #expect(harness.scans.options.count == 2)
        app.cancelScan()
        await release.tick()
        await app.waitForScan()
    }

    @Test func `a session removed by retention is dropped when the next scan starts`() async throws {
        let harness = try await CandidateHarness(name: "ScanVanished", sessions: [
            ScanSession(id: 1, startedAt: Date(), finishedAt: Date(), status: .finished, roots: []),
            ScanSession(id: 2, startedAt: Date(), finishedAt: Date(), status: .finished, roots: []),
        ]) { HangingScanService(sessionID: 3) }
        let app = harness.app
        #expect(app.currentSessionID == 2)
        await harness.store.deleteSession(id: 2)

        app.startScan()
        #expect(await eventually { app.currentSessionID == 1 })
        #expect(app.latestFinishedSession?.id == 1)
        app.cancelScan()
        await app.waitForScan()
        #expect(app.currentSessionID == 1)
    }

    @Test func `scan failure surfaces the error`() async throws {
        let harness = try await CandidateHarness(name: "ScanFail") {
            StubScanService(events: [.started(sessionID: 2)], error: .persistence("disk full"))
        }
        harness.app.startScan()
        await harness.app.waitForScan()
        let message = ScanError.persistence("disk full").localizedDescription
        #expect(harness.app.scanState == .failed(message))
        #expect(harness.app.toast?.kind == .scanFailed(message))
        #expect(harness.app.toast?.autoDismisses == false)
    }

    @Test func `quarantine is disabled for the running session and allowed for the finished one`() async throws {
        let previous = CandidateHarness.candidate(id: 1, session: 1, name: "Previous")
        let running = CandidateHarness.candidate(id: 2, session: 2, name: "Running")
        let harness = try await CandidateHarness(name: "ScanQuarantine", candidates: [previous, running]) {
            HangingScanService(sessionID: 2)
        }
        let app = harness.app
        app.startScan()
        #expect(await eventually { app.runningSessionID == 2 })

        #expect(app.quarantineBlockReason(for: [running]) == "Wait for the scan to finish")
        #expect(await app.quarantine([running]) == nil)
        #expect(app.toast?.kind == .message("Nothing was quarantined. Wait for the scan to finish"))
        #expect(app.quarantineBlockReason(for: [previous]) == nil)
        let result = try #require(await app.quarantine([previous]))
        #expect(result.moved.count == 1)
        #expect(await harness.quarantine.quarantineCalls.map { $0.compactMap(\.id) } == [[1]])
        app.cancelScan()
    }

    @Test func `a confirm sheet left open across a session change explains why nothing moved`() async throws {
        let harness = try await CandidateHarness(name: "ListStaleConfirm", candidates: [CandidateHarness.candidate(id: 1, name: "One")])
        let model = harness.list(.devCaches)
        #expect(await eventually { model.checkedIDs == [1] })
        model.requestQuarantine()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.destination == harness.app.quarantineFolderDisplay)
        #expect(confirmation.message
            .hasSuffix("moves to ~/\(DefaultQuarantineService.folderName). Nothing is deleted, and you can restore it."))

        await harness.app.reloadSessions(preferring: 2)
        await model.confirm(confirmation)
        #expect(await harness.quarantine.quarantineCalls.isEmpty)
        let reason = try #require(harness.app.quarantineBlockReason(for: confirmation.candidates))
        #expect(harness.app.toast?.kind == .message("Nothing was quarantined. \(reason)"))
    }

    @Test func `scan options come from settings`() async throws {
        let harness = try await CandidateHarness(name: "ScanOptions") { StubScanService(events: []) } configure: { store in
            store.minAgeDays = 90
            store.minSizeBytes = 2_000_000_000
            store.disabledProfileGroups = ["Unity"]
            store.duplicateMinSizeBytes = 5_000_000
        }
        harness.app.startScan()
        await harness.app.waitForScan()
        let options = try #require(harness.scans.options.first)
        #expect(options.thresholds == Thresholds(minAgeDays: 90, minSize: 2_000_000_000, ageBasis: .lastUsed))
        #expect(options.disabledGroups == ["Unity"])
        #expect(options.duplicateMinSize == 5_000_000)
        #expect(options.projectRoots == [harness.fixture.root.standardizedFileURL])
    }

    @Test func `sidebar badges follow category totals`() async throws {
        let harness = try await CandidateHarness(name: "ScanBadges", candidates: [
            CandidateHarness.candidate(id: 1, name: "A", size: 2_000_000_000),
            CandidateHarness.candidate(id: 2, name: "B", size: 1_000_000_000),
            CandidateHarness.candidate(id: 3, name: "C", category: .appCache, ruleID: "app.cache", size: 500_000_000),
        ])
        let app = harness.app
        #expect(await eventually { app.badgeBytes(for: .devCaches) == 3_000_000_000 })
        #expect(app.badgeBytes(for: .appCaches) == 500_000_000)
        #expect(app.total(for: .devCaches)?.count == 2)
        #expect(app.badgeBytes(for: .overview) == nil)
        #expect(app.badgeBytes(for: .quarantine) == nil)
    }

    @Test func `flag only rows count under Flagged and never as reclaimable`() async throws {
        let gigabyte: Int64 = 1_000_000_000
        let harness = try await CandidateHarness(name: "ScanActionTotals", candidates: [
            CandidateHarness.candidate(id: 1, name: "DerivedData", size: 2 * gigabyte),
            CandidateHarness.candidate(id: 2, name: "Leftover", category: .orphan, ruleID: "orphan.caches", size: gigabyte),
            CandidateHarness.candidate(
                id: 3, name: "agent.plist", category: .orphan, ruleID: "orphan.launchAgents", action: .flagOnly, size: 3 * gigabyte,
            ),
            CandidateHarness.candidate(
                id: 4,
                name: "Docker.raw",
                category: .flagged,
                ruleID: "docker.raw",
                action: .flagOnly,
                size: 4 * gigabyte,
            ),
            CandidateHarness.candidate(id: 5, name: "RootOwned", action: .flagOnly, size: 5 * gigabyte),
        ])
        let app = harness.app
        #expect(await eventually { app.totalsLoaded })
        #expect(app.badgeBytes(for: .devCaches) == 2 * gigabyte)
        #expect(app.badgeBytes(for: .orphans) == gigabyte)
        #expect(app.total(for: .flagged) == CategoryTotal(count: 3, freeable: 12 * gigabyte))
        #expect(app.reclaimableBytes == 3 * gigabyte)
        #expect(app.menuBar.totals.reclaimable == 3 * gigabyte)

        let flagged = harness.list(.flagged)
        #expect(await eventually { flagged.candidates.compactMap(\.id) == [5, 4, 3] })
        let overview = OverviewModel(app: app)
        await overview.activate()
        await overview.waitForOffenders()
        #expect(overview.cards.first { $0.item == .flagged }?.total.count == 3)
        #expect(overview.cards.first { $0.item == .flagged }?.offenders.map(\.id) == [5, 4, 3])
        #expect(overview.cards.first { $0.item == .orphans }?.offenders.map(\.id) == [2])
    }

    @Test func `no badges and no session before the first scan`() async throws {
        let harness = try await CandidateHarness(name: "ScanNone", sessions: [])
        #expect(harness.app.currentSessionID == nil)
        #expect(harness.app.badgeBytes(for: .devCaches) == nil)
        let model = harness.list(.devCaches)
        #expect(model.phase == .noScan)
    }

    @Test func `inspector collapses automatically when the window gets narrow`() async throws {
        let harness = try await CandidateHarness(name: "Inspector")
        let app = harness.app
        app.windowSize = CGSize(width: 1200, height: 780)
        #expect(app.isInspectorPresented)
        app.windowSize = CGSize(width: 960, height: 620)
        #expect(!app.isInspectorPresented)
        app.toggleInspector()
        #expect(app.isInspectorPresented)
        app.windowSize = CGSize(width: 1300, height: 780)
        app.windowSize = CGSize(width: 1000, height: 780)
        #expect(!app.isInspectorPresented)
    }

    @Test func `duration and toast text formatting`() {
        #expect(DurationFormat.string(.seconds(131)) == "2 min 11 s")
        #expect(DurationFormat.string(.seconds(48)) == "48 s")
        #expect(DurationFormat.string(.seconds(3720)) == "1 h 2 min")
        #expect(SizeStops.index(for: 500_000_000) == 6)
        #expect(SizeStops.index(for: 0) == 0)
        #expect(SizeStops.index(for: 1) == 1)
    }
}
