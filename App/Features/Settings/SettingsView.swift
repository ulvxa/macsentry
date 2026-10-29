import MacSentryCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Thresholds", systemImage: "slider.horizontal.3") {
                ThresholdsSettingsView()
            }
            Tab("Profiles", systemImage: "shippingbox") {
                ProfilesSettingsView()
            }
            Tab("Never Touch", systemImage: "hand.raised") {
                NeverTouchSettingsView()
            }
            Tab("Projects", systemImage: "folder.badge.gearshape") {
                ProjectsSettingsView()
            }
            Tab("Duplicates", systemImage: "doc.on.doc") {
                DuplicatesSettingsView()
            }
            Tab("Notifications", systemImage: "bell") {
                NotificationsSettingsView()
            }
            Tab("Appearance", systemImage: "circle.lefthalf.filled") {
                AppearanceSettingsView()
            }
        }
        .frame(width: 620, height: 520)
        .tint(.primary)
        .preferredColorScheme(model.settings.appearance.colorScheme)
    }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearancePreference.allCases, id: \.self) { preference in
                    Text(preference.title).tag(preference)
                }
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}
