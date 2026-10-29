import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct ProjectScannerTests {
    private typealias Support = GraveyardTestSupport

    @Test func `reflog parse takes the timestamp after the email even with spaces in the name`() {
        let log = """
        0000000 1111111 Jane Q Doe <jane@example.com> 1700000000 +0100\tcommit (initial): first
        1111111 2222222 Jane Q Doe <jane@example.com> 1709294400 -0500\tcommit: second

        """
        #expect(GitMetadata.parseLastReflogTimestamp(log) == Date(timeIntervalSince1970: 1_709_294_400))
        #expect(GitMetadata.parseLastReflogTimestamp("") == nil)
        #expect(GitMetadata.parseLastReflogTimestamp("garbage line without email") == nil)
    }

    @Test func `git file pointer resolves relative and absolute gitdir`() {
        let root = URL(filePath: "/tmp/mono/crates/core", directoryHint: .isDirectory)
        #expect(GitMetadata.parseGitFile("gitdir: ../../.git/modules/core\n", relativeTo: root)?
            .storagePath == "/tmp/mono/.git/modules/core")
        #expect(GitMetadata.parseGitFile("gitdir: /abs/repo.git", relativeTo: root)?.storagePath == "/abs/repo.git")
        #expect(GitMetadata.parseGitFile("nonsense", relativeTo: root) == nil)
    }

    @Test func `project roots require git or a manifest`() throws {
        let fixture = try FixtureBuilder(name: "ScannerRoots")
        try fixture.file("unity/ProjectSettings/ProjectVersion.txt", size: 1)
        let scanner = DefaultProjectScanner(git: GitClientDouble(commit: .success(nil), dirty: .success(false)))
        let dir = fixture.root

        #expect(scanner.isProjectRoot(dir, entries: [".git", "README.md"]) == ProjectMarker(hasGit: true, ecosystems: []))
        #expect(scanner.isProjectRoot(dir, entries: ["package.json", "Cargo.toml"]) == ProjectMarker(
            hasGit: false,
            ecosystems: [.node, .rust],
        ))
        #expect(scanner.isProjectRoot(dir, entries: ["settings.gradle.kts"])?.ecosystems == [.gradle])
        #expect(scanner.isProjectRoot(dir, entries: ["Package.swift", "pyproject.toml"])?.ecosystems == [.apple, .python])
        #expect(scanner.isProjectRoot(fixture.root.appending(path: "unity"), entries: ["ProjectSettings"])?.ecosystems == [.unity])
        #expect(scanner.isProjectRoot(dir, entries: ["ProjectSettings", "requirements.txt", "build.gradle"]) == nil)
    }

    @Test func `artifact catalog markers`() throws {
        let fixture = try FixtureBuilder(name: "ScannerArtifacts")
        try fixture.file("venv/pyvenv.cfg", size: 1)
        try fixture.folder("env")
        let scanner = DefaultProjectScanner(git: GitClientDouble(commit: .success(nil), dirty: .success(false)))
        let dir = fixture.root
        func match(_ name: String, _ siblings: [String]) -> String? {
            scanner.artifact(for: dir.appending(path: name), name: name, siblings: siblings)?.rule.ruleID
        }

        #expect(match("node_modules", ["package.json"]) == "graveyard.node.node_modules")
        #expect(match("node_modules", ["index.js"]) == nil)
        #expect(match("DerivedData", ["App.xcodeproj"]) == "graveyard.apple.DerivedData")
        #expect(match(".build", ["Package.swift"]) == "graveyard.apple..build")
        #expect(match("Pods", ["Podfile"]) == "graveyard.apple.Pods")
        #expect(match("build", ["sketch.ino"]) == "graveyard.arduino.build")
        #expect(match("build", ["pubspec.yaml"]) == "graveyard.flutter.build")
        #expect(match("build", ["app.gradle", "build.gradle"]) == "graveyard.gradle.build")
        #expect(match("build", ["README.md"]) == nil)
        #expect(match("dist", ["package.json"]) == "graveyard.generic.dist")
        #expect(match("target", ["Cargo.toml"]) == "graveyard.rust.target")
        #expect(match("__pycache__", []) == "graveyard.python.__pycache__")
        #expect(match("venv", []) == "graveyard.python.venv")
        #expect(match("env", []) == nil)
        #expect(match("cache", ["package.json"]) == nil)
        #expect(scanner.artifact(for: dir.appending(path: "src"), name: "src", siblings: ["package.json"]) == nil)
        #expect(ArtifactCatalog.default.rules.first { $0.folder == "Pods" }?.tier == .yellow)
        #expect(ArtifactCatalog.default.rules.filter { $0.ecosystem == .generic }.allSatisfy { $0.tier == .yellow })
    }

    @Test func `git info falls back to reflog when git is missing`() async throws {
        let fixture = try FixtureBuilder(name: "ScannerNoGitBinary")
        try fixture.file("repo/.git/logs/HEAD", size: 0)
        try "0 1 A B <a@b.c> 1700000000 +0000\tcommit: x\n".write(to: fixture.url("repo/.git/logs/HEAD"), atomically: true, encoding: .utf8)
        let scanner = DefaultProjectScanner(git: ProcessGitClient(executableURL: nil))

        let info = try await scanner.gitInfo(forRepositoryAt: fixture.url("repo"))

        #expect(info == GitInfo(lastCommitAt: Date(timeIntervalSince1970: 1_700_000_000), uncommitted: .unknown, gitUnavailable: true))
    }

    @Test func `git info takes the newest of reflog and git log`() async throws {
        let fixture = try FixtureBuilder(name: "ScannerNewest")
        try fixture.file("repo/.git/logs/HEAD", size: 0)
        try "0 1 A <a@b.c> 1700000000 +0000\tcheckout: x\n".write(to: fixture.url("repo/.git/logs/HEAD"), atomically: true, encoding: .utf8)
        let newer = Date(timeIntervalSince1970: 1_710_000_000)
        let older = Date(timeIntervalSince1970: 1_600_000_000)

        let newerLog = try await DefaultProjectScanner(git: GitClientDouble(commit: .success(newer), dirty: .success(true)))
            .gitInfo(forRepositoryAt: fixture.url("repo"))
        let olderLog = try await DefaultProjectScanner(git: GitClientDouble(commit: .success(older), dirty: .success(false)))
            .gitInfo(forRepositoryAt: fixture.url("repo"))

        #expect(newerLog == GitInfo(lastCommitAt: newer, uncommitted: .dirty, gitUnavailable: false))
        #expect(olderLog.lastCommitAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func `process git client reads a real repo`() async throws {
        let fixture = try FixtureBuilder(name: "ScannerProcess")
        try fixture.file("repo/a.txt", size: 3)
        let repo = try fixture.url("repo")
        try Support.commitAll(in: repo, home: fixture.root)
        let client = Support.gitClient(home: fixture.root)

        #expect(try await client.lastCommitDate(in: repo) == Support.commitDate)
        #expect(try await client.hasUncommittedChanges(in: repo) == false)
        try fixture.file("repo/untracked.txt", size: 1)
        #expect(try await client.hasUncommittedChanges(in: repo) == false)
        try "changed".write(to: repo.appending(path: "a.txt"), atomically: false, encoding: .utf8)
        #expect(try await client.hasUncommittedChanges(in: repo) == true)
        await #expect(throws: GitError.self) { try await client.lastCommitDate(in: fixture.root) }
    }

    @Test func `process git client times out a hung git`() async throws {
        let fixture = try FixtureBuilder(name: "ScannerTimeout")
        let script = try fixture.file("fake-git", size: 0)
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let client = ProcessGitClient(executableURL: script, timeout: .milliseconds(200))
        let start = ContinuousClock.now

        await #expect(throws: GitError.timedOut) { try await client.hasUncommittedChanges(in: fixture.root) }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func `enrich fills git fields and leaves noGit projects alone`() async throws {
        let fixture = try FixtureBuilder(name: "ScannerEnrich")
        try fixture.file("repo/a.txt", size: 3)
        try fixture.file("plain/Cargo.toml", size: 3)
        let repo = try fixture.url("repo")
        try Support.commitAll(in: repo, home: fixture.root)
        let scanner = Support.scanner(home: fixture.root)
        let projects = try [repo, fixture.url("plain")].map {
            Project(sessionID: 1, rootURL: $0, name: $0.lastPathComponent, ecosystems: [], lastModifiedAt: .now, artifactsSize: 0)
        }

        let enriched = await scanner.enrich(projects)

        #expect(enriched.map(\.lastCommitAt) == [Support.commitDate, nil])
        #expect(enriched.map(\.hasUncommitted) == [false, false])
    }

    @Test func `regeneration hint per ecosystem is exposed on candidates`() {
        #expect(Ecosystem.allCases.allSatisfy { !$0.regenerationHint.isEmpty })
        #expect(Ecosystem.python.regenerationHint.contains("pip install -r requirements.txt"))
        #expect(Ecosystem.rust.regenerationHint.contains("cargo build"))
        #expect(Ecosystem.unity.regenerationHint.contains("reimports"))
        let candidate = Candidate(
            sessionID: 1, url: URL(filePath: "/x/node_modules"), kind: .folder, category: .projectArtifact,
            ruleID: "graveyard.node.node_modules", tier: .green, action: .quarantine, reason: "",
            logicalSize: 0, allocatedSize: 0, freeableSize: 0,
        )
        #expect(candidate.regenerationHint == Ecosystem.node.regenerationHint)
    }
}
