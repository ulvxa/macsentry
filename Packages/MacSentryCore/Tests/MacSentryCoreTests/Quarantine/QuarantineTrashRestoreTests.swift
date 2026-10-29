import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct QuarantineTrashRestoreTests {
    private func quarantined(
        _ harness: QuarantineHarness,
        _ paths: [String],
        sizes: [Int64]? = nil,
    ) async throws -> (DefaultQuarantineService, QuarantineResult) {
        var candidates: [Candidate] = []
        for (index, path) in paths.enumerated() {
            let folder = try harness.fixture.folder(path)
            try harness.fixture.file("\(path)/payload.bin", size: 4096)
            try candidates.append(harness.candidate(folder, freeable: sizes?[index] ?? 1000))
        }
        let service = harness.makeService()
        let result = await service.quarantine(candidates)
        try #require(result.moved.count == paths.count)
        return (service, result)
    }

    @Test func `move to trash lands item in fixture trash and marks it trashed`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Caches/Homebrew"])
        let entry = try #require(result.moved.first)
        let batchFolder = try harness.batchFolder(result.batchID)

        let trash = try await service.trash([#require(entry.id)])

        #expect(trash.failed.isEmpty)
        let trashed = try #require(try harness.entry(entry.id))
        #expect(trashed.status == .trashed)
        #expect(trashed.trashedAt != nil)
        let trashURL = try #require(trashed.trashURL)
        #expect(trashURL.storagePath.hasPrefix(harness.trashDirectory.storagePath + "/"))
        #expect(exists(trashURL.appending(path: "payload.bin")))
        #expect(!exists(entry.quarantineURL))
        #expect(try harness.candidateStatus(entry.candidateID) == .trashed)

        #expect(!exists(batchFolder))
        let trashedBatch = try #require(harness.trashContents().first { $0.hasSuffix(batchFolder.lastPathComponent) })
        let trashedBatchURL = harness.trashDirectory.appending(path: trashedBatch)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: trashedBatchURL.path(percentEncoded: false))
        #expect(leftovers.sorted() == ["journal.jsonl", "manifest.json"])
        #expect(try harness.manifest(in: trashedBatchURL).entries.map(\.status) == [.trashed])
    }

    @Test func `partially trashed batch keeps folder and updates manifest`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Caches/a", "home/Library/Caches/b"])
        let batchFolder = try harness.batchFolder(result.batchID)

        _ = try await service.trash([#require(result.moved[0].id)])

        #expect(exists(batchFolder))
        #expect(exists(result.moved[1].quarantineURL))
        #expect(try harness.manifest(in: batchFolder).entries.map(\.status) == [.trashed, .inQuarantine])
    }

    @Test func `restore puts item back at its original path`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Developer/Xcode/DerivedData"])
        let entry = try #require(result.moved.first)
        let quarantinedInode = inode(entry.quarantineURL)
        let batchFolder = try harness.batchFolder(result.batchID)
        let parent = entry.originalURL.deletingLastPathComponent()
        _ = try harness.moveAway(parent, as: "Xcode")

        let restore = try await service.restore([#require(entry.id)])

        #expect(restore.failed.isEmpty)
        #expect(restore.restored.map(\.status) == [.restored])
        #expect(inode(entry.originalURL) == quarantinedInode)
        #expect(exists(entry.originalURL.appending(path: "payload.bin")))
        #expect(try harness.entry(entry.id)?.status == .restored)
        #expect(try harness.candidateStatus(entry.candidateID) == .found)
        #expect(!exists(batchFolder))
    }

    @Test func `restore refuses when something now exists at the original path`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Caches/again"])
        let entry = try #require(result.moved.first)
        let entryID = try #require(entry.id)
        try harness.fixture.folder("home/Library/Caches/again")

        let restore = await service.restore([entryID])

        #expect(restore.failed == [EntryFailure(entryID: entryID, path: entry.originalURL, reason: .destinationExists)])
        #expect(exists(entry.quarantineURL))
        #expect(try harness.entry(entryID)?.status == .inQuarantine)
    }

    @Test func `trashed or unknown entries cannot be restored or trashed again`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Caches/once"])
        let entry = try #require(result.moved.first)
        let entryID = try #require(entry.id)
        _ = await service.trash([entryID])

        let restore = await service.restore([entryID, 9999])
        let trashAgain = await service.trash([entryID])

        #expect(restore.failed == [
            EntryFailure(entryID: entryID, path: entry.originalURL, reason: .alreadyTrashed),
            EntryFailure(entryID: 9999, path: nil, reason: .notFound),
        ])
        #expect(trashAgain.failed.map(\.reason) == [.alreadyTrashed])
    }

    @Test func `trashing a vanished item marks it missing`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Library/Caches/vanish"])
        let entry = try #require(result.moved.first)
        _ = try harness.moveAway(entry.quarantineURL, as: "vanish")

        let trash = try await service.trash([#require(entry.id)])

        #expect(trash.failed.map(\.reason) == [.missing])
        #expect(try harness.entry(entry.id)?.status == .missing)
        #expect(harness.trashContents().count == 1)
    }

    @Test func `dry run service refuses to touch real entries`() async throws {
        let harness = try QuarantineHarness()
        let (_, result) = try await quarantined(harness, ["home/Library/Caches/real"])
        let entry = try #require(result.moved.first)

        let trash = try await harness.makeService(isDryRun: true).trash([#require(entry.id)])

        #expect(trash.failed.map(\.reason) == [.dryRunMode])
        #expect(exists(entry.quarantineURL))
        #expect(!exists(harness.trashDirectory))
    }

    @Test func `totals split quarantine trash and freed this month`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(
            harness,
            ["home/Caches/a", "home/Caches/b", "home/Caches/c"],
            sizes: [100, 200, 400],
        )
        let ids = try result.moved.map { try #require($0.id) }
        _ = await service.trash([ids[0], ids[1]])
        let emptied = try #require(try harness.entry(ids[1])?.trashURL)
        _ = try harness.moveAway(emptied, as: "emptied")

        let totals = try await service.totals()

        #expect(totals == QuarantineTotals(inQuarantine: 400, inTrash: 100, freedThisMonth: 200, dryRunInQuarantine: 0))
    }

    @Test func `list summarizes batches with item count size and tiers`() async throws {
        let harness = try QuarantineHarness()
        let service = harness.makeService(now: { QuarantineHarness.fixedDate })
        let green = try harness.candidate(harness.fixture.folder("home/Caches/green"), tier: .green, freeable: 10)
        let yellow = try harness.candidate(harness.fixture.folder("home/Caches/yellow"), tier: .yellow, freeable: 20)
        let later = try harness.candidate(harness.fixture.folder("home/Caches/later"), tier: .red, freeable: 5)
        _ = await service.quarantine([green, yellow])
        _ = await service.quarantine([later])

        let summaries = try await service.list()

        #expect(summaries.map(\.id) == ["2025-10-29_064512-2", "2025-10-29_064512"])
        let first = try #require(summaries.last)
        #expect(first.itemCount == 2)
        #expect(first.totalSize == 30)
        #expect(first.tiers == [.green: TierTotal(count: 1, size: 10), .yellow: TierTotal(count: 1, size: 20)])
        #expect(first.entries.map(\.originalURL.storagePath) == [green.url.storagePath, yellow.url.storagePath])
        #expect(summaries.allSatisfy { !$0.isDryRun })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACSENTRY_REAL_TRASH"] == "1"))
    func `system trasher moves a tiny temp file into the real Trash`() throws {
        let fixture = try FixtureBuilder(name: "RealTrash")
        let file = try fixture.file("macsentry-real-trash-test.txt", size: 16)

        let resulting = try SystemTrasher().trash(file)

        #expect(!exists(file))
        #expect(try exists(#require(resulting)))
    }
}
