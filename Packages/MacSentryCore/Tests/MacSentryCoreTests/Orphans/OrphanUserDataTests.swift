import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct OrphanUserDataTests {
    private static let old = Date().addingTimeInterval(-30 * 86400)
    private static let support = "home/Library/Application Support"

    @Test func `folders holding saves, project libraries, credentials or tokens are red and low confidence`() async throws {
        let home = try OrphanFixture()
        let fixture = home.fixture
        try fixture.file("\(Self.support)/com.fake.game/saves/World1/level.dat", size: 10)
        try fixture.file("\(Self.support)/com.fake.editor/Editor/Fake Project Library/library.bin", size: 10)
        try fixture.file("\(Self.support)/com.fake.matlab/credentials", size: 10)
        try fixture.file("\(Self.support)/com.fake.tunnel/tunnel.yml", size: 10)
        try fixture.file("\(Self.support)/com.fake.keys/certs/server.pem", size: 10)
        try fixture.file("\(Self.support)/com.fake.auth/auth_token.json", size: 10)
        try fixture.file("\(Self.support)/com.fake.plain/cache.bin", size: 10)

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        let marked = ["com.fake.game", "com.fake.editor", "com.fake.matlab", "com.fake.tunnel", "com.fake.keys", "com.fake.auth"]
        for name in marked {
            let candidate = try #require(findings.finding(named: name)?.candidate, "\(name)")
            #expect(candidate.tier == .red, "\(name)")
            #expect(candidate.confidence == .low, "\(name)")
            #expect(candidate.action == .quarantine, "\(name)")
            #expect(candidate.reason.contains("holds your own data"), "\(name)")
        }
        #expect(findings.finding(named: "com.fake.game")?.candidate.reason.contains("saves") == true)
        #expect(findings.finding(named: "com.fake.editor")?.explanation.notes.last?.contains("Fake Project Library") == true)
        let plain = try #require(findings.finding(named: "com.fake.plain")?.candidate)
        #expect(plain.tier == .yellow)
        #expect(plain.confidence == .high)
    }

    @Test func `a database and its sidecars become one red candidate sized together`() async throws {
        let home = try OrphanFixture()
        let fixture = home.fixture
        try fixture.file("\(Self.support)/library.store", size: 8192, modified: Self.old)
        try fixture.file("\(Self.support)/library.store-wal", size: 4096, modified: Self.old)
        try fixture.file("\(Self.support)/library.store-shm", size: 4096, modified: Self.old)
        try fixture.file("\(Self.support)/lonely.sqlite-journal", size: 512, modified: Self.old)

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.names == ["library.store", "lonely.sqlite-journal"])
        let store = try #require(findings.finding(named: "library.store")?.candidate)
        #expect(store.tier == .red)
        #expect(store.kind == .file)
        #expect(store.logicalSize == 16384)
        #expect(store.freeableSize > store.allocatedSize)
        #expect(store.reason.contains("library.store-wal"))
        #expect(findings.finding(named: "lonely.sqlite-journal")?.candidate.tier == .red)
    }

    @Test func `a database changed in the last week means its owner is still in use`() async throws {
        let home = try OrphanFixture()
        let fixture = home.fixture
        try fixture.file("\(Self.support)/default.store", size: 8192, modified: Self.old)
        try fixture.file("\(Self.support)/fresh.store", size: 8192, modified: Self.old)
        try fixture.file("\(Self.support)/fresh.store-wal", size: 4096)
        try fixture.file("\(Self.support)/com.fake.live/Data/state.sqlite", size: 4096)
        try fixture.file("home/Library/Caches/com.fake.running/Cache.db", size: 4096)
        try fixture.file("home/Library/Caches/com.fake.stale/Cache.db", size: 4096, modified: Self.old)

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.names == ["com.fake.stale"])
        let stale = try #require(findings.finding(named: "com.fake.stale")?.candidate)
        #expect(stale.tier == .green)
        #expect(stale.confidence == .high)
    }

    @Test func `marker search stops three levels down`() async throws {
        let home = try OrphanFixture()
        let fixture = home.fixture
        try fixture.folder("\(Self.support)/com.fake.shallow/a/b/saves")
        try fixture.folder("\(Self.support)/com.fake.deep/a/b/c/saves")

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.finding(named: "com.fake.shallow")?.candidate.tier == .red)
        #expect(findings.finding(named: "com.fake.deep")?.candidate.tier == .yellow)
    }

    @Test func `names that reuse an identifier of an Apple app are never high confidence`() async throws {
        let home = try OrphanFixture()
        let shortcuts = try appleApp(home, name: "Shortcuts", bundleID: "com.apple.shortcuts", extra: [
            "NSUserActivityTypes": ["is.workflow.my.app.runaction"],
            "CFBundleURLTypes": [["CFBundleURLName": "is.workflow.app.url-scheme"]],
        ])
        let homeApp = try appleApp(home, name: "Home", bundleID: "com.apple.Home")
        try home.folder("Application Support/is.workflow.legacy")
        try home.folder("Application Support/com.shortcuts.helper")
        try home.folder("Application Support/Home")
        try home.folder("Application Support/HomeAssistant")
        try home.folder("Application Support/com.fake.other")

        let findings = try await home.detector().findings(inventory: [shortcuts, homeApp], library: home.library)

        let legacy = try #require(findings.finding(named: "is.workflow.legacy"))
        #expect(legacy.candidate.confidence == .medium)
        #expect(legacy.explanation.notes.contains { $0.contains("Shortcuts") && $0.contains("comes with macOS") })
        #expect(findings.finding(named: "com.shortcuts.helper")?.candidate.confidence == .medium)
        #expect(findings.finding(named: "Home") == nil)
        #expect(findings.finding(named: "HomeAssistant") != nil)
        #expect(findings.finding(named: "com.fake.other")?.candidate.confidence == .high)
    }

    private func appleApp(_ home: OrphanFixture, name: String, bundleID: String, extra: [String: Any] = [:]) throws -> InstalledApp {
        let appPath = "System/Applications/\(name).app"
        let plist = try home.fixture.file("\(appPath)/Contents/Info.plist")
        let info = extra.merging(["CFBundleIdentifier": bundleID, "CFBundleName": name]) { $1 }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        return try InstalledApp(bundleID: bundleID, name: name, version: nil, url: home.fixture.url(appPath))
    }
}
