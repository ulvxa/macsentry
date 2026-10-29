import Foundation

struct PathPattern: Sendable, Hashable {
    enum Segment: Sendable, Hashable {
        case literal(String)
        case glob([String])

        func matches(_ name: String) -> Bool {
            switch self {
            case let .literal(literal):
                literal == name
            case let .glob(parts):
                Self.glob(parts, matches: name)
            }
        }

        private static func glob(_ parts: [String], matches name: String) -> Bool {
            guard let first = parts.first, let last = parts.last, parts.count > 1 else { return parts.first == name }
            guard name.count >= parts.map(\.count).reduce(0, +), name.hasPrefix(first), name.hasSuffix(last) else { return false }
            var remainder = name.dropFirst(first.count).dropLast(last.count)
            for part in parts.dropFirst().dropLast() where !part.isEmpty {
                guard let range = remainder.range(of: part) else { return false }
                remainder = remainder[range.upperBound...]
            }
            return true
        }
    }

    let segments: [Segment]
    let literalPrefixLength: Int
    let endsWithGlob: Bool
    let namesHiddenEntries: Bool

    var literalPath: String? {
        var components: [String] = []
        for segment in segments {
            guard case let .literal(name) = segment else { return nil }
            components.append(name)
        }
        return "/" + components.joined(separator: "/")
    }

    init(_ pattern: String, home: String) {
        let expanded = Self.expand(pattern, home: home).lowercased()
        literalPrefixLength = expanded.firstIndex(of: "*").map { expanded.distance(from: expanded.startIndex, to: $0) } ?? expanded.count
        let names = Self.components(of: expanded)
        segments = names.map { name in
            name.contains("*") ? .glob(name.components(separatedBy: "*")) : .literal(name)
        }
        endsWithGlob = expanded.hasSuffix("*")
        namesHiddenEntries = names.last?.hasPrefix(".") == true
    }

    func matches(_ components: [String]) -> Bool {
        components.count == segments.count && zip(segments, components).allSatisfy { $0.matches($1) }
    }

    func isProperAncestor(_ components: [String]) -> Bool {
        components.count < segments.count && zip(segments, components).allSatisfy { $0.matches($1) }
    }

    func contains(_ components: [String]) -> Bool {
        components.count >= segments.count && zip(segments, components).allSatisfy { $0.matches($1) }
    }

    static func expand(_ pattern: String, home: String) -> String {
        if pattern == "~" {
            return home
        }
        guard pattern.hasPrefix("~/") else { return pattern }
        return home + pattern.dropFirst()
    }

    static func components(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func entryComponents(_ url: URL) -> [String] {
        components(of: url.storagePath.lowercased())
    }

    static func homePath(_ homeURL: URL) -> String {
        homeURL.storagePath
    }

    static func problem(in pattern: String) -> String? {
        guard pattern.hasPrefix("~/") || pattern.hasPrefix("/") else { return "must start with ~/ or /" }
        guard !pattern.contains("**") else { return "** is not allowed, * matches one segment" }
        guard !pattern.hasSuffix("/") else { return "must not end with /" }
        let body = pattern.hasPrefix("~/") ? String(pattern.dropFirst(2)) : String(pattern.dropFirst())
        let parts = body.components(separatedBy: "/")
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == "~" }) else {
            return "empty, ., .. or ~ segments are not allowed"
        }
        return nil
    }
}

extension Tier {
    var severity: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        }
    }
}
