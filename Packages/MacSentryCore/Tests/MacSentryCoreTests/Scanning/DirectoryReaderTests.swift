import Darwin
import Foundation
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct DirectoryReaderTests {
    private static let failAtEnd: BulkListing = { descriptor, request, buffer, size, options in
        let count = getattrlistbulk(descriptor, request, buffer, size, options)
        guard count == 0 else { return count }
        errno = EIO
        return -1
    }

    private func errorOnlyEntry(error: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        func append(_ value: some BitwiseCopyable) {
            withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
        }
        var returned = attribute_set_t()
        returned.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_ERROR)
        append(UInt32(4 + MemoryLayout<attribute_set_t>.size + 4))
        append(returned)
        append(error)
        return bytes
    }

    @Test func `error only entry at the end of the buffer is parsed within its length`() {
        let bytes = errorOnlyEntry(error: UInt32(EACCES))
        let entry = bytes.withUnsafeBytes { DirectoryReader.parse($0.baseAddress.unsafelyUnwrapped, length: $0.count) }
        #expect(entry?.error == UInt32(EACCES))
        #expect(entry?.name == "")
    }

    @Test func `truncated entry without an error is rejected`() {
        var bytes = errorOnlyEntry(error: 0)
        bytes += [UInt8](repeating: 0, count: 6)
        let entry = bytes.withUnsafeBytes { DirectoryReader.parse($0.baseAddress.unsafelyUnwrapped, length: $0.count) }
        #expect(entry == nil)
    }

    @Test func `listing that fails midway is returned as partial`() throws {
        let fixture = try FixtureBuilder(name: "PartialListing")
        for name in ["a", "b", "c"] {
            try fixture.file("dir/\(name).txt", size: 1)
        }
        let path = try fixture.url("dir").path(percentEncoded: false)
        let devices = try Set([#require(lstatInfo(fixture.url("dir"))).st_dev])

        let result = DirectoryReader(bulk: Self.failAtEnd).read(path, allowedDevices: devices)

        guard case let .partial(entries, code) = result else {
            Issue.record("expected a partial listing, got \(result)")
            return
        }
        #expect(code == EIO)
        #expect(entries.map(\.name).sorted() == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func `walker reports partial listings and still visits what it read`() async throws {
        let fixture = try FixtureBuilder(name: "PartialWalk")
        try fixture.file("a.txt", size: 1)
        try fixture.file("sub/b.txt", size: 1)
        let issues = Mutex<[WalkIssue]>([])
        let visited = Mutex<[String]>([])

        try await BulkFileWalker().walk(
            root: fixture.root,
            excluded: [],
            pool: ReaderPool { DirectoryReader(bulk: Self.failAtEnd) },
            onIssue: { issue in issues.withLock { $0.append(issue) } },
            visit: { entry in
                visited.withLock { $0.append(entry.url.lastPathComponent) }
                return .descend
            },
        )

        #expect(visited.withLock { $0 }.sorted() == ["a.txt", "b.txt", "sub"])
        let reported = issues.withLock { $0 }.compactMap { issue -> String? in
            guard case let .unreadable(url, code) = issue, code == EIO else { return nil }
            return url.storagePath
        }
        #expect(try reported.sorted() == [fixture.root.storagePath, fixture.url("sub").storagePath].sorted())
    }

    @Test func `entry level errors are reported instead of dropped`() async throws {
        let issues = Mutex<[WalkIssue]>([])
        let job = WalkJob(
            excluded: [],
            devices: [],
            pool: ReaderPool(),
            onIssue: { issue in issues.withLock { $0.append(issue) } },
            visit: { _ in .descend },
        )
        let raw = RawEntry(
            name: "secret", type: VREG.rawValue, device: 0, inode: 0, linkCount: 1, logicalSize: 0, allocatedSize: 0,
            privateSize: nil, flags: 0, ownerUID: 0, created: nil, modified: nil, finderFlags: 0, error: UInt32(EACCES),
        )

        let next = try await job.handle(raw, in: "/fixture/dir", DirectoryReader())

        #expect(next == nil)
        #expect(issues.withLock { $0 } == [.unreadable(URL(filePath: "/fixture/dir/secret"), errno: EACCES)])
    }

    @Test func `walker reuses a bounded pool of read buffers`() async throws {
        let fixture = try FixtureBuilder(name: "ReaderPool")
        for index in 0 ..< 40 {
            try fixture.file("d\(index % 8)/n\(index)/f.txt", size: 1)
        }
        let pool = ReaderPool()

        try await BulkFileWalker(maxConcurrency: 3).walk(
            root: fixture.root, excluded: [], pool: pool, onIssue: { _ in }, visit: { _ in .descend },
        )

        #expect(pool.created >= 1)
        #expect(pool.created <= 3)
    }
}
