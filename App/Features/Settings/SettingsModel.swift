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

    var largeFileMinSizeBytes: Int64 {
        didSet { store.largeFileMinSizeBytes = largeFileMinSizeBytes }
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

    var menuBarShowText: Bool {
        didSet { store.menuBarShowText = menuBarShowText }
    }

    var disabledProfileGroups: Set<String> {
        didSet { store.disabledProfileGroups = disabledProfileGroups.sorted() }
    }

    var projectRoots: [URL] {
        didSet { store.projectRoots = projectRoots }
    }

    var projectIdleDays: Int {
        didSet { store.projectIdleDays = projectIdleDays }
    }

    var duplicateRoots: [URL] {
        didSet { store.duplicateRoots = duplicateRoots }
    }

    var duplicateMinSizeBytes: Int64 {
        didSet { store.duplicateMinSizeBytes = duplicateMinSizeBytes }
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
        largeFileMinSizeBytes = store.largeFileMinSizeBytes
        ageBasis = store.ageBasis
        scanRoots = store.scanRoots
        menuBarEnabled = store.menuBarEnabled
        menuBarShowText = store.menuBarShowText
        disabledProfileGroups = Set(store.disabledProfileGroups)
        projectRoots = store.projectRoots
        projectIdleDays = store.projectIdleDays
        duplicateRoots = store.duplicateRoots
        duplicateMinSizeBytes = store.duplicateMinSizeBytes
        launchAtLogin = store.launchAtLogin
        appearance = store.appearance
        limitedMode = store.limitedMode
    }

    static let defaultDuplicateFolders = ["Downloads", "Desktop", "Documents", "Movies", "Pictures", "Music"]

    var thresholds: Thresholds {
        Thresholds(
            minAgeDays: minAgeDays,
            minSize: minSizeBytes,
            ageBasis: ageBasis,
            largeFileMinSize: largeFileMinSizeBytes,
        )
    }

    func addScanRoots(_ urls: [URL]) {
        let existing = Set(scanRoots.map(\.standardizedFileURL))
        scanRoots += urls.map(\.standardizedFileURL).filter { !existing.contains($0) }
    }

    func removeScanRoots(_ urls: Set<URL>) {
        scanRoots.removeAll { urls.contains($0) }
    }

    func restoreDefaultDuplicateRoots() {
        duplicateRoots = Self.defaultDuplicateFolders.map { store.homeURL.appending(path: $0, directoryHint: .isDirectory) }
    }

    func displayPath(_ url: URL) -> String {
        UserPath.abbreviate(url, homeURL: store.homeURL)
    }
}
