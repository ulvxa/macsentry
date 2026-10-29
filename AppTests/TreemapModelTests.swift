import CoreGraphics
import Foundation
import MacSentryCore
import Testing
@testable import MacSentry

@MainActor
struct TreemapModelTests {
    private static let base = URL(filePath: "/Treemap-Fixture/home")

    private static func node(_ id: Int64, parent: Int64?, _ path: String, size: Int64) -> DirNode {
        let url = base.appending(path: path)
        return DirNode(
            id: id,
            sessionID: 1,
            parentID: parent,
            url: url,
            name: url.lastPathComponent,
            depth: path.split(separator: "/").count,
            allocatedSize: size,
            fileCount: 1,
        )
    }

    private static func candidate(_ path: String, tier: Tier, freeable: Int64) -> Candidate {
        Candidate(
            sessionID: 1,
            url: base.appending(path: path),
            kind: .folder,
            category: .devCache,
            ruleID: "test.rule",
            tier: tier,
            action: .quarantine,
            reason: "test",
            logicalSize: freeable,
            allocatedSize: freeable,
            freeableSize: freeable,
        )
    }

    private static func tree() -> [DirNode] {
        [
            DirNode(id: 1, sessionID: 1, parentID: nil, url: base, name: "home", depth: 0, allocatedSize: 1000, fileCount: 10),
            node(2, parent: 1, "a", size: 600),
            node(3, parent: 1, "b", size: 300),
            node(4, parent: 1, "c", size: 100),
            node(5, parent: 2, "a/inner", size: 400),
            node(6, parent: 5, "a/inner/deep", size: 200),
        ]
    }

    private static func model(
        nodes: [DirNode] = tree(),
        candidates: [Candidate] = [],
        session: Int64? = 1,
    ) -> TreemapModel {
        TreemapModel(store: InMemoryCandidateStore(candidates: candidates, dirNodes: nodes), session: session)
    }

    @Test func `no session shows the no scan state`() async {
        let model = Self.model(session: nil)
        await model.loadIfNeeded()
        #expect(model.phase == .noScan)
        #expect(model.items.isEmpty)
        #expect(model.crumbs.isEmpty)
    }

    @Test func `no nodes shows the empty state`() async {
        let model = Self.model(nodes: [])
        await model.load()
        #expect(model.phase == .empty)
    }

    @Test func `single root opens at its children sorted by size`() async {
        let model = Self.model()
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.items.map(\.name) == ["a", "b", "c"])
        #expect(model.crumbs.map(\.name) == ["home"])
        #expect(model.items.map(\.sizeRank) == model.items.map(\.sizeRank).sorted(by: >))
    }

    @Test func `multiple roots start at the scanned folders level`() async {
        let nodes = [
            DirNode(
                id: 1,
                sessionID: 1,
                parentID: nil,
                url: URL(filePath: "/Treemap-Fixture/one"),
                name: "one",
                depth: 0,
                allocatedSize: 20,
                fileCount: 1,
            ),
            DirNode(
                id: 2,
                sessionID: 1,
                parentID: nil,
                url: URL(filePath: "/Treemap-Fixture/two"),
                name: "two",
                depth: 0,
                allocatedSize: 10,
                fileCount: 1,
            ),
        ]
        let model = Self.model(nodes: nodes)
        await model.load()
        #expect(model.items.map(\.name) == ["one", "two"])
        #expect(model.crumbs == [.root])
    }

    @Test func `drill down builds the breadcrumb and back restores the level`() async throws {
        let model = Self.model()
        await model.load()
        let rootCrumb = try #require(model.crumbs.first)

        try await model.drill(into: #require(model.items.first))
        #expect(model.items.map(\.name) == ["inner"])
        #expect(model.crumbs.map(\.name) == ["home", "a"])

        try await model.drill(into: #require(model.items.first))
        #expect(model.items.map(\.name) == ["deep"])
        #expect(model.crumbs.map(\.name) == ["home", "a", "inner"])

        await model.goUp()
        #expect(model.crumbs.map(\.name) == ["home", "a"])
        #expect(model.items.map(\.name) == ["inner"])

        await model.navigate(to: rootCrumb)
        #expect(model.crumbs.map(\.name) == ["home"])
        #expect(model.items.map(\.name) == ["a", "b", "c"])
        #expect(!model.canGoUp)
    }

    @Test func `drilling into a folder without children keeps the current level`() async throws {
        let model = Self.model()
        await model.load()
        let key = model.levelKey
        try await model.drill(into: #require(model.items.last))
        #expect(model.items.map(\.name) == ["a", "b", "c"])
        #expect(model.levelKey == key)
    }

    @Test func `candidate counts and most severe tier come from candidates below each tile`() async {
        let candidates = [
            Self.candidate("a/inner", tier: .green, freeable: 50),
            Self.candidate("a/inner/deep", tier: .red, freeable: 10),
            Self.candidate("b", tier: .yellow, freeable: 5),
            Self.candidate("b/x", tier: .green, freeable: 90),
        ]
        let model = Self.model(candidates: candidates)
        await model.load()
        let byName = Dictionary(uniqueKeysWithValues: model.items.map { ($0.name, $0) })
        #expect(byName["a"]?.candidateCount == 2)
        #expect(byName["a"]?.tier == .red)
        #expect(byName["a"]?.candidateURL == Self.base.appending(path: "a/inner"))
        #expect(byName["b"]?.candidateCount == 2)
        #expect(byName["b"]?.candidateURL == Self.base.appending(path: "b"))
        #expect(byName["c"]?.candidateCount == 0)
        #expect(byName["c"]?.tier == nil)
        #expect(byName["c"]?.candidateURL == nil)
    }

    @Test func `sibling with a shared name prefix is not counted`() async {
        let nodes = [
            DirNode(
                id: 1,
                sessionID: 1,
                parentID: nil,
                url: URL(filePath: "/Treemap-Fixture"),
                name: "root",
                depth: 0,
                allocatedSize: 100,
                fileCount: 1,
            ),
            DirNode(
                id: 2,
                sessionID: 1,
                parentID: 1,
                url: URL(filePath: "/Treemap-Fixture/app"),
                name: "app",
                depth: 1,
                allocatedSize: 60,
                fileCount: 1,
            ),
            DirNode(
                id: 3,
                sessionID: 1,
                parentID: 1,
                url: URL(filePath: "/Treemap-Fixture/app2"),
                name: "app2",
                depth: 1,
                allocatedSize: 40,
                fileCount: 1,
            ),
        ]
        let candidate = Candidate(
            sessionID: 1, url: URL(filePath: "/Treemap-Fixture/app2/cache"), kind: .folder, category: .appCache, ruleID: "r",
            tier: .green, action: .quarantine, reason: "t", logicalSize: 1, allocatedSize: 1, freeableSize: 1,
        )
        let model = Self.model(nodes: nodes, candidates: [candidate])
        await model.load()
        #expect(model.items.first { $0.name == "app" }?.candidateCount == 0)
        #expect(model.items.first { $0.name == "app2" }?.candidateCount == 1)
    }

    @Test func `option click reports the candidate path and plain click drills`() async throws {
        let model = Self.model(candidates: [Self.candidate("a/inner", tier: .green, freeable: 50)])
        var selected: [URL] = []
        model.onSelectCandidatePath = { selected.append($0) }
        await model.load()
        let tiles = model.placedTiles(in: CGSize(width: 400, height: 300))
        let tileA = try #require(tiles.first { $0.item.name == "a" })
        let tileC = try #require(tiles.first { $0.item.name == "c" })

        await model.activate(tileC, selectingCandidate: true)
        #expect(selected.isEmpty)
        await model.activate(tileA, selectingCandidate: true)
        #expect(selected == [Self.base.appending(path: "a/inner")])
        #expect(model.crumbs.map(\.name) == ["home"])

        await model.activate(tileA, selectingCandidate: false)
        #expect(model.crumbs.map(\.name) == ["home", "a"])
    }

    @Test func `hover tracks the tile under the pointer`() async throws {
        let model = Self.model()
        await model.load()
        let tiles = model.placedTiles(in: CGSize(width: 400, height: 300))
        let target = try #require(tiles.first)
        model.updateHover(at: CGPoint(x: target.rect.midX, y: target.rect.midY), in: tiles)
        #expect(model.hoveredTile?.id == target.id)
        model.updateHover(at: nil, in: tiles)
        #expect(model.hoveredTile == nil)
    }

    @Test func `levels beyond the cap collapse into one Other tile`() async throws {
        var nodes = [DirNode(id: 1, sessionID: 1, parentID: nil, url: Self.base, name: "home", depth: 0, allocatedSize: 1, fileCount: 1)]
        for index in 0 ..< 350 {
            nodes.append(Self.node(Int64(index + 2), parent: 1, "dir\(index)", size: Int64(index + 1) * 1000))
        }
        let model = Self.model(nodes: nodes)
        await model.load()
        #expect(model.items.count == 350)
        let tiles = model.placedTiles(in: CGSize(width: 1000, height: 600))
        #expect(tiles.count == SquarifiedLayout.maxTiles)
        let other = try #require(tiles.first { $0.item.isOther })
        #expect(other.item.mergedCount == 350 - 299)
        #expect(!other.item.isDrillable)
        await model.activate(other, selectingCandidate: false)
        #expect(model.crumbs.map(\.name) == ["home"])
    }

    @Test func `breadcrumb collapses the middle when deeper than five`() async throws {
        var nodes = [DirNode(id: 1, sessionID: 1, parentID: nil, url: Self.base, name: "home", depth: 0, allocatedSize: 100, fileCount: 1)]
        var path = ""
        for level in 1 ... 6 {
            path += "d\(level)/"
            nodes.append(Self.node(Int64(level + 1), parent: Int64(level), String(path.dropLast()), size: Int64(100 - level)))
        }
        let model = Self.model(nodes: nodes)
        await model.load()
        for _ in 0 ..< 5 {
            try await model.drill(into: #require(model.items.first))
        }
        #expect(model.crumbs.map(\.name) == ["home", "d1", "d2", "d3", "d4", "d5"])
        let segments = model.breadcrumbSegments
        #expect(segments.count == 5)
        #expect(segments.first == .crumb(model.crumbs[0]))
        #expect(segments[1] == .overflow(Array(model.crumbs[1 ... 2])))
        #expect(segments.suffix(3) == model.crumbs.suffix(3).map { .crumb($0) })
    }

    @Test func `switching session reloads`() async {
        let model = Self.model()
        await model.load()
        await model.setSession(nil)
        #expect(model.phase == .noScan)
        await model.setSession(1)
        #expect(model.phase == .loaded)
    }
}
