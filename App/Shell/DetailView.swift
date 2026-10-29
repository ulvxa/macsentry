import SwiftUI

struct DetailView: View {
    let item: SidebarItem

    var body: some View {
        Group {
            switch item {
            case .overview: OverviewView()
            case .devCaches, .appCaches, .oldLarge, .orphans: CategoryListView(item: item)
            case .projects: ProjectsView()
            case .duplicates: DuplicatesView()
            case .flagged: FlaggedView()
            case .quarantine: QuarantineView()
            }
        }
        .navigationTitle(item.title)
    }
}
