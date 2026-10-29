import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class DuplicatesModel {
    enum Phase: Equatable {
        case loading, noScan, scanningNoData, failed(String), loaded
    }

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    static let keepOneCopyReason = "Keep at least one copy of each file"

    let app: AppModel
    private(set) var sessionID: Int64?
    private(set) var groups: [DuplicateGroupRow] = []
    private(set) var isChangingKeeper = false
    private var loadState: LoadState = .idle
    var checkedGroupIDs: Set<Int64> = []
    var focusedIDs: Set<DuplicateTableRow.ID> = []
    var collapsedGroupIDs: Set<Int64> = []
    var query = ""
    var quickLookURL: URL?
    var confirmation: QuarantineConfirmation?
    var failureReport: FailureReport?

    @ObservationIgnored private var observeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(app: AppModel) {
        self.app = app
    }

    var phase: Phase {
        guard app.isReady else { return .loading }
        guard sessionID != nil else { return app.isScanning ? .scanningNoData : .noScan }
        switch loadState {
        case let .failed(message): return .failed(message)
        case .loaded: return .loaded
        case .idle, .loading: return .loading
        }
    }

    var isSkippedForSession: Bool {
        sessionID != nil && app.duplicatesSkippedSessionID == sessionID
    }

    func activate() {
        sessionID = app.currentSessionID
        observe()
    }

    func deactivate() {
        observeTask?.cancel()
        observeTask = nil
    }

    func sessionChanged(to sessionID: Int64?) {
        guard sessionID != self.sessionID else { return }
        self.sessionID = sessionID
        checkedGroupIDs = []
        focusedIDs = []
        collapsedGroupIDs = []
        groups = []
        loadState = .idle
        observe()
    }

    func retry() {
        loadState = .idle
        observe()
    }

    private func observe() {
        observeTask?.cancel()
        observeTask = nil
        guard let sessionID, let store = app.services?.candidates else {
            groups = []
            return
        }
        if loadState != .loaded {
            loadState = .loading
        }
        let filter = CandidateFilter(categories: [.duplicate], statuses: [])
        observeTask = Task { [weak self] in
            do {
                for try await rows in store.observeCandidates(session: sessionID, filter: filter) {
                    guard !Task.isCancelled else { return }
                    await self?.load(rows, store: store, sessionID: sessionID)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func load(_ rows: [Candidate], store: any CandidateStore, sessionID: Int64) async {
        generation += 1
        let current = generation
        do {
            let groups = try await store.duplicateGroups(session: sessionID)
            let keepers = groups.map(\.keeperURL)
            let probes = await Task.detached(priority: .userInitiated) { keepers.map(KeeperProbe.probe) }.value
            guard current == generation, !Task.isCancelled else { return }
            apply(groups: groups, rows: rows, probes: probes)
        } catch {
            guard current == generation else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func apply(groups: [DuplicateGroup], rows: [Candidate], probes: [KeeperProbe]) {
        let byGroup = rows.reduce(into: [Int64: [Candidate]]()) { result, row in
            if let groupID = row.dupGroupID {
                result[groupID, default: []].append(row)
            }
        }
        self.groups = zip(groups, probes)
            .compactMap { group, probe in
                group.id.flatMap { DuplicateGroupRow.make(group: group, rows: byGroup[$0] ?? [], probe: probe) }
            }
            .sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.groupID < $1.groupID }
        let visibleIDs = Set(self.groups.map(\.groupID))
        checkedGroupIDs.formIntersection(visibleIDs)
        loadState = .loaded
    }

    // MARK: Rows

    var visibleGroups: [DuplicateGroupRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return groups }
        return groups.filter { $0.matches(term) }
    }

    var tableRows: [DuplicateTableRow] {
        visibleGroups.map(DuplicateTableRow.init(group:))
    }

    func group(_ id: Int64) -> DuplicateGroupRow? {
        groups.first { $0.groupID == id }
    }

    func member(for id: DuplicateTableRow.ID) -> DuplicateMember? {
        guard case let .member(groupID, path) = id else { return nil }
        return group(groupID)?.members.first { $0.path == path }
    }

    func isExpanded(_ groupID: Int64) -> Bool {
        !collapsedGroupIDs.contains(groupID)
    }

    func setExpanded(_ groupID: Int64, _ expanded: Bool) {
        if expanded {
            collapsedGroupIDs.remove(groupID)
        } else {
            collapsedGroupIDs.insert(groupID)
        }
    }

    // MARK: Checking

    func isCheckable(_ group: DuplicateGroupRow) -> Bool {
        !group.isSpaceEfficient && !group.candidates.isEmpty
    }

    func checkState(of group: DuplicateGroupRow) -> CheckState {
        checkedGroupIDs.contains(group.groupID) ? .on : .off
    }

    func toggleCheck(_ group: DuplicateGroupRow) {
        if checkedGroupIDs.contains(group.groupID) {
            checkedGroupIDs.remove(group.groupID)
        } else if isCheckable(group) {
            checkedGroupIDs.insert(group.groupID)
        }
    }

    func clearChecks() {
        checkedGroupIDs = []
    }

    var checkedGroups: [DuplicateGroupRow] {
        groups.filter { checkedGroupIDs.contains($0.groupID) && isCheckable($0) }
    }

    var checkedCandidates: [Candidate] {
        checkedGroups.flatMap(\.candidates)
    }

    var checkedBytes: Int64 {
        checkedCandidates.reduce(0) { $0 + $1.freeableSize }
    }

    var blockedGroups: [DuplicateGroupRow] {
        checkedGroups.filter(\.wouldRemoveEveryCopy)
    }

    var primaryTitle: String {
        let checked = checkedCandidates
        return "Quarantine \(Self.duplicates(checked.count)), \(ByteFormat.string(checked.reduce(0) { $0 + $1.freeableSize }))"
    }

    var primaryShortTitle: String {
        "Quarantine \(Self.duplicates(checkedCandidates.count))"
    }

    var quarantineDisabledReason: String? {
        let checked = checkedCandidates
        guard !checked.isEmpty else { return "Select groups to quarantine their extra copies" }
        if !blockedGroups.isEmpty {
            return Self.keepOneCopyReason
        }
        if isChangingKeeper {
            return "Saving the new keeper"
        }
        return app.quarantineBlockReason(for: checked)
    }

    static func duplicates(_ count: Int) -> String {
        count == 1 ? "1 duplicate" : "\(count.formatted()) duplicates"
    }

    func setKeeper(_ member: DuplicateMember) async {
        guard !member.isKeeper, !isChangingKeeper, let store = app.services?.candidates else { return }
        isChangingKeeper = true
        defer { isChangingKeeper = false }
        do {
            _ = try await store.changeKeeper(ofGroup: member.groupID, to: member.url)
        } catch {
            app.alert = AppAlert(title: "Couldn't Change the Keeper", message: error.localizedDescription)
        }
    }
}
