import MacSentryCore
import SwiftUI

enum SidebarSection: CaseIterable, Identifiable {
    case overview, clean, review

    var id: Self {
        self
    }

    var title: String? {
        switch self {
        case .overview: nil
        case .clean: "Clean"
        case .review: "Review"
        }
    }

    var items: [SidebarItem] {
        SidebarItem.allCases.filter { $0.section == self }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, devCaches, appCaches, oldLarge, projects, orphans, duplicates, flagged, quarantine

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .devCaches: "Dev Caches"
        case .appCaches: "App Caches"
        case .oldLarge: "Old and Large"
        case .projects: "Projects"
        case .orphans: "Orphans"
        case .duplicates: "Duplicates"
        case .flagged: "Flagged"
        case .quarantine: "Quarantine"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .devCaches: "hammer"
        case .appCaches: "square.stack.3d.up"
        case .oldLarge: "clock.arrow.circlepath"
        case .projects: "folder.badge.gearshape"
        case .orphans: "questionmark.folder"
        case .duplicates: "doc.on.doc"
        case .flagged: "flag"
        case .quarantine: "archivebox"
        }
    }

    var section: SidebarSection {
        switch self {
        case .overview: .overview
        case .devCaches, .appCaches, .oldLarge, .projects, .orphans, .duplicates: .clean
        case .flagged, .quarantine: .review
        }
    }

    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }
}

extension SidebarItem {
    var categories: Set<MacSentryCore.Category> {
        switch self {
        case .overview, .quarantine: []
        case .devCaches: [.devCache]
        case .appCaches: [.appCache]
        case .oldLarge: [.oldLarge]
        case .projects: [.projectArtifact]
        case .orphans: [.orphan]
        case .duplicates: [.duplicate]
        case .flagged: [.flagged]
        }
    }

    var showsToolbarScan: Bool {
        self != .overview
    }

    static func destination(for candidate: Candidate) -> SidebarItem {
        if candidate.action == .flagOnly {
            return .flagged
        }
        return switch candidate.category {
        case .devCache: .devCaches
        case .appCache: .appCaches
        case .oldLarge: .oldLarge
        case .projectArtifact: .projects
        case .orphan: .orphans
        case .duplicate: .duplicates
        case .flagged: .flagged
        }
    }
}
