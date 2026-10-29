import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

@MainActor
struct CandidateListModelTests {
    @Test func `moving the age filter changes results without a rescan`() async throws {
        let harness = try await CandidateHarness(name: "ListAge", candidates: [
            CandidateHarness.candidate(id: 1, name: "Old", category: .oldLarge, ruleID: "oldLarge", ageDays: 400),
            CandidateHarness.candidate(id: 2, name: "Recent", category: .oldLarge, ruleID: "oldLarge", ageDays: 40),
        ])
        let model = harness.list(.oldLarge)
        #expect(model.filter.minAgeDays == 180)
        #expect(await eventually { model.candidates.map(\.id) == [1] })

        model.filter.minAgeDays = 30
        #expect(await eventually { Set(model.candidates.compactMap(\.id)) == [1, 2] })
        #expect(harness.scans.options.isEmpty)
        #expect(harness.app.scanState == .idle)
    }

    @Test func `filters initialize from settings thresholds and size filters in the query`() async throws {
        let harness = try await CandidateHarness(
            name: "ListSize",
            candidates: [
                CandidateHarness.candidate(id: 1, name: "Big", category: .oldLarge, ruleID: "oldLarge", size: 5_000_000_000),
                CandidateHarness.candidate(id: 2, name: "Small", category: .oldLarge, ruleID: "oldLarge", size: 50_000_000),
            ],
            configure: { $0.minSizeBytes = 1_000_000_000 },
        )
        let model = harness.list(.oldLarge)
        #expect(model.filter.minSizeBytes == 1_000_000_000)
        #expect(model.candidateFilter.minFreeable == 1_000_000_000)
        #expect(model.candidateFilter.categories == [.oldLarge])
        #expect(await eventually { model.candidates.map(\.id) == [1] })

        model.filter.minSizeBytes = SizeStops.values[0]
        #expect(await eventually { model.candidates.count == 2 })
    }

    @Test func `cache orphan and flagged lists start without age or size filters`() async throws {
        let harness = try await CandidateHarness(
            name: "ListUnfiltered",
            candidates: [
                CandidateHarness.candidate(id: 1, name: "FreshCache", size: 2_000_000, ageDays: 0),
                CandidateHarness.candidate(id: 2, name: "FreshAppCache", category: .appCache, ruleID: "npm.cache", size: 1000, ageDays: 1),
                CandidateHarness.candidate(id: 3, name: "Leftover", category: .orphan, ruleID: "orphan.caches", size: 64000, ageDays: 2),
                CandidateHarness.candidate(
                    id: 4, name: "Docker.raw", category: .flagged, ruleID: "docker.vmDisk", action: .flagOnly, size: 3000, ageDays: 0,
                ),
            ],
            configure: {
                $0.minAgeDays = 365
                $0.minSizeBytes = 5_000_000_000
            },
        )
        for (item, id) in [(SidebarItem.devCaches, Int64(1)), (.appCaches, 2), (.orphans, 3), (.flagged, 4)] {
            let model = harness.list(item)
            #expect(model.defaultFilter == .unfiltered, "\(item)")
            #expect(model.candidateFilter.minAgeDays == nil, "\(item)")
            #expect(model.candidateFilter.minFreeable == 0, "\(item)")
            #expect(await eventually { model.candidates.compactMap(\.id) == [id] }, "\(item)")

            harness.app.settings.minAgeDays = 30
            harness.app.settings.minSizeBytes = 100_000_000
            model.thresholdsChanged(to: harness.app.settings.thresholds)
            #expect(model.filter == .unfiltered, "\(item)")
        }

        let caches = harness.list(.devCaches)
        caches.filter.minSizeBytes = SizeStops.values[1]
        #expect(await eventually { caches.candidates.isEmpty })
        caches.filter = .unfiltered
        caches.filter.minAgeDays = 30
        #expect(await eventually { caches.candidates.isEmpty })

        let oldLarge = harness.list(.oldLarge)
        #expect(oldLarge.filter.minAgeDays == 30)
        #expect(oldLarge.filter.minSizeBytes == 100_000_000)
        #expect(FilterState.unfiltered.summary(controls: FilterControl.listControls) == "Any age · Any size · all tiers")
    }

    @Test func `default selection is green only and never for orphans`() async throws {
        let harness = try await CandidateHarness(name: "ListDefault", candidates: [
            CandidateHarness.candidate(id: 1, name: "Green", tier: .green),
            CandidateHarness.candidate(id: 2, name: "Yellow", tier: .yellow),
            CandidateHarness.candidate(id: 3, name: "Red", tier: .red),
            CandidateHarness.candidate(id: 4, name: "Leftover", category: .orphan, ruleID: "orphan.caches", tier: .green),
        ])
        let caches = harness.list(.devCaches)
        #expect(await eventually { caches.candidates.count == 3 })
        #expect(caches.checkedIDs == [1])
        #expect(caches.primaryTitle == "Quarantine 1 item, 1 GB")

        let orphans = harness.list(.orphans)
        #expect(await eventually { orphans.candidates.count == 1 })
        #expect(orphans.checkedIDs.isEmpty)
        #expect(!orphans.hasDefaultSelectable)
    }

    @Test func `blocked items are never preselected`() async throws {
        let harness = try await CandidateHarness(
            name: "ListBlocked",
            candidates: [CandidateHarness.candidate(id: 1, name: "DerivedData", bundleID: "com.apple.dt.Xcode")],
            running: ["com.apple.dt.Xcode"],
        )
        let model = harness.list(.devCaches)
        #expect(await eventually { model.candidates.count == 1 })
        #expect(model.checkedIDs.isEmpty)
        #expect(model.blockReason(model.candidates[0]) == "Quit Xcode to quarantine this")
    }

    @Test func `dev caches group by rule group with tri state checkbox`() async throws {
        let harness = try await CandidateHarness(name: "ListGroups", candidates: [
            CandidateHarness.candidate(id: 1, name: "DerivedData", size: 3_000_000_000),
            CandidateHarness.candidate(id: 2, name: "DeviceSupport", ruleID: "xcode.deviceSupport", tier: .yellow, size: 2_000_000_000),
            CandidateHarness.candidate(id: 3, name: "npm", ruleID: "npm.cache", size: 1_000_000_000),
        ])
        let model = harness.list(.devCaches)
        #expect(await eventually { model.rows.count == 2 })
        let xcode = try #require(model.rows.first)
        #expect(xcode.name == "Xcode")
        #expect(xcode.children.count == 2)
        #expect(xcode.freeable == 5_000_000_000)
        #expect(model.checkState(of: xcode) == .mixed)

        model.toggleCheck(xcode)
        #expect(model.checkState(of: xcode) == .on)
        model.toggleCheck(xcode)
        #expect(model.checkState(of: xcode) == .off)
        #expect(model.candidates(for: [.group("Xcode")]).compactMap(\.id) == [1, 2])
    }

    @Test func `sort order maps to the SQL sort`() async throws {
        let harness = try await CandidateHarness(name: "ListSort", candidates: [
            CandidateHarness.candidate(id: 1, name: "b", category: .oldLarge, ruleID: "oldLarge", size: 2_000_000_000),
            CandidateHarness.candidate(id: 2, name: "a", category: .oldLarge, ruleID: "oldLarge", size: 1_000_000_000),
        ])
        let model = harness.list(.oldLarge)
        #expect(await eventually { model.candidates.map(\.id) == [1, 2] })
        model.sortOrder = [KeyPathComparator(\CandidateRow.name)]
        #expect(model.sort == CandidateSort(column: .name, ascending: true))
        #expect(await eventually { model.candidates.map(\.id) == [2, 1] })
    }

    @Test func `quarantine from the bar moves checked items and reports failures`() async throws {
        let failing = CandidateHarness.candidate(id: 2, name: "Two")
        let harness = try await CandidateHarness(
            name: "ListQuarantine",
            candidates: [CandidateHarness.candidate(id: 1, name: "One"), failing],
        )
        await harness.quarantine.setMoveFailure(.appRunning, for: failing.url)
        let model = harness.list(.devCaches)
        #expect(await eventually { model.checkedIDs == [1, 2] })
        #expect(model.quarantineDisabledReason == nil)

        await model.quarantineChecked()
        #expect(await harness.quarantine.quarantineCalls.count == 1)
        #expect(await eventually { model.candidates.compactMap(\.id) == [2] })
        let report = try #require(model.failureReport)
        #expect(report.reasons.map(\.title) == ["App is running"])
        #expect(harness.app.toast?.action?.destination == .quarantine)
    }

    @Test func `command delete opens a confirm sheet before quarantining`() async throws {
        let harness = try await CandidateHarness(name: "ListConfirm", candidates: [
            CandidateHarness.candidate(id: 1, name: "One"),
            CandidateHarness.candidate(id: 2, name: "Two", tier: .yellow),
        ])
        let model = harness.list(.devCaches)
        #expect(await eventually { model.candidates.count == 2 })
        model.checkedIDs = [1, 2]
        #expect(model.screenActions.canQuarantine)
        model.requestQuarantine()
        let confirmation = try #require(model.confirmation)
        #expect(confirmation.nonSafeCount == 1)
        #expect(await harness.quarantine.quarantineCalls.isEmpty)

        await model.confirm(confirmation)
        #expect(await harness.quarantine.quarantineCalls.first?.count == 2)
    }

    @Test func `ignore removes rows through the store`() async throws {
        let harness = try await CandidateHarness(name: "ListIgnore", candidates: [CandidateHarness.candidate(id: 1, name: "One")])
        let model = harness.list(.devCaches)
        #expect(await eventually { model.candidates.count == 1 })
        await model.ignore([.item(1)])
        #expect(await eventually { model.candidates.isEmpty })
        #expect(await harness.store.isIgnored(URL(filePath: "/fixture/One", directoryHint: .isDirectory)))
    }

    @Test func `flagged list shows only flag only candidates with commands`() async throws {
        let harness = try await CandidateHarness(name: "ListFlagged", candidates: [
            CandidateHarness.candidate(id: 1, name: "Docker.raw", category: .flagged, ruleID: "docker.raw", tier: .red, action: .flagOnly),
            CandidateHarness.candidate(id: 2, name: "agent.plist", category: .orphan, ruleID: "orphan.launchAgents", action: .flagOnly),
            CandidateHarness.candidate(id: 3, name: "Leftover", category: .orphan, ruleID: "orphan.caches"),
        ])
        let model = harness.list(.flagged)
        #expect(await eventually { model.candidates.count == 2 })
        #expect(model.checkedIDs.isEmpty)
        #expect(!model.screenActions.canQuarantine)
        #expect(model.candidates.first?.resolvedCommand == "tool prune '/fixture/Docker.raw'")
        #expect(harness.app.quarantineBlockReason(for: model.candidates) != nil)
    }

    @Test func `changing only the age basis re queries the list`() async throws {
        var opened = CandidateHarness.candidate(id: 1, name: "Opened", category: .oldLarge, ruleID: "oldLarge", ageDays: 400)
        opened.lastUsedAt = Date().addingTimeInterval(-10 * 86400)
        let harness = try await CandidateHarness(name: "ListAgeBasis", candidates: [opened])
        let model = harness.list(.oldLarge)
        #expect(await eventually { model.queryCount > 0 })
        #expect(model.candidates.isEmpty)

        harness.app.settings.ageBasis = .modified
        model.thresholdsChanged(to: harness.app.settings.thresholds)
        #expect(await eventually { model.candidates.compactMap(\.id) == [1] })
        #expect(model.candidateFilter.ageBasis == .modified)
    }

    @Test func `the low confidence group checkbox is disabled but its rows stay checkable`() async throws {
        var low = CandidateHarness.candidate(id: 1, name: "maybe-cli", category: .orphan, ruleID: "orphan.caches")
        low.confidence = .low
        var high = CandidateHarness.candidate(id: 2, name: "gone-app", category: .orphan, ruleID: "orphan.caches")
        high.confidence = .high
        let harness = try await CandidateHarness(name: "ListLowGroup", candidates: [low, high])
        let model = harness.list(.orphans)
        #expect(await eventually { model.candidates.count == 2 })
        let sections = OrphanSections.rows(model.candidates)
        let lowSection = try #require(sections.first { $0.name == Confidence.low.sectionTitle })
        let highSection = try #require(sections.first { $0.name == Confidence.high.sectionTitle })

        #expect(!model.canToggle(lowSection))
        model.toggleCheck(lowSection)
        #expect(model.checkedIDs.isEmpty)
        let lowRow = try #require(lowSection.children.first)
        #expect(model.canToggle(lowRow))
        model.toggleCheck(lowRow)
        #expect(model.checkedIDs == [1])
        #expect(model.canToggle(highSection))
        model.toggleCheck(highSection)
        #expect(model.checkedIDs == [1, 2])
    }

    @Test func `pending row selection from another screen focuses the row`() async throws {
        let target = CandidateHarness.candidate(id: 7, name: "Target", category: .oldLarge, ruleID: "oldLarge")
        let harness = try await CandidateHarness(name: "ListPending", candidates: [target])
        harness.app.reveal(target)
        #expect(harness.app.selection == .oldLarge)
        let model = harness.list(.oldLarge)
        #expect(await eventually { model.focusedIDs == [.item(7)] })
        #expect(harness.app.pendingRowSelection == nil)
    }
}
