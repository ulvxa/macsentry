import MacSentryCore

struct CandidateListConfiguration {
    let item: SidebarItem
    let categories: Set<MacSentryCore.Category>
    var action: CandidateAction = .quarantine
    var groupsByRule = false
    var defaultCheckedTiers: Set<Tier> = [.green]
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
            CandidateListConfiguration(item: item, categories: [.oldLarge], noScanSubject: "old and large files")
        case .orphans:
            CandidateListConfiguration(
                item: item,
                categories: [.orphan],
                defaultCheckedTiers: [],
                noScanSubject: "leftover app files",
            )
        case .flagged:
            CandidateListConfiguration(
                item: item,
                categories: [.flagged, .orphan],
                action: .flagOnly,
                groupsByRule: true,
                defaultCheckedTiers: [],
                controls: [.size(label: "Size at least"), .tiers],
                isCheckable: false,
                emptyTitle: "Nothing flagged",
                emptyMessage: "Items that need a command line tool to clean appear here.",
                noScanSubject: "items that need a command line tool",
            )
        case .projects:
            CandidateListConfiguration(item: item, categories: [.projectArtifact], noScanSubject: "idle projects")
        case .duplicates:
            CandidateListConfiguration(
                item: item,
                categories: [.duplicate],
                defaultCheckedTiers: [],
                controls: [.size(label: "Reclaimable at least")],
                noScanSubject: "duplicate files",
            )
        case .overview, .quarantine:
            CandidateListConfiguration(item: item, categories: [], noScanSubject: item.title.lowercased())
        }
    }
}
