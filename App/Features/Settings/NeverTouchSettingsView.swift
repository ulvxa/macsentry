import MacSentryCore
import SwiftUI

struct NeverTouchSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let neverTouch = model.neverTouch {
            NeverTouchForm(model: neverTouch)
        } else {
            ContentUnavailableView(
                "Never Touch Unavailable",
                systemImage: "hand.raised",
                description: Text("The database is still opening or could not be opened."),
            )
        }
    }
}

private struct NeverTouchForm: View {
    @Bindable var model: NeverTouchModel
    @State private var selection: Set<Int64> = []
    @State private var showsBuiltIn = false

    var body: some View {
        Form {
            Section {
                DisclosureGroup("Built in protections", isExpanded: $showsBuiltIn) {
                    ForEach(DefaultProtectionPolicy.builtInSummary, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Your Patterns") {
                Table(model.rows, selection: $selection) {
                    TableColumn("Pattern") { pattern in
                        HStack(spacing: 4) {
                            if pattern.protectsEverything {
                                Image(systemName: "exclamationmark.triangle")
                                    .help(GlobWarning.protectsEverything.message)
                                    .accessibilityLabel(GlobWarning.protectsEverything.message)
                            }
                            Text(pattern.pattern).font(.callout.monospaced())
                        }
                    }
                    TableColumn("Note") { pattern in
                        Text(pattern.note ?? "").foregroundStyle(.secondary)
                    }
                    TableColumn("Added") { pattern in
                        Text(pattern.createdAt, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    }
                    .width(90)
                }
                .frame(minHeight: 120)
                .onDeleteCommand { remove() }

                HStack(spacing: 8) {
                    TextField("Pattern", text: $model.draftPattern, prompt: Text("~/Work/ClientWork/**"))
                        .font(.callout.monospaced())
                        .onSubmit { Task { await model.add() } }
                    TextField("Note", text: $model.draftNote, prompt: Text("Optional note"))
                        .frame(width: 150)
                        .onSubmit { Task { await model.add() } }
                }
                .labelsHidden()
                if let message = model.draftError ?? model.errorMessage {
                    InlineMessage(systemImage: "xmark.octagon", text: message)
                } else if let warning = model.draftWarning {
                    InlineMessage(systemImage: "exclamationmark.triangle", text: warning)
                }
                HStack(spacing: 8) {
                    Button("Add", systemImage: "plus") { Task { await model.add() } }
                        .disabled(!model.canAdd)
                    Button("Remove", systemImage: "minus") { remove() }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Text("Supports *, ** and ?. ~ is your home folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.glass)
            }

            Section("Test a Path") {
                TextField("Path", text: $model.testPath, prompt: Text("Type a path to see if it is protected"))
                    .font(.callout.monospaced())
                    .labelsHidden()
                switch model.testVerdict {
                case nil:
                    EmptyView()
                case .allowed:
                    InlineMessage(systemImage: "checkmark.circle", text: "Not protected. MacSentry may suggest cleaning it.")
                case let .denied(reason):
                    InlineMessage(systemImage: "lock.shield", text: "Protected: \(reason)")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func remove() {
        let ids = selection
        selection = []
        Task { await model.remove(ids: ids) }
    }
}

private struct InlineMessage: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}
