import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct ProtectionStoreTests {
    @Test func `never touch pattern persists across reopen and removal persists too`() async throws {
        let fixture = try FixtureBuilder(name: "NeverTouchReopen")
        let url = try fixture.url("db/macsentry.sqlite")

        try await GRDBNeverTouchStore(database: Database.open(at: url)).add("**/ClientWork/**", note: " client files ")

        let reopened = try GRDBNeverTouchStore(database: Database.open(at: url))
        let stored = try await reopened.patterns()
        #expect(stored.map(\.pattern) == ["**/ClientWork/**"])
        #expect(stored.first?.note == "client files")
        try await reopened.remove(id: #require(stored.first?.id))

        let afterRemoval = try await GRDBNeverTouchStore(database: Database.open(at: url)).patterns()
        #expect(afterRemoval.isEmpty)
    }

    @Test func `invalid pattern is not saved`() async throws {
        let store = try GRDBNeverTouchStore(database: Database.inMemory())
        await #expect(throws: ProtectionStoreError.invalidPattern(.unsupportedSyntax("["))) {
            try await store.add("~/a[b]", note: nil)
        }
        #expect(try await store.patterns().isEmpty)
    }

    @Test func `duplicate pattern is rejected`() async throws {
        let store = try GRDBNeverTouchStore(database: Database.inMemory())
        try await store.add("~/Work", note: nil)
        await #expect(throws: ProtectionStoreError.duplicatePattern("~/Work")) {
            try await store.add(" ~/Work ", note: "again")
        }
    }

    @Test func `ignored paths add list and remove`() async throws {
        let fixture = try FixtureBuilder(name: "IgnoredPaths")
        let url = try fixture.url("macsentry.sqlite")
        let target = try fixture.folder("Library/Caches/com.example")
        let store = try GRDBIgnoredPathStore(database: Database.open(at: url))
        try await store.add(target)
        try await store.add(target)
        let reopened = try GRDBIgnoredPathStore(database: Database.open(at: url))
        #expect(try await reopened.paths().map(\.url.storagePath) == [target.storagePath])
        try await reopened.remove(target)
        #expect(try await reopened.paths().isEmpty)
    }

    @Test func `provider refreshes after pattern changes and is shared`() async throws {
        let fixture = try FixtureBuilder(name: "Provider")
        let target = try fixture.folder("Work/ClientWork/cache")
        let database = try Database.inMemory()
        let neverTouch = GRDBNeverTouchStore(database: database)
        let ignored = GRDBIgnoredPathStore(database: database)
        let provider = try ProtectionPolicyProvider(
            homeURL: fixture.root,
            databaseURL: fixture.url("db/macsentry.sqlite"),
            neverTouchStore: neverTouch,
            ignoredPathStore: ignored,
        )
        let scannerView: any ProtectionPolicy = provider
        let quarantineView: any ProtectionPolicy = provider
        #expect(scannerView.check(target) == .allowed)

        try await neverTouch.add("**/ClientWork/**", note: nil)
        try await provider.refresh()
        #expect(scannerView.check(target).isDenied)
        #expect(quarantineView.check(target).isDenied)

        let id = try #require(try await neverTouch.patterns().first?.id)
        try await neverTouch.remove(id: id)
        try await ignored.add(target)
        try await provider.refresh()
        #expect(provider.check(target) == .denied("Ignored by you"))
    }

    @Test func `provider uses installed apps from inventory`() async throws {
        let fixture = try FixtureBuilder(name: "ProviderInventory")
        let prefs = try fixture.file("Library/Preferences/com.example.app.plist", size: 1)
        let provider = try ProtectionPolicyProvider(
            homeURL: fixture.root,
            databaseURL: fixture.url("db/macsentry.sqlite"),
            neverTouchStore: InMemoryNeverTouchStore(),
            ignoredPathStore: InMemoryIgnoredPathStore(),
            appInventory: StubInventory(),
        )
        #expect(provider.check(prefs) == .allowed)
        try await provider.refresh()
        #expect(provider.check(prefs).isDenied)
    }
}

private struct StubInventory: AppInventory {
    func installedApps() async -> [InstalledApp] {
        [InstalledApp(bundleID: "com.example.app", name: "Example", version: "1", url: URL(filePath: "/Applications/Example.app"))]
    }

    func isRunning(bundleID _: String) -> Bool {
        false
    }
}
