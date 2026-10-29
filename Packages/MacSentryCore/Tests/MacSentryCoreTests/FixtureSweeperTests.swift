import Foundation
import Testing
@testable import MacSentryTestSupport

struct FixtureSweeperTests {
    @Test func `sweep removes only stale fixture folders`() throws {
        let manager = FileManager.default
        let base = FixtureSweeper.base
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let stale = base.appending(path: "Stale-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fresh = base.appending(path: "Fresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        let foreign = base.appending(path: "not-a-fixture-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        for folder in [stale, fresh, foreign] {
            try manager.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        }
        let locked = stale.appending(path: "nested/locked")
        try Data("x".utf8).write(to: locked)
        chflags(locked.path(percentEncoded: false), UInt32(UF_IMMUTABLE))
        chmod(stale.appending(path: "nested").path(percentEncoded: false), 0o500)
        var old = URLResourceValues()
        old.creationDate = Date(timeIntervalSinceNow: -7200)
        var staleURL = stale
        try staleURL.setResourceValues(old)
        var foreignURL = foreign
        try foreignURL.setResourceValues(old)

        FixtureSweeper.sweep(olderThan: 3600)

        #expect(!manager.fileExists(atPath: stale.path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: fresh.path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: foreign.path(percentEncoded: false)))
    }

    @Test func `symlinks and folders outside the fixture base are never sweepable`() throws {
        let fixture = try FixtureBuilder(name: "SweepGuard")
        let outside = try fixture.folder("Outside-\(UUID().uuidString)")
        let link = FixtureSweeper.base.appending(path: "Link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let future = Date(timeIntervalSinceNow: 86400)
        #expect(!FixtureSweeper.isSweepable(link, base: FixtureSweeper.base, olderThan: 0, now: future))
        #expect(!FixtureSweeper.isSweepable(outside, base: FixtureSweeper.base, olderThan: 0, now: future))
    }
}
