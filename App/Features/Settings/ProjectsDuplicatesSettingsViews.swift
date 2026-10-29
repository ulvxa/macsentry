import SwiftUI

enum DuplicateSizeStops {
    static let values: [Int64] = [
        100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000,
        20_000_000, 50_000_000, 100_000_000, 200_000_000, 500_000_000, 1_000_000_000,
    ]

    static func index(for bytes: Int64) -> Int {
        values.indices.min { abs(values[$0] - bytes) < abs(values[$1] - bytes) } ?? 0
    }

    static func bytes(at index: Int) -> Int64 {
        values[min(max(index, 0), values.count - 1)]
    }
}

struct ProjectsSettingsView: View {
    private static let idlePresets = [30, 90, 180, 365]

    @Environment(AppModel.self) private var model
    @State private var idleDraft: Double?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Project Folders") {
                SettingsFolderList(title: "Project folders", roots: $settings.projectRoots, displayPath: settings.displayPath)
            }
            Section("Idle Projects") {
                LabeledContent("Not touched for") {
                    Text("\(idleDraft.map { Int($0.rounded()) } ?? settings.projectIdleDays) days").monospacedDigit()
                }
                DraftSlider(
                    value: Binding(
                        get: { Double(settings.projectIdleDays) },
                        set: { settings.projectIdleDays = Int($0.rounded()) },
                    ),
                    draft: $idleDraft,
                    in: 7 ... 730,
                ) {
                    Text("Idle days")
                } minimumValueLabel: {
                    Text("7 d")
                } maximumValueLabel: {
                    Text("2 y")
                }
                .labelsHidden()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Self.idlePresets, id: \.self) { days in
                            presetButton(days)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func presetButton(_ days: Int) -> some View {
        let title = days == 365 ? "1 year" : "\(days) days"
        if model.settings.projectIdleDays == days {
            Button(title) { model.settings.projectIdleDays = days }
                .buttonStyle(.glassProminent)
        } else {
            Button(title) { model.settings.projectIdleDays = days }
                .buttonStyle(.glass)
        }
    }
}

struct DuplicatesSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var sizeDraft: Double?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Duplicate Folders") {
                SettingsFolderList(title: "Duplicate folders", roots: $settings.duplicateRoots, displayPath: settings.displayPath)
                Button("Restore Default Folders") { settings.restoreDefaultDuplicateRoots() }
                    .buttonStyle(.glass)
            }
            Section("Minimum File Size") {
                LabeledContent("Larger than") {
                    Text((sizeDraft.map { DuplicateSizeStops.bytes(at: Int($0.rounded())) } ?? settings.duplicateMinSizeBytes)
                        .formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                }
                DraftSlider(
                    value: Binding(
                        get: { Double(DuplicateSizeStops.index(for: settings.duplicateMinSizeBytes)) },
                        set: { settings.duplicateMinSizeBytes = DuplicateSizeStops.bytes(at: Int($0.rounded())) },
                    ),
                    draft: $sizeDraft,
                    in: 0 ... Double(DuplicateSizeStops.values.count - 1),
                    step: 1,
                ) {
                    Text("Minimum file size")
                } minimumValueLabel: {
                    Text("100 KB")
                } maximumValueLabel: {
                    Text("1 GB")
                }
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }
}
