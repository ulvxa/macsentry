import SwiftUI

struct CategoryListView: View {
    let item: SidebarItem

    var body: some View {
        SectionPlaceholder(item: item, message: "No scan yet. Items for \(item.title) appear here after a scan.")
    }
}
