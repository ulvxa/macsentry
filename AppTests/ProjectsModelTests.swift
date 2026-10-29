import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

@MainActor
struct ProjectsModelTests {
    private static let webapp = ProjectsHarness.project(id: 1, name: "webapp")
    private static let dirty = ProjectsHarness.project(id: 2, name: "dirty", uncommitted: true, size: 500_000_000)
    private static let active = ProjectsHarness.project(id: 3, name: "active", commitDaysAgo: 10, modifiedDaysAgo: 5, size: 200_000_000)

    private static let artifacts = [
        ProjectsHarness.artifact(id: 1, project: 1, in: "webapp", folder: "node_modules"),
        ProjectsHarness.artifact(
            id: 2, project: 1, in: "webapp", folder: ".venv", ecosystem: "python", tier: .yellow, size: 300_000_000,
        ),
        ProjectsHarness.artifact(id: 3, project: 2, in: "dirty", folder: "node_modules", size: 500_000_000),
        ProjectsHarness.artifact(id: 4, project: 3, in: "active", folder: "target", ecosystem: "rust", size: 200_000_000),
    ]

    private func harness(_ name: String, running: Set<String> = []) async throws -> ProjectsHarness {
        try await ProjectsHarness(
            name: name,
            projects: [Self.webapp, Self.dirty, Self.active],
            artifacts: Self.artifacts,
            running: running,
        )
    }

    @Test func `seeded project lists both artifacts with the last commit and only the green one is checked`() async throws {
        let harness = try await harness("ProjectsSeeded")
        let model = harness.model()
        #expect(await eventually { model.phase == .loaded && !model.entries.isEmpty })

        let entry = try #require(model.entries.first { $0.project.name == "webapp" })
        #expect(Set(entry.artifacts.map(\.name)) == ["node_modules", ".venv"])
        #expect(entry.project.lastCommitAt == Self.webapp.lastCommitAt)
        #expect(entry.project.ecosystems == ["node", "python"])
        #expect(entry.freeable == 1_300_000_000)
        #expect(model.checkedIDs == [1])
        #expect(model.focusedEntries.isEmpty)

        let row = try #require(model.rows.first { $0.entry.id == 1 })
        #expect(row.children.count == 2)
        #expect(model.checkState(of: row) == .on)
        #expect(try model.checkState(of: #require(row.children.first { $0.artifact?.name == ".venv" })) == .off)
        #expect(entry.artifacts.first { $0.name == ".venv" }?.regenerationHint?.contains("pip install") == true)
    }

    @Test func `rows are sorted by artifacts size and only idle projects are listed`() async throws {
        let model = try await harness("ProjectsSorted").model()
        #expect(await eventually { model.phase == .loaded && !model.rows.isEmpty })
        #expect(model.rows.map(\.name) == ["webapp", "dirty"])
    }

    @Test func `dirty project is badged and nothing in it is preselected`() async throws {
        let model = try await harness("ProjectsDirty").model()
        #expect(await eventually { model.entries.count == 2 })

        let entry = try #require(model.entries.first { $0.project.name == "dirty" })
        #expect(entry.project.hasUncommitted)
        #expect(entry.artifacts.contains { $0.tier == .green })
        #expect(!model.checkedIDs.contains(3))
        let row = try #require(model.rows.first { $0.entry.id == 2 })
        #expect(model.checkState(of: row) == .off)

        model.toggleCheck(row)
        #expect(model.checkedIDs.contains(3))
        #expect(model.checkState(of: row) == .on)
        model.toggleCheck(row)
        #expect(!model.checkedIDs.contains(3))
    }

    @Test func `project checkbox checks green artifacts only and is mixed when a safe one is unchecked`() async throws {
        let model = try await harness("ProjectsTriState").model()
        #expect(await eventually { model.entries.count == 2 })
        let row = try #require(model.rows.first { $0.entry.id == 1 })

        model.toggleCheck(row)
        #expect(model.checkedIDs.isEmpty)
        #expect(model.checkState(of: row) == .off)
        model.toggleCheck(row)
        #expect(model.checkedIDs == [1])

        let venv = try #require(row.children.first { $0.artifact?.name == ".venv" })
        model.toggleCheck(venv)
        #expect(model.checkedIDs == [1, 2])
        #expect(model.checkState(of: row) == .on)
        let node = try #require(row.children.first { $0.artifact?.name == "node_modules" })
        model.toggleCheck(node)
        #expect(model.checkState(of: row) == .mixed)
    }

    @Test func `idle slider filters live without a rescan and new projects get default checks`() async throws {
        let harness = try await harness("ProjectsIdle")
        let model = harness.model()
        #expect(await eventually { model.entries.count == 2 })
        #expect(model.filter.minAgeDays == 90)
        #expect(!model.isOverridingIdleDays)

        model.filter.minAgeDays = 3
        #expect(model.entries.count == 3)
        #expect(model.isOverridingIdleDays)
        #expect(model.checkedIDs == [1, 4])

        model.filter.minAgeDays = 365
        #expect(model.entries.isEmpty)
        #expect(model.checkedCandidates.isEmpty)
        #expect(model.phase == .loaded)
        #expect(harness.app.scanState == .idle)

        model.filter.minAgeDays = 90
        #expect(model.entries.map(\.id).sorted() == [1, 2])
    }

    @Test func `idle days default comes from settings and follows changes`() async throws {
        let harness = try await harness("ProjectsSettings")
        harness.app.settings.projectIdleDays = 30
        let model = harness.model()
        #expect(model.filter.minAgeDays == 30)
        model.filter.minAgeDays = 45
        #expect(model.isOverridingIdleDays)
        model.idleDaysChanged(to: 60)
        #expect(model.filter.minAgeDays == 60)
        #expect(!model.isOverridingIdleDays)
    }

    @Test func `search narrows by project name, path and artifact name`() async throws {
        let model = try await harness("ProjectsSearch").model()
        #expect(await eventually { model.entries.count == 2 })
        model.filter.query = "dirt"
        #expect(model.entries.map(\.project.name) == ["dirty"])
        model.filter.query = ".venv"
        #expect(model.entries.map(\.project.name) == ["webapp"])
        model.filter.query = "nope"
        #expect(model.rows.isEmpty)
    }

    @Test func `action bar counts distinct projects with checked artifacts`() async throws {
        let model = try await harness("ProjectsActionBar").model()
        #expect(await eventually { model.entries.count == 2 })
        #expect(model.chipText == "1 project")
        #expect(model.primaryTitle == "Quarantine artifacts of 1 project, 1 GB")
        #expect(model.quarantineDisabledReason == nil)

        try model.toggleCheck(#require(model.rows.first { $0.entry.id == 2 }))
        #expect(model.chipText == "2 projects")
        #expect(model.primaryTitle == "Quarantine artifacts of 2 projects, \(ByteFormat.string(1_500_000_000))")

        model.clearChecks()
        #expect(model.chipText == nil)
        #expect(model.quarantineDisabledReason == "Select artifacts to quarantine")
        #expect(model.hasDefaultSelectable)
        model.selectDefault()
        #expect(model.checkedIDs == [1])
    }

    @Test func `quarantine hands the service only artifact folders never the project root or git`() async throws {
        let harness = try await harness("ProjectsQuarantine")
        let model = harness.model()
        #expect(await eventually { model.entries.count == 2 })
        try model
            .toggleCheck(#require(model.rows.first { $0.entry.id == 1 }.flatMap { $0.children.first { $0.artifact?.name == ".venv" } }))

        await model.quarantineChecked()

        let calls = await harness.quarantine.quarantineCalls
        #expect(calls.count == 1)
        let sent = try #require(calls.first)
        let artifactPaths = Set(Self.artifacts.map { $0.url.path(percentEncoded: false) })
        let projectRoots = Set([Self.webapp, Self.dirty, Self.active].map { $0.rootURL.path(percentEncoded: false) })
        let sentPaths = sent.map { $0.url.path(percentEncoded: false) }
        #expect(Set(sentPaths) == [
            ProjectsHarness.root("webapp").appending(path: "node_modules").path(percentEncoded: false),
            ProjectsHarness.root("webapp").appending(path: ".venv").path(percentEncoded: false),
        ])
        #expect(Set(sentPaths).isSubset(of: artifactPaths))
        #expect(Set(sentPaths).isDisjoint(with: projectRoots))
        #expect(sentPaths.allSatisfy { !$0.contains("/.git") && !$0.hasSuffix("/src") })
        #expect(sent.allSatisfy { $0.category == .projectArtifact && $0.action == .quarantine && $0.projectID == 1 })
    }

    @Test func `quarantined artifacts leave the list but the project stays with what remains`() async throws {
        let harness = try await harness("ProjectsAfterQuarantine")
        let model = harness.model()
        #expect(await eventually { model.entries.count == 2 })

        await model.quarantineChecked()

        #expect(await eventually { model.entries.first { $0.id == 1 }?.artifacts.map(\.name) == [".venv"] })
        #expect(model.checkedIDs.isEmpty)
        #expect(model.failureReport == nil)
    }

    @Test func `running IDE blocks artifacts of a project changed in the last day`() async throws {
        let recent = ProjectsHarness.project(id: 5, name: "fresh", commitDaysAgo: 0.1, modifiedDaysAgo: 0.05)
        let harness = try await ProjectsHarness(
            name: "ProjectsBlocked",
            projects: [recent],
            artifacts: [ProjectsHarness.artifact(id: 9, project: 5, in: "fresh", folder: "node_modules")],
            running: ["com.apple.dt.Xcode"],
        )
        let model = harness.model()
        #expect(await eventually { model.phase == .loaded })
        model.filter.minAgeDays = 0
        let entry = try #require(model.entries.first)
        let artifact = try #require(entry.artifacts.first)

        #expect(model.isBlocked(artifact))
        #expect(model.blockReason(artifact) == "Xcode is running and this project changed in the last 24 hours")
        #expect(model.checkedIDs.isEmpty)
        let row = try #require(model.rows.first)
        #expect(!model.isEnabled(row))
        model.toggleCheck(row)
        #expect(model.checkedIDs.isEmpty)
    }

    @Test func `without a scan the screen asks for one`() async throws {
        let harness = try await ProjectsHarness(name: "ProjectsNoScan", sessions: [])
        let model = harness.model()
        #expect(model.phase == .noScan)
        #expect(model.rows.isEmpty)
    }

    @Test func `a finished scan with no projects is loaded and empty`() async throws {
        let harness = try await ProjectsHarness(name: "ProjectsEmpty")
        let model = harness.model()
        #expect(await eventually { model.phase == .loaded })
        #expect(model.rows.isEmpty)
        #expect(model.entries.isEmpty)
    }

    @Test func `focusing an artifact row inspects its project`() async throws {
        let model = try await harness("ProjectsFocus").model()
        #expect(await eventually { model.entries.count == 2 })
        model.focusedIDs = [.artifact(2)]
        #expect(model.focusedEntries.map(\.id) == [1])
        model.focusedIDs = [.artifact(2), .project(2)]
        #expect(Set(model.focusedEntries.map(\.id)) == [1, 2])
        #expect(model.targets(for: [.project(2)]).map(\.id) == [3])
        #expect(model.urls(for: [.project(2)]).map { $0.path(percentEncoded: false) } == ["/fixture/dirty"])
    }
}
