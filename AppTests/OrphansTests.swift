import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

private struct AllowEverything: ProtectionPolicy {
    func check(_: URL) -> ProtectionVerdict {
        .allowed
    }
}

@MainActor
struct OrphansTests {
    private static let size: Int64 = 1_000_000_000

    private static func findings() async throws -> [OrphanFinding] {
        let fixture = try FixtureBuilder(name: "OrphanFindings")
        let library = try fixture.folder("Library")
        try fixture.folder("Library/Application Support/com.fake.deletedapp")
        try fixture.folder("Library/Caches/com.microsoft.teams")
        try fixture.folder("Library/Application Support/ollama")
        try fixture.folder("Library/LaunchAgents")
        let agent = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.fake.agent", "Program": "/msfixture/missing/agent"],
            format: .xml,
            options: 0,
        )
        try agent.write(to: fixture.url("Library/LaunchAgents/com.fake.agent.plist"))
        let word = try InstalledApp(
            bundleID: "com.microsoft.Word",
            name: "Microsoft Word",
            version: "16.0",
            url: fixture.url("Applications/Microsoft Word.app"),
        )
        let size = Self.size
        let detector = try DefaultOrphanDetector(
            sessionID: 1,
            allowlist: SystemAllowlist.bundled(),
            policy: AllowEverything(),
            applicationURL: { _ in nil },
            isClaimedByRule: { _ in false },
            folderSize: { _ in SizeInfo(logical: size, allocated: size, freeable: size) },
        )
        return try await detector.findings(inventory: [word], library: library)
    }

    private static func seeded(_ findings: [OrphanFinding]) -> [Candidate] {
        findings.enumerated().map { index, finding in
            var candidate = finding.candidate
            candidate.id = Int64(index + 1)
            candidate.logicalSize = size
            candidate.allocatedSize = size
            candidate.freeableSize = size
            candidate.modifiedAt = Date().addingTimeInterval(-400 * 86400)
            return candidate
        }
    }

    @Test func `deleted app orphan is in the High section and never preselected`() async throws {
        let findings = try await Self.findings()
        let candidates = Self.seeded(findings)
        let deleted = try #require(candidates.first { $0.name == "com.fake.deletedapp" })
        #expect(deleted.confidence == .high)
        #expect(candidates.contains { $0.confidence == .medium })
        #expect(candidates.contains { $0.confidence == .low })

        let harness = try await CandidateHarness(name: "OrphanSections", candidates: candidates)
        let model = harness.list(.orphans)
        #expect(await eventually { model.candidates.count == candidates.count })

        let sections = OrphanSections.rows(model.candidates)
        #expect(sections.map(\.name) == ["High confidence", "Medium confidence", "Low confidence"])
        let high = try #require(sections.first)
        #expect(try high.children.compactMap(\.candidate?.id).contains(#require(deleted.id)))
        #expect(!sections.dropFirst().contains { $0.children.contains { $0.candidate?.id == deleted.id } })
        #expect(model.checkedIDs.isEmpty)
        #expect(!model.hasDefaultSelectable)
        #expect(model.isExpanded("High confidence"))
        #expect(!model.isExpanded("Low confidence"))
        #expect(model.quarantineDisabledReason == "Select items to quarantine")
    }

    @Test func `row details come from the persisted reason and rule`() async throws {
        let findings = try await Self.findings()
        for finding in findings {
            let details = OrphanDetails(candidate: finding.candidate)
            #expect(details.appName == finding.explanation.guessedAppName)
            #expect(details.identity == finding.explanation.identity)
            #expect(details.failedChecks == finding.explanation.failedChecks)
            #expect(details.location == finding.location)
            #expect(details.notes == finding.explanation.notes)
        }
        let deleted = try #require(findings.first { $0.candidate.name == "com.fake.deletedapp" })
        let details = OrphanDetails(candidate: deleted.candidate)
        #expect(details.appName == "deletedapp")
        #expect(details.locationTitle == "Application Support")
        #expect(details.failedChecks.contains(.installedBundleID))
    }

    @Test func `older version folders read the installed app from the reason`() {
        let candidate = Candidate(
            id: 1,
            sessionID: 1,
            url: URL(filePath: "/msfixture/Library/Application Support/JetBrains/IntelliJIdea2023.1", directoryHint: .isDirectory),
            kind: .folder,
            category: .orphan,
            ruleID: OrphanDetails.oldVersionRuleID,
            tier: .yellow,
            action: .quarantine,
            reason: "\(DefaultOrphanDetector.olderVersionReason). IntelliJ IDEA 2024.1 is installed.",
            logicalSize: 1,
            allocatedSize: 1,
            freeableSize: 1,
            confidence: .medium,
        )
        let details = OrphanDetails(candidate: candidate)
        #expect(details.isOlderVersion)
        #expect(details.appName == "IntelliJ IDEA")
        #expect(details.location == .applicationSupport)
        #expect(details.failedChecks.isEmpty)
    }

    @Test func `launch agent orphans are listed but flag only, and also appear in Flagged`() async throws {
        let candidates = try await Self.seeded(Self.findings())
        let agent = try #require(candidates.first { $0.action == .flagOnly })
        #expect(OrphanDetails.location(of: agent) == .launchAgents)
        #expect(agent.resolvedCommand?.contains("launchctl bootout") == true)

        let harness = try await CandidateHarness(name: "OrphanAgents", candidates: candidates)
        let orphans = harness.list(.orphans)
        #expect(await eventually { orphans.candidates.contains { $0.id == agent.id } })
        #expect(!orphans.isCheckable(agent))
        for section in OrphanSections.rows(orphans.candidates) {
            orphans.toggleCheck(section)
        }
        #expect(try !orphans.checkedIDs.contains(#require(agent.id)))
        #expect(orphans.checkedCandidates.allSatisfy { $0.action == .quarantine })
        #expect(orphans.quarantineDisabledReason == nil)

        let flagged = harness.list(.flagged)
        #expect(await eventually { flagged.candidates.map(\.id) == [agent.id] })
    }

    @Test func `this app is still installed adds the path to Never Touch and hides the row`() async throws {
        let candidates = try await Self.seeded(Self.findings())
        let deleted = try #require(candidates.first { $0.name == "com.fake.deletedapp" })
        let harness = try await CandidateHarness(name: "OrphanStillInstalled", candidates: candidates)
        let model = harness.list(.orphans)
        #expect(await eventually { model.candidates.contains { $0.id == deleted.id } })

        await harness.app.addToNeverTouch([deleted])
        #expect(await eventually { !model.candidates.contains { $0.id == deleted.id } })
        #expect(harness.app.toast?.kind == .message("Added com.fake.deletedapp to Never Touch"))
        let deletedID = try #require(deleted.id)
        let stored = try #require(await harness.store.candidate(id: deletedID))
        #expect(stored.status == .ignored)
    }
}
