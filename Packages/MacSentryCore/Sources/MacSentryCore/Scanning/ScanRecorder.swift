import Foundation
import GRDB
import Synchronization

final class ScanRecorder: Sendable {
    private struct State {
        var pending: [Candidate] = []
        var keys: Set<String> = []
        var inserted: [Candidate] = []
        var freeableByPath: [String: Int64] = [:]
    }

    let database: Database
    let batchSize: Int
    private let candidateExcluded: Set<String>
    private let state = Mutex(State())

    init(database: Database, batchSize: Int, candidateExcluded: [URL]) {
        self.database = database
        self.batchSize = max(1, batchSize)
        self.candidateExcluded = Set(candidateExcluded.map(WalkRules.path(of:)))
    }

    var inserted: [Candidate] {
        state.withLock { $0.inserted }
    }

    var totals: (count: Int, freeable: Int64) {
        state.withLock { ($0.inserted.count, $0.freeableByPath.values.reduce(0, +)) }
    }

    func add(_ candidates: [Candidate]) async throws -> [Candidate] {
        var ready: [[Candidate]] = []
        state.withLock { state in
            for candidate in candidates {
                let path = candidate.url.storagePath
                guard !WalkRules.isInside(path, anyOf: candidateExcluded),
                      state.keys.insert(path + "\u{0}" + candidate.category.rawValue).inserted
                else { continue }
                state.pending.append(candidate)
                if state.pending.count >= batchSize {
                    ready.append(state.pending)
                    state.pending = []
                }
            }
        }
        var written: [Candidate] = []
        for batch in ready {
            written += try await insert(batch)
        }
        return written
    }

    func flush() async throws -> [Candidate] {
        let batch = state.withLock { state in
            defer { state.pending = [] }
            return state.pending
        }
        return batch.isEmpty ? [] : try await insert(batch)
    }

    private func insert(_ batch: [Candidate]) async throws -> [Candidate] {
        let written = try await database.writer.write { db in
            try batch.map { candidate in
                var candidate = candidate
                try candidate.insert(db)
                return candidate
            }
        }
        state.withLock { state in
            state.inserted += written
            for candidate in written {
                let path = candidate.url.storagePath
                state.freeableByPath[path] = max(state.freeableByPath[path] ?? 0, candidate.freeableSize)
            }
        }
        return written
    }

    func resolveLastUsed(with resolver: any LastUsedResolver) async throws -> [Candidate] {
        let pending = inserted.filter { $0.lastUsedAt == nil }
        guard !pending.isEmpty else { return [] }
        let found = await resolver.lastUsed(for: pending.map(\.url))
        let spotlight = Dictionary(found.map { ($0.key.storagePath, $0.value) }) { first, _ in first }

        var updates: [(id: Int64, date: Date)] = []
        for candidate in pending {
            guard let id = candidate.id else { continue }
            let indexed = spotlight[candidate.url.storagePath]
            let date: Date? = switch candidate.kind {
            case .file: indexed ?? candidate.modifiedAt
            case .folder, .package: [indexed, candidate.modifiedAt].compactMap(\.self).max()
            }
            if let date {
                updates.append((id, date))
            }
        }

        var updated: [Candidate] = []
        var start = updates.startIndex
        while start < updates.endIndex {
            let batch = Array(updates[start ..< min(start + batchSize, updates.endIndex)])
            updated += try await database.writer.write { db in
                for update in batch {
                    try db.execute(
                        sql: "UPDATE candidate SET last_used_at = ? WHERE id = ?",
                        arguments: [update.date.timeIntervalSince1970, update.id],
                    )
                }
                return try Candidate.fetchAll(db, keys: batch.map(\.id))
            }
            start += batch.count
        }
        return updated
    }
}
