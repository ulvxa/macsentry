import AppKit
import MacSentryCore

struct AppServices: Sendable {
    let candidates: any CandidateStore
    let quarantine: any QuarantineService
    let neverTouch: any NeverTouchStore
    let inventory: any AppInventory
    let protection: ProtectionPolicyProvider?
    let ruleGroups: [String: String]
    let scanConfig: @Sendable ([URL]) -> ScanConfig
    let makeScanService: @Sendable (ScanPipelineOptions, ScanControl) -> any ScanService
    var volume: (any VolumeSampler)?
    var snapshots: (any LocalSnapshotChecker)?

    static func live(
        environment: AppEnvironment,
        database: Database,
        protection: ProtectionPolicyProvider,
        neverTouch: any NeverTouchStore,
        inventory: SystemAppInventory,
    ) -> AppServices {
        let pipeline = ScanPipeline(
            environment: environment,
            database: database,
            protection: protection,
            inventory: inventory,
            applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        )
        return AppServices(
            candidates: GRDBCandidateStore(database: database),
            quarantine: DefaultQuarantineService(
                environment: environment,
                database: database,
                protectionPolicy: protection,
                appInventory: inventory,
                sizeCalculator: DefaultSizeCalculator(),
            ),
            neverTouch: neverTouch,
            inventory: inventory,
            protection: protection,
            ruleGroups: RuleGroups.bundled(),
            scanConfig: { pipeline.config(scanRoots: $0) },
            makeScanService: { pipeline.makeService(options: $0, control: $1) },
            volume: SystemVolumeSampler(),
            snapshots: TmutilLocalSnapshotChecker(),
        )
    }
}

enum RuleGroups {
    static func bundled() -> [String: String] {
        var groups: [String: String] = [:]
        for rule in (try? RuleCatalog.bundled().rules) ?? [] {
            groups[rule.id] = rule.group
        }
        for rule in [OldLargeRule.rule, OldLargeRule.installerRule] {
            groups[rule.id] = rule.group
        }
        return groups
    }

    static func fallback(for ruleID: String) -> String {
        let prefix = ruleID.split(separator: ".").first.map(String.init) ?? ruleID
        return prefix.prefix(1).uppercased() + prefix.dropFirst()
    }
}

enum ScanState: Equatable {
    case idle
    case scanning(ScanActivity)
    case finished(ScanSummary)
    case cancelled
    case failed(String)
}

struct ScanActivity: Equatable {
    var sessionID: Int64?
    var phase: ScanPhase = .walking
    var filesVisited = 0
    var bytesVisited: Int64 = 0
    var currentPath = ""
    var hashing: HashingProgress?
    var duplicatesSkipped = false

    var isHashingDuplicates: Bool {
        phase == .duplicates || hashing != nil
    }
}

struct ToastAction: Equatable {
    let title: String
    let destination: SidebarItem
}

struct Toast: Identifiable, Equatable {
    enum Kind: Equatable {
        case scanFinished(ScanSummary)
        case scanCancelled(hasPreviousResults: Bool)
        case scanFailed(String)
        case message(String)
    }

    let id = UUID()
    let kind: Kind
    var action: ToastAction?

    var autoDismisses: Bool {
        switch kind {
        case let .scanFinished(summary): summary.unreadable.isEmpty
        case .scanFailed: false
        case .scanCancelled, .message: true
        }
    }
}

enum StatusOverlay: Equatable {
    case none
    case hud(ScanActivity)
    case toast(Toast)
}

struct UnreadableReport: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct PendingRowSelection: Equatable {
    let item: SidebarItem
    let candidateID: Int64
}
