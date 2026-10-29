import Foundation
import Synchronization

final class DuplicateScanHandler: ScanEntryHandler {
    typealias FoundGroup = (group: DuplicateGroup, members: [Candidate])

    let finishPhase: ScanPhase? = .duplicates
    private let roots: [URL]
    private let rootPrefixes: [String]
    private let minSize: Int64
    private let homeURL: URL
    private let finder: any DuplicateFinder
    private let control: ScanControl
    private let gate: CandidateGate
    private let index: Mutex<SizeIndex>

    init(
        roots: [URL],
        minSize: Int64,
        homeURL: URL,
        finder: any DuplicateFinder,
        control: ScanControl,
        policy: any ProtectionPolicy,
        gate: CandidateGate,
        isInsideProject: @escaping @Sendable (URL) -> Bool = { _ in false },
    ) {
        self.roots = roots
        rootPrefixes = roots.map { $0.storagePath.hasSuffix("/") ? $0.storagePath : $0.storagePath + "/" }
        self.minSize = minSize
        self.homeURL = homeURL
        self.finder = finder
        self.control = control
        self.gate = gate
        index = Mutex(SizeIndex(roots: roots, minSize: minSize) { isInsideProject($0) || policy.check($0) != .allowed })
    }

    func visit(_ entry: FileEntry, context _: ScanContext) async -> HandlerDecision {
        if entry.kind == .file, entry.logicalSize < minSize, entry.url.lastPathComponent != ".git" {
            return .descend
        }
        let path = entry.url.path(percentEncoded: false)
        guard rootPrefixes.contains(where: path.hasPrefix) else { return .descend }
        index.withLock { _ = $0.add(entry) }
        return .descend
    }

    func finish(context: ScanContext) async throws -> [Candidate] {
        defer { control.end() }
        guard !control.isDuplicatesSkipped else { return [] }
        let stream = finder.find(
            sizeIndex: index.withLock { $0 },
            options: DuplicateOptions(roots: roots, minSize: minSize, homeURL: homeURL, sessionID: context.sessionID),
        )
        let control = control
        let hashing = Task { () throws -> [FoundGroup]? in
            var groups: [FoundGroup] = []
            for try await event in stream {
                switch event {
                case let .hashing(done, total, bytes):
                    control.report(HashingProgress(done: done, total: total, bytes: bytes))
                case let .group(group, members):
                    groups.append((group, members))
                case .finished:
                    return groups
                }
            }
            return nil
        }
        control.attachHashing { hashing.cancel() }
        let outcome = await withTaskCancellationHandler {
            await hashing.result
        } onCancel: {
            hashing.cancel()
        }
        control.detachHashing()
        try Task.checkCancellation()
        guard !control.isDuplicatesSkipped, let groups = try outcome.get(), !groups.isEmpty else { return [] }
        return try await persist(groups, context: context)
    }

    private func persist(_ groups: [FoundGroup], context: ScanContext) async throws -> [Candidate] {
        let emitted = try await EmittedPaths.load(session: context.sessionID, database: context.database)
        let kept: [FoundGroup] = groups.compactMap { found in
            let members = found.members.filter { gate.admits($0.url, action: $0.action) && !emitted.overlaps($0.url) }
            guard !members.isEmpty else { return nil }
            var group = found.group
            if members.count != found.members.count {
                group.memberCount = members.count + 1
                group.reclaimableSize = members.reduce(0) { $0 + $1.freeableSize }
            }
            return (group, members)
        }
        guard !kept.isEmpty else { return [] }
        do {
            return try await context.database.writer.write { db in
                try kept.flatMap { try DuplicateStore.insert($0.group, members: $0.members, in: db).members }
            }
        } catch {
            throw ScanPipelineError.persistence(error.localizedDescription)
        }
    }
}
