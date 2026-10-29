import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

@MainActor
struct CandidateListGroupTests {
    @Test func `app caches group by the stored per app group and name the app when blocked`() async throws {
        func appCache(_ id: Int64, _ name: String, group: String?, bundleID: String? = nil) -> Candidate {
            var candidate = CandidateHarness.candidate(
                id: id,
                name: name,
                category: .appCache,
                ruleID: "appcache.chromium",
                bundleID: bundleID,
            )
            candidate.group = group
            return candidate
        }
        let harness = try await CandidateHarness(
            name: "ListAppGroups",
            candidates: [
                appCache(1, "Notion Cache", group: "Notion", bundleID: "notion.id"),
                appCache(2, "Miro Cache", group: "Miro"),
                appCache(3, "Unknown Cache", group: AppScope.otherGroup, bundleID: "com.unknown.tool"),
                appCache(4, "Old Row", group: nil),
            ],
            running: ["notion.id", "com.unknown.tool"],
        )
        let model = harness.list(.appCaches)
        #expect(await eventually { model.rows.count == 4 })
        #expect(Set(model.rows.map(\.name)) == ["Notion", "Miro", AppScope.otherGroup, harness.app.ruleGroup(for: "appcache.chromium")])
        let notion = try #require(model.candidates.first { $0.id == 1 })
        #expect(model.blockReason(notion) == "Quit Notion to quarantine this")
        let unknown = try #require(model.candidates.first { $0.id == 3 })
        #expect(model.blockReason(unknown) == "Quit the app that owns it to quarantine this")
        #expect(model.candidates(for: [.group("Miro")]).compactMap(\.id) == [2])
    }
}
