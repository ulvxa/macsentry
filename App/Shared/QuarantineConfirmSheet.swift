import MacSentryCore
import SwiftUI

struct QuarantineConfirmation: Identifiable {
    struct Item: Identifiable {
        let id: Int
        let name: String
        let bytes: Int64
    }

    let id = UUID()
    let candidates: [Candidate]
    let title: String
    let totalBytes: Int64
    let nonSafeCount: Int
    let preview: [Item]
    let isDryRun: Bool
    let destination: String

    init(candidates: [Candidate], isDryRun: Bool, destination: String, noun: String = "items") {
        self.candidates = candidates
        self.isDryRun = isDryRun
        self.destination = destination
        title = candidates.count == 1 ? "Quarantine \(candidates[0].name)?" : "Quarantine \(candidates.count.formatted()) \(noun)?"
        totalBytes = candidates.reduce(0) { $0 + $1.freeableSize }
        nonSafeCount = candidates.count { $0.tier != .green }
        preview = candidates.prefix(5).enumerated().map { Item(id: $0.offset, name: $0.element.name, bytes: $0.element.freeableSize) }
    }

    var remainingCount: Int {
        candidates.count - preview.count
    }

    var message: String {
        "\(ByteFormat.string(totalBytes)) moves to \(destination). Nothing is deleted, and you can restore it."
    }
}

struct QuarantineConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss

    let confirmation: QuarantineConfirmation
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(confirmation.title)
                .font(.title3.weight(.semibold))
            Text(confirmation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if confirmation.isDryRun {
                Label("Dry run is on. Nothing will move.", systemImage: "eye")
                    .font(.callout)
            }
            if confirmation.nonSafeCount > 0 {
                Label(
                    confirmation.nonSafeCount == 1 ? "1 item is not marked Safe" : "\(confirmation.nonSafeCount) items are not marked Safe",
                    systemImage: "exclamationmark.triangle",
                )
                .font(.callout.weight(.medium))
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(confirmation.preview) { item in
                    HStack {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Space.l)
                        SizeText(item.bytes).foregroundStyle(.secondary)
                    }
                }
                if confirmation.remainingCount > 0 {
                    Text("and \(confirmation.remainingCount.formatted()) more")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack(spacing: Space.s) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glass)
                Button("Quarantine") {
                    dismiss()
                    confirm()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 400)
        .presentationSizing(.fitted)
    }
}
