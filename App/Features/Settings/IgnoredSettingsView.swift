import MacSentryCore
import SwiftUI

struct IgnoredSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [IgnoredPath] = []
    @State private var selection: Set<URL> = []

    var body: some View {
        Form {
            Section {
                Table(rows, selection: $selection) {
                    TableColumn("Path") { row in
                        Text(row.url.path(percentEncoded: false))
                            .font(.callout.monospaced())
                            .truncationMode(.middle)
                            .help(row.url.path(percentEncoded: false))
                    }
                    TableColumn("Ignored") { row in
                        Text(row.createdAt, format: .dateTime.year().month().day())
                            .foregroundStyle(.secondary)
                    }
                    .width(90)
                }
                .frame(minHeight: 260)
                .onDeleteCommand { stopIgnoring() }
                .contextMenu(forSelectionType: URL.self) { urls in
                    Button("Stop Ignoring", systemImage: "eye") { stopIgnoring(urls) }
                    Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(Array(urls)) }
                }

                HStack(spacing: 8) {
                    Button("Stop Ignoring", systemImage: "eye") { stopIgnoring() }
                        .disabled(selection.isEmpty)
                    Button("Stop Ignoring All") { stopIgnoring(Set(rows.map(\.url))) }
                        .disabled(rows.isEmpty)
                    Spacer()
                }
                .buttonStyle(.glass)
            } header: {
                Text("Ignored Items")
            } footer: {
                Text(
                    "Ignored items are hidden from results and skipped by scans. Stop ignoring to see them again.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing Ignored",
                    systemImage: "eye",
                    description: Text("Items you ignore from a list show up here."),
                )
            }
        }
        .task { await reload() }
    }

    private func stopIgnoring(_ urls: Set<URL>? = nil) {
        let targets = urls ?? selection
        guard !targets.isEmpty else { return }
        Task {
            await model.unignore(Array(targets))
            selection.subtract(targets)
            await reload()
        }
    }

    private func reload() async {
        rows = await model.ignoredPaths()
    }
}

extension IgnoredPath: @retroactive Identifiable {
    public var id: URL {
        url
    }
}
