import AppKit
import Foundation

@MainActor
enum FinderActions {
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
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
