import MacSentryCore
import SwiftUI

struct ThresholdsSettingsView: View {
    private static let agePresets = [30, 90, 180, 365]

    @Environment(AppModel.self) private var model
    @State private var preview = ThresholdPreviewModel()
    @State private var ageDraft: Double?
    @State private var sizeDraft: Double?
    @State private var largeDraft: Double?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Minimum Age") {
                LabeledContent("Older than") {
                    Text("\(ageDraft.map { Int($0.rounded()) } ?? settings.minAgeDays) days").monospacedDigit()
                }
                DraftSlider(
                    value: Binding(
                        get: { Double(settings.minAgeDays) },
                        set: { settings.minAgeDays = Int($0.rounded()) },
                    ),
                    draft: $ageDraft,
                    in: 7 ... 730,
                ) {
                    Text("Minimum age")
                } minimumValueLabel: {
                    Text("7 d")
                } maximumValueLabel: {
                    Text("2 y")
                }
                .labelsHidden()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Self.agePresets, id: \.self) { days in
                            presetButton(days, selected: settings.minAgeDays == days)
                        }
                    }
                }
            }

            Section("Minimum Size") {
                LabeledContent("Larger than") {
                    Text((sizeDraft.map(LogSizeScale.bytes(at:)) ?? settings.minSizeBytes).formatted(.byteCount(style: .file)))
                        .monospacedDigit()
                }
                DraftSlider(
                    value: Binding(
                        get: { LogSizeScale.position(for: settings.minSizeBytes) },
                        set: { settings.minSizeBytes = LogSizeScale.bytes(at: $0) },
                    ),
                    draft: $sizeDraft,
                    in: 0 ... 1,
                ) {
                    Text("Minimum size")
                } minimumValueLabel: {
                    Text("10 MB")
                } maximumValueLabel: {
                    Text("50 GB")
                }
                .labelsHidden()
            }

            Section {
                Toggle("List large files of any age", isOn: Binding(
                    get: { settings.largeFileMinSizeBytes > 0 },
                    set: { settings.largeFileMinSizeBytes = $0 ? Thresholds.defaultLargeFileMinSize : 0 },
                ))
                if settings.largeFileMinSizeBytes > 0 {
                    LabeledContent("Larger than") {
                        Text((largeDraft.map(LogSizeScale.bytes(at:)) ?? settings.largeFileMinSizeBytes)
                            .formatted(.byteCount(style: .file)))
                            .monospacedDigit()
                    }
                    DraftSlider(
                        value: Binding(
                            get: { LogSizeScale.position(for: settings.largeFileMinSizeBytes) },
                            set: { settings.largeFileMinSizeBytes = LogSizeScale.bytes(at: $0) },
                        ),
                        draft: $largeDraft,
                        in: 0 ... 1,
                    ) {
                        Text("Large file size")
                    } minimumValueLabel: {
                        Text("10 MB")
                    } maximumValueLabel: {
                        Text("50 GB")
                    }
                    .labelsHidden()
                }
            } header: {
                Text("Large Files")
            } footer: {
                Text("Shown in Old and Large for review, never preselected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Age based on", selection: $settings.ageBasis) {
                    Text("Last opened").tag(AgeBasis.lastUsed)
                    Text("Last modified").tag(AgeBasis.modified)
                    Text("Created").tag(AgeBasis.created)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let text = preview.text {
                        Text(text)
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                    Text("Changes apply to list filters instantly. Rules use the values captured when a scan starts.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task(id: ThresholdPreviewModel.key(for: model)) {
            await preview.refresh(app: model)
        }
    }

    @ViewBuilder
    private func presetButton(_ days: Int, selected: Bool) -> some View {
        let title = days == 365 ? "1 year" : "\(days) days"
        if selected {
            Button(title) { model.settings.minAgeDays = days }
                .buttonStyle(.glassProminent)
        } else {
            Button(title) { model.settings.minAgeDays = days }
                .buttonStyle(.glass)
        }
    }
}
