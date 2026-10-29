import SwiftUI

struct EmptyStateView: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let symbol: String
    let title: String
    let message: String
    var action: Action?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.glass)
            }
        }
    }
}

struct ScanCallToAction: View {
    @Environment(AppModel.self) private var model

    let sectionTitle: String

    var body: some View {
        ContentUnavailableView {
            Label("No scan yet", systemImage: "internaldrive")
        } description: {
            Text("Run a scan to see \(sectionTitle).")
        } actions: {
            Button {
                model.startScan()
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!model.canStartScan)
        }
    }
}

struct ScanningPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("Scanning… \(model.scanActivity?.filesVisited.formatted() ?? "0") files")
                .monospacedDigit()
        }
    }
}
