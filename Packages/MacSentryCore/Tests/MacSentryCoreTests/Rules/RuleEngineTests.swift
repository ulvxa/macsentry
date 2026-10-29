import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct RuleEngineTests {
    private typealias Kit = RuleTestKit

    private let xcode = RuleTestKit.app("com.apple.dt.Xcode", name: "Xcode", version: "26.0")

    @Test func `derived data fixture yields green dev cache candidate claiming the folder`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let derivedData = try fixture.folder("Library/Developer/Xcode/DerivedData")
        try fixture.file("Library/Developer/Xcode/DerivedData/App-abc/Build/out.o", size: 4096)
        let engine = try Kit.engine(home: fixture.root)

        let match = try #require(engine.match(derivedData, inventory: [xcode]))
        #expect(match.rule.id == "xcode.derivedData")
        #expect(match.claimsFolder)
        let candidate = try #require(CandidateFactory.candidate(
            for: Kit.entry(derivedData),
            sizeInfo: Kit.size(4096),
            match: match,
            sessionID: 7,
        ))
        #expect(candidate.tier == .green)
        #expect(candidate.category == .devCache)
        #expect(candidate.action == .quarantine)
        #expect(candidate.kind == .folder)
        #expect(candidate.ruleID == "xcode.derivedData")
        #expect(candidate.cliCommand == nil)
        #expect(candidate.appBundleID == "com.apple.dt.Xcode")
        #expect(candidate.sessionID == 7)
        #expect(candidate.freeableSize == 4096)
        #expect(candidate.url == derivedData)
        #expect(try engine.match(fixture.url("Library/Developer/Xcode/DerivedData/App-abc"), inventory: [xcode]) == nil)
    }

    @Test func `docker raw fixture is flag only with docker command`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let raw = try fixture.sparseFile("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", logicalSize: 64 << 30)
        let engine = try Kit.engine(home: fixture.root)

        for owner: uid_t in [Kit.userUID, 0] {
            let match = try #require(engine.match(raw, ownerUID: owner))
            #expect(match.rule.id == "docker.vmDisk")
            let candidate = try #require(CandidateFactory.candidate(
                for: Kit.entry(raw, ownerUID: owner),
                sizeInfo: Kit.size(64 << 30),
                match: match,
                sessionID: 1,
            ))
            #expect(candidate.action == .flagOnly)
            #expect(candidate.action != .quarantine)
            #expect(candidate.category == .flagged)
            #expect(candidate.cliCommand?.contains("docker system prune -a") == true)
            #expect(candidate.cliCommand?.contains("docker builder prune -a") == true)
        }
    }

    @Test func `rule for missing app and missing path is skipped`() async throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let engine = try Kit.engine(home: fixture.root)
        let nothing = await TestAppInventory().installedApps()

        let inactive = Set(engine.activeRules(inventory: nothing, existingPaths: { _ in false }).map(\.id))
        #expect(!inactive.contains("xcode.derivedData"))
        #expect(!inactive.contains("docker.vmDisk"))
        #expect(!inactive.contains("vmware.vms"))
        #expect(inactive.contains("npm.cache"))
        #expect(!inactive.contains("appcache.generic"))

        let installed = await TestAppInventory(apps: [xcode]).installedApps()
        let withApp = Set(engine.activeRules(inventory: installed, existingPaths: { _ in false }).map(\.id))
        #expect(withApp.isSuperset(of: ["xcode.derivedData", "xcode.archives", "xcode.simDevices"]))
        #expect(!withApp.contains("docker.vmDisk"))

        let leftover = try fixture.folder("Library/Developer/Xcode/DerivedData")
        let withPath = engine.activeRules(inventory: nothing, existingPaths: { $0.pathComponents == leftover.pathComponents })
        #expect(Set(withPath.map(\.id)).contains("xcode.derivedData"))
        #expect(!Set(withPath.map(\.id)).contains("xcode.archives"))
        let skipped = engine.activeRules(inventory: nothing, existingPaths: { _ in false })
        #expect(engine.evaluate(Kit.entry(leftover), rules: skipped, thresholds: Thresholds()) == nil)
    }

    @Test func `globbed path activates rule when expansion exists`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let deviceSupport = try fixture.folder("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A)")
        let engine = try Kit.engine(home: fixture.root)
        let active = engine.activeRules(inventory: [], existingPaths: Kit.liveExists)
        #expect(active.map(\.id).contains("xcode.deviceSupport"))
        #expect(engine.evaluate(Kit.entry(deviceSupport), rules: active, thresholds: Thresholds())?.rule.id == "xcode.deviceSupport")
    }

    @Test func `disabled groups are skipped`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let engine = try Kit.engine(home: fixture.root)
        let active = engine.activeRules(inventory: [xcode], disabledGroups: ["Xcode", "Node"], existingPaths: { _ in true })
        #expect(!active.contains { $0.group == "Xcode" || $0.group == "Node" })
        #expect(active.contains { $0.group == "Python" })
    }

    @Test func `most specific path wins`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let specific = try fixture.folder("a/b")
        let other = try fixture.folder("a/c")
        let engine = try Kit.engine(home: fixture.root, rules: [
            Kit.rule("t.wide", paths: ["~/a/*"], tier: .red),
            Kit.rule("t.narrow", paths: ["~/a/b"], tier: .green),
        ])
        #expect(engine.match(specific)?.rule.id == "t.narrow")
        #expect(engine.match(other)?.rule.id == "t.wide")
    }

    @Test func `equal specificity goes to higher severity`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let folder = try fixture.folder("cache")
        for tiers in [[Tier.green, .red, .yellow], [.red, .yellow, .green], [.yellow, .green, .red]] {
            let rules = tiers.map { Kit.rule("t.\($0.rawValue)", paths: ["~/cache"], tier: $0) }
            #expect(try Kit.engine(home: fixture.root, rules: rules).match(folder)?.rule.tier == .red)
        }
        let pair = [Kit.rule("t.green", paths: ["~/cache"]), Kit.rule("t.yellow", paths: ["~/cache"], tier: .yellow)]
        #expect(try Kit.engine(home: fixture.root, rules: pair).match(folder)?.rule.id == "t.yellow")
    }

    @Test func `symlink never matches`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let target = try fixture.folder("Elsewhere/DerivedData")
        let link = try fixture.symlink("Library/Developer/Xcode/DerivedData", to: target)
        let engine = try Kit.engine(home: fixture.root)
        #expect(Kit.entry(link).kind == .symlink)
        #expect(engine.match(link, inventory: [xcode]) == nil)
        let file = try fixture.file("real.bin")
        let fileLink = try fixture.symlink("Downloads/Xcode_26.xip", to: file)
        #expect(engine.match(fileLink, inventory: [xcode]) == nil)
    }

    @Test func `glob star matches a single segment only`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let old = Kit.daysAgo(90)
        let direct = try fixture.file("Library/Logs/app.log", modified: old)
        let nested = try fixture.file("Library/Logs/App/sub/deep.log", modified: old)
        let engine = try Kit.engine(home: fixture.root)
        #expect(engine.match(direct)?.rule.id == "logs.user")
        #expect(engine.match(nested) == nil)
        #expect(engine.match(nested.deletingLastPathComponent()) == nil)
    }

    @Test func `logs only match after thirty days`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let fresh = try fixture.file("Library/Logs/fresh.log", modified: Kit.daysAgo(10))
        let stale = try fixture.folder("Library/Logs/SomeApp", modified: Kit.daysAgo(31))
        let engine = try Kit.engine(home: fixture.root)
        #expect(engine.match(fresh) == nil)
        let match = try #require(engine.match(stale))
        #expect(match.rule.id == "logs.user")
        #expect(match.claimsFolder)
        let crash = try fixture.folder("Library/Logs/DiagnosticReports")
        #expect(engine.match(crash)?.rule.id == "crashReports")
    }

    @Test func `claim is withheld from ancestors of more specific rules`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let studio = AppFixture.androidStudio("2024.1")
        let google = try fixture.folder("Library/Logs/Google", modified: Kit.daysAgo(90))
        let studioLogs = try fixture.folder("Library/Logs/Google/AndroidStudio2024.1")
        let engine = try Kit.engine(home: fixture.root)
        #expect(engine.match(google, inventory: [studio]) == nil)
        #expect(engine.match(studioLogs, inventory: [studio])?.rule.id == "android.studioLogs")
    }
}

struct RuleEngineVersionAndAppTests {
    private typealias Kit = RuleTestKit

    @Test func `old android studio config is only marked below the installed version`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let base = "Library/Application Support/Google"
        let old = try fixture.folder("\(base)/AndroidStudio2023.3")
        let current = try fixture.folder("\(base)/AndroidStudio2024.1")
        let preview = try fixture.folder("\(base)/AndroidStudioPreview2024.2")
        let engine = try Kit.engine(home: fixture.root)
        let studio = AppFixture.androidStudio("2024.1.2")

        #expect(engine.match(old, inventory: [studio])?.rule.id == "android.oldStudioConfig")
        #expect(engine.match(current, inventory: [studio]) == nil)
        #expect(engine.match(preview, inventory: [studio]) == nil)
        #expect(engine.match(old, inventory: []) == nil)
    }

    @Test func `blender keeps the installed version folder`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let base = "Library/Application Support/Blender"
        let blender = Kit.app("org.blenderfoundation.blender", name: "Blender", version: "4.1.1")
        let engine = try Kit.engine(home: fixture.root)
        #expect(try engine.match(fixture.folder("\(base)/3.6"), inventory: [blender])?.rule.id == "blender.oldConfig")
        #expect(try engine.match(fixture.folder("\(base)/4.1"), inventory: [blender]) == nil)
        #expect(try engine.match(fixture.folder("\(base)/4.2"), inventory: [blender]) == nil)
        #expect(try engine.match(fixture.folder("\(base)/config"), inventory: [blender]) == nil)
    }

    @Test func `vscode keeps the newest extension version`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let base = ".vscode/extensions"
        let older = try fixture.folder("\(base)/ms-python.python-2024.1.0")
        let newest = try fixture.folder("\(base)/ms-python.python-2024.10.1")
        let platformOld = try fixture.folder("\(base)/ms-vscode.cpptools-1.2.3-darwin-arm64")
        try fixture.folder("\(base)/ms-vscode.cpptools-1.20.0-darwin-arm64")
        let single = try fixture.folder("\(base)/esbenp.prettier-vscode-10.4.0")
        let engine = try Kit.engine(home: fixture.root)
        #expect(engine.match(older)?.rule.id == "vscode.oldExt")
        #expect(engine.match(platformOld)?.rule.id == "vscode.oldExt")
        #expect(engine.match(newest) == nil)
        #expect(engine.match(single) == nil)
    }

    @Test func `root owned quarantine entry becomes flag only without command`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let cache = try fixture.folder("Library/Caches/Homebrew")
        let engine = try Kit.engine(home: fixture.root)
        let match = try #require(engine.match(cache, ownerUID: 0))
        #expect(match.isRootOwned)
        let candidate = try #require(CandidateFactory.candidate(
            for: Kit.entry(cache, ownerUID: 0),
            sizeInfo: Kit.size(1),
            match: match,
            sessionID: 1,
        ))
        #expect(candidate.action == .flagOnly)
        #expect(candidate.category == .flagged)
        #expect(candidate.reason == "Owned by root, remove manually if you are sure")
        #expect(candidate.cliCommand == nil)
        #expect(candidate.ruleID == "homebrew.cache")

        let rootEngine = try Kit.engine(home: fixture.root, uid: 0)
        #expect(rootEngine.match(cache, ownerUID: 0)?.isRootOwned == false)
    }

    @Test func `cli command substitutes shell quoted placeholders`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let avd = try fixture.folder(".android/avd/Pixel 8 API 35.avd")
        let engine = try Kit.engine(home: fixture.root)
        let match = try #require(engine.match(avd))
        #expect(match.rule.id == "android.avd")
        #expect(match.cliCommand(for: avd) == "avdmanager delete avd -n 'Pixel 8 API 35'")

        let quoted = try fixture.folder("it's here")
        let custom = Kit.rule("t.cli", paths: ["~/*"], action: .flagOnly, cliCommand: "du -sh {path}")
        let customMatch = try #require(Kit.engine(home: fixture.root, rules: [custom]).match(quoted))
        let root = fixture.root.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        #expect(customMatch.cliCommand(for: quoted) == "du -sh '/\(root)/it'\\''s here'")
    }

    @Test func `app caches are materialized per installed app`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let discord = Kit.app("com.hnc.Discord", name: "Discord")
        let safari = Kit.app("com.apple.Safari", name: "Safari")
        let support = "Library/Application Support"
        let gpu = try fixture.folder("\(support)/discord/GPUCache")
        let worker = try fixture.folder("\(support)/Discord/Service Worker/CacheStorage")
        let settings = try fixture.folder("\(support)/Discord/Local Storage")
        let library = try fixture.folder("Library/Caches/com.hnc.Discord")
        let safariCache = try fixture.folder("Library/Caches/com.apple.Safari")
        let safariSupport = try fixture.folder("\(support)/Safari/Cache")
        let engine = try Kit.engine(home: fixture.root)
        let inventory = [discord, safari]

        let gpuMatch = try #require(engine.match(gpu, inventory: inventory))
        #expect(gpuMatch.rule.id == "appcache.generic")
        #expect(gpuMatch.rule.group == "Discord")
        #expect(gpuMatch.rule.appBundleIDs == ["com.hnc.Discord"])
        #expect(gpuMatch.rule.requiresAppQuit)
        #expect(engine.match(worker, inventory: inventory)?.rule.id == "appcache.generic")
        #expect(engine.match(worker.deletingLastPathComponent(), inventory: inventory) == nil)
        #expect(engine.match(settings, inventory: inventory) == nil)
        #expect(engine.match(library, inventory: inventory)?.rule.id == "appcache.library")
        #expect(engine.match(safariCache, inventory: inventory) == nil)
        #expect(engine.match(safariSupport, inventory: inventory)?.rule.id == "appcache.generic")
        let unattributed = try #require(engine.match(gpu, inventory: []))
        #expect(unattributed.rule.id == "appcache.chromium")
        #expect(unattributed.rule.group == AppScope.otherGroup)
        #expect(unattributed.unattributedFolder?.lastPathComponent == "discord")
        #expect(gpuMatch.unattributedFolder == nil)
    }

    @Test func `specific catalog rule beats the generic app cache on the same path`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let spotify = Kit.app("com.spotify.client", name: "Spotify")
        let cache = try fixture.folder("Library/Caches/com.spotify.client")
        let engine = try Kit.engine(home: fixture.root)
        #expect(engine.match(cache, inventory: [spotify])?.rule.id == "spotify.cache")
    }

    @Test func `zoom recordings follow the user thresholds`() throws {
        let fixture = try FixtureBuilder(name: "Rules")
        let old = try fixture.folder("Documents/Zoom/2024-01-01 Standup", modified: Kit.daysAgo(400))
        let recent = try fixture.folder("Documents/Zoom/2026-01-01 Standup", modified: Kit.daysAgo(5))
        let engine = try Kit.engine(home: fixture.root)
        let thresholds = Thresholds(minAgeDays: 180, minSize: 500_000_000)

        #expect(engine.match(recent, thresholds: thresholds) == nil)
        let match = try #require(engine.match(old, thresholds: thresholds))
        #expect(match.minFreeableSize == 500_000_000)
        let entry = Kit.entry(old)
        #expect(CandidateFactory.candidate(for: entry, sizeInfo: Kit.size(100_000_000), match: match, sessionID: 1) == nil)
        let candidate = try #require(CandidateFactory.candidate(for: entry, sizeInfo: Kit.size(900_000_000), match: match, sessionID: 1))
        #expect(candidate.category == .oldLarge)
        #expect(candidate.tier == .red)
    }

    @Test func `rule engine double returns configured matches`() {
        let url = URL(filePath: "/tmp/fixture/x")
        let rule = Kit.rule("t.double", paths: ["~/x"])
        let double = TestRuleEngine(rules: [rule], matches: [url: RuleMatch(rule: rule, claimsFolder: true)])
        let entry = FileEntry(
            url: url, kind: .folder, logicalSize: 0, allocatedSize: 0, privateSize: nil, linkCount: 1,
            inode: 1, device: 1, flags: 0, created: nil, modified: nil, ownerUID: 501,
        )
        #expect(double.activeRules(inventory: [], existingPaths: { _ in false }) == [rule])
        #expect(double.activeRules(inventory: [], disabledGroups: ["Test"], existingPaths: { _ in false }).isEmpty)
        #expect(double.evaluate(entry, rules: [rule], thresholds: Thresholds())?.rule == rule)
    }
}

private enum AppFixture {
    static func androidStudio(_ version: String) -> InstalledApp {
        RuleTestKit.app("com.google.android.studio", name: "Android Studio", version: version)
    }
}
