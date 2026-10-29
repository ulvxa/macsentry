import AppKit
import Foundation
import MacSentryCore
import Observation

struct QuarantineRow: Identifiable {
    // swiftlint:disable:next type_name
    enum ID: Hashable {
        case batch(String)
        case entry(Int64)
    }

    let id: ID
    let batch: QuarantineBatchSummary
    let entry: QuarantineEntry?
    var isFreed = false
    var children: [QuarantineRow] = []

    var isBatch: Bool {
        entry == nil
    }

    var isDryRun: Bool {
        batch.isDryRun
    }

    var name: String {
        entry?.originalURL.lastPathComponent ?? batch.batch.createdAt.formatted(QuarantineRow.batchDateStyle)
    }

    var size: Int64 {
        entry?.size ?? batch.totalSize
    }

    var location: URL? {
        guard let entry else { return nil }
        switch entry.status {
        case .inQuarantine: return isDryRun ? entry.originalURL : entry.quarantineURL
        case .trashed: return isFreed ? nil : entry.trashURL
        case .restored: return entry.originalURL
        case .missing: return nil
        }
    }

    static let batchDateStyle = Date.FormatStyle.dateTime.year().month(.abbreviated).day().hour().minute()
}

struct TrashConfirmation: Identifiable {
    struct Item: Identifiable {
        let id: Int
        let name: String
        let bytes: Int64
    }

    let id = UUID()
    let entries: [QuarantineEntry]
    let title: String
    let totalBytes: Int64
    let preview: [Item]
    let isSimulated: Bool

    init(entries: [QuarantineEntry], isSimulated: Bool) {
        self.entries = entries
        self.isSimulated = isSimulated
        title = entries.count == 1
            ? "Move \(entries[0].originalURL.lastPathComponent) to the Trash?"
            : "Move \(entries.count.formatted()) items to the Trash?"
        totalBytes = entries.reduce(0) { $0 + $1.size }
        preview = entries.prefix(5).enumerated().map {
            Item(id: $0.offset, name: $0.element.originalURL.lastPathComponent, bytes: $0.element.size)
        }
    }

    var remainingCount: Int {
        entries.count - preview.count
    }
}

@Observable
@MainActor
final class QuarantineModel {
    enum Phase: Equatable {
        case loading, failed(String), loaded
    }

    struct Counts: Equatable {
        var items = 0
        var batches = 0
        var dryRunItems = 0
    }

    static let putBackHint = "Restore from Trash using Finder Put Back"
    static let dryRunHint = "Dry run is on, so real batches can't change. Relaunch without dry run to act on them."

    let app: AppModel
    private(set) var batches: [QuarantineBatchSummary] = []
    private(set) var rows: [QuarantineRow] = []
    private(set) var counts = Counts()
    private(set) var isWorking = false
    private var state: Phase = .loading
    var selection: Set<QuarantineRow.ID> = []
    var expanded: Set<String> = []
    var quickLookURL: URL?
    var trashConfirmation: TrashConfirmation?
    var failureReport: FailureReport?

    @ObservationIgnored private var hasLoaded = false

    init(app: AppModel) {
        self.app = app
    }

    var phase: Phase {
        app.isReady ? state : .loading
    }

    func load() async {
        guard app.isReady else { return }
        do {
            try await apply(app.quarantineBatches())
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func apply(_ loaded: [QuarantineBatchSummary]) {
        batches = loaded
        if !hasLoaded {
            hasLoaded = true
            expanded = loaded.first.map { [$0.id] } ?? []
        }
        rows = loaded.map { summary in
            var row = QuarantineRow(id: .batch(summary.id), batch: summary, entry: nil)
            row.children = summary.entries.compactMap { entry in
                guard let id = entry.id else { return nil }
                let freed = entry.status == .trashed
                    && entry.trashURL.map { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
                return QuarantineRow(id: .entry(id), batch: summary, entry: entry, isFreed: freed)
            }
            return row
        }
        var counts = Counts()
        for summary in loaded {
            let waiting = summary.entries.count { $0.status == .inQuarantine }
            if summary.isDryRun {
                counts.dryRunItems += waiting
            } else if waiting > 0 {
                counts.items += waiting
                counts.batches += 1
            }
        }
        self.counts = counts
        let valid = Set(rows.flatMap { [$0.id] + $0.children.map(\.id) })
        selection.formIntersection(valid)
    }

    // MARK: Selection

    func entryRows(for ids: Set<QuarantineRow.ID>) -> [QuarantineRow] {
        rows.flatMap { batch in
            ids.contains(batch.id) ? batch.children : batch.children.filter { ids.contains($0.id) }
        }
    }

    var focusedRows: [QuarantineRow] {
        entryRows(for: selection)
    }

    var focusedBatch: QuarantineRow? {
        guard selection.count == 1, case .batch = selection.first else { return nil }
        return rows.first { selection.contains($0.id) }
    }

    func isActionable(_ row: QuarantineRow) -> Bool {
        guard let entry = row.entry, entry.status == .inQuarantine else { return false }
        return row.isDryRun || !app.environment.isDryRun
    }

    func actionableRows(for ids: Set<QuarantineRow.ID>? = nil) -> [QuarantineRow] {
        entryRows(for: ids ?? selection).filter(isActionable)
    }

    func disabledReason(for ids: Set<QuarantineRow.ID>? = nil) -> String? {
        if isWorking {
            return "Working on the previous request"
        }
        let targets = entryRows(for: ids ?? selection)
        guard !targets.isEmpty else { return "Select items in quarantine" }
        guard !targets.contains(where: isActionable) else { return nil }
        if targets.contains(where: { $0.entry?.status == .trashed }) {
            return Self.putBackHint
        }
        if targets.contains(where: { $0.entry?.status == .inQuarantine }) {
            return Self.dryRunHint
        }
        return "Nothing in the selection is still in quarantine"
    }

    func isSimulatedTrash(for ids: Set<QuarantineRow.ID>? = nil) -> Bool {
        let targets = actionableRows(for: ids)
        return !targets.isEmpty && (app.environment.isDryRun || targets.allSatisfy(\.isDryRun))
    }

    func trashTitle(for ids: Set<QuarantineRow.ID>? = nil) -> String {
        isSimulatedTrash(for: ids) ? "Simulate Move to Trash…" : "Move to Trash…"
    }

    func trashHelp(for ids: Set<QuarantineRow.ID>? = nil) -> String {
        isSimulatedTrash(for: ids)
            ? "Dry run: only marks the entries as trashed. Nothing is moved on disk."
            : "Move to the macOS Trash after you confirm"
    }

    var actionableBytes: Int64 {
        actionableRows().reduce(0) { $0 + $1.size }
    }

    var chipText: String? {
        let actionable = actionableRows()
        if !actionable.isEmpty {
            return "\(actionable.count.formatted()) selected · \(ByteFormat.string(actionableBytes))"
        }
        return focusedRows.isEmpty ? nil : disabledReason()
    }

    // MARK: Trash and restore

    func requestTrash(_ ids: Set<QuarantineRow.ID>? = nil) {
        let targets = actionableRows(for: ids)
        guard !isWorking, !targets.isEmpty else { return }
        trashConfirmation = TrashConfirmation(
            entries: targets.compactMap(\.entry),
            isSimulated: app.environment.isDryRun || targets.allSatisfy(\.isDryRun),
        )
    }

    func confirmTrash(_ confirmation: TrashConfirmation) async {
        trashConfirmation = nil
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        guard let result = await app.trashQuarantined(confirmation.entries, simulated: confirmation.isSimulated) else { return }
        if !result.failed.isEmpty {
            failureReport = FailureReport(doneCount: result.trashed.count, verb: "moved to the Trash", failures: result.failed)
        }
        await load()
    }

    func restore(_ ids: Set<QuarantineRow.ID>? = nil) async {
        let targets = actionableRows(for: ids).compactMap(\.entry)
        guard !isWorking, !targets.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        guard let result = await app.restoreQuarantined(targets) else { return }
        if !result.failed.isEmpty {
            failureReport = FailureReport(doneCount: result.restored.count, verb: "restored", failures: result.failed)
        }
        await load()
    }

    // MARK: Finder and Quick Look

    func locations(for ids: Set<QuarantineRow.ID>? = nil) -> [URL] {
        entryRows(for: ids ?? selection).compactMap(\.location)
    }

    func reveal(_ ids: Set<QuarantineRow.ID>? = nil) {
        FinderActions.reveal(locations(for: ids))
    }

    func openTrash() {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        else { return }
        NSWorkspace.shared.open(trash)
    }

    var previewURLs: [URL] {
        let focused = locations()
        return focused.isEmpty ? rows.flatMap(\.children).compactMap(\.location) : focused
    }

    func quickLook(_ ids: Set<QuarantineRow.ID>? = nil) {
        quickLookURL = locations(for: ids).first
    }

    func toggleQuickLook() {
        if quickLookURL != nil {
            quickLookURL = nil
        } else {
            quickLook()
        }
    }

    var screenActions: ScreenActions {
        ScreenActions(
            canQuarantine: false,
            quarantine: {},
            quickLook: { [weak self] in self?.toggleQuickLook() },
        )
    }

    // MARK: Expansion

    func isExpanded(_ batchID: String) -> Bool {
        expanded.contains(batchID)
    }

    func setExpanded(_ batchID: String, _ isExpanded: Bool) {
        if isExpanded {
            expanded.insert(batchID)
        } else {
            expanded.remove(batchID)
        }
    }
}
