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
    case cancelling
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

    convenience init(settings: SettingsModel, notifier: any LowSpaceNotifier) {
        self.init(
            pressure: DiskPressureController(store: settings.store, notifier: notifier),
            loginItem: LoginItemController(mirror: { settings.launchAtLogin = $0 }),
        )
    }

    func attach(services: AppServices) async {
        totalsLoader = Self.makeTotalsLoader(services)
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

    private static func makeTotalsLoader(_ services: AppServices) -> @Sendable () async -> MenuBarTotals {
        let candidates = services.candidates
        let quarantine = services.quarantine
        return {
            var totals = MenuBarTotals()
            if let quarantineTotals = try? await quarantine.totals() {
                totals.inQuarantine = quarantineTotals.inQuarantine
                totals.inTrash = quarantineTotals.inTrash
            }
            if let session = try? await candidates.latestFinishedSession(), let id = session.id,
               let sessionTotals = try? await candidates.actionTotals(session: id) {
                totals.reclaimable = sessionTotals.reclaimable.freeable
            }
            return totals
        }
    }
}
