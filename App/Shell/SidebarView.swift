import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
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
            .badge(badge(for: item))
        }
    }

    private func badge(for item: SidebarItem) -> Text? {
        guard let bytes = model.badgeBytes(for: item) else { return nil }
        return Text(ByteFormat.string(bytes)).monospacedDigit()
    }
}
