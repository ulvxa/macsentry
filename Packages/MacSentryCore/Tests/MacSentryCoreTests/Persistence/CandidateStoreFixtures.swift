import Foundation
import GRDB
import Testing
@testable import MacSentryCore

enum StoreBackend: String, CaseIterable, Sendable {
    case grdb, memory
}

let referenceNow = Date(timeIntervalSince1970: 1_800_000_000)

func daysAgo(_ days: Double) -> Date {
    referenceNow.addingTimeInterval(-days * 86400)
}

// swiftlint:disable:next function_parameter_count
func candidate(
    _ id: Int64,
    _ path: String,
    category: MacSentryCore.Category,
    tier: Tier,
    rule: String,
    freeable: Int64,
    session: Int64 = 1,
    status: CandidateStatus = .found,
    created: Date? = nil,
    modified: Date? = nil,
    lastUsed: Date? = nil,
) -> Candidate {
    Candidate(
        id: id,
        sessionID: session,
        url: URL(filePath: path),
        kind: .folder,
        category: category,
        ruleID: rule,
        tier: tier,
        action: .quarantine,
        reason: "r",
        logicalSize: freeable,
        allocatedSize: freeable,
        freeableSize: freeable,
        createdAt: created,
        modifiedAt: modified,
        lastUsedAt: lastUsed,
        status: status,
    )
}

let sessionRows: [ScanSession] = [
    ScanSession(id: 1, startedAt: daysAgo(3), finishedAt: daysAgo(3), status: .finished, roots: [URL(filePath: "/")]),
    ScanSession(id: 2, startedAt: daysAgo(2), finishedAt: daysAgo(2), status: .finished, roots: [URL(filePath: "/")]),
    ScanSession(id: 3, startedAt: daysAgo(1), status: .running, roots: [URL(filePath: "/")]),
]

let candidateRows: [Candidate] = [
    candidate(
        1, "/Users/u/Library/Developer/Xcode/DerivedData", category: .devCache, tier: .green, rule: "xcode.derived",
        freeable: 5000, created: daysAgo(400), modified: daysAgo(250), lastUsed: daysAgo(100),
    ),
    candidate(
        2, "/Users/u/Library/Caches/com.foo.app", category: .appCache, tier: .green, rule: "cache.app",
        freeable: 300, created: daysAgo(300), modified: daysAgo(200),
    ),
    candidate(
        3, "/Users/u/Downloads/Big_Movie.mov", category: .oldLarge, tier: .yellow, rule: "old.large",
        freeable: 9000, created: daysAgo(600), modified: daysAgo(500), lastUsed: daysAgo(400),
    ),
    candidate(
        4, "/Users/u/.npm/_cacache", category: .devCache, tier: .red, rule: "npm.cache",
        freeable: 700, created: daysAgo(50), modified: daysAgo(5), lastUsed: daysAgo(5),
    ),
    candidate(5, "/Users/u/Downloads/100%_done_file.zip", category: .oldLarge, tier: .green, rule: "old.large", freeable: 50),
    candidate(
        6, "/Users/u/Library/Caches/old.thing", category: .devCache, tier: .green, rule: "zzz",
        freeable: 123, status: .quarantined,
    ),
    candidate(7, "/Users/u/Other/session2", category: .devCache, tier: .green, rule: "xcode.derived", freeable: 77, session: 2),
]

func node(
    _ id: Int64,
    _ parent: Int64?,
    _ path: String,
    size: Int64,
    session: Int64 = 1,
) -> DirNode {
    let url = URL(filePath: path)
    return DirNode(
        id: id,
        sessionID: session,
        parentID: parent,
        url: url,
        name: url.lastPathComponent,
        depth: 0,
        allocatedSize: size,
        fileCount: 1,
    )
}

let nodeRows: [DirNode] = [
    node(1, nil, "/Users/u", size: 10000),
    node(2, 1, "/Users/u/Library", size: 6000),
    node(3, 1, "/Users/u/Downloads", size: 3000),
    node(4, 2, "/Users/u/Library/Developer", size: 5000),
    node(5, 4, "/Users/u/Library/Developer/Xcode", size: 4000),
    node(6, nil, "/Volumes/x", size: 20000),
    node(7, nil, "/Other", size: 1, session: 2),
]

func makeStore(
    _ backend: StoreBackend,
    candidates: [Candidate] = candidateRows,
    now: Date = referenceNow,
) throws -> (store: any CandidateStore, database: MacSentryCore.Database) {
    let database = try Database.inMemory()
    switch backend {
    case .grdb:
        try database.writer.write { db in
            for var row in sessionRows {
                try row.insert(db)
            }
            for var row in candidates {
                try row.insert(db)
            }
            for var row in nodeRows {
                try row.insert(db)
            }
        }
        return (GRDBCandidateStore(database: database, now: { now }), database)
    case .memory:
        return (InMemoryCandidateStore(sessions: sessionRows, candidates: candidates, dirNodes: nodeRows, now: { now }), database)
    }
}

func ids(_ rows: [Candidate]) -> [Int64] {
    rows.compactMap(\.id)
}
