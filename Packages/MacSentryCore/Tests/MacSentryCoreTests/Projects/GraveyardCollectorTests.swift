import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct GraveyardCollectorTests {
    private typealias Support = GraveyardTestSupport

    private func makeNodePythonRepo(_ fixture: FixtureBuilder) throws -> URL {
        let repo = try fixture.folder("Code/webapp")
        try fixture.file("Code/webapp/package.json", size: 20)
        try fixture.file("Code/webapp/src/index.js", size: 100)
        try fixture.file("Code/webapp/.gitignore", size: 0)
        try "node_modules/\n.venv/\n".write(to: fixture.url("Code/webapp/.gitignore"), atomically: true, encoding: .utf8)
        try fixture.file("Code/webapp/node_modules/left-pad/package.json", size: 10)
        try fixture.file("Code/webapp/node_modules/left-pad/index.js", size: 4096)
        try fixture.file("Code/webapp/node_modules/left-pad/node_modules/inner/package.json", size: 10)
        try fixture.file("Code/webapp/node_modules/left-pad/node_modules/inner/index.js", size: 8192)
        try fixture.file("Code/webapp/.venv/pyvenv.cfg", size: 30)
        try fixture.file("Code/webapp/.venv/lib/site.py", size: 2048)
        try Support.commitAll(in: repo, home: fixture.root)
        return repo
    }

    private func collector(_ fixture: FixtureBuilder, scanner: (any ProjectScanner)? = nil) -> GraveyardCollector {
        GraveyardCollector(
            home: fixture.root,
            quarantineFolder: fixture.root.appending(path: "MacSentry Quarantine"),
            scanner: scanner ?? Support.scanner(home: fixture.root),
        )
    }

    @Test func `git repo with node_modules and venv detects project, both artifacts and last commit`() async throws {
        let fixture = try FixtureBuilder(name: "Graveyard")
        let repo = try makeNodePythonRepo(fixture)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        let project = try #require(projects.first)
        #expect(projects.count == 1)
        #expect(project.project.rootURL.storagePath == repo.storagePath)
        #expect(project.project.name == "webapp")
        #expect(project.hasGit)
        #expect(project.project.ecosystems == ["node", "python"])
        #expect(project.project.lastCommitAt == Support.commitDate)
        #expect(project.uncommitted == .clean)
        #expect(!project.gitUnavailable)
        let byRule = Dictionary(uniqueKeysWithValues: project.artifacts.map { ($0.ruleID, $0) })
        #expect(Set(byRule.keys) == ["graveyard.node.node_modules", "graveyard.python..venv"])
        #expect(byRule["graveyard.node.node_modules"]?.tier == .green)
        #expect(byRule["graveyard.python..venv"]?.tier == .yellow)
        #expect(project.artifacts.allSatisfy { $0.category == .projectArtifact && $0.kind == .folder && $0.action == .quarantine })
        #expect(project.project.artifactsSize == project.artifacts.reduce(0) { $0 + $1.freeableSize })
        #expect(byRule["graveyard.node.node_modules"]?.reason.contains("npm install") == true)
    }

    @Test func `source files are never candidates, only artifact folders`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardSource")
        let repo = try makeNodePythonRepo(fixture)
        try fixture.file("Code/webapp/build/output.txt", size: 10)
        try fixture.file("Code/webapp/dist.js", size: 10)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        let urls = projects.flatMap(\.artifacts).map(\.url.storagePath)
        #expect(Set(urls) == [repo.appending(path: "node_modules").storagePath, repo.appending(path: ".venv").storagePath])
        let sources = ["package.json", "src", "src/index.js", ".gitignore", "build", "dist.js"].map { repo.appending(path: $0).storagePath }
        #expect(urls.allSatisfy { !sources.contains($0) })
    }

    @Test func `nested node_modules inside node_modules is counted once`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardNested")
        let repo = try makeNodePythonRepo(fixture)
        let outer = repo.appending(path: "node_modules")

        for honorSkip in [true, false] {
            let projects = try await Support.collect(collector(fixture), root: fixture.root, honorSkip: honorSkip)
            let node = projects.flatMap(\.artifacts).filter { $0.ruleID == "graveyard.node.node_modules" }
            #expect(node.map(\.url.storagePath) == [outer.storagePath])
            #expect(try node.first?.freeableSize == (Support.folderSize(outer)).freeable)
        }

        var decisions: [String: WalkDecision] = [:]
        let collector = collector(fixture)
        let visited = try Support.walk(fixture.root) { entry in
            let decision = collector.visit(entry)
            decisions[entry.url.storagePath] = decision
            return decision
        }
        #expect(decisions[outer.storagePath] == .skipChildren)
        #expect(!visited.contains { $0.storagePath.hasPrefix(outer.storagePath + "/") })
    }

    @Test func `dirty repo reports uncommitted and is never preselected`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardDirty")
        _ = try makeNodePythonRepo(fixture)

        let clean = try #require(try await Support.collect(collector(fixture), root: fixture.root).first)
        #expect(clean.uncommitted == .clean)
        #expect(!clean.project.hasUncommitted)
        #expect(GraveyardPolicy.defaultSelection(for: clean).map(\.ruleID) == ["graveyard.node.node_modules"])

        try "{\"name\":\"changed\"}".write(to: fixture.url("Code/webapp/package.json"), atomically: false, encoding: .utf8)
        let dirty = try #require(try await Support.collect(collector(fixture), root: fixture.root).first)
        #expect(dirty.uncommitted == .dirty)
        #expect(dirty.project.hasUncommitted)
        #expect(GraveyardPolicy.defaultSelection(for: dirty).isEmpty)
    }

    @Test func `artifact paths never include git metadata or source`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardSafety")
        let repo = try makeNodePythonRepo(fixture)
        try fixture.file("Code/webapp/dist/.git/HEAD", size: 10)
        try fixture.file("Code/webapp/dist/bundle.js", size: 10)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        let artifacts = try #require(projects.first).artifacts.map(\.url.storagePath)
        #expect(artifacts.sorted() == [repo.appending(path: ".venv").storagePath, repo.appending(path: "node_modules").storagePath])
        let gitPath = repo.appending(path: ".git").storagePath
        for artifact in artifacts {
            #expect(!artifact.hasPrefix(gitPath))
            #expect(!gitPath.hasPrefix(artifact + "/"))
            #expect(artifact != repo.storagePath)
            #expect(!repo.storagePath.hasPrefix(artifact + "/"))
            #expect(!repo.appending(path: "src/index.js").storagePath.hasPrefix(artifact + "/"))
        }
    }

    @Test func `build folder without marker is ignored`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardBuild")
        let repo = try fixture.folder("Code/tool")
        try fixture.file("Code/tool/README.md", size: 10)
        try fixture.file("Code/tool/build/out.bin", size: 100)
        try Support.commitAll(in: repo, home: fixture.root)
        try fixture.file("Code/gradle-app/build.gradle.kts", size: 10)
        try fixture.file("Code/gradle-app/settings.gradle.kts", size: 10)
        try fixture.file("Code/gradle-app/build/classes/A.class", size: 100)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        #expect(projects.map(\.project.name) == ["gradle-app"])
        #expect(projects.first?.artifacts.map(\.ruleID) == ["graveyard.gradle.build"])
    }

    @Test func `unity Library with ProjectVersion is yellow and without it is ignored`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardUnity")
        try fixture.file("Code/Game/ProjectSettings/ProjectVersion.txt", size: 20)
        try fixture.file("Code/Game/Assets/Player.cs", size: 20)
        try fixture.file("Code/Game/Library/ArtifactDB", size: 4096)
        try fixture.file("Code/NotUnity/ProjectSettings/Other.txt", size: 20)
        try fixture.file("Code/NotUnity/package.json", size: 20)
        try fixture.file("Code/NotUnity/Library/keep.txt", size: 20)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        #expect(projects.map(\.project.name) == ["Game"])
        let artifact = try #require(projects.first?.artifacts.first)
        #expect(artifact.ruleID == "graveyard.unity.Library")
        #expect(artifact.tier == .yellow)
        #expect(projects.first?.project.ecosystems == ["unity"])
        #expect(projects.first.map(GraveyardPolicy.defaultSelection(for:))?.isEmpty == true)
    }

    @Test func `manifest only folder is a noGit project`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardNoGit")
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.file("Code/crate/Cargo.toml", size: 10, modified: old)
        try fixture.file("Code/crate/src/main.rs", size: 10, modified: old)
        try fixture.file("Code/crate/target/debug/crate", size: 4096)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        let project = try #require(projects.first)
        #expect(!project.hasGit)
        #expect(project.project.lastCommitAt == nil)
        #expect(!project.project.hasUncommitted)
        #expect(project.project.ecosystems == ["rust"])
        #expect(project.project.lastModifiedAt == old)
        #expect(project.artifacts.map(\.ruleID) == ["graveyard.rust.target"])
    }

    @Test func `last modified ignores artifacts, git metadata and DS_Store`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardMTime")
        let repo = try makeNodePythonRepo(fixture)
        let old = Date(timeIntervalSince1970: 1_650_000_000)
        let newest = Date(timeIntervalSince1970: 1_660_000_000)
        for path in ["package.json", ".gitignore"] {
            try fixture.setDates(of: repo.appending(path: path), modified: old)
        }
        try fixture.setDates(of: repo.appending(path: "src/index.js"), modified: newest)
        try fixture.file("Code/webapp/.DS_Store", size: 10)

        let project = try #require(try await Support.collect(collector(fixture), root: fixture.root).first)

        #expect(project.project.lastModifiedAt == newest)
    }

    @Test func `nested packages attach to the outermost git root with per package artifacts`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardMonorepo")
        let repo = try fixture.folder("Code/mono")
        try fixture.file("Code/mono/README.md", size: 10)
        try fixture.file("Code/mono/packages/web/package.json", size: 10)
        try fixture.file("Code/mono/packages/web/node_modules/react/index.js", size: 1024)
        try fixture.file("Code/mono/packages/web/.angular/cache/data.bin", size: 1024)
        try fixture.file("Code/mono/packages/web/.angular/config.json", size: 10)
        try fixture.file("Code/mono/crates/core/Cargo.toml", size: 10)
        try fixture.file("Code/mono/crates/core/target/out", size: 1024)
        try fixture.file("Code/mono/node_modules/README", size: 10)
        try Support.commitAll(in: repo, home: fixture.root)
        try "gitdir: ../../.git/modules/core\n".write(to: fixture.url("Code/mono/crates/core/.git"), atomically: true, encoding: .utf8)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.project.rootURL.storagePath == repo.storagePath)
        #expect(project.project.ecosystems == ["node", "rust"])
        #expect(Set(project.artifacts.map(\.url.storagePath)) == [
            repo.appending(path: "packages/web/node_modules").storagePath,
            repo.appending(path: "packages/web/.angular/cache").storagePath,
            repo.appending(path: "crates/core/target").storagePath,
        ])
        #expect(project.artifacts.contains { $0.ruleID == "graveyard.node..angular/cache" })
    }

    @Test func `symlinked node_modules is never an artifact`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardSymlink")
        let store = try fixture.folder("Code/store/real_modules")
        try fixture.file("Code/store/real_modules/dep/index.js", size: 1024)
        try fixture.file("Code/pnpm-app/package.json", size: 10)
        try fixture.symlink("Code/pnpm-app/node_modules", to: store)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        #expect(projects.isEmpty)
    }

    @Test func `library, trash, quarantine and hidden home folders are skipped`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardExcluded")
        for base in ["Library/App", ".vscode/extensions/ext", ".Trash/old", "MacSentry Quarantine/batch/proj"] {
            try fixture.file("\(base)/package.json", size: 10)
            try fixture.file("\(base)/node_modules/dep/index.js", size: 1024)
        }
        try fixture.file("package.json", size: 10)
        try fixture.file("node_modules/dep/index.js", size: 1024)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        #expect(projects.isEmpty)
    }

    @Test func `python caches need an owning project`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardPyCache")
        try fixture.file("Scripts/tool.py", size: 10)
        try fixture.file("Scripts/__pycache__/tool.cpython-312.pyc", size: 512)
        try fixture.file("Code/svc/pyproject.toml", size: 10)
        try fixture.file("Code/svc/app/__pycache__/main.pyc", size: 512)
        try fixture.file("Code/loose/requirements.txt", size: 10)
        try fixture.file("Code/loose/venv/pyvenv.cfg", size: 10)
        try fixture.file("Code/loose/env/not-a-venv.txt", size: 10)

        let projects = try await Support.collect(collector(fixture), root: fixture.root)

        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.project.name, $0.artifacts.map(\.ruleID)) })
        #expect(names == ["svc": ["graveyard.python.__pycache__"], "loose": ["graveyard.python.venv"]])
    }

    @Test func `git failure is reported as unavailable with unknown uncommitted state`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardGitDown")
        _ = try makeNodePythonRepo(fixture)
        let scanner = DefaultProjectScanner(git: GitClientDouble(commit: .failure(.timedOut), dirty: .failure(.timedOut)))

        let project = try #require(try await Support.collect(collector(fixture, scanner: scanner), root: fixture.root).first)

        #expect(project.gitUnavailable)
        #expect(project.uncommitted == .unknown)
        #expect(project.project.hasUncommitted)
        #expect(project.project.lastCommitAt == Support.commitDate)
        #expect(GraveyardPolicy.defaultSelection(for: project).isEmpty)
    }

    @Test func `collector uses the injected scanner git info`() async throws {
        let fixture = try FixtureBuilder(name: "GraveyardDouble")
        _ = try makeNodePythonRepo(fixture)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let scanner = ProjectScannerDouble(info: GitInfo(lastCommitAt: date, uncommitted: .dirty, gitUnavailable: false))

        let project = try #require(try await Support.collect(collector(fixture, scanner: scanner), root: fixture.root).first)

        #expect(project.project.lastCommitAt == date)
        #expect(project.uncommitted == .dirty)
    }
}
