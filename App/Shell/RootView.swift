import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let item = model.selection ?? .overview
        NavigationSplitView {
            SidebarView(selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            DetailView(item: item)
                .overlay(alignment: .bottom) {
                    ScanStatusOverlay()
                }
        }
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { model.windowSize = $0 })
        .environment(\.homeURL, model.environment.homeURL)
        .toolbar {
            if item.showsToolbarScan {
                ToolbarItem(placement: .primaryAction) {
                    ScanToolbarButton()
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            if model.environment.isDryRun {
                ToolbarItem(placement: .primaryAction) {
                    DryRunBadge()
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleInspector()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or Hide Inspector (⌥⌘I)")
                .disabled(item == .overview)
            }
        }
        .task {
            await model.openDatabase()
        }
        .sheet(item: $model.unreadableReport) { report in
            UnreadableListSheet(report: report)
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

struct ScanToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isScanning {
            Button {
                model.cancelScan()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .help("Cancel Scan (Esc)")
        } else {
            Button {
                model.startScan()
            } label: {
                Label("Scan", systemImage: "arrow.clockwise")
            }
            .help("Scan (⌘R)")
            .disabled(!model.canStartScan)
        }
    }
}
