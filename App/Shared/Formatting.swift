import Foundation
import MacSentryCore

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum DurationFormat {
    static func string(_ duration: Duration) -> String {
        let total = max(Int(duration.components.seconds), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours) h \(minutes) min"
        }
        if minutes > 0 {
            return "\(minutes) min \(seconds) s"
        }
        return "\(seconds) s"
    }
}

enum CountFormat {
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}

extension Tier {
    var word: String {
        switch self {
        case .green: "Safe"
        case .yellow: "Rebuildable"
        case .red: "Careful"
        }
    }

    var systemImage: String {
        switch self {
        case .green: "checkmark.circle"
        case .yellow: "arrow.triangle.2.circlepath.circle"
        case .red: "exclamationmark.octagon"
        }
    }

    var meaning: String {
        switch self {
        case .green: "Regenerates automatically"
        case .yellow: "Costs time or bandwidth to rebuild"
        case .red: "Your data or hard to recover. Review every item"
        }
    }

    var rank: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        }
    }
}

extension ScanPhase {
    var label: String {
        switch self {
        case .walking: "Walking disk"
        case .evaluatingRules: "Evaluating rules"
        case .projects: "Finding projects"
        case .orphans: "Finding orphans"
        case .duplicates: "Hashing duplicates"
        case .lastUsed: "Resolving last used"
        }
    }
}

extension MacSentryCore.Category {
    var title: String {
        switch self {
        case .devCache: "Dev Cache"
        case .appCache: "App Cache"
        case .oldLarge: "Old and Large"
        case .projectArtifact: "Project Artifact"
        case .orphan: "Orphan"
        case .duplicate: "Duplicate"
        case .flagged: "Flagged"
        }
    }
}

extension CandidateKind {
    var title: String {
        switch self {
        case .file: "File"
        case .folder: "Folder"
        case .package: "Package"
        }
    }
}

extension Candidate {
    var name: String {
        url.lastPathComponent
    }

    var resolvedCommand: String? {
        guard let cliCommand, !cliCommand.isEmpty else { return nil }
        let quoted = "'" + url.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''") + "'"
        return cliCommand.replacingOccurrences(of: "{path}", with: quoted)
    }
}
