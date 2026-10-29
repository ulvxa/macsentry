import Foundation

public enum AppearancePreference: String, Sendable, CaseIterable {
    case system, light, dark
}

public enum SettingsKey: String, Sendable, CaseIterable {
    case minAgeDays = "thresholds.minAgeDays"
    case minSizeBytes = "thresholds.minSizeBytes"
    case ageBasis = "thresholds.ageBasis"
    case scanRoots = "scan.roots"
    case projectRoots = "projects.roots"
    case projectIdleDays = "projects.idleDays"
    case duplicateRoots = "duplicates.roots"
    case duplicateMinSizeBytes = "duplicates.minSizeBytes"
    case disabledProfileGroups = "profiles.disabledGroups"
    case menuBarEnabled = "menuBar.enabled"
    case menuBarShowText = "menuBar.showText"
    case launchAtLogin
    case diskAlertEnabled = "diskAlert.enabled"
    case diskAlertThresholdBytes = "diskAlert.thresholdBytes"
    case appearance
    case limitedMode

    var defaultValue: Any {
        switch self {
        case .minAgeDays: 180
        case .minSizeBytes: Int64(500_000_000)
        case .ageBasis: AgeBasis.lastUsed.rawValue
        case .scanRoots: ["/"]
        case .projectRoots: ["~"]
        case .projectIdleDays: 90
        case .duplicateRoots: ["~/Downloads", "~/Desktop", "~/Documents", "~/Movies", "~/Pictures", "~/Music"]
        case .duplicateMinSizeBytes: Int64(1_000_000)
        case .disabledProfileGroups: [String]()
        case .menuBarEnabled, .menuBarShowText, .diskAlertEnabled: true
        case .launchAtLogin, .limitedMode: false
        case .diskAlertThresholdBytes: Int64(30_000_000_000)
        case .appearance: AppearancePreference.system.rawValue
        }
    }
}

/// UserDefaults is documented as thread safe; it just is not annotated Sendable.
public final class SettingsStore: @unchecked Sendable {
    public let homeURL: URL
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, homeURL: URL) {
        self.defaults = defaults
        self.homeURL = homeURL
        defaults.register(defaults: Dictionary(uniqueKeysWithValues: SettingsKey.allCases.map { ($0.rawValue, $0.defaultValue) }))
    }

    public var minAgeDays: Int {
        get { defaults.integer(forKey: SettingsKey.minAgeDays.rawValue) }
        set { defaults.set(max(newValue, 0), forKey: SettingsKey.minAgeDays.rawValue) }
    }

    public var minSizeBytes: Int64 {
        get { int64(.minSizeBytes) }
        set { defaults.set(max(newValue, 0), forKey: SettingsKey.minSizeBytes.rawValue) }
    }

    public var ageBasis: AgeBasis {
        get { enumValue(.ageBasis, default: .lastUsed) }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.ageBasis.rawValue) }
    }

    public var thresholds: Thresholds {
        get { Thresholds(minAgeDays: minAgeDays, minSize: minSizeBytes, ageBasis: ageBasis) }
        set {
            minAgeDays = newValue.minAgeDays
            minSizeBytes = newValue.minSize
            ageBasis = newValue.ageBasis
        }
    }

    public var scanRoots: [URL] {
        get { urls(.scanRoots) }
        set { setURLs(newValue, .scanRoots) }
    }

    public var projectRoots: [URL] {
        get { urls(.projectRoots) }
        set { setURLs(newValue, .projectRoots) }
    }

    public var projectIdleDays: Int {
        get { defaults.integer(forKey: SettingsKey.projectIdleDays.rawValue) }
        set { defaults.set(max(newValue, 0), forKey: SettingsKey.projectIdleDays.rawValue) }
    }

    public var duplicateRoots: [URL] {
        get { urls(.duplicateRoots) }
        set { setURLs(newValue, .duplicateRoots) }
    }

    public var duplicateMinSizeBytes: Int64 {
        get { int64(.duplicateMinSizeBytes) }
        set { defaults.set(max(newValue, 0), forKey: SettingsKey.duplicateMinSizeBytes.rawValue) }
    }

    public var disabledProfileGroups: [String] {
        get { defaults.stringArray(forKey: SettingsKey.disabledProfileGroups.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: SettingsKey.disabledProfileGroups.rawValue) }
    }

    public var menuBarEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.menuBarEnabled.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.menuBarEnabled.rawValue) }
    }

    public var menuBarShowText: Bool {
        get { defaults.bool(forKey: SettingsKey.menuBarShowText.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.menuBarShowText.rawValue) }
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: SettingsKey.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.launchAtLogin.rawValue) }
    }

    public var diskAlertEnabled: Bool {
        get { defaults.bool(forKey: SettingsKey.diskAlertEnabled.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.diskAlertEnabled.rawValue) }
    }

    public var diskAlertThresholdBytes: Int64 {
        get { int64(.diskAlertThresholdBytes) }
        set { defaults.set(max(newValue, 0), forKey: SettingsKey.diskAlertThresholdBytes.rawValue) }
    }

    public var appearance: AppearancePreference {
        get { enumValue(.appearance, default: .system) }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.appearance.rawValue) }
    }

    public var limitedMode: Bool {
        get { defaults.bool(forKey: SettingsKey.limitedMode.rawValue) }
        set { defaults.set(newValue, forKey: SettingsKey.limitedMode.rawValue) }
    }

    private func int64(_ key: SettingsKey) -> Int64 {
        (defaults.object(forKey: key.rawValue) as? NSNumber)?.int64Value ?? 0
    }

    private func enumValue<Value: RawRepresentable<String>>(_ key: SettingsKey, default fallback: Value) -> Value {
        defaults.string(forKey: key.rawValue).flatMap(Value.init(rawValue:)) ?? fallback
    }

    private func urls(_ key: SettingsKey) -> [URL] {
        (defaults.stringArray(forKey: key.rawValue) ?? []).map { UserPath.expand($0, homeURL: homeURL) }
    }

    private func setURLs(_ urls: [URL], _ key: SettingsKey) {
        var seen = Set<String>()
        let values = urls.map { UserPath.abbreviate($0, homeURL: homeURL) }.filter { seen.insert($0).inserted }
        defaults.set(values, forKey: key.rawValue)
    }
}
