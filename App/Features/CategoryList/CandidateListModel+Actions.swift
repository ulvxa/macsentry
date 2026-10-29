import Foundation
import MacSentryCore

extension CandidateListModel {
    func quarantineChecked() async {
        await quarantine(checkedCandidates)
    }

    func requestQuarantine() {
        guard quarantineDisabledReason == nil else { return }
        confirmation = QuarantineConfirmation(
            candidates: checkedCandidates,
            isDryRun: app.environment.isDryRun,
            destination: app.quarantineFolderDisplay,
        )
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

    func ignore(_ ids: Set<CandidateRow.ID>) async {
        let targets = candidates(for: ids)
        checkedIDs.subtract(targets.compactMap(\.id))
        await app.ignore(targets)
    }

    func addToNeverTouch(_ ids: Set<CandidateRow.ID>) async {
        let targets = candidates(for: ids)
        checkedIDs.subtract(targets.compactMap(\.id))
        await app.addToNeverTouch(targets)
    }

    func candidates(for ids: Set<CandidateRow.ID>) -> [Candidate] {
        var wanted = Set<Int64>()
        var groups = Set<String>()
        for id in ids {
            switch id {
            case let .item(value): wanted.insert(value)
            case let .group(name): groups.insert(name)
            }
        }
        return candidates.filter { candidate in
            candidate.id.map(wanted.contains) == true || groups.contains(app.ruleGroup(for: candidate.ruleID))
        }
    }

    var focusedCandidates: [Candidate] {
        candidates(for: focusedIDs)
    }

    // MARK: Quick Look

    var previewURLs: [URL] {
        let focused = focusedCandidates
        return (focused.isEmpty ? candidates : focused).map(\.url)
    }

    func quickLook(_ ids: Set<CandidateRow.ID>? = nil) {
        quickLookURL = candidates(for: ids ?? focusedIDs).first?.url
    }

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLook()
        }
    }

    // MARK: Groups

    func isExpanded(_ group: String) -> Bool {
        !collapsedGroups.contains(group)
    }

    func setExpanded(_ group: String, _ expanded: Bool) {
        if expanded {
            collapsedGroups.remove(group)
        } else {
            collapsedGroups.insert(group)
        }
    }

    var screenActions: ScreenActions {
        ScreenActions(
            canQuarantine: configuration.isCheckable && quarantineDisabledReason == nil,
            quarantine: { [weak self] in self?.requestQuarantine() },
            quickLook: { [weak self] in self?.toggleQuickLook() },
        )
    }
}
