import MacSentryCore
import Observation
import SwiftUI

struct ProfileRow: Identifiable, Equatable {
    enum Kind: Int {
        case detected, tool, notInstalled
    }

    let group: String
    let ruleCount: Int
    let detected: [InstalledApp]
    let kind: Kind

    var id: String {
        group
    }

    var subtitle: String {
        let rules = ruleCount == 1 ? "1 rule" : "\(ruleCount) rules"
        switch kind {
        case .detected:
            let names = detected.prefix(2).map { app in [app.name, app.version].compactMap(\.self).joined(separator: " ") }
            let extra = detected.count > 2 ? ["+\(detected.count - 2) more"] : []
            return (names + extra + [rules]).joined(separator: " · ")
        case .tool:
            return rules
        case .notInstalled:
            return "\(rules) · Not installed. Matches leftover files only."
        }
    }
}

@Observable
@MainActor
final class ProfilesModel {
    private(set) var rows: [ProfileRow] = []
    private(set) var loadError: String?
    private(set) var isLoaded = false

    func load(catalog: RuleCatalog, inventory: any AppInventory) async {
        rows = await Self.rows(catalog: catalog, apps: inventory.installedApps())
        loadError = nil
        isLoaded = true
    }

    func load(inventory: any AppInventory) async {
        do {
            try await load(catalog: RuleCatalog.bundled(), inventory: inventory)
        } catch {
            loadError = error.localizedDescription
            isLoaded = true
        }
    }

    nonisolated static func rows(catalog: RuleCatalog, apps: [InstalledApp]) -> [ProfileRow] {
        let appsByBundleID = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        return catalog.groups
            .map { group -> ProfileRow in
                let rules = catalog.rules.filter { $0.group == group }
                let bundleIDs = Set(rules.flatMap(\.appBundleIDs))
                let detected = bundleIDs.sorted().compactMap { appsByBundleID[$0] }
                let kind: ProfileRow.Kind = if !detected.isEmpty {
                    .detected
                } else if bundleIDs.isEmpty {
                    .tool
                } else {
                    .notInstalled
                }
                return ProfileRow(group: group, ruleCount: rules.count, detected: detected, kind: kind)
            }
            .sorted { lhs, rhs in
                lhs.kind.rawValue != rhs.kind.rawValue
                    ? lhs.kind.rawValue < rhs.kind.rawValue
                    : lhs.group.localizedCaseInsensitiveCompare(rhs.group) == .orderedAscending
            }
    }
}

struct ProfilesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var profiles = ProfilesModel()

    var body: some View {
        let settings = model.settings
        Form {
            Section {
                if let error = profiles.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                } else if !profiles.isLoaded {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    ForEach(profiles.rows) { row in
                        Toggle(isOn: binding(for: row.group, settings: settings)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.group)
                                Text(row.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }
            } footer: {
                Text("Turned off groups are skipped by the next scan.")
            }
        }
        .formStyle(.grouped)
        .task {
            await profiles.load(inventory: SystemAppInventory.standard(homeURL: model.environment.homeURL))
        }
    }

    private func binding(for group: String, settings: SettingsModel) -> Binding<Bool> {
        Binding(
            get: { !settings.disabledProfileGroups.contains(group) },
            set: { enabled in
                if enabled {
                    settings.disabledProfileGroups.remove(group)
                } else {
                    settings.disabledProfileGroups.insert(group)
                }
            },
        )
    }
}
