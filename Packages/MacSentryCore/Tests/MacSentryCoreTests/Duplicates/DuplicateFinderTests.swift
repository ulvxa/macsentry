import CryptoKit
import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct DuplicateFinderTests {
    private typealias Support = DuplicateTestSupport
    private static let twentyMB: Int64 = 20 << 20

    @Test func `three identical 20 MB files form one group with the oldest created as keeper`() async throws {
        let fixture = try FixtureBuilder(name: "DupThree")
        let urls = try [
            fixture.file("Documents/report.bin", size: Self.twentyMB, created: Support.date(20)),
            fixture.file("Desktop/report.bin", size: Self.twentyMB, created: Support.date(5)),
            fixture.file("Downloads/report copy.bin", size: Self.twentyMB, created: Support.date(30)),
        ]
        let index = try Support.index(fixture, urls)

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))
        let groups = Support.groups(events)

        try #require(groups.count == 1)
        let (group, members) = groups[0]
        #expect(group.keeperURL == urls[1])
        #expect(group.memberCount == 3)
        #expect(group.fileSize == Self.twentyMB)
        #expect(group.sessionID == Support.sessionID)
        #expect(group.id == nil)
        let expectedHash = SHA256.hash(data: Data(repeating: 0x61, count: Int(Self.twentyMB)))
            .map { String(format: "%02x", $0) }.joined()
        #expect(group.contentHash == expectedHash)
        #expect(Set(members.map(\.url)) == [urls[0], urls[2]])
        for member in members {
            #expect(member.category == .duplicate)
            #expect(member.tier == .yellow)
            #expect(member.ruleID == "duplicate.content")
            #expect(member.action == .quarantine)
            #expect(member.kind == .file)
            #expect(member.status == .found)
            #expect(member.dupGroupID == nil)
            #expect(member.logicalSize == Self.twentyMB)
            #expect(member.freeableSize > Self.twentyMB / 2)
            #expect(member.createdAt != nil && member.modifiedAt != nil)
            #expect(member.reason.contains("report.bin in Desktop"))
        }
        #expect(group.reclaimableSize == members.reduce(0) { $0 + $1.freeableSize })
        #expect(!group.isSpaceEfficient)

        let summary = try #require(Support.summary(events))
        #expect(summary.groupCount == 1)
        #expect(summary.filesHashed == 3)
        #expect(summary.bytesHashed == 3 * Self.twentyMB)
        #expect(summary.unreadable.isEmpty && summary.changedDuringHashing.isEmpty)
        #expect(events.contains(.hashing(done: 3, total: 3, bytes: 3 * Self.twentyMB)))
    }

    @Test func `a clone pair is grouped but reclaimable is near zero`() async throws {
        let fixture = try FixtureBuilder(name: "DupClone")
        let original = try fixture.file("Movies/clip.mov", size: Self.twentyMB, created: Support.date(1))
        let clone = try fixture.clone("Desktop/clip copy.mov", of: original)
        let index = try Support.index(fixture, [original, clone])

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))
        let groups = Support.groups(events)

        try #require(groups.count == 1)
        let (group, members) = groups[0]
        #expect(group.memberCount == 2)
        #expect(group.reclaimableSize * 20 < group.fileSize)
        #expect(group.isSpaceEfficient)
        #expect(members.count == 1)
        #expect(members.first?.freeableSize ?? .max < Self.twentyMB / 20)
        #expect(members.first?.reason.contains("Shares its storage") == true)
    }

    @Test func `hard links to the same inode are not duplicates`() async throws {
        let fixture = try FixtureBuilder(name: "DupHardLink")
        let original = try fixture.file("Documents/a.bin", size: 2_000_000)
        let link = try fixture.hardLink("Desktop/a-link.bin", to: original)
        let index = try Support.index(fixture, [original, link])

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))

        #expect(Support.groups(events).isEmpty)
        #expect(Support.summary(events)?.filesHashed == 0)
    }

    @Test func `hard link plus a real copy is a group of two`() async throws {
        let fixture = try FixtureBuilder(name: "DupHardLinkCopy")
        let original = try fixture.file("Documents/a.bin", size: 2_000_000, created: Support.date(1))
        let link = try fixture.hardLink("Documents/Old/a-link.bin", to: original)
        let copy = try fixture.file("Desktop/a.bin", size: 2_000_000, created: Support.date(2))
        let index = try Support.index(fixture, [original, link, copy])

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))
        let groups = Support.groups(events)

        try #require(groups.count == 1)
        #expect(groups[0].group.memberCount == 2)
        #expect(groups[0].group.keeperURL == original)
        #expect(groups[0].members.map(\.url) == [copy])
    }

    @Test func `partial hash rejects same size files with different content`() async throws {
        let fixture = try FixtureBuilder(name: "DupPartial")
        let first = try fixture.file("Documents/a.bin", size: 2_000_000, fill: 0x61)
        let second = try fixture.file("Documents/b.bin", size: 2_000_000, fill: 0x62)
        let index = try Support.index(fixture, [first, second])

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))

        #expect(Support.groups(events).isEmpty)
        #expect(Support.summary(events)?.filesHashed == 0)
        #expect(events.contains(.hashing(done: 0, total: 0, bytes: 0)))
        let entries = try Support.entries([first, second])
        #expect(FileHasher.partialHash(entries[0]) != FileHasher.partialHash(entries[1]))
    }

    @Test func `full hash rejects files that only differ in the middle`() async throws {
        let fixture = try FixtureBuilder(name: "DupMiddle")
        var bytes = Data(repeating: 0x61, count: 2_000_000)
        let first = try fixture.url("Documents/a.bin")
        let second = try fixture.url("Documents/b.bin")
        try fixture.folder("Documents")
        try bytes.write(to: first)
        bytes[1_000_000] = 0x62
        try bytes.write(to: second)
        let index = try Support.index(fixture, [first, second])

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))

        #expect(Support.groups(events).isEmpty)
        #expect(Support.summary(events)?.filesHashed == 2)
    }

    @Test func `files changed after the walk are dropped`() async throws {
        let fixture = try FixtureBuilder(name: "DupChanged")
        let urls = try (0 ..< 4).map { try fixture.file("Documents/copy\($0).bin", size: 2_000_000, created: Support.date($0)) }
        let index = try Support.index(fixture, urls)
        try fixture.setDates(of: urls[0], modified: Support.date(400))
        let handle = try FileHandle(forWritingTo: urls[1])
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x61]))
        try handle.close()

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))
        let groups = Support.groups(events)

        try #require(groups.count == 1)
        #expect(groups[0].group.memberCount == 2)
        #expect(groups[0].group.keeperURL == urls[2])
        #expect(groups[0].members.map(\.url) == [urls[3]])
        #expect(Set(Support.summary(events)?.changedDuringHashing ?? []) == [urls[0], urls[1]])
    }

    @Test func `unreadable files are skipped and counted`() async throws {
        let fixture = try FixtureBuilder(name: "DupUnreadable")
        let urls = try (0 ..< 3).map { try fixture.file("Documents/copy\($0).bin", size: 2_000_000, created: Support.date($0)) }
        let index = try Support.index(fixture, urls)
        let locked = urls[0].path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }

        let events = try await Support.collect(DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture)))
        let groups = Support.groups(events)

        try #require(groups.count == 1)
        #expect(groups[0].group.memberCount == 2)
        #expect(Support.summary(events)?.unreadable == [urls[0]])
    }

    @Test func `dataless files are never indexed or hashed`() {
        var index = SizeIndex(roots: [URL(filePath: "/fixture")])
        let dataless = Support.syntheticEntry("/fixture/Documents/cloud.bin", inode: 1, flags: UInt32(SF_DATALESS))
        let added = [dataless, Support.syntheticEntry("/fixture/Documents/local.bin", inode: 2)].map { index.add($0) }
        #expect(added == [false, true])
        #expect(index.datalessCount == 1)
        #expect(index.fileCount == 1)
    }

    @Test func `verify accepts an unchanged file and flags a deleted one as changed`() throws {
        let fixture = try FixtureBuilder(name: "DupVerify")
        let url = try fixture.file("Documents/a.bin", size: 2_000_000)
        #expect(try FileHasher.verify(FileProbe.entry(for: url)) == nil)
        #expect(try !FileProbe.status(of: url).get().isDataless)
        #expect(FileHasher.verify(Support.syntheticEntry(fixture.root.appending(path: "gone.bin").path(percentEncoded: false))) == .changed)
    }

    @Test func `hashing a 5 GB fixture stops quickly when the stream is cancelled`() async throws {
        let fixture = try FixtureBuilder(name: "DupCancelStream")
        let urls = try [
            fixture.sparseFile("Movies/big-a.raw", logicalSize: 2_500_000_000),
            fixture.sparseFile("Movies/big-b.raw", logicalSize: 2_500_000_000),
        ]
        let index = try Support.index(fixture, urls)
        let stream = DefaultDuplicateFinder().find(sizeIndex: index, options: Support.options(fixture))
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()

        let consumer = Task {
            var events: [DuplicateEvent] = []
            do {
                for try await event in stream {
                    events.append(event)
                    if case let .hashing(_, _, bytes) = event, bytes > 0 {
                        startedContinuation.yield()
                    }
                }
            } catch {}
            return events
        }
        for await _ in started {
            break
        }
        let cancelledAt = ContinuousClock.now
        consumer.cancel()
        let events = await consumer.value

        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(Support.groups(events).isEmpty)
        #expect(Support.summary(events) == nil)
    }

    @Test func `hashing work itself throws cancellation between chunks`() async throws {
        let fixture = try FixtureBuilder(name: "DupCancelRun")
        let urls = try [
            fixture.sparseFile("Movies/big-a.raw", logicalSize: 2_500_000_000),
            fixture.sparseFile("Movies/big-b.raw", logicalSize: 2_500_000_000),
        ]
        let index = try Support.index(fixture, urls)
        let options = Support.options(fixture)
        let (progress, progressContinuation) = AsyncStream<Int64>.makeStream()

        let work = Task {
            try await DefaultDuplicateFinder().run(sizeIndex: index, options: options) { event in
                if case let .hashing(_, _, bytes) = event, bytes > 0 {
                    progressContinuation.yield(bytes)
                }
            }
        }
        var bytesAtCancel: Int64 = 0
        for await bytes in progress {
            bytesAtCancel = bytes
            break
        }
        let cancelledAt = ContinuousClock.now
        work.cancel()
        let result = await work.result

        #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
        #expect(bytesAtCancel < 5_000_000_000)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func `stub finder replays scripted events`() async throws {
        let group = DuplicateGroup(
            sessionID: 1, contentHash: "abc", fileSize: 10, memberCount: 2, reclaimableSize: 10,
            keeperURL: URL(filePath: "/a"),
        )
        let scripted: [DuplicateEvent] = [.hashing(done: 0, total: 2, bytes: 0), .group(group, members: []), .finished(DuplicateSummary())]
        let finder = StubDuplicateFinder(events: scripted)
        let index = SizeIndex(roots: [])
        let options = DuplicateOptions(roots: [], homeURL: URL(filePath: "/"), sessionID: 1)
        #expect(try await Support.collect(finder.find(sizeIndex: index, options: options)) == scripted)

        let failing = StubDuplicateFinder(events: [], failure: .storage("boom"))
        await #expect(throws: DuplicateError.storage("boom")) {
            _ = try await Support.collect(failing.find(sizeIndex: index, options: options))
        }
    }
}
