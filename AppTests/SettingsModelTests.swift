import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct SettingsModelTests {
    @Test func `settings model round trips through store`() throws {
        let fixture = try FixtureBuilder(name: "SettingsModel")
        let model = try SettingsModel(store: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root))
        model.minAgeDays = 90
        model.minSizeBytes = 2_000_000_000
        model.ageBasis = .created
        model.appearance = .light
        model.addScanRoots([fixture.root.appending(path: "Projects")])
        model.removeScanRoots([URL(filePath: "/")])

        let reopened = try SettingsModel(store: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root))
        #expect(reopened.thresholds == Thresholds(minAgeDays: 90, minSize: 2_000_000_000, ageBasis: .created))
        #expect(reopened.appearance == .light)
        #expect(reopened.scanRoots.map(\.lastPathComponent) == ["Projects"])
        #expect(reopened.displayPath(reopened.scanRoots[0]) == "~/Projects")
    }

    @Test func `log size scale covers range and round trips`() {
        #expect(LogSizeScale.bytes(at: 0) == LogSizeScale.minimum)
        #expect(LogSizeScale.bytes(at: 1) == LogSizeScale.maximum)
        #expect(LogSizeScale.bytes(at: LogSizeScale.position(for: 500_000_000)) == 500_000_000)
        #expect(LogSizeScale.position(for: 1) == 0)
    }

    @Test func `never touch model adds and removes through database across reopen`() async throws {
        let fixture = try FixtureBuilder(name: "NeverTouchModel")
        let environment = try fixture.environment()
        let protected = try fixture.folder("Work/ClientWork/cache")

        let first = try AppModel(
            environment: environment,
            settingsStore: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root),
            permissions: PermissionServiceDouble(granted: true),
            notifier: SilentLowSpaceNotifier(),
        )
        await first.openDatabase()
        let neverTouch = try #require(first.neverTouch)
        neverTouch.draftPattern = "**/ClientWork/**"
        neverTouch.draftNote = "client"
        await neverTouch.add()
        #expect(neverTouch.draftPattern.isEmpty)
        #expect(first.protection?.check(protected) != .allowed)
        neverTouch.testPath = "~/Work/ClientWork/cache"
        #expect(neverTouch.testVerdict != .allowed)

        let second = try AppModel(
            environment: environment,
            settingsStore: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root),
            permissions: PermissionServiceDouble(granted: true),
            notifier: SilentLowSpaceNotifier(),
        )
        await second.openDatabase()
        let reopened = try #require(second.neverTouch)
        #expect(reopened.rows.map(\.pattern) == ["**/ClientWork/**"])
        #expect(second.protection?.check(protected) != .allowed)
        await reopened.remove(ids: Set(reopened.rows.map(\.id)))
        #expect(second.protection?.check(protected) == .allowed)

        let third = try AppModel(
            environment: environment,
            settingsStore: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root),
            permissions: PermissionServiceDouble(granted: true),
            notifier: SilentLowSpaceNotifier(),
        )
        await third.openDatabase()
        #expect(third.neverTouch?.rows.isEmpty == true)
    }

    @Test func `invalid draft shows inline error and is not saved`() async throws {
        let fixture = try FixtureBuilder(name: "NeverTouchInvalid")
        let model = try AppModel(
            environment: fixture.environment(),
            settingsStore: SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root),
            permissions: PermissionServiceDouble(granted: true),
            notifier: SilentLowSpaceNotifier(),
        )
        await model.openDatabase()
        let neverTouch = try #require(model.neverTouch)
        neverTouch.draftPattern = "~/a[b]"
        #expect(neverTouch.draftError != nil)
        #expect(!neverTouch.canAdd)
        await neverTouch.add()
        #expect(neverTouch.rows.isEmpty)

        neverTouch.draftPattern = "**"
        #expect(neverTouch.draftError == nil)
        #expect(neverTouch.draftWarning == GlobWarning.protectsEverything.message)
    }

    @Test func `thresholds preview counts old and large matches in the last finished session`() async throws {
        let gigabyte: Int64 = 1_000_000_000
        let harness = try await CandidateHarness(
            name: "ThresholdPreview",
            candidates: [
                CandidateHarness.candidate(id: 1, name: "Big", category: .oldLarge, ruleID: "oldLarge", size: 5 * gigabyte),
                CandidateHarness.candidate(id: 2, name: "Small", category: .oldLarge, ruleID: "oldLarge", size: gigabyte),
                CandidateHarness.candidate(id: 3, name: "Recent", category: .oldLarge, ruleID: "oldLarge", size: 5 * gigabyte, ageDays: 30),
                CandidateHarness.candidate(id: 4, name: "Cache", size: 5 * gigabyte),
            ],
            configure: {
                $0.minAgeDays = 180
                $0.minSizeBytes = 2 * gigabyte
            },
        )
        let preview = ThresholdPreviewModel()
        await preview.refresh(app: harness.app, debounce: .zero)
        #expect(preview.match == CategoryTotal(count: 1, freeable: 5 * gigabyte))
        #expect(preview.text == "Currently matches 1 item, \(ByteFormat.string(5 * gigabyte))")

        harness.app.settings.minSizeBytes = 500_000_000
        #expect(ThresholdPreviewModel.key(for: harness.app).thresholds.minSize == 500_000_000)
        await preview.refresh(app: harness.app, debounce: .zero)
        #expect(preview.match == CategoryTotal(count: 2, freeable: 6 * gigabyte))

        let empty = try await CandidateHarness(name: "ThresholdPreviewNone", sessions: [])
        await preview.refresh(app: empty.app, debounce: .zero)
        #expect(preview.text == nil)
    }
}
