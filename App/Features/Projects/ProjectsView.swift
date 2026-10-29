import MacSentryCore
import SwiftUI

struct ProjectsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ProjectsContent(model: ProjectsModel(app: app))
    }
}

private struct ProjectsContent: View {
    @Environment(AppModel.self) private var app
    @State var model: ProjectsModel

    var body: some View {
        @Bindable var app = app
        @Bindable var model = model
        Group {
            switch model.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noScan:
                ScanCallToAction(sectionTitle: "idle projects")
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
                loaded
            }
        }
        .searchable(text: $model.filter.query, placement: .toolbar, prompt: "Filter by name or path")
        .inspector(isPresented: $app.isInspectorPresented) {
            ProjectInspector(entries: model.focusedEntries, blockReason: model.blockReason)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
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
        .onChange(of: app.settings.projectIdleDays) { _, days in
            model.idleDaysChanged(to: days)
        }
    }

    private var loaded: some View {
        @Bindable var model = model
        return VStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xs) {
                FilterBar(filter: $model.filter, defaults: model.defaultFilter, controls: ProjectsModel.controls)
                if model.isOverridingIdleDays {
                    Text("Overrides Settings > Projects for this screen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.l)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.s)
            if model.rows.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                ProjectTable(model: model)
            }
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            if !model.entries.isEmpty {
                actionBar
            }
        }
    }

    private var emptyState: some View {
        var defaults = model.defaultFilter
        defaults.query = ""
        let differs = model.filter != defaults
        return EmptyStateView(
            symbol: "folder.badge.gearshape",
            title: "No idle projects",
            message: "Nothing has been idle for \(model.filter.minAgeDays) days. Lower the idle threshold to see more.",
            action: differs ? .init(title: "Reset Filters") { model.filter = defaults } : nil,
        )
    }

    private var actionBar: some View {
        SelectionActionBar(
            itemCount: model.checkedCandidates.count,
            bytes: model.checkedBytes,
            chipText: model.chipText,
            primary: SelectionAction(
                title: model.primaryTitle,
                shortTitle: model.primaryShortTitle,
                systemImage: "archivebox",
                disabledReason: model.quarantineDisabledReason,
                hint: "Moves the checked artifact folders to the MacSentry quarantine folder. Nothing is deleted.",
            ) {
                Task { await model.quarantineChecked() }
            },
            secondary: SelectionAction(
                title: "Ignore",
                disabledReason: model.checkedCandidates.isEmpty ? "Select artifacts to ignore" : nil,
            ) {
                Task { await model.ignoreChecked() }
            },
            selectDefault: model.hasDefaultSelectable ? SelectionAction(title: "Select Safe") { model.selectDefault() } : nil,
            clear: { model.clearChecks() },
        )
    }
}
