import SwiftUI
import Testing
@testable import MacSentry

struct SidebarItemTests {
    @Test func `sections match UI shell spec`() {
        #expect(SidebarSection.overview.items.map(\.title) == ["Overview"])
        #expect(SidebarSection.clean.items.map(\.title)
            == ["Dev Caches", "App Caches", "Old and Large", "Projects", "Orphans", "Duplicates"])
        #expect(SidebarSection.review.items.map(\.title) == ["Flagged", "Quarantine"])
    }

    @Test func `every item has A unique command digit`() {
        let shortcuts = SidebarItem.allCases.compactMap { $0.shortcut?.character }
        #expect(shortcuts == Array("123456789"))
    }
}
