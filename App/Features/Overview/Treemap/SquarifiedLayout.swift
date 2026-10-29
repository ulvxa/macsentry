import CoreGraphics

enum SquarifiedLayout {
    static let maxTiles = 300

    struct Tile: Equatable, Sendable {
        /// Index into the input weights. `nil` for the merged "Other" tile.
        var index: Int?
        var mergedIndices: [Int]
        var weight: Double
        var rect: CGRect

        var isOther: Bool {
            index == nil
        }
    }

    private struct Entry {
        var index: Int?
        var merged: [Int]
        var weight: Double
        var sortKey: Int {
            index ?? Int.max
        }
    }

    static func layout(weights: [Double], in bounds: CGRect, maxTiles: Int = SquarifiedLayout.maxTiles) -> [Tile] {
        guard bounds.width > 0, bounds.height > 0, maxTiles > 0 else { return [] }
        var entries = weights.enumerated()
            .filter { $0.element.isFinite && $0.element > 0 }
            .map { Entry(index: $0.offset, merged: [], weight: $0.element) }
        guard !entries.isEmpty else { return [] }
        entries.sort(by: ordered)
        if entries.count > maxTiles {
            let tail = entries[(maxTiles - 1)...]
            let other = Entry(index: nil, merged: tail.compactMap(\.index), weight: tail.reduce(0) { $0 + $1.weight })
            entries = Array(entries[..<(maxTiles - 1)]) + [other]
            entries.sort(by: ordered)
        }

        let total = entries.reduce(0) { $0 + $1.weight }
        let scale = Double(bounds.width * bounds.height) / total
        let rects = squarify(areas: entries.map { $0.weight * scale }, in: bounds)
        return zip(entries, rects).map { Tile(index: $0.index, mergedIndices: $0.merged, weight: $0.weight, rect: $1) }
    }

    private static func ordered(_ lhs: Entry, _ rhs: Entry) -> Bool {
        lhs.weight != rhs.weight ? lhs.weight > rhs.weight : lhs.sortKey < rhs.sortKey
    }

    private static func squarify(areas: [Double], in bounds: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: areas.count)
        var free = bounds
        var start = 0
        while start < areas.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var sum = areas[start]
            var worst = worstRatio(sum: sum, smallest: areas[start], largest: areas[start], side: side)
            while end < areas.count {
                let candidateSum = sum + areas[end]
                let candidateWorst = worstRatio(sum: candidateSum, smallest: areas[end], largest: areas[start], side: side)
                if candidateWorst > worst {
                    break
                }
                sum = candidateSum
                worst = candidateWorst
                end += 1
            }
            free = place(areas[start ..< end], sum: sum, isLast: end == areas.count, in: free, into: &rects)
            start = end
        }
        return rects
    }

    private static func worstRatio(sum: Double, smallest: Double, largest: Double, side: Double) -> Double {
        let sideSquared = side * side
        let sumSquared = sum * sum
        return max(sideSquared * largest / sumSquared, sumSquared / (sideSquared * smallest))
    }

    private static func place(
        _ row: ArraySlice<Double>,
        sum: Double,
        isLast: Bool,
        in free: CGRect,
        into rects: inout [CGRect],
    ) -> CGRect {
        let vertical = free.width >= free.height
        let extent = vertical ? free.height : free.width
        let full = vertical ? free.width : free.height
        var thickness = CGFloat(sum / Double(extent))
        if isLast || thickness > full {
            thickness = full
        }
        var cursor: CGFloat = 0
        for (offset, area) in row.enumerated() {
            let isTail = offset == row.count - 1
            let length = isTail ? extent - cursor : min(CGFloat(area / Double(thickness)), extent - cursor)
            rects[row.startIndex + offset] = vertical
                ? CGRect(x: free.minX, y: free.minY + cursor, width: thickness, height: length)
                : CGRect(x: free.minX + cursor, y: free.minY, width: length, height: thickness)
            cursor += length
        }
        return vertical
            ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
            : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
    }
}
