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
}
