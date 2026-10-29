import Darwin
import Foundation
import MacSentryCore
import MacSentryTestSupport

enum RuleTestKit {
    static let packageExtensions: Set = ["app", "photoslibrary", "vmwarevm", "bundle", "xcarchive"]
    static let day: TimeInterval = 86400
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let userUID: uid_t = 501

    static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * day)
    }

    static func entry(_ url: URL, ownerUID: uid_t? = nil, added: Date? = nil) -> FileEntry {
        var info = stat()
        precondition(lstat(url.path(percentEncoded: false), &info) == 0, "missing fixture \(url.path(percentEncoded: false))")
        let kind: EntryKind = switch info.st_mode & S_IFMT {
        case S_IFLNK: .symlink
        case S_IFDIR: packageExtensions.contains(url.pathExtension.lowercased()) ? .package : .folder
        default: .file
        }
        return FileEntry(
            url: url,
            kind: kind,
            logicalSize: Int64(info.st_size),
            allocatedSize: Int64(info.st_blocks) * 512,
            privateSize: nil,
            linkCount: UInt32(info.st_nlink),
            inode: info.st_ino,
            device: info.st_dev,
            flags: info.st_flags,
            created: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)),
            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            added: added,
            ownerUID: ownerUID ?? info.st_uid,
        )
    }

    static func engine(home: URL, rules: [Rule]? = nil, uid: uid_t = userUID) throws -> DefaultRuleEngine {
        let catalog = try rules.map { try RuleCatalog(rules: $0) } ?? RuleCatalog.bundled()
        return DefaultRuleEngine(catalog: catalog, homeURL: home, currentUID: uid, now: { now })
    }

    static func liveExists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0
    }

    static func app(_ bundleID: String, name: String, version: String? = nil) -> InstalledApp {
        InstalledApp(bundleID: bundleID, name: name, version: version, url: URL(filePath: "/Applications/\(name).app"))
    }

    static func size(_ bytes: Int64) -> SizeInfo {
        SizeInfo(logical: bytes, allocated: bytes, freeable: bytes)
    }

    static func rule(
        _ id: String,
        paths: [String],
        tier: Tier = .green,
        action: CandidateAction = .quarantine,
        cliCommand: String? = nil,
        claim: Bool = true,
    ) -> Rule {
        Rule(
            id: id,
            group: "Test",
            category: action == .flagOnly ? .flagged : .devCache,
            tier: tier,
            action: action,
            match: Match(paths: paths, claimWholeFolder: claim),
            reason: "Test rule \(id).",
            cliCommand: cliCommand,
        )
    }
}

extension DefaultRuleEngine {
    func match(_ url: URL, inventory: [InstalledApp] = [], thresholds: Thresholds = Thresholds(), ownerUID: uid_t? = nil) -> RuleMatch? {
        let active = activeRules(inventory: inventory, existingPaths: RuleTestKit.liveExists)
        return evaluate(RuleTestKit.entry(url, ownerUID: ownerUID), rules: active, thresholds: thresholds)
    }
}
