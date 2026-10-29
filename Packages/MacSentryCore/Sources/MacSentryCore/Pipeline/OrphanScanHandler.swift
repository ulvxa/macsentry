import Foundation

struct OrphanScanHandler: ScanEntryHandler {
    let finishPhase: ScanPhase? = .orphans
    let library: URL
    let apps: [InstalledApp]
    let helperBundleIDs: Set<String>
    let allowlist: SystemAllowlist
    let policy: any ProtectionPolicy
    let applicationURL: DefaultOrphanDetector.ApplicationLookup
    let rules: CompiledRuleSet
    let gate: CandidateGate

    func finish(context: ScanContext) async throws -> [Candidate] {
        let emitted = try await EmittedPaths.load(session: context.sessionID, database: context.database)
        let rules = rules
        let sizeCalculator = context.sizeCalculator
        let detector = DefaultOrphanDetector(
            sessionID: context.sessionID,
            allowlist: allowlist,
            policy: policy,
            helperBundleIDs: helperBundleIDs,
            applicationURL: applicationURL,
            isClaimedByRule: { rules.claims($0) || emitted.overlaps($0) },
            folderSize: { try await sizeCalculator.aggregate(folder: $0) },
        )
        return try await detector.detect(inventory: apps, library: library)
            .filter { gate.admits($0.url, action: $0.action) && !emitted.overlaps($0.url) }
    }
}
