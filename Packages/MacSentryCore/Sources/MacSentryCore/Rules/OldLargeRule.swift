import Darwin
import Foundation

public struct OldLargeRule: Sendable {
    public static let rule = Rule(
        id: "oldLarge",
        group: "Old and Large",
        category: .oldLarge,
        tier: .red,
        action: .quarantine,
        match: Match(claimWholeFolder: true),
        reason: "Large and not used for a long time. This is your data, review it before removing.",
    )

    public static let installerRule = Rule(
        id: "oldLarge.installer",
        group: "Old and Large",
        category: .oldLarge,
        tier: .yellow,
        action: .quarantine,
        match: Match(claimWholeFolder: true),
        reason: "Old installer or archive in Downloads. Download it again if you need it.",
    )

    public static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "iso", "zip"]

    public static let defaultExclusions = [
        "~/Pictures/*.photoslibrary",
        "~/Music/Music",
        "~/Library/Mail",
        "~/Library/Messages",
        "~/Library/Containers/com.apple.mail",
        "~/Library/Containers/com.apple.MobileSMS",
        "~/Library/Group Containers/group.com.apple.mail",
        "~/Library/Containers/com.docker.docker",
        "~/.Trash",
    ]

    private let homeComponents: [String]
    private let downloads: PathPattern
    private let exclusions: [PathPattern]
    private let currentUID: uid_t
    private let now: @Sendable () -> Date
    private let isInsideGitWorkTree: @Sendable (URL) -> Bool

    public init(
        homeURL: URL,
        currentUID: uid_t = getuid(),
        now: @escaping @Sendable () -> Date = { Date() },
        exclusions: [String] = OldLargeRule.defaultExclusions,
        isInsideGitWorkTree: @escaping @Sendable (URL) -> Bool,
    ) {
        let home = PathPattern.homePath(homeURL)
        homeComponents = PathPattern.components(of: home.lowercased())
        downloads = PathPattern("~/Downloads", home: home)
        self.exclusions = exclusions.map { PathPattern($0, home: home) }
        self.currentUID = currentUID
        self.now = now
        self.isInsideGitWorkTree = isInsideGitWorkTree
    }

    public func evaluate(_ entry: FileEntry, sizeInfo: SizeInfo, lastUsed: Date? = nil, thresholds: Thresholds) -> RuleMatch? {
        guard entry.kind == .file || entry.kind == .package else { return nil }
        let components = PathPattern.entryComponents(entry.url)
        guard isUnderHome(components), sizeInfo.freeable >= thresholds.minSize, isOld(entry, lastUsed: lastUsed, thresholds: thresholds),
              !exclusions.contains(where: { $0.contains(components) }), !isInsideGitWorkTree(entry.url) else { return nil }
        let isInstaller = downloads.contains(components)
            && Self.installerExtensions.contains(entry.url.pathExtension.lowercased())
        return RuleMatch(
            rule: isInstaller ? Self.installerRule : Self.rule,
            claimsFolder: entry.kind == .package,
            isRootOwned: entry.ownerUID == 0 && currentUID != 0,
            minFreeableSize: thresholds.minSize,
        )
    }

    private func isUnderHome(_ components: [String]) -> Bool {
        components.count > homeComponents.count && components.starts(with: homeComponents)
    }

    private func isOld(_ entry: FileEntry, lastUsed: Date?, thresholds: Thresholds) -> Bool {
        let date: Date? = switch thresholds.ageBasis {
        case .lastUsed: lastUsed ?? entry.modified
        case .modified: entry.modified
        case .created: entry.created
        }
        guard let date else { return false }
        return now().timeIntervalSince(date) >= Double(thresholds.minAgeDays) * 86400
    }
}
