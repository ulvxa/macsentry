import SwiftUI

@main
struct MacSentryApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("MacSentry", id: "main") {
            RootView()
                .modifier(OnboardingPresenter())
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .tint(.primary)
        }
        .defaultSize(width: 1200, height: 780)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            NavigationCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
