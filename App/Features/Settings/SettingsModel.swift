import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class SettingsModel {
    @ObservationIgnored let store: SettingsStore

    var minAgeDays: Int {
        didSet { store.minAgeDays = minAgeDays }
    }

    var minSizeBytes: Int64 {
        didSet { store.minSizeBytes = minSizeBytes }
    }

    var ageBasis: AgeBasis {
        didSet { store.ageBasis = ageBasis }
    }

    var scanRoots: [URL] {
        didSet { store.scanRoots = scanRoots }
    }

    var menuBarEnabled: Bool {
        didSet { store.menuBarEnabled = menuBarEnabled }
    }

    var launchAtLogin: Bool {
        didSet { store.launchAtLogin = launchAtLogin }
    }

    var appearance: AppearancePreference {
        didSet { store.appearance = appearance }
    }

    var limitedMode: Bool {
        didSet { store.limitedMode = limitedMode }
    }

    init(store: SettingsStore) {
        self.store = store
        minAgeDays = store.minAgeDays
        minSizeBytes = store.minSizeBytes
        ageBasis = store.ageBasis
        scanRoots = store.scanRoots
        menuBarEnabled = store.menuBarEnabled
        launchAtLogin = store.launchAtLogin
        appearance = store.appearance
        limitedMode = store.limitedMode
    }

    var thresholds: Thresholds {
        Thresholds(minAgeDays: minAgeDays, minSize: minSizeBytes, ageBasis: ageBasis)
    }

    func addScanRoots(_ urls: [URL]) {
        let existing = Set(scanRoots.map(\.standardizedFileURL))
        scanRoots += urls.map(\.standardizedFileURL).filter { !existing.contains($0) }
    }

    func removeScanRoots(_ urls: Set<URL>) {
        scanRoots.removeAll { urls.contains($0) }
    }

    func displayPath(_ url: URL) -> String {
        UserPath.abbreviate(url, homeURL: store.homeURL)
    }
}
