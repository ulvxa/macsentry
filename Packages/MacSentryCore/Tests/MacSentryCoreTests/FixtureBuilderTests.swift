import Darwin
import Foundation
import MacSentryTestSupport
import Testing

struct FixtureBuilderTests {
    private func info(_ url: URL) throws -> stat {
        var info = stat()
        #expect(lstat(url.path(percentEncoded: false), &info) == 0)
        return info
    }

    @Test func `root is fresh temp directory outside home`() throws {
        let first = try FixtureBuilder()
        let second = try FixtureBuilder()
        #expect(first.root != second.root)
        let tempRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path(percentEncoded: false)
        #expect(first.root.path(percentEncoded: false).hasPrefix(tempRoot))
        let contents = try FileManager.default.contentsOfDirectory(atPath: first.root.path(percentEncoded: false))
        #expect(contents.isEmpty)
    }

    @Test func `file has exact size and dates`() throws {
        let fixture = try FixtureBuilder()
        let created = Date(timeIntervalSince1970: 1_500_000_000)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        let url = try fixture.file("a/b/data.bin", size: 3 * 1024 * 1024 + 7, created: created, modified: modified)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        #expect(values.fileSize == 3 * 1024 * 1024 + 7)
        #expect(values.creationDate == created)
        #expect(values.contentModificationDate == modified)
    }

    @Test func `clone has same content and different inode`() throws {
        let fixture = try FixtureBuilder()
        let source = try fixture.file("source.bin", size: 2 * 1024 * 1024, fill: 0x42)
        let clone = try fixture.clone("copies/clone.bin", of: source)
        #expect(try Data(contentsOf: source) == Data(contentsOf: clone))
        #expect(try info(source).st_ino != info(clone).st_ino)
        #expect(try info(source).st_nlink == 1)
    }

    @Test func `hard link shares inode`() throws {
        let fixture = try FixtureBuilder()
        let source = try fixture.file("original.txt", size: 4096)
        let linked = try fixture.hardLink("other/linked.txt", to: source)
        #expect(try info(source).st_ino == info(linked).st_ino)
        #expect(try info(source).st_nlink == 2)
        #expect(try info(linked).st_nlink == 2)
    }

    @Test func `sparse file allocates far less than logical size`() throws {
        let fixture = try FixtureBuilder()
        let url = try fixture.sparseFile("big.sparse", logicalSize: 1 << 30)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        #expect(values.fileSize == 1 << 30)
        #expect((values.fileAllocatedSize ?? .max) < 1 << 20)
    }

    @Test func `symlink points at destination without following`() throws {
        let fixture = try FixtureBuilder()
        let folder = try fixture.folder("real")
        let link = try fixture.symlink("link", to: folder)
        #expect(try info(link).st_mode & S_IFMT == S_IFLNK)
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false))
        #expect(destination == folder.path(percentEncoded: false))
    }

    @Test(arguments: ["/etc/passwd", "../escape", "a/../../b", "", "./x"])
    func `rejects paths that leave root`(_ path: String) throws {
        let fixture = try FixtureBuilder()
        #expect(throws: FixtureError.invalidRelativePath(path)) { try fixture.file(path) }
    }
}
