import Foundation

final class RuleScanHandler: ScanEntryHandler {
    private let engine: DefaultRuleEngine
    private let rules: CompiledRuleSet
    private let thresholds: Thresholds
    private let oldLarge: OldLargeRule
    private let gate: CandidateGate
    private let claims: WalkClaims
    private let deferred: DeferredAppCaches?

    init(
        engine: DefaultRuleEngine,
        rules: CompiledRuleSet,
        thresholds: Thresholds,
        oldLarge: OldLargeRule,
        gate: CandidateGate,
        claims: WalkClaims,
        deferred: DeferredAppCaches? = nil,
    ) {
        self.engine = engine
        self.rules = rules
        self.thresholds = thresholds
        self.oldLarge = oldLarge
        self.gate = gate
        self.claims = claims
        self.deferred = deferred
    }

    func visit(_ entry: FileEntry, context: ScanContext) async -> HandlerDecision {
        guard entry.kind != .symlink, !claims.contains(entry.url) else { return .descend }
        if let match = engine.evaluate(entry, rules: rules, thresholds: thresholds) {
            guard entry.kind != .folder || match.claimsFolder else { return .descend }
            if let owner = match.unattributedFolder, let deferred, deferred.holds(owner) {
                if case let .claim(draft) = claim(entry, match: match, context: context) {
                    deferred.add(DeferredAppCaches.Item(entry: entry, draft: draft))
                }
                return .descend
            }
            return claim(entry, match: match, context: context)
        }
        guard entry.kind != .folder else { return .descend }
        let size = context.sizeCalculator.sizeInfo(for: entry)
        guard let match = oldLarge.evaluate(entry, sizeInfo: size, thresholds: thresholds) else { return .descend }
        return claim(entry, match: match, context: context, lastUsed: OldLargeRule.activityDate(of: entry))
    }

    private func claim(_ entry: FileEntry, match: RuleMatch, context: ScanContext, lastUsed: Date? = nil) -> HandlerDecision {
        if entry.kind != .folder, context.sizeCalculator.sizeInfo(for: entry).freeable < match.minFreeableSize {
            return .descend
        }
        guard gate.admits(entry.url, action: match.action) else { return .descend }
        return .claim(CandidateDraft(
            category: match.category,
            ruleID: match.rule.id,
            tier: match.rule.tier,
            action: match.action,
            reason: match.reason,
            cliCommand: match.cliCommand(for: entry.url),
            appBundleID: match.rule.appBundleIDs.first,
            lastUsedAt: lastUsed,
            minFreeableSize: match.minFreeableSize,
            group: match.rule.group,
        ))
    }
}
