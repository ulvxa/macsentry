import Foundation

public enum RuleCatalogError: LocalizedError, Equatable {
    case resourcesMissing
    case unreadable(URL, reason: String)
    case invalidJSON(file: String, reason: String)
    case invalidRule(id: String, reason: String)
    case duplicateID(String)

    public var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            "The bundled rule catalog is missing."
        case let .unreadable(url, reason):
            "Cannot read rule file \(url.path(percentEncoded: false)): \(reason)"
        case let .invalidJSON(file, reason):
            "Rule file \(file) is invalid: \(reason)"
        case let .invalidRule(id, reason):
            "Rule \(id) is invalid: \(reason)"
        case let .duplicateID(id):
            "Rule id \(id) is defined more than once."
        }
    }
}

public struct RuleCatalog: Sendable, Equatable {
    public static let nonRuleFiles: Set<String> = ["system-allowlist.json"]

    public let rules: [Rule]

    public var groups: [String] {
        var seen = Set<String>()
        return rules.map(\.group).filter { seen.insert($0).inserted }
    }

    public init(rules: [Rule]) throws {
        var ids = Set<String>()
        for rule in rules {
            guard ids.insert(rule.id).inserted else { throw RuleCatalogError.duplicateID(rule.id) }
            try RuleValidator.validate(rule)
        }
        self.rules = rules
    }

    public init(directory: URL) throws {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" && !Self.nonRuleFiles.contains($0.lastPathComponent) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            throw RuleCatalogError.unreadable(directory, reason: error.localizedDescription)
        }
        var rules: [Rule] = []
        for file in files {
            try rules.append(contentsOf: Self.decode(file))
        }
        try self.init(rules: rules)
    }

    public static func bundled() throws -> RuleCatalog {
        guard let directory = Bundle.module.url(forResource: "Rules", withExtension: nil) else {
            throw RuleCatalogError.resourcesMissing
        }
        return try RuleCatalog(directory: directory)
    }

    public static func decode(_ data: Data, file: String) throws -> [Rule] {
        do {
            return try JSONDecoder().decode([Rule].self, from: data)
        } catch let error as DecodingError {
            throw RuleCatalogError.invalidJSON(file: file, reason: describe(error))
        } catch {
            throw RuleCatalogError.invalidJSON(file: file, reason: error.localizedDescription)
        }
    }

    private static func decode(_ file: URL) throws -> [Rule] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw RuleCatalogError.unreadable(file, reason: error.localizedDescription)
        }
        return try decode(data, file: file.lastPathComponent)
    }

    private static func describe(_ error: DecodingError) -> String {
        let context: DecodingError.Context? = switch error {
        case let .dataCorrupted(context), let .keyNotFound(_, context), let .typeMismatch(_, context), let .valueNotFound(_, context):
            context
        @unknown default:
            nil
        }
        guard let context else { return String(describing: error) }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        var message = path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        if case let .keyNotFound(key, _) = error {
            message += " (\(key.stringValue))"
        }
        return message
    }
}

enum RuleValidator {
    static func validate(_ rule: Rule) throws {
        func fail(_ reason: String) -> RuleCatalogError {
            .invalidRule(id: rule.id, reason: reason)
        }
        let match = rule.match
        guard !rule.id.isEmpty, !rule.group.isEmpty, !rule.reason.isEmpty else { throw fail("id, group and reason are required") }
        if rule.cliCommand != nil, rule.action != .flagOnly {
            throw fail("cliCommand is only allowed on flagOnly rules")
        }
        let hasSelector = match.paths != nil || match.dirName != nil || match.extensions != nil || match.installedAppFolder != nil
        guard hasSelector || match.appScope != nil else {
            throw fail("match needs paths, dirName, extensions, installedAppFolder or appScope")
        }
        if match.installedAppFolder != nil, match.paths != nil {
            throw fail("installedAppFolder and paths are mutually exclusive")
        }
        if let scope = match.appScope {
            guard !hasSelector, match.versionPolicy == nil else { throw fail("appScope cannot be combined with other selectors") }
            if let problem = scope.problem {
                throw fail("appScope \(problem)")
            }
        }
        try validateDependencies(rule)
        if let days = match.minAgeDays, days < 0 {
            throw fail("minAgeDays must not be negative")
        }
        try validatePaths(rule)
    }

    private static func validateDependencies(_ rule: Rule) throws {
        let match = rule.match
        let problem: String? = if match.installedAppFolder == nil, match.subpaths != nil || match.excludeBundleIDPrefixes != nil {
            "subpaths and excludeBundleIDPrefixes need installedAppFolder"
        } else if match.siblingMarker != nil, match.dirName == nil {
            "siblingMarker needs dirName"
        } else if match.versionPolicy != nil, match.paths == nil {
            "versionPolicy needs paths"
        } else if match.versionPolicy == .olderThanInstalled, rule.appBundleIDs.isEmpty {
            "olderThanInstalled needs appBundleIDs"
        } else {
            nil
        }
        if let problem {
            throw RuleCatalogError.invalidRule(id: rule.id, reason: problem)
        }
    }

    private static func validatePaths(_ rule: Rule) throws {
        func fail(_ reason: String) -> RuleCatalogError {
            .invalidRule(id: rule.id, reason: reason)
        }
        let match = rule.match
        for path in match.paths ?? [] {
            if let problem = PathPattern.problem(in: path) {
                throw fail("path \(path): \(problem)")
            }
        }
        for subpath in match.subpaths ?? [] {
            if let problem = PathPattern.problem(in: "~/\(subpath)") {
                throw fail("subpath \(subpath): \(problem)")
            }
        }
        for name in [match.dirName, match.siblingMarker].compactMap(\.self) where name.isEmpty || name.contains("/") || name.contains("*") {
            throw fail("\(name) must be a single literal name")
        }
    }
}
