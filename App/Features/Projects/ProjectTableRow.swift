import Foundation
import MacSentryCore

struct ProjectEntry: Identifiable, Equatable {
    let project: Project
    let artifacts: [Candidate]
    let hasGit: Bool

    var id: Int64 {
        project.id ?? 0
    }

    var freeable: Int64 {
        artifacts.reduce(0) { $0 + $1.freeableSize }
    }

    var lastActivity: Date {
        GraveyardPolicy.lastActivity(of: project)
    }

    var hasKnownCommit: Bool {
        project.lastCommitAt != nil
    }
}

struct ProjectTableRow: Identifiable {
    // swiftlint:disable:next type_name
    enum ID: Hashable {
        case project(Int64)
        case artifact(Int64)
    }

    let id: ID
    let name: String
    let path: String
    let freeable: Int64
    let lastActivity: Date
    let entry: ProjectEntry
    let artifact: Candidate?
    let children: [ProjectTableRow]

    var isProject: Bool {
        artifact == nil
    }

    init(entry: ProjectEntry) {
        id = .project(entry.id)
        name = entry.project.name
        path = entry.project.rootURL.path(percentEncoded: false)
        freeable = entry.freeable
        lastActivity = entry.lastActivity
        self.entry = entry
        artifact = nil
        children = entry.artifacts.compactMap { ProjectTableRow(entry: entry, artifact: $0) }
    }

    private init?(entry: ProjectEntry, artifact: Candidate) {
        guard let artifactID = artifact.id else { return nil }
        id = .artifact(artifactID)
        name = artifact.name
        path = artifact.url.path(percentEncoded: false)
        freeable = artifact.freeableSize
        lastActivity = entry.lastActivity
        self.entry = entry
        self.artifact = artifact
        children = []
    }

    var artifacts: [Candidate] {
        artifact.map { [$0] } ?? entry.artifacts
    }

    var relativePath: String {
        guard let artifact else { return path }
        let root = entry.project.rootURL.path(percentEncoded: false)
        let full = artifact.url.path(percentEncoded: false)
        guard full.hasPrefix(root + "/") else { return full }
        return entry.project.name + "/" + full.dropFirst(root.count + 1)
    }
}
