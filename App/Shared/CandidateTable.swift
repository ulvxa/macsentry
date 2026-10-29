import MacSentryCore
import SwiftUI

struct CandidateTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: CandidateListModel

    var body: some View {
        Table(of: CandidateRow.self, selection: $model.focusedIDs, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                CheckboxCell(
                    state: model.checkState(of: row),
                    isEnabled: row.candidate.map { !model.isBlocked($0) } ?? true,
                    label: "Select \(row.name)",
                ) {
                    model.toggleCheck(row)
                }
            }
            .width(28)
            TableColumn("Name", sortUsing: KeyPathComparator(\CandidateRow.name)) { row in
                NameCell(row: row, blockReason: row.candidate.flatMap(model.blockReason))
            }
            .width(min: 160, ideal: 220)
            TableColumn("Location", sortUsing: KeyPathComparator(\CandidateRow.path)) { row in
                if let candidate = row.candidate {
                    PathText(candidate.url.deletingLastPathComponent())
                } else {
                    Text(CountFormat.items(row.children.count))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 140, ideal: 260)
            TableColumn("Will free", sortUsing: KeyPathComparator(\CandidateRow.freeable, order: .reverse)) { row in
                FreeableCell(row: row)
            }
            .width(min: 80, ideal: 96)
            .alignment(.numeric)
            TableColumn("Last used", sortUsing: KeyPathComparator(\CandidateRow.lastUsedSortKey)) { row in
                if row.isGroup {
                    Text("")
                } else {
                    RelativeDateText(row.lastUsed)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Tier", sortUsing: KeyPathComparator(\CandidateRow.tierRank)) { row in
                if let tier = row.tier {
                    TierLabel(tier, style: .compact)
                }
            }
            .width(min: 96, ideal: 112)
            if !model.configuration.groupsByRule {
                TableColumn("Group", sortUsing: KeyPathComparator(\CandidateRow.group)) { row in
                    Text(row.group).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 120)
            }
        } rows: {
            ForEach(model.rows) { row in
                if row.isGroup {
                    DisclosureTableRow(row, isExpanded: expansion(for: row.name)) {
                        ForEach(row.children) { child in
                            TableRow(child)
                        }
                    }
                } else {
                    TableRow(row)
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

    private func expansion(for group: String) -> Binding<Bool> {
        Binding(get: { model.isExpanded(group) }, set: { model.setExpanded(group, $0) })
    }
}

struct CandidateContextMenu: View {
    let model: CandidateListModel
    let ids: Set<CandidateRow.ID>

    var body: some View {
        let targets = model.candidates(for: ids)
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(targets.map(\.url)) }
        Button("Quick Look", systemImage: "eye") { model.quickLook(ids) }
        Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths(targets.map(\.url)) }
        if let command = targets.first?.resolvedCommand, targets.count == 1 {
            Button("Copy Command", systemImage: "terminal") { FinderActions.copy(command) }
        }
        Divider()
        Button("Ignore", systemImage: "eye.slash") { Task { await model.ignore(ids) } }
        Button("Add to Never Touch", systemImage: "hand.raised") { Task { await model.addToNeverTouch(ids) } }
    }
}

private struct NameCell: View {
    let row: CandidateRow
    let blockReason: String?

    var body: some View {
        HStack(spacing: Space.s) {
            if let candidate = row.candidate {
                AppIconView(bundleID: candidate.appBundleID, fallback: candidate.url)
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
        .accessibilityLabel(row.isGroup ? "\(row.name) group" : "\(row.name), \(row.group)")
    }
}

private struct FreeableCell: View {
    let row: CandidateRow

    var body: some View {
        if let candidate = row.candidate {
            let shared = candidate.logicalSize > 0 && candidate.freeableSize * 20 < candidate.logicalSize
            SizeText(candidate.freeableSize)
                .foregroundStyle(shared ? .secondary : .primary)
                .help(shared ? "Shared with APFS clones or hard links" : ByteFormat.string(candidate.freeableSize))
        } else {
            SizeText(row.freeable)
                .fontWeight(.semibold)
        }
    }
}
