import AppKit
import Foundation

@MainActor
enum ProjectActions {
    static let terminalBundleID = "com.apple.Terminal"

    static func openInFinder(_ url: URL) {
        FinderActions.openFolder(url)
    }

    static func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) else { return }
        NSWorkspace.shared.open(
            [FinderTarget.nearestExisting(url)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration(),
        )
    }
}
