import Foundation

public struct SparklinePoint: Sendable, Equatable {
    public let bucketStart: Date
    public let freeBytes: Int64
    public let sampleCount: Int

    public init(bucketStart: Date, freeBytes: Int64, sampleCount: Int) {
        self.bucketStart = bucketStart
        self.freeBytes = freeBytes
        self.sampleCount = sampleCount
    }
}

public struct Sparkline: Sendable, Equatable {
    public static let defaultBucket: Duration = .seconds(6 * 3600)

    public let bucketSeconds: TimeInterval
    public let points: [SparklinePoint]

    public var minPoint: SparklinePoint? {
        points.min { $0.freeBytes < $1.freeBytes }
    }

    public var maxPoint: SparklinePoint? {
        points.max { $0.freeBytes < $1.freeBytes }
    }

    /// Contiguous runs of adjacent buckets; draw each run as its own line so gaps stay visible.
    public var segments: [[SparklinePoint]] {
        var result: [[SparklinePoint]] = []
        for point in points {
            if let last = result.last?.last,
               point.bucketStart.timeIntervalSince(last.bucketStart) <= bucketSeconds {
                result[result.count - 1].append(point)
            } else {
                result.append([point])
            }
        }
        return result
    }

    /// One point per non-empty bucket, valued at the mean `important_free` of its samples.
    /// Empty buckets produce no point. Buckets are aligned to the Unix epoch.
    public static func make(samples: [DiskSample], bucket: Duration = defaultBucket) -> Sparkline {
        let bucketSeconds = max(1, TimeInterval(bucket.components.seconds))
        var sums: [Int64: (sum: Int64, count: Int)] = [:]
        for sample in samples {
            let index = Int64((sample.sampledAt.timeIntervalSince1970 / bucketSeconds).rounded(.down))
            let current = sums[index] ?? (0, 0)
            sums[index] = (current.sum + sample.importantFree, current.count + 1)
        }
        let points = sums.keys.sorted().compactMap { index -> SparklinePoint? in
            guard let entry = sums[index] else { return nil }
            return SparklinePoint(
                bucketStart: Date(timeIntervalSince1970: TimeInterval(index) * bucketSeconds),
                freeBytes: entry.sum / Int64(entry.count),
                sampleCount: entry.count,
            )
        }
        return Sparkline(bucketSeconds: bucketSeconds, points: points)
    }
}
