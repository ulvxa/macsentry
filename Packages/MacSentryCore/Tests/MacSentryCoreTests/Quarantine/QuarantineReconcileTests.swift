import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct QuarantineReconcileTests {
    private func quarantined(_ harness: QuarantineHarness, _ paths: [String]) async throws -> (DefaultQuarantineService, QuarantineResult) {
        let candidates = try paths.map { try harness.candidate(harness.fixture.folder($0), ruleID: "rule.\($0.count)") }
        let service = harness.makeService()
        let result = await service.quarantine(candidates)
        try #require(result.moved.count == paths.count)
        return (service, result)
    }

    @Test func `reconcile marks entries missing after the user moves them out`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Caches/kept", "home/Caches/taken"])
        _ = try harness.moveAway(result.moved[1].quarantineURL, as: "taken")

        try await service.reconcile()

        #expect(try harness.entry(result.moved[0].id)?.status == .inQuarantine)
        #expect(try harness.entry(result.moved[1].id)?.status == .missing)
        #expect(try harness.manifest(in: harness.batchFolder(result.batchID)).entries.map(\.status) == [.inQuarantine, .missing])
    }

    @Test func `reconcile survives the quarantine folder being deleted`() async throws {
        let harness = try QuarantineHarness()
        let (service, result) = try await quarantined(harness, ["home/Caches/a", "home/Caches/b"])
        _ = try harness.moveAway(harness.quarantineRoot, as: "Quarantine")

        try await service.reconcile()

        #expect(try result.moved.map { try harness.entry($0.id)?.status } == [.missing, .missing])
        #expect(try await service.totals().inQuarantine == 0)
    }

    @Test func `reconcile rebuilds entries from manifests into an empty database`() async throws {
        let harness = try QuarantineHarness()
        let (_, result) = try await quarantined(harness, ["home/Caches/one", "home/Caches/two"])
        let fresh = try Database.inMemory()
        let service = harness.makeService(database: fresh)

        try await service.reconcile()
        try await service.reconcile()

        let summaries = try await service.list()
        let summary = try #require(summaries.first)
        #expect(summaries.count == 1)
        #expect(try summary.batch.folderName == harness.batchFolder(result.batchID).lastPathComponent)
        #expect(summary.entries.map(\.originalURL) == result.moved.map(\.originalURL))
        #expect(summary.entries.map(\.quarantineURL) == result.moved.map(\.quarantineURL))
        #expect(summary.entries.map(\.ruleID) == result.moved.map(\.ruleID))
        #expect(summary.entries.map(\.size) == result.moved.map(\.size))
        #expect(summary.entries.allSatisfy { $0.status == .inQuarantine && $0.candidateID == nil })

        let restored = try await service.restore([#require(summary.entries.first?.id)])
        #expect(restored.failed.isEmpty)
        #expect(exists(result.moved[0].originalURL))
    }

    @Test func `reconcile skips unreadable and tampered manifests`() async throws {
        let harness = try QuarantineHarness()
        try harness.fixture.file("home/MacSentry Quarantine/2020-01-01_000000/manifest.json", size: 12, fill: 0x7B)
        let outside = try harness.fixture.folder("home/Documents")
        let tampered = """
        {"version":1,"batch":"2020-01-02_000000","createdAt":"2020-01-02T00:00:00Z","dryRun":false,"entries":[
        {"originalPath":"/tmp/x","quarantinePath":"\(outside.storagePath)","kind":"folder","ruleId":"r","tier":"green",
        "size":1,"status":"inQuarantine"}]}
        """
        let tamperedURL = try harness.fixture.url("home/MacSentry Quarantine/2020-01-02_000000/manifest.json")
        try FileManager.default.createDirectory(at: tamperedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(tampered.utf8).write(to: tamperedURL)
        let service = harness.makeService()

        try await service.reconcile()

        let summaries = try await service.list()
        #expect(summaries.map(\.id) == ["2020-01-02_000000"])
        #expect(summaries.first?.entries.isEmpty == true)
        #expect(exists(outside))
    }
}

struct TestQuarantineServiceTests {
    @Test func `double records calls and simulates outcomes`() async throws {
        let blocked = URL(filePath: "/fixture/blocked")
        let service = TestQuarantineService(moveFailures: [blocked: .appRunning])
        let candidates = [
            Candidate(
                sessionID: 1, url: URL(filePath: "/fixture/ok"), kind: .folder, category: .devCache, ruleID: "r",
                tier: .green, action: .quarantine, reason: "x", logicalSize: 5, allocatedSize: 5, freeableSize: 5,
            ),
            Candidate(
                sessionID: 1, url: blocked, kind: .folder, category: .devCache, ruleID: "r",
                tier: .green, action: .quarantine, reason: "x", logicalSize: 5, allocatedSize: 5, freeableSize: 5,
            ),
        ]

        let result = await service.quarantine(candidates)
        let entryID = try #require(result.moved.first?.id)
        let trash = await service.trash([entryID])
        let restore = await service.restore([entryID])

        #expect(result.failed == [QuarantineFailure(path: blocked, reason: .appRunning)])
        #expect(trash.trashed.map(\.status) == [.trashed])
        #expect(restore.failed.map(\.reason) == [.alreadyTrashed])
        #expect(try await service.totals().inTrash == 5)
        #expect(await service.quarantineCalls.count == 1)
    }
}
