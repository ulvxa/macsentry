import Foundation
import MacSentryCore
import Observation

@Observable
@MainActor
final class ProjectsModel {
    enum Phase: Equatable {
        case loading, noScan, scanningNoData, failed(String), loaded
    }

    private enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    static let controls: [FilterControl] = [.age(label: "Idle for at least")]

    let app: AppModel
    private(set) var defaultFilter: FilterState
    var filter: FilterState {
        didSet {
            if filter != oldValue {
                rebuild()
            }
        }
    }

    var sortOrder: [KeyPathComparator<ProjectTableRow>] = [KeyPathComparator(\.freeable, order: .reverse)] {
        didSet { rebuild() }
    }

    private(set) var sessionID: Int64?
    private(set) var entries: [ProjectEntry] = []
    private(set) var rows: [ProjectTableRow] = []
    private(set) var blockReasons: [Int64: String] = [:]
    private(set) var queryCount = 0
    private var loadState: LoadState = .idle
    private var projects: [Project] = [] {
        didSet {
            projectsByID = Dictionary(projects.compactMap { project in project.id.map { ($0, project) } }) { first, _ in first }
        }
    }

    private var gitProjectIDs: Set<Int64> = []
    private var artifacts: [Candidate] = []
    var checkedIDs: Set<Int64> = []
    var focusedIDs: Set<ProjectTableRow.ID> = []
    var expandedIDs: Set<ProjectTableRow.ID> = []
    var confirmation: QuarantineConfirmation?
    var failureReport: FailureReport?

    @ObservationIgnored private var seenIDs: Set<Int64> = []
    @ObservationIgnored private var projectsByID: [Int64: Project] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let probe: any ProjectFileProbe

    init(app: AppModel, now: @escaping @MainActor () -> Date = { Date() }, probe: any ProjectFileProbe = FileManagerProjectProbe()) {
        self.app = app
        self.now = now
        self.probe = probe
        let defaults = FilterState(minAgeDays: app.settings.projectIdleDays, minSizeBytes: 0)
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
        load()
    }

    func deactivate() {
        loadTask?.cancel()
        loadTask = nil
    }

    func sessionChanged(to sessionID: Int64?) {
        guard sessionID != self.sessionID else { return }
        self.sessionID = sessionID
        seenIDs = []
        checkedIDs = []
        focusedIDs = []
        expandedIDs = []
        loadState = .idle
        load()
    }

    func idleDaysChanged(to days: Int) {
        let updated = FilterState(minAgeDays: days, minSizeBytes: 0).minAgeDays
        defaultFilter.minAgeDays = updated
        filter.minAgeDays = updated
    }

    func retry() {
        loadState = .idle
        load()
    }

    var isOverridingIdleDays: Bool {
        filter.minAgeDays != defaultFilter.minAgeDays
    }

    // MARK: Loading

    private func load() {
        loadTask?.cancel()
        loadTask = nil
        guard let sessionID, let store = app.services?.candidates else {
            projects = []
            artifacts = []
            rebuild()
            return
        }
        if loadState != .loaded {
            loadState = .loading
        }
        let probe = probe
        loadTask = Task { [weak self] in
            do {
                let loaded = try await store.projects(session: sessionID)
                guard !Task.isCancelled else { return }
                self?.projects = loaded
                self?.gitProjectIDs = Set(loaded.compactMap { project in
                    project.id.flatMap { probe.itemExists(at: project.rootURL.appending(path: ".git")) ? $0 : nil }
                })
                let stream = store.observeCandidates(
                    session: sessionID,
                    filter: CandidateFilter(categories: [.projectArtifact]),
                    sort: .default,
                    limit: nil,
                    offset: 0,
                )
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
        artifacts = value.filter { $0.action == .quarantine && $0.id != nil && $0.projectID != nil }
        loadState = .loaded
        queryCount += 1
        rebuild()
    }

    func rebuild() {
        let reference = now()
        let grouped = Dictionary(grouping: artifacts) { $0.projectID ?? 0 }
        let term = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let running = app.runningApps(among: Set(GraveyardPolicy.ideBundleIDs))
        var visible: [ProjectEntry] = []
        var blocked: [Int64: String] = [:]
        for project in projects {
            guard let id = project.id, let group = grouped[id], GraveyardPolicy.isIdle(project, idleDays: filter.minAgeDays, now: reference)
            else { continue }
            let entry = ProjectEntry(
                project: project,
                artifacts: group.sorted { ($0.freeableSize, $1.name) > ($1.freeableSize, $0.name) },
                hasGit: gitProjectIDs.contains(id),
            )
            if !term.isEmpty, !Self.matches(entry, term: term) {
                continue
            }
            visible.append(entry)
            if let inventory = app.services?.inventory,
               GraveyardPolicy.isBlockedByIDE(project: project, inventory: inventory, now: reference) {
                blocked[id] = Self.blockReason(running: running)
            }
        }
        blockReasons = blocked
        entries = visible
        for entry in visible {
            for artifact in entry.artifacts {
                guard let id = artifact.id, seenIDs.insert(id).inserted else { continue }
                if isDefaultChecked(artifact) {
                    checkedIDs.insert(id)
                }
            }
        }
        rows = visible.map(ProjectTableRow.init(entry:)).sorted(using: sortOrder + [KeyPathComparator(\.path)])
    }

    private static func matches(_ entry: ProjectEntry, term: String) -> Bool {
        let haystacks = [entry.project.name, entry.project.rootURL.path(percentEncoded: false)] + entry.artifacts.map(\.name)
        return haystacks.contains { $0.range(of: term, options: .caseInsensitive) != nil }
    }

    private static func blockReason(running: Set<String>) -> String {
        let names = GraveyardPolicy.ideBundleIDs.filter(running.contains).map(ideName)
        let who = names.isEmpty ? "An IDE" : names.joined(separator: " and ")
        return "\(who) \(names.count > 1 ? "are" : "is") running and this project changed in the last 24 hours"
    }

    private static func ideName(_ bundleID: String) -> String {
        switch bundleID {
        case "com.apple.dt.Xcode": "Xcode"
        case "com.microsoft.VSCode": "VS Code"
        case "com.google.android.studio": "Android Studio"
        case "com.unity3d.UnityEditor5.x": "Unity"
        default: bundleID
        }
    }
}

extension ProjectsModel {
    // MARK: Checking

    func blockReason(_ artifact: Candidate) -> String? {
        artifact.projectID.flatMap { blockReasons[$0] }
    }

    func isBlocked(_ artifact: Candidate) -> Bool {
        blockReason(artifact) != nil
    }

    func isDefaultChecked(_ artifact: Candidate) -> Bool {
        guard artifact.tier == .green, !isBlocked(artifact), let project = project(for: artifact) else { return false }
        return !project.hasUncommitted
    }

    private func project(for artifact: Candidate) -> Project? {
        artifact.projectID.flatMap { projectsByID[$0] }
    }

    private func selectable(_ row: ProjectTableRow) -> [Candidate] {
        row.artifacts.filter { !isBlocked($0) && $0.id != nil }
    }

    func isEnabled(_ row: ProjectTableRow) -> Bool {
        !selectable(row).isEmpty
    }

    private func checkTargets(_ candidates: [Candidate]) -> [Candidate] {
        let safe = candidates.filter { $0.tier == .green }
        return safe.isEmpty ? candidates : safe
    }

    func checkState(of row: ProjectTableRow) -> CheckState {
        let candidates = selectable(row)
        guard candidates.contains(where: { $0.id.map(checkedIDs.contains) == true }) else { return .off }
        if row.artifact != nil {
            return .on
        }
        return checkTargets(candidates).allSatisfy { $0.id.map(checkedIDs.contains) == true } ? .on : .mixed
    }

    func toggleCheck(_ row: ProjectTableRow) {
        let candidates = selectable(row)
        if checkState(of: row) == .on {
            checkedIDs.subtract(candidates.compactMap(\.id))
        } else {
            checkedIDs.formUnion((row.artifact != nil ? candidates : checkTargets(candidates)).compactMap(\.id))
        }
    }

    func clearChecks() {
        checkedIDs = []
    }

    var hasDefaultSelectable: Bool {
        entries.contains { $0.artifacts.contains(where: isDefaultChecked) }
    }

    func selectDefault() {
        checkedIDs = Set(entries.flatMap(\.artifacts).filter(isDefaultChecked).compactMap(\.id))
    }

    var checkedCandidates: [Candidate] {
        entries.flatMap(\.artifacts).filter { artifact in artifact.id.map(checkedIDs.contains) == true && !isBlocked(artifact) }
    }

    var checkedBytes: Int64 {
        checkedCandidates.reduce(0) { $0 + $1.freeableSize }
    }

    var checkedProjectCount: Int {
        Set(checkedCandidates.compactMap(\.projectID)).count
    }

    static func projectCount(_ count: Int) -> String {
        count == 1 ? "1 project" : "\(count.formatted()) projects"
    }

    var chipText: String? {
        let count = checkedProjectCount
        return count > 0 ? Self.projectCount(count) : nil
    }

    var primaryTitle: String {
        "Quarantine artifacts of \(Self.projectCount(checkedProjectCount)), \(ByteFormat.string(checkedBytes))"
    }

    var primaryShortTitle: String {
        "Quarantine \(Self.projectCount(checkedProjectCount))"
    }

    var quarantineDisabledReason: String? {
        let checked = checkedCandidates
        guard !checked.isEmpty else {
            return checkedIDs.isEmpty ? "Select artifacts to quarantine" : "Quit the IDE that has these projects open first"
        }
        return app.quarantineBlockReason(for: checked)
    }

    // MARK: Focus

    var focusedEntries: [ProjectEntry] {
        rows.map(\.entry).filter { entry in
            focusedIDs.contains(.project(entry.id))
                || entry.artifacts.contains { artifact in artifact.id.map { focusedIDs.contains(.artifact($0)) } == true }
        }
    }

    func isExpanded(_ id: ProjectTableRow.ID) -> Bool {
        expandedIDs.contains(id)
    }

    func setExpanded(_ id: ProjectTableRow.ID, _ expanded: Bool) {
        if expanded {
            expandedIDs.insert(id)
        } else {
            expandedIDs.remove(id)
        }
    }

    func targets(for ids: Set<ProjectTableRow.ID>) -> [Candidate] {
        entries.flatMap { entry in
            if ids.contains(.project(entry.id)) {
                return entry.artifacts
            }
            return entry.artifacts.filter { artifact in artifact.id.map { ids.contains(.artifact($0)) } == true }
        }
    }

    func urls(for ids: Set<ProjectTableRow.ID>) -> [URL] {
        entries.flatMap { entry -> [URL] in
            var urls: [URL] = []
            if ids.contains(.project(entry.id)) {
                urls.append(entry.project.rootURL)
            }
            urls += entry.artifacts.filter { artifact in artifact.id.map { ids.contains(.artifact($0)) } == true }.map(\.url)
            return urls
        }
    }
}
