import Foundation
import MacSentryCore
import MacSentryTestSupport
import Synchronization
@testable import MacSentry

final class ScanServiceFactory: Sendable {
    private let calls = Mutex<[ScanPipelineOptions]>([])
    private let controlCalls = Mutex<[ScanControl]>([])
    private let make: @Sendable (ScanControl) -> any ScanService

    init(_ make: @escaping @Sendable () -> any ScanService) {
        self.make = { _ in make() }
    }

    init(controlled make: @escaping @Sendable (ScanControl) -> any ScanService) {
        self.make = make
    }

    var options: [ScanPipelineOptions] {
        calls.withLock { $0 }
    }

    var controls: [ScanControl] {
        controlCalls.withLock { $0 }
    }

    func service(_ options: ScanPipelineOptions, control: ScanControl) -> any ScanService {
        calls.withLock { $0.append(options) }
        controlCalls.withLock { $0.append(control) }
        return make(control)
    }
}

struct HangingScanService: ScanService {
    let sessionID: Int64

    func scan(config _: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(sessionID: sessionID))
            continuation.yield(.phase(.walking))
            continuation.yield(.progress(filesVisited: 42, bytesVisited: 4200, currentPath: "/fixture/a"))
        }
    }
}

@MainActor
struct CandidateHarness {
    let fixture: FixtureBuilder
    let app: AppModel
    let store: InMemoryCandidateStore
    let quarantine: TestQuarantineService
    let scans: ScanServiceFactory

    init(
        name: String,
        candidates: [Candidate] = [],
        sessions: [ScanSession]? = nil,
        running: Set<String> = [],
        scan: @escaping @Sendable () -> any ScanService = { StubScanService(events: []) },
        configure: (SettingsStore) -> Void = { _ in },
        duplicateGroups: [DuplicateGroup] = [],
        controlledScan: (@Sendable (ScanControl) -> any ScanService)? = nil,
    ) async throws {
        fixture = try FixtureBuilder(name: name)
        let settings = try SettingsStore(defaults: fixture.isolatedDefaults(), homeURL: fixture.root)
        configure(settings)
        app = try AppModel(environment: fixture.environment(), settingsStore: settings)
        store = InMemoryCandidateStore(
            sessions: sessions ?? [ScanSession(id: 1, startedAt: Date(), finishedAt: Date(), status: .finished, roots: [fixture.root])],
            candidates: candidates,
            duplicateGroups: duplicateGroups,
        )
        quarantine = TestQuarantineService()
        scans = controlledScan.map { ScanServiceFactory(controlled: $0) } ?? ScanServiceFactory(scan)
        let root = fixture.root
        let scans = scans
        await app.attach(AppServices(
            candidates: store,
            quarantine: quarantine,
            neverTouch: InMemoryNeverTouchStore(),
            inventory: TestAppInventory(running: running),
            protection: nil,
            ruleGroups: ["xcode.derivedData": "Xcode", "xcode.deviceSupport": "Xcode", "npm.cache": "npm", "oldLarge": "Old and Large"],
            scanConfig: { _ in ScanConfig(roots: [root]) },
            makeScanService: { scans.service($0, control: $1) },
        ))
    }

    func list(_ item: SidebarItem) -> CandidateListModel {
        let model = CandidateListModel(configuration: .forItem(item), app: app)
        model.activate()
        return model
    }

    static func candidate(
        id: Int64,
        session: Int64 = 1,
        name: String,
        category: MacSentryCore.Category = .devCache,
        ruleID: String = "xcode.derivedData",
        tier: Tier = .green,
        action: CandidateAction = .quarantine,
        size: Int64 = 1_000_000_000,
        ageDays: Double = 400,
        bundleID: String? = nil,
    ) -> Candidate {
        Candidate(
            id: id,
            sessionID: session,
            url: URL(filePath: "/fixture/\(name)", directoryHint: .isDirectory),
            kind: .folder,
            category: category,
            ruleID: ruleID,
            tier: tier,
            action: action,
            reason: "Test reason",
            cliCommand: action == .flagOnly ? "tool prune {path}" : nil,
            appBundleID: bundleID,
            logicalSize: size,
            allocatedSize: size,
            freeableSize: size,
            modifiedAt: Date().addingTimeInterval(-ageDays * 86400),
            lastUsedAt: Date().addingTimeInterval(-ageDays * 86400),
        )
    }
}
