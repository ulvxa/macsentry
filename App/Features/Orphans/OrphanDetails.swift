import Foundation
import MacSentryCore

struct OrphanDetails: Equatable {
    static let oldVersionRuleID = "orphan.oldVersion"
    private static let ownerPrefix = "No installed app owns \""
    private static let ownerSuffix = "\": "

    let location: OrphanLocation?
    let identity: String
    let appName: String
    let isOlderVersion: Bool
    let failedChecks: [OrphanCheck]
    let notes: [String]

    init(candidate: Candidate) {
        location = Self.location(of: candidate)
        isOlderVersion = candidate.ruleID == Self.oldVersionRuleID
        let reason = candidate.reason
        if isOlderVersion {
            identity = candidate.name
            let rest = reason.hasPrefix(DefaultOrphanDetector.olderVersionReason + ". ")
                ? String(reason.dropFirst(DefaultOrphanDetector.olderVersionReason.count + 2))
                : ""
            appName = Self.installedAppName(in: rest) ?? candidate.name
            failedChecks = []
            notes = Self.sentences(rest)
        } else if let owner = Self.parseOwner(reason) {
            identity = owner.identity
            appName = OrphanExplanation.guessedAppName(for: owner.identity)
            failedChecks = OrphanCheck.allCases.filter { owner.checks.contains($0.failureDescription) }
            notes = Self.sentences(owner.notes)
        } else {
            identity = candidate.name
            appName = OrphanExplanation.guessedAppName(for: candidate.url.deletingPathExtension().lastPathComponent)
            failedChecks = []
            notes = Self.sentences(reason)
        }
    }

    var locationTitle: String {
        location?.title ?? "Library"
    }

    static func location(of candidate: Candidate) -> OrphanLocation? {
        if candidate.ruleID.hasPrefix("orphan."), let location = OrphanLocation(rawValue: String(candidate.ruleID.dropFirst(7))) {
            return location
        }
        let components = candidate.url.pathComponents
        for index in components.indices.dropLast() where components[index] == "Library" {
            if let location = OrphanLocation.allCases.first(where: { $0.folderName == components[index + 1] }) {
                return location
            }
        }
        return nil
    }

    private static func installedAppName(in text: String) -> String? {
        guard let range = text.range(of: " is installed.") else { return nil }
        let words = text[..<range.lowerBound].split(separator: " ")
        guard words.count > 1 else { return nil }
        return words.dropLast().joined(separator: " ")
    }

    private struct Owner {
        let identity: String
        let checks: Substring
        let notes: String
    }

    private static func parseOwner(_ reason: String) -> Owner? {
        guard reason.hasPrefix(ownerPrefix) else { return nil }
        let rest = reason.dropFirst(ownerPrefix.count)
        guard let close = rest.range(of: ownerSuffix) else { return nil }
        let identity = String(rest[..<close.lowerBound])
        let tail = rest[close.upperBound...]
        guard let end = tail.range(of: ". ") else { return Owner(identity: identity, checks: tail, notes: "") }
        return Owner(identity: identity, checks: tail[..<end.lowerBound], notes: String(tail[end.upperBound...]))
    }

    private static func sentences(_ text: String) -> [String] {
        text.components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix(".") ? $0 : $0 + "." }
    }
}

extension OrphanLocation {
    var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .caches: "Caches"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedApplicationState: "Saved State"
        case .httpStorages: "HTTP Storages"
        case .webKit: "WebKit"
        case .logs: "Logs"
        case .preferences: "Preferences"
        case .launchAgents: "LaunchAgents"
        }
    }
}

extension OrphanCheck {
    var passedTitle: String {
        switch self {
        case .installedBundleID: "No installed app has this bundle ID"
        case .installedAppName: "No installed app name matches"
        case .systemFolder: "Not an Apple or system folder"
        case .claimedByRule: "Not claimed by another rule"
        case .launchServices: "macOS Launch Services knows no app for it"
        }
    }
}

extension Confidence {
    var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }

    var sectionTitle: String {
        "\(title) confidence"
    }
}

enum OrphanSections {
    static func rows(_ candidates: [Candidate]) -> [CandidateRow] {
        Confidence.allCases.compactMap { level in
            let children = candidates
                .filter { ($0.confidence ?? .low) == level }
                .compactMap { CandidateRow(candidate: $0, group: level.sectionTitle) }
            return children.isEmpty ? nil : CandidateRow(group: level.sectionTitle, children: children)
        }
    }
}
