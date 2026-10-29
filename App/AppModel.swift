import AppKit
import Foundation
import MacSentryCore
import Observation

enum ProtectionSetupError: LocalizedError, Equatable {
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case let .refreshFailed(reason):
            "MacSentry couldn't load its protection rules, so scanning and quarantine stay off. \(reason)"
        }
    }
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
@MainActor
final class AppModel {
    static let narrowWidth: CGFloat = 1100

    let environment: AppEnvironment
    let settings: SettingsModel
    let permissions: any PermissionService
    let menuBar: MenuBarModel
    var selection: SidebarItem? = .overview
    var alert: AppAlert?
    var isOnboardingPresented = false
    private(set) var hasFullDiskAccess = false
    private(set) var database: Database?
    private(set) var protection: ProtectionPolicyProvider?
    private(set) var neverTouch: NeverTouchModel?
    private var isOpeningDatabase = false

    private(set) var services: AppServices?
    var scanState: ScanState = .idle
    private(set) var currentSessionID: Int64?
    private(set) var latestFinishedSession: ScanSession?
    private(set) var previousFinishedSession: ScanSession?
    var runningSessionID: Int64?
    private(set) var totals = SessionTotals.empty
    private(set) var totalsLoaded = false
    private(set) var quarantineTotals: QuarantineTotals?
    private(set) var reconcileReport: ReconcileReport?
    var hasLocalSnapshots = false
    var isQuarantining = false
    var toast: Toast?
    var unreadableReport: UnreadableReport?
    var pendingRowSelection: PendingRowSelection?
    var duplicatesSkippedSessionID: Int64?
    var bottomChromeInset: CGFloat = 0
    var inspectorPreferred = true
    private var inspectorForcedOpen = false
    var windowSize: CGSize = .zero {
        didSet {
            if isNarrow, oldValue.width >= Self.narrowWidth {
                inspectorForcedOpen = false
            }
        }
    }

    @ObservationIgnored var scanTask: Task<Void, Never>?
    @ObservationIgnored var scanControl: ScanControl?
    @ObservationIgnored var hashingTask: Task<Void, Never>?
    @ObservationIgnored private var totalsTask: Task<Void, Never>?

    init(
        environment: AppEnvironment = AppEnvironment(),
        settingsStore: SettingsStore? = nil,
        permissions: (any PermissionService)? = nil,
        notifier: any LowSpaceNotifier = SystemLowSpaceNotifier(),
    ) {
        self.environment = environment
        settings = SettingsModel(store: settingsStore ?? SettingsStore(homeURL: environment.homeURL))
        self.permissions = permissions ?? SystemPermissionService(homeURL: environment.homeURL) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        menuBar = MenuBarModel(settings: settings, notifier: notifier)
        refreshPermissions()
        connectMenuBar()
    }

    private func connectMenuBar() {
        menuBar.scanStatus = { [weak self] in
            guard let self, isReady else { return .unavailable }
            if isCancellingScan {
                return .cancelling
            }
            return scanActivity.map { .scanning(files: $0.filesVisited) } ?? .idle
        }
        menuBar.startScan = { [weak self] in self?.startScan() }
        menuBar.cancelScan = { [weak self] in self?.cancelScan() }
    }

    var showsLimitedModeBadge: Bool {
        settings.limitedMode && !hasFullDiskAccess
    }

    var isReady: Bool {
        services != nil
    }

    func refreshPermissions() {
        hasFullDiskAccess = permissions.hasFullDiskAccess()
        isOnboardingPresented = OnboardingDecision.shouldPresent(
            hasFullDiskAccess: hasFullDiskAccess,
            limitedMode: settings.limitedMode,
        )
    }

    func continueWithLimitedScan() {
        settings.limitedMode = true
        refreshPermissions()
    }

    func openDatabase() async {
        guard database == nil, !isOpeningDatabase else { return }
        isOpeningDatabase = true
        defer { isOpeningDatabase = false }
        let url = environment.databaseURL
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try Database.open(at: url)
            }.value
            database = opened
            let inventory = SystemAppInventory.standard(homeURL: environment.homeURL)
            let (provider, store) = try await attachProtection(to: opened, inventory: inventory)
            await attach(AppServices.live(
                environment: environment,
                database: opened,
                protection: provider,
                neverTouch: store,
                inventory: inventory,
            ))
            await menuBar.pressure.attach(database: opened)
            if let backup = opened.corruptBackupURL {
                alert = AppAlert(
                    title: "Database Was Reset",
                    message: "MacSentry found a damaged database and moved it aside to \(backup.lastPathComponent). "
                        + "Quarantined files are untouched and their manifests on disk remain the record.",
                )
            }
        } catch {
            let title = error is ProtectionSetupError ? "Protection Rules Unavailable" : "Database Unavailable"
            alert = AppAlert(title: title, message: error.localizedDescription)
        }
    }

    func attach(_ services: AppServices) async {
        self.services = services
        await reloadSessions(preferring: nil)
        do {
            if let service = services.quarantine as? DefaultQuarantineService {
                reconcileReport = try await service.reconcileWithReport()
            } else {
                try await services.quarantine.reconcile()
            }
        } catch {
            alert = AppAlert(title: "Quarantine Check Failed", message: error.localizedDescription)
        }
        await refreshQuarantineTotals()
        await refreshLocalSnapshots()
        await menuBar.attach(services: services)
    }

    private func attachProtection(
        to database: Database,
        inventory: SystemAppInventory,
    ) async throws -> (ProtectionPolicyProvider, GRDBNeverTouchStore) {
        let store = GRDBNeverTouchStore(database: database)
        let provider = ProtectionPolicyProvider(
            environment: environment,
            neverTouchStore: store,
            ignoredPathStore: GRDBIgnoredPathStore(database: database),
            appInventory: inventory,
        )
        do {
            try await provider.refresh()
        } catch {
            throw ProtectionSetupError.refreshFailed(error.localizedDescription)
        }
        protection = provider
        let model = NeverTouchModel(store: store, provider: provider, homeURL: environment.homeURL)
        neverTouch = model
        await model.load()
        return (provider, store)
    }

    // MARK: Sessions and totals

    func ruleGroup(for ruleID: String) -> String {
        services?.ruleGroups[ruleID] ?? RuleGroups.fallback(for: ruleID)
    }

    func ruleGroup(for candidate: Candidate) -> String {
        candidate.group ?? ruleGroup(for: candidate.ruleID)
    }

    func total(for item: SidebarItem) -> CategoryTotal? {
        guard currentSessionID != nil, let scope = item.scope else { return nil }
        return totals.total(categories: scope.categories, actions: scope.actions)
    }

    func badgeBytes(for item: SidebarItem) -> Int64? {
        if item == .quarantine {
            return quarantineTotals.map(\.inQuarantine).flatMap { $0 > 0 ? $0 : nil }
        }
        return total(for: item).map(\.freeable).flatMap { $0 > 0 ? $0 : nil }
    }

    func refreshQuarantineTotals() async {
        guard let services else { return }
        quarantineTotals = try? await services.quarantine.totals()
    }

    func reveal(_ candidate: Candidate) {
        guard let id = candidate.id else { return }
        let item = SidebarItem.destination(for: candidate)
        pendingRowSelection = PendingRowSelection(item: item, candidateID: id)
        selection = item
    }

    func reloadSessions(preferring sessionID: Int64?) async {
        guard let store = services?.candidates,
              let sessions = try? await store.sessions(limit: DefaultScanService.retainedSessions + 1)
        else { return }
        let finished = sessions.filter { $0.status == .finished }
        latestFinishedSession = finished.first
        previousFinishedSession = finished.dropFirst().first
        setCurrentSession(sessionID ?? finished.first?.id)
    }

    private func setCurrentSession(_ sessionID: Int64?) {
        guard sessionID != currentSessionID || totalsTask == nil else { return }
        currentSessionID = sessionID
        totalsTask?.cancel()
        totalsTask = nil
        totals = .empty
        totalsLoaded = false
        guard let sessionID, let store = services?.candidates else { return }
        totalsTask = Task { [weak self] in
            do {
                for try await value in store.observeActionTotals(session: sessionID) {
                    self?.totals = value
                    self?.totalsLoaded = true
                }
            } catch {
                self?.totals = .empty
                self?.totalsLoaded = true
            }
        }
    }

    // MARK: Inspector

    var isNarrow: Bool {
        windowSize.width > 0 && windowSize.width < Self.narrowWidth
    }

    var isInspectorPresented: Bool {
        get { inspectorPreferred && (!isNarrow || inspectorForcedOpen) }
        set {
            inspectorPreferred = newValue
            inspectorForcedOpen = newValue && isNarrow
        }
    }

    func toggleInspector() {
        isInspectorPresented.toggle()
    }
}
