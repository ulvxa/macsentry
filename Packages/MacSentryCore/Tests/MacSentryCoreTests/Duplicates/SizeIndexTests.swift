import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct SizeIndexTests {
    private typealias Support = DuplicateTestSupport

    private struct DenyPolicy: ProtectionPolicy {
        let deniedName: String

        func check(_ url: URL) -> ProtectionVerdict {
            url.lastPathComponent == deniedName ? .denied("protected") : .allowed
        }
    }

    @Test func `only files at or above min size inside roots are indexed`() {
        var index = SizeIndex(roots: [URL(filePath: "/msfixture/Documents")], minSize: 1_000_000)
        let added = [
            Support.syntheticEntry("/msfixture/Documents/a.bin", size: 1_000_000),
            Support.syntheticEntry("/msfixture/Documents/small.bin", size: 999_999),
            Support.syntheticEntry("/msfixture/DocumentsOther/a.bin"),
            Support.syntheticEntry("/msfixture/Desktop/a.bin"),
            Support.syntheticEntry("/msfixture/Documents/folder", kind: .folder),
            Support.syntheticEntry("/msfixture/Documents/link", kind: .symlink),
        ].map { index.add($0) }
        #expect(added == [true, false, false, false, false, false])
        #expect(index.fileCount == 1)
    }

    @Test func `packages node modules and git internals are excluded by path`() {
        var index = SizeIndex(roots: [URL(filePath: "/msfixture")])
        let added = [
            "/msfixture/Apps/Tool.app/Contents/Resources/big.bin",
            "/msfixture/Pictures/Photos Library.photoslibrary/originals/a.heic",
            "/msfixture/Music/Music Library.MusicLibrary/a.m4a",
            "/msfixture/code/web/node_modules/pkg/big.js",
            "/msfixture/code/repo/.git/objects/pack/a.pack",
            "/msfixture/Documents/v1.2/file.bin",
        ].map { index.add(Support.syntheticEntry($0)) }
        #expect(added == [false, false, false, false, false, true])
        #expect(index.fileCount == 1)
    }

    @Test func `git working trees and walked packages are excluded from candidates`() throws {
        let fixture = try FixtureBuilder(name: "SizeIndexGit")
        let inRepo = try fixture.file("Documents/repo/assets/a.bin", size: 2_000_000)
        try fixture.folder("Documents/repo/.git")
        let inPackage = try fixture.file("Documents/Thing.custompkg/a.bin", size: 2_000_000)
        let loose = try fixture.file("Documents/a.bin", size: 2_000_000)
        let other = try fixture.file("Desktop/a.bin", size: 2_000_000)

        var index = SizeIndex(roots: [fixture.root])
        try index.add(contentsOf: Support.entries([inRepo, inPackage, loose, other]))
        try index.add(FileEntry(
            url: fixture.url("Documents/Thing.custompkg"), kind: .package, logicalSize: 0, allocatedSize: 0,
            privateSize: nil, linkCount: 1, inode: 99, device: 1, flags: 0, created: nil, modified: nil, ownerUID: 501,
        ))

        let buckets = index.duplicateCandidates(minSize: 1_000_000, roots: [fixture.root])
        #expect(buckets.map { Set($0.map(\.url)) } == [[loose, other]])
    }

    @Test func `protection policy denies entries`() throws {
        let fixture = try FixtureBuilder(name: "SizeIndexPolicy")
        let urls = try ["Documents/a.bin", "Desktop/a.bin", "Movies/secret.bin"].map { try fixture.file($0, size: 2_000_000) }
        var index = SizeIndex(options: Support.options(fixture), protectionPolicy: DenyPolicy(deniedName: "secret.bin"))
        try index.add(contentsOf: Support.entries(urls))
        let buckets = index.duplicateCandidates(minSize: 1_000_000, roots: [])
        #expect(buckets.map { Set($0.map(\.url)) } == [[urls[0], urls[1]]])
    }

    @Test func `same inode entries collapse and singleton buckets are dropped`() {
        var index = SizeIndex(roots: [URL(filePath: "/msfixture")])
        index.add(Support.syntheticEntry("/msfixture/a.bin", inode: 1))
        index.add(Support.syntheticEntry("/msfixture/b/a-link.bin", inode: 1))
        index.add(Support.syntheticEntry("/msfixture/lonely.bin", size: 3_000_000, inode: 2))
        #expect(index.duplicateCandidates(minSize: 1_000_000, roots: []).isEmpty)
        index.add(Support.syntheticEntry("/msfixture/c.bin", inode: 3))
        let buckets = index.duplicateCandidates(minSize: 1_000_000, roots: [])
        #expect(buckets.map { $0.map(\.url.lastPathComponent) } == [["a.bin", "c.bin"]])
    }

    @Test func `finder options narrow roots and min size`() {
        var index = SizeIndex(roots: [URL(filePath: "/msfixture")], minSize: 100_000)
        index.add(Support.syntheticEntry("/msfixture/Documents/a.bin", size: 500_000, inode: 1))
        index.add(Support.syntheticEntry("/msfixture/Desktop/a.bin", size: 500_000, inode: 2))
        index.add(Support.syntheticEntry("/msfixture/Documents/b.bin", size: 2_000_000, inode: 3))
        index.add(Support.syntheticEntry("/msfixture/Movies/b.bin", size: 2_000_000, inode: 4))
        #expect(index.duplicateCandidates(minSize: 100_000, roots: []).count == 2)
        #expect(index.duplicateCandidates(minSize: 1_000_000, roots: []).count == 1)
        #expect(index.duplicateCandidates(minSize: 100_000, roots: [URL(filePath: "/msfixture/Documents")]).isEmpty)
    }
}
