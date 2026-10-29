import Darwin
import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct FileWalkerTests {
    @Test func `files report exact logical sizes`() async throws {
        let fixture = try FixtureBuilder(name: "WalkSizes")
        try fixture.file("a/one.bin", size: ScanTest.megabyte)
        try fixture.file("a/b/ten.bin", size: 10 * ScanTest.megabyte)
        try fixture.file("c/hundred.bin", size: 100 * ScanTest.megabyte)

        let (entries, issues) = try await ScanTest.entries(BulkFileWalker(), root: fixture.root)
        let files = Dictionary(uniqueKeysWithValues: entries.filter { $0.kind == .file }.map { ($0.url.lastPathComponent, $0) })
        #expect(files["one.bin"]?.logicalSize == ScanTest.megabyte)
        #expect(files["ten.bin"]?.logicalSize == 10 * ScanTest.megabyte)
        #expect(files["hundred.bin"]?.logicalSize == 100 * ScanTest.megabyte)
        #expect(try files["hundred.bin"]?.allocatedSize == ScanTest.allocated(fixture.url("c/hundred.bin")))
        #expect(Set(entries.filter { $0.kind == .folder }.map(\.url.lastPathComponent)) == ["a", "b", "c"])
        #expect(issues.isEmpty)
    }

    @Test func `entries carry inode device link count and dates`() async throws {
        let fixture = try FixtureBuilder(name: "WalkAttributes")
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        let created = Date(timeIntervalSince1970: 1_500_000_000)
        let url = try fixture.file("data.bin", size: 4096, created: created, modified: modified)
        try fixture.hardLink("link.bin", to: url)
        var info = stat()
        lstat(url.path(percentEncoded: false), &info)

        let (entries, _) = try await ScanTest.entries(BulkFileWalker(), root: fixture.root)
        let entry = try #require(entries.first { $0.url.lastPathComponent == "data.bin" })
        #expect(entry.inode == info.st_ino)
        #expect(entry.device == info.st_dev)
        #expect(entry.linkCount == 2)
        #expect(entry.ownerUID == getuid())
        #expect(entry.modified == modified)
        #expect(entry.created == created)
        #expect(entry.privateSize != nil)
    }

    @Test func `symlink to outside directory is emitted but not traversed`() async throws {
        let outside = try FixtureBuilder(name: "WalkOutside")
        try outside.file("big/secret.bin", size: 5 * ScanTest.megabyte)
        let fixture = try FixtureBuilder(name: "WalkSymlink")
        try fixture.file("inside.bin", size: 10)
        let link = try fixture.symlink("escape", to: outside.url("big"))

        for walker in [BulkFileWalker() as any ReportingFileWalker, EnumeratorFileWalker()] {
            let (entries, _) = try await ScanTest.entries(walker, root: fixture.root)
            let symlink = try #require(entries.first { $0.path == link.storagePath })
            #expect(symlink.kind == .symlink)
            #expect(symlink.allocatedSize < ScanTest.megabyte)
            #expect(!entries.contains { $0.path.hasPrefix(link.storagePath + "/") })
            #expect(!entries.contains { $0.path.hasPrefix(outside.root.storagePath) })
            #expect(entries.count == 2)
        }
    }

    @Test func `excluded roots are skipped`() async throws {
        let fixture = try FixtureBuilder(name: "WalkExcluded")
        try fixture.file("keep/a.bin", size: 10)
        try fixture.file("skip/b.bin", size: 10)
        try fixture.file("skip/deep/c.bin", size: 10)

        for walker in [BulkFileWalker() as any ReportingFileWalker, EnumeratorFileWalker()] {
            let (entries, _) = try await ScanTest.entries(walker, root: fixture.root, excluded: [fixture.url("skip")])
            #expect(Set(entries.map(\.url.lastPathComponent)) == ["keep", "a.bin"])
            let (none, _) = try await ScanTest.entries(walker, root: fixture.url("skip/deep"), excluded: [fixture.url("skip")])
            #expect(none.isEmpty)
        }
    }

    @Test func `packages are one atomic entry sized fully`() async throws {
        let fixture = try FixtureBuilder(name: "WalkPackage")
        try fixture.file("Tool.app/Contents/MacOS/tool", size: 2 * ScanTest.megabyte)
        try fixture.file("Tool.app/Contents/Resources/icon.icns", size: ScanTest.megabyte)
        try fixture.file("Notes.rtfd/TXT.rtf", size: 100)

        for walker in [BulkFileWalker() as any ReportingFileWalker, EnumeratorFileWalker()] {
            let (entries, _) = try await ScanTest.entries(walker, root: fixture.root)
            #expect(entries.count == 2)
            let app = try #require(entries.first { $0.url.lastPathComponent == "Tool.app" })
            #expect(app.kind == .package)
            #expect(app.logicalSize == 3 * ScanTest.megabyte)
            #expect(app.allocatedSize >= 3 * ScanTest.megabyte)
            #expect(entries.first { $0.url.lastPathComponent == "Notes.rtfd" }?.kind == .package)
        }
    }

    @Test func `skip children stops descent`() async throws {
        let fixture = try FixtureBuilder(name: "WalkSkip")
        try fixture.file("cache/inner/a.bin", size: 10)
        try fixture.file("other/b.bin", size: 10)
        let (entries, _) = try await ScanTest.entries(BulkFileWalker(), root: fixture.root) {
            $0.url.lastPathComponent == "cache" ? .skipChildren : .descend
        }
        #expect(Set(entries.map(\.url.lastPathComponent)) == ["cache", "other", "b.bin"])
    }

    @Test func `permission denied directory is reported and walk continues`() async throws {
        let fixture = try FixtureBuilder(name: "WalkLocked")
        try fixture.file("locked/hidden.bin", size: 10)
        try fixture.file("open/visible.bin", size: 10)
        let locked = try fixture.url("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path(percentEncoded: false)) }

        let (entries, issues) = try await ScanTest.entries(BulkFileWalker(), root: fixture.root)
        #expect(entries.contains { $0.url.lastPathComponent == "visible.bin" })
        #expect(!entries.contains { $0.url.lastPathComponent == "hidden.bin" })
        #expect(issues == [.unreadable(URL(filePath: locked.storagePath, directoryHint: .isDirectory), errno: EACCES)])
    }

    @Test func `missing root throws typed error`() async throws {
        let fixture = try FixtureBuilder(name: "WalkMissing")
        let missing = try fixture.url("nope")
        await #expect(throws: ScanError.rootUnavailable(missing, errno: ENOENT)) {
            _ = try await ScanTest.entries(BulkFileWalker(), root: missing)
        }
    }

    @Test func `dataless flag is detected in isolation`() {
        #expect(WalkRules.isDataless(flags: UInt32(SF_DATALESS)))
        #expect(WalkRules.isDataless(flags: UInt32(SF_DATALESS) | UInt32(UF_HIDDEN)))
        #expect(!WalkRules.isDataless(flags: 0))
        #expect(!WalkRules.isDataless(flags: UInt32(UF_IMMUTABLE) | UInt32(SF_RESTRICTED)))
    }

    @Test func `package detection uses extensions and type conformance`() {
        #expect(WalkRules.isPackage(name: "Xcode.app"))
        #expect(WalkRules.isPackage(name: "Photos Library.photoslibrary"))
        #expect(WalkRules.isPackage(name: "Build.XCARCHIVE"))
        #expect(WalkRules.isPackage(name: "plain", finderFlags: 0x2000))
        #expect(!WalkRules.isPackage(name: "node_modules"))
        #expect(!WalkRules.isPackage(name: ".app"))
        #expect(!WalkRules.isPackage(name: "com.example.cache"))
    }

    @Test func `bulk and enumerator walkers agree`() async throws {
        let fixture = try FixtureBuilder(name: "WalkParity")
        let shared = try fixture.file("a/shared.bin", size: 70000)
        try fixture.hardLink("b/shared-link.bin", to: shared)
        try fixture.file("a/b/c/deep.bin", size: 123_456)
        try fixture.sparseFile("sparse.img", logicalSize: 50 * ScanTest.megabyte)
        try fixture.symlink("a/link", to: fixture.url("a/b"))
        try fixture.file("Thing.bundle/Contents/x", size: 9000)
        try fixture.folder("empty")

        struct Key: Hashable {
            let path: String, kind: EntryKind, logical: Int64, allocated: Int64, inode: UInt64, links: UInt32
        }
        func keys(_ entries: [FileEntry]) -> Set<Key> {
            Set(entries.map {
                Key(
                    path: $0.path,
                    kind: $0.kind,
                    logical: $0.logicalSize,
                    allocated: $0.allocatedSize,
                    inode: $0.inode,
                    links: $0.linkCount,
                )
            })
        }
        let bulk = try await ScanTest.entries(BulkFileWalker(maxConcurrency: 4), root: fixture.root).entries
        let enumerated = try await ScanTest.entries(EnumeratorFileWalker(), root: fixture.root).entries
        #expect(bulk.count == 11)
        #expect(keys(bulk) == keys(enumerated))
    }
}
