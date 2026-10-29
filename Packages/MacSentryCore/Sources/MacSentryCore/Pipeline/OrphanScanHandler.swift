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

struct LeftoverProbe: Sendable {
    let library: URL
    let matcher: OrphanMatcher
    let applicationURL: DefaultOrphanDetector.ApplicationLookup

    /// True when the orphan pass would report this `~/Library/<location>/<name>` folder as owned by no installed app.
    func isLeftover(_ folder: URL) -> Bool {
        let parent = folder.deletingLastPathComponent().storagePath
        guard let location = OrphanLocation.allCases.first(where: {
            library.appending(path: $0.folderName, directoryHint: .isDirectory).storagePath == parent
        }) else { return false }
        let name = folder.lastPathComponent
        let identity = DefaultOrphanDetector.resolveIdentity(of: folder, name: name, in: location)
        guard !matcher.isSystem(name), !matcher.isSystem(identity.value) else { return false }
        return !DefaultOrphanDetector.isOwned(identity, matcher: matcher, applicationURL: applicationURL)
    }
}
