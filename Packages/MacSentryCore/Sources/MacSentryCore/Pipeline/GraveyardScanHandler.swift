import Foundation
import GRDB

final class GraveyardScanHandler: ScanEntryHandler {
    let finishPhase: ScanPhase? = .projects
    private let collector: GraveyardCollector
    private let gate: CandidateGate
    private let claims: WalkClaims

    init(collector: GraveyardCollector, gate: CandidateGate, claims: WalkClaims) {
        self.collector = collector
        self.gate = gate
        self.claims = claims
    }

    func visit(_ entry: FileEntry, context _: ScanContext) async -> HandlerDecision {
        let (decision, artifact) = collector.classify(entry)
        guard decision == .skipChildren else { return .descend }
        guard let artifact, gate.admits(entry.url, action: .quarantine) else { return .skip }
        claims.insert(entry.url)
        return .claim(CandidateDraft(
            category: .projectArtifact,
            ruleID: artifact.match.rule.ruleID,
            tier: artifact.match.rule.tier,
            action: .quarantine,
            reason: artifact.reason,
        ))
    }

    /// Artifacts were claimed and sized during the walk; here they get their project row and project_id.
    func finish(context: ScanContext) async throws -> [Candidate] {
        let session = context.sessionID
        let database = context.database
        let recorded: [String: Candidate]
        do {
            recorded = try await database.writer.read { db in
                try Candidate
                    .filter(Column(Candidate.CodingKeys.sessionID.rawValue) == session)
                    .filter(Column(Candidate.CodingKeys.category.rawValue) == Category.projectArtifact.rawValue)
                    .fetchAll(db)
            }.reduce(into: [:]) { $0[$1.url.storagePath] = $1 }
        } catch {
            throw ScanPipelineError.persistence(error.localizedDescription)
        }
        let projects = await collector.finish(sessionID: session) { url in
            guard let row = recorded[url.storagePath] else { throw ScanPipelineError.artifactNotRecorded(url) }
            return SizeInfo(logical: row.logicalSize, allocated: row.allocatedSize, freeable: row.freeableSize)
        }
        guard !projects.isEmpty else { return [] }
        do {
            return try await database.writer.write { db in
                var linked: [Candidate] = []
                for item in projects {
                    var project = item.project
                    try project.insert(db)
                    for artifact in item.artifacts {
                        guard var row = recorded[artifact.url.storagePath] else { continue }
                        row.projectID = project.id
                        row.reason = artifact.reason
                        try row.update(db)
                        linked.append(row)
                    }
                }
                return linked
            }
        } catch {
            throw ScanPipelineError.persistence(error.localizedDescription)
        }
    }
}
