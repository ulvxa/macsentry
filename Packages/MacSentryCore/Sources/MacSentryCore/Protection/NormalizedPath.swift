import Darwin
import Foundation

struct NormalizedPath: Hashable {
    let components: [String]
    let folded: [String]

    static let root = NormalizedPath(components: [])

    init(components: [String]) {
        self.components = components
        folded = components.map(Self.fold)
    }

    init(absolutePath: String) {
        self.init(components: Self.lexicallyNormalized(Self.split(absolutePath)))
    }

    var path: String {
        "/" + components.joined(separator: "/")
    }

    var count: Int {
        components.count
    }

    var lastFolded: String? {
        folded.last
    }

    func appending(_ more: [String]) -> NormalizedPath {
        NormalizedPath(components: Self.lexicallyNormalized(components + more))
    }

    func isInside(_ other: NormalizedPath) -> Bool {
        count >= other.count && Array(folded.prefix(other.count)) == other.folded
    }

    func isStrictAncestor(of other: NormalizedPath) -> Bool {
        count < other.count && other.isInside(self)
    }

    func isInsideOrAncestor(of other: NormalizedPath) -> Bool {
        isInside(other) || isStrictAncestor(of: other)
    }

    func relative(to base: NormalizedPath) -> ArraySlice<String>? {
        guard isInside(base) else { return nil }
        return folded.dropFirst(base.count)
    }

    static func fold(_ component: String) -> String {
        component.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func lexicallyNormalized(_ components: [String]) -> [String] {
        var result: [String] = []
        for component in components {
            switch component {
            case ".": continue
            case "..": _ = result.popLast()
            default: result.append(component)
            }
        }
        return result
    }
}

enum PathResolver {
    static func lexical(_ url: URL) -> NormalizedPath {
        NormalizedPath(absolutePath: url.absoluteURL.standardizedFileURL.path(percentEncoded: false))
    }

    static func physical(_ url: URL) -> NormalizedPath {
        // The leaf is never resolved: renaming a symlink moves the link, not its target.
        var components = NormalizedPath.split(url.absoluteURL.path(percentEncoded: false))
        while components.last == "." {
            components.removeLast()
        }
        guard let leaf = components.last else { return .root }
        if leaf == ".." {
            return resolveExisting(components)
        }
        return resolveExisting(Array(components.dropLast())).appending([leaf])
    }

    static func resolveExisting(_ components: [String]) -> NormalizedPath {
        var count = components.count
        while count > 0 {
            if let real = realPath("/" + components.prefix(count).joined(separator: "/")) {
                return NormalizedPath(absolutePath: real).appending(Array(components.dropFirst(count)))
            }
            count -= 1
        }
        return NormalizedPath(components: NormalizedPath.lexicallyNormalized(components))
    }

    static func resolveDirectory(_ url: URL) -> NormalizedPath {
        resolveExisting(NormalizedPath.split(url.absoluteURL.path(percentEncoded: false)))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
