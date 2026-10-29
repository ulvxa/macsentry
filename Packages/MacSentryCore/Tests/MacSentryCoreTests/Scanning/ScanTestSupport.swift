import Darwin
import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
@testable import MacSentryCore

enum ScanTest {
    static let megabyte: Int64 = 1024 * 1024

    static func entries(
        _ walker: some ReportingFileWalker,
        root: URL,
        excluded: [URL] = [],
        decide: @Sendable (FileEntry) -> WalkDecision = { _ in .descend },
    ) async throws -> (entries: [FileEntry], issues: [WalkIssue]) {
        let entries = Mutex<[FileEntry]>([])
        let issues = Mutex<[WalkIssue]>([])
        try await walker.walk(root: root, excluded: excluded) { issue in
            issues.withLock { $0.append(issue) }
        } visit: { entry in
            entries.withLock { $0.append(entry) }
            return decide(entry)
        }
        return (entries.withLock { $0 }, issues.withLock { $0 })
    }

    static func collect(_ stream: AsyncThrowingStream<ScanEvent, Error>) async throws -> [ScanEvent] {
        var events: [ScanEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    static func summary(_ events: [ScanEvent]) -> ScanSummary? {
        events.lazy.compactMap {
            if case let .finished(summary) = $0 {
                summary
            } else {
                nil
            }
        }.first
    }

    static func candidates(_ events: [ScanEvent]) -> [[Candidate]] {
        events.compactMap {
            if case let .candidates(batch) = $0 {
                batch
            } else {
                nil
            }
        }
    }

    static func allocated(_ url: URL) -> Int64 {
        var info = stat()
        lstat(url.path(percentEncoded: false), &info)
        return Int64(info.st_blocks) * 512
    }

    static func service(
        _ database: MacSentryCore.Database,
        handlers: [any ScanEntryHandler] = [],
        resolver: any LastUsedResolver = FixedLastUsedResolver(),
    ) -> DefaultScanService {
        DefaultScanService(database: database, lastUsedResolver: resolver, handlers: handlers)
    }

    static func nodes(_ database: MacSentryCore.Database, session: Int64) throws -> [String: DirNode] {
        try database.writer.read { db in
            try DirNode.filter(Column("session_id") == session).fetchAll(db)
        }.reduce(into: [:]) { $0[$1.url.storagePath] = $1 }
    }
}

extension FileEntry {
    var path: String {
        url.storagePath
    }
}

final class RecordingHandler: ScanEntryHandler {
    let finishPhase: ScanPhase?
    private let decide: @Sendable (FileEntry) -> HandlerDecision
    private let produce: @Sendable (ScanContext) -> [Candidate]
    private let delay: Duration?
    private let seen = Mutex<[FileEntry]>([])

    init(
        finishPhase: ScanPhase? = nil,
        delay: Duration? = nil,
        decide: @escaping @Sendable (FileEntry) -> HandlerDecision = { _ in .descend },
        produce: @escaping @Sendable (ScanContext) -> [Candidate] = { _ in [] },
    ) {
        self.finishPhase = finishPhase
        self.delay = delay
        self.produce = produce
        self.decide = decide
    }

    var entries: [FileEntry] {
        seen.withLock { $0 }
    }

    func visit(_ entry: FileEntry, context _: ScanContext) async -> HandlerDecision {
        seen.withLock { $0.append(entry) }
        if let delay {
            try? await Task.sleep(for: delay)
        }
        return decide(entry)
    }

    func finish(context: ScanContext) async throws -> [Candidate] {
        produce(context)
    }
}

extension CandidateDraft {
    static func test(_ category: MacSentryCore.Category = .appCache, rule: String = "test.rule") -> CandidateDraft {
        CandidateDraft(category: category, ruleID: rule, tier: .green, action: .quarantine, reason: "Test")
    }
}
