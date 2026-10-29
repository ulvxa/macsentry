import Foundation

/// Pure URL logic behind every "Reveal in Finder" / "Open" action.
enum FinderTarget {
    struct Plan: Equatable {
        /// Existing items to select in Finder (packages are selected as a whole).
        var select: [URL] = []
        /// Nearest existing folders for items that no longer exist.
        var openFolders: [URL] = []
    }

    static let maxOpenedWindows = 3

    static let defaultExists: @Sendable (URL) -> Bool = { url in
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// Resolves symlinks in the parent chain only, so a symlink item itself is revealed rather than its target.
    static func normalized(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        let name = standard.lastPathComponent
        guard standard.path != "/", !name.isEmpty else { return standard.resolvingSymlinksInPath() }
        return standard.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: name, directoryHint: .inferFromPath)
    }

    static func nearestExisting(_ url: URL, exists: (URL) -> Bool = defaultExists) -> URL {
        var current = normalized(url)
        while !exists(current) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return current
    }

    static func plan(for urls: [URL], exists: (URL) -> Bool = defaultExists) -> Plan {
        var plan = Plan()
        var seen = Set<String>()
        for url in urls {
            let resolved = normalized(url)
            if exists(resolved) {
                if seen.insert(resolved.path).inserted {
                    plan.select.append(resolved)
                }
            } else {
                let ancestor = nearestExisting(resolved, exists: exists)
                if seen.insert(ancestor.path).inserted {
                    plan.openFolders.append(ancestor)
                }
            }
        }
        return plan
    }

    /// Root first, the URL itself last.
    static func chain(of url: URL) -> [URL] {
        var chain = [normalized(url)]
        while let last = chain.last, last.path != "/" {
            let parent = last.deletingLastPathComponent()
            if parent.path == last.path {
                break
            }
            chain.append(parent)
        }
        return chain.reversed()
    }

    static func displayName(of url: URL) -> String {
        url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }
}
