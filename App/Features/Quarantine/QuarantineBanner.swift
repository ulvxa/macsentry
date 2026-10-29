import MacSentryCore
import SwiftUI

struct QuarantineBanner: View {
    let totals: QuarantineTotals?
    let counts: QuarantineModel.Counts

    var body: some View {
        HStack(spacing: Space.l) {
            StatColumn(
                label: "In quarantine",
                bytes: totals?.inQuarantine ?? 0,
                caption: counts.items == 0
                    ? "Nothing waiting"
                    : "\(CountFormat.items(counts.items)), \(counts.batches == 1 ? "1 batch" : "\(counts.batches.formatted()) batches")",
            )
            Divider()
            StatColumn(
                label: "In Trash",
                bytes: totals?.inTrash ?? 0,
                caption: (totals?.inTrash ?? 0) > 0 ? "Empty the Trash to free it" : "Nothing in the Trash",
            )
            Divider()
            StatColumn(
                label: "Freed this month",
                bytes: totals?.freedThisMonth ?? 0,
                caption: (totals?.freedThisMonth ?? 0) > 0 ? "Since \(Self.startOfMonth)" : "Nothing freed yet",
            )
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Space.l)
        .padding(.horizontal, Space.xl)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.card))
        .accessibilityElement(children: .contain)
    }

    private static var startOfMonth: String {
        let start = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        return start.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct StatColumn: View {
    let label: String
    let bytes: Int64
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            SizeText(bytes, style: .stat)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(ByteFormat.string(bytes)), \(caption)")
    }
}

struct QuarantineHints: View {
    let model: QuarantineModel
    let totals: QuarantineTotals?

    var body: some View {
        let inTrash = totals?.inTrash ?? 0
        let dryRun = totals?.dryRunInQuarantine ?? 0
        if inTrash > 0 {
            HStack(spacing: Space.m) {
                Label("\(ByteFormat.string(inTrash)) is in the Trash, empty it to free space", systemImage: "trash")
                    .font(.callout)
                Spacer(minLength: Space.l)
                Button("Open Trash") { model.openTrash() }
                    .buttonStyle(.glass)
                    .help("Opens the Trash in Finder")
            }
        }
        if dryRun > 0 || model.app.environment.isDryRun {
            HStack(spacing: Space.m) {
                DryRunBadge(style: .tag)
                Text(dryRun > 0
                    ? "\(ByteFormat.string(dryRun)) recorded by dry runs. Nothing was moved, so it is not counted above."
                    : "Dry run is on. Real batches can't be trashed or restored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        if let untracked = model.app.reconcileReport?.untracked, !untracked.isEmpty {
            HStack(spacing: Space.m) {
                Label(untrackedMessage(untracked.count), systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.l)
                Button("Reveal") { FinderActions.reveal(untracked) }
                    .buttonStyle(.glass)
                    .help("Shows the untracked items in Finder")
            }
        }
    }
}

private func untrackedMessage(_ count: Int) -> String {
    count == 1
        ? "1 untracked item is in the quarantine folder. It was left in place."
        : "\(count.formatted()) untracked items are in the quarantine folder. They were left in place."
}
