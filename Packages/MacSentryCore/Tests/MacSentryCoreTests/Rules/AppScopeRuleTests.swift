import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

enum AppCacheFixture {
    struct Expected {
        let path: String
        let ruleID: String
        let group: String
        let bundleID: String?
    }

    static let support = "Library/Application Support"

    static func app(_ id: String, _ name: String, executable: String? = nil) -> InstalledApp {
        InstalledApp(bundleID: id, name: name, version: "1.0", url: URL(filePath: "/Applications/\(name).app"), executable: executable)
    }

    static let inventory = [
        app("notion.id", "Notion"),
        app("com.electron.realtimeboard", "Miro"),
        app("com.figma.Desktop", "Figma"),
        app("com.google.Chrome", "Google Chrome"),
        app("com.brave.Browser", "Brave Browser"),
        app("com.microsoft.edgemac", "Microsoft Edge"),
        app("company.thebrowser.Browser", "Arc"),
        app("com.microsoft.VSCode", "Visual Studio Code", executable: "Code"),
        app("com.unity3d.unityhub", "Unity Hub"),
        app("com.anthropic.claudefordesktop", "Claude"),
        app("com.example.sandboxed", "Sandboxed"),
        app("com.spotify.client", "Spotify"),
        app("com.apple.Safari", "Safari"),
    ]

    static let realMachine: [Expected] = {
        let notion = "\(support)/Notion/Partitions/notion"
        let figma = "\(support)/Figma/DesktopProfile/v43"
        let chrome = "\(support)/Google/Chrome"
        let worker = "Service Worker/CacheStorage"
        return [
            Expected(path: "\(notion)/\(worker)", ruleID: "appcache.chromium", group: "Notion", bundleID: "notion.id"),
            Expected(path: "\(notion)/Cache", ruleID: "appcache.chromiumHTTP", group: "Notion", bundleID: "notion.id"),
            Expected(path: "\(notion)/Code Cache", ruleID: "appcache.chromium", group: "Notion", bundleID: "notion.id"),
            Expected(
                path: "\(support)/RealtimeBoard/Cache",
                ruleID: "appcache.chromiumHTTP",
                group: "Miro",
                bundleID: "com.electron.realtimeboard",
            ),
            Expected(
                path: "\(support)/RealtimeBoard/Code Cache",
                ruleID: "appcache.chromium",
                group: "Miro",
                bundleID: "com.electron.realtimeboard",
            ),
            Expected(path: "\(figma)/Code Cache", ruleID: "appcache.chromium", group: "Figma", bundleID: "com.figma.Desktop"),
            Expected(path: "\(figma)/Cache", ruleID: "appcache.chromiumHTTP", group: "Figma", bundleID: "com.figma.Desktop"),
            Expected(path: "\(figma)/DawnWebGPUCache", ruleID: "appcache.chromium", group: "Figma", bundleID: "com.figma.Desktop"),
            Expected(
                path: "\(support)/Figma/DesktopProfile/v44/DawnWebGPUCache",
                ruleID: "appcache.chromium",
                group: "Figma",
                bundleID: "com.figma.Desktop",
            ),
            Expected(
                path: "\(chrome)/Default/\(worker)",
                ruleID: "appcache.chromium",
                group: "Google Chrome",
                bundleID: "com.google.Chrome",
            ),
            Expected(
                path: "\(chrome)/Default/Service Worker/ScriptCache",
                ruleID: "appcache.chromium",
                group: "Google Chrome",
                bundleID: "com.google.Chrome",
            ),
            Expected(
                path: "\(chrome)/Profile 1/\(worker)",
                ruleID: "appcache.chromium",
                group: "Google Chrome",
                bundleID: "com.google.Chrome",
            ),
            Expected(
                path: "\(support)/BraveSoftware/Brave-Browser/Default/\(worker)",
                ruleID: "appcache.chromium",
                group: "Brave Browser",
                bundleID: "com.brave.Browser",
            ),
            Expected(
                path: "\(support)/Microsoft Edge/Default/\(worker)",
                ruleID: "appcache.chromium",
                group: "Microsoft Edge",
                bundleID: "com.microsoft.edgemac",
            ),
            Expected(
                path: "\(support)/Arc/User Data/Default/\(worker)",
                ruleID: "appcache.chromium",
                group: "Arc",
                bundleID: "company.thebrowser.Browser",
            ),
            Expected(
                path: "\(support)/Code/\(worker)",
                ruleID: "appcache.chromium",
                group: "Visual Studio Code",
                bundleID: "com.microsoft.VSCode",
            ),
            Expected(
                path: "\(support)/Code/CachedData",
                ruleID: "appcache.chromium",
                group: "Visual Studio Code",
                bundleID: "com.microsoft.VSCode",
            ),
            Expected(
                path: "Library/Caches/com.microsoft.VSCode.ShipIt",
                ruleID: "appcache.libraryFallback",
                group: "Visual Studio Code",
                bundleID: "com.microsoft.VSCode",
            ),
            Expected(
                path: "\(support)/Caches/unityhub-updater",
                ruleID: "appcache.updater",
                group: "Unity Hub",
                bundleID: "com.unity3d.unityhub",
            ),
            Expected(path: "\(support)/Caches/notion-updater", ruleID: "appcache.updater", group: "Notion", bundleID: "notion.id"),
            Expected(path: "\(support)/Caches/cursor-updater", ruleID: "appcache.updater", group: AppScope.otherGroup, bundleID: nil),
            Expected(
                path: "\(support)/Claude/DawnGraphiteCache",
                ruleID: "appcache.chromium",
                group: "Claude",
                bundleID: "com.anthropic.claudefordesktop",
            ),
            Expected(
                path: "\(support)/Claude/GraphiteDawnCache",
                ruleID: "appcache.chromium",
                group: "Claude",
                bundleID: "com.anthropic.claudefordesktop",
            ),
            Expected(
                path: "\(support)/Claude/ShaderCache",
                ruleID: "appcache.chromium",
                group: "Claude",
                bundleID: "com.anthropic.claudefordesktop",
            ),
            Expected(
                path: "\(support)/Claude/GrShaderCache",
                ruleID: "appcache.chromium",
                group: "Claude",
                bundleID: "com.anthropic.claudefordesktop",
            ),
            Expected(
                path: "Library/Containers/com.example.sandboxed/Data/Library/Caches",
                ruleID: "appcache.container",
                group: "Sandboxed",
                bundleID: "com.example.sandboxed",
            ),
            Expected(
                path: "Library/Containers/com.unknown.tool/Data/Library/Caches",
                ruleID: "appcache.container",
                group: AppScope.otherGroup,
                bundleID: "com.unknown.tool",
            ),
            Expected(path: "Library/Caches/ms-playwright", ruleID: "appcache.libraryFallback", group: AppScope.otherGroup, bundleID: nil),
        ]
    }()

    static let neverMatched = [
        "Notion/Partitions/notion/Local Storage", "Notion/Partitions/notion/IndexedDB", "Notion/Partitions/notion/WebStorage",
        "Notion/Partitions/notion/Session Storage", "Notion/Partitions/notion/File System", "Notion/Partitions/notion/databases",
        "Notion/Partitions/notion/Service Worker", "Notion/Partitions/notion/Service Worker/Database",
        "Notion/Partitions/notion", "Notion/Partitions", "Code/User", "Code/User/globalStorage",
        "Google/Chrome/Default", "Google/Chrome/Default/IndexedDB", "Google/Chrome/Default/Local Storage",
        "Figma/DesktopProfile/v42/Cache", "Figma/DesktopProfile", "RealtimeBoard",
        "Google/Chrome/Default/Extensions/abc/Service Worker/CacheStorage",
        "com.apple.foo/GPUCache",
    ].map { "\(support)/\($0)" } + [
        "Library/Caches/com.apple.Safari", "Library/Caches/CloudKit", "Library/Caches/GeoServices", "Library/Caches/GameKit",
        "Library/Caches/icloudmailagent", "Library/Caches/FamilyCircle", "Library/Caches/PassKit", "Library/Caches/Metal",
        "Library/Caches/TemporaryItems", "Library/Caches/Google", "Library/Containers/com.apple.Notes/Data/Library/Caches",
        "Library/Containers/com.example.sandboxed/Data/Library", "Library/Containers/com.example.sandboxed",
        "\(support)/Caches/notion-updater/pending", "\(support)/Caches/other-folder",
    ]

    static func buildRealMachine(_ fixture: FixtureBuilder) throws {
        for expected in realMachine {
            try fixture.file("\(expected.path)/blob", size: 4096)
        }
        for path in neverMatched {
            try fixture.folder(path)
        }
        for cache in ["Notion/Partitions/notion/Cache", "RealtimeBoard/Cache", "Figma/DesktopProfile/v43/Cache"] {
            try fixture.folder("\(support)/\(cache)/Cache_Data")
        }
        try fixture.file("\(support)/Notion/Partitions/notion/Cookies", size: 1024)
        try fixture.file("\(support)/Notion/Partitions/notion/Local Storage/leveldb/000003.log", size: 1024)
        try fixture.folder("Library/Caches/Google/Chrome")
    }
}

struct AppScopeRuleTests {
    private typealias Kit = RuleTestKit
    private typealias Fixture = AppCacheFixture

    private func engine(_ home: URL) throws -> DefaultRuleEngine {
        try DefaultRuleEngine(catalog: .bundled(), homeURL: home, currentUID: Kit.userUID, now: { Kit.now })
    }

    private func evaluate(_ engine: DefaultRuleEngine, _ url: URL, rules: CompiledRuleSet) -> RuleMatch? {
        engine.evaluate(Kit.entry(url), rules: rules, thresholds: Thresholds())
    }

    @Test func `every real machine cache path is found with its app`() throws {
        let fixture = try FixtureBuilder(name: "AppScope")
        try Fixture.buildRealMachine(fixture)
        let engine = try engine(fixture.root)
        let rules = engine.compile(engine.activeRules(inventory: Fixture.inventory, existingPaths: Kit.liveExists))

        for expected in Fixture.realMachine {
            let match = try evaluate(engine, fixture.url(expected.path), rules: rules)
            #expect(match?.rule.id == expected.ruleID, "\(expected.path)")
            #expect(match?.rule.group == expected.group, "\(expected.path)")
            #expect(match?.rule.appBundleIDs.first == expected.bundleID, "\(expected.path)")
            #expect(match?.claimsFolder == true, "\(expected.path)")
            #expect(match?.rule.tier == .green, "\(expected.path)")
            #expect(match?.action == .quarantine, "\(expected.path)")
            #expect(match?.category == .appCache, "\(expected.path)")
            #expect(match?.rule.requiresAppQuit == true, "\(expected.path)")
            #expect((match?.unattributedFolder == nil) == (expected.group != AppScope.otherGroup), "\(expected.path)")
        }
    }

    @Test func `user data, intermediate folders and system folders are never matched`() throws {
        let fixture = try FixtureBuilder(name: "AppScope")
        try Fixture.buildRealMachine(fixture)
        let engine = try engine(fixture.root)
        let rules = engine.compile(engine.activeRules(inventory: Fixture.inventory, existingPaths: Kit.liveExists))

        for path in Fixture.neverMatched + ["\(Fixture.support)/Notion/Partitions/notion/Cookies"] {
            #expect(try evaluate(engine, fixture.url(path), rules: rules) == nil, "\(path)")
        }
        let leveldb = try fixture.url("\(Fixture.support)/Notion/Partitions/notion/Local Storage/leveldb")
        #expect(evaluate(engine, leveldb, rules: rules) == nil)
    }

    @Test func `specific catalog rules beat the app scope rules on the same folder`() throws {
        let fixture = try FixtureBuilder(name: "AppScope")
        let expectations = [
            ("Library/Caches/Homebrew", "homebrew.cache"),
            ("Library/Caches/pip", "pip.cache"),
            ("Library/Caches/Yarn", "yarn.cache"),
            ("Library/Caches/CocoaPods", "cocoapods.cache"),
            ("Library/Caches/org.swift.swiftpm", "spm.cache"),
            ("Library/Caches/com.apple.dt.Xcode", "xcode.cache"),
            ("Library/Caches/com.spotify.client", "spotify.cache"),
            ("Library/Caches/notion.id", "appcache.library"),
            ("Library/Caches/Google/Chrome", "chrome.cache"),
            ("\(Fixture.support)/Claude/Cache", "appcache.generic"),
            ("\(Fixture.support)/Notion/GPUCache", "appcache.generic"),
        ]
        for (path, _) in expectations {
            try fixture.folder(path)
        }
        try fixture.folder("\(Fixture.support)/Claude/Cache/Cache_Data")
        let engine = try engine(fixture.root)
        let xcode = Fixture.app("com.apple.dt.Xcode", "Xcode")
        let rules = engine.compile(engine.activeRules(inventory: Fixture.inventory + [xcode], existingPaths: Kit.liveExists))

        for (path, ruleID) in expectations {
            #expect(try evaluate(engine, fixture.url(path), rules: rules)?.rule.id == ruleID, "\(path)")
        }
        #expect(try evaluate(engine, fixture.url("Library/Caches/Google"), rules: rules) == nil)
    }

    @Test func `shared vendor folders in Caches are caches, only Apple's own folders are skipped`() throws {
        let fixture = try FixtureBuilder(name: "AppScope")
        for name in ["JetBrains", "Code", "Python", "Microsoft", "com.crashlytics", "CloudKit", "GameKit", "Google/Chrome"] {
            try fixture.folder("Library/Caches/\(name)")
        }
        let engine = try engine(fixture.root)
        let rules = engine.compile(engine.activeRules(inventory: Fixture.inventory, existingPaths: Kit.liveExists))

        for name in ["JetBrains", "Code", "Python", "Microsoft", "com.crashlytics"] {
            let match = try evaluate(engine, fixture.url("Library/Caches/\(name)"), rules: rules)
            #expect(match?.rule.id == "appcache.libraryFallback", "\(name)")
        }
        #expect(try evaluate(engine, fixture.url("Library/Caches/Code"), rules: rules)?.rule.group == "Visual Studio Code")
        for name in ["CloudKit", "GameKit", "Google"] {
            #expect(try evaluate(engine, fixture.url("Library/Caches/\(name)"), rules: rules) == nil, "\(name)")
        }
        #expect(try evaluate(engine, fixture.url("Library/Caches/Google/Chrome"), rules: rules)?.rule.id == "chrome.cache")
    }

    @Test func `turned off groups and an empty inventory are respected`() throws {
        let fixture = try FixtureBuilder(name: "AppScope")
        let worker = try fixture.folder("\(Fixture.support)/Notion/Partitions/notion/Service Worker/CacheStorage")
        let engine = try engine(fixture.root)

        let off = engine.compile(engine.activeRules(
            inventory: Fixture.inventory,
            disabledGroups: ["App Caches"],
            existingPaths: Kit.liveExists,
        ))
        #expect(evaluate(engine, worker, rules: off) == nil)
        let notionOff = engine.compile(engine.activeRules(
            inventory: Fixture.inventory,
            disabledGroups: ["Notion"],
            existingPaths: Kit.liveExists,
        ))
        #expect(evaluate(engine, worker, rules: notionOff) == nil)
        let nobody = engine.compile(engine.activeRules(inventory: [], existingPaths: Kit.liveExists))
        let match = try #require(evaluate(engine, worker, rules: nobody))
        #expect(match.rule.group == AppScope.otherGroup)
        #expect(match.rule.appBundleIDs.isEmpty)
        #expect(match.unattributedFolder?.standardizedFileURL.pathComponents == fixture.root.appending(path: "\(Fixture.support)/Notion")
            .pathComponents)
    }
}
