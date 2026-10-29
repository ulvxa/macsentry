import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct SettingsStoreTests {
    private static func defaults(_ fixture: FixtureBuilder) throws -> UserDefaults {
        // An absolute suite name keeps the plist inside the fixture instead of ~/Library/Preferences.
        try #require(UserDefaults(suiteName: fixture.url("prefs/settings").path(percentEncoded: false)))
    }

    @Test func `defaults match settings table`() throws {
        let fixture = try FixtureBuilder(name: "SettingsDefaults")
        let store = try SettingsStore(defaults: Self.defaults(fixture), homeURL: fixture.root)
        #expect(store.minAgeDays == 180)
        #expect(store.minSizeBytes == 100_000_000)
        #expect(store.largeFileMinSizeBytes == 1_000_000_000)
        #expect(store.ageBasis == .lastUsed)
        #expect(store.scanRoots.map(\.storagePath) == ["/"])
        #expect(store.projectRoots.map(\.storagePath) == [fixture.root.storagePath])
        #expect(store.projectIdleDays == 90)
        #expect(store.duplicateRoots.map(\.lastPathComponent) == ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"])
        #expect(store.duplicateRoots.allSatisfy { $0.storagePath.hasPrefix(fixture.root.storagePath) })
        #expect(store.duplicateMinSizeBytes == 1_000_000)
        #expect(store.disabledProfileGroups.isEmpty)
        #expect(store.menuBarEnabled)
        #expect(store.menuBarShowText)
        #expect(!store.launchAtLogin)
        #expect(store.diskAlertEnabled)
        #expect(store.diskAlertThresholdBytes == 30_000_000_000)
        #expect(store.appearance == .system)
        #expect(!store.limitedMode)
        #expect(store.thresholds == Thresholds())
    }

    @Test func `values persist across instances`() throws {
        let fixture = try FixtureBuilder(name: "SettingsPersist")
        let store = try SettingsStore(defaults: Self.defaults(fixture), homeURL: fixture.root)
        store.thresholds = Thresholds(minAgeDays: 30, minSize: 5_000_000_000, ageBasis: .modified)
        store.scanRoots = [
            fixture.root.appending(path: "Projects"),
            URL(filePath: "/Volumes/Data"),
            fixture.root.appending(path: "Projects"),
        ]
        store.appearance = .dark
        store.limitedMode = true
        store.diskAlertThresholdBytes = 10_000_000_000

        let reopened = try SettingsStore(defaults: Self.defaults(fixture), homeURL: fixture.root)
        #expect(reopened.thresholds == Thresholds(minAgeDays: 30, minSize: 5_000_000_000, ageBasis: .modified))
        #expect(reopened.scanRoots.map(\.storagePath) == [fixture.root.appending(path: "Projects").storagePath, "/Volumes/Data"])
        #expect(reopened.appearance == .dark)
        #expect(reopened.limitedMode)
        #expect(reopened.diskAlertThresholdBytes == 10_000_000_000)
        let raw = try Self.defaults(fixture).stringArray(forKey: SettingsKey.scanRoots.rawValue)
        #expect(raw == ["~/Projects", "/Volumes/Data"])
    }

    @Test func `user path expands and abbreviates against home`() {
        let home = URL(filePath: "/fixture/home", directoryHint: .isDirectory)
        #expect(UserPath.expand("~", homeURL: home).storagePath == "/fixture/home")
        #expect(UserPath.expand("~/Work/a", homeURL: home).storagePath == "/fixture/home/Work/a")
        #expect(UserPath.expand("/tmp/x/../y", homeURL: home).storagePath == "/tmp/y")
        #expect(UserPath.abbreviate(URL(filePath: "/fixture/home/Work"), homeURL: home) == "~/Work")
        #expect(UserPath.abbreviate(URL(filePath: "/fixture/homework"), homeURL: home) == "/fixture/homework")
        #expect(UserPath.abbreviate(home, homeURL: home) == "~")
    }
}
