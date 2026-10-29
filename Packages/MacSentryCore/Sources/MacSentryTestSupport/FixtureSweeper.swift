import Foundation

/// The only sanctioned delete in the repo: test fixtures under $TMPDIR/MacSentryFixtures, never anything else.
enum FixtureSweeper {
    static let maxAge: TimeInterval = 30 * 60

    static let sweepOnce: Void = sweep(olderThan: maxAge)

    static var base: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MacSentryFixtures", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
    }

    static func sweep(olderThan age: TimeInterval, now: Date = Date()) {
        let base = base
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else { return }
        for child in children where isSweepable(child, base: base, olderThan: age, now: now) {
            unlockTree(child)
            // swiftlint:disable:next no_remove_item
            try? manager.removeItem(at: child)
        }
    }

    static func isSweepable(_ child: URL, base: URL, olderThan age: TimeInterval, now: Date) -> Bool {
        guard child.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path,
              child.lastPathComponent.range(
                  of: #"^[A-Za-z0-9_]+-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$"#,
                  options: .regularExpression,
              ) != nil,
              let values = try? child.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory == true,
              let created = values.creationDate
        else { return false }
        return now.timeIntervalSince(created) > age
    }

    private static func unlockTree(_ root: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        chflags(root.path(percentEncoded: false), 0)
        chmod(root.path(percentEncoded: false), 0o755)
        for case let url as URL in enumerator {
            let path = url.path(percentEncoded: false)
            lchflags(path, 0)
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                chmod(path, 0o755)
            }
        }
    }
}
