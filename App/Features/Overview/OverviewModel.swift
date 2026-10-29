import Foundation
import MacSentryCore
import Observation

struct OverviewOffender: Identifiable, Equatable {
    let id: Int64
    let name: String
    let freeable: Int64
}

struct OverviewCard: Identifiable, Equatable {
    let item: SidebarItem
    let total: CategoryTotal
    let offenders: [OverviewOffender]

    var id: SidebarItem {
        item
    }

    var isEmpty: Bool {
        total.count < 1
    }

    var accessibilityText: String {
        var text = "\(item.title), \(ByteFormat.string(total.freeable)) freeable, \(CountFormat.items(total.count))"
        if let top = offenders.first {
            text += ". Largest: \(top.name) \(ByteFormat.string(top.freeable))"
        }
        return text
    }
}

@Observable
@MainActor
final class OverviewModel {
    enum Phase: Equatable {
        case loading, noScan, scanningNoData, nothingFound, loaded
    }

    static let cardItems: [SidebarItem] = [.devCaches, .appCaches, .oldLarge, .projects, .orphans, .duplicates, .flagged]
    static let offenderLimit = 3

    let app: AppModel
    private(set) var capacity: VolumeCapacity?
    private(set) var offenders: [SidebarItem: [OverviewOffender]] = [:]
    private(set) var treemap: TreemapModel?

    @ObservationIgnored private var offendersTask: Task<Void, Never>?
    @ObservationIgnored private var loadedSession: Int64?

    init(app: AppModel) {
        self.app = app
    }

    var phase: Phase {
        guard app.isReady else { return .loading }
        guard app.currentSessionID != nil else { return app.isScanning ? .scanningNoData : .noScan }
        guard app.totalsLoaded else { return .loading }
        return cards.allSatisfy(\.isEmpty) ? .nothingFound : .loaded
    }

    var breakdown: DiskUsageBreakdown? {
        capacity.map { DiskUsageBreakdown(capacity: $0, reclaimable: app.reclaimableBytes, quarantine: app.quarantineTotals) }
    }

    var cards: [OverviewCard] {
        Self.cardItems.map { item in
            OverviewCard(item: item, total: app.total(for: item) ?? .zero, offenders: offenders[item] ?? [])
        }
    }

    var lastScanDate: Date? {
        app.latestFinishedSession.map { $0.finishedAt ?? $0.startedAt }
    }

    var scanCaption: String {
        if let activity = app.scanActivity {
            return activity.phase.label
        }
        if app.scanState.isFailure {
            return "Last scan failed"
        }
        return lastScanDate == nil ? "Never scanned" : "Last scan"
    }

    var lastScanCaptionDate: Date? {
        app.isScanning || app.scanState.isFailure ? nil : lastScanDate
    }

    func activate() async {
        ensureTreemap()
        await refreshCapacity()
        await sessionChanged()
    }

    func sessionChanged() async {
        let session = app.currentSessionID
        ensureTreemap()
        if session != loadedSession {
            loadedSession = session
            offenders = [:]
            await treemap?.setSession(session)
        }
        reloadOffenders()
    }

    func refreshCapacity() async {
        capacity = await app.sampleVolume()
    }

    func reloadOffenders() {
        offendersTask?.cancel()
        guard let session = app.currentSessionID, let store = app.services?.candidates else {
            offenders = [:]
            return
        }
        offendersTask = Task { [weak self] in
            var loaded: [SidebarItem: [OverviewOffender]] = [:]
            for item in Self.cardItems {
                var found: [Candidate] = []
                for category in item.categories {
                    found += await (try? store.topOffenders(session: session, category: category, limit: Self.offenderLimit)) ?? []
                }
                loaded[item] = found
                    .sorted { $0.freeableSize > $1.freeableSize }
                    .prefix(Self.offenderLimit)
                    .compactMap { candidate in
                        candidate.id.map { OverviewOffender(id: $0, name: candidate.name, freeable: candidate.freeableSize) }
                    }
            }
            guard !Task.isCancelled, let self, app.currentSessionID == session else { return }
            offenders = loaded
        }
    }

    func waitForOffenders() async {
        await offendersTask?.value
    }

    private func ensureTreemap() {
        guard treemap == nil, let store = app.services?.candidates else { return }
        let app = app
        treemap = TreemapModel(store: store, session: nil) { url in
            Task { await app.revealCandidate(at: url) }
        }
    }
}

extension ScanState {
    var isFailure: Bool {
        if case .failed = self {
            true
        } else {
            false
        }
    }
}
