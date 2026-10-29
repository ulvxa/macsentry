import Foundation
import MacSentryCore

extension DuplicatesModel {
    // MARK: Actions

    func quarantineChecked() async {
        guard quarantineDisabledReason == nil else { return }
        await quarantine(checkedCandidates)
    }

    func requestQuarantine() {
        guard quarantineDisabledReason == nil else { return }
        confirmation = QuarantineConfirmation(
            candidates: checkedCandidates,
            isDryRun: app.environment.isDryRun,
            destination: app.quarantineFolderDisplay,
            noun: "duplicates",
        )
    }

    func confirm(_ confirmation: QuarantineConfirmation) async {
        self.confirmation = nil
        guard quarantineDisabledReason == nil else { return }
        await quarantine(confirmation.candidates)
    }

    private func quarantine(_ targets: [Candidate]) async {
        let blocked = groups.contains { group in
            let urls = targets.filter { $0.dupGroupID == group.groupID }.map(\.url)
            return !urls.isEmpty && group.wouldRemoveEveryCopy(selecting: urls)
        }
        guard !blocked, let result = await app.quarantine(targets) else { return }
        let moved = Set(result.moved.compactMap(\.candidateID))
        for group in checkedGroups where group.candidates.allSatisfy({ $0.id.map(moved.contains) == true }) {
            checkedGroupIDs.remove(group.groupID)
        }
        if !result.failed.isEmpty {
            failureReport = FailureReport(result: result)
        }
    }

    // MARK: Inspector and Quick Look

    var focusedCandidates: [Candidate] {
        groups.flatMap { group -> [Candidate] in
            if focusedIDs.contains(.group(group.groupID)) {
                return group.candidates
            }
            return group.members.filter { focusedIDs.contains($0.id) }.compactMap(displayCandidate)
        }
    }

    var focusedMember: DuplicateMember? {
        guard focusedIDs.count == 1, let id = focusedIDs.first else { return nil }
        return member(for: id)
    }

    func displayCandidate(_ member: DuplicateMember) -> Candidate? {
        guard member.isKeeper else { return member.row }
        guard let group = group(member.groupID) else { return nil }
        var keeper = member.row ?? Candidate(
            sessionID: group.group.sessionID,
            url: member.url,
            kind: .file,
            category: .duplicate,
            ruleID: DuplicateGroup.ruleID,
            tier: .yellow,
            action: .quarantine,
            reason: "",
            logicalSize: group.group.fileSize,
            allocatedSize: group.group.fileSize,
            freeableSize: 0,
            createdAt: group.keeperProbe.created,
            modifiedAt: group.keeperProbe.modified,
            dupGroupID: group.groupID,
            status: .ignored,
        )
        keeper.reason = "This copy is kept. The other copies in the group can go to quarantine."
        keeper.freeableSize = 0
        return keeper
    }

    var previewURLs: [URL] {
        let focused = focusedIDs.compactMap { member(for: $0)?.url }
        return focused.isEmpty ? visibleGroups.flatMap { $0.members.map(\.url) } : focused
    }

    func quickLook(_ ids: Set<DuplicateTableRow.ID>? = nil) {
        let targets = ids ?? focusedIDs
        quickLookURL = targets.lazy.compactMap { id -> URL? in
            switch id {
            case let .group(groupID): self.group(groupID)?.keeper.url
            case .member: self.member(for: id)?.url
            }
        }.first
    }

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLook()
        }
    }

    func urls(for ids: Set<DuplicateTableRow.ID>) -> [URL] {
        ids.flatMap { id -> [URL] in
            switch id {
            case let .group(groupID): group(groupID)?.members.map(\.url) ?? []
            case .member: member(for: id).map { [$0.url] } ?? []
            }
        }
    }

    var screenActions: ScreenActions {
        ScreenActions(
            canQuarantine: quarantineDisabledReason == nil,
            quarantine: { [weak self] in self?.requestQuarantine() },
            quickLook: { [weak self] in self?.toggleQuickLook() },
        )
    }
}
