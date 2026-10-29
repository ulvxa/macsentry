import Foundation

/// Names of command line tools and SDKs installed outside /Applications. Built from directory listings only.
public struct CLIToolInventory: Sendable, Equatable {
    public struct Roots: Sendable, Equatable {
        /// Folders of executables (`/opt/homebrew/bin`, `~/.cargo/bin`): every child name is a tool.
        public var binDirs: [URL]
        /// Folders of packages (Cellar, Caskroom, `node_modules`, Toolbox apps): child names count, `@scope` folders are descended.
        public var packageDirs: [URL]
        /// SDK folders keyed by the token they own (`android` for `~/Library/Android/sdk`): the token and child names count.
        public var sdkDirs: [String: URL]

        public init(binDirs: [URL] = [], packageDirs: [URL] = [], sdkDirs: [String: URL] = [:]) {
            self.binDirs = binDirs
            self.packageDirs = packageDirs
            self.sdkDirs = sdkDirs
        }

        public static func standard(homeURL: URL) -> Roots {
            func dir(_ path: String) -> URL {
                URL(filePath: path, directoryHint: .isDirectory)
            }
            func home(_ path: String) -> URL {
                homeURL.appending(path: path, directoryHint: .isDirectory)
            }
            return Roots(
                binDirs: [
                    dir("/opt/homebrew/bin"), dir("/opt/homebrew/sbin"), dir("/usr/local/bin"), dir("/usr/local/sbin"),
                    home(".npm-global/bin"), home(".bun/bin"), home(".cargo/bin"), home("go/bin"), home(".local/bin"),
                    home(".deno/bin"), home(".pub-cache/bin"), home(".dotnet/tools"), home(".pyenv/shims"),
                ],
                packageDirs: [
                    dir("/opt/homebrew/Cellar"), dir("/opt/homebrew/Caskroom"), dir("/usr/local/Cellar"), dir("/usr/local/Caskroom"),
                    dir("/opt/homebrew/lib/node_modules"), dir("/usr/local/lib/node_modules"), home(".npm-global/lib/node_modules"),
                    home(".bun/install/global/node_modules"), home("Library/Application Support/JetBrains/Toolbox/apps"),
                    home("Library/Application Support/Setapp"),
                ],
                sdkDirs: ["android": home("Library/Android/sdk"), "flutter": home("flutter"), "qt": home("Qt")],
            )
        }
    }

    public static let empty = CLIToolInventory(names: [])
    static let minimumLength = 3

    let names: Set<String>

    public static func scan(_ roots: Roots) -> CLIToolInventory {
        var names = Set<String>()
        func add(_ raw: String) {
            let base = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? raw
            let normalized = OrphanMatcher.normalize(base)
            if normalized.count >= 2 {
                names.insert(normalized)
            }
        }
        for dir in roots.binDirs {
            children(dir).forEach(add)
        }
        for dir in roots.packageDirs {
            for name in children(dir) {
                if name.hasPrefix("@") {
                    children(dir.appending(path: name, directoryHint: .isDirectory)).forEach(add)
                } else {
                    add(name)
                }
            }
        }
        for (token, dir) in roots.sdkDirs {
            let listing = children(dir)
            guard !listing.isEmpty else { continue }
            add(token)
            listing.forEach(add)
        }
        return CLIToolInventory(names: names)
    }

    func contains(_ token: String) -> Bool {
        names.contains(token)
    }

    private static func children(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }
    }
}

/// SDK and installer frameworks write preferences under their own vendor name from inside other apps and tools, so the
/// vendor alone never proves the owner is gone.
enum SDKVendors {
    static let tokens: Set<String> = [
        "firebase", "install4j", "qtproject", "sentry", "crashlytics", "fabric", "bugsnag", "appcenter", "mixpanel", "segment",
    ]
    static let aliases: [String: String] = ["qtproject": "qt", "firebase": "firebasetools", "sentry": "sentrycli"]
    private static let generic: Set<String> = [
        "cli", "app", "apps", "client", "helper", "mac", "macos", "desktop", "agent", "service", "tool", "tools", "core", "shared",
        "installations", "installer", "updater", "launcher", "main", "default",
    ]

    static func tokens(of identity: String) -> [String] {
        let lower = identity.lowercased()
        let parts: [Substring] = OrphanMatcher.isReverseDNS(lower)
            ? Array(lower.split(separator: ".").dropFirst())
            : [Substring(lower)]
        return parts.map { OrphanMatcher.normalize(String($0)) }.filter { !$0.isEmpty && !generic.contains($0) }
    }
}
