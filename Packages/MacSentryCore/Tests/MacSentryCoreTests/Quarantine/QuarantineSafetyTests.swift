import Darwin
import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct QuarantineSafetyTests {
    private func relative(_ url: URL, _ harness: QuarantineHarness) -> String {
        String(url.storagePath.dropFirst(harness.fixture.root.storagePath.count + 1))
    }

    @Test func `crafted manifest with a symlink cannot move a document onto ssh keys`() async throws {
        let harness = try QuarantineHarness()
        let documents = try harness.fixture.folder("home/Documents")
        let secret = try harness.fixture.file("home/Documents/secret.txt", size: 6)
        let secretInode = inode(secret)
        try harness.fixture.folder("home/.ssh")
        let keys = harness.home.appending(path: ".ssh/authorized_keys")
        let name = "2020-01-03_000000"
        let batch = harness.quarantineRoot.appending(path: name, directoryHint: .isDirectory)
        try harness.fixture.symlink("home/MacSentry Quarantine/\(name)/lnk", to: documents)
        let crafted = batch.appending(path: "lnk/secret.txt")
        let mirroredKeys = batch.appending(path: String(keys.storagePath.dropFirst()))
        try harness.fixture.file(relative(mirroredKeys, harness), size: 4)
        try harness.writeManifest(batch: name, entries: [
            (keys.storagePath, crafted.storagePath),
            (keys.storagePath, mirroredKeys.storagePath),
        ])
        let fresh = try Database.inMemory()
        let service = try await harness.makeService(database: fresh, policy: harness.realProvider())

        let report = try await service.reconcileWithReport()
        let summaries = try await service.list()
        #expect(report.skippedEntries == 2)
        #expect(summaries.flatMap(\.entries).isEmpty)

        let batchID = try #require(summaries.first?.batch.id)
        let injected = try [crafted, mirroredKeys].map { url in
            var entry = QuarantineEntry(
                batchID: batchID, originalURL: keys, quarantineURL: url, kind: .file, ruleID: "r", tier: .green,
                size: 1, quarantinedAt: Date(), status: .inQuarantine,
            )
            try fresh.writer.write { try entry.insert($0) }
            return try #require(entry.id)
        }
        let restore = await service.restore(injected)
        let trash = await service.trash([injected[0]])

        #expect(restore.failed.map(\.reason) == [.protected, .protected])
        #expect(trash.failed.map(\.reason) == [.outsideQuarantine])
        #expect(inode(secret) == secretInode)
        #expect(!exists(keys))
        #expect(harness.trashContents().isEmpty)
    }

    @Test func `mirrored parent swapped for a symlink is never trashed or restored through`() async throws {
        let harness = try QuarantineHarness()
        let cache = try harness.fixture.folder("home/Library/Caches/app")
        try harness.fixture.file("home/Library/Caches/app/blob.bin", size: 4096)
        let service = try await harness.makeService(policy: harness.realProvider())
        let result = try await service.quarantine([harness.candidate(cache)])
        let entry = try #require(result.moved.first)
        let entryID = try #require(entry.id)
        let mirroredParent = entry.quarantineURL.deletingLastPathComponent()
        _ = try harness.moveAway(mirroredParent, as: "Caches")
        let documents = try harness.fixture.folder("home/Documents")
        let precious = try harness.fixture.file("home/Documents/app/precious.txt", size: 10)
        try harness.fixture.symlink(relative(mirroredParent, harness), to: documents)

        let trash = await service.trash([entryID])
        let restore = await service.restore([entryID])

        #expect(trash.failed.map(\.reason) == [.outsideQuarantine])
        #expect(restore.failed.map(\.reason) == [.outsideQuarantine])
        #expect(exists(precious))
        #expect(!exists(cache))
        #expect(harness.trashContents().isEmpty)
        #expect(try harness.entry(entryID)?.status == .inQuarantine)
    }

    @Test func `end to end with the real provider refuses restore into a newly protected location`() async throws {
        let harness = try QuarantineHarness()
        let kept = try harness.fixture.folder("home/Library/Caches/kept")
        let ignored = try harness.fixture.folder("home/Library/Caches/ignored")
        let ssh = try harness.fixture.folder("home/.ssh")
        let ignoredStore = InMemoryIgnoredPathStore()
        let provider = try ProtectionPolicyProvider(
            homeURL: harness.home,
            databaseURL: harness.fixture.url("db/macsentry.sqlite"),
            neverTouchStore: InMemoryNeverTouchStore(),
            ignoredPathStore: ignoredStore,
        )
        try await provider.refresh()
        let service = harness.makeService(policy: provider)
        let result = try await service.quarantine([harness.candidate(kept), harness.candidate(ignored), harness.candidate(ssh)])
        #expect(result.failed == [QuarantineFailure(path: ssh, reason: .protected)])
        let ids = try result.moved.map { try #require($0.id) }

        await ignoredStore.add(ignored)
        try await provider.refresh()
        let restore = await service.restore(ids)
        let trash = await service.trash([ids[1]])

        #expect(restore.restored.map(\.originalURL.storagePath) == [kept.storagePath])
        #expect(restore.failed.map(\.reason) == [.protected])
        #expect(exists(kept))
        #expect(!exists(ignored))
        #expect(trash.trashed.map(\.status) == [.trashed])
        #expect(harness.trashContents().count == 2)
    }

    @Test func `protection that changes during the size check stops the move`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/flip")
        try harness.fixture.file("home/Library/Caches/flip/a.bin", size: 4096)
        let policy = SwitchablePolicy()
        let service = harness.makeService(policy: policy, sizeCalculator: HookedSizeCalculator { _ in policy.deny() })

        let result = try await service.quarantine([harness.candidate(folder)])

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .protected)])
        #expect(result.batchID == nil)
        #expect(exists(folder.appending(path: "a.bin")))
    }

    @Test func `item locked during the size check fails with locked`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/lockme")
        try harness.fixture.file("home/Library/Caches/lockme/a.bin", size: 4096)
        let path = folder.path(percentEncoded: false)
        defer { chflags(path, 0) }
        let service = harness.makeService(sizeCalculator: HookedSizeCalculator { _ in _ = chflags(path, UInt32(UF_IMMUTABLE)) })

        let result = try await service.quarantine([harness.candidate(folder)])

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .locked)])
        #expect(exists(folder.appending(path: "a.bin")))
    }

    @Test func `item swapped for a symlink during the size check is not moved`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/swap")
        try harness.fixture.file("home/Library/Caches/swap/a.bin", size: 4096)
        let away = try harness.fixture.url("elsewhere/swap")
        let fixture = harness.fixture
        let service = harness.makeService(sizeCalculator: HookedSizeCalculator { url in
            try? FileManager.default.createDirectory(at: away.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: url, to: away)
            _ = try? fixture.symlink("home/Library/Caches/swap", to: away)
        })

        let result = try await service.quarantine([harness.candidate(folder)])

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .changedSinceScan)])
        #expect(lstatInfo(folder).map { $0.st_mode & S_IFMT == S_IFLNK } == true)
    }

    @Test func `reconcile keeps status when the quarantine path cannot be checked`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/sealed")
        let service = harness.makeService()
        let entry = try await #require(service.quarantine([harness.candidate(folder)]).moved.first)
        let parent = entry.quarantineURL.deletingLastPathComponent().path(percentEncoded: false)
        #expect(chmod(parent, 0) == 0)
        defer { chmod(parent, 0o755) }

        try await service.reconcile()

        #expect(try harness.entry(entry.id)?.status == .inQuarantine)
    }

    @Test func `reconcile brings a missing entry back when the item returns`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/roundtrip")
        let service = harness.makeService()
        let entry = try await #require(service.quarantine([harness.candidate(folder)]).moved.first)
        let away = try harness.moveAway(entry.quarantineURL, as: "roundtrip")
        let first = try await service.reconcileWithReport()
        #expect(try harness.entry(entry.id)?.status == .missing)

        try FileManager.default.moveItem(at: away, to: entry.quarantineURL)
        let second = try await service.reconcileWithReport()

        #expect(first.markedMissing == 1)
        #expect(second.recovered == 1)
        #expect(try harness.entry(entry.id)?.status == .inQuarantine)
        #expect(try harness.manifest(in: harness.batchFolder(entry.batchID)).entries.map(\.status) == [.inQuarantine])
    }

    @Test func `journal keeps moved items recoverable without a manifest`() async throws {
        let harness = try QuarantineHarness()
        let urls = try (0 ..< 3).map { try harness.fixture.file("home/Caches/j\($0).bin", size: 1) }
        let result = try await harness.makeService().quarantine(urls.map { try harness.candidate($0, kind: .file) })
        let folder = try harness.batchFolder(result.batchID)
        let journal = try String(contentsOf: folder.appending(path: "journal.jsonl"), encoding: .utf8)
        #expect(journal.split(separator: "\n").count == 3)
        _ = try harness.moveAway(folder.appending(path: "manifest.json"), as: "manifest.json")

        let service = try harness.makeService(database: Database.inMemory())
        try await service.reconcile()

        let entries = try await service.list().flatMap(\.entries)
        #expect(entries.map(\.quarantineURL.storagePath) == result.moved.map(\.quarantineURL.storagePath))
        #expect(entries.allSatisfy { $0.status == .inQuarantine })
    }

    @Test func `failed database insert moves the item back and journals the revert`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/revert")
        let originalInode = inode(folder)
        let candidate = try harness.candidate(folder)
        try await harness.database.writer.write {
            try $0.execute(sql: "CREATE TRIGGER boom BEFORE INSERT ON quarantine_entry BEGIN SELECT RAISE(ABORT, 'boom'); END")
        }

        let result = await harness.makeService(now: { QuarantineHarness.fixedDate }).quarantine([candidate])

        #expect(result.failed == [QuarantineFailure(path: folder, reason: .unknown)])
        #expect(inode(folder) == originalInode)
        let journal = harness.quarantineRoot.appending(path: "2025-10-29_064512/journal.jsonl")
        let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        let statuses = try lines.map { try JSONDecoder().decode(QuarantineManifest.Entry.self, from: Data($0.utf8)).status }
        #expect(statuses == [.inQuarantine, .restored])
        let recovered = try harness.makeService(database: Database.inMemory())
        try await recovered.reconcile()
        #expect(try await recovered.list().isEmpty)
    }

    @Test func `trash during a running batch keeps the batch folder and the final manifest`() async throws {
        let harness = try QuarantineHarness()
        let file = try harness.fixture.file("home/Caches/first.bin", size: 4096)
        let folder = try harness.fixture.folder("home/Caches/second")
        try harness.fixture.file("home/Caches/second/a.bin", size: 4096)
        let database = harness.database
        let box = Mutex<DefaultQuarantineService?>(nil)
        let service = harness.makeService(sizeCalculator: HookedSizeCalculator { _ in
            guard let service = box.withLock({ $0 }),
                  let id = try? await database.writer.read({ try Int64.fetchOne($0, sql: "SELECT MIN(id) FROM quarantine_entry") })
            else { return }
            _ = await service.trash([id])
        })
        box.withLock { $0 = service }

        let result = try await service.quarantine([harness.candidate(file, kind: .file), harness.candidate(folder)])

        let batchFolder = try harness.batchFolder(result.batchID)
        #expect(result.moved.count == 2)
        #expect(exists(result.moved[1].quarantineURL))
        #expect(try harness.manifest(in: batchFolder).entries.map(\.status) == [.trashed, .inQuarantine])
    }

    @Test func `reconcile reports untracked content and leaves it in place`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/tracked")
        let service = harness.makeService()
        let entry = try await #require(service.quarantine([harness.candidate(folder)]).moved.first)
        let batchFolder = try harness.batchFolder(entry.batchID)
        let stray = try harness.fixture.file(relative(batchFolder.appending(path: "stray.txt"), harness), size: 3)
        try harness.fixture.folder(relative(batchFolder.appending(path: "empty/mirror"), harness))
        let unknown = try harness.fixture.folder("home/MacSentry Quarantine/unknown")
        try harness.fixture.file("home/MacSentry Quarantine/unknown/x.bin", size: 1)

        let report = try await service.reconcileWithReport()

        #expect(report.untracked.map(\.storagePath) == [stray.storagePath, unknown.storagePath])
        #expect(exists(stray))
        #expect(exists(unknown.appending(path: "x.bin")))
        #expect(exists(entry.quarantineURL))
    }

    @Test func `dry run reconcile never rewrites a real manifest`() async throws {
        let harness = try QuarantineHarness()
        let folder = try harness.fixture.folder("home/Library/Caches/dry")
        let entry = try await #require(harness.makeService().quarantine([harness.candidate(folder)]).moved.first)
        let manifestURL = try harness.batchFolder(entry.batchID).appending(path: "manifest.json")
        let before = try Data(contentsOf: manifestURL)
        _ = try harness.moveAway(entry.quarantineURL, as: "dry")

        try await harness.makeService(isDryRun: true).reconcile()

        #expect(try Data(contentsOf: manifestURL) == before)
    }
}
