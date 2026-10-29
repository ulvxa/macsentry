import Foundation
import GRDB
import Synchronization

public protocol ScanService: Sendable {
    func scan(config: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error>
}

public struct DefaultScanService: ScanService {
    public static let retainedSessions = 5
    public static let batchSize = 500

    private let database: Database
    private let walker: (any ReportingFileWalker)?
    private let lastUsedResolver: any LastUsedResolver
    private let makeHandlers: @Sendable (ScanConfig) -> [any ScanEntryHandler]
    private let progressInterval: Duration
    private let control: ScanControl?

    public init(
        database: Database,
        walker: (any ReportingFileWalker)? = nil,
        lastUsedResolver: any LastUsedResolver = SpotlightLastUsedResolver(),
        progressInterval: Duration = .milliseconds(100),
        control: ScanControl? = nil,
        makeHandlers: @escaping @Sendable (ScanConfig) -> [any ScanEntryHandler] = { _ in [] },
    ) {
        self.database = database
        self.walker = walker
        self.lastUsedResolver = lastUsedResolver
        self.progressInterval = progressInterval
        self.control = control
        self.makeHandlers = makeHandlers
    }

    public init(
        database: Database,
        walker: (any ReportingFileWalker)? = nil,
        lastUsedResolver: any LastUsedResolver = SpotlightLastUsedResolver(),
        handlers: [any ScanEntryHandler],
    ) {
        self.init(database: database, walker: walker, lastUsedResolver: lastUsedResolver) { _ in handlers }
    }

    public func scan(config: ScanConfig) -> AsyncThrowingStream<ScanEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ScanEvent.self, throwing: Error.self)
        let excluded = config.effectiveExcluded
        let walker = walker ?? BulkFileWalker(maxConcurrency: config.maxConcurrency)
        let run = ScanRun(
            config: config,
            excluded: excluded,
            database: database,
            walker: walker,
            sizeCalculator: DefaultSizeCalculator(walker: self.walker ?? BulkFileWalker(maxConcurrency: 2), excluded: excluded),
            lastUsedResolver: lastUsedResolver,
            makeHandlers: makeHandlers,
            progressInterval: progressInterval,
            continuation: continuation,
        )
        let task = Task { await run.execute() }
        continuation.onTermination = { _ in task.cancel() }
        control?.attachCancel { task.cancel() }
        return stream
    }
}

private final class ScanProgress: Sendable {
    struct Values {
        var files = 0
        var bytes: Int64 = 0
        var lastEmit: ContinuousClock.Instant?
        var unreadable: [URL] = []
        var dataless = 0
        var failure: String?
        var treesWritten = false
    }

    private let interval: Duration
    private let values = Mutex(Values())

    init(interval: Duration) {
        self.interval = interval
    }

    var snapshot: Values {
        values.withLock { $0 }
    }

    func record(_ issue: WalkIssue) {
        values.withLock { values in
            switch issue {
            case let .unreadable(url, _): values.unreadable.append(url)
            case .skippedDataless: values.dataless += 1
            }
        }
    }

    func markTreesWritten() {
        values.withLock { $0.treesWritten = true }
    }

    func recordFailure(_ error: any Error) {
        values.withLock { values in
            if values.failure == nil {
                values.failure = error.localizedDescription
            }
        }
    }

    func count(files: Int, bytes: Int64, path: @autoclosure () -> String) -> ScanEvent? {
        let now = ContinuousClock.now
        let due: (Int, Int64)? = values.withLock { values in
            values.files += files
            values.bytes += bytes
            if let last = values.lastEmit, now - last < interval {
                return nil
            }
            values.lastEmit = now
            return (values.files, values.bytes)
        }
        return due.map { .progress(filesVisited: $0.0, bytesVisited: $0.1, currentPath: path()) }
    }
}

private struct ScanRun: Sendable {
    let config: ScanConfig
    let excluded: [URL]
    let database: Database
    let walker: any ReportingFileWalker
    let sizeCalculator: DefaultSizeCalculator
    let lastUsedResolver: any LastUsedResolver
    let makeHandlers: @Sendable (ScanConfig) -> [any ScanEntryHandler]
    let progressInterval: Duration
    let continuation: AsyncThrowingStream<ScanEvent, Error>.Continuation

    func execute() async {
        let sessionID: Int64
        do {
            sessionID = try await startSession()
        } catch {
            continuation.finish(throwing: ScanError.persistence(error.localizedDescription))
            return
        }
        continuation.yield(.started(sessionID: sessionID))

        let pass = ScanPass(
            sessionID: sessionID,
            started: .now,
            context: ScanContext(
                sessionID: sessionID, config: config, database: database,
                sizeCalculator: sizeCalculator, lastUsedResolver: lastUsedResolver,
            ),
            handlers: makeHandlers(config),
            progress: ScanProgress(interval: progressInterval),
            recorder: ScanRecorder(
                database: database, batchSize: DefaultScanService.batchSize, candidateExcluded: config.candidateExcluded,
            ),
            trees: config.roots.map { DirectoryTree(root: $0, maxDepth: config.treeDepth) },
        )
        do {
            try await run(pass)
            let summary = try await finish(.finished, pass)
            continuation.yield(.finished(summary))
            continuation.finish()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError
            await Task.detached { [self] in
                if cancelled {
                    _ = try? await pass.recorder.flush()
                    if !pass.progress.snapshot.treesWritten {
                        try? await writeTrees(pass.trees, sessionID: sessionID)
                    }
                }
                _ = try? await finish(cancelled ? .cancelled : .failed, pass, error: cancelled ? nil : error.localizedDescription)
            }.value
            if cancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    private func run(_ pass: ScanPass) async throws {
        continuation.yield(.phase(.walking))
        for tree in pass.trees {
            try await walker.walk(root: URL(filePath: tree.rootPath, directoryHint: .isDirectory), excluded: excluded) { issue in
                pass.progress.record(issue)
            } visit: { entry in
                await visit(entry, tree: tree, pass: pass)
            }
        }
        try Task.checkCancellation()
        let totals = pass.progress.snapshot
        if let failure = totals.failure {
            throw ScanError.persistence(failure)
        }
        continuation.yield(.progress(filesVisited: totals.files, bytesVisited: totals.bytes, currentPath: ""))
        try await emit(pass.recorder.flush())
        try await writeTrees(pass.trees, sessionID: pass.sessionID)
        pass.progress.markTreesWritten()

        for handler in pass.handlers {
            if let phase = handler.finishPhase {
                continuation.yield(.phase(phase))
            }
            let produced = try await handler.finish(context: pass.context)
            try await emit(pass.recorder.add(produced))
            try await emit(pass.recorder.flush())
        }

        continuation.yield(.phase(.lastUsed))
        try await emit(pass.recorder.resolveLastUsed(with: lastUsedResolver))
        try Task.checkCancellation()
    }

    private func visit(_ entry: FileEntry, tree: DirectoryTree, pass: ScanPass) async -> WalkDecision {
        var drafts: [CandidateDraft] = []
        var skip = false
        for handler in pass.handlers {
            switch await handler.visit(entry, context: pass.context) {
            case .descend: continue
            case .skip: skip = true
            case let .claim(draft): drafts.append(draft)
            }
        }

        var candidates: [Candidate] = []
        let decision: WalkDecision
        if entry.kind == .folder {
            if drafts.isEmpty {
                if skip {
                    return .skipChildren
                }
                tree.addFolder(entry.url)
                return .descend
            }
            decision = .skipChildren
            guard let summary = try? await sizeCalculator.summarize(folder: entry.url) else { return decision }
            tree.addAggregate(path: WalkRules.path(of: entry.url), allocated: summary.size.allocated, files: summary.itemCount)
            yieldProgress(pass.progress.count(
                files: summary.itemCount,
                bytes: summary.size.allocated,
                path: entry.url.path(percentEncoded: false),
            ))
            let modified = [entry.modified, summary.latestModified].compactMap(\.self).max()
            candidates = drafts.filter { summary.size.freeable >= $0.minFreeableSize }
                .map { pass.context.candidate($0, for: entry, size: summary.size, modified: modified) }
        } else {
            decision = .descend
            tree.addItem(entry)
            yieldProgress(pass.progress.count(files: 1, bytes: entry.allocatedSize, path: entry.url.path(percentEncoded: false)))
            let size = sizeCalculator.sizeInfo(for: entry)
            candidates = drafts.filter { size.freeable >= $0.minFreeableSize }.map { pass.context.candidate($0, for: entry, size: size) }
        }

        if !candidates.isEmpty {
            do {
                try await emit(pass.recorder.add(candidates))
            } catch {
                pass.progress.recordFailure(error)
            }
        }
        return decision
    }

    private func yieldProgress(_ event: ScanEvent?) {
        if let event {
            continuation.yield(event)
        }
    }

    private func emit(_ candidates: [Candidate]) {
        guard !candidates.isEmpty else { return }
        continuation.yield(.candidates(candidates))
    }

    private func startSession() async throws -> Int64 {
        let roots = config.roots
        return try await database.writer.write { db in
            var session = ScanSession(startedAt: Date(), status: .running, roots: roots)
            try session.insert(db)
            // Keeps at most retainedSessions + 1 rows: the newest five plus the newest finished one the app may still show.
            try db.execute(
                sql: """
                DELETE FROM scan_session
                WHERE id NOT IN (SELECT id FROM scan_session ORDER BY id DESC LIMIT ?)
                  AND id NOT IN (SELECT id FROM scan_session WHERE status = ? ORDER BY id DESC LIMIT 1)
                """,
                arguments: [DefaultScanService.retainedSessions, ScanStatus.finished],
            )
            guard let id = session.id else { throw ScanError.persistence("scan session has no id") }
            return id
        }
    }

    private func writeTrees(_ trees: [DirectoryTree], sessionID: Int64) async throws {
        for tree in trees {
            try await DirectoryTree.write(
                tree.rows(minNodeSize: config.minTreeNodeSize),
                sessionID: sessionID,
                database: database,
                batchSize: DefaultScanService.batchSize,
            )
        }
    }

    private func finish(_ status: ScanStatus, _ pass: ScanPass, error: String? = nil) async throws -> ScanSummary {
        let values = pass.progress.snapshot
        let totals = pass.recorder.totals
        let sessionID = pass.sessionID
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE scan_session SET status = ?, finished_at = ?, files_visited = ?, bytes_visited = ?, error = ?
                WHERE id = ?
                """,
                arguments: [status, Date().timeIntervalSince1970, values.files, values.bytes, error, sessionID],
            )
        }
        return ScanSummary(
            sessionID: sessionID,
            status: status,
            duration: ContinuousClock.now - pass.started,
            filesVisited: values.files,
            bytesVisited: values.bytes,
            unreadable: values.unreadable,
            skippedDataless: values.dataless,
            candidateCount: totals.count,
            totalFreeable: totals.freeable,
        )
    }
}

private struct ScanPass: Sendable {
    let sessionID: Int64
    let started: ContinuousClock.Instant
    let context: ScanContext
    let handlers: [any ScanEntryHandler]
    let progress: ScanProgress
    let recorder: ScanRecorder
    let trees: [DirectoryTree]
}
