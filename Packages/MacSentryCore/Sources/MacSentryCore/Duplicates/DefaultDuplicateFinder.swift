import Foundation
import Synchronization

public struct DefaultDuplicateFinder: DuplicateFinder {
    static let progressInterval: Int64 = 64 << 20

    public init() {}

    public func find(sizeIndex: SizeIndex, options: DuplicateOptions) -> AsyncThrowingStream<DuplicateEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let summary = try await run(sizeIndex: sizeIndex, options: options) { continuation.yield($0) }
                    continuation.yield(.finished(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func run(
        sizeIndex: SizeIndex,
        options: DuplicateOptions,
        emit: @escaping @Sendable (DuplicateEvent) -> Void,
    ) async throws -> DuplicateSummary {
        var summary = DuplicateSummary()
        summary.datalessSkipped = sizeIndex.datalessCount
        let limit = max(1, options.concurrency)
        let sizeBuckets = sizeIndex.duplicateCandidates(minSize: options.minSize, roots: options.roots)

        let partialJobs = sizeBuckets.enumerated().flatMap { bucket, entries in entries.map { HashJob(bucket: bucket, entry: $0) } }
        var partialMatches = Array(repeating: [String: [FileEntry]](), count: sizeBuckets.count)
        try await Self.bounded(partialJobs, limit: limit) { job in
            try Task.checkCancellation()
            return FileHasher.partialHash(job.entry)
        } collect: { job, outcome in
            if case let .digest(hash) = outcome {
                partialMatches[job.bucket][hash, default: []].append(job.entry)
            } else {
                Self.record(outcome, for: job.entry, in: &summary)
            }
        }

        let fullBuckets = partialMatches.flatMap { matches in
            matches.values.filter { $0.count > 1 }.sorted { $0[0].url.path(percentEncoded: false) < $1[0].url.path(percentEncoded: false) }
        }
        let fullJobs = fullBuckets.enumerated().flatMap { bucket, entries in entries.map { HashJob(bucket: bucket, entry: $0) } }
        let progress = HashProgress(total: fullJobs.count)
        var remaining = fullBuckets.map(\.count)
        var fullMatches = Array(repeating: [String: [FileEntry]](), count: fullBuckets.count)
        emit(.hashing(done: 0, total: fullJobs.count, bytes: 0))

        try await Self.bounded(fullJobs, limit: limit) { job in
            try FileHasher.fullHash(job.entry) { count in
                if let event = progress.add(bytes: count) {
                    emit(event)
                }
            }
        } collect: { job, outcome in
            if case let .digest(hash) = outcome {
                fullMatches[job.bucket][hash, default: []].append(job.entry)
                summary.filesHashed += 1
            } else {
                Self.record(outcome, for: job.entry, in: &summary)
            }
            emit(progress.completeFile())
            remaining[job.bucket] -= 1
            guard remaining[job.bucket] == 0 else { return }
            for (hash, members) in fullMatches[job.bucket] where members.count > 1 {
                guard let result = Self.makeGroup(hash: hash, entries: members, options: options) else { continue }
                summary.groupCount += 1
                emit(.group(result.group, members: result.members))
            }
            fullMatches[job.bucket] = [:]
        }

        summary.bytesHashed = progress.bytes
        return summary
    }

    static func makeGroup(
        hash: String,
        entries: [FileEntry],
        options: DuplicateOptions,
    ) -> (group: DuplicateGroup, members: [Candidate])? {
        guard let keeper = DuplicateKeeper.preferred(among: entries, homeURL: options.homeURL) else { return nil }
        let copies = entries.filter { $0.inode != keeper.inode || $0.device != keeper.device }
        // A full APFS clone shares every block with the keeper, so moving it frees nothing.
        let members = copies
            .filter { DuplicateKeeper.freeableSize(of: $0) > 0 }
            .sorted { $0.url.path(percentEncoded: false) < $1.url.path(percentEncoded: false) }
            .map { DuplicateKeeper.candidate(for: $0, keeper: keeper.url, sessionID: options.sessionID, groupID: nil) }
        guard !members.isEmpty else { return nil }
        let group = DuplicateGroup(
            sessionID: options.sessionID,
            contentHash: hash,
            fileSize: keeper.logicalSize,
            memberCount: entries.count - (copies.count - members.count),
            reclaimableSize: members.reduce(0) { $0 + $1.freeableSize },
            keeperURL: keeper.url,
        )
        return (group, members)
    }

    private static func record(_ outcome: HashOutcome, for entry: FileEntry, in summary: inout DuplicateSummary) {
        switch outcome {
        case .digest:
            break
        case .unreadable:
            summary.unreadable.append(entry.url)
        case .changed:
            summary.changedDuringHashing.append(entry.url)
        case .dataless:
            summary.datalessSkipped += 1
        }
    }

    private static func bounded<Output: Sendable>(
        _ jobs: [HashJob],
        limit: Int,
        work: @escaping @Sendable (HashJob) async throws -> Output,
        collect: (HashJob, Output) throws -> Void,
    ) async throws {
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            while next < min(limit, jobs.count) {
                let index = next
                group.addTask { try await (index, work(jobs[index])) }
                next += 1
            }
            while let (index, output) = try await group.next() {
                try collect(jobs[index], output)
                guard next < jobs.count else { continue }
                let upcoming = next
                group.addTask { try await (upcoming, work(jobs[upcoming])) }
                next += 1
            }
        }
    }
}

struct HashJob: Sendable {
    let bucket: Int
    let entry: FileEntry
}

final class HashProgress: Sendable {
    private struct State {
        var done = 0
        var bytes: Int64 = 0
        var reportedBytes: Int64 = 0
    }

    let total: Int
    private let state = Mutex(State())

    init(total: Int) {
        self.total = total
    }

    var bytes: Int64 {
        state.withLock(\.bytes)
    }

    func add(bytes count: Int) -> DuplicateEvent? {
        state.withLock { state in
            state.bytes += Int64(count)
            guard state.bytes - state.reportedBytes >= DefaultDuplicateFinder.progressInterval else { return nil }
            state.reportedBytes = state.bytes
            return .hashing(done: state.done, total: total, bytes: state.bytes)
        }
    }

    func completeFile() -> DuplicateEvent {
        state.withLock { state in
            state.done += 1
            state.reportedBytes = state.bytes
            return .hashing(done: state.done, total: total, bytes: state.bytes)
        }
    }
}
