import AppKit
import SwiftUI

/// Real app icons by bundle ID. Lookup and icon decoding happen off the main actor; results (including misses) are cached.
final class AppIconCache: @unchecked Sendable {
    final class Entry {
        let image: NSImage?
        init(_ image: NSImage?) {
            self.image = image
        }
    }

    static let shared = AppIconCache()

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 512
        return cache
    }()

    func entry(_ bundleID: String) -> Entry? {
        cache.object(forKey: bundleID as NSString)
    }

    @discardableResult
    func load(_ bundleID: String) async -> Entry {
        if let hit = entry(bundleID) {
            return hit
        }
        let image = await Task.detached(priority: .utility) { () -> ImageBox in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return ImageBox(image: nil) }
            return ImageBox(image: NSWorkspace.shared.icon(forFile: appURL.path(percentEncoded: false)))
        }.value.image
        let entry = Entry(image)
        cache.setObject(entry, forKey: bundleID as NSString)
        return entry
    }

    private struct ImageBox: @unchecked Sendable {
        let image: NSImage?
    }
}

/// The owning app's icon, or the file's own icon when the app is unknown or not installed.
struct AppIconView: View {
    let bundleID: String?
    let fallback: URL
    var size: CGFloat = 16
    @State private var loadedID: String?

    var body: some View {
        Group {
            if let bundleID {
                if let entry = AppIconCache.shared.entry(bundleID) {
                    Image(nsImage: entry.image ?? FinderActions.icon(for: fallback))
                        .resizable()
                } else {
                    Color.clear
                }
            } else {
                Image(nsImage: FinderActions.icon(for: fallback))
                    .resizable()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: bundleID) {
            guard let bundleID, AppIconCache.shared.entry(bundleID) == nil else { return }
            await AppIconCache.shared.load(bundleID)
            loadedID = bundleID
        }
    }
}
