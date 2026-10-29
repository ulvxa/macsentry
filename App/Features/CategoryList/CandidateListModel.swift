import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class CandidateListModel {
    enum Phase: Equatable {
        case loading, noScan, scanningNoData, failed(String), loaded
    }

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    static let filterDebounce: Duration = .milliseconds(80)

    let configuration: CandidateListConfiguration
    let app: AppModel
    private(set) var defaultFilter: FilterState
    var filter: FilterState {
        didSet {
            if filter != oldValue {
                scheduleQuery(debounce: true)
            }
        }
    }

    var sort: CandidateSort = .default {
        didSet {
            if sort != oldValue {
                scheduleQuery(debounce: false)
            }
        }
    }

    private(set) var sessionID: Int64?
    private(set) var candidates: [Candidate] = []
    private(set) var rows: [CandidateRow] = []
    private(set) var blockedBundleIDs: Set<String> = []
    private(set) var queryCount = 0
    private var loadState: LoadState = .idle
    var checkedIDs: Set<Int64> = []
    var focusedIDs: Set<CandidateRow.ID> = []
    var collapsedGroups: Set<String> = []
    var quickLookURL: URL?
    var confirmation: QuarantineConfirmation?
    var failureReport: FailureReport?

    @ObservationIgnored private var seenIDs: Set<Int64> = []
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queriedFilter: CandidateFilter?

    init(configuration: CandidateListConfiguration, app: AppModel) {
        self.configuration = configuration
        self.app = app
        collapsedGroups = configuration.collapsedByDefault
        let defaults = configuration.defaultFilter(thresholds: app.settings.thresholds)
        defaultFilter = defaults
        filter = defaults
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

    func activate() {
        sessionID = app.currentSessionID
        scheduleQuery(debounce: false)
    }

    func deactivate() {
        queryTask?.cancel()
        queryTask = nil
    }

    func sessionChanged(to sessionID: Int64?) {
        guard sessionID != self.sessionID else { return }
        self.sessionID = sessionID
        seenIDs = []
        checkedIDs = []
        focusedIDs = []
        loadState = .idle
        scheduleQuery(debounce: false)
    }

    func thresholdsChanged(to thresholds: Thresholds) {
        if configuration.usesThresholdFilters {
            let updated = FilterState(thresholds: thresholds)
            var next = filter
            next.minAgeDays = updated.minAgeDays
            next.minSizeBytes = updated.minSizeBytes
            defaultFilter.minAgeDays = updated.minAgeDays
            defaultFilter.minSizeBytes = updated.minSizeBytes
            filter = next
        }
        if candidateFilter != queriedFilter {
            scheduleQuery(debounce: true)
        }
    }

    func retry() {
        loadState = .idle
        scheduleQuery(debounce: false)
    }

    // MARK: Query

    var candidateFilter: CandidateFilter {
        filter.candidateFilter(
            categories: configuration.categories,
            actions: configuration.actions,
            controls: configuration.controls,
            ageBasis: app.settings.ageBasis,
        )
    }

    private func scheduleQuery(debounce: Bool) {
        queryTask?.cancel()
        queryTask = nil
        queriedFilter = candidateFilter
        guard let sessionID, let store = app.services?.candidates else {
            receive([])
            return
        }
        if configuration.controls.contains(.tiers), filter.tiers.isEmpty {
            receive([])
            return
        }
        if loadState != .loaded {
            loadState = .loading
        }
        let candidateFilter = candidateFilter
        let sort = sort
        queryTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: Self.filterDebounce)
                guard !Task.isCancelled else { return }
            }
            do {
                let stream = store.observeCandidates(session: sessionID, filter: candidateFilter, sort: sort, limit: nil, offset: 0)
                for try await value in stream {
                    guard !Task.isCancelled else { return }
                    self?.receive(value)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func receive(_ value: [Candidate]) {
        let visible = value.filter { $0.id != nil }
        blockedBundleIDs = app.runningApps(among: Set(visible.compactMap(\.appBundleID)))
        for candidate in visible {
            guard let id = candidate.id, !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)
            if configuration.isCheckable, configuration.defaultCheckedTiers.contains(candidate.tier), isCheckable(candidate) {
                checkedIDs.insert(id)
            }
        }
        candidates = visible
        rows = Self.makeRows(visible, grouped: configuration.groupsByRule, groupName: app.ruleGroup(for:))
        loadState = .loaded
        queryCount += 1
        consumePendingSelection()
    }

    private static func makeRows(_ candidates: [Candidate], grouped: Bool, groupName: (Candidate) -> String) -> [CandidateRow] {
        guard grouped else {
            return candidates.compactMap { CandidateRow(candidate: $0, group: groupName($0)) }
        }
        var order: [String] = []
        var buckets: [String: [CandidateRow]] = [:]
        for candidate in candidates {
            let group = groupName(candidate)
            guard let row = CandidateRow(candidate: candidate, group: group) else { continue }
            if buckets[group] == nil {
                order.append(group)
            }
            buckets[group, default: []].append(row)
        }
        return order.map { CandidateRow(group: $0, children: buckets[$0] ?? []) }
    }

    private func consumePendingSelection() {
        guard let pending = app.pendingRowSelection, pending.item == configuration.item,
              let candidate = candidates.first(where: { $0.id == pending.candidateID }) else { return }
        app.pendingRowSelection = nil
        collapsedGroups.remove(app.ruleGroup(for: candidate))
        focusedIDs = [.item(pending.candidateID)]
    }

    // MARK: Sorting

    var sortOrder: [KeyPathComparator<CandidateRow>] {
        get { [sort.comparator] }
        set {
            if let first = newValue.first, let mapped = CandidateSort(comparator: first) {
                sort = mapped
            }
        }
    }

    // MARK: Checking

    func isBlocked(_ candidate: Candidate) -> Bool {
        candidate.appBundleID.map(blockedBundleIDs.contains) ?? false
    }

    func blockReason(_ candidate: Candidate) -> String? {
        guard isBlocked(candidate) else { return nil }
        let group = app.ruleGroup(for: candidate)
        return "Quit \(group == AppScope.otherGroup ? "the app that owns it" : group) to quarantine this"
    }

    func isCheckable(_ candidate: Candidate) -> Bool {
        candidate.action == .quarantine && !isBlocked(candidate)
    }

    func checkState(of row: CandidateRow) -> CheckState {
        let ids = row.candidates.filter(isCheckable).compactMap(\.id)
        let checked = ids.count { checkedIDs.contains($0) }
        if checked == 0 {
            return .off
        }
        return checked == ids.count ? .on : .mixed
    }

    func canToggle(_ row: CandidateRow) -> Bool {
        if let candidate = row.candidate {
            return isCheckable(candidate)
        }
        return !configuration.groupCheckDisabled.contains(row.name) && row.candidates.contains(where: isCheckable)
    }

    func toggleCheck(_ row: CandidateRow) {
        guard canToggle(row) else { return }
        let ids = row.candidates.filter(isCheckable).compactMap(\.id)
        if checkState(of: row) == .on {
            checkedIDs.subtract(ids)
        } else {
            checkedIDs.formUnion(ids)
        }
    }

    func clearChecks() {
        checkedIDs = []
    }

    var hasDefaultSelectable: Bool {
        candidates.contains { configuration.defaultCheckedTiers.contains($0.tier) && isCheckable($0) }
    }

    func selectDefault() {
        checkedIDs = Set(candidates.filter { configuration.defaultCheckedTiers.contains($0.tier) && isCheckable($0) }.compactMap(\.id))
    }

    var checkedCandidates: [Candidate] {
        candidates.filter { candidate in candidate.id.map(checkedIDs.contains) == true && isCheckable(candidate) }
    }

    var checkedBytes: Int64 {
        checkedCandidates.reduce(0) { $0 + $1.freeableSize }
    }

    var primaryTitle: String {
        let checked = checkedCandidates
        return "Quarantine \(CountFormat.items(checked.count)), \(ByteFormat.string(checked.reduce(0) { $0 + $1.freeableSize }))"
    }

    var primaryShortTitle: String {
        "Quarantine \(CountFormat.items(checkedCandidates.count))"
    }

    var quarantineDisabledReason: String? {
        let checked = checkedCandidates
        guard !checked.isEmpty else {
            return checkedIDs.isEmpty ? "Select items to quarantine" : "Quit the apps that own the checked items first"
        }
        return app.quarantineBlockReason(for: checked)
    }
}
