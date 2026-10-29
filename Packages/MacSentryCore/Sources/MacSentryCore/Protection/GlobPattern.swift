import Foundation

public struct GlobPattern: Sendable, Hashable {
    enum Anchor: Hashable {
        case root, home, anywhere
    }

    enum Token: Hashable {
        case star, single
        case character(Character)
    }

    enum Segment: Hashable {
        case anyDepth
        case literal(String)
        case wildcard([Token])

        var isWildcardOnly: Bool {
            switch self {
            case .anyDepth: true
            case .literal: false
            case let .wildcard(tokens): tokens.allSatisfy { $0 == .star }
            }
        }
    }

    struct Parsed: Hashable {
        let anchor: Anchor
        let segments: [Segment]
    }

    public let raw: String
    let segments: [Segment]

    public init(_ raw: String, homeURL: URL) throws(GlobPatternError) {
        let parsed = try Self.parse(raw)
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        segments = Self.resolve(parsed, homeURL: homeURL)
    }

    @discardableResult
    public static func validate(_ raw: String) throws(GlobPatternError) -> GlobWarning? {
        let parsed = try parse(raw)
        return parsed.segments.allSatisfy(\.isWildcardOnly) ? .protectsEverything : nil
    }

    public func matches(_ url: URL) -> Bool {
        matches(PathResolver.lexical(url)) || matches(PathResolver.physical(url))
    }

    func matches(_ path: NormalizedPath) -> Bool {
        matchTable(path).last?.last ?? false
    }

    /// Protects matches, everything inside them, and folders on the way to a match (up to the first **).
    func protects(_ path: NormalizedPath) -> Bool {
        if let lastRow = matchTable(path).last, lastRow.contains(true) {
            return true
        }
        guard segments.count > path.count else { return false }
        for (segment, component) in zip(segments, path.folded) {
            guard segment != .anyDepth, Self.matches(segment, component) else { return false }
        }
        return true
    }

    private func matchTable(_ path: NormalizedPath) -> [[Bool]] {
        let names = path.folded
        var table = Array(repeating: Array(repeating: false, count: names.count + 1), count: segments.count + 1)
        table[0][0] = true
        for (index, segment) in segments.enumerated() {
            let row = index + 1
            for column in 0 ... names.count {
                if segment == .anyDepth {
                    table[row][column] = table[index][column] || (column > 0 && table[row][column - 1])
                } else if column > 0 {
                    table[row][column] = table[index][column - 1] && Self.matches(segment, names[column - 1])
                }
            }
        }
        return table
    }

    static func matches(_ segment: Segment, _ name: String) -> Bool {
        switch segment {
        case .anyDepth: true
        case let .literal(literal): literal == name
        case let .wildcard(tokens): matches(tokens, Array(name))
        }
    }

    private static func matches(_ tokens: [Token], _ characters: [Character]) -> Bool {
        var previous = Array(repeating: false, count: characters.count + 1)
        previous[0] = true
        for token in tokens {
            var current = Array(repeating: false, count: characters.count + 1)
            current[0] = token == .star && previous[0]
            for index in 0 ..< characters.count {
                switch token {
                case .star: current[index + 1] = previous[index + 1] || current[index]
                case .single: current[index + 1] = previous[index]
                case let .character(character): current[index + 1] = previous[index] && character == characters[index]
                }
            }
            previous = current
        }
        return previous[characters.count]
    }

    static func parse(_ raw: String) throws(GlobPatternError) -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw .invalidCharacter
        }
        if let unsupported = trimmed.first(where: { "[]{}\\".contains($0) }) {
            throw .unsupportedSyntax(unsupported)
        }

        var body = Substring(trimmed)
        let anchor: Anchor
        if body.hasPrefix("~") {
            body = body.dropFirst()
            guard body.isEmpty || body.hasPrefix("/") else { throw .userHomeNotSupported }
            anchor = .home
        } else if body.hasPrefix("/") {
            anchor = .root
        } else {
            anchor = .anywhere
        }

        var segments: [Segment] = anchor == .anywhere ? [.anyDepth] : []
        for part in body.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            let segment = try parseSegment(part)
            if segment != .anyDepth || segments.last != .anyDepth {
                segments.append(segment)
            }
        }
        return Parsed(anchor: anchor, segments: segments)
    }

    private static func parseSegment(_ part: String) throws(GlobPatternError) -> Segment {
        if part == "." || part == ".." {
            throw .relativeSegment(part)
        }
        if part == "**" {
            return .anyDepth
        }
        if part.contains("**") {
            throw .invalidDoubleStar(part)
        }
        guard part.contains(where: { $0 == "*" || $0 == "?" }) else {
            return .literal(NormalizedPath.fold(part))
        }
        return .wildcard(NormalizedPath.fold(part).map { character in
            switch character {
            case "*": .star
            case "?": .single
            default: .character(character)
            }
        })
    }

    private static func resolve(_ parsed: Parsed, homeURL: URL) -> [Segment] {
        guard parsed.anchor != .anywhere else { return parsed.segments }
        var literalPrefix: [String] = []
        var rest = parsed.segments[...]
        while case let .literal(name)? = rest.first {
            literalPrefix.append(name)
            rest = rest.dropFirst()
        }
        let base = parsed.anchor == .home ? PathResolver.resolveDirectory(homeURL) : .root
        let resolved = PathResolver.resolveExisting(base.components + literalPrefix)
        return resolved.folded.map(Segment.literal) + rest
    }
}
