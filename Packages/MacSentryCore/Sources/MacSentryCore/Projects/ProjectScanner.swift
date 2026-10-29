import Foundation

public enum UncommittedState: String, Sendable, Equatable {
    case clean, dirty, unknown
}

public struct GitInfo: Sendable, Equatable {
    public var lastCommitAt: Date?
    public var uncommitted: UncommittedState
    public var gitUnavailable: Bool

    public init(lastCommitAt: Date?, uncommitted: UncommittedState, gitUnavailable: Bool) {
        self.lastCommitAt = lastCommitAt
        self.uncommitted = uncommitted
        self.gitUnavailable = gitUnavailable
    }

    /// The column is 0/1, so unknown is stored as uncommitted to keep it out of the default selection.
    public var storedHasUncommitted: Bool {
        uncommitted != .clean
    }
}

public protocol ProjectScanner: Sendable {
    var artifactFolderNames: Set<String> { get }
    func isProjectRoot(_ dir: URL, entries: [String]) -> ProjectMarker?
    func artifact(for dir: URL, name: String, siblings: [String]) -> ArtifactMatch?
    func enrich(_ projects: [Project]) async -> [Project]
    func gitInfo(forRepositoryAt root: URL) async -> GitInfo
}

public struct DefaultProjectScanner: ProjectScanner {
    public static let enrichConcurrency = 4

    public let catalog: ArtifactCatalog
    let probe: any ProjectFileProbe
    let git: any GitClient

    public init(
        catalog: ArtifactCatalog = .default,
        probe: any ProjectFileProbe = FileManagerProjectProbe(),
        git: any GitClient = ProcessGitClient(),
    ) {
        self.catalog = catalog
        self.probe = probe
        self.git = git
    }

    public var artifactFolderNames: Set<String> {
        catalog.folderNames
    }

    public func isProjectRoot(_ dir: URL, entries: [String]) -> ProjectMarker? {
        let hasGit = entries.contains(".git")
        var ecosystems = Set(ArtifactCatalog.manifests.compactMap { manifest in
            entries.contains { ArtifactCatalog.matches(manifest.pattern, $0) } ? manifest.ecosystem : nil
        })
        if entries.contains("ProjectSettings"), probe.itemExists(at: dir.appending(path: ArtifactCatalog.unityVersionFile)) {
            ecosystems.insert(.unity)
        }
        guard hasGit || !ecosystems.isEmpty else { return nil }
        return ProjectMarker(hasGit: hasGit, ecosystems: ecosystems)
    }

    public func artifact(for dir: URL, name: String, siblings: [String]) -> ArtifactMatch? {
        let parent = dir.deletingLastPathComponent()
        for rule in catalog.rules(named: name) {
            let components = rule.components
            var markerRoot = parent
            var rootEntries = siblings
            if components.count > 1 {
                let expectedParents = components.dropLast().reversed()
                var cursor = parent
                var nestedMatch = true
                for expected in expectedParents {
                    guard cursor.lastPathComponent == expected else {
                        nestedMatch = false
                        break
                    }
                    cursor = cursor.deletingLastPathComponent()
                }
                guard nestedMatch else { continue }
                markerRoot = cursor
                rootEntries = probe.contents(of: cursor)
            }
            if markerSatisfied(rule.marker, artifact: dir, root: markerRoot, rootEntries: rootEntries) {
                return ArtifactMatch(rule: rule, url: dir, markerRoot: markerRoot)
            }
        }
        return nil
    }

    public func enrich(_ projects: [Project]) async -> [Project] {
        await projects.concurrentMap(limit: Self.enrichConcurrency) { project in
            guard probe.itemExists(at: project.rootURL.appending(path: ".git")) else { return project }
            let info = await gitInfo(forRepositoryAt: project.rootURL)
            var enriched = project
            enriched.lastCommitAt = info.lastCommitAt
            enriched.hasUncommitted = info.storedHasUncommitted
            return enriched
        }
    }

    public func gitInfo(forRepositoryAt root: URL) async -> GitInfo {
        let reflog = GitMetadata.gitDirectory(forRoot: root, probe: probe).flatMap(GitMetadata.reflogDate(gitDirectory:))
        async let logResult = result { () async throws(GitError) in try await git.lastCommitDate(in: root) }
        async let statusResult = result { () async throws(GitError) in try await git.hasUncommittedChanges(in: root) }
        let (log, status) = await (logResult, statusResult)

        var unavailable = false
        var lastCommit = reflog
        switch log {
        case let .success(date):
            if let date {
                lastCommit = max(lastCommit ?? date, date)
            }
        case .failure:
            unavailable = true
        }

        let uncommitted: UncommittedState
        switch status {
        case let .success(dirty):
            uncommitted = dirty ? .dirty : .clean
        case .failure:
            uncommitted = .unknown
            unavailable = true
        }
        return GitInfo(lastCommitAt: lastCommit, uncommitted: uncommitted, gitUnavailable: unavailable)
    }

    private func markerSatisfied(_ marker: ArtifactMarker, artifact: URL, root: URL, rootEntries: [String]) -> Bool {
        switch marker {
        case let .sibling(patterns):
            ArtifactCatalog.containsMatch(for: patterns, in: rootEntries)
        case let .contains(name):
            probe.itemExists(at: artifact.appending(path: name))
        case let .rootFile(relativePath):
            probe.itemExists(at: root.appending(path: relativePath))
        case .none:
            true
        }
    }

    private func result<Value: Sendable>(
        _ body: () async throws(GitError) -> Value,
    ) async -> Result<Value, GitError> {
        do {
            return try await .success(body())
        } catch {
            return .failure(error)
        }
    }
}

extension Sequence where Element: Sendable {
    func concurrentMap<Output: Sendable>(
        limit: Int,
        _ transform: @escaping @Sendable (Element) async -> Output,
    ) async -> [Output] {
        let items = Array(self)
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0 ..< Swift.min(Swift.max(limit, 1), items.count) {
                let index = next
                group.addTask { await (index, transform(items[index])) }
                next += 1
            }
            for await (index, output) in group {
                results[index] = output
                if next < items.count {
                    let index = next
                    group.addTask { await (index, transform(items[index])) }
                    next += 1
                }
            }
            return results.compactMap(\.self)
        }
    }
}
