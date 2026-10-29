import SwiftUI

struct DetailView: View {
    let item: SidebarItem

    var body: some View {
        Group {
            switch item {
            case .overview: OverviewView()
            case .devCaches, .appCaches, .oldLarge: CategoryListView(item: item)
            case .orphans: OrphansView()
            case .projects: ProjectsView()
            case .duplicates: DuplicatesView()
            case .flagged: FlaggedView()
            case .quarantine: QuarantineView()
            }
        }
        .id(item)
        .navigationTitle(item.title)
    }
}
