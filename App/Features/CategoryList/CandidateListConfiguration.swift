import MacSentryCore

struct CandidateListConfiguration {
    let item: SidebarItem
    let categories: Set<MacSentryCore.Category>
    var actions: Set<CandidateAction> = [.quarantine]
    var groupsByRule = false
    var defaultCheckedTiers: Set<Tier> = [.green]
    var collapsedByDefault: Set<String> = []
    var groupCheckDisabled: Set<String> = []
    var controls: [FilterControl] = FilterControl.listControls
    var isCheckable = true
    var emptyTitle = "Nothing here above your thresholds"
    var emptyMessage = "Lower the filters or the thresholds in Settings to see more."
    var noScanSubject: String

    static func forItem(_ item: SidebarItem) -> CandidateListConfiguration {
        switch item {
        case .devCaches:
            CandidateListConfiguration(item: item, categories: [.devCache], groupsByRule: true, noScanSubject: "developer caches")
        case .appCaches:
            CandidateListConfiguration(item: item, categories: [.appCache], groupsByRule: true, noScanSubject: "app caches")
        case .oldLarge:
            CandidateListConfiguration(
                item: item,
                categories: [.oldLarge],
                noScanSubject: "old and large files",
            )
        case .orphans:
            .orphans
        case .flagged:
            .flagged
        case .overview, .projects, .duplicates, .quarantine:
            CandidateListConfiguration(item: item, categories: [], noScanSubject: item.title.lowercased())
        }
    }
}

extension CandidateListConfiguration {
    private static var orphans: CandidateListConfiguration {
        CandidateListConfiguration(
            item: .orphans,
            categories: [.orphan],
            actions: [.quarantine, .flagOnly],
            defaultCheckedTiers: [],
            collapsedByDefault: [Confidence.low.sectionTitle],
            groupCheckDisabled: [Confidence.low.sectionTitle],
            emptyTitle: "No leftovers found",
            emptyMessage: "Nothing in your Library looks orphaned.",
            noScanSubject: "leftover app files",
        )
    }

    private static var flagged: CandidateListConfiguration {
        CandidateListConfiguration(
            item: .flagged,
            categories: [],
            actions: [.flagOnly],
            groupsByRule: true,
            defaultCheckedTiers: [],
            controls: [.size(label: "Size at least"), .tiers],
            isCheckable: false,
            emptyTitle: "Nothing flagged",
            emptyMessage: "Items that need a command line tool to clean appear here.",
            noScanSubject: "items that need a command line tool",
        )
    }

    var usesThresholdFilters: Bool {
        item == .oldLarge
    }

    func defaultFilter(thresholds: Thresholds) -> FilterState {
        usesThresholdFilters ? FilterState(thresholds: thresholds) : .unfiltered
    }
}
