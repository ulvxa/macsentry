import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            DetailView(item: model.selection ?? .overview)
        }
        .toolbar {
            if model.environment.isDryRun {
                ToolbarItem(placement: .primaryAction) {
                    DryRunBadge()
                }
            }
        }
        .task {
            await model.openDatabase()
        }
        .alert(
            model.alert?.title ?? "",
            isPresented: Binding(get: { model.alert != nil }, set: {
                if !$0 {
                    model.alert = nil
                }
            }),
            presenting: model.alert,
        ) { _ in
            Button("OK") {}
        } message: { alert in
            Text(alert.message)
        }
    }
}
