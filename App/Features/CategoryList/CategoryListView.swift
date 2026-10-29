import MacSentryCore
import SwiftUI

struct CategoryListView: View {
    @Environment(AppModel.self) private var app
    let item: SidebarItem

    var body: some View {
        CategoryListContent(model: CandidateListModel(configuration: .forItem(item), app: app))
    }
}

private struct CategoryListContent: View {
    @State var model: CandidateListModel

    var body: some View {
        CandidateScreenScaffold(model: model) {
            VStack(spacing: Space.s) {
                FilterBar(filter: $model.filter, defaults: model.defaultFilter, controls: model.configuration.controls)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
                if model.rows.isEmpty {
                    CandidateEmptyState(model: model)
                        .frame(maxHeight: .infinity)
                } else {
                    CandidateTable(model: model)
                }
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                if !model.candidates.isEmpty {
                    actionBar
                }
            }
        }
    }

    private var actionBar: some View {
        SelectionActionBar(
            itemCount: model.checkedCandidates.count,
            bytes: model.checkedBytes,
            primary: SelectionAction(
                title: model.primaryTitle,
                shortTitle: model.primaryShortTitle,
                systemImage: "archivebox",
                disabledReason: model.quarantineDisabledReason,
                hint: "Moves the checked items to the MacSentry quarantine folder. Nothing is deleted.",
            ) {
                Task { await model.quarantineChecked() }
            },
            secondary: SelectionAction(title: "Ignore", disabledReason: model.checkedCandidates.isEmpty ? "Select items to ignore" : nil) {
                Task { await model.ignoreChecked() }
            },
            selectDefault: model.hasDefaultSelectable ? SelectionAction(title: "Select Safe") { model.selectDefault() } : nil,
            clear: { model.clearChecks() },
        )
    }
}
