import CoreGraphics
import Testing
@testable import MacSentry

struct TreemapSquarifiedLayoutTests {
    private let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)

    private func assertValid(_ tiles: [SquarifiedLayout.Tile], weights _: [Double], in bounds: CGRect) {
        let epsilon: CGFloat = 1e-6
        let total = tiles.reduce(0) { $0 + $1.weight }
        for tile in tiles {
            #expect(tile.rect.minX >= bounds.minX - epsilon)
            #expect(tile.rect.minY >= bounds.minY - epsilon)
            #expect(tile.rect.maxX <= bounds.maxX + epsilon)
            #expect(tile.rect.maxY <= bounds.maxY + epsilon)
            let expected = tile.weight / total * Double(bounds.width * bounds.height)
            let actual = Double(tile.rect.width * tile.rect.height)
            #expect(abs(actual - expected) <= max(expected * 1e-4, 1e-3))
        }
        let area = tiles.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(area - Double(bounds.width * bounds.height)) < 1e-3)
        for (offset, lhs) in tiles.enumerated() {
            for rhs in tiles[(offset + 1)...] {
                let overlap = lhs.rect.intersection(rhs.rect)
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-6)
            }
        }
    }

    @Test func `areas are proportional and tiles stay inside bounds without overlap`() {
        let weights: [Double] = [600, 600, 400, 300, 200, 100, 100, 50, 25, 5]
        let tiles = SquarifiedLayout.layout(weights: weights, in: bounds)
        #expect(tiles.count == weights.count)
        assertValid(tiles, weights: weights, in: bounds)
    }

    @Test func `proportions hold for skewed and tall bounds`() {
        let weights: [Double] = [1e9, 5e8, 1e6, 1e3, 7, 3, 2, 1]
        let tall = CGRect(x: 0, y: 0, width: 120, height: 900)
        assertValid(SquarifiedLayout.layout(weights: weights, in: tall), weights: weights, in: tall)
    }

    @Test func `zero negative and non finite weights are ignored`() {
        let tiles = SquarifiedLayout.layout(weights: [0, -5, 10, .nan, .infinity, 30], in: bounds)
        #expect(tiles.compactMap(\.index).sorted() == [2, 5])
        #expect(SquarifiedLayout.layout(weights: [0, -1], in: bounds).isEmpty)
        #expect(SquarifiedLayout.layout(weights: [], in: bounds).isEmpty)
    }

    @Test func `empty bounds produce no tiles`() {
        #expect(SquarifiedLayout.layout(weights: [1, 2], in: .zero).isEmpty)
        #expect(SquarifiedLayout.layout(weights: [1, 2], in: CGRect(x: 0, y: 0, width: 0, height: 100)).isEmpty)
    }

    @Test func `single item fills bounds`() throws {
        let tiles = SquarifiedLayout.layout(weights: [42], in: bounds)
        #expect(try #require(tiles.first).rect == bounds)
    }

    @Test func `more than the cap merges the rest into Other`() throws {
        let weights = (1 ... 450).map { Double($0) }
        let tiles = SquarifiedLayout.layout(weights: weights, in: bounds)
        #expect(tiles.count == SquarifiedLayout.maxTiles)
        let others = tiles.filter(\.isOther)
        #expect(others.count == 1)
        let other = try #require(others.first)
        #expect(other.mergedIndices.count == 450 - (SquarifiedLayout.maxTiles - 1))
        let kept = tiles.compactMap(\.index)
        #expect(Set(kept).isDisjoint(with: other.mergedIndices))
        #expect(kept.count + other.mergedIndices.count == 450)
        #expect(other.weight == other.mergedIndices.reduce(0) { $0 + weights[$1] })
        assertValid(tiles, weights: weights, in: bounds)
    }

    @Test func `exactly the cap does not create Other`() {
        let tiles = SquarifiedLayout.layout(weights: (1 ... 300).map { Double($0) }, in: bounds)
        #expect(tiles.count == 300)
        #expect(tiles.allSatisfy { !$0.isOther })
    }

    @Test func `layout is deterministic including ties`() {
        let weights = [5, 5, 5, 3, 3, 1, 1, 1, 1].map(Double.init)
        let first = SquarifiedLayout.layout(weights: weights, in: bounds)
        let second = SquarifiedLayout.layout(weights: weights, in: bounds)
        #expect(first == second)
        #expect(first.prefix(3).compactMap(\.index) == [0, 1, 2])
    }

    @Test func `tiles are reasonably square`() {
        let weights = (1 ... 40).map { Double(41 - $0) }
        let tiles = SquarifiedLayout.layout(weights: weights, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let worst = tiles.map { max($0.rect.width / $0.rect.height, $0.rect.height / $0.rect.width) }.max() ?? .infinity
        #expect(worst < 8)
    }
}
