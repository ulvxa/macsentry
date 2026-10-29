import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct RuleTrailingGlobTests {
    private typealias Kit = RuleTestKit

    private let xcode = RuleTestKit.app("com.apple.dt.Xcode", name: "Xcode", version: "26.0")

    @Test func `trailing star rules skip hidden names and plain files when they claim folders`() throws {
        let fixture = try FixtureBuilder(name: "RulesTrailingGlob")
        let dist = try fixture.folder(".gradle/wrapper/dists/gradle-8.5-bin")
        let tag = try fixture.file(".gradle/wrapper/dists/CACHEDIR.TAG", size: 43)
        let image = try fixture.folder("Library/Android/sdk/system-images/android-34")
        let imageStore = try fixture.file("Library/Android/sdk/system-images/.DS_Store", size: 6148)
        let archive = try fixture.folder("Library/Developer/Xcode/Archives/2026-01-01")
        let archiveStore = try fixture.file("Library/Developer/Xcode/Archives/.DS_Store", size: 6148)
        let hiddenArchive = try fixture.folder("Library/Developer/Xcode/Archives/.staging")
        let engine = try Kit.engine(home: fixture.root)

        #expect(engine.match(dist)?.rule.id == "android.gradleDists")
        #expect(engine.match(tag) == nil)
        #expect(engine.match(image)?.rule.id == "android.systemImages")
        #expect(engine.match(imageStore) == nil)
        #expect(engine.match(archive, inventory: [xcode])?.rule.id == "xcode.archives")
        #expect(engine.match(archiveStore, inventory: [xcode]) == nil)
        #expect(engine.match(hiddenArchive, inventory: [xcode]) == nil)
    }

    @Test func `a trailing star that names hidden entries still matches them`() throws {
        let fixture = try FixtureBuilder(name: "RulesTrailingHidden")
        let hidden = try fixture.folder("Tools/.cache-old")
        let visible = try fixture.folder("Tools/cache-old")
        let engine = try Kit.engine(home: fixture.root, rules: [Kit.rule("t.hidden", paths: ["~/Tools/.cache*"])])

        #expect(engine.match(hidden)?.rule.id == "t.hidden")
        #expect(engine.match(visible) == nil)
    }

    @Test func `logs user claims old log files and folders only`() throws {
        let fixture = try FixtureBuilder(name: "RulesLogs")
        let old = Kit.daysAgo(40)
        let base = "Library/Logs"
        let log = try fixture.file("\(base)/helper.log", size: 10, modified: old)
        let rotated = try fixture.file("\(base)/helper.log.gz", size: 10, modified: old)
        let report = try fixture.file("\(base)/Tool_2026-01-01.ips", size: 10, modified: old)
        let folder = try fixture.folder("\(base)/SomeApp", modified: old)
        let plist = try fixture.file("\(base)/com.apple.wifi.syncable-networks.legacy.plist", size: 10, modified: old)
        let config = try fixture.file("\(base)/NGLClient_Photoshop1.ngllogcontrolconfig", size: 10, modified: old)
        let hidden = try fixture.file("\(base)/.ngllogcontrolconfig", size: 10, modified: old)
        let archive = try fixture.file("\(base)/bundle.gz", size: 10, modified: old)
        let fresh = try fixture.file("\(base)/fresh.log", size: 10, modified: Kit.daysAgo(3))
        let engine = try Kit.engine(home: fixture.root)

        #expect(engine.match(log)?.rule.id == "logs.user")
        #expect(engine.match(rotated)?.rule.id == "logs.user")
        #expect(engine.match(report)?.rule.id == "logs.user")
        let folderMatch = try #require(engine.match(folder))
        #expect(folderMatch.rule.id == "logs.user")
        #expect(folderMatch.claimsFolder)
        for url in [plist, config, hidden, archive, fresh] {
            #expect(engine.match(url) == nil, "\(url.lastPathComponent)")
        }
    }
}
