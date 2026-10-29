import Foundation
import MacSentryCore

extension AppModel {
    var reclaimableBytes: Int64? {
        guard currentSessionID != nil else { return nil }
        return totals.reclaimable.freeable
    }

    func refreshLocalSnapshots() async {
        guard let checker = services?.snapshots else { return }
        hasLocalSnapshots = await ((try? checker.localSnapshotCount()) ?? 0) > 0
    }

    func sampleVolume() async -> VolumeCapacity? {
        guard let sampler = services?.volume else { return nil }
        return await Task.detached(priority: .utility) { try? sampler.sample() }.value
    }

    func revealCandidate(at url: URL) async {
        guard let sessionID = currentSessionID, let store = services?.candidates else { return }
        let path = treemapStoragePath(url)
        let matches = await (try? store.candidates(session: sessionID, filter: CandidateFilter(search: path))) ?? []
        guard let candidate = matches.first(where: { treemapStoragePath($0.url) == path }) else { return }
        reveal(candidate)
    }
}
