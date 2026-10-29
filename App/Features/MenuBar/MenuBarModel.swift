import AppKit
import Foundation
import MacSentryCore
import Observation

struct MenuBarTotals: Equatable {
    var reclaimable: Int64?
    var inQuarantine: Int64 = 0
    var inTrash: Int64 = 0
}

enum MenuBarScanStatus: Equatable {
    case unavailable
    case idle
    case scanning(files: Int?)
}

@Observable
@MainActor
final class MenuBarModel {
    let pressure: DiskPressureController
    let loginItem: LoginItemController
    private(set) var totals = MenuBarTotals()
    @ObservationIgnored var totalsLoader: (@Sendable () async -> MenuBarTotals)?
    @ObservationIgnored var scanStatus: @MainActor () -> MenuBarScanStatus = { .unavailable }
    @ObservationIgnored var startScan: (@MainActor () async -> Void)?
    @ObservationIgnored var cancelScan: (@MainActor () -> Void)?
    @ObservationIgnored var windowOpener: (@MainActor () -> Void)?

    init(pressure: DiskPressureController, loginItem: LoginItemController) {
        self.pressure = pressure
        self.loginItem = loginItem
    }

    convenience init(settings: SettingsModel) {
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let notifier: any LowSpaceNotifier = underTest ? SilentLowSpaceNotifier() : SystemLowSpaceNotifier()
        self.init(
            pressure: DiskPressureController(store: settings.store, notifier: notifier),
            loginItem: LoginItemController(mirror: { settings.launchAtLogin = $0 }),
        )
    }

    func attach(database: Database, environment: AppEnvironment, protection: ProtectionPolicyProvider?) async {
        totalsLoader = Self.makeTotalsLoader(database: database, environment: environment, protection: protection)
        await pressure.attach(database: database)
        await refreshTotals()
    }

    func refreshTotals() async {
        guard let totalsLoader else { return }
        totals = await totalsLoader()
    }

    func openMainWindow() {
        if let windowOpener {
            windowOpener()
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.activate()
    }

    private static func makeTotalsLoader(
        database: Database,
        environment: AppEnvironment,
        protection: ProtectionPolicyProvider?,
    ) -> @Sendable () async -> MenuBarTotals {
        let candidates = GRDBCandidateStore(database: database)
        let quarantine = protection.map {
            DefaultQuarantineService(
                environment: environment,
                database: database,
                protectionPolicy: $0,
                appInventory: SystemAppInventory.standard(homeURL: environment.homeURL),
                sizeCalculator: DefaultSizeCalculator(),
            )
        }
        return {
            var totals = MenuBarTotals()
            if let quarantineTotals = try? await quarantine?.totals() {
                totals.inQuarantine = quarantineTotals.inQuarantine
                totals.inTrash = quarantineTotals.inTrash
            }
            if let session = try? await candidates.latestFinishedSession(), let id = session.id,
               let byCategory = try? await candidates.totals(session: id) {
                totals.reclaimable = byCategory.filter { $0.key != .flagged }.values.reduce(0) { $0 + $1.freeable }
            }
            return totals
        }
    }
}
