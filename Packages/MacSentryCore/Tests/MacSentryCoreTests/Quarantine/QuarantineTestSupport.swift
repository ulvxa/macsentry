import Darwin
import Foundation
import GRDB
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct StubProtectionPolicy: ProtectionPolicy {
    var denied: Set<String> = []

    func check(_ url: URL) -> ProtectionVerdict {
        denied.contains(url.storagePath) ? .denied("denied by test") : .allowed
    }
}

struct StubAppInventory: AppInventory {
    var running: Set<String> = []
    var runningNames: [String] = []

    func installedApps() async -> [InstalledApp] {
        []
    }

    func runningAppNames() -> [String] {
        runningNames
    }

    func isRunning(bundleID: String) -> Bool {
        running.contains(bundleID)
    }
}

struct WalkingSizeCalculator: SizeCalculator {
    func sizeInfo(for entry: FileEntry) -> SizeInfo {
        SizeInfo(logical: entry.logicalSize, allocated: entry.allocatedSize, freeable: entry.allocatedSize)
    }

    func aggregate(folder: URL) async throws -> SizeInfo {
        let allocated = Self.allocated(folder)
        return SizeInfo(logical: allocated, allocated: allocated, freeable: allocated)
    }

    static func allocated(_ url: URL) -> Int64 {
        guard let info = lstatInfo(url) else { return 0 }
        guard info.st_mode & S_IFMT == S_IFDIR else { return Int64(info.st_blocks) * 512 }
        let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return children.reduce(0) { total, child in
            guard let childInfo = lstatInfo(child), childInfo.st_mode & S_IFMT != S_IFDIR else { return total }
            return total + Int64(childInfo.st_blocks) * 512
        }
    }
}

struct HookedSizeCalculator: SizeCalculator {
    let onAggregate: @Sendable (URL) async -> Void

    func sizeInfo(for entry: FileEntry) -> SizeInfo {
        WalkingSizeCalculator().sizeInfo(for: entry)
    }

    func aggregate(folder: URL) async throws -> SizeInfo {
        let info = try await WalkingSizeCalculator().aggregate(folder: folder)
        await onAggregate(folder)
        return info
    }
}

final class SwitchablePolicy: ProtectionPolicy {
    private let denied = Mutex(false)

    func deny() {
        denied.withLock { $0 = true }
    }

    func check(_: URL) -> ProtectionVerdict {
        denied.withLock { $0 } ? .denied("switched to deny") : .allowed
    }
}

struct FixtureTrasher: Trasher {
    let trashDirectory: URL

    func trash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        let destination = trashDirectory.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class Recorder<Value: Sendable>: Sendable {
    private let storage = Mutex<[Value]>([])

    var values: [Value] {
        storage.withLock { $0 }
    }

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }
}

func lstatInfo(_ url: URL) -> stat? {
    var info = stat()
    return lstat(url.path(percentEncoded: false), &info) == 0 ? info : nil
}

func inode(_ url: URL) -> UInt64? {
    lstatInfo(url)?.st_ino
}

func exists(_ url: URL) -> Bool {
    lstatInfo(url) != nil
}

struct QuarantineHarness {
    static let fixedDate = Date(timeIntervalSince1970: 1_761_716_712)
    static let timeZone = TimeZone(secondsFromGMT: 3600) ?? .gmt

    let fixture: FixtureBuilder
    let home: URL
    let trashDirectory: URL
    let database: MacSentryCore.Database
    let sessionID: Int64

    var quarantineRoot: URL {
        DefaultQuarantineService.quarantineRoot(home: home)
    }

    init(name: String = "Quarantine") throws {
        fixture = try FixtureBuilder(name: name)
        home = try fixture.folder("home")
        trashDirectory = try fixture.url("Trash")
        database = try MacSentryCore.Database.inMemory()
        var session = ScanSession(startedAt: Self.fixedDate, status: .finished, roots: [home])
        try database.writer.write { try session.insert($0) }
        sessionID = try #require(session.id)
    }

    func makeService(
        isDryRun: Bool = false,
        denied: [URL] = [],
        running: Set<String> = [],
        runningNames: [String] = [],
        database: MacSentryCore.Database? = nil,
        policy: (any ProtectionPolicy)? = nil,
        sizeCalculator: any SizeCalculator = WalkingSizeCalculator(),
        now: @escaping @Sendable () -> Date = { Date() },
        runningAppURL: URL = Bundle.main.bundleURL,
    ) -> DefaultQuarantineService {
        DefaultQuarantineService(
            database: database ?? self.database,
            quarantineRoot: quarantineRoot,
            isDryRun: isDryRun,
            protectionPolicy: policy ?? StubProtectionPolicy(denied: Set(denied.map(\.storagePath))),
            appInventory: StubAppInventory(running: running, runningNames: runningNames),
            sizeCalculator: sizeCalculator,
            trasher: FixtureTrasher(trashDirectory: trashDirectory),
            timeZone: Self.timeZone,
            now: now,
            runningAppURL: runningAppURL,
        )
    }

    func candidate(
        _ url: URL,
        kind: CandidateKind = .folder,
        ruleID: String = "test.cache",
        tier: Tier = .green,
        action: CandidateAction = .quarantine,
        appBundleID: String? = nil,
        allocated: Int64? = nil,
        freeable: Int64 = 1000,
    ) throws -> Candidate {
        var candidate = Candidate(
            sessionID: sessionID,
            url: url,
            kind: kind,
            category: .devCache,
            ruleID: ruleID,
            tier: tier,
            action: action,
            reason: "test",
            appBundleID: appBundleID,
            logicalSize: freeable,
            allocatedSize: allocated ?? WalkingSizeCalculator.allocated(url),
            freeableSize: freeable,
        )
        try database.writer.write { try candidate.insert($0) }
        return candidate
    }

    func candidateStatus(_ id: Int64?) throws -> CandidateStatus? {
        try database.writer.read { try Candidate.fetchOne($0, key: id)?.status }
    }

    func entry(_ id: Int64?, in database: MacSentryCore.Database? = nil) throws -> QuarantineEntry? {
        try (database ?? self.database).writer.read { try QuarantineEntry.fetchOne($0, key: id) }
    }

    func batch(_ id: Int64?) throws -> QuarantineBatch? {
        try database.writer.read { try QuarantineBatch.fetchOne($0, key: id) }
    }

    func batchFolder(_ id: Int64?) throws -> URL {
        let batch = try #require(try batch(id))
        return quarantineRoot.appending(path: batch.folderName, directoryHint: .isDirectory)
    }

    func manifest(in folder: URL) throws -> QuarantineManifest {
        try QuarantineManifest.decode(Data(contentsOf: folder.appending(path: "manifest.json")))
    }

    func moveAway(_ url: URL, as name: String) throws -> URL {
        let destination = try fixture.url("elsewhere/\(name)")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func trashContents() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: trashDirectory.path(percentEncoded: false))) ?? []
    }
}

extension QuarantineHarness {
    func realProvider(ignored: [URL] = [], neverTouch: [String] = []) async throws -> ProtectionPolicyProvider {
        let provider = try ProtectionPolicyProvider(
            homeURL: home,
            databaseURL: fixture.url("db/macsentry.sqlite"),
            neverTouchStore: InMemoryNeverTouchStore(patterns: neverTouch),
            ignoredPathStore: InMemoryIgnoredPathStore(urls: ignored),
        )
        try await provider.refresh()
        return provider
    }

    func writeManifest(batch name: String, entries: [(original: String, quarantine: String)]) throws {
        let items = entries.map { item in
            """
            {"originalPath":"\(item.original)","quarantinePath":"\(item.quarantine)","kind":"file","ruleId":"r","tier":"green",\
            "size":1,"status":"inQuarantine"}
            """
        }
        let json = """
        {"version":1,"batch":"\(name)","createdAt":"2020-01-03T00:00:00Z","dryRun":false,"entries":[\(items.joined(separator: ","))]}
        """
        let url = quarantineRoot.appending(path: name).appending(path: "manifest.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }
}
