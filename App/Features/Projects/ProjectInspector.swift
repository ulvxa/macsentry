import MacSentryCore
import SwiftUI

struct ProjectInspector: View {
    let entries: [ProjectEntry]
    let blockReason: (Candidate) -> String?

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.trailing",
                description: Text("Select a project to see details."),
            )
        } else if entries.count == 1, let entry = entries.first {
            ScrollView {
                SingleProjectDetails(entry: entry, blockReason: blockReason)
                    .padding(Space.l)
            }
        } else {
            ScrollView {
                MultipleProjectDetails(entries: entries)
                    .padding(Space.l)
            }
        }
    }
}

private struct SingleProjectDetails: View {
    let entry: ProjectEntry
    let blockReason: (Candidate) -> String?

    var body: some View {
        let project = entry.project
        let exists = FileManager.default.fileExists(atPath: project.rootURL.path(percentEncoded: false))
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(project.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                EcosystemBadges(names: project.ecosystems)
                if project.hasUncommitted {
                    UncommittedBadge()
                        .padding(.top, Space.xs)
                }
            }
            ForEach(notes, id: \.self) { note in
                Label(note.text, systemImage: note.systemImage)
                    .font(.callout)
                    .padding(Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: .rect(cornerRadius: Radius.inset))
            }
            Divider()
            InspectorSection(title: "Path") {
                PathText(project.rootURL, style: .block)
            }
            InspectorSection(title: "Activity") {
                LabeledContent("Last activity") { RelativeDateText(entry.lastActivity) }
                LabeledContent("Last commit") { RelativeDateText(project.lastCommitAt) }
                LabeledContent("Last file change") { RelativeDateText(project.lastModifiedAt) }
            }
            .font(.callout)
            VStack(spacing: Space.s) {
                Button("Open in Finder", systemImage: "folder") { ProjectActions.openInFinder(project.rootURL) }
                Button("Open in Terminal", systemImage: "terminal") { ProjectActions.openInTerminal(project.rootURL) }
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
            .disabled(!exists)
            InspectorSection(title: "Artifacts") {
                LabeledContent("Will free") { SizeText(entry.freeable).fontWeight(.semibold) }
                    .font(.callout)
                ForEach(entry.artifacts, id: \.id) { artifact in
                    ArtifactDetails(project: project, artifact: artifact, blockReason: blockReason(artifact))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notes: [ProjectNote] {
        var result: [ProjectNote] = []
        if !entry.hasGit {
            result.append(ProjectNote(text: "Not a git repository. Using file dates.", systemImage: "info.circle"))
        } else if !entry.hasKnownCommit {
            result.append(ProjectNote(text: "Git unavailable. Using file dates.", systemImage: "exclamationmark.triangle"))
        }
        if entry.project.hasUncommitted {
            result.append(ProjectNote(
                text: "Uncommitted changes, or git could not say. Artifacts of this project are never selected by default.",
                systemImage: "pencil.circle",
            ))
        }
        return result
    }
}

private struct ProjectNote: Hashable {
    let text: String
    let systemImage: String
}

private struct ArtifactDetails: View {
    let project: Project
    let artifact: Candidate
    let blockReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Text(relativeName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Space.s)
                SizeText(artifact.freeableSize)
                    .font(.callout)
                TierLabel(artifact.tier, style: .compact)
            }
            Text("Safe to regenerate")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let blockReason {
                Label(blockReason, systemImage: "lock")
                    .font(.caption)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: Radius.inset))
        .accessibilityElement(children: .combine)
    }

    private var relativeName: String {
        let root = project.rootURL.path(percentEncoded: false)
        let full = artifact.url.path(percentEncoded: false)
        return full.hasPrefix(root + "/") ? String(full.dropFirst(root.count + 1)) : artifact.name
    }

    private var hint: AttributedString {
        let text = artifact.regenerationHint ?? artifact.reason
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

private struct MultipleProjectDetails: View {
    let entries: [ProjectEntry]

    var body: some View {
        let urls = entries.map(\.project.rootURL)
        VStack(alignment: .leading, spacing: Space.l) {
            Text(ProjectsModel.projectCount(entries.count))
                .font(.title3.weight(.semibold))
            InspectorSection(title: "Artifacts will free") {
                SizeText(entries.reduce(0) { $0 + $1.freeable }, style: .card)
            }
            VStack(spacing: Space.s) {
                Button("Reveal in Finder", systemImage: "folder") { FinderActions.reveal(urls) }
                Button("Copy Paths", systemImage: "doc.on.doc") { FinderActions.copyPaths(urls) }
            }
            .buttonStyle(.bordered)
            .buttonSizing(.flexible)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
