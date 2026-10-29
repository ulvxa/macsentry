import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct RuleCatalogTests {
    private static let documentedIDs: Set = [
        "xcode.derivedData", "xcode.deviceSupport", "xcode.previews", "xcode.cache", "xcode.archives",
        "xcode.simCaches", "xcode.simDevices", "xcode.simRuntimes", "xcode.xip",
        "android.gradleCaches", "android.gradleDists", "android.studioCaches", "android.studioLogs",
        "android.oldStudioConfig", "android.avd", "android.systemImages",
        "unity.cache", "unity.assetStore", "unity.editors", "unity.logs",
        "docker.vmDisk", "ollama.models", "vmware.vms",
        "npm.cache", "yarn.cache", "pnpm.store", "bun.cache", "pip.cache", "uv.cache", "conda.pkgs", "python38",
        "cargo.registry", "go.modcache", "spm.cache", "cocoapods.cache", "homebrew.cache",
        "adobe.mediaCache", "adobe.mediaCacheDB", "adobe.caches", "resolve.cacheClip", "blender.oldConfig",
        "appcache.generic", "appcache.library",
        "vscode.vsix", "vscode.oldExt", "chrome.cache", "spotify.cache", "spotify.offline", "steam.httpCache",
        "steam.games", "telegram.media", "mobileSync.backups", "arduino.staging",
        "mail.downloads", "logs.user", "crashReports", "zoom.recordings",
    ]

    private static let validRule = """
    {"id":"t.one","group":"Test","category":"devCache","tier":"green","action":"quarantine",
     "match":{"paths":["~/x"],"claimWholeFolder":true},"appBundleIDs":[],"requiresAppQuit":false,
     "reason":"Test.","verify":false}
    """

    @Test func `every bundled rule decodes and validates`() throws {
        let catalog = try RuleCatalog.bundled()
        let ids = Set(catalog.rules.map(\.id))
        #expect(ids.count == catalog.rules.count)
        #expect(Self.documentedIDs.isSubset(of: ids))
        for rule in catalog.rules {
            #expect((rule.action == .flagOnly) == (rule.category == .flagged), "\(rule.id)")
            #expect(rule.cliCommand == nil || rule.action == .flagOnly, "\(rule.id)")
            #expect(!(rule.match.paths ?? []).contains { $0.contains("**") }, "\(rule.id)")
        }
        let verified = Set(catalog.rules.filter(\.verify).map(\.id))
        #expect(verified == ["resolve.cacheClip"])
        #expect(!ids.contains("rpiImager.cache"))
    }

    @Test func `bundled catalog round trips through JSON`() throws {
        let catalog = try RuleCatalog.bundled()
        let data = try JSONEncoder().encode(catalog.rules)
        #expect(try RuleCatalog.decode(data, file: "roundtrip.json") == catalog.rules)
    }

    @Test func `documented tiers and actions`() throws {
        let rules = try Dictionary(uniqueKeysWithValues: RuleCatalog.bundled().rules.map { ($0.id, $0) })
        #expect(rules["xcode.derivedData"]?.tier == .green)
        #expect(rules["xcode.derivedData"]?.match.claimWholeFolder == true)
        #expect(rules["xcode.archives"]?.tier == .red)
        #expect(rules["docker.vmDisk"]?.action == .flagOnly)
        #expect(rules["zoom.recordings"]?.category == .oldLarge)
        #expect(rules["zoom.recordings"]?.match.applyUserThresholds == true)
        #expect(rules["logs.user"]?.match.minAgeDays == 30)
        #expect(rules["logs.user"]?.match.extensions == ["log", "txt", "ips", "crash", "diag", "spin", "hang"])
        #expect(rules["appcache.library"]?.match.excludeBundleIDPrefixes == ["com.apple."])
        #expect(rules["android.oldStudioConfig"]?.match.versionPolicy == .olderThanInstalled)
        #expect(rules["vscode.oldExt"]?.match.versionPolicy == .olderSibling)
    }

    @Test func `valid inline rule decodes`() throws {
        let rules = try RuleCatalog.decode(Data("[\(Self.validRule)]".utf8), file: "inline.json")
        #expect(rules.map(\.id) == ["t.one"])
        #expect(rules.first?.cliCommand == nil)
    }

    @Test func `unknown rule key fails decoding`() {
        let json = Self.validRule.replacingOccurrences(of: "\"verify\":false", with: "\"verify\":false,\"colour\":\"red\"")
        let error = #expect(throws: RuleCatalogError.self) {
            try RuleCatalog.decode(Data("[\(json)]".utf8), file: "inline.json")
        }
        guard case let .invalidJSON(file, reason) = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(file == "inline.json")
        #expect(reason.contains("Unknown keys: colour"))
    }

    @Test func `unknown match key fails decoding`() {
        let json = Self.validRule.replacingOccurrences(
            of: "\"claimWholeFolder\":true",
            with: "\"claimWholeFolder\":true,\"recursive\":true",
        )
        let error = #expect(throws: RuleCatalogError.self) {
            try RuleCatalog.decode(Data("[\(json)]".utf8), file: "inline.json")
        }
        guard case let .invalidJSON(_, reason) = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(reason.contains("recursive"))
    }

    @Test func `runtime only reference version cannot come from JSON`() {
        let json = Self.validRule.replacingOccurrences(
            of: "\"claimWholeFolder\":true",
            with: "\"claimWholeFolder\":true,\"referenceVersion\":\"9\"",
        )
        #expect(throws: RuleCatalogError.self) {
            try RuleCatalog.decode(Data("[\(json)]".utf8), file: "inline.json")
        }
    }

    @Test func `missing required key fails decoding`() {
        let json = Self.validRule.replacingOccurrences(of: ",\"claimWholeFolder\":true", with: "")
        #expect(throws: RuleCatalogError.self) {
            try RuleCatalog.decode(Data("[\(json)]".utf8), file: "inline.json")
        }
    }

    @Test(arguments: ["~/Library/**/Caches", "Library/Caches", "~/a//b", "~/a/../b", "~/a/"])
    func `invalid path is rejected at load`(path: String) {
        let rule = RuleTestKit.rule("t.bad", paths: [path])
        #expect(throws: RuleCatalogError.self) { try RuleCatalog(rules: [rule]) }
    }

    @Test func `cli command on quarantine rule is rejected`() {
        let rule = RuleTestKit.rule("t.cli", paths: ["~/x"], cliCommand: "echo")
        #expect(throws: RuleCatalogError.invalidRule(id: "t.cli", reason: "cliCommand is only allowed on flagOnly rules")) {
            try RuleCatalog(rules: [rule])
        }
    }

    @Test func `duplicate ids are rejected`() {
        let rule = RuleTestKit.rule("t.dup", paths: ["~/x"])
        #expect(throws: RuleCatalogError.duplicateID("t.dup")) { try RuleCatalog(rules: [rule, rule]) }
    }

    @Test func `injected directory loads and skips system allowlist`() throws {
        let fixture = try FixtureBuilder(name: "RuleCatalog")
        let directory = try fixture.folder("Rules")
        try Data("[\(Self.validRule)]".utf8).write(to: directory.appending(path: "test.json"))
        try Data(#"{"bundleIDPrefixes":["com.apple."]}"#.utf8).write(to: directory.appending(path: "system-allowlist.json"))
        try Data("ignored".utf8).write(to: directory.appending(path: "notes.txt"))
        let catalog = try RuleCatalog(directory: directory)
        #expect(catalog.rules.map(\.id) == ["t.one"])
        #expect(catalog.groups == ["Test"])
    }

    @Test func `broken file is reported by name`() throws {
        let fixture = try FixtureBuilder(name: "RuleCatalog")
        let directory = try fixture.folder("Rules")
        try Data("[{".utf8).write(to: directory.appending(path: "broken.json"))
        let error = #expect(throws: RuleCatalogError.self) { try RuleCatalog(directory: directory) }
        guard case let .invalidJSON(file, _) = error else {
            Issue.record("unexpected \(String(describing: error))")
            return
        }
        #expect(file == "broken.json")
    }
}
