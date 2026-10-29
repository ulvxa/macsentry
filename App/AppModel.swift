import AppKit
import Foundation
import MacSentryCore
import Observation

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
@MainActor
final class AppModel {
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

    init(
        environment: AppEnvironment = AppEnvironment(),
        settingsStore: SettingsStore? = nil,
        permissions: (any PermissionService)? = nil,
    ) {
        self.environment = environment
        settings = SettingsModel(store: settingsStore ?? SettingsStore(homeURL: environment.homeURL))
        self.permissions = permissions ?? SystemPermissionService(homeURL: environment.homeURL) { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        menuBar = MenuBarModel(settings: settings)
        refreshPermissions()
    }

    var showsLimitedModeBadge: Bool {
        settings.limitedMode && !hasFullDiskAccess
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
            await attachProtection(to: opened)
            await menuBar.attach(database: opened, environment: environment, protection: protection)
            if let backup = opened.corruptBackupURL {
                alert = AppAlert(
                    title: "Database Was Reset",
                    message: "MacSentry found a damaged database and moved it aside to \(backup.lastPathComponent). "
                        + "Quarantined files are untouched and their manifests on disk remain the record.",
                )
            }
        } catch {
            alert = AppAlert(title: "Database Unavailable", message: error.localizedDescription)
        }
    }

    private func attachProtection(to database: Database) async {
        let store = GRDBNeverTouchStore(database: database)
        let provider = ProtectionPolicyProvider(
            environment: environment,
            neverTouchStore: store,
            ignoredPathStore: GRDBIgnoredPathStore(database: database),
        )
        protection = provider
        let model = NeverTouchModel(store: store, provider: provider, homeURL: environment.homeURL)
        neverTouch = model
        await model.load()
    }
}
