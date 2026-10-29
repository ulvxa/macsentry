import MacSentryCore
import SwiftUI

struct QuarantineBatchTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: QuarantineModel

    var body: some View {
        Table(of: QuarantineRow.self, selection: $model.selection) {
            TableColumn("Name") { row in
                QuarantineNameCell(row: row)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Items") { row in
                if row.isBatch {
                    Text(row.batch.itemCount.formatted()).monospacedDigit()
                }
            }
            .width(min: 44, ideal: 56)
            .alignment(.numeric)
            TableColumn("Size") { row in
                SizeText(row.size)
                    .fontWeight(row.isBatch ? .semibold : .regular)
            }
            .width(min: 72, ideal: 90)
            .alignment(.numeric)
            TableColumn("Tiers") { row in
                if let entry = row.entry {
                    TierLabel(entry.tier, style: .compact)
                } else {
                    TierSummary(counts: row.batch.tiers.mapValues(\.count))
                }
            }
            .width(min: 96, ideal: 180)
            TableColumn("Status") { row in
                if let entry = row.entry {
                    QuarantineStatusLabel(status: entry.status, isFreed: row.isFreed)
                }
            }
            .width(min: 96, ideal: 120)
            TableColumn("Original Location") { row in
                if let entry = row.entry {
                    PathText(entry.originalURL.deletingLastPathComponent())
                }
            }
            .width(min: 140, ideal: 260)
        } rows: {
            ForEach(model.rows) { row in
                DisclosureTableRow(row, isExpanded: expansion(for: row.batch.id)) {
                    ForEach(row.children) { child in
                        TableRow(child)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: QuarantineRow.ID.self) { ids in
            QuarantineContextMenu(model: model, ids: ids)
        } primaryAction: { _ in
            app.toggleInspector()
        }
        .onKeyPress(.space) {
            guard !model.selection.isEmpty else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
    }

    private func expansion(for batchID: String) -> Binding<Bool> {
        Binding(get: { model.isExpanded(batchID) }, set: { model.setExpanded(batchID, $0) })
    }
}

private struct QuarantineContextMenu: View {
    let model: QuarantineModel
    let ids: Set<QuarantineRow.ID>

    var body: some View {
        let locations = model.locations(for: ids)
        let reason = model.disabledReason(for: ids)
        Button("Reveal in Finder", systemImage: "folder") { model.reveal(ids) }
            .disabled(locations.isEmpty)
        Button("Quick Look", systemImage: "eye") { model.quickLook(ids) }
            .disabled(locations.isEmpty)
        Button("Copy Original Path", systemImage: "doc.on.doc") {
            FinderActions.copyPaths(model.entryRows(for: ids).compactMap(\.entry?.originalURL))
        }
        Divider()
        Button("Restore", systemImage: "arrow.uturn.backward") { Task { await model.restore(ids) } }
            .disabled(reason != nil)
        Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestTrash(ids) }
            .disabled(reason != nil)
        if let reason, reason == QuarantineModel.putBackHint {
            Text(reason)
        }
    }
}

private struct QuarantineNameCell: View {
    let row: QuarantineRow

    var body: some View {
        HStack(spacing: Space.s) {
            if let entry = row.entry {
                Image(nsImage: FinderActions.icon(for: row.location ?? entry.originalURL))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(row.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if row.isDryRun {
                    DryRunBadge(style: .tag)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isBatch ? "Batch from \(row.name)\(row.isDryRun ? ", dry run" : "")" : row.name)
    }
}

struct QuarantineStatusLabel: View {
    let status: QuarantineStatus
    var isFreed = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(status == .inQuarantine || status == .restored ? .primary : .secondary)
            .help(help)
            .accessibilityLabel(title)
    }

    private var title: String {
        switch status {
        case .inQuarantine: "In quarantine"
        case .trashed: isFreed ? "Freed" : "In Trash"
        case .restored: "Restored"
        case .missing: "Missing"
        }
    }

    private var systemImage: String {
        switch status {
        case .inQuarantine: "archivebox"
        case .trashed: isFreed ? "checkmark.circle" : "trash"
        case .restored: "arrow.uturn.backward.circle"
        case .missing: "questionmark.circle"
        }
    }

    private var help: String {
        switch status {
        case .inQuarantine: "Waiting in the MacSentry quarantine folder"
        case .trashed: isFreed ? "The Trash was emptied, so the space is free" : QuarantineModel.putBackHint
        case .restored: "Moved back to its original location"
        case .missing: "The file is no longer in the quarantine folder"
        }
    }
}
