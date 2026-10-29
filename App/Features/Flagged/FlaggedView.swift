import MacSentryCore
import SwiftUI

struct FlaggedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        FlaggedContent(model: CandidateListModel(configuration: .forItem(.flagged), app: app))
    }
}

private struct FlaggedContent: View {
    @State var model: CandidateListModel

    var body: some View {
        CandidateScreenScaffold(model: model) {
            VStack(alignment: .leading, spacing: Space.s) {
                FilterBar(filter: $model.filter, defaults: model.defaultFilter, controls: model.configuration.controls)
                    .padding(.horizontal, Space.l)
                    .padding(.top, Space.s)
                Label("MacSentry never runs these commands. Copy one and run it in Terminal.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Space.l)
                if model.rows.isEmpty {
                    CandidateEmptyState(model: model)
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort By", selection: Binding(
                        get: { model.sort.column },
                        set: { model.sort = CandidateSort(column: $0, ascending: $0 == .name) },
                    )) {
                        Text("Size").tag(CandidateSort.Column.freeable)
                        Text("Name").tag(CandidateSort.Column.name)
                        Text("Tier").tag(CandidateSort.Column.tier)
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort flagged items")
            }
        }
    }

    private var list: some View {
        List(selection: $model.focusedIDs) {
            ForEach(model.rows) { group in
                Section(group.name) {
                    ForEach(group.children) { row in
                        if let candidate = row.candidate {
                            FlaggedRow(candidate: candidate)
                                .tag(row.id)
                                .contextMenu {
                                    CandidateContextMenu(model: model, ids: [row.id])
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .listItemTint(.monochrome)
        .onKeyPress(.space) {
            guard !model.focusedIDs.isEmpty else { return .ignored }
            model.toggleQuickLook()
            return .handled
        }
    }
}

private struct FlaggedRow: View {
    let candidate: Candidate
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(candidate.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s)
                TierLabel(candidate.tier, style: .compact)
                SizeText(candidate.freeableSize)
                    .font(.callout.weight(.medium))
            }
            Text(candidate.reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            PathText(candidate.url)
            if let command = candidate.resolvedCommand {
                HStack(alignment: .top, spacing: Space.s) {
                    Text(command)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: Radius.inset))
                    Button {
                        FinderActions.copy(command)
                        copied = true
                        AccessibilityNotification.Announcement("Command copied").post()
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(width: 72)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Copy command for \(candidate.name)")
                    .task(id: copied) {
                        guard copied else { return }
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
            }
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
    }
}
