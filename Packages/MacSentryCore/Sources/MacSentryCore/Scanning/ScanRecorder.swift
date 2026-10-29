import Foundation
import GRDB
import Synchronization

final class ScanRecorder: Sendable {
    private struct State {
        var pending: [Candidate] = []
        var keys: Set<String> = []
        var inserted: [Candidate] = []
        var insertedIndex: [Int64: Int] = [:]
        var freeableByPath: [String: Int64] = [:]

        mutating func record(_ written: [Candidate]) {
            for candidate in written {
                let path = candidate.url.storagePath
                if let id = candidate.id, let index = insertedIndex[id] {
                    inserted[index] = candidate
                } else {
                    if let id = candidate.id {
                        insertedIndex[id] = inserted.count
                    }
                    inserted.append(candidate)
                }
                freeableByPath[path] = max(freeableByPath[path] ?? 0, candidate.freeableSize)
            }
        }
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
        let persisted = candidates.filter { $0.id != nil }
        state.withLock { state in
            for candidate in persisted {
                state.keys.insert(candidate.url.storagePath + "\u{0}" + candidate.category.rawValue)
            }
            state.record(persisted)
            for candidate in candidates where candidate.id == nil {
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
        var written = persisted
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
        state.withLock { $0.record(written) }
        return written
    }

    func resolveLastUsed(with resolver: any LastUsedResolver) async throws -> [Candidate] {
        let pending = inserted.filter { $0.lastUsedAt == nil || $0.category == .oldLarge }
        guard !pending.isEmpty else { return [] }
        let found = await resolver.lastUsed(for: pending.map(\.url))
        let spotlight = Dictionary(found.map { ($0.key.storagePath, $0.value) }) { first, _ in first }

        struct Update {
            let id: Int64
            let date: Date
            let reason: String?
        }
        var updates: [Update] = []
        for candidate in pending {
            guard let id = candidate.id else { continue }
            let indexed = spotlight[candidate.url.storagePath]
            if let date = [indexed, candidate.lastUsedAt, candidate.modifiedAt].compactMap(\.self).max() {
                let opened = indexed != nil && candidate.ruleID == OldLargeRule.rule.id
                updates.append(Update(id: id, date: date, reason: opened ? OldLargeRule.openedReason : nil))
            }
        }

        var updated: [Candidate] = []
        var start = updates.startIndex
        while start < updates.endIndex {
            let batch = Array(updates[start ..< min(start + batchSize, updates.endIndex)])
            updated += try await database.writer.write { db in
                for update in batch {
                    try db.execute(
                        sql: "UPDATE candidate SET last_used_at = ?, reason = COALESCE(?, reason) WHERE id = ?",
                        arguments: [update.date.timeIntervalSince1970, update.reason, update.id],
                    )
                }
                return try Candidate.fetchAll(db, keys: batch.map(\.id))
            }
            start += batch.count
        }
        return updated
    }
}
