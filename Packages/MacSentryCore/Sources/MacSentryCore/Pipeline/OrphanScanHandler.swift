import Foundation
import Synchronization

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
    let deferred: DeferredAppCaches?

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
        let orphans = try await detector.detect(inventory: apps, library: library)
            .filter { gate.admits($0.url, action: $0.action) && !emitted.overlaps($0.url) }
        return try await orphans + releasedCaches(orphans: orphans, emitted: emitted, context: context)
    }

    /// Deferred caches whose folder the orphan pass did not report whole are emitted now, so each folder is counted once.
    private func releasedCaches(orphans: [Candidate], emitted: EmittedPaths, context: ScanContext) async throws -> [Candidate] {
        guard let deferred else { return [] }
        let reported = EmittedPaths(orphans.map(\.url.storagePath))
        var kept: [String] = []
        var released: [Candidate] = []
        for item in deferred.items.sorted(by: { $0.entry.url.storagePath < $1.entry.url.storagePath }) {
            try Task.checkCancellation()
            let url = item.entry.url
            let path = url.storagePath
            guard !kept.contains(where: { path.hasPrefix($0 + "/") }), !reported.overlaps(url), !emitted.overlaps(url),
                  gate.admits(url, action: item.draft.action),
                  let size = try? await context.sizeCalculator.aggregate(folder: url)
            else { continue }
            kept.append(path)
            released.append(context.candidate(item.draft, for: item.entry, size: size))
        }
        return released
    }
}

/// Unattributed app caches inside a top level Library folder wait for the orphan pass: if it reports that folder whole they are
/// dropped, otherwise they are emitted. This keeps the decision identical to the orphan pass instead of predicting it.
final class DeferredAppCaches: Sendable {
    struct Item: Sendable {
        let entry: FileEntry
        let draft: CandidateDraft
    }

    private let locations: Set<String>
    private let held = Mutex<[Item]>([])

    init(library: URL) {
        locations = Set(OrphanLocation.allCases.map { library.appending(path: $0.folderName, directoryHint: .isDirectory).storagePath })
    }

    func holds(_ owner: URL) -> Bool {
        locations.contains(owner.deletingLastPathComponent().storagePath)
    }

    func add(_ item: Item) {
        held.withLock { $0.append(item) }
    }

    var items: [Item] {
        held.withLock { $0 }
    }
}
