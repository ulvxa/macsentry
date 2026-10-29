import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PipelineAppCacheTests {
    private typealias Harness = PipelineHarness

    @Test func `a real machine layout yields every app cache once and nothing nested`() async throws {
        let harness = try Harness("AppScope", apps: AppCacheFixture.inventory)
        try AppCacheFixture.buildRealMachine(harness.fixture)
        try harness.fixture.file("Library/Caches/Homebrew/downloads/blob", size: 4096)
        try harness.fixture.file("Library/Caches/JetBrains/IntelliJIdea2025.1/index/blob", size: 4096)

        let summary = try await harness.scan()
        #expect(summary.status == .finished)
        let candidates = try await harness.candidates(summary.sessionID)
        let byPath = Dictionary(grouping: candidates, by: \.url.storagePath)
        #expect(byPath.values.allSatisfy { $0.count == 1 })

        // Unattributed folders directly in a Library location belong to no installed app, so the orphan pass reports them whole.
        let leftovers = ["Library/Caches/ms-playwright": "orphan.caches", "Library/Containers/com.unknown.tool": "orphan.containers"]
        for expected in AppCacheFixture.realMachine {
            let found = byPath[harness.url(expected.path).storagePath]?.first
            if expected.group == AppScope.otherGroup, expected.ruleID != "appcache.updater" {
                #expect(found?.category != .appCache, "\(expected.path)")
                continue
            }
            let candidate = try #require(found, "\(expected.path)")
            #expect(candidate.ruleID == expected.ruleID, "\(expected.path)")
            #expect(candidate.appBundleID == expected.bundleID, "\(expected.path)")
            #expect(candidate.group == expected.group, "\(expected.path)")
            #expect(candidate.category == .appCache && candidate.action == .quarantine)
            #expect(candidate.tier == .green, "\(expected.path)")
        }
        for (path, ruleID) in leftovers {
            #expect(byPath[harness.url(path).storagePath]?.first?.ruleID == ruleID, "\(path)")
        }
        #expect(byPath[harness.url("Library/Caches/Homebrew").storagePath]?.first?.ruleID == "homebrew.cache")
        #expect(byPath[harness.url("Library/Caches/Homebrew").storagePath]?.first?.group == "Homebrew")
        #expect(byPath[harness.url("Library/Caches/JetBrains").storagePath]?.first?.ruleID == "appcache.libraryFallback")
        #expect(candidates.filter { $0.category == .orphan }.allSatisfy { $0.group == nil })
        for path in AppCacheFixture.neverMatched {
            #expect(byPath[harness.url(path).storagePath]?.first?.category != .appCache, "\(path)")
        }

        let paths = candidates.map(\.url.storagePath)
        for path in paths {
            #expect(!paths.contains { path.hasPrefix($0 + "/") }, "\(path) is nested in another candidate")
        }
    }

    @Test func `leftovers of deleted apps stay whole orphans instead of losing their caches`() async throws {
        let notion = AppCacheFixture.app("notion.id", "Notion")
        let harness = try Harness("AppScopeOrphans", apps: [notion])
        let fixture = harness.fixture
        let support = AppCacheFixture.support
        try fixture.file("\(support)/com.fake.deletedapp/GPUCache/blob", size: 64 * 1024)
        try fixture.file("\(support)/com.fake.deletedapp/Local Storage/leveldb/000003.log", size: 1024)
        try fixture.file("Library/Caches/com.fake.leftover/blob", size: 64 * 1024)
        try fixture.file("Library/Containers/com.fake.gone/Data/Library/Caches/blob", size: 64 * 1024)
        try fixture.file("Library/Caches/NotionHelperData/blob", size: 64 * 1024)
        try fixture.file("Library/Caches/CloudKit/blob", size: 64 * 1024)

        let summary = try await harness.scan()
        let candidates = try await harness.candidates(summary.sessionID)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url.storagePath, $0) })
        func candidate(_ path: String) -> Candidate? {
            byPath[harness.url(path).storagePath]
        }

        #expect(candidate("\(support)/com.fake.deletedapp")?.category == .orphan)
        #expect(candidate("\(support)/com.fake.deletedapp/GPUCache") == nil)
        #expect(candidate("Library/Caches/com.fake.leftover")?.ruleID == "orphan.caches")
        #expect(candidate("Library/Containers/com.fake.gone")?.category == .orphan)
        #expect(candidate("Library/Containers/com.fake.gone/Data/Library/Caches") == nil)

        let owned = try #require(candidate("Library/Caches/NotionHelperData"))
        #expect(owned.ruleID == "appcache.libraryFallback")
        #expect(owned.category == .appCache)
        #expect(owned.appBundleID == nil)
        #expect(candidate("Library/Caches/CloudKit") == nil)
        #expect(!candidates.contains { $0.category == .orphan && $0.url.lastPathComponent == "NotionHelperData" })
    }

    @Test func `a recently used leftover the orphan pass skips is still claimed by the cache rules`() async throws {
        let harness = try Harness("AppScopeRecent", apps: [AppCacheFixture.app("notion.id", "Notion")])
        let fixture = harness.fixture
        let support = AppCacheFixture.support
        try fixture.file("\(support)/com.fake.recent/GPUCache/blob", size: 64 * 1024)
        try fixture.file("\(support)/com.fake.recent/state.sqlite", size: 4096)
        try fixture.file("Library/Caches/com.fake.recentcache/Cache.db", size: 4096)
        try fixture.file("\(support)/com.fake.stale/GPUCache/blob", size: 64 * 1024)
        try fixture.file("\(support)/com.fake.stale/state.sqlite", size: 4096, modified: Harness.old)

        let summary = try await harness.scan()
        let candidates = try await harness.candidates(summary.sessionID)
        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.url.storagePath, $0) })
        func candidate(_ path: String) -> Candidate? {
            byPath[harness.url(path).storagePath]
        }

        #expect(candidate("\(support)/com.fake.recent") == nil)
        let gpu = try #require(candidate("\(support)/com.fake.recent/GPUCache"))
        #expect(gpu.ruleID == "appcache.chromium")
        #expect(gpu.group == AppScope.otherGroup)
        #expect(gpu.appBundleID == "com.fake.recent")
        #expect(candidate("Library/Caches/com.fake.recentcache")?.ruleID == "appcache.libraryFallback")
        #expect(candidate("\(support)/com.fake.stale")?.category == .orphan)
        #expect(candidate("\(support)/com.fake.stale/GPUCache") == nil)
    }

    @Test func `a cache held back for a leftover is emitted when another rule keeps the orphan pass away`() async throws {
        let harness = try Harness("AppScopeOverlap", apps: [AppCacheFixture.app("notion.id", "Notion")])
        let support = AppCacheFixture.support
        try harness.fixture.file("\(support)/Steam/appcache/httpcache/blob", size: 64 * 1024)
        try harness.fixture.file("\(support)/Steam/GPUCache/blob", size: 64 * 1024)
        try harness.fixture.file("\(support)/Steam/zz/GPUCache/blob", size: 64 * 1024)

        let summary = try await harness.scan()
        let byPath = try await Dictionary(uniqueKeysWithValues: harness.candidates(summary.sessionID).map { ($0.url.storagePath, $0) })

        #expect(byPath[harness.url("\(support)/Steam").storagePath] == nil)
        #expect(byPath[harness.url("\(support)/Steam/appcache/httpcache").storagePath]?.ruleID == "steam.httpCache")
        for path in ["\(support)/Steam/GPUCache", "\(support)/Steam/zz/GPUCache"] {
            let cache = try #require(byPath[harness.url(path).storagePath], "\(path)")
            #expect(cache.ruleID == "appcache.chromium")
            #expect(cache.group == AppScope.otherGroup)
            #expect(cache.freeableSize >= 64 * 1024)
        }
    }

    @Test func `protected folders under the new rules are never emitted`() async throws {
        let harness = try Harness(
            "AppScopeProtected",
            apps: AppCacheFixture.inventory,
            neverTouch: ["**/RealtimeBoard/**", "**/com.fake.kept/**"],
        )
        let support = AppCacheFixture.support
        try harness.fixture.file("\(support)/RealtimeBoard/Code Cache/blob", size: 4096)
        try harness.fixture.file("\(support)/RealtimeBoard/Cache/Cache_Data/blob", size: 4096)
        try harness.fixture.file("\(support)/com.fake.kept/GPUCache/blob", size: 4096)
        try harness.fixture.file("\(support)/Notion/Partitions/notion/Code Cache/blob", size: 4096)

        let summary = try await harness.scan()
        let paths = try await Set(harness.candidates(summary.sessionID).map(\.url.storagePath))

        #expect(paths.allSatisfy { !$0.contains("/RealtimeBoard") && !$0.contains("/com.fake.kept") })
        #expect(paths.contains(harness.url("\(support)/Notion/Partitions/notion/Code Cache").storagePath))
    }
}
