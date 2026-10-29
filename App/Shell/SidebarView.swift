import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                if let title = section.title {
                    Section(title) {
                        rows(for: section)
                    }
                } else {
                    rows(for: section)
                }
            }
        }
    }

    private func rows(for section: SidebarSection) -> some View {
        ForEach(section.items) { item in
            NavigationLink(value: item) {
                Label(item.title, systemImage: item.systemImage)
            }
        }
    }
}
