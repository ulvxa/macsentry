import Foundation
import Synchronization

public struct DefaultSizeCalculator: SizeCalculator {
    private let walker: any FileWalker
    private let excluded: [URL]

    public init(walker: any FileWalker = BulkFileWalker(maxConcurrency: 2), excluded: [URL] = []) {
        self.walker = walker
        self.excluded = excluded
    }

    public func sizeInfo(for entry: FileEntry) -> SizeInfo {
        SizeInfo(
            logical: entry.logicalSize,
            allocated: entry.allocatedSize,
            freeable: TrueSize.freeable(
                kind: entry.kind, allocated: entry.allocatedSize, privateSize: entry.privateSize, linkCount: entry.linkCount,
            ),
        )
    }

    public func aggregate(folder: URL) async throws -> SizeInfo {
        try await summarize(folder: folder).size
    }

    public func summarize(folder: URL) async throws -> FolderSummary {
        let accumulator = Mutex(SizeAccumulator())
        try await walker.walk(root: folder, excluded: excluded) { entry in
            accumulator.withLock { $0.add(entry) }
            return .descend
        }
        return accumulator.withLock { $0.summary }
    }
}
