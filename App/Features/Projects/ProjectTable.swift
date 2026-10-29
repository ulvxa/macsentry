import MacSentryCore
import SwiftUI

struct ProjectTable: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ProjectsModel

    var body: some View {
        Table(of: ProjectTableRow.self, selection: $model.focusedIDs, sortOrder: $model.sortOrder) {
            TableColumn("") { row in
                CheckboxCell(
                    state: model.checkState(of: row),
                    isEnabled: model.isEnabled(row),
                    label: "Select \(row.name)",
                ) {
                    model.toggleCheck(row)
                }
            }
            .width(28)
            TableColumn("Name", sortUsing: KeyPathComparator(\ProjectTableRow.name)) { row in
                ProjectNameCell(row: row, blockReason: row.artifact.flatMap(model.blockReason))
            }
            .width(min: 160, ideal: 220)
            TableColumn("Path", sortUsing: KeyPathComparator(\ProjectTableRow.path)) { row in
                ProjectPathCell(row: row)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Ecosystems") { row in
                EcosystemBadges(names: ecosystems(of: row))
            }
            .width(min: 110, ideal: 150)
            TableColumn("Last activity", sortUsing: KeyPathComparator(\ProjectTableRow.lastActivity)) { row in
                if row.isProject {
                    LastActivityText(project: row.entry.project)
                } else {
                    Text("")
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn("Status") { row in
                if let artifact = row.artifact {
                    TierLabel(artifact.tier, style: .compact)
                } else {
                    ProjectStatusBadge(entry: row.entry)
                }
            }
            .width(min: 110, ideal: 130)
            TableColumn("Artifacts", sortUsing: KeyPathComparator(\ProjectTableRow.freeable, order: .reverse)) { row in
                SizeText(row.freeable)
                    .fontWeight(row.isProject ? .semibold : .regular)
            }
            .width(min: 90, ideal: 100)
            .alignment(.numeric)
        } rows: {
            ForEach(model.rows) { row in
                DisclosureTableRow(row, isExpanded: expansion(for: row.id)) {
                    ForEach(row.children) { child in
                        TableRow(child)
                    }
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ProjectTableRow.ID.self) { ids in
            ProjectContextMenu(model: model, ids: ids)
        } primaryAction: { _ in
            app.toggleInspector()
        }
    }

    private func ecosystems(of row: ProjectTableRow) -> [String] {
        guard let artifact = row.artifact else { return row.entry.project.ecosystems }
        return artifact.ecosystemName.map { [$0] } ?? []
    }

    private func expansion(for id: ProjectTableRow.ID) -> Binding<Bool> {
        Binding(get: { model.isExpanded(id) }, set: { model.setExpanded(id, $0) })
    }
}

private struct ProjectContextMenu: View {
    let model: ProjectsModel
    let ids: Set<ProjectTableRow.ID>

    var body: some View {
        let urls = model.urls(for: ids)
        Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(urls) }
        Button("Copy Path", systemImage: "doc.on.doc") { FinderActions.copyPaths(urls) }
        Divider()
        Button("Ignore", systemImage: "eye.slash") { Task { await model.ignore(ids) } }
        Button("Add to Never Touch", systemImage: "hand.raised") { Task { await model.addToNeverTouch(ids) } }
    }
}

private struct ProjectNameCell: View {
    let row: ProjectTableRow
    let blockReason: String?

    var body: some View {
        HStack(spacing: Space.s) {
            if let artifact = row.artifact {
                Image(nsImage: FinderActions.icon(for: artifact.url))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(row.name)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let blockReason {
                    Image(systemName: "lock")
                        .foregroundStyle(.secondary)
                        .help(blockReason)
                        .accessibilityLabel(blockReason)
                }
            } else {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(row.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isProject ? "\(row.name) project" : "\(row.name) in \(row.entry.project.name)")
    }
}

private struct ProjectPathCell: View {
    let row: ProjectTableRow

    var body: some View {
        if row.isProject {
            PathText(row.entry.project.rootURL)
        } else {
            Text(row.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.path)
        }
    }
}

struct EcosystemBadge: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }
}

struct EcosystemBadges: View {
    static let visibleLimit = 3

    let names: [String]

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(names.prefix(Self.visibleLimit), id: \.self) { EcosystemBadge(name: $0) }
            if names.count > Self.visibleLimit {
                Text("+\(names.count - Self.visibleLimit)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(names.joined(separator: ", "))
    }
}

private struct LastActivityText: View {
    let project: Project

    var body: some View {
        Text(GraveyardPolicy.lastActivity(of: project), format: .relative(presentation: .named))
            .help(tooltip)
    }

    private var tooltip: String {
        let commit = project.lastCommitAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "none"
        return "Last commit: \(commit)\nLast file change: \(project.lastModifiedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct UncommittedBadge: View {
    var body: some View {
        Label("Uncommitted", systemImage: "pencil.circle")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .overlay(Capsule().stroke(.primary.opacity(0.4), lineWidth: 1))
            .help("This repository has changes that are not committed. Artifacts are never preselected.")
    }
}

private struct ProjectStatusBadge: View {
    let entry: ProjectEntry

    var body: some View {
        if entry.project.hasUncommitted {
            UncommittedBadge()
        } else if !entry.hasGit {
            Text("No git")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Not a git repository. Activity is based on file dates.")
        } else if !entry.hasKnownCommit {
            Text("Git unknown")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Git did not answer. Activity is based on file dates.")
        }
    }
}

extension Candidate {
    var ecosystemName: String? {
        let parts = ruleID.split(separator: ".", maxSplits: 2)
        guard parts.count == 3, parts[0] == "graveyard" else { return nil }
        return String(parts[1])
    }
}
