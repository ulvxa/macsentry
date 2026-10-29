import Darwin
import Foundation

public typealias ArtifactPredicate = @Sendable (URL) -> Bool

public struct DefaultProtectionPolicy: ProtectionPolicy {
    public static let defaultArtifactNames: Set<String> = [
        "node_modules", ".next", ".nuxt", ".turbo", ".parcel-cache", ".svelte-kit", ".angular", ".venv", "venv", "env",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", "target", "build", ".gradle", "Library",
        "Temp", "Obj", "Logs", "DerivedData", ".build", "Pods", ".dart_tool", "dist", "out",
    ]

    public static let isDefaultArtifact: ArtifactPredicate = { url in
        defaultArtifactNames.contains(url.lastPathComponent)
    }

    public static let quarantineFolderName = "MacSentry Quarantine"

    public static let builtInSummary: [String] = [
        "/ (startup disk root), your home folder and every top level folder in it",
        "/System, /bin, /sbin, /usr (except inside /usr/local), /private/var, /private/etc",
        "/Library/Apple, /Library/Keychains",
        "/Applications/*.app, ~/Applications/*.app, /Users/*, /Volumes/*",
        "~/Library/Keychains, ~/Library/Mail, ~/Library/Messages, ~/Library/Accounts",
        "~/Library/Mobile Documents, ~/Library/CloudStorage, ~/Library/Cookies, ~/Library/LaunchAgents",
        "~/Library/Preferences/*.plist of installed apps",
        "~/.ssh, ~/.gnupg, ~/.aws, ~/.config/gcloud, ~/.kube, ~/.docker/config.json, dotfiles in ~",
        "~/Library/Application Support/Ledger Live and anything named *wallet* under Application Support",
        "Every .git folder and source files inside git working trees (build artifacts excepted)",
        "*.photoslibrary, ~/Pictures/Photos Library.photoslibrary, ~/Music/Music",
        "~/\(quarantineFolderName) and the MacSentry database folder",
        "Your Never Touch patterns and ignored items",
    ]

    private static let systemRoots: [(path: NormalizedPath, reason: String)] = [
        ("/System", "macOS system folder"),
        ("/bin", "macOS system folder"),
        ("/sbin", "macOS system folder"),
        ("/usr", "macOS system folder"),
        ("/private/var", "macOS system folder"),
        ("/private/etc", "macOS system folder"),
        ("/Library/Apple", "macOS system folder"),
        ("/Library/Keychains", "System keychains"),
    ].map { (NormalizedPath(absolutePath: $0.0), $0.1) }

    private static let homeRoots: [(path: String, reason: String)] = [
        ("Library/Keychains", "Keychains"),
        ("Library/Mail", "Mail data"),
        ("Library/Messages", "Messages data"),
        ("Library/Mobile Documents", "iCloud Drive"),
        ("Library/CloudStorage", "Cloud storage"),
        ("Library/Accounts", "Accounts"),
        ("Library/Cookies", "Cookies"),
        ("Library/LaunchAgents", "Launch agents"),
        (".ssh", "SSH keys"),
        (".gnupg", "GPG keys"),
        (".aws", "AWS credentials"),
        (".config/gcloud", "Google Cloud credentials"),
        (".kube", "Kubernetes credentials"),
        (".docker/config.json", "Docker credentials"),
        ("Library/Application Support/Ledger Live", "Crypto wallet"),
        ("Music/Music", "Music library"),
        ("Pictures/Photos Library.photoslibrary", "Photos library"),
        (quarantineFolderName, "MacSentry quarantine folder"),
        ("Library/Application Support/MacSentry", "MacSentry data"),
    ]

    private static let usrLocal = NormalizedPath(absolutePath: "/usr/local")
    private static let shallowRoots = [
        ("/Applications", "Applications folder", "Installed application"),
        ("/Users", "Users folder", "A user's home folder"),
        ("/Volumes", "Volumes folder", "A mounted volume"),
    ].map { (path: NormalizedPath(absolutePath: $0.0), itself: $0.1, child: $0.2) }
    private static let temporaryRoots = ["/private/var/folders", "/private/tmp"].map(NormalizedPath.init(absolutePath:))
    private static let libraryExtensions: Set = ["photoslibrary", "photolibrary", "musiclibrary"]

    private struct Root {
        let path: NormalizedPath
        let reason: String
    }

    private let home: NormalizedPath
    private let homeIsTemporary: Bool
    private let roots: [Root]
    private let databaseFiles: Set<NormalizedPath>
    private let databaseFolder: NormalizedPath
    private let userApplications: NormalizedPath
    private let patterns: [GlobPattern]
    private let isKnownArtifact: ArtifactPredicate

    public init(
        homeURL: URL,
        databaseURL: URL,
        installedBundleIDs: Set<String> = [],
        neverTouchPatterns: [String] = [],
        ignoredPaths: [URL] = [],
        isKnownArtifact: @escaping ArtifactPredicate = DefaultProtectionPolicy.isDefaultArtifact,
    ) {
        let home = PathResolver.resolveDirectory(homeURL)
        self.home = home
        homeIsTemporary = Self.temporaryRoots.contains { home.count > $0.count && home.isInside($0) }
        userApplications = home.appending(["Applications"])
        self.isKnownArtifact = isKnownArtifact
        patterns = neverTouchPatterns.compactMap { try? GlobPattern($0, homeURL: homeURL) }

        let database = PathResolver.physical(databaseURL)
        let folder = NormalizedPath(components: Array(database.components.dropLast()))
        databaseFolder = folder
        databaseFiles = Set(["", "-wal", "-shm", "-journal"].map { suffix in
            NormalizedPath(components: Array(folder.components) + [(database.components.last ?? "") + suffix])
        })

        var roots = Self.homeRoots.map { Root(path: home.appending(NormalizedPath.split($0.path)), reason: $0.reason) }
        roots += installedBundleIDs.map {
            Root(path: home.appending(["Library", "Preferences", "\($0).plist"]), reason: "Preferences of an installed app")
        }
        roots += ignoredPaths.map { Root(path: PathResolver.physical($0), reason: "Ignored by you") }
        if !home.isInside(folder) {
            roots.append(Root(path: folder, reason: "MacSentry database folder"))
        }
        self.roots = roots
    }

    public func check(_ url: URL) -> ProtectionVerdict {
        let physical = PathResolver.physical(url)
        let lexical = PathResolver.lexical(url)
        for path in physical == lexical ? [physical] : [physical, lexical] {
            if let reason = denial(for: path) {
                return .denied(reason)
            }
        }
        return .allowed
    }

    private func denial(for path: NormalizedPath) -> String? {
        if path.components.isEmpty {
            return "Startup disk root"
        }
        if path == home {
            return "Your home folder"
        }
        if path.isStrictAncestor(of: home) {
            return "Contains your home folder"
        }
        if let reason = systemDenial(for: path) ?? shallowDenial(for: path) ?? homeDenial(for: path) {
            return reason
        }
        if let pattern = patterns.first(where: { $0.protects(path) }) {
            return "Matches Never Touch pattern \(pattern.raw)"
        }
        return gitDenial(for: path)
    }

    private func systemDenial(for path: NormalizedPath) -> String? {
        if homeIsTemporary, path.isInside(home) {
            return nil
        }
        for root in Self.systemRoots {
            if path.isInside(root.path) {
                if root.path == Self.usrLocal.parent, path.count > Self.usrLocal.count, path.isInside(Self.usrLocal) {
                    continue
                }
                return root.reason
            }
            if path.isStrictAncestor(of: root.path) {
                return "Contains a macOS system folder"
            }
        }
        return nil
    }

    private func shallowDenial(for path: NormalizedPath) -> String? {
        for root in Self.shallowRoots where path.isInside(root.path) && path.count <= root.path.count + 1 {
            return path.count == root.path.count ? root.itself : root.child
        }
        for folder in [Self.shallowRoots[0].path, userApplications] where path.isInside(folder) {
            if path.folded.dropFirst(folder.count).contains(where: { $0.hasSuffix(".app") }) {
                return "Installed application"
            }
        }
        return nil
    }

    private func homeDenial(for path: NormalizedPath) -> String? {
        if databaseFiles.contains(path) {
            return "MacSentry database"
        }
        if path.isStrictAncestor(of: databaseFolder) || path == databaseFolder {
            return "Contains the MacSentry database"
        }
        if let root = roots.first(where: { path.isInsideOrAncestor(of: $0.path) }) {
            return path.isInside(root.path) ? root.reason : "Contains protected item: \(root.reason)"
        }
        if path.count == home.count + 1, path.isInside(home), let name = path.components.last,
           name.hasPrefix(".") || !Self.isRegularFileOrLink(path) {
            return name.hasPrefix(".") ? "Dotfile in your home folder" : "Top level folder in your home"
        }
        if let index = path.folded.firstIndex(of: "application support"),
           path.folded.dropFirst(index + 1).contains(where: { $0.contains("wallet") }) {
            return "Crypto wallet"
        }
        if path.folded.contains(where: { Self.libraryExtensions.contains(($0 as NSString).pathExtension) }) {
            return "Photos or Music library"
        }
        return nil
    }

    private func gitDenial(for path: NormalizedPath) -> String? {
        if path.folded.contains(".git") {
            return "Git repository data"
        }
        var depth = path.count
        while depth > home.count || (!path.isInside(home) && depth > 0) {
            let candidate = NormalizedPath(components: Array(path.components.prefix(depth)))
            if Self.exists(candidate.appending([".git"])) {
                guard candidate != path else { return "Git working tree" }
                let isArtifact = (depth + 1 ... path.count).contains { length in
                    isKnownArtifact(URL(filePath: NormalizedPath(components: Array(path.components.prefix(length))).path))
                }
                return isArtifact ? nil : "Inside a git working tree"
            }
            depth -= 1
        }
        return nil
    }

    private static func exists(_ path: NormalizedPath) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0
    }

    private static func isRegularFileOrLink(_ path: NormalizedPath) -> Bool {
        var info = stat()
        guard lstat(path.path, &info) == 0 else { return false }
        let type = info.st_mode & S_IFMT
        return type == S_IFREG || type == S_IFLNK
    }
}

private extension NormalizedPath {
    var parent: NormalizedPath {
        NormalizedPath(components: Array(components.dropLast()))
    }
}
