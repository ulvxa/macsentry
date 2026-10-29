import Foundation
import Testing
@testable import MacSentry

struct FinderTargetTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FinderTargetTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @Test func `existing item is selected`() throws {
        let root = try makeRoot()
        let file = root.appending(path: "a b é.txt")
        try Data().write(to: file)
        let plan = FinderTarget.plan(for: [file])
        #expect(plan.select.map(\.lastPathComponent) == ["a b é.txt"])
        #expect(plan.openFolders.isEmpty)
    }

    @Test func `missing item opens nearest existing ancestor`() throws {
        let root = try makeRoot()
        let existing = root.appending(path: "Caches")
        try makeDir(existing)
        let missing = existing.appending(path: "gone/deeper/file.bin")
        let plan = FinderTarget.plan(for: [missing])
        #expect(plan.select.isEmpty)
        #expect(plan.openFolders.map(\.path) == [FinderTarget.normalized(existing).path])
    }

    @Test func `ancestors are deduplicated`() throws {
        let root = try makeRoot()
        let plan = FinderTarget.plan(for: [root.appending(path: "x/1"), root.appending(path: "x/2")])
        #expect(plan.openFolders.count == 1)
    }

    @Test func `symlinked parents resolve`() throws {
        let root = try makeRoot()
        let real = root.appending(path: "real")
        try makeDir(real)
        let file = real.appending(path: "f.txt")
        try Data().write(to: file)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let viaLink = link.appending(path: "f.txt")
        let plan = FinderTarget.plan(for: [viaLink])
        #expect(plan.select.map(\.path) == [FinderTarget.normalized(file).path])
    }

    @Test func `symlink item is not followed`() throws {
        let root = try makeRoot()
        let target = root.appending(path: "target")
        try makeDir(target)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(FinderTarget.normalized(link).lastPathComponent == "link")
    }

    @Test func `tmp and private tmp normalize to the same URL`() {
        #expect(FinderTarget.normalized(URL(filePath: "/tmp/x")).path == FinderTarget.normalized(URL(filePath: "/private/tmp/x")).path)
        #expect(FinderTarget.normalized(URL(filePath: "/var/folders")).path == FinderTarget
            .normalized(URL(filePath: "/private/var/folders")).path)
    }

    @Test func `package is selected as a whole and inside paths use the injected check`() {
        let app = URL(filePath: "/Applications/Foo.app")
        let inside = app.appending(path: "Contents/Resources/gone.bin")
        let known: Set = ["/Applications", "/Applications/Foo.app", "/Applications/Foo.app/Contents"]
        let exists: (URL) -> Bool = { known.contains($0.path) }
        #expect(FinderTarget.plan(for: [app], exists: exists).select.map(\.path) == ["/Applications/Foo.app"])
        #expect(FinderTarget.nearestExisting(inside, exists: exists).path == "/Applications/Foo.app/Contents")
    }

    @Test func `nothing existing falls back to root`() {
        #expect(FinderTarget.nearestExisting(URL(filePath: "/nope/a/b"), exists: { $0.path == "/" }).path == "/")
        #expect(FinderTarget.nearestExisting(URL(filePath: "/nope"), exists: { _ in false }).path == "/")
    }

    @Test func `chain runs from root to item`() {
        let chain = FinderTarget.chain(of: URL(filePath: "/Users/me/Library/Caches"))
        #expect(chain.map(\.path) == ["/", "/Users", "/Users/me", "/Users/me/Library", "/Users/me/Library/Caches"])
        #expect(FinderTarget.displayName(of: chain[0]) == "Macintosh HD")
        #expect(FinderTarget.displayName(of: chain[4]) == "Caches")
    }
}
