import MacSentryCore
import SwiftUI

struct QuarantineView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        QuarantineContent(model: QuarantineModel(app: app))
    }
}

private struct QuarantineContent: View {
    @Environment(AppModel.self) private var app
    @State var model: QuarantineModel

    var body: some View {
        @Bindable var app = app
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load the quarantine",
                    message: message,
                    action: .init(title: "Try Again") { Task { await model.load() } },
                )
            case .loaded:
                loaded
            }
        }
        .inspector(isPresented: $app.isInspectorPresented) {
            QuarantineInspector(model: model)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .quickLookPreview(url: $model.quickLookURL, in: model.previewURLs)
        .sheet(item: $model.trashConfirmation) { confirmation in
            MoveToTrashSheet(confirmation: confirmation) {
                Task { await model.confirmTrash(confirmation) }
            }
        }
        .sheet(item: $model.failureReport) { report in
            QuarantineFailureSheet(report: report)
                .onExitCommand { model.failureReport = nil }
        }
        .focusedSceneValue(\.screenActions, model.screenActions)
        .task(id: app.isReady) { await model.load() }
    }

    private var loaded: some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.m) {
                QuarantineBanner(totals: app.quarantineTotals, counts: model.counts)
                QuarantineHints(model: model, totals: app.quarantineTotals)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            if model.rows.isEmpty {
                EmptyStateView(
                    symbol: "archivebox",
                    title: "Nothing in quarantine",
                    message: "Items you quarantine wait here until you move them to the Trash.",
                )
                .frame(maxHeight: .infinity)
            } else {
                QuarantineBatchTable(model: model)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !model.rows.isEmpty {
                actionBar
            }
        }
    }

    private var actionBar: some View {
        let reason = model.disabledReason()
        let count = model.actionableRows().count
        let simulated = model.isSimulatedTrash()
        return SelectionActionBar(
            itemCount: count,
            bytes: model.actionableBytes,
            chipText: model.chipText,
            primary: SelectionAction(
                title: simulated
                    ? "Simulate Trash…"
                    : (count == 1 ? "Move to Trash…" : "Move \(count.formatted()) items to Trash…"),
                shortTitle: simulated ? "Simulate Trash…" : "Move to Trash…",
                systemImage: "trash",
                role: .destructive,
                disabledReason: reason,
                hint: simulated
                    ? "Dry run: only marks the entries as trashed. Nothing is moved on disk."
                    : "Moves the selected items from quarantine to the macOS Trash after you confirm.",
            ) {
                model.requestTrash()
            },
            secondary: SelectionAction(
                title: "Restore",
                systemImage: "arrow.uturn.backward",
                disabledReason: reason,
                hint: "Moves the selected items back to where they were found.",
            ) {
                Task { await model.restore() }
            },
            clear: { model.selection = [] },
        )
    }
}
