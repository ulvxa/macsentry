import Darwin
import Foundation

public struct SizeIndex: Sendable {
    static let excludedComponents: Set<String> = [".git", "node_modules"]
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "photoslibrary", "photolibrary",
        "musiclibrary", "tvlibrary", "aplibrary", "lrlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "xcarchive", "xcodeproj", "xcworkspace", "playground", "vmwarevm", "pvm", "utm", "sparsebundle",
    ]

    private let rootPaths: [String]
    private let minSize: Int64
    private let isExcluded: @Sendable (URL) -> Bool
    private var buckets: [Int64: [FileEntry]] = [:]
    private var excludedDirectories: Set<String> = []
    public private(set) var fileCount = 0
    public private(set) var datalessCount = 0

    public init(
        roots: [URL],
        minSize: Int64 = DuplicateOptions.defaultMinSize,
        isExcluded: @escaping @Sendable (URL) -> Bool = { _ in false },
    ) {
        rootPaths = roots.map(Self.directoryPrefix)
        self.minSize = minSize
        self.isExcluded = isExcluded
    }

    public init(options: DuplicateOptions, protectionPolicy: any ProtectionPolicy) {
        self.init(roots: options.roots, minSize: options.minSize) { protectionPolicy.check($0) != .allowed }
    }

    @discardableResult
    public mutating func add(_ entry: FileEntry) -> Bool {
        let path = entry.url.path(percentEncoded: false)
        guard let root = rootPaths.first(where: { path.hasPrefix($0) }) else { return false }
        let name = entry.url.lastPathComponent
        switch entry.kind {
        case .symlink:
            return false
        case .package:
            excludedDirectories.insert(Self.trimmed(path))
            return false
        case .folder:
            if name == ".git" {
                excludedDirectories.insert(Self.trimmed(entry.url.deletingLastPathComponent().path(percentEncoded: false)))
            }
            return false
        case .file:
            break
        }
        if name == ".git" {
            excludedDirectories.insert(Self.trimmed(entry.url.deletingLastPathComponent().path(percentEncoded: false)))
            return false
        }
        guard entry.logicalSize >= minSize else { return false }
        guard entry.flags & UInt32(SF_DATALESS) == 0 else {
            datalessCount += 1
            return false
        }
        guard !Self.hasExcludedComponent(path.dropFirst(root.count)) else { return false }
        buckets[entry.logicalSize, default: []].append(entry)
        fileCount += 1
        return true
    }

    public mutating func add(contentsOf entries: some Sequence<FileEntry>) {
        for entry in entries {
            add(entry)
        }
    }

    func duplicateCandidates(minSize requestedMinSize: Int64, roots: [URL]) -> [[FileEntry]] {
        let scope = roots.map(Self.directoryPrefix)
        var repositoryCache: [String: Bool] = [:]
        return buckets.keys.sorted(by: >).compactMap { size in
            guard size >= requestedMinSize, let entries = buckets[size], entries.count > 1 else { return nil }
            let eligible = entries.filter { entry in
                let path = entry.url.path(percentEncoded: false)
                guard scope.isEmpty || scope.contains(where: { path.hasPrefix($0) }) else { return false }
                return !isExcluded(entry.url) && !isInsideExcludedDirectory(path, cache: &repositoryCache)
            }
            let unique = Self.uniqueInodes(eligible)
            return unique.count > 1 ? unique : nil
        }
    }

    private func isInsideExcludedDirectory(_ path: String, cache: inout [String: Bool]) -> Bool {
        guard let root = rootPaths.first(where: { path.hasPrefix($0) }) else { return true }
        let rootDirectory = Self.trimmed(root)
        var directory = Self.trimmed(URL(filePath: path).deletingLastPathComponent().path(percentEncoded: false))
        while directory.count >= rootDirectory.count {
            if let known = cache[directory] {
                if known {
                    return true
                }
            } else {
                let excluded = excludedDirectories.contains(directory)
                    || FileManager.default.fileExists(atPath: directory + "/.git")
                cache[directory] = excluded
                if excluded {
                    return true
                }
            }
            guard let slash = directory.lastIndex(of: "/"), slash > directory.startIndex else { break }
            directory = String(directory[..<slash])
        }
        return false
    }

    private static func uniqueInodes(_ entries: [FileEntry]) -> [FileEntry] {
        struct Identity: Hashable {
            let device: Int32
            let inode: UInt64
        }
        var seen: Set<Identity> = []
        return entries
            .sorted { lhs, rhs in
                let left = lhs.url.path(percentEncoded: false)
                let right = rhs.url.path(percentEncoded: false)
                return left.count == right.count ? left < right : left.count < right.count
            }
            .filter { seen.insert(Identity(device: $0.device, inode: $0.inode)).inserted }
    }

    private static func hasExcludedComponent(_ relativePath: Substring) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { component in
            if excludedComponents.contains(String(component)) {
                return true
            }
            guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return false }
            return packageExtensions.contains(component[component.index(after: dot)...].lowercased())
        }
    }

    private static func directoryPrefix(_ url: URL) -> String {
        let path = url.storagePath
        return path.hasSuffix("/") ? path : path + "/"
    }

    private static func trimmed(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
