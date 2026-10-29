import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct ProfilesSettingsTests {
    @Test func `profiles list detected apps first and flag missing ones`() async throws {
        let xcode = InstalledApp(
            bundleID: "com.apple.dt.Xcode",
            name: "Xcode",
            version: "26.3",
            url: URL(filePath: "/Applications/Xcode.app"),
        )
        let model = ProfilesModel()
        try await model.load(catalog: RuleCatalog.bundled(), inventory: TestAppInventory(apps: [xcode]))

        let rows = model.rows
        #expect(rows.first?.group == "Xcode")
        #expect(rows.first?.subtitle == "Xcode 26.3 · 10 rules")
        let docker = try #require(rows.first { $0.group == "Docker" })
        #expect(docker.kind == .notInstalled)
        #expect(docker.subtitle.contains("Not installed"))
        let node = try #require(rows.first { $0.group == "Node" })
        #expect(node.kind == .tool)
        #expect(node.subtitle == "7 rules")
        let kinds = rows.map(\.kind.rawValue)
        #expect(kinds == kinds.sorted())
    }

    @Test func `new settings round trip through the store`() throws {
        let fixture = try FixtureBuilder(name: "SettingsRoundTrip")
        let defaults = try fixture.isolatedDefaults()
        let model = SettingsModel(store: SettingsStore(defaults: defaults, homeURL: fixture.root))
        model.menuBarShowText = false
        model.disabledProfileGroups = ["Xcode", "Docker"]
        model.projectRoots = [fixture.root.appending(path: "Code")]
        model.projectIdleDays = 45
        model.duplicateMinSizeBytes = 200_000
        model.duplicateRoots = [fixture.root.appending(path: "Downloads")]

        let reopened = SettingsModel(store: SettingsStore(defaults: defaults, homeURL: fixture.root))
        #expect(!reopened.menuBarShowText)
        #expect(reopened.disabledProfileGroups == ["Xcode", "Docker"])
        #expect(reopened.projectRoots.map(\.lastPathComponent) == ["Code"])
        #expect(reopened.projectIdleDays == 45)
        #expect(reopened.duplicateMinSizeBytes == 200_000)
        #expect(reopened.duplicateRoots.map(\.lastPathComponent) == ["Downloads"])

        reopened.restoreDefaultDuplicateRoots()
        #expect(reopened.duplicateRoots.map(\.lastPathComponent) == SettingsModel.defaultDuplicateFolders)
    }

    @Test func `duplicate size stops snap to the nearest stop`() {
        #expect(DuplicateSizeStops.values.first == 100_000)
        #expect(DuplicateSizeStops.values.last == 1_000_000_000)
        #expect(DuplicateSizeStops.index(for: 1_000_000) == 3)
        #expect(DuplicateSizeStops.bytes(at: DuplicateSizeStops.index(for: 480_000)) == 500_000)
        #expect(DuplicateSizeStops.bytes(at: 99) == 1_000_000_000)
        #expect(DuplicateSizeStops.bytes(at: -1) == 100_000)
    }
}
