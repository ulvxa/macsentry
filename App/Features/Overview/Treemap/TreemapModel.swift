import CoreGraphics
import Foundation
import MacSentryCore
import Observation

struct TreemapItem: Identifiable, Equatable, Sendable {
    let id: String
    let nodeID: Int64?
    let name: String
    let size: Int64
    let sizeText: String
    var sizeRank: Double
    var candidateCount: Int
    var tier: Tier?
    /// Candidate to jump to on Option-click: the folder's own candidate if it has one, else the largest below it.
    var candidateURL: URL?
    var mergedCount: Int

    var isOther: Bool {
        nodeID == nil
    }

    var isDrillable: Bool {
        nodeID != nil
    }

    var candidateText: String {
        switch candidateCount {
        case 0: "No candidates"
        case 1: "1 candidate"
        default: "\(candidateCount) candidates"
        }
    }

    var accessibilityText: String {
        "\(name), \(sizeText), \(candidateText)"
    }
}

struct TreemapPlacedTile: Identifiable, Equatable, Sendable {
    let item: TreemapItem
    let rect: CGRect

    var id: String {
        item.id
    }
}

struct IndexedCandidate: Sendable {
    let path: String
    let url: URL
    let tier: Tier

    init(_ candidate: Candidate) {
        url = candidate.url
        path = treemapStoragePath(candidate.url)
        tier = candidate.tier
    }

    init(url: URL, tier: Tier) {
        self.url = url
        path = treemapStoragePath(url)
        self.tier = tier
    }
}

func treemapStoragePath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path(percentEncoded: false)
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
}

extension Tier {
    var treemapSeverity: Int {
        switch self {
        case .green: 0
        case .yellow: 1
        case .red: 2
        }
    }

    var treemapSymbol: String {
        switch self {
        case .green: "checkmark.circle"
        case .yellow: "arrow.triangle.2.circlepath.circle"
        case .red: "exclamationmark.octagon"
        }
    }

    var treemapWord: String {
        switch self {
        case .green: "Safe"
        case .yellow: "Rebuildable"
        case .red: "Careful"
        }
    }
}

@Observable
@MainActor
final class TreemapModel {
    enum Phase: Equatable {
        case noScan
        case loading
        case loaded
        case empty
        case failed(String)
    }

    struct Crumb: Identifiable, Equatable, Sendable {
        static let root = Crumb(nodeID: nil, name: "Scanned folders")

        let nodeID: Int64?
        let name: String

        var id: String {
            nodeID.map { "node-\($0)" } ?? "root"
        }
    }

    enum BreadcrumbSegment: Identifiable, Equatable {
        case crumb(Crumb)
        case overflow([Crumb])

        var id: String {
            switch self {
            case let .crumb(crumb): crumb.id
            case let .overflow(crumbs): "overflow-" + crumbs.map(\.id).joined(separator: ",")
            }
        }
    }

    private(set) var phase: Phase
    private(set) var items: [TreemapItem] = []
    private(set) var crumbs: [Crumb] = []
    private(set) var levelKey = 0
    private(set) var hoveredTile: TreemapPlacedTile?
    private(set) var hoverPoint: CGPoint = .zero

    var onSelectCandidatePath: (@MainActor (URL) -> Void)?

    @ObservationIgnored private let store: any CandidateStore
    @ObservationIgnored private var session: Int64?
    @ObservationIgnored private var candidates: [IndexedCandidate] = []
    @ObservationIgnored private var hasMultipleRoots = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var didLoad = false

    init(store: any CandidateStore, session: Int64?, onSelectCandidatePath: (@MainActor (URL) -> Void)? = nil) {
        self.store = store
        self.session = session
        self.onSelectCandidatePath = onSelectCandidatePath
        phase = session == nil ? .noScan : .loading
    }

    var breadcrumbSegments: [BreadcrumbSegment] {
        guard crumbs.count > 5 else { return crumbs.map(BreadcrumbSegment.crumb) }
        return [.crumb(crumbs[0]), .overflow(Array(crumbs[1 ..< crumbs.count - 3]))]
            + crumbs.suffix(3).map(BreadcrumbSegment.crumb)
    }

    var canGoUp: Bool {
        crumbs.count > 1
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        await load()
    }

    func setSession(_ newSession: Int64?) async {
        session = newSession
        await load()
    }

    func load() async {
        didLoad = true
        generation += 1
        let current = generation
        hoveredTile = nil
        guard let session else {
            reset(to: .noScan)
            return
        }
        if items.isEmpty {
            phase = .loading
        }
        do {
            let roots = try await store.rootDirNodes(session: session)
            let found = try await store.candidates(session: session, filter: CandidateFilter(), sort: .default, limit: nil, offset: 0)
            guard current == generation else { return }
            candidates = found.map(IndexedCandidate.init)
            hasMultipleRoots = roots.count != 1
            guard !roots.isEmpty else {
                reset(to: .empty)
                return
            }
            let startNode = roots.count == 1 ? roots[0].id : nil
            _ = try await show(nodeID: startNode, requireChildren: false, generation: current)
        } catch {
            guard current == generation else { return }
            reset(to: .failed(error.localizedDescription))
        }
    }

    func drill(into item: TreemapItem) async {
        guard let nodeID = item.nodeID else { return }
        await navigate(toNode: nodeID, requireChildren: true)
    }

    func navigate(to crumb: Crumb) async {
        guard crumb != crumbs.last else { return }
        await navigate(toNode: crumb.nodeID, requireChildren: false)
    }

    func goUp() async {
        guard crumbs.count > 1 else { return }
        await navigate(to: crumbs[crumbs.count - 2])
    }

    func activate(_ tile: TreemapPlacedTile, selectingCandidate: Bool) async {
        if selectingCandidate {
            if let url = tile.item.candidateURL {
                onSelectCandidatePath?(url)
            }
        } else {
            await drill(into: tile.item)
        }
    }

    func placedTiles(in size: CGSize) -> [TreemapPlacedTile] {
        let bounds = CGRect(origin: .zero, size: size)
        let tiles = SquarifiedLayout.layout(weights: items.map { Double($0.size) }, in: bounds)
        return tiles.compactMap { tile in
            if let index = tile.index {
                return TreemapPlacedTile(item: items[index], rect: tile.rect)
            }
            return TreemapPlacedTile(item: mergedItem(for: tile.mergedIndices), rect: tile.rect)
        }
    }

    func updateHover(at point: CGPoint?, in tiles: [TreemapPlacedTile]) {
        guard let point else {
            hoveredTile = nil
            return
        }
        hoverPoint = point
        let hit = tiles.first { $0.rect.contains(point) }
        if hit != hoveredTile {
            hoveredTile = hit
        }
    }

    private func navigate(toNode nodeID: Int64?, requireChildren: Bool) async {
        generation += 1
        let current = generation
        hoveredTile = nil
        do {
            _ = try await show(nodeID: nodeID, requireChildren: requireChildren, generation: current)
        } catch {
            guard current == generation else { return }
            reset(to: .failed(error.localizedDescription))
        }
    }

    private func show(nodeID: Int64?, requireChildren: Bool, generation current: Int) async throws -> Bool {
        guard let session else { return false }
        let nodes: [DirNode]
        var trail: [Crumb]
        if let nodeID {
            nodes = try await store.children(of: nodeID, session: session)
            let ancestors = try await store.ancestors(of: nodeID)
            let node = try await store.dirNode(id: nodeID)
            trail = (hasMultipleRoots ? [Crumb.root] : []) + (ancestors + [node].compactMap(\.self)).map {
                Crumb(nodeID: $0.id, name: $0.name)
            }
        } else {
            nodes = try await store.rootDirNodes(session: session)
            trail = [Crumb.root]
        }
        if requireChildren, nodes.isEmpty {
            return false
        }
        let snapshot = candidates
        let built = await Self.buildItems(nodes: nodes, candidates: snapshot)
        guard current == generation else { return false }
        items = built
        crumbs = trail
        levelKey += 1
        phase = built.isEmpty ? .empty : .loaded
        return true
    }

    private func reset(to newPhase: Phase) {
        items = []
        crumbs = []
        levelKey += 1
        phase = newPhase
    }

    private func mergedItem(for indices: [Int]) -> TreemapItem {
        let merged = indices.map { items[$0] }
        let size = merged.reduce(Int64(0)) { $0 + $1.size }
        return TreemapItem(
            id: "other",
            nodeID: nil,
            name: "Other",
            size: size,
            sizeText: ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
            sizeRank: 0,
            candidateCount: merged.reduce(0) { $0 + $1.candidateCount },
            tier: merged.compactMap(\.tier).max { $0.treemapSeverity < $1.treemapSeverity },
            candidateURL: nil,
            mergedCount: merged.count,
        )
    }

    nonisolated static func buildItems(nodes: [DirNode], candidates: [IndexedCandidate]) async -> [TreemapItem] {
        let sorted = nodes.filter { $0.id != nil }.sorted {
            $0.allocatedSize != $1.allocatedSize ? $0.allocatedSize > $1.allocatedSize : $0.name < $1.name
        }
        var tilePaths: [String: Int] = [:]
        for (index, node) in sorted.enumerated() {
            tilePaths[treemapStoragePath(node.url)] = index
        }

        var counts = [Int](repeating: 0, count: sorted.count)
        var tiers = [Tier?](repeating: nil, count: sorted.count)
        var firstURLs = [URL?](repeating: nil, count: sorted.count)
        var exactURLs = [URL?](repeating: nil, count: sorted.count)
        if !tilePaths.isEmpty {
            for candidate in candidates {
                guard let index = owningTile(of: candidate.path, in: tilePaths) else { continue }
                counts[index] += 1
                if tiers[index].map({ $0.treemapSeverity < candidate.tier.treemapSeverity }) ?? true {
                    tiers[index] = candidate.tier
                }
                if firstURLs[index] == nil {
                    firstURLs[index] = candidate.url
                }
                if exactURLs[index] == nil, candidate.path == treemapStoragePath(sorted[index].url) {
                    exactURLs[index] = candidate.url
                }
            }
        }

        let positives = sorted.map(\.allocatedSize).filter { $0 > 0 }
        let low = positives.min().map { log(Double($0)) } ?? 0
        let high = positives.max().map { log(Double($0)) } ?? 0
        return sorted.enumerated().compactMap { index, node in
            guard let nodeID = node.id else { return nil }
            let rank = high > low && node.allocatedSize > 0 ? (log(Double(node.allocatedSize)) - low) / (high - low) : 0.5
            return TreemapItem(
                id: "node-\(nodeID)",
                nodeID: nodeID,
                name: node.name,
                size: node.allocatedSize,
                sizeText: ByteCountFormatter.string(fromByteCount: node.allocatedSize, countStyle: .file),
                sizeRank: rank,
                candidateCount: counts[index],
                tier: tiers[index],
                candidateURL: exactURLs[index] ?? firstURLs[index],
                mergedCount: 0,
            )
        }
    }

    nonisolated static func owningTile(of path: String, in tilePaths: [String: Int]) -> Int? {
        var key = Substring(path)
        while true {
            if let index = tilePaths[String(key)] {
                return index
            }
            guard let slash = key.lastIndex(of: "/"), slash != key.startIndex else { return nil }
            key = key[..<slash]
        }
    }
}
