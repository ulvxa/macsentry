import SwiftUI

struct NavigationCommands: Commands {
    let model: AppModel
    @FocusedValue(\.screenActions) private var screenActions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Scan") { model.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.canStartScan)
            Button("Cancel Scan") { model.cancelScan() }
                .disabled(!model.isScanning)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Quarantine Selection…") { screenActions?.quarantine() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(screenActions?.canQuarantine != true)
            Button("Quick Look") { screenActions?.quickLook?() }
                .disabled(screenActions?.quickLook == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.isInspectorPresented ? "Hide Inspector" : "Show Inspector") { model.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
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
