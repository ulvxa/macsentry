import SwiftUI

@main
struct MacSentryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacSentry", id: "main") {
            RootView()
                .modifier(OnboardingPresenter())
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .tint(.primary)
                .task { appDelegate.connect(to: model) }
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            NavigationCommands(model: model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.menuBarEnabled }, set: { model.settings.menuBarEnabled = $0 })) {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
