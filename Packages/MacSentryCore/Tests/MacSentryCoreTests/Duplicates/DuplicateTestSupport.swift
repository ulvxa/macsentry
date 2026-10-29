import Foundation
import MacSentryTestSupport
@testable import MacSentryCore

enum DuplicateTestSupport {
    static let sessionID: Int64 = 1

    static func entries(_ urls: [URL]) throws -> [FileEntry] {
        try urls.map { try FileProbe.entry(for: $0) }
    }

    static func options(_ fixture: FixtureBuilder, minSize: Int64 = DuplicateOptions.defaultMinSize) -> DuplicateOptions {
        DuplicateOptions(roots: [fixture.root], minSize: minSize, homeURL: fixture.root, sessionID: sessionID)
    }

    static func index(_ fixture: FixtureBuilder, _ urls: [URL], minSize: Int64 = DuplicateOptions.defaultMinSize) throws -> SizeIndex {
        var index = SizeIndex(roots: [fixture.root], minSize: minSize)
        try index.add(contentsOf: entries(urls))
        return index
    }

    static func collect(_ stream: AsyncThrowingStream<DuplicateEvent, Error>) async throws -> [DuplicateEvent] {
        var events: [DuplicateEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    static func groups(_ events: [DuplicateEvent]) -> [(group: DuplicateGroup, members: [Candidate])] {
        events.compactMap { event in
            guard case let .group(group, members) = event else { return nil }
            return (group, members)
        }
    }

    static func summary(_ events: [DuplicateEvent]) -> DuplicateSummary? {
        guard case let .finished(summary) = events.last else { return nil }
        return summary
    }

    static func syntheticEntry(
        _ path: String,
        size: Int64 = 2_000_000,
        inode: UInt64 = 1,
        flags: UInt32 = 0,
        kind: EntryKind = .file,
        created: Date? = Date(timeIntervalSince1970: 1_700_000_000),
    ) -> FileEntry {
        FileEntry(
            url: URL(filePath: path), kind: kind, logicalSize: size, allocatedSize: size, privateSize: size,
            linkCount: 1, inode: inode, device: 1, flags: flags, created: created, modified: created, ownerUID: 501,
        )
    }

    static func date(_ day: Int) -> Date {
        Date(timeIntervalSince1970: 1_600_000_000 + TimeInterval(day) * 86400)
    }
}
