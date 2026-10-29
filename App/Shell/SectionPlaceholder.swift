import SwiftUI

struct SectionPlaceholder: View {
    let item: SidebarItem
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(item.title, systemImage: item.systemImage)
        } description: {
            Text(message)
        }
    }
}
