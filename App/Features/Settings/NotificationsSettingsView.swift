import SwiftUI

struct NotificationsSettingsView: View {
    static let thresholdRangeGB = 5 ... 500
    private static let bytesPerGB: Int64 = 1_000_000_000

    @Environment(AppModel.self) private var model

    var body: some View {
        let pressure = model.menuBar.pressure
        Form {
            Section {
                Toggle(
                    "Warn when free space is low",
                    isOn: Binding(
                        get: { pressure.alertEnabled },
                        set: { enabled in Task { await pressure.setAlertEnabled(enabled) } },
                    ),
                )
                LabeledContent("Warn below") {
                    HStack(spacing: 6) {
                        TextField("Threshold", value: thresholdGB(pressure), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                            .labelsHidden()
                        Text("GB")
                            .foregroundStyle(.secondary)
                        Stepper("Threshold", value: thresholdGB(pressure), in: Self.thresholdRangeGB)
                            .labelsHidden()
                    }
                }
                .disabled(!pressure.alertEnabled)
            } footer: {
                Text("Measured against free space including purgeable files. One alert per drop, re-armed after space recovers.")
            }

            if pressure.alertEnabled {
                Section("Status") {
                    statusRow(pressure)
                }
            }
        }
        .formStyle(.grouped)
        .task { await pressure.refreshAuthorization() }
        .refreshOnActivate { Task { await pressure.refreshAuthorization() } }
    }

    @ViewBuilder
    private func statusRow(_ pressure: DiskPressureController) -> some View {
        switch pressure.authorization {
        case .authorized:
            Label("Notifications are on for MacSentry", systemImage: "bell")
        case .notDetermined:
            Label("MacSentry hasn't asked to send notifications yet", systemImage: "bell.badge")
            Button("Allow Notifications") { Task { await pressure.requestNotificationPermission() } }
                .buttonStyle(.glassProminent)
        case .denied:
            Label("Notifications are off for MacSentry", systemImage: "bell.slash")
            Button("Open Notification Settings") { Task { await pressure.openNotificationSettings() } }
                .buttonStyle(.glass)
        }
    }

    private func thresholdGB(_ pressure: DiskPressureController) -> Binding<Int> {
        Binding(
            get: { Int(pressure.alertThresholdBytes / Self.bytesPerGB) },
            set: {
                pressure
                    .alertThresholdBytes = Int64(min(max($0, Self.thresholdRangeGB.lowerBound), Self.thresholdRangeGB.upperBound)) * Self
                    .bytesPerGB
            },
        )
    }
}
