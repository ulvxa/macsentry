import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct RuleCatalogGapTests {
    private typealias Kit = RuleTestKit

    struct Case: Sendable, CustomTestStringConvertible {
        let id: String
        let hit: String
        let miss: String
        let tier: Tier
        let group: String
        let action: CandidateAction

        var testDescription: String {
            id
        }
    }

    private static let cases: [Case] = [
        Case(id: "npm.npx", hit: ".npm/_npx", miss: ".npm/_logs", tier: .green, group: "Node", action: .quarantine),
        Case(id: "puppeteer.browsers", hit: ".cache/puppeteer", miss: ".cache/gh", tier: .yellow, group: "Node", action: .quarantine),
        Case(
            id: "mongodb.binaries",
            hit: ".cache/mongodb-binaries",
            miss: ".cache/mongodb-data",
            tier: .yellow,
            group: "Node",
            action: .quarantine,
        ),
        Case(
            id: "huggingface.hub",
            hit: ".cache/huggingface/hub",
            miss: ".cache/huggingface/token-store",
            tier: .yellow,
            group: "Python",
            action: .quarantine,
        ),
        Case(id: "torch.hub", hit: ".cache/torch", miss: ".cache/torchvision-notes", tier: .yellow, group: "Python", action: .quarantine),
        Case(id: "gradle.jdks", hit: ".gradle/jdks", miss: ".gradle/init.d", tier: .yellow, group: "Gradle", action: .quarantine),
        Case(id: "expo.caches", hit: ".expo/expo-go", miss: ".expo/codesigning", tier: .yellow, group: "Expo", action: .quarantine),
        Case(
            id: "expo.caches",
            hit: ".expo/android-apk-cache",
            miss: ".expo/schema-cache",
            tier: .yellow,
            group: "Expo",
            action: .quarantine,
        ),
        Case(
            id: "expo.caches",
            hit: ".expo/ios-simulator-app-cache",
            miss: ".expo/state-backup",
            tier: .yellow,
            group: "Expo",
            action: .quarantine,
        ),
        Case(
            id: "platformio.packages",
            hit: ".platformio/packages/toolchain-xtensa-esp-elf",
            miss: ".platformio/penv",
            tier: .yellow,
            group: "PlatformIO",
            action: .quarantine,
        ),
        Case(
            id: "burp.updates",
            hit: ".BurpSuite/updates/31bee42e",
            miss: ".BurpSuite/ConfigLibrary",
            tier: .yellow,
            group: "Burp Suite",
            action: .quarantine,
        ),
        Case(
            id: "xcode.documentationCache",
            hit: "Library/Developer/Xcode/DocumentationCache",
            miss: "Library/Developer/Xcode/UserData",
            tier: .green,
            group: "Xcode",
            action: .quarantine,
        ),
        Case(
            id: "android.ndk",
            hit: "Library/Android/sdk/ndk/27.0.12077973",
            miss: "Library/Android/sdk/platform-tools",
            tier: .yellow,
            group: "Android Studio",
            action: .flagOnly,
        ),
        Case(
            id: "android.buildTools",
            hit: "Library/Android/sdk/build-tools/34.0.0",
            miss: "Library/Android/sdk/licenses",
            tier: .yellow,
            group: "Android Studio",
            action: .flagOnly,
        ),
    ]

    @Test(arguments: cases)
    func `gap rule claims its folder and leaves the neighbour alone`(_ testCase: Case) throws {
        let fixture = try FixtureBuilder(name: "RulesGap")
        let hit = try fixture.folder(testCase.hit)
        _ = try fixture.file("\(testCase.hit)/payload.bin", size: 16)
        let miss = try fixture.folder(testCase.miss)
        let engine = try Kit.engine(home: fixture.root)

        let match = try #require(engine.match(hit))
        #expect(match.rule.id == testCase.id)
        #expect(match.rule.tier == testCase.tier)
        #expect(match.rule.group == testCase.group)
        #expect(match.rule.action == testCase.action)
        #expect(match.claimsFolder)
        #expect(engine.match(miss) == nil)
    }

    @Test func `platformio packages skip bookkeeping files`() throws {
        let fixture = try FixtureBuilder(name: "RulesGapPio")
        let store = try fixture.file(".platformio/packages/.DS_Store", size: 6148)
        let engine = try Kit.engine(home: fixture.root)

        #expect(engine.match(store) == nil)
    }

    @Test(arguments: ["dmg", "pkg", "ipsw", "iso"])
    func `old installers in downloads are yellow review items`(ext: String) throws {
        let fixture = try FixtureBuilder(name: "RulesInstallers")
        let old = try fixture.file("Downloads/Tool-1.0.\(ext)", size: 32, modified: Kit.daysAgo(40))
        let fresh = try fixture.file("Downloads/New-2.0.\(ext)", size: 32, modified: Kit.daysAgo(2))
        let nested = try fixture.file("Documents/Tool-1.0.\(ext)", size: 32, modified: Kit.daysAgo(40))
        let notes = try fixture.file("Downloads/Tool-1.0.\(ext).txt", size: 32, modified: Kit.daysAgo(40))
        let folder = try fixture.folder("Downloads/Projects", modified: Kit.daysAgo(40))
        let engine = try Kit.engine(home: fixture.root)

        let match = try #require(engine.match(old))
        #expect(match.rule.id == "installers.\(ext)")
        #expect(match.rule.tier == .yellow)
        #expect(match.rule.group == "Installers")
        #expect(match.rule.action == .quarantine)
        #expect(!match.claimsFolder)
        for url in [fresh, nested, notes, folder] {
            #expect(engine.match(url)?.rule.id.hasPrefix("installers.") != true, "\(url.lastPathComponent)")
        }
    }
}
