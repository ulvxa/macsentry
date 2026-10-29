import SwiftUI

struct MoveToTrashSheet: View {
    private enum Focus: Hashable {
        case cancel, confirm
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Focus?

    let confirmation: TrashConfirmation
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Image(systemName: "trash")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(confirmation.title)
                .font(.title3.weight(.semibold))
            Text(confirmation.isSimulated
                ? "This was recorded by a dry run, so nothing is in the quarantine folder to move."
                : "\(ByteFormat.string(confirmation.totalBytes)) moves from quarantine to the macOS Trash. " +
                "You can still use Put Back until you empty the Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if confirmation.isSimulated {
                Label("Dry run: the entries are only marked as trashed. Nothing will move on disk.", systemImage: "eye")
                    .font(.callout)
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
                Button(confirmation.isSimulated ? "Mark as Trashed" : "Move to Trash", role: .destructive) {
                    dismiss()
                    confirm()
                }
                .buttonStyle(.glass)
                .focused($focus, equals: .confirm)
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .focused($focus, equals: .cancel)
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
        .presentationSizing(.fitted)
        .defaultFocus($focus, .cancel)
        .onExitCommand { dismiss() }
        .accessibilityLabel(confirmation.title)
    }
}
