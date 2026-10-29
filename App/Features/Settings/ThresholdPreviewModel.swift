import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class ThresholdPreviewModel {
    struct Key: Equatable {
        let thresholds: Thresholds
        let sessionID: Int64?
    }

    static let debounce: Duration = .milliseconds(250)

    private(set) var match: CategoryTotal?

    var text: String? {
        match.map { "Currently matches \(CountFormat.items($0.count)), \(ByteFormat.string($0.freeable))" }
    }

    static func key(for app: AppModel) -> Key {
        Key(thresholds: app.settings.thresholds, sessionID: app.latestFinishedSession?.id)
    }

    func refresh(app: AppModel, debounce: Duration = ThresholdPreviewModel.debounce) async {
        if debounce > .zero {
            try? await Task.sleep(for: debounce)
        }
        guard !Task.isCancelled else { return }
        guard let sessionID = app.latestFinishedSession?.id, let store = app.services?.candidates else {
            match = nil
            return
        }
        let thresholds = app.settings.thresholds
        let filter = CandidateFilter(
            categories: [.oldLarge],
            actions: [.quarantine],
            minFreeable: thresholds.minSize,
            minAgeDays: thresholds.minAgeDays,
            ageBasis: thresholds.ageBasis,
        )
        let value = try? await store.total(session: sessionID, filter: filter)
        guard !Task.isCancelled else { return }
        match = value
    }
}
