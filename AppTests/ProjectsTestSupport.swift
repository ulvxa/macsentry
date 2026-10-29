import Foundation
import MacSentryCore
import MacSentryTestSupport
@testable import MacSentry

@MainActor
struct ProjectsHarness {
    let fixture: FixtureBuilder
    let app: AppModel
    let store: InMemoryCandidateStore
    let quarantine: TestQuarantineService

    init(
        name: String,
        projects: [Project] = [],
        artifacts: [Candidate] = [],
        sessions: [ScanSession]? = nil,
        running: Set<String> = [],
    ) async throws {
        fixture = try FixtureBuilder(name: name)
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        app = try AppModel(environment: fixture.environment(), settingsStore: settings)
        store = InMemoryCandidateStore(
            sessions: sessions ?? [ScanSession(id: 1, startedAt: Date(), finishedAt: Date(), status: .finished, roots: [fixture.root])],
            candidates: artifacts,
            projects: projects,
        )
        quarantine = TestQuarantineService()
        let root = fixture.root
        await app.attach(AppServices(
            candidates: store,
            quarantine: quarantine,
            neverTouch: InMemoryNeverTouchStore(),
            inventory: TestAppInventory(running: running),
            protection: nil,
            ruleGroups: [:],
            scanConfig: { _ in ScanConfig(roots: [root]) },
            makeScanService: { _, _ in StubScanService(events: []) },
        ))
    }

    func model() -> ProjectsModel {
        let model = ProjectsModel(app: app)
        model.activate()
        return model
    }

    static func project(
        id: Int64,
        name: String,
        ecosystems: [String] = ["node", "python"],
        commitDaysAgo: Double? = 200,
        modifiedDaysAgo: Double = 150,
        uncommitted: Bool = false,
        size: Int64 = 1_000_000_000,
    ) -> Project {
        Project(
            id: id,
            sessionID: 1,
            rootURL: root(name),
            name: name,
            ecosystems: ecosystems,
            lastCommitAt: commitDaysAgo.map { Date().addingTimeInterval(-$0 * 86400) },
            lastModifiedAt: Date().addingTimeInterval(-modifiedDaysAgo * 86400),
            hasUncommitted: uncommitted,
            artifactsSize: size,
        )
    }

    static func root(_ name: String) -> URL {
        URL(filePath: "/fixture/\(name)", directoryHint: .isDirectory)
    }

    static func artifact(
        id: Int64,
        project: Int64,
        in name: String,
        folder: String,
        ecosystem: String = "node",
        tier: Tier = .green,
        size: Int64 = 1_000_000_000,
    ) -> Candidate {
        Candidate(
            id: id,
            sessionID: 1,
            url: root(name).appending(path: folder, directoryHint: .isDirectory),
            kind: .folder,
            category: .projectArtifact,
            ruleID: "graveyard.\(ecosystem).\(folder)",
            tier: tier,
            action: .quarantine,
            reason: "`\(folder)` of \(name). Rebuilt by the project's tooling.",
            logicalSize: size,
            allocatedSize: size,
            freeableSize: size,
            projectID: project,
        )
    }
}
