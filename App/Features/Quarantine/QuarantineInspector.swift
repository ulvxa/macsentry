import MacSentryCore
import SwiftUI

struct QuarantineInspector: View {
    let model: QuarantineModel

    var body: some View {
        let rows = model.focusedRows
        if let batch = model.focusedBatch {
            ScrollView {
                BatchDetails(model: model, row: batch).padding(Space.l)
            }
        } else if rows.count == 1, let row = rows.first, let entry = row.entry {
            ScrollView {
                EntryDetails(model: model, row: row, entry: entry).padding(Space.l)
            }
        } else if !rows.isEmpty {
            ScrollView {
                MultipleEntryDetails(model: model, rows: rows).padding(Space.l)
            }
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.trailing",
                description: Text("Select a batch or an item to see details."),
            )
        }
    }
}

private struct EntryDetails: View {
    let model: QuarantineModel
    let row: QuarantineRow
    let entry: QuarantineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(row.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                SizeText(entry.size, style: .card)
                HStack(spacing: Space.m) {
                    TierLabel(entry.tier)
                    QuarantineStatusLabel(status: entry.status, isFreed: row.isFreed)
                }
            }
            if entry.status == .trashed, !row.isFreed {
                Label(QuarantineModel.putBackHint, systemImage: "info.circle")
                    .font(.callout)
            }
            InspectorSection(title: "Original Location") {
                PathText(entry.originalURL, style: .block)
            }
            if !row.isDryRun, entry.status == .inQuarantine {
                InspectorSection(title: "In Quarantine") {
                    PathText(entry.quarantineURL, style: .block)
                }
            }
            if let trashURL = entry.trashURL, entry.status == .trashed {
                InspectorSection(title: row.isFreed ? "Was in Trash" : "In Trash") {
                    PathText(trashURL, style: .block)
                }
            }
            InspectorSection(title: "Batch") {
                HStack(spacing: Space.s) {
                    Text(row.batch.batch.createdAt.formatted(QuarantineRow.batchDateStyle))
                        .font(.callout)
                    if row.isDryRun {
                        DryRunBadge(style: .tag)
                    }
                }
                Text("Rule \(entry.ruleID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            InspectorActions(model: model, ids: [row.id])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BatchDetails: View {
    let model: QuarantineModel
    let row: QuarantineRow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.s) {
                    Text(row.name).font(.title3.weight(.semibold))
                    if row.isDryRun {
                        DryRunBadge(style: .tag)
                    }
                }
                SizeText(row.size, style: .card)
                Text(CountFormat.items(row.batch.itemCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TierSummary(counts: row.batch.tiers.mapValues(\.count))
            }
            InspectorSection(title: "Folder") {
                Text(row.batch.batch.folderName)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            InspectorActions(model: model, ids: [row.id])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MultipleEntryDetails: View {
    let model: QuarantineModel
    let rows: [QuarantineRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.s) {
                Text(CountFormat.items(rows.count)).font(.title3.weight(.semibold))
                SizeText(rows.reduce(0) { $0 + $1.size }, style: .card)
                TierSummary(counts: rows.compactMap(\.entry).reduce(into: [:]) { $0[$1.tier, default: 0] += 1 })
            }
            InspectorActions(model: model, ids: model.selection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorActions: View {
    let model: QuarantineModel
    let ids: Set<QuarantineRow.ID>

    var body: some View {
        let locations = model.locations(for: ids)
        let reason = model.disabledReason(for: ids)
        VStack(spacing: Space.s) {
            Button("Reveal in Finder", systemImage: "folder") { model.reveal(ids) }
                .disabled(locations.isEmpty)
            Button("Quick Look", systemImage: "eye") { model.quickLook(ids) }
                .disabled(locations.isEmpty)
            Button("Restore", systemImage: "arrow.uturn.backward") { Task { await model.restore(ids) } }
                .disabled(reason != nil)
                .help(reason ?? "Move back to the original location")
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.requestTrash(ids) }
                .disabled(reason != nil)
                .help(reason ?? "Move to the macOS Trash after you confirm")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .buttonSizing(.flexible)
    }
}
