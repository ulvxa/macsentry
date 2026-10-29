import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PipelineRuleTests {
    private typealias Harness = PipelineHarness

    @Test func `derived data becomes one green dev cache candidate for the whole folder`() async throws {
        let harness = try Harness("DerivedData")
        try harness.fixture.file("Library/Developer/Xcode/DerivedData/Foo/blob", size: Harness.megabyte)
        try harness.fixture.file("Library/Developer/Xcode/DerivedData/Bar/Build/out.o", size: 4096)

        let summary = try await harness.scan()
        #expect(summary.status == .finished)
        let derived = harness.url("Library/Developer/Xcode/DerivedData")
        let candidates = try await harness.candidates(summary.sessionID)
        let candidate = try #require(candidates.first { $0.ruleID == "xcode.derivedData" })
        #expect(candidate.url.storagePath == derived.storagePath)
        #expect(candidate.category == .devCache)
        #expect(candidate.tier == .green)
        #expect(candidate.action == .quarantine)
        #expect(candidate.kind == .folder)
        #expect(candidate.freeableSize >= Harness.megabyte + 4096)
        #expect(candidates.filter { $0.url.storagePath.hasPrefix(derived.storagePath + "/") }.isEmpty)
        #expect(candidates.count(where: { $0.url.storagePath == derived.storagePath }) == 1)
    }

    @Test func `disabled rule groups produce no candidates`() async throws {
        let harness = try Harness("DisabledGroup")
        try harness.fixture.file("Library/Developer/Xcode/DerivedData/Foo/blob", size: Harness.megabyte)

        let summary = try await harness.scan(ScanPipelineOptions(disabledGroups: ["Xcode"]))
        #expect(try await harness.candidates(summary.sessionID).allSatisfy { !$0.ruleID.hasPrefix("xcode.") })
    }

    @Test func `docker disk image is flagged with its command and never quarantined`() async throws {
        let harness = try Harness("Docker")
        let raw = try harness.fixture.sparseFile(
            "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            logicalSize: 8 << 30,
            modified: Harness.old,
        )

        let summary = try await harness.scan(ScanPipelineOptions(thresholds: Thresholds(minSize: 1)))
        let candidates = try await harness.candidates(summary.sessionID)
        let docker = try #require(candidates.first { $0.url.storagePath == raw.storagePath })
        #expect(docker.ruleID == "docker.vmDisk")
        #expect(docker.category == .flagged)
        #expect(docker.action == .flagOnly)
        #expect(docker.cliCommand?.contains("docker system prune") == true)
        #expect(docker.appBundleID == "com.docker.docker")
        let container = harness.url("Library/Containers/com.docker.docker").storagePath
        let quarantinable = candidates.filter { $0.action == .quarantine }.map(\.url.storagePath)
        #expect(quarantinable.allSatisfy { !raw.storagePath.hasPrefix($0) && !$0.hasPrefix(container) })
    }

    @Test func `raising the minimum size removes smaller old and large candidates on rescan`() async throws {
        let harness = try Harness("MinSize")
        let backup = try harness.fixture.file("Archive/backup.bin", size: 600_000_000, created: Harness.old, modified: Harness.old)

        let first = try await harness.scan(ScanPipelineOptions(thresholds: Thresholds(minSize: 500_000_000, largeFileMinSize: 0)))
        let oldLarge = try await harness.candidates(first.sessionID, in: .oldLarge)
        #expect(oldLarge.map(\.url.storagePath) == [backup.storagePath])
        #expect(oldLarge.first?.tier == .red)

        let second = try await harness.scan(ScanPipelineOptions(thresholds: Thresholds(minSize: 5_000_000_000, largeFileMinSize: 0)))
        #expect(try await harness.candidates(second.sessionID, in: .oldLarge).isEmpty)
    }

    @Test func `rules of apps that are not installed and whose paths do not exist stay inactive`() async throws {
        let bare = try Harness("Inactive")
        #expect(try await bare.pipeline.activeRules().allSatisfy { $0.group != "Unity" })

        let unity = try Harness("ActiveUnity", apps: [Harness.app("Unity Hub", bundleID: "com.unity3d.unityhub", home: bare.home)])
        #expect(try await unity.pipeline.activeRules().contains { $0.id == "unity.cache" })
    }

    @Test func `app cache rules only fire for installed apps`() async throws {
        let missing = try Harness("AppMissing")
        try missing.fixture.file("Library/Application Support/Slack/Cache/data_0", size: 2 * Harness.megabyte)
        let missingSummary = try await missing.scan()
        #expect(try await missing.candidates(missingSummary.sessionID, in: .appCache).isEmpty)

        let slack = Harness.app("Slack", bundleID: "com.tinyspeck.slackmacgap", home: missing.home)
        let installed = try Harness("AppInstalled", apps: [slack])
        try installed.fixture.file("Library/Application Support/Slack/Cache/data_0", size: 2 * Harness.megabyte)
        let summary = try await installed.scan()
        let cache = try #require(try await installed.candidates(summary.sessionID, in: .appCache).first)
        #expect(cache.url.storagePath == installed.url("Library/Application Support/Slack/Cache").storagePath)
        #expect(cache.appBundleID == "com.tinyspeck.slackmacgap")
        #expect(try await installed.candidates(summary.sessionID, in: .orphan).isEmpty)
    }

    @Test func `huge recent files are listed beside old ones and survive the age filter`() async throws {
        let harness = try Harness("LargeAnyAge")
        let mebibyte = Harness.megabyte
        let recent = try harness.fixture.file("Documents/film.mov", size: 4 * mebibyte)
        let old = try harness.fixture.file("Documents/archive.bin", size: 2 * mebibyte, created: Harness.old, modified: Harness.old)
        try harness.fixture.file("Documents/small.bin", size: mebibyte / 2, created: Harness.old, modified: Harness.old)
        let thresholds = Thresholds(minAgeDays: 180, minSize: mebibyte, largeFileMinSize: 3 * mebibyte)

        let summary = try await harness.scan(ScanPipelineOptions(thresholds: thresholds))
        let found = try await harness.candidates(summary.sessionID, in: .oldLarge)
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.url.storagePath, $0) })
        #expect(byPath.count == 2)
        #expect(byPath[recent.storagePath]?.ruleID == "oldLarge.large")
        #expect(byPath[recent.storagePath]?.tier == .red)
        let oldCandidate = try #require(byPath[old.storagePath])
        #expect(oldCandidate.ruleID == "oldLarge")
        #expect(oldCandidate.reason == OldLargeRule.rule.reason)
        #expect(try #require(oldCandidate.lastUsedAt).timeIntervalSince(Harness.old) < 5)

        let filter = CandidateFilter(categories: [.oldLarge], minFreeable: mebibyte, minAgeDays: 180)
        let store = GRDBCandidateStore(database: harness.database)
        let listed = try await store.candidates(session: summary.sessionID, filter: filter, sort: .default, limit: nil, offset: 0)
        #expect(Set(listed.map(\.ruleID)) == ["oldLarge", "oldLarge.large"])
        #expect(try CandidateFilter(minAgeDays: 180).matches(#require(byPath[recent.storagePath]), now: Date()))
    }
}
