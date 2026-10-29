import MacSentryCore
import SwiftUI

struct CandidateScreenScaffold<Content: View, InspectorExtra: View>: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CandidateListModel
    @ViewBuilder let inspectorExtra: (Candidate) -> InspectorExtra
    @ViewBuilder let content: Content

    var body: some View {
        @Bindable var app = app
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noScan:
                ScanCallToAction(sectionTitle: model.configuration.noScanSubject)
            case .scanningNoData:
                ScanningPlaceholder()
            case let .failed(message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load results",
                    message: message,
                    action: .init(title: "Try Again") { model.retry() },
                )
            case .loaded:
                content
            }
        }
        .searchable(text: $model.filter.query, placement: .toolbar, prompt: "Filter by name or path")
        .deferredInspector(isPresented: $app.isInspectorPresented) {
            CandidateInspector(
                candidates: model.focusedCandidates,
                groupName: { app.ruleGroup(for: $0) },
                blockReason: model.blockReason,
                quickLook: { candidate in model.quickLookURL = candidate.url },
                extra: inspectorExtra,
            )
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .quickLookPreview(url: $model.quickLookURL, in: model.previewURLs)
        .sheet(item: $model.confirmation) { confirmation in
            QuarantineConfirmSheet(confirmation: confirmation) {
                Task { await model.confirm(confirmation) }
            }
        }
        .sheet(item: $model.failureReport) { report in
            QuarantineFailureSheet(report: report)
        }
        .focusedSceneValue(\.screenActions, model.screenActions)
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: app.currentSessionID) { _, sessionID in
            model.sessionChanged(to: sessionID)
        }
        .onChange(of: app.settings.thresholds) { _, thresholds in
            model.thresholdsChanged(to: thresholds)
        }
    }
}

extension CandidateScreenScaffold where InspectorExtra == EmptyView {
    init(model: CandidateListModel, @ViewBuilder content: () -> Content) {
        self.init(model: model, inspectorExtra: { _ in EmptyView() }, content: content)
    }
}

struct CandidateEmptyState: View {
    let model: CandidateListModel

    var body: some View {
        EmptyStateView(
            symbol: model.configuration.isCheckable ? "sparkles" : "flag",
            title: model.configuration.emptyTitle,
            message: model.configuration.emptyMessage,
            action: model.filter != filterDefaults ? .init(title: "Reset Filters") { model.filter = filterDefaults } : nil,
        )
    }

    private var filterDefaults: FilterState {
        var defaults = model.defaultFilter
        defaults.query = ""
        return defaults
    }
}
