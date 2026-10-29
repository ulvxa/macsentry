import Foundation

public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        guard let start = string.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        var components: [Int] = []
        var current = ""
        for character in string[start...] {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else if character == ".", !current.isEmpty {
                components.append(Int(current) ?? 0)
                current = ""
            } else {
                break
            }
        }
        if !current.isEmpty {
            components.append(Int(current) ?? 0)
        }
        guard !components.isEmpty else { return nil }
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs.components, rhs.components) == .orderedAscending
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        compare(lhs.components, rhs.components) == .orderedSame
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        hasher.combine(trimmed)
    }

    /// A folder named "4.1" belongs to an installed "4.1.2", so compare only the precision the folder carries.
    public func isOlder(thanInstalled installed: SemanticVersion) -> Bool {
        Self.compare(components, Array(installed.components.prefix(components.count))) == .orderedAscending
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0 ..< max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right {
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
