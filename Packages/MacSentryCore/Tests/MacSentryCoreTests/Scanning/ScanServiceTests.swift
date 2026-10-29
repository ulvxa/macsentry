import Darwin
import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct ScanServiceTests {
    @Test func `folder totals land in dir_node`() async throws {
        let fixture = try FixtureBuilder(name: "ScanTotals")
        let one = try fixture.file("a/one.bin", size: ScanTest.megabyte)
        let ten = try fixture.file("a/b/ten.bin", size: 10 * ScanTest.megabyte)
        let hundred = try fixture.file("c/hundred.bin", size: 100 * ScanTest.megabyte)
        let database = try Database.inMemory()

        let events = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root])))
        let summary = try #require(ScanTest.summary(events))
        let nodes = try ScanTest.nodes(database, session: summary.sessionID)
        let sizes = (one: ScanTest.allocated(one), ten: ScanTest.allocated(ten), hundred: ScanTest.allocated(hundred))

        #expect(nodes.count == 4)
        let root = try #require(nodes[fixture.root.storagePath])
        #expect(root.depth == 0)
        #expect(root.parentID == nil)
        #expect(root.allocatedSize == sizes.one + sizes.ten + sizes.hundred)
        #expect(root.fileCount == 3)
        let folderA = try #require(nodes[fixture.url("a").storagePath])
        #expect(folderA.allocatedSize == sizes.one + sizes.ten)
        #expect(folderA.parentID == root.id)
        #expect(folderA.name == "a")
        let folderB = try #require(nodes[fixture.url("a/b").storagePath])
        #expect(folderB.allocatedSize == sizes.ten)
        #expect(folderB.depth == 2)
        #expect(folderB.parentID == folderA.id)
        try #expect(nodes[fixture.url("c").storagePath]?.allocatedSize == sizes.hundred)
        #expect(summary.filesVisited == 3)
        #expect(summary.bytesVisited == root.allocatedSize)
        #expect(summary.status == .finished)

        let session = try await database.writer.read { try ScanSession.fetchOne($0, key: summary.sessionID) }
        #expect(session?.status == .finished)
        #expect(session?.filesVisited == 3)
        #expect(session?.finishedAt != nil)
        #expect(session?.roots.map(\.storagePath) == [fixture.root.storagePath])
    }

    @Test func `hard linked file counts once in folder totals`() async throws {
        let fixture = try FixtureBuilder(name: "ScanHardLink")
        let original = try fixture.file("x/f.bin", size: 2 * ScanTest.megabyte)
        try fixture.hardLink("y/g.bin", to: original)
        let database = try Database.inMemory()

        let events = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root])))
        let nodes = try ScanTest.nodes(database, session: #require(ScanTest.summary(events)).sessionID)
        let size = ScanTest.allocated(original)
        #expect(nodes[fixture.root.storagePath]?.allocatedSize == size)
        #expect(nodes[fixture.root.storagePath]?.fileCount == 2)
        let parts = try [fixture.url("x"), fixture.url("y")].compactMap { nodes[$0.storagePath]?.allocatedSize }
        #expect(parts.sorted() == [0, size])
    }

    @Test func `tree depth and minimum node size are honoured`() async throws {
        let fixture = try FixtureBuilder(name: "ScanDepth")
        try fixture.sparseFile("l1/l2/l3/l4/l5/big.img", logicalSize: 1)
        try fixture.file("l1/l2/l3/l4/big.bin", size: 11 * ScanTest.megabyte)
        try fixture.file("l1/l2/l3/t4/tiny.bin", size: 100)
        let database = try Database.inMemory()

        let deep = try await ScanTest.collect(ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root])))
        let nodes = try ScanTest.nodes(database, session: #require(ScanTest.summary(deep)).sessionID)
        #expect(try nodes[fixture.url("l1/l2/l3/l4").storagePath] != nil)
        #expect(try nodes[fixture.url("l1/l2/l3/t4").storagePath] == nil)
        #expect(try nodes[fixture.url("l1/l2/l3/l4/l5").storagePath] == nil)
        #expect(try nodes[fixture.url("l1/l2/l3").storagePath]?.fileCount == 3)

        let shallow = try await ScanTest.collect(
            ScanTest.service(database).scan(config: ScanConfig(roots: [fixture.root], treeDepth: 2, minTreeNodeSize: 0)),
        )
        let shallowNodes = try ScanTest.nodes(database, session: #require(ScanTest.summary(shallow)).sessionID)
        #expect(shallowNodes.values.map(\.depth).max() == 2)
        #expect(try shallowNodes[fixture.url("l1/l2").storagePath]?.fileCount == 3)
        #expect(try (shallowNodes[fixture.url("l1/l2").storagePath]?.allocatedSize ?? 0) >= 11 * ScanTest.megabyte)
    }

    @Test func `claimed folder is sized whole and its children are never visited`() async throws {
        let fixture = try FixtureBuilder(name: "ScanClaim")
        try fixture.file("Library/Caches/com.example/blob.bin", size: 3 * ScanTest.megabyte)
        try fixture.file("Library/Caches/com.example/deep/more.bin", size: ScanTest.megabyte)
        try fixture.file("Documents/report.pdf", size: 20000)
        let caches = try fixture.url("Library/Caches/com.example")
        let handler = RecordingHandler { entry in
            entry.url.lastPathComponent == "com.example" ? .claim(.test()) : .descend
        }
        let database = try Database.inMemory()

        let events = try await ScanTest
            .collect(ScanTest.service(database, handlers: [handler]).scan(config: ScanConfig(roots: [fixture.root])))
        #expect(!handler.entries.contains { $0.path.hasPrefix(caches.storagePath + "/") })
        let streamed = ScanTest.candidates(events).flatMap(\.self)
        let candidate = try #require(streamed.first)
        #expect(candidate.url.storagePath == caches.storagePath)
        #expect(candidate.kind == .folder)
        #expect(candidate.logicalSize == 4 * ScanTest.megabyte)
        #expect(candidate.freeableSize == candidate.allocatedSize)
        #expect(candidate.id != nil)

        let summary = try #require(ScanTest.summary(events))
        #expect(summary.candidateCount == 1)
        #expect(summary.totalFreeable == candidate.freeableSize)
        #expect(summary.filesVisited == 3)
        let nodes = try ScanTest.nodes(database, session: summary.sessionID)
        #expect(nodes[caches.storagePath]?.allocatedSize == candidate.allocatedSize)
        #expect(nodes[caches.storagePath]?.fileCount == 2)
        #expect(try nodes[fixture.url("Library").storagePath]?.allocatedSize == candidate.allocatedSize)
        let stored = try await database.writer.read { try Candidate.fetchAll($0) }
        #expect(stored.count == 1)
    }

    @Test func `file claims finish passes and cloud folders feed candidates`() async throws {
        let fixture = try FixtureBuilder(name: "ScanHandlers")
        try fixture.file("old.dmg", size: 5000)
        try fixture.file("Library/CloudStorage/Drive/remote.dmg", size: 5000)
        let extra = try fixture.file("dup.bin", size: 7000)
        let index = FileIndexCollector(minimumSize: 6000)
        let rules = RecordingHandler { $0.url.pathExtension == "dmg" ? .claim(.test(.oldLarge)) : .descend }
        let duplicates = RecordingHandler(finishPhase: .duplicates, produce: { context in
            index.entries.map { context.candidate(.test(.duplicate), for: $0) }
        })
        let database = try Database.inMemory()
        let config = ScanConfig(roots: [fixture.root], candidateExcluded: ScanConfig.cloudStorageFolders(home: fixture.root))

        let events = try await ScanTest.collect(ScanTest.service(database, handlers: [index, rules, duplicates]).scan(config: config))
        #expect(index.entries.map(\.path) == [extra.storagePath])
        let stored = try await database.writer.read { try Candidate.order(Column("path")).fetchAll($0) }
        #expect(stored.map(\.url.lastPathComponent) == ["dup.bin", "old.dmg"])
        #expect(stored.map(\.category) == [.duplicate, .oldLarge])
        #expect(stored.first?.freeableSize == ScanTest.allocated(extra))

        let phases = events.compactMap {
            if case let .phase(phase) = $0 {
                phase
            } else {
                nil
            }
        }
        #expect(phases == [.walking, .duplicates, .lastUsed])
        guard case .started = events.first, case .finished = events.last else {
            Issue.record("stream must start with started and end with finished")
            return
        }
    }

    @Test func `last used comes from resolver with modified fallback`() async throws {
        let fixture = try FixtureBuilder(name: "ScanLastUsed")
        let used = Date(timeIntervalSince1970: 1_650_000_000)
        let newest = Date(timeIntervalSince1970: 1_690_000_000)
        let modified = Date(timeIntervalSince1970: 1_610_000_000)
        let spotlit = try fixture.file("a.dmg", size: 10, modified: Date(timeIntervalSince1970: 1_600_000_000))
        try fixture.file("b.dmg", size: 10, modified: modified)
        try fixture.file("Cache/inner/x.bin", size: 10, modified: newest)
        try fixture.setDates(of: fixture.url("Cache/inner"), modified: Date(timeIntervalSince1970: 1000))
        try fixture.setDates(of: fixture.url("Cache"), modified: Date(timeIntervalSince1970: 1000))
        let handler = RecordingHandler { entry in
            entry.url.pathExtension == "dmg" || entry.url.lastPathComponent == "Cache" ? .claim(.test()) : .descend
        }
        let database = try Database.inMemory()
        let service = ScanTest.service(database, handlers: [handler], resolver: FixedLastUsedResolver([spotlit: used]))

        let events = try await ScanTest.collect(service.scan(config: ScanConfig(roots: [fixture.root])))
        let stored = try await database.writer.read { try Candidate.fetchAll($0) }
            .reduce(into: [:]) { $0[$1.url.lastPathComponent] = $1 }
        #expect(stored["a.dmg"]?.lastUsedAt == used)
        #expect(stored["b.dmg"]?.lastUsedAt == modified)
        #expect(stored["Cache"]?.lastUsedAt == newest)
        #expect(stored["Cache"]?.modifiedAt == newest)
        let redelivered = try #require(ScanTest.candidates(events).last)
        #expect(redelivered.count == 3)
        #expect(redelivered.allSatisfy { $0.lastUsedAt != nil })
    }

    @Test func `spotlight resolver only answers for requested urls`() async throws {
        let fixture = try FixtureBuilder(name: "ScanSpotlight")
        let urls = try [fixture.file("a.bin", size: 1), fixture.url("missing.bin")]
        let dates = await SpotlightLastUsedResolver().lastUsed(for: urls)
        #expect(Set(dates.keys).isSubset(of: Set(urls)))
    }

    @Test func `config from environment scans the fixture root and drops cloud folders`() throws {
        let fixture = try FixtureBuilder(name: "ScanEnvironment")
        let quarantine = try fixture.url("Quarantine")
        let environment = AppEnvironment(
            arguments: ["app", "-MacSentryScanRoot", fixture.root.storagePath],
            realHomeURL: URL(filePath: "/nonexistent"),
        )
        let config = ScanConfig(environment: environment, quarantineFolder: quarantine)
        #expect(config.roots.map(\.storagePath) == [fixture.root.storagePath])
        #expect(config.excluded == [quarantine])
        #expect(config.effectiveExcluded.contains(URL(filePath: "/System", directoryHint: .isDirectory)))
        #expect(try config.candidateExcluded.map(\.storagePath) == [
            fixture.url("Library/Mobile Documents").storagePath, fixture.url("Library/CloudStorage").storagePath,
        ])
    }
}

final class InsertCommitCounter: TransactionObserver, Sendable {
    private struct State {
        var current = 0
        var commits: [Int] = []
    }

    private let table: String
    private let state = Mutex(State())

    init(table: String) {
        self.table = table
    }

    var commits: [Int] {
        state.withLock { $0.commits }
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
        if case let .insert(tableName) = eventKind {
            return tableName == table
        }
        return false
    }

    func databaseDidChange(with _: DatabaseEvent) {
        state.withLock { $0.current += 1 }
    }

    func databaseDidCommit(_: GRDB.Database) {
        state.withLock { state in
            if state.current > 0 {
                state.commits.append(state.current)
            }
            state.current = 0
        }
    }

    func databaseDidRollback(_: GRDB.Database) {
        state.withLock { $0.current = 0 }
    }
}
