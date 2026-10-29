import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct OldLargeRuleTests {
    private typealias Kit = RuleTestKit
    private static let gigabyte: Int64 = 1 << 30

    private func rule(home: URL, gitRoots: [URL] = []) -> OldLargeRule {
        let roots = gitRoots.map { $0.standardizedFileURL.path(percentEncoded: false) }
        return OldLargeRule(homeURL: home, currentUID: Kit.userUID, now: { Kit.now }, isInsideGitWorkTree: { url in
            roots.contains { url.standardizedFileURL.path(percentEncoded: false).hasPrefix($0) }
        })
    }

    private func evaluate(_ rule: OldLargeRule, _ url: URL, thresholds: Thresholds, lastUsed: Date? = nil) -> RuleMatch? {
        let entry = Kit.entry(url)
        return rule.evaluate(entry, sizeInfo: Kit.size(entry.logicalSize), lastUsed: lastUsed, thresholds: thresholds)
    }

    @Test func `raising min size from 500 MB to 5 GB drops smaller candidates`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        let old = Kit.daysAgo(400)
        let files = try [1, 3, 6].map { size in
            try fixture.sparseFile("Documents/Footage/clip-\(size).mov", logicalSize: Int64(size) * Self.gigabyte, modified: old)
        }
        let small = try fixture.sparseFile("Documents/small.bin", logicalSize: 100_000_000, modified: old)
        let oldLarge = rule(home: fixture.root)

        func candidates(minSize: Int64) -> [URL] {
            let thresholds = Thresholds(minAgeDays: 180, minSize: minSize, ageBasis: .modified)
            return (files + [small]).compactMap { url in
                let entry = Kit.entry(url)
                let size = Kit.size(entry.logicalSize)
                return oldLarge.evaluate(entry, sizeInfo: size, thresholds: thresholds)
                    .flatMap { CandidateFactory.candidate(for: entry, sizeInfo: size, match: $0, sessionID: 1) }?.url
            }
        }

        #expect(candidates(minSize: 500_000_000) == files)
        #expect(candidates(minSize: 5_000_000_000) == [files[2]])
    }

    @Test func `installers in downloads are yellow and everything else is red`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        let old = Kit.daysAgo(365)
        let dmg = try fixture.sparseFile("Downloads/Tool.DMG", logicalSize: Self.gigabyte, modified: old)
        let movie = try fixture.sparseFile("Downloads/movie.mov", logicalSize: Self.gigabyte, modified: old)
        let zip = try fixture.sparseFile("Documents/archive.zip", logicalSize: Self.gigabyte, modified: old)
        let oldLarge = rule(home: fixture.root)
        let thresholds = Thresholds(minAgeDays: 180, minSize: 500_000_000)

        let installer = try #require(evaluate(oldLarge, dmg, thresholds: thresholds))
        #expect(installer.rule.tier == .yellow)
        #expect(installer.rule.category == .oldLarge)
        #expect(evaluate(oldLarge, movie, thresholds: thresholds)?.rule.tier == .red)
        #expect(evaluate(oldLarge, zip, thresholds: thresholds)?.rule.tier == .red)
    }

    @Test func `protected stores and git work trees are excluded`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        let old = Kit.daysAgo(365)
        let size = Self.gigabyte
        let library = try fixture.folder("Pictures/Photos Library.photoslibrary", modified: old)
        let insideLibrary = try fixture.sparseFile(
            "Pictures/Photos Library.photoslibrary/originals/a.heic",
            logicalSize: size,
            modified: old,
        )
        let music = try fixture.sparseFile("Music/Music/Media/song.m4a", logicalSize: size, modified: old)
        let messages = try fixture.sparseFile("Library/Messages/chat.db", logicalSize: size, modified: old)
        let mail = try fixture.sparseFile("Library/Mail/V10/box.mbox", logicalSize: size, modified: old)
        let repoFile = try fixture.sparseFile("Code/app/assets/big.bin", logicalSize: size, modified: old)
        let loose = try fixture.sparseFile("Code/big.bin", logicalSize: size, modified: old)
        let oldLarge = try rule(home: fixture.root, gitRoots: [fixture.url("Code/app")])
        let thresholds = Thresholds(minAgeDays: 180, minSize: 500_000_000)

        let libraryEntry = Kit.entry(library)
        #expect(libraryEntry.kind == .package)
        #expect(oldLarge.evaluate(libraryEntry, sizeInfo: Kit.size(size), thresholds: thresholds) == nil)
        for url in [insideLibrary, music, messages, mail, repoFile] {
            #expect(evaluate(oldLarge, url, thresholds: thresholds) == nil, "\(url.lastPathComponent)")
        }
        #expect(evaluate(oldLarge, loose, thresholds: thresholds) != nil)
    }

    @Test func `age follows the selected basis`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        // APFS pulls the birth time back when mtime is set earlier, so the created date is the older one here.
        let url = try fixture.sparseFile(
            "Documents/video.mov",
            logicalSize: Self.gigabyte,
            created: Kit.daysAgo(300),
            modified: Kit.daysAgo(10),
        )
        let oldLarge = rule(home: fixture.root)
        func thresholds(_ basis: AgeBasis) -> Thresholds {
            Thresholds(minAgeDays: 180, minSize: 500_000_000, ageBasis: basis)
        }
        #expect(evaluate(oldLarge, url, thresholds: thresholds(.created)) != nil)
        #expect(evaluate(oldLarge, url, thresholds: thresholds(.modified)) == nil)
        #expect(evaluate(oldLarge, url, thresholds: thresholds(.lastUsed), lastUsed: Kit.daysAgo(200)) != nil)
        #expect(evaluate(oldLarge, url, thresholds: thresholds(.lastUsed), lastUsed: Kit.daysAgo(3)) == nil)
        #expect(evaluate(oldLarge, url, thresholds: thresholds(.lastUsed)) == nil)
    }

    @Test func `folders and paths outside home are ignored`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        let home = try fixture.folder("home")
        let folder = try fixture.folder("home/Documents/Project", modified: Kit.daysAgo(400))
        let outside = try fixture.sparseFile("elsewhere/big.bin", logicalSize: Self.gigabyte, modified: Kit.daysAgo(400))
        let oldLarge = rule(home: home)
        let thresholds = Thresholds(minAgeDays: 180, minSize: 1)
        #expect(oldLarge.evaluate(Kit.entry(folder), sizeInfo: Kit.size(Self.gigabyte), thresholds: thresholds) == nil)
        #expect(evaluate(oldLarge, outside, thresholds: thresholds) == nil)
    }

    @Test func `root owned old file is flag only`() throws {
        let fixture = try FixtureBuilder(name: "OldLarge")
        let url = try fixture.sparseFile("Documents/root.bin", logicalSize: Self.gigabyte, modified: Kit.daysAgo(400))
        let entry = Kit.entry(url, ownerUID: 0)
        let match = try #require(rule(home: fixture.root).evaluate(entry, sizeInfo: Kit.size(Self.gigabyte), thresholds: Thresholds()))
        let candidate = try #require(CandidateFactory.candidate(for: entry, sizeInfo: Kit.size(Self.gigabyte), match: match, sessionID: 1))
        #expect(candidate.action == .flagOnly)
        #expect(candidate.reason == RuleMatch.rootOwnedReason)
        #expect(candidate.cliCommand == nil)
    }
}
