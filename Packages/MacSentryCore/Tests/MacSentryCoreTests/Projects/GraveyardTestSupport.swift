import Foundation
import MacSentryTestSupport
import Synchronization
@testable import MacSentryCore

enum GraveyardTestSupport {
    static let commitDate = Date(timeIntervalSince1970: 1_709_294_400)

    static func entry(for url: URL) throws -> FileEntry {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey, .fileAllocatedSizeKey,
            .creationDateKey, .contentModificationDateKey,
        ])
        let kind: EntryKind = if values.isSymbolicLink == true {
            .symlink
        } else if values.isPackage == true {
            .package
        } else if values.isDirectory == true {
            .folder
        } else {
            .file
        }
        return FileEntry(
            url: url,
            kind: kind,
            logicalSize: Int64(values.fileSize ?? 0),
            allocatedSize: Int64(values.fileAllocatedSize ?? 0),
            privateSize: nil,
            linkCount: 1,
            inode: 0,
            device: 0,
            flags: 0,
            created: values.creationDate,
            modified: values.contentModificationDate,
            ownerUID: getuid(),
        )
    }

    @discardableResult
    static func walk(_ root: URL, honorSkip: Bool = true, visit: (FileEntry) -> WalkDecision) throws -> [URL] {
        var visited: [URL] = []
        var stack = [root]
        while let directory = stack.popLast() {
            let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                let entry = try entry(for: child)
                visited.append(child)
                let decision = visit(entry)
                if entry.kind == .folder, decision == .descend || !honorSkip {
                    stack.append(child)
                }
            }
        }
        return visited
    }

    static func collect(_ collector: GraveyardCollector, root: URL, honorSkip: Bool = true) async throws -> [GraveyardProject] {
        try walk(root, honorSkip: honorSkip) { collector.visit($0) }
        return await collector.finish(sessionID: 1, sizeOf: folderSize)
    }

    @Sendable static func folderSize(_ url: URL) throws -> SizeInfo {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let child = enumerator?.nextObject() as? URL {
            let values = try child.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            logical += Int64(values.fileSize ?? 0)
            allocated += Int64(values.fileAllocatedSize ?? 0)
        }
        return SizeInfo(logical: logical, allocated: allocated, freeable: allocated)
    }

    static func gitEnvironment(home: URL) -> [String: String] {
        [
            "HOME": home.path(percentEncoded: false),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        ]
    }

    static func gitClient(home: URL, timeout: Duration = .seconds(30)) -> ProcessGitClient {
        ProcessGitClient(executableURL: URL(filePath: "/usr/bin/git"), timeout: timeout, environmentOverrides: gitEnvironment(home: home))
    }

    static func scanner(home: URL) -> DefaultProjectScanner {
        DefaultProjectScanner(git: gitClient(home: home))
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL, home: URL, date: Date = commitDate) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = [
            "-c", "user.name=Fixture Author", "-c", "user.email=fixture@example.com",
            "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
        ] + arguments
        process.currentDirectoryURL = directory
        let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
        process.environment = gitEnvironment(home: home).merging([
            "GIT_AUTHOR_NAME": "Fixture Author", "GIT_AUTHOR_EMAIL": "fixture@example.com", "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_NAME": "Fixture Author", "GIT_COMMITTER_EMAIL": "fixture@example.com", "GIT_COMMITTER_DATE": stamp,
            "PATH": "/usr/bin:/bin",
        ]) { $1 }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw GitFixtureError.failed(arguments.joined(separator: " "), text)
        }
        return text
    }

    static func commitAll(in directory: URL, home: URL, date: Date = commitDate) throws {
        try git(["init", "-q"], in: directory, home: home, date: date)
        try git(["add", "-A"], in: directory, home: home, date: date)
        try git(["commit", "-q", "-m", "initial"], in: directory, home: home, date: date)
    }
}

enum GitFixtureError: Error {
    case failed(String, String)
}

struct GitClientDouble: GitClient {
    var commit: Result<Date?, GitError>
    var dirty: Result<Bool, GitError>

    func lastCommitDate(in _: URL) async throws(GitError) -> Date? {
        try commit.get()
    }

    func hasUncommittedChanges(in _: URL) async throws(GitError) -> Bool {
        try dirty.get()
    }
}

struct ProjectScannerDouble: ProjectScanner {
    var base = DefaultProjectScanner(git: GitClientDouble(commit: .success(nil), dirty: .success(false)))
    var info = GitInfo(lastCommitAt: nil, uncommitted: .clean, gitUnavailable: false)

    var artifactFolderNames: Set<String> {
        base.artifactFolderNames
    }

    func isProjectRoot(_ dir: URL, entries: [String]) -> ProjectMarker? {
        base.isProjectRoot(dir, entries: entries)
    }

    func artifact(for dir: URL, name: String, siblings: [String]) -> ArtifactMatch? {
        base.artifact(for: dir, name: name, siblings: siblings)
    }

    func enrich(_ projects: [Project]) async -> [Project] {
        projects
    }

    func gitInfo(forRepositoryAt _: URL) async -> GitInfo {
        info
    }
}

final class AppInventoryDouble: AppInventory {
    private let running: Mutex<Set<String>>

    init(running: Set<String> = []) {
        self.running = Mutex(running)
    }

    func installedApps() async -> [InstalledApp] {
        []
    }

    func isRunning(bundleID: String) -> Bool {
        running.withLock { $0.contains(bundleID) }
    }
}

final class ProjectStoreDouble: ProjectStore {
    let saved = Mutex<[GraveyardProject]>([])

    func save(_ projects: [GraveyardProject]) async throws(ProjectStoreError) -> [GraveyardProject] {
        saved.withLock { $0 += projects }
        return projects
    }
}
