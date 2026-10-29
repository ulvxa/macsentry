import Foundation
import MacSentryCore

extension AppModel {
    func quarantineBlockReason(for candidates: [Candidate]) -> String? {
        guard services != nil else { return "MacSentry is still loading" }
        if isQuarantining {
            return "Moving items to quarantine"
        }
        if let running = runningSessionID, candidates.contains(where: { $0.sessionID == running }) {
            return "Wait for the scan to finish"
        }
        if candidates.contains(where: { $0.sessionID != currentSessionID }) {
            return "These results are from an older scan. Scan again to review them."
        }
        if candidates.contains(where: { $0.action != .quarantine }) {
            return "Flagged items are cleaned with their own tool"
        }
        return nil
    }

    func quarantine(_ candidates: [Candidate]) async -> QuarantineResult? {
        let eligible = candidates.filter { $0.status == .found }
        guard let services, !eligible.isEmpty else { return nil }
        if let reason = quarantineBlockReason(for: eligible) {
            toast = Toast(kind: .message("Nothing was quarantined. \(reason)"))
            return nil
        }
        isQuarantining = true
        defer { isQuarantining = false }
        let result = await services.quarantine.quarantine(eligible)
        await refreshQuarantineTotals()
        await menuBar.refreshTotals()
        if !result.moved.isEmpty {
            let bytes = result.moved.reduce(Int64(0)) { $0 + $1.size }
            let text = environment.isDryRun
                ? "Dry run: \(CountFormat.items(result.moved.count)) would be quarantined. Nothing was moved."
                : "Moved \(CountFormat.items(result.moved.count)) to quarantine · \(ByteFormat.string(bytes))"
            toast = Toast(kind: .message(text), action: ToastAction(title: "View", destination: .quarantine))
        }
        return result
    }

    func ignore(_ candidates: [Candidate]) async {
        guard let services, !candidates.isEmpty else { return }
        do {
            try await services.candidates.ignore(paths: candidates.map(\.url))
        } catch {
            alert = AppAlert(title: "Couldn't Ignore", message: error.localizedDescription)
            return
        }
        if await refreshProtection() {
            toast = Toast(kind: .message(candidates.count == 1
                    ? "Ignored \(candidates[0].name)"
                    : "Ignored \(CountFormat.items(candidates.count))"))
        }
    }

    func addToNeverTouch(_ candidates: [Candidate]) async {
        guard let services, !candidates.isEmpty else { return }
        do {
            for candidate in candidates {
                do {
                    try await services.neverTouch.add(
                        candidate.url.path(percentEncoded: false),
                        note: "Added from \(candidate.category.title)",
                    )
                } catch ProtectionStoreError.duplicatePattern {
                    continue
                }
            }
            try await services.candidates.setStatus(.ignored, ids: candidates.compactMap(\.id))
        } catch {
            alert = AppAlert(title: "Couldn't Add to Never Touch", message: error.localizedDescription)
            return
        }
        await neverTouch?.load()
        if await refreshProtection() {
            toast = Toast(kind: .message(candidates.count == 1
                    ? "Added \(candidates[0].name) to Never Touch"
                    : "Added \(CountFormat.items(candidates.count)) to Never Touch"))
        }
    }

    private func refreshProtection() async -> Bool {
        guard let provider = services?.protection else { return true }
        do {
            try await provider.refresh()
            return true
        } catch {
            alert = AppAlert(
                title: "Protection Rules Out of Date",
                message: "Your change was saved, but MacSentry couldn't reload its protection rules. \(error.localizedDescription)",
            )
            return false
        }
    }

    func runningApps(among bundleIDs: Set<String>) -> Set<String> {
        guard let services, !bundleIDs.isEmpty else { return [] }
        if let running = services.runningBundleIDs {
            return bundleIDs.intersection(running())
        }
        return bundleIDs.filter { services.inventory.isRunning(bundleID: $0) }
    }
}
