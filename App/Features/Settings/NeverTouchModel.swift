import Foundation
import MacSentryCore
import Observation

struct NeverTouchRow: Identifiable, Equatable {
    let id: Int64
    let pattern: String
    let note: String?
    let createdAt: Date
    let protectsEverything: Bool
}

@Observable
@MainActor
final class NeverTouchModel {
    @ObservationIgnored private let store: any NeverTouchStore
    @ObservationIgnored let provider: ProtectionPolicyProvider
    @ObservationIgnored private let homeURL: URL

    private(set) var patterns: [NeverTouchPattern] = []
    private(set) var errorMessage: String?
    var draftPattern = ""
    var draftNote = ""
    var testPath = ""

    init(store: any NeverTouchStore, provider: ProtectionPolicyProvider, homeURL: URL) {
        self.store = store
        self.provider = provider
        self.homeURL = homeURL
    }

    var draftError: String? {
        guard !draftPattern.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do {
            try GlobPattern.validate(draftPattern)
            return nil
        } catch {
            return error.errorDescription
        }
    }

    var draftWarning: String? {
        (try? GlobPattern.validate(draftPattern))??.message
    }

    var canAdd: Bool {
        !draftPattern.trimmingCharacters(in: .whitespaces).isEmpty && draftError == nil
    }

    var testVerdict: ProtectionVerdict? {
        let trimmed = testPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return provider.check(UserPath.expand(trimmed, homeURL: homeURL))
    }

    var rows: [NeverTouchRow] {
        patterns.compactMap { record in
            record.id.map { id in
                NeverTouchRow(
                    id: id,
                    pattern: record.pattern,
                    note: record.note,
                    createdAt: record.createdAt,
                    protectsEverything: (try? GlobPattern.validate(record.pattern)) == .protectsEverything,
                )
            }
        }
    }

    func load() async {
        await perform {}
    }

    func add() async {
        guard canAdd else { return }
        let pattern = draftPattern
        let note = draftNote
        if await perform({ try await store.add(pattern, note: note) }) {
            draftPattern = ""
            draftNote = ""
        }
    }

    func remove(ids: Set<Int64>) async {
        await perform {
            for id in ids {
                try await store.remove(id: id)
            }
        }
    }

    @discardableResult
    private func perform(_ change: () async throws -> Void) async -> Bool {
        do {
            try await change()
            try await provider.refresh()
            patterns = try await store.patterns()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
