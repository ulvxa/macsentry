import SwiftUI

struct NavigationCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(SidebarItem.allCases) { item in
                if let shortcut = item.shortcut {
                    Button(item.title) { model.selection = item }
                        .keyboardShortcut(shortcut, modifiers: .command)
                }
            }
        }
    }
}
