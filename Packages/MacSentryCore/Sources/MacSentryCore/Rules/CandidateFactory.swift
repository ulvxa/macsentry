import Foundation

public enum CandidateFactory {
    public static func candidate(
        for entry: FileEntry,
        sizeInfo: SizeInfo,
        match: RuleMatch,
        sessionID: Int64,
        lastUsed: Date? = nil,
    ) -> Candidate? {
        let kind: CandidateKind
        switch entry.kind {
        case .file: kind = .file
        case .folder: kind = .folder
        case .package: kind = .package
        case .symlink: return nil
        }
        guard sizeInfo.freeable >= match.minFreeableSize else { return nil }
        return Candidate(
            sessionID: sessionID,
            url: entry.url,
            kind: kind,
            category: match.category,
            ruleID: match.rule.id,
            tier: match.rule.tier,
            action: match.action,
            reason: match.reason,
            cliCommand: match.cliCommand(for: entry.url),
            appBundleID: match.rule.appBundleIDs.first,
            logicalSize: sizeInfo.logical,
            allocatedSize: sizeInfo.allocated,
            freeableSize: sizeInfo.freeable,
            createdAt: entry.created,
            modifiedAt: entry.modified,
            lastUsedAt: lastUsed,
        )
    }
}
