import Foundation

/// Folders below `<root>/<top>` that belong to whichever app owns `<top>`, attributed against the inventory when a scan starts.
public struct AppScope: Codable, Sendable, Hashable {
    public static let otherGroup = "Other App Caches"

    public let root: String
    public let names: [String]?
    public let maxDepth: Int?
    public let childMarker: String?
    public let topNames: [String]?
    public let excludeTopPrefixes: [String]?
    public let excludeTopNames: [String]?
    public let vendorFolders: Bool?
    public let unattributedTier: Tier?
    public let unattributedReason: String?
    /// Filled in by activeRules, never read from JSON: the lowercased `<top>` or `<top>/<second>` this copy covers.
    public let owner: String?
    public let attributed: Bool

    public init(
        root: String,
        names: [String]? = nil,
        maxDepth: Int? = nil,
        childMarker: String? = nil,
        topNames: [String]? = nil,
        excludeTopPrefixes: [String]? = nil,
        excludeTopNames: [String]? = nil,
        vendorFolders: Bool? = nil,
        unattributedTier: Tier? = nil,
        unattributedReason: String? = nil,
        owner: String? = nil,
        attributed: Bool = false,
    ) {
        self.root = root
        self.names = names
        self.maxDepth = maxDepth
        self.childMarker = childMarker
        self.topNames = topNames
        self.excludeTopPrefixes = excludeTopPrefixes
        self.excludeTopNames = excludeTopNames
        self.vendorFolders = vendorFolders
        self.unattributedTier = unattributedTier
        self.unattributedReason = unattributedReason
        self.owner = owner
        self.attributed = attributed
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case root, names, maxDepth, childMarker, topNames, excludeTopPrefixes, excludeTopNames, vendorFolders
        case unattributedTier, unattributedReason
    }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.reject(unknownIn: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(String.self, forKey: .root)
        names = try container.decodeIfPresent([String].self, forKey: .names)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        childMarker = try container.decodeIfPresent(String.self, forKey: .childMarker)
        topNames = try container.decodeIfPresent([String].self, forKey: .topNames)
        excludeTopPrefixes = try container.decodeIfPresent([String].self, forKey: .excludeTopPrefixes)
        excludeTopNames = try container.decodeIfPresent([String].self, forKey: .excludeTopNames)
        vendorFolders = try container.decodeIfPresent(Bool.self, forKey: .vendorFolders)
        unattributedTier = try container.decodeIfPresent(Tier.self, forKey: .unattributedTier)
        unattributedReason = try container.decodeIfPresent(String.self, forKey: .unattributedReason)
        owner = nil
        attributed = false
    }

    private static let ownerLocations: Set = ["Application Support", "Caches", "Containers"]

    /// Normalized names the app owning an unattributed app cache could run under, taken from its `<top>` folder.
    public static func ownerKeys(ofCandidateAt url: URL) -> [String] {
        let parts = url.standardizedFileURL.pathComponents
        guard let library = parts.indices.first(where: {
            parts[$0] == "Library" && $0 + 2 < parts.count && ownerLocations.contains(parts[$0 + 1])
        }) else { return [] }
        var top = library + 2
        if parts[library + 1] == "Application Support", parts[top] == "Caches", top + 1 < parts.count {
            top += 1
        }
        return AppAttribution.ownerKeys(of: parts[top])
    }

    func owned(by owner: String, attributed: Bool) -> AppScope {
        AppScope(
            root: root,
            names: names,
            maxDepth: maxDepth,
            childMarker: childMarker,
            topNames: topNames,
            excludeTopPrefixes: excludeTopPrefixes,
            excludeTopNames: excludeTopNames,
            vendorFolders: vendorFolders,
            unattributedTier: unattributedTier,
            unattributedReason: unattributedReason,
            owner: owner.lowercased(),
            attributed: attributed,
        )
    }

    var problem: String? {
        if let problem = PathPattern.problem(in: root) ?? (root.contains("*") ? "must be literal" : nil) {
            return "root \(root): \(problem)"
        }
        for name in names ?? [] {
            if let problem = PathPattern.problem(in: "~/\(name)") ?? (name.contains("*") ? "must be literal" : nil) {
                return "name \(name): \(problem)"
            }
        }
        let longest = (names ?? []).map { PathPattern.components(of: $0).count }.max()
        switch (longest, maxDepth) {
        case (nil, .some):
            return "maxDepth needs names"
        case (.some, nil):
            return "names need maxDepth"
        case let (.some(longest), .some(depth)) where depth < longest:
            return "maxDepth is shorter than a name"
        default:
            break
        }
        if unattributedReason?.isEmpty == true {
            return "unattributedReason must not be empty"
        }
        let literals = [childMarker].compactMap(\.self) + (topNames ?? []) + (excludeTopNames ?? [])
        if literals.contains(where: { $0.isEmpty || $0.contains("/") }) || childMarker?.contains("*") == true {
            return "childMarker, topNames and excludeTopNames must be single names"
        }
        return nil
    }
}

/// Matches Library folder names to installed apps by name, bundle file name, bundle id, executable or the last bundle id part.
struct AppAttribution {
    private static let updaterSuffix = "-updater"

    private static let genericKeys: Set = [
        "app", "mac", "macos", "osx", "desktop", "client", "helper", "agent", "electron", "launcher", "application", "main",
    ]

    private var byID: [String: InstalledApp] = [:]
    private var byKey: [String: InstalledApp] = [:]

    init(_ apps: [InstalledApp]) {
        for app in apps where byID[app.bundleID.lowercased()] == nil {
            byID[app.bundleID.lowercased()] = app
        }
        let tiers: [(InstalledApp) -> [String?]] = [
            { [$0.name, $0.url.deletingPathExtension().lastPathComponent, $0.bundleID] },
            { [$0.executable] },
            { [$0.bundleID.split(separator: ".").last.map(String.init)] },
        ]
        for keys in tiers {
            for app in apps {
                for key in keys(app).compactMap(\.self).map(Self.key) where key.count >= 3 && !Self.genericKeys.contains(key) {
                    byKey[key] = byKey[key] ?? app
                }
            }
        }
    }

    func app(top: String) -> InstalledApp? {
        let lower = top.lowercased()
        if let app = byID[lower] ?? longestIDPrefix(of: lower) ?? byKey[Self.key(top)] {
            return app
        }
        return Self.updaterOwner(top).flatMap { byKey[$0] }
    }

    /// electron-updater names its download folder `<app>-updater`; other dashed names are not attributed by their prefix.
    static func updaterOwner(_ top: String) -> String? {
        guard top.lowercased().hasSuffix(updaterSuffix) else { return nil }
        let owner = key(String(top.dropLast(updaterSuffix.count)))
        return owner.count >= 4 ? owner : nil
    }

    /// Normalized names a running app could have for an unattributed `<top>` folder, used to block moves while it runs.
    static func ownerKeys(of top: String) -> [String] {
        [key(top), updaterOwner(top)].compactMap { $0.flatMap { $0.count >= 3 ? $0 : nil } }
    }

    func app(top: String, second: String) -> InstalledApp? {
        byKey[Self.key(top + second)] ?? byKey[Self.key(second)]
    }

    static func key(_ value: String) -> String {
        OrphanMatcher.normalize(value)
    }

    private func longestIDPrefix(of lower: String) -> InstalledApp? {
        byID.filter { lower.hasPrefix($0.key + ".") }.max { $0.key.count < $1.key.count }?.value
    }
}

extension CompiledRuleSet {
    struct ScopeTarget {
        let index: Int
        let suffixes: [[String]]?
        let maxDepth: Int
        let marker: String?
    }

    struct ScopeRoot {
        let prefix: String
        let depth: Int
        var owners: [String: [ScopeTarget]]
    }

    static func scopeRoots(_ rules: [Rule], homePath: String) -> [ScopeRoot] {
        var roots: [ScopeRoot] = []
        for (index, rule) in rules.enumerated() {
            guard let scope = rule.match.appScope, let owner = scope.owner else { continue }
            let components = PathPattern.components(of: PathPattern.expand(scope.root, home: homePath).lowercased())
            let prefix = "/" + components.joined(separator: "/") + "/"
            let target = ScopeTarget(
                index: index,
                suffixes: scope.names.map { $0.map { PathPattern.components(of: $0.lowercased()) } },
                maxDepth: scope.maxDepth ?? 0,
                marker: scope.childMarker,
            )
            if let existing = roots.firstIndex(where: { $0.prefix == prefix }) {
                roots[existing].owners[owner, default: []].append(target)
            } else {
                roots.append(ScopeRoot(prefix: prefix, depth: components.count, owners: [owner: [target]]))
            }
        }
        return roots
    }
}

extension DefaultRuleEngine {
    func materialize(
        _ rule: Rule,
        scope: AppScope,
        attribution: AppAttribution,
        disabledGroups: Set<String>,
        listings: inout [String: [String]],
    ) -> [Rule] {
        let rootURL = URL(filePath: PathPattern.expand(scope.root, home: homePath), directoryHint: .isDirectory)
        func list(_ url: URL) -> [String] {
            if let cached = listings[url.storagePath] {
                return cached
            }
            let names = fileSystem.contentsOfDirectory(url).sorted()
            listings[url.storagePath] = names
            return names
        }
        var rules: [Rule] = []
        func add(_ owner: String, app: InstalledApp?, top: String) {
            let group = app?.name ?? AppScope.otherGroup
            guard !disabledGroups.contains(group) else { return }
            let bundleIDs = app.map { [$0.bundleID] } ?? (OrphanMatcher.isReverseDNS(top) ? [top] : [])
            let match = rule.match.with(paths: nil, referenceVersion: nil, appScope: scope.owned(by: owner, attributed: app != nil))
            rules.append(rule.with(
                group: group,
                match: match,
                appBundleIDs: bundleIDs,
                tier: app == nil ? scope.unattributedTier : nil,
                reason: app == nil ? scope.unattributedReason : nil,
            ))
        }
        for top in list(rootURL) where Self.includes(top, in: scope) {
            if let app = attribution.app(top: top) {
                add(top, app: app, top: top)
                continue
            }
            if scope.vendorFolders == true {
                for second in list(rootURL.appending(path: top, directoryHint: .isDirectory)) where !second.hasPrefix(".") {
                    if let app = attribution.app(top: top, second: second) {
                        add(top + "/" + second, app: app, top: top)
                    }
                }
            }
            add(top, app: nil, top: top)
        }
        return rules
    }

    private static func includes(_ top: String, in scope: AppScope) -> Bool {
        let lower = top.lowercased()
        guard !lower.hasPrefix("."), !lower.contains("*") else { return false }
        if (scope.excludeTopPrefixes ?? []).contains(where: { lower.hasPrefix($0.lowercased()) }) {
            return false
        }
        if (scope.excludeTopNames ?? []).contains(where: { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + ".") }) {
            return false
        }
        guard let globs = scope.topNames else { return true }
        return globs.contains { PathPattern.Segment.glob($0.lowercased().components(separatedBy: "*")).matches(lower) }
    }

    func scopeHits(_ components: [String], path: String, entry: FileEntry, in set: CompiledRuleSet) -> [CompiledRuleSet.Hit] {
        guard entry.kind != .file else { return [] }
        var hits: [CompiledRuleSet.Hit] = []
        for root in set.scopeRoots where components.count > root.depth && path.hasPrefix(root.prefix) {
            let relative = components[root.depth...]
            let top = relative[relative.startIndex]
            var targets: [CompiledRuleSet.ScopeTarget] = []
            if relative.count > 1 {
                targets = root.owners[top + "/" + relative[relative.startIndex + 1]] ?? []
            }
            if targets.isEmpty {
                targets = root.owners[top] ?? []
            }
            for target in targets where matches(target, relative: relative, entry: entry) {
                hits.append(.init(index: target.index, specificity: root.prefix.count - 1))
            }
        }
        return hits
    }

    private func matches(_ target: CompiledRuleSet.ScopeTarget, relative: ArraySlice<String>, entry: FileEntry) -> Bool {
        guard let suffixes = target.suffixes else { return relative.count == 1 }
        let depth = relative.count - 1
        guard depth >= 1, depth <= target.maxDepth,
              suffixes.contains(where: { $0.count <= depth && relative.suffix($0.count).elementsEqual($0) })
        else { return false }
        return target.marker.map { fileSystem.itemExists(entry.url.appending(path: $0)) } ?? true
    }

    /// `<root>/<top>` of a match no installed app owns, so the orphan detector can claim the whole folder instead.
    func unattributedFolder(of rule: Rule, entry: FileEntry, components: [String]) -> URL? {
        guard let scope = rule.match.appScope, !scope.attributed else { return nil }
        let rootDepth = PathPattern.components(of: PathPattern.expand(scope.root, home: homePath)).count
        var folder = entry.url
        for _ in 0 ..< max(0, components.count - rootDepth - 1) {
            folder = folder.deletingLastPathComponent()
        }
        return folder
    }
}
