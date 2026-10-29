import Foundation

public enum InstalledAppFolder: String, Codable, Sendable, Hashable {
    case applicationSupport, caches
}

public enum VersionPolicy: String, Codable, Sendable, Hashable {
    case olderThanInstalled, olderSibling
}

public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let group: String
    public let category: Category
    public let tier: Tier
    public let action: CandidateAction
    public let match: Match
    public let appBundleIDs: [String]
    public let requiresAppQuit: Bool
    public let reason: String
    public let cliCommand: String?
    public let verify: Bool

    public init(
        id: String,
        group: String,
        category: Category,
        tier: Tier,
        action: CandidateAction,
        match: Match,
        appBundleIDs: [String] = [],
        requiresAppQuit: Bool = false,
        reason: String,
        cliCommand: String? = nil,
        verify: Bool = false,
    ) {
        self.id = id
        self.group = group
        self.category = category
        self.tier = tier
        self.action = action
        self.match = match
        self.appBundleIDs = appBundleIDs
        self.requiresAppQuit = requiresAppQuit
        self.reason = reason
        self.cliCommand = cliCommand
        self.verify = verify
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, group, category, tier, action, match, appBundleIDs, requiresAppQuit, reason, cliCommand, verify
    }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.reject(unknownIn: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        group = try container.decode(String.self, forKey: .group)
        category = try container.decode(Category.self, forKey: .category)
        tier = try container.decode(Tier.self, forKey: .tier)
        action = try container.decode(CandidateAction.self, forKey: .action)
        match = try container.decode(Match.self, forKey: .match)
        appBundleIDs = try container.decode([String].self, forKey: .appBundleIDs)
        requiresAppQuit = try container.decode(Bool.self, forKey: .requiresAppQuit)
        reason = try container.decode(String.self, forKey: .reason)
        cliCommand = try container.decodeIfPresent(String.self, forKey: .cliCommand)
        verify = try container.decode(Bool.self, forKey: .verify)
    }

    func with(group: String? = nil, match: Match? = nil, appBundleIDs: [String]? = nil) -> Rule {
        Rule(
            id: id,
            group: group ?? self.group,
            category: category,
            tier: tier,
            action: action,
            match: match ?? self.match,
            appBundleIDs: appBundleIDs ?? self.appBundleIDs,
            requiresAppQuit: requiresAppQuit,
            reason: reason,
            cliCommand: cliCommand,
            verify: verify,
        )
    }
}

public struct Match: Codable, Sendable, Hashable {
    public let paths: [String]?
    public let dirName: String?
    public let siblingMarker: String?
    public let extensions: [String]?
    public let minAgeDays: Int?
    public let claimWholeFolder: Bool
    public let installedAppFolder: InstalledAppFolder?
    public let subpaths: [String]?
    public let excludeBundleIDPrefixes: [String]?
    public let versionPolicy: VersionPolicy?
    public let applyUserThresholds: Bool?
    /// Filled in by activeRules from the inventory, never read from JSON.
    public let referenceVersion: String?

    public init(
        paths: [String]? = nil,
        dirName: String? = nil,
        siblingMarker: String? = nil,
        extensions: [String]? = nil,
        minAgeDays: Int? = nil,
        claimWholeFolder: Bool,
        installedAppFolder: InstalledAppFolder? = nil,
        subpaths: [String]? = nil,
        excludeBundleIDPrefixes: [String]? = nil,
        versionPolicy: VersionPolicy? = nil,
        applyUserThresholds: Bool? = nil,
        referenceVersion: String? = nil,
    ) {
        self.paths = paths
        self.dirName = dirName
        self.siblingMarker = siblingMarker
        self.extensions = extensions
        self.minAgeDays = minAgeDays
        self.claimWholeFolder = claimWholeFolder
        self.installedAppFolder = installedAppFolder
        self.subpaths = subpaths
        self.excludeBundleIDPrefixes = excludeBundleIDPrefixes
        self.versionPolicy = versionPolicy
        self.applyUserThresholds = applyUserThresholds
        self.referenceVersion = referenceVersion
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case paths, dirName, siblingMarker, extensions, minAgeDays, claimWholeFolder
        case installedAppFolder, subpaths, excludeBundleIDPrefixes, versionPolicy, applyUserThresholds
    }

    public init(from decoder: any Decoder) throws {
        try StrictKeys.reject(unknownIn: decoder, known: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decodeIfPresent([String].self, forKey: .paths)
        dirName = try container.decodeIfPresent(String.self, forKey: .dirName)
        siblingMarker = try container.decodeIfPresent(String.self, forKey: .siblingMarker)
        extensions = try container.decodeIfPresent([String].self, forKey: .extensions)
        minAgeDays = try container.decodeIfPresent(Int.self, forKey: .minAgeDays)
        claimWholeFolder = try container.decode(Bool.self, forKey: .claimWholeFolder)
        installedAppFolder = try container.decodeIfPresent(InstalledAppFolder.self, forKey: .installedAppFolder)
        subpaths = try container.decodeIfPresent([String].self, forKey: .subpaths)
        excludeBundleIDPrefixes = try container.decodeIfPresent([String].self, forKey: .excludeBundleIDPrefixes)
        versionPolicy = try container.decodeIfPresent(VersionPolicy.self, forKey: .versionPolicy)
        applyUserThresholds = try container.decodeIfPresent(Bool.self, forKey: .applyUserThresholds)
        referenceVersion = nil
    }

    func with(paths: [String]?, referenceVersion: String?) -> Match {
        Match(
            paths: paths,
            dirName: dirName,
            siblingMarker: siblingMarker,
            extensions: extensions,
            minAgeDays: minAgeDays,
            claimWholeFolder: claimWholeFolder,
            versionPolicy: versionPolicy,
            applyUserThresholds: applyUserThresholds,
            referenceVersion: referenceVersion,
        )
    }
}

private enum StrictKeys {
    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }
    }

    static func reject<Known: CodingKey & CaseIterable>(unknownIn decoder: any Decoder, known _: Known.Type) throws {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        let knownNames = Set(Known.allCases.map(\.stringValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !knownNames.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown keys: \(unknown.joined(separator: ", "))",
            ))
        }
    }
}
