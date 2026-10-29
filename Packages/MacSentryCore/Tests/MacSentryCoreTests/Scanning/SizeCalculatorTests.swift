import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct SizeCalculatorTests {
    private let calculator = DefaultSizeCalculator()

    private func entry(_ name: String, in fixture: FixtureBuilder) async throws -> FileEntry {
        let entries = try await ScanTest.entries(BulkFileWalker(), root: fixture.root).entries
        return try #require(entries.first { $0.url.lastPathComponent == name })
    }

    @Test func `clone of a 50 MB file frees close to nothing`() async throws {
        let fixture = try FixtureBuilder(name: "SizeClone")
        let source = try fixture.file("source.bin", size: 50 * ScanTest.megabyte, fill: 0x42)
        try fixture.clone("clone.bin", of: source)

        let clone = try await entry("clone.bin", in: fixture)
        let info = calculator.sizeInfo(for: clone)
        #expect(info.logical == 50 * ScanTest.megabyte)
        #expect(info.allocated >= 50 * ScanTest.megabyte)
        #expect(info.freeable < ScanTest.megabyte)
    }

    @Test func `unshared file frees its allocated size`() async throws {
        let fixture = try FixtureBuilder(name: "SizePlain")
        try fixture.file("plain.bin", size: 5 * ScanTest.megabyte)
        let info = try await calculator.sizeInfo(for: entry("plain.bin", in: fixture))
        #expect(info.freeable == info.allocated)
        #expect(info.allocated >= 5 * ScanTest.megabyte)
    }

    @Test func `sparse 1 GB file allocates far below logical`() async throws {
        let fixture = try FixtureBuilder(name: "SizeSparse")
        try fixture.sparseFile("disk.raw", logicalSize: 1024 * ScanTest.megabyte)
        let info = try await calculator.sizeInfo(for: entry("disk.raw", in: fixture))
        #expect(info.logical == 1024 * ScanTest.megabyte)
        #expect(info.allocated < ScanTest.megabyte)
        #expect(info.freeable <= info.allocated)

        let folder = try await calculator.aggregate(folder: fixture.root)
        #expect(folder.logical == 1024 * ScanTest.megabyte)
        #expect(folder.allocated < ScanTest.megabyte)
    }

    @Test func `single file with extra hard links frees nothing`() async throws {
        let fixture = try FixtureBuilder(name: "SizeLinkedFile")
        let original = try fixture.file("a.bin", size: ScanTest.megabyte)
        try fixture.hardLink("b.bin", to: original)
        let info = try await calculator.sizeInfo(for: entry("a.bin", in: fixture))
        #expect(info.allocated >= ScanTest.megabyte)
        #expect(info.freeable == 0)
    }

    @Test func `folder counts hard links once and frees them only when all links are inside`() async throws {
        let fixture = try FixtureBuilder(name: "SizeLinkedFolder")
        let original = try fixture.file("candidate/a.bin", size: ScanTest.megabyte)
        try fixture.hardLink("candidate/nested/b.bin", to: original)
        let partial = try fixture.file("candidate/c.bin", size: 2 * ScanTest.megabyte)
        try fixture.hardLink("elsewhere/c.bin", to: partial)
        try fixture.file("candidate/plain.bin", size: 3 * ScanTest.megabyte)
        let one = ScanTest.allocated(original)
        let two = ScanTest.allocated(partial)
        let three = try ScanTest.allocated(fixture.url("candidate/plain.bin"))

        let summary = try await calculator.summarize(folder: fixture.url("candidate"))
        #expect(summary.size.logical == 6 * ScanTest.megabyte)
        #expect(summary.size.allocated == one + two + three)
        #expect(summary.size.freeable == one + three)
        #expect(summary.itemCount == 4)

        let whole = try await calculator.aggregate(folder: fixture.root)
        #expect(whole.allocated == one + two + three)
        #expect(whole.freeable == one + two + three)
    }

    @Test func `folder freeable sums members and tracks latest modified`() async throws {
        let fixture = try FixtureBuilder(name: "SizeFolder")
        let newest = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try fixture.file("f/source.bin", size: 4 * ScanTest.megabyte, modified: Date(timeIntervalSince1970: 1_600_000_000))
        try fixture.clone("f/clone.bin", of: source)
        try fixture.file("f/deep/new.bin", size: ScanTest.megabyte, modified: newest)
        try fixture.setDates(of: fixture.url("f/deep"), modified: Date(timeIntervalSince1970: 1000))
        try fixture.setDates(of: fixture.url("f"), modified: Date(timeIntervalSince1970: 1000))

        let summary = try await calculator.summarize(folder: fixture.url("f"))
        #expect(summary.size.logical == 9 * ScanTest.megabyte)
        #expect(summary.size.freeable < 2 * ScanTest.megabyte)
        #expect(summary.size.freeable >= ScanTest.megabyte)
        #expect(summary.latestModified == newest)
    }

    @Test func `package entry freeable is its aggregate`() {
        let entry = FileEntry(
            url: URL(filePath: "/x/Y.app", directoryHint: .isDirectory), kind: .package, logicalSize: 10, allocatedSize: 8,
            privateSize: 4, linkCount: 1, inode: 1, device: 1, flags: 0, created: nil, modified: nil, ownerUID: 0,
        )
        #expect(calculator.sizeInfo(for: entry) == SizeInfo(logical: 10, allocated: 8, freeable: 4))
    }
}
