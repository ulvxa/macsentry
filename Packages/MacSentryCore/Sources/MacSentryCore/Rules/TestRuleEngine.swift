import Foundation

public struct TestRuleEngine: RuleEngine {
    public var rules: [Rule]
    public var matches: [URL: RuleMatch]

    public init(rules: [Rule] = [], matches: [URL: RuleMatch] = [:]) {
        self.rules = rules
        self.matches = matches
    }

    public func activeRules(inventory _: [InstalledApp], disabledGroups: Set<String>, existingPaths _: (URL) -> Bool) -> [Rule] {
        rules.filter { !disabledGroups.contains($0.group) }
    }

    public func compile(_ rules: [Rule]) -> CompiledRuleSet {
        CompiledRuleSet(rules: rules, homePath: "/")
    }

    public func evaluate(_ entry: FileEntry, rules _: CompiledRuleSet, thresholds _: Thresholds) -> RuleMatch? {
        entry.kind == .symlink ? nil : matches[entry.url]
    }
}
