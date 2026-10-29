import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct QuarantineUnattributedOwnerTests {
    @Test func `an unattributed app cache is blocked while an app named like its folder runs`() async throws {
        let harness = try QuarantineHarness(name: "QuarantineUnattributed")
        let fixture = harness.fixture
        let playwright = try fixture.folder("home/Library/Caches/ms-playwright")
        try fixture.file("home/Library/Caches/ms-playwright/blob", size: 4096)
        let updater = try fixture.folder("home/Library/Application Support/Caches/notion-updater")
        try fixture.file("home/Library/Application Support/Caches/notion-updater/blob", size: 4096)
        let idle = try fixture.folder("home/Library/Caches/idle-tool")
        try fixture.file("home/Library/Caches/idle-tool/blob", size: 4096)
        let devCache = try fixture.folder("home/Library/Caches/Notion Dev")
        try fixture.file("home/Library/Caches/Notion Dev/blob", size: 4096)
        func appCache(_ url: URL) throws -> Candidate {
            var candidate = try harness.candidate(url, ruleID: "appcache.libraryFallback")
            candidate.category = .appCache
            return candidate
        }
        let candidates = try [appCache(playwright), appCache(updater), appCache(idle), harness.candidate(devCache)]

        let service = harness.makeService(runningNames: ["Notion", "ms-playwright", "notiondev"])
        let result = await service.quarantine(candidates)

        #expect(Set(result.failed.map(\.path.storagePath)) == [playwright.storagePath, updater.storagePath])
        #expect(result.failed.allSatisfy { $0.reason == .appRunning })
        #expect(Set(result.moved.map(\.originalURL.storagePath)) == [idle.storagePath, devCache.storagePath])
    }

    @Test func `owner keys come from the top folder below a Library location`() {
        let home = "/Users/tester/Library"
        let keys = { AppScope.ownerKeys(ofCandidateAt: URL(filePath: home + $0)) }
        #expect(keys("/Caches/ms-playwright") == ["msplaywright"])
        #expect(keys("/Application Support/Caches/notion-updater") == ["notionupdater", "notion"])
        #expect(keys("/Application Support/Foo Bar/Partitions/x/Cache") == ["foobar"])
        #expect(keys("/Application Support/Caches/ab-updater") == ["abupdater"])
        #expect(keys("/Logs/Foo").isEmpty)
    }
}
