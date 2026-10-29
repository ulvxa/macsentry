import MacSentryCore
import SwiftUI

struct OrphansView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        OrphansContent(model: CandidateListModel(configuration: .forItem(.orphans), app: app))
    }
}

private struct OrphansContent: View {
    @State var model: CandidateListModel

    var body: some View {
        CandidateScreenScaffold(model: model) { candidate in
            OrphanInspectorSection(candidate: candidate)
        } content: {
            VStack(spacing: Space.s) {
                FilterBar(filter: $model.filter, defaults: model.defaultFilter, controls: model.configuration.controls)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
                if model.rows.isEmpty {
                    CandidateEmptyState(model: model)
                        .frame(maxHeight: .infinity)
                } else {
                    OrphanTable(model: model)
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
            clear: { model.clearChecks() },
        )
    }
}

private struct OrphanTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CandidateListModel

    var body: some View {
        let sections = OrphanSections.rows(model.candidates)
        Table(of: CandidateRow.self, selection: $model.focusedIDs, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                CheckboxCell(
                    state: model.checkState(of: row),
                    isEnabled: model.canToggle(row),
                    label: "Select \(row.name)",
                ) {
                    model.toggleCheck(row)
                }
                .help(row.candidate?.action == .flagOnly ? "Unload it with the command in the inspector" : "Select \(row.name)")
            }
            .width(28)
            TableColumn("App", sortUsing: KeyPathComparator(\CandidateRow.name)) { row in
                OrphanNameCell(row: row, blockReason: row.candidate.flatMap(model.blockReason))
            }
            .width(min: 160, ideal: 200)
            TableColumn("Location", sortUsing: KeyPathComparator(\CandidateRow.path)) { row in
                if let candidate = row.candidate {
                    PathText(candidate.url)
                } else {
                    Text(row.name == Confidence.low.sectionTitle
                        ? "\(CountFormat.items(row.children.count)) · may belong to command line tools"
                        : CountFormat.items(row.children.count))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 140, ideal: 260)
            TableColumn("Type") { row in
                if let candidate = row.candidate {
                    Text(OrphanDetails.location(of: candidate)?.title ?? "Library")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 90, ideal: 130)
            TableColumn("Will free", sortUsing: KeyPathComparator(\CandidateRow.freeable, order: .reverse)) { row in
                SizeText(row.freeable)
                    .fontWeight(row.isGroup ? .semibold : .regular)
            }
            .width(min: 80, ideal: 96)
            .alignment(.numeric)
            TableColumn("Last modified", sortUsing: KeyPathComparator(\CandidateRow.lastUsedSortKey)) { row in
                if let candidate = row.candidate {
                    RelativeDateText(candidate.modifiedAt)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Tier", sortUsing: KeyPathComparator(\CandidateRow.tierRank)) { row in
                if let tier = row.tier {
                    TierLabel(tier, style: .compact)
                }
            }
            .width(min: 96, ideal: 112)
        } rows: {
            ForEach(sections) { section in
                DisclosureTableRow(section, isExpanded: expansion(for: section.name)) {
                    ForEach(section.children) { child in
                        TableRow(child)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: CandidateRow.ID.self) { ids in
            CandidateContextMenu(model: model, ids: ids)
        } primaryAction: { _ in
            app.toggleInspector()
        }
        .onKeyPress(.space) {
            guard !model.focusedIDs.isEmpty else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
    }

    private func expansion(for section: String) -> Binding<Bool> {
        Binding(get: { model.isExpanded(section) }, set: { model.setExpanded(section, $0) })
    }
}

private struct OrphanNameCell: View {
    let row: CandidateRow
    let blockReason: String?

    var body: some View {
        HStack(spacing: Space.s) {
            if let candidate = row.candidate {
                let details = OrphanDetails(candidate: candidate)
                Image(systemName: "questionmark.app")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(details.appName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(details.identity)
                if candidate.action == .flagOnly {
                    Image(systemName: "flag")
                        .foregroundStyle(.secondary)
                        .help("Flagged: needs a command to unload")
                        .accessibilityLabel("Flagged")
                }
                if let blockReason {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .help(blockReason)
                        .accessibilityLabel(blockReason)
                }
            } else {
                Text(row.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isGroup ? row.name : row.candidate.map { OrphanDetails(candidate: $0).appName } ?? row.name)
    }
}
