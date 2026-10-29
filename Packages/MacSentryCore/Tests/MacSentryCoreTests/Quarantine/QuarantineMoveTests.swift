import Darwin
import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct QuarantineMoveTests {
    @Test func `quarantined folder keeps its inode at the mirrored batch path`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/com.example")
        try harness.fixture.file("home/Library/Caches/com.example/blob.bin", size: 64 * 1024)
        let originalInode = try #require(inode(folder))
        let candidate = try harness.candidate(folder)

        let result = await harness.makeService().quarantine([candidate])

        #expect(result.failed.isEmpty)
        let entry = try #require(result.moved.first)
        let expected = try harness.batchFolder(result.batchID).appending(path: String(folder.storagePath.dropFirst()))
        #expect(harness.quarantineRoot.storagePath == harness.home.storagePath + "/MacSentry Quarantine")
        #expect(entry.quarantineURL.storagePath == expected.storagePath)
        #expect(inode(expected) == originalInode)
        #expect(!exists(folder))
        #expect(try harness.entry(entry.id)?.status == .inQuarantine)
        #expect(try harness.candidateStatus(candidate.id) == .quarantined)
    }

    @Test func `manifest lists every item and quarantine folder is prepared`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/Homebrew")
        try harness.fixture.file("home/Library/Caches/Homebrew/a.tar", size: 8192)
        let file = try harness.fixture.file("home/Downloads/big.dmg", size: 4096)
        let candidates = try [
            harness.candidate(folder, ruleID: "homebrew.cache", tier: .green, freeable: 8192),
            harness.candidate(file, kind: .file, ruleID: "downloads.old", tier: .yellow, freeable: 4096),
        ]

        let result = await harness.makeService(now: { QuarantineHarness.fixedDate }).quarantine(candidates)

        #expect(result.moved.count == 2)
        let batchFolder = try harness.batchFolder(result.batchID)
        #expect(batchFolder.lastPathComponent == "2025-10-29_064512")
        let manifest = try harness.manifest(in: batchFolder)
        #expect(manifest.version == 1)
        #expect(manifest.batch == "2025-10-29_064512")
        #expect(manifest.createdAt == "2025-10-29T06:45:12+01:00")
        #expect(manifest.dryRun == false)
        #expect(manifest.entries.map(\.originalPath) == [folder.storagePath, file.storagePath])
        #expect(manifest.entries.map(\.ruleId) == ["homebrew.cache", "downloads.old"])
        #expect(manifest.entries.map(\.size) == [8192, 4096])
        #expect(manifest.entries.map(\.kind) == [.folder, .file])
        #expect(manifest.entries.map(\.tier) == [.green, .yellow])
        #expect(manifest.entries.allSatisfy { $0.status == .inQuarantine })
        #expect(manifest.entries.map(\.quarantinePath) == result.moved.map(\.quarantineURL.storagePath))

        let json = try String(contentsOf: batchFolder.appending(path: "manifest.json"), encoding: .utf8)
        #expect(json.contains("\"originalPath\" : \"\(folder.storagePath)\""))
        #expect(exists(harness.quarantineRoot.appending(path: ".metadata_never_index")))
        #expect(exists(harness.quarantineRoot.appending(path: "README.txt")))
        let values = try harness.quarantineRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func `item deleted after scan fails with missing while others succeed`() async throws {
        let harness = try QuarantineHarness()
        let first = try harness.fixture.folder("home/Library/Caches/one")
        let gone = try harness.fixture.folder("home/Library/Caches/two")
        let third = try harness.fixture.file("home/Library/Caches/three.log", size: 100)
        let candidates = try [harness.candidate(first), harness.candidate(gone), harness.candidate(third, kind: .file)]
        _ = try harness.moveAway(gone, as: "two")

        let result = await harness.makeService().quarantine(candidates)

        #expect(result.moved.map(\.originalURL.storagePath) == [first.storagePath, third.storagePath])
        #expect(result.failed == [QuarantineFailure(path: gone, reason: .missing)])
        #expect(try harness.candidateStatus(candidates[1].id) == .stale)
        #expect(!exists(first))
        #expect(!exists(third))
    }

    @Test func `protected path is refused and never moved`() async throws {
        let harness = try QuarantineHarness()
        let protected = try harness.fixture.folder("home/.ssh")
        let allowed = try harness.fixture.folder("home/Library/Caches/ok")
        let candidates = try [harness.candidate(protected), harness.candidate(allowed)]

        let result = await harness.makeService(denied: [protected]).quarantine(candidates)

        #expect(result.failed == [QuarantineFailure(path: protected, reason: .protected)])
        #expect(result.moved.count == 1)
        #expect(exists(protected))
        #expect(try harness.candidateStatus(candidates[0].id) == .found)
    }

    @Test func `flag only and quarantine folder items are refused as protected`() async throws {
        let harness = try QuarantineHarness()
        let flagged = try harness.fixture.folder("home/Library/Containers/big")
        let inside = try harness.fixture.folder("home/MacSentry Quarantine/stray")
        let candidates = try [
            harness.candidate(flagged, action: .flagOnly),
            harness.candidate(inside),
            harness.candidate(harness.home),
        ]

        let result = await harness.makeService().quarantine(candidates)

        #expect(result.batchID == nil)
        #expect(result.failed.map(\.reason) == [.protected, .protected, .protected])
        #expect(exists(flagged))
        #expect(exists(inside))
    }

    @Test func `running owning app blocks the move`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/com.tinyspeck.slackmacgap")
        let candidate = try harness.candidate(folder, appBundleID: "com.tinyspeck.slackmacgap")

        let result = await harness.makeService(running: ["com.tinyspeck.slackmacgap"]).quarantine([candidate])

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .appRunning)])
        #expect(result.batchID == nil)
        #expect(exists(folder))
        #expect(!exists(harness.quarantineRoot))
    }

    @Test func `size change beyond ten percent fails with changedSinceScan`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/grows")
        try harness.fixture.file("home/Library/Caches/grows/a.bin", size: 64 * 1024)
        let stable = try harness.fixture.file("home/Library/Caches/stable.bin", size: 64 * 1024)
        let scanned = WalkingSizeCalculator.allocated(stable)
        let candidates = try [
            harness.candidate(folder, allocated: 4096),
            harness.candidate(stable, kind: .file, allocated: scanned + scanned / 20),
        ]

        let result = await harness.makeService().quarantine(candidates)

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .changedSinceScan)])
        #expect(result.moved.map(\.originalURL.storagePath) == [stable.storagePath])
    }

    @Test func `item that became a symlink fails with changedSinceScan`() async throws {
        let harness = try QuarantineHarness()
        let file = try harness.fixture.file("home/Library/Caches/swap.bin", size: 4096)
        let candidate = try harness.candidate(file, kind: .file)
        let moved = try harness.moveAway(file, as: "swap.bin")
        try harness.fixture.symlink("home/Library/Caches/swap.bin", to: moved)

        let result = await harness.makeService().quarantine([candidate])

        #expect(result.failed == [QuarantineFailure(path: file, reason: .changedSinceScan)])
        #expect(lstatInfo(file).map { $0.st_mode & S_IFMT == S_IFLNK } == true)
    }

    @Test func `immutable item fails with locked`() async throws {
        let harness = try QuarantineHarness()
        let file = try harness.fixture.file("home/Library/Caches/locked.bin", size: 4096)
        let candidate = try harness.candidate(file, kind: .file)
        #expect(chflags(file.path(percentEncoded: false), UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path(percentEncoded: false), 0) }

        let result = await harness.makeService().quarantine([candidate])

        #expect(result.failed == [QuarantineFailure(path: file, reason: .locked)])
        #expect(exists(file))
    }

    @Test func `destination longer than PATH_MAX fails with unknown`() async throws {
        let harness = try QuarantineHarness()
        let segment = String(repeating: "d", count: 200)
        let relative = "home/" + Array(repeating: segment, count: 4).joined(separator: "/") + "/f.bin"
        let file = try harness.fixture.file(relative, size: 10)
        let candidate = try harness.candidate(file, kind: .file)

        let result = await harness.makeService().quarantine([candidate])

        #expect(result.failed == [QuarantineFailure(path: file, reason: .unknown)])
        #expect(result.batchID == nil)
        #expect(exists(file))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: harness.quarantineRoot.path(percentEncoded: false))
        #expect(Set(leftovers) == [".metadata_never_index", "README.txt"])
    }

    @Test func `batch folder names get a suffix on collision`() async throws {
        let harness = try QuarantineHarness()
        let service = harness.makeService(now: { QuarantineHarness.fixedDate })
        let first = try harness.candidate(harness.fixture.folder("home/Library/Caches/a"))
        let second = try harness.candidate(harness.fixture.folder("home/Library/Caches/b"))

        let one = await service.quarantine([first])
        let two = await service.quarantine([second])

        #expect(try harness.batchFolder(one.batchID).lastPathComponent == "2025-10-29_064512")
        #expect(try harness.batchFolder(two.batchID).lastPathComponent == "2025-10-29_064512-2")
    }

    @Test func `progress is reported per item and manifest flushes every hundred`() async throws {
        let harness = try QuarantineHarness()
        var candidates: [Candidate] = []
        for index in 0 ..< 150 {
            try candidates.append(harness.candidate(harness.fixture.file("home/Caches/f\(index).bin", size: 1), kind: .file))
        }
        let recorder = Recorder<(Int, Int?)>()
        let root = harness.quarantineRoot

        let result = await harness.makeService().quarantine(candidates) { progress in
            var flushed: Int?
            if progress.completed == 100 || progress.completed == 99 {
                let batches = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                let manifests = batches.compactMap { try? Data(contentsOf: $0.appending(path: "manifest.json")) }
                flushed = manifests.first.flatMap { try? QuarantineManifest.decode($0).entries.count } ?? 0
            }
            recorder.append((progress.completed, flushed))
        }

        #expect(result.moved.count == 150)
        #expect(recorder.values.map(\.0) == Array(1 ... 150))
        #expect(recorder.values.first { $0.0 == 99 }?.1 == 0)
        #expect(recorder.values.first { $0.0 == 100 }?.1 == 100)
        #expect(try harness.manifest(in: harness.batchFolder(result.batchID)).entries.count == 150)
    }

    @Test func `dry run moves nothing and writes nothing to disk`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/dry")
        try harness.fixture.file("home/Library/Caches/dry/x.bin", size: 4096)
        let originalInode = inode(folder)
        let candidate = try harness.candidate(folder, freeable: 4096)
        let service = harness.makeService(isDryRun: true)

        let result = await service.quarantine([candidate])

        let entry = try #require(result.moved.first)
        #expect(try harness.batch(result.batchID)?.dryRun == true)
        #expect(inode(folder) == originalInode)
        #expect(!exists(entry.quarantineURL))
        #expect(!exists(harness.quarantineRoot))
        #expect(try await service.totals() == QuarantineTotals(inQuarantine: 0, inTrash: 0, freedThisMonth: 0, dryRunInQuarantine: 4096))

        let trashed = try await service.trash([#require(entry.id)])
        #expect(trashed.trashed.map(\.status) == [.trashed])
        #expect(exists(folder))
        #expect(!exists(harness.trashDirectory))
        #expect(!exists(harness.quarantineRoot))
    }

    @Test func `move failure maps errno to reasons with messages`() {
        #expect(MoveFailure(errno: EXDEV) == .crossDevice)
        #expect(MoveFailure(errno: EACCES) == .permissionDenied)
        #expect(MoveFailure(errno: EPERM) == .permissionDenied)
        #expect(MoveFailure(errno: EEXIST) == .destinationExists)
        #expect(MoveFailure(errno: ENOENT) == .missing)
        #expect(MoveFailure(errno: ENAMETOOLONG) == .unknown)
        #expect(MoveFailure.allCases.allSatisfy { !($0.errorDescription ?? "").isEmpty })
        #expect(EntryFailureReason.allCases.allSatisfy { !($0.errorDescription ?? "").isEmpty })
    }
}
