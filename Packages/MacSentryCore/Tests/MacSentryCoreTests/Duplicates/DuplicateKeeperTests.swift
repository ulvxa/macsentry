import Foundation
import Testing
@testable import MacSentryCore

struct DuplicateKeeperTests {
    private typealias Support = DuplicateTestSupport
    private static let home = URL(filePath: "/msfixture/home", directoryHint: .isDirectory)

    private static func keeper(_ entries: [FileEntry]) -> String? {
        DuplicateKeeper.preferred(among: entries, homeURL: home)?.url.path(percentEncoded: false)
    }

    @Test func `oldest created wins over shorter path`() {
        let entries = [
            Support.syntheticEntry("/msfixture/home/a.bin", inode: 1, created: Support.date(9)),
            Support.syntheticEntry("/msfixture/home/Documents/deep/a.bin", inode: 2, created: Support.date(1)),
        ]
        #expect(Self.keeper(entries) == "/msfixture/home/Documents/deep/a.bin")
    }

    @Test func `equal created dates fall back to the shortest path`() {
        let entries = [
            Support.syntheticEntry("/msfixture/home/Documents/sub/a.bin", inode: 1, created: Support.date(1)),
            Support.syntheticEntry("/msfixture/home/Documents/a.bin", inode: 2, created: Support.date(1)),
        ]
        #expect(Self.keeper(entries) == "/msfixture/home/Documents/a.bin")
    }

    @Test func `equal created and path length prefer a path outside Downloads`() {
        let entries = [
            Support.syntheticEntry("/msfixture/home/Downloads/a.bin", inode: 1, created: Support.date(1)),
            Support.syntheticEntry("/msfixture/home/Documents/a.bin", inode: 2, created: Support.date(1)),
        ]
        #expect(Self.keeper(entries) == "/msfixture/home/Documents/a.bin")
        #expect(Self.keeper(entries.reversed()) == "/msfixture/home/Documents/a.bin")
    }

    @Test func `missing created date loses to a known one`() {
        let entries = [
            Support.syntheticEntry("/msfixture/home/a.bin", inode: 1, created: nil),
            Support.syntheticEntry("/msfixture/home/Documents/a.bin", inode: 2, created: Support.date(100)),
        ]
        #expect(Self.keeper(entries) == "/msfixture/home/Documents/a.bin")
    }

    private struct Sample {
        var group: DuplicateGroup
        var members: [Candidate]
        let keeper: FileEntry
    }

    private static func sampleGroup() throws -> Sample {
        let entries = [
            Support.syntheticEntry("/msfixture/home/Documents/a.bin", size: 1000, inode: 1, created: Support.date(1)),
            Support.syntheticEntry("/msfixture/home/Desktop/a.bin", size: 1000, inode: 2, created: Support.date(2)),
            Support.syntheticEntry("/msfixture/home/Downloads/a.bin", size: 1000, inode: 3, created: Support.date(3)),
        ]
        let options = DuplicateOptions(roots: [home], homeURL: home, sessionID: 7)
        let result = try #require(DefaultDuplicateFinder.makeGroup(hash: "h", entries: entries, options: options))
        return Sample(group: result.group, members: result.members, keeper: entries[0])
    }

    @Test func `changing the keeper turns the old keeper into a candidate and ignores the new one`() throws {
        let sample = try Self.sampleGroup()
        #expect(sample.group.keeperURL == sample.keeper.url)
        #expect(sample.group.reclaimableSize == 2000)
        let newKeeper = URL(filePath: "/msfixture/home/Desktop/a.bin")

        let changed = try DuplicateKeeper.changeKeeper(
            group: sample.group, members: sample.members, to: newKeeper, previousKeeper: sample.keeper,
        )

        #expect(changed.group.keeperURL == newKeeper)
        #expect(changed.group.reclaimableSize == 2000)
        let byPath = Dictionary(uniqueKeysWithValues: changed.members.map { ($0.url.path(percentEncoded: false), $0) })
        #expect(byPath["/msfixture/home/Desktop/a.bin"]?.status == .ignored)
        let oldKeeper = try #require(byPath["/msfixture/home/Documents/a.bin"])
        #expect(oldKeeper.status == .found)
        #expect(oldKeeper.sessionID == 7)
        #expect(oldKeeper.category == .duplicate)
        #expect(oldKeeper.createdAt == Support.date(1))
        #expect(oldKeeper.reason.contains("in Desktop"))
        #expect(byPath["/msfixture/home/Downloads/a.bin"]?.reason.contains("in Desktop") == true)

        let restored = try DuplicateKeeper.changeKeeper(
            group: changed.group, members: changed.members, to: sample.keeper.url,
            previousKeeper: Support.syntheticEntry("/msfixture/home/Desktop/a.bin", size: 1000, inode: 2),
        )
        #expect(restored.members.count == 3)
        #expect(restored.members.first { $0.url == sample.keeper.url }?.status == .ignored)
        #expect(restored.members.first { $0.url == newKeeper }?.status == .found)
        #expect(restored.group.keeperURL == sample.keeper.url)
    }

    @Test func `changing to a non member is rejected`() throws {
        let sample = try Self.sampleGroup()
        let stranger = URL(filePath: "/msfixture/home/other.bin")
        #expect(throws: DuplicateError.keeperNotInGroup(stranger)) {
            try DuplicateKeeper.changeKeeper(group: sample.group, members: sample.members, to: stranger, previousKeeper: sample.keeper)
        }
        let wrongPrevious = Support.syntheticEntry("/msfixture/home/Desktop/a.bin")
        #expect(throws: DuplicateError.keeperNotInGroup(wrongPrevious.url)) {
            try DuplicateKeeper.changeKeeper(
                group: sample.group, members: sample.members, to: URL(filePath: "/msfixture/home/Downloads/a.bin"),
                previousKeeper: wrongPrevious,
            )
        }
    }

    @Test func `quarantining every member of a group is blocked`() throws {
        var sample = try Self.sampleGroup()
        let candidates = sample.members.map(\.url)
        #expect(!DuplicateKeeper.wouldRemoveEveryMember(group: sample.group, members: sample.members, selection: candidates))
        #expect(DuplicateKeeper.wouldRemoveEveryMember(
            group: sample.group, members: sample.members, selection: candidates + [sample.keeper.url],
        ))
        sample.members[0].status = .quarantined
        #expect(DuplicateKeeper.wouldRemoveEveryMember(
            group: sample.group, members: sample.members, selection: [sample.members[1].url, sample.keeper.url],
        ))
        #expect(!DuplicateKeeper.wouldRemoveEveryMember(group: sample.group, members: sample.members, selection: [sample.keeper.url]))
    }
}
