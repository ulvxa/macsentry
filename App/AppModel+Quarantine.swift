import Foundation
import MacSentryCore

extension AppModel {
    func quarantineBatches() async throws -> [QuarantineBatchSummary] {
        guard let services else { return [] }
        return try await services.quarantine.list()
    }

    func trashQuarantined(_ entries: [QuarantineEntry], simulated: Bool) async -> TrashResult? {
        let ids = entries.compactMap(\.id)
        guard let services, !ids.isEmpty else { return nil }
        let result = await services.quarantine.trash(ids)
        await quarantineChanged()
        if !result.trashed.isEmpty {
            let count = CountFormat.items(result.trashed.count)
            let bytes = ByteFormat.string(result.trashed.reduce(Int64(0)) { $0 + $1.size })
            toast = Toast(kind: .message(simulated
                    ? "Dry run: \(count) marked as moved to the Trash. Nothing was moved."
                    : "Moved \(count) to the Trash · \(bytes). Empty the Trash to free the space."))
        }
        return result
    }

    func restoreQuarantined(_ entries: [QuarantineEntry]) async -> RestoreResult? {
        let ids = entries.compactMap(\.id)
        guard let services, !ids.isEmpty else { return nil }
        let result = await services.quarantine.restore(ids)
        await quarantineChanged()
        if !result.restored.isEmpty {
            toast = Toast(kind: .message(result.restored.count == 1
                    ? "Restored \(result.restored[0].originalURL.lastPathComponent)"
                    : "Restored \(CountFormat.items(result.restored.count))"))
        }
        return result
    }

    private func quarantineChanged() async {
        await refreshQuarantineTotals()
        await menuBar.refreshTotals()
    }
}
