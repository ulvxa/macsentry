import Darwin
import Foundation

public struct RuleMatch: Sendable, Equatable {
    public static let rootOwnedReason = "Owned by root, remove manually if you are sure"

    public let rule: Rule
    public let claimsFolder: Bool
    public let isRootOwned: Bool
    public let minFreeableSize: Int64

    public init(rule: Rule, claimsFolder: Bool, isRootOwned: Bool = false, minFreeableSize: Int64 = 0) {
        self.rule = rule
        self.claimsFolder = claimsFolder
        self.isRootOwned = isRootOwned
        self.minFreeableSize = minFreeableSize
    }

    private var overridesToFlagOnly: Bool {
        isRootOwned && rule.action == .quarantine
    }

    public var action: CandidateAction {
        overridesToFlagOnly ? .flagOnly : rule.action
    }

    public var category: Category {
        overridesToFlagOnly ? .flagged : rule.category
    }

    public var reason: String {
        overridesToFlagOnly ? Self.rootOwnedReason : rule.reason
    }

    public func cliCommand(for url: URL) -> String? {
        guard action == .flagOnly, !overridesToFlagOnly, let template = rule.cliCommand else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return template
            .replacingOccurrences(of: "{path}", with: ShellQuote.quote(url.storagePath))
            .replacingOccurrences(of: "{name}", with: ShellQuote.quote(name))
    }
}

public struct RuleFileSystem: Sendable {
    public var contentsOfDirectory: @Sendable (URL) -> [String]
    public var itemExists: @Sendable (URL) -> Bool

    public init(contentsOfDirectory: @escaping @Sendable (URL) -> [String], itemExists: @escaping @Sendable (URL) -> Bool) {
        self.contentsOfDirectory = contentsOfDirectory
        self.itemExists = itemExists
    }

    public static let live = RuleFileSystem(
        contentsOfDirectory: { url in
            (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
        },
        itemExists: { url in
            var info = stat()
            return lstat(url.path(percentEncoded: false), &info) == 0
        },
    )
}

public struct CompiledRuleSet: Sendable {
    struct Hit {
        let index: Int
        let specificity: Int
    }

    public let rules: [Rule]
    let literalIndex: [String: [Hit]]
    let globbed: [(index: Int, pattern: PathPattern)]
    let selectorOnly: [Int]
    let literalAncestors: Set<String>

    init(rules: [Rule], homePath: String) {
        self.rules = rules
        var literalIndex: [String: [Hit]] = [:]
        var globbed: [(index: Int, pattern: PathPattern)] = []
        var selectorOnly: [Int] = []
        var literalAncestors = Set<String>()
        for (index, rule) in rules.enumerated() {
            let compiled = (rule.match.paths ?? []).map { PathPattern($0, home: homePath) }
            if rule.match.paths == nil, rule.match.installedAppFolder == nil {
                selectorOnly.append(index)
            }
            for pattern in compiled {
                if let literal = pattern.literalPath {
                    literalIndex[literal, default: []].append(Hit(index: index, specificity: pattern.literalPrefixLength))
                } else {
                    globbed.append((index, pattern))
                }
                var ancestor = ""
                for segment in pattern.segments.dropLast() {
                    guard case let .literal(name) = segment else { break }
                    ancestor += "/" + name
                    literalAncestors.insert(ancestor)
                }
            }
        }
        self.literalIndex = literalIndex
        self.globbed = globbed
        self.selectorOnly = selectorOnly
        self.literalAncestors = literalAncestors
    }

    func isAncestorOfAnyPattern(_ components: [String], path: String) -> Bool {
        literalAncestors.contains(path) || globbed.contains { $0.pattern.isProperAncestor(components) }
    }
}

public protocol RuleEngine: Sendable {
    func activeRules(inventory: [InstalledApp], disabledGroups: Set<String>, existingPaths: (URL) -> Bool) -> [Rule]
    func compile(_ rules: [Rule]) -> CompiledRuleSet
    func evaluate(_ entry: FileEntry, rules: CompiledRuleSet, thresholds: Thresholds) -> RuleMatch?
}

public extension RuleEngine {
    func activeRules(inventory: [InstalledApp], existingPaths: (URL) -> Bool) -> [Rule] {
        activeRules(inventory: inventory, disabledGroups: [], existingPaths: existingPaths)
    }

    func evaluate(_ entry: FileEntry, rules: [Rule], thresholds: Thresholds) -> RuleMatch? {
        evaluate(entry, rules: compile(rules), thresholds: thresholds)
    }
}

public struct DefaultRuleEngine: RuleEngine {
    private static let secondsPerDay: TimeInterval = 86400
    private static let globExpansionLimit = 256

    public let catalog: RuleCatalog
    private let homePath: String
    private let currentUID: uid_t
    private let now: @Sendable () -> Date
    private let fileSystem: RuleFileSystem

    public init(
        catalog: RuleCatalog,
        homeURL: URL,
        currentUID: uid_t = getuid(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileSystem: RuleFileSystem = .live,
    ) {
        self.catalog = catalog
        homePath = PathPattern.homePath(homeURL)
        self.currentUID = currentUID
        self.now = now
        self.fileSystem = fileSystem
    }

    public func activeRules(inventory: [InstalledApp], disabledGroups: Set<String>, existingPaths: (URL) -> Bool) -> [Rule] {
        let installedIDs = Set(inventory.map(\.bundleID))
        var active: [Rule] = []
        var perApp: [Rule] = []
        for rule in catalog.rules where !disabledGroups.contains(rule.group) {
            if let folder = rule.match.installedAppFolder {
                perApp += materialize(rule, folder: folder, inventory: inventory, disabledGroups: disabledGroups)
                continue
            }
            let installed = rule.appBundleIDs.filter(installedIDs.contains)
            guard rule.appBundleIDs.isEmpty || !installed.isEmpty || anyPathExists(rule, existingPaths: existingPaths) else { continue }
            var match = rule.match
            if match.versionPolicy == .olderThanInstalled {
                let versions = inventory
                    .filter { rule.appBundleIDs.contains($0.bundleID) }
                    .compactMap { $0.version.flatMap(SemanticVersion.init) }
                guard let oldestInstalled = versions.min() else { continue }
                match = match.with(paths: match.paths, referenceVersion: oldestInstalled.description)
            }
            let ordered = installed + rule.appBundleIDs.filter { !installedIDs.contains($0) }
            active.append(rule.with(match: match, appBundleIDs: ordered))
        }
        return active + perApp
    }

    public func compile(_ rules: [Rule]) -> CompiledRuleSet {
        CompiledRuleSet(rules: rules, homePath: homePath)
    }

    public func evaluate(_ entry: FileEntry, rules set: CompiledRuleSet, thresholds: Thresholds) -> RuleMatch? {
        guard entry.kind != .symlink else { return nil }
        let components = PathPattern.entryComponents(entry.url)
        let path = "/" + components.joined(separator: "/")
        var hits: [CompiledRuleSet.Hit] = (set.literalIndex[path] ?? []).filter { selectorsMatch(set.rules[$0.index], entry) }
        for (index, pattern) in set.globbed where pattern.matches(components) && selectorsMatch(set.rules[index], entry) {
            hits.append(.init(index: index, specificity: pattern.literalPrefixLength))
        }
        for index in set.selectorOnly where selectorsMatch(set.rules[index], entry) {
            hits.append(.init(index: index, specificity: 0))
        }
        guard let best = hits.min(by: { isPreferred($0, over: $1, in: set) }) else { return nil }
        let rule = set.rules[best.index]
        guard passesVersionPolicy(rule, entry), passesAge(rule, entry, thresholds: thresholds) else { return nil }
        let claims = rule.match.claimWholeFolder && entry.kind != .file
        if claims, set.isAncestorOfAnyPattern(components, path: path) {
            return nil
        }
        return RuleMatch(
            rule: rule,
            claimsFolder: claims,
            isRootOwned: entry.ownerUID == 0 && currentUID != 0,
            minFreeableSize: rule.match.applyUserThresholds == true ? thresholds.minSize : 0,
        )
    }

    private func isPreferred(_ lhs: CompiledRuleSet.Hit, over rhs: CompiledRuleSet.Hit, in set: CompiledRuleSet) -> Bool {
        if lhs.specificity != rhs.specificity {
            return lhs.specificity > rhs.specificity
        }
        let left = set.rules[lhs.index].tier.severity
        let right = set.rules[rhs.index].tier.severity
        if left != right {
            return left > right
        }
        return lhs.index < rhs.index
    }

    private func selectorsMatch(_ rule: Rule, _ entry: FileEntry) -> Bool {
        let match = rule.match
        let name = entry.url.lastPathComponent
        if let dirName = match.dirName {
            guard entry.kind != .file, name.caseInsensitiveCompare(dirName) == .orderedSame else { return false }
        }
        if let marker = match.siblingMarker {
            guard fileSystem.itemExists(entry.url.deletingLastPathComponent().appending(path: marker)) else { return false }
        }
        if let extensions = match.extensions {
            let ext = entry.url.pathExtension.lowercased()
            guard entry.kind != .folder, extensions.contains(where: { $0.lowercased() == ext }) else { return false }
        }
        return true
    }

    private func passesVersionPolicy(_ rule: Rule, _ entry: FileEntry) -> Bool {
        switch rule.match.versionPolicy {
        case nil:
            return true
        case .olderThanInstalled:
            guard let reference = rule.match.referenceVersion.flatMap(SemanticVersion.init),
                  let version = SemanticVersion(entry.url.lastPathComponent)
            else { return false }
            return version.isOlder(thanInstalled: reference)
        case .olderSibling:
            guard let own = VersionedName(entry.url.lastPathComponent) else { return false }
            return fileSystem.contentsOfDirectory(entry.url.deletingLastPathComponent())
                .compactMap(VersionedName.init)
                .contains { $0.base == own.base && own.version < $0.version }
        }
    }

    private func passesAge(_ rule: Rule, _ entry: FileEntry, thresholds: Thresholds) -> Bool {
        let userMinimum = rule.match.applyUserThresholds == true ? thresholds.minAgeDays : 0
        let minimum = max(rule.match.minAgeDays ?? 0, userMinimum)
        guard minimum > 0 else { return true }
        guard let date = thresholds.ageBasis == .created ? entry.created : entry.modified else { return false }
        return now().timeIntervalSince(date) >= Double(minimum) * Self.secondsPerDay
    }

    private func anyPathExists(_ rule: Rule, existingPaths: (URL) -> Bool) -> Bool {
        (rule.match.paths ?? []).contains { pattern in
            expandGlobs(PathPattern.expand(pattern, home: homePath)).contains(where: existingPaths)
        }
    }

    private func expandGlobs(_ expanded: String) -> [URL] {
        var frontier = ["/"]
        for component in PathPattern.components(of: expanded) {
            if component.contains("*") {
                let segment = PathPattern.Segment.glob(component.lowercased().components(separatedBy: "*"))
                frontier = frontier.flatMap { parent in
                    fileSystem.contentsOfDirectory(URL(filePath: parent, directoryHint: .isDirectory))
                        .filter { segment.matches($0.lowercased()) }
                        .map { parent + $0 + "/" }
                }
                frontier = Array(frontier.prefix(Self.globExpansionLimit))
            } else {
                frontier = frontier.map { $0 + component + "/" }
            }
            if frontier.isEmpty {
                return []
            }
        }
        return frontier.map { URL(filePath: String($0.dropLast()), directoryHint: .inferFromPath) }
    }

    private func materialize(_ rule: Rule, folder: InstalledAppFolder, inventory: [InstalledApp], disabledGroups: Set<String>) -> [Rule] {
        let base = switch folder {
        case .applicationSupport: "~/Library/Application Support"
        case .caches: "~/Library/Caches"
        }
        let excluded = rule.match.excludeBundleIDPrefixes ?? []
        let subpaths = rule.match.subpaths ?? [""]
        var seenBundleIDs = Set<String>()
        var rules: [Rule] = []
        for app in inventory where !disabledGroups.contains(app.name) && !excluded.contains(where: { app.bundleID.hasPrefix($0) }) {
            guard seenBundleIDs.insert(app.bundleID).inserted else { continue }
            var seenNames = Set<String>()
            let names = [app.name, app.url.deletingPathExtension().lastPathComponent, app.bundleID]
                .filter { !$0.isEmpty && !$0.contains("/") && !$0.contains("*") && $0 != "." && $0 != ".." }
                .filter { seenNames.insert($0.lowercased()).inserted }
            let paths = names.flatMap { name in
                subpaths.map { $0.isEmpty ? "\(base)/\(name)" : "\(base)/\(name)/\($0)" }
            }
            guard !paths.isEmpty else { continue }
            rules.append(rule.with(
                group: app.name,
                match: rule.match.with(paths: paths, referenceVersion: nil),
                appBundleIDs: [app.bundleID],
            ))
        }
        return rules
    }
}

struct VersionedName {
    let base: String
    let version: SemanticVersion

    init?(_ name: String) {
        guard let match = name.wholeMatch(of: #/(.+?)-(\d+(?:\.\d+)+)(?:-.*)?/#),
              let version = SemanticVersion(String(match.output.2))
        else { return nil }
        base = match.output.1.lowercased()
        self.version = version
    }
}

enum ShellQuote {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:@%+=,")

    static func quote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
