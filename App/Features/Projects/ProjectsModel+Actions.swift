import Foundation
import MacSentryCore

extension ProjectsModel {
    func requestQuarantine() {
        guard quarantineDisabledReason == nil else { return }
        confirmation = QuarantineConfirmation(candidates: checkedCandidates, isDryRun: app.environment.isDryRun, noun: "artifacts")
    }

    func quarantineChecked() async {
        await quarantine(checkedCandidates)
    }

    func confirm(_ confirmation: QuarantineConfirmation) async {
        self.confirmation = nil
        await quarantine(confirmation.candidates)
    }

    private func quarantine(_ targets: [Candidate]) async {
        guard let result = await app.quarantine(targets) else { return }
        checkedIDs.subtract(result.moved.compactMap(\.candidateID))
        if !result.failed.isEmpty {
            failureReport = FailureReport(result: result)
        }
    }

    func ignoreChecked() async {
        let targets = checkedCandidates
        checkedIDs.subtract(targets.compactMap(\.id))
        await app.ignore(targets)
    }

    func ignore(_ ids: Set<ProjectTableRow.ID>) async {
        let targets = targets(for: ids)
        checkedIDs.subtract(targets.compactMap(\.id))
        await app.ignore(targets)
    }

    func addToNeverTouch(_ ids: Set<ProjectTableRow.ID>) async {
        let targets = targets(for: ids)
        checkedIDs.subtract(targets.compactMap(\.id))
        await app.addToNeverTouch(targets)
    }

    var screenActions: ScreenActions {
        ScreenActions(
            canQuarantine: quarantineDisabledReason == nil,
            quarantine: { [weak self] in self?.requestQuarantine() },
            quickLook: nil,
        )
    }
}
