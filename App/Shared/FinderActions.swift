import AppKit
import Foundation

@MainActor
enum FinderActions {
    static func reveal(_ urls: [URL]) {
        let plan = FinderTarget.plan(for: urls)
        if plan.openFolders.count > FinderTarget.maxOpenedWindows {
            NSWorkspace.shared.activateFileViewerSelecting(plan.select + plan.openFolders)
            return
        }
        if !plan.select.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(plan.select)
        }
        for folder in plan.openFolders {
            NSWorkspace.shared.open(folder)
        }
    }

    /// Opens the folder itself (or its nearest existing ancestor) in Finder.
    static func openFolder(_ url: URL) {
        NSWorkspace.shared.open(FinderTarget.nearestExisting(url))
    }

    static func copyPaths(_ urls: [URL]) {
        copy(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}
